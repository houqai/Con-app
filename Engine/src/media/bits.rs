fn unescaped(nal: &[u8]) -> impl Iterator<Item = (usize, u8)> + '_ {
    let mut zeros = 0usize;
    nal.iter().copied().enumerate().filter(move |&(_, b)| {
        if zeros >= 2 && b == 0x03 {
            zeros = 0;
            return false;
        }
        zeros = if b == 0 { zeros + 1 } else { 0 };
        true
    })
}

pub fn unescape_nal(nal: &[u8]) -> Vec<u8> {
    let mut rbsp = Vec::with_capacity(nal.len());
    rbsp.extend(unescaped(nal).map(|(_, b)| b));
    rbsp
}

#[cfg(test)]
pub(crate) fn raw_offset(nal: &[u8], rbsp_byte: usize) -> Option<usize> {
    unescaped(nal).nth(rbsp_byte).map(|(i, _)| i)
}

#[derive(Clone, Debug)]
pub struct BitReader<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> BitReader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }

    pub fn position(&self) -> usize {
        self.pos
    }

    pub fn remaining(&self) -> usize {
        (self.data.len() * 8).saturating_sub(self.pos)
    }

    pub fn bit(&mut self) -> Option<bool> {
        let byte = *self.data.get(self.pos / 8)?;
        let v = byte & (0x80 >> (self.pos % 8)) != 0;
        self.pos += 1;
        Some(v)
    }

    pub fn bits(&mut self, n: u32) -> Option<u32> {
        if n > 32 || self.remaining() < n as usize {
            return None;
        }
        let mut v = 0u64;
        for _ in 0..n {
            v = (v << 1) | u64::from(self.bit()?);
        }
        Some(v as u32)
    }

    pub fn skip(&mut self, n: usize) -> Option<()> {
        if self.remaining() < n {
            return None;
        }
        self.pos += n;
        Some(())
    }

    pub fn ue(&mut self) -> Option<u32> {
        let mut zeros = 0u32;
        while !self.bit()? {
            zeros += 1;
            if zeros > 31 {
                return None;
            }
        }
        if zeros == 0 {
            return Some(0);
        }
        let rest = u64::from(self.bits(zeros)?);
        let v = (1u64 << zeros) - 1 + rest;
        u32::try_from(v).ok()
    }

    pub fn se(&mut self) -> Option<i32> {
        let k = self.ue()?;
        let mag = k.div_ceil(2) as i32;
        Some(if k % 2 == 1 { mag } else { -mag })
    }
}

#[derive(Clone, Debug, Default)]
pub struct BitWriter {
    bytes: Vec<u8>,
    len: usize,
}

impl BitWriter {
    pub fn new() -> Self {
        Self::default()
    }

    #[cfg(test)]
    pub fn len_bits(&self) -> usize {
        self.len
    }

    pub fn bit(&mut self, v: bool) -> &mut Self {
        if self.len.is_multiple_of(8) {
            self.bytes.push(0);
        }
        if v {
            let last = self.bytes.len() - 1;
            self.bytes[last] |= 0x80 >> (self.len % 8);
        }
        self.len += 1;
        self
    }

    pub fn bits(&mut self, n: u32, v: u64) -> &mut Self {
        for i in (0..n).rev() {
            self.bit(v >> i & 1 == 1);
        }
        self
    }

    pub fn ue(&mut self, v: u32) -> &mut Self {
        let x = u64::from(v) + 1;
        let n = 64 - x.leading_zeros();
        self.bits(n - 1, 0);
        self.bits(n, x)
    }

    pub fn se(&mut self, v: i32) -> &mut Self {
        let k = if v > 0 {
            (v as u32) * 2 - 1
        } else {
            v.unsigned_abs() * 2
        };
        self.ue(k)
    }

    pub fn trailing(&mut self) -> &mut Self {
        self.bit(true);
        while !self.len.is_multiple_of(8) {
            self.bit(false);
        }
        self
    }

    #[cfg(test)]
    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }

    pub fn annex_b_nal(&self, header: &[u8]) -> Vec<u8> {
        let mut out = vec![0, 0, 0, 1];
        out.extend_from_slice(header);
        out.extend_from_slice(&add_emulation_prevention(&self.bytes));
        out
    }
}

pub fn add_emulation_prevention(payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(payload.len() + payload.len() / 64 + 1);
    let mut zeros = 0usize;
    for &b in payload {
        if zeros >= 2 && b <= 3 {
            out.push(3);
            zeros = 0;
        }
        out.push(b);
        zeros = if b == 0 { zeros + 1 } else { 0 };
    }
    out
}

pub fn escape_nal(rbsp: &[u8]) -> Vec<u8> {
    let mut out = add_emulation_prevention(rbsp);
    if out.last() == Some(&0) {
        out.push(3);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escape_round_trip() {
        for nal in [
            &[0x02, 0x01, 0x00, 0x00, 0x03, 0x00, 0x05][..],
            &[0x02, 0x01, 0x80, 0x00, 0x00, 0x03][..],
            &[0x02, 0x01, 0x00, 0x00, 0x03, 0x01, 0x00, 0x00, 0x03, 0x03][..],
        ] {
            assert_eq!(escape_nal(&unescape_nal(nal)), nal);
        }
    }

    #[test]
    fn exp_golomb_round_trip() {
        let mut w = BitWriter::new();
        let values = [0u32, 1, 2, 3, 7, 8, 255, 65535, 1 << 20];
        for v in values {
            w.ue(v);
        }
        for v in [-5i32, -1, 0, 1, 2, 100] {
            w.se(v);
        }
        w.bits(5, 0b10110).trailing();
        let mut r = BitReader::new(w.bytes());
        for v in values {
            assert_eq!(r.ue(), Some(v));
        }
        for v in [-5i32, -1, 0, 1, 2, 100] {
            assert_eq!(r.se(), Some(v));
        }
        assert_eq!(r.bits(5), Some(0b10110));
        assert_eq!(r.bit(), Some(true));
    }

    #[test]
    fn known_codes() {
        let mut w = BitWriter::new();
        w.ue(0).ue(1).ue(2).ue(3);
        assert_eq!(w.len_bits(), 1 + 3 + 3 + 5);
        assert_eq!(w.bytes(), &[0b1010_0110, 0b0100_0000]);
    }

    #[test]
    fn emulation_prevention_both_ways() {
        let payload = [
            0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x03, 0x05, 0x00, 0x00,
        ];
        let nal = add_emulation_prevention(&payload);
        assert_eq!(
            nal,
            vec![
                0x00, 0x00, 0x03, 0x01, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x03, 0x05, 0x00, 0x00
            ]
        );
        assert_eq!(unescape_nal(&nal), payload);
        assert_eq!(raw_offset(&nal, 2), Some(3));
        assert_eq!(raw_offset(&nal, 7), Some(10));
        assert_eq!(raw_offset(&nal, payload.len()), None);
    }

    #[test]
    fn reader_limits() {
        let mut r = BitReader::new(&[0x00]);
        assert_eq!(r.ue(), None);
        let mut r = BitReader::new(&[0xff]);
        assert_eq!(r.bits(9), None);
        assert_eq!(r.bits(8), Some(0xff));
        assert_eq!(r.bit(), None);
    }
}
