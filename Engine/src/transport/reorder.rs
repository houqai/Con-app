use std::collections::VecDeque;

use super::packet::{DATA_CONT_HEADER, DATA_FIRST_HEADER, FLAG_LAST_FRAGMENT};

pub const DATA_WINDOW: usize = 16;
pub const MAX_MESSAGE: usize = 1 << 20;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Insert {
    Stored,
    Old,
    Duplicate,
    TooFar,
}

#[derive(Debug)]
pub struct DataWindow<T> {
    start: u32,
    slots: VecDeque<Option<T>>,
}

impl<T> DataWindow<T> {
    pub fn new(start: u32) -> Self {
        Self {
            start,
            slots: VecDeque::new(),
        }
    }

    pub fn start(&self) -> u32 {
        self.start
    }

    pub fn insert(&mut self, tsn: u32, item: T) -> Insert {
        let d = tsn.wrapping_sub(self.start);
        if d >= 0x8000_0000 {
            return Insert::Old;
        }
        let d = d as usize;
        if d >= DATA_WINDOW {
            return Insert::TooFar;
        }
        while self.slots.len() <= d {
            self.slots.push_back(None);
        }
        if self.slots[d].is_some() {
            return Insert::Duplicate;
        }
        self.slots[d] = Some(item);
        Insert::Stored
    }

    pub fn pop_ready(&mut self) -> Option<(u32, T)> {
        let item = self.slots.front_mut()?.take()?;
        self.slots.pop_front();
        let tsn = self.start;
        self.start = self.start.wrapping_add(1);
        Some((tsn, item))
    }

    pub fn retain(&mut self, mut keep: impl FnMut(u32, &mut T) -> bool) {
        let start = self.start;
        for (i, slot) in self.slots.iter_mut().enumerate() {
            if let Some(item) = slot {
                if !keep(start.wrapping_add(i as u32), item) {
                    *slot = None;
                }
            }
        }
        while matches!(self.slots.back(), Some(None)) {
            self.slots.pop_back();
        }
    }

    #[cfg(test)]
    pub fn held(&self) -> usize {
        self.slots.iter().filter(|s| s.is_some()).count()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DataMessage {
    pub channel: u16,
    pub data_type: u8,
    pub data: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Assembled {
    Message(DataMessage),
    Pending,
    DroppedSecondStart,
    DroppedShort,
    DroppedTooLarge,
}

#[derive(Debug)]
struct Pending {
    channel: u16,
    data_type: u8,
    data: Vec<u8>,
}

#[derive(Debug, Default)]
pub struct Reassembler {
    pending: Option<Pending>,
}

impl Reassembler {
    pub fn new() -> Self {
        Self::default()
    }

    #[cfg(test)]
    pub fn pending_channel(&self) -> Option<u16> {
        self.pending.as_ref().map(|p| p.channel)
    }

    pub fn push(&mut self, channel: u16, flags: u8, payload: &[u8]) -> Assembled {
        let last = flags & FLAG_LAST_FRAGMENT != 0;
        if let Some(pending) = self.pending.as_mut().filter(|p| p.channel == channel) {
            let body = &payload[DATA_CONT_HEADER.min(payload.len())..];
            if pending.data.len() + body.len() > MAX_MESSAGE {
                self.pending = None;
                return Assembled::DroppedTooLarge;
            }
            pending.data.extend_from_slice(body);
            if !last {
                return Assembled::Pending;
            }
            let data_type = pending.data_type;
            let data = std::mem::take(&mut pending.data);
            self.pending = None;
            return Assembled::Message(DataMessage {
                channel,
                data_type,
                data,
            });
        }
        if payload.len() < DATA_FIRST_HEADER {
            self.pending = None;
            return Assembled::DroppedShort;
        }
        let data_type = payload[DATA_FIRST_HEADER - 1];
        let body = &payload[DATA_FIRST_HEADER..];
        if last {
            return Assembled::Message(DataMessage {
                channel,
                data_type,
                data: body.to_vec(),
            });
        }
        if self.pending.is_some() {
            return Assembled::DroppedSecondStart;
        }
        if body.len() > MAX_MESSAGE {
            return Assembled::DroppedTooLarge;
        }
        self.pending = Some(Pending {
            channel,
            data_type,
            data: body.to_vec(),
        });
        Assembled::Pending
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transport::packet::encode_data_payload;

    #[test]
    fn window_orders_and_drops() {
        let mut w = DataWindow::new(100);
        assert_eq!(w.insert(102, 'c'), Insert::Stored);
        assert_eq!(w.pop_ready(), None);
        assert_eq!(w.insert(100, 'a'), Insert::Stored);
        assert_eq!(w.insert(100, 'x'), Insert::Duplicate);
        assert_eq!(w.insert(115, 'z'), Insert::Stored);
        assert_eq!(w.insert(116, 'y'), Insert::TooFar);
        assert_eq!(w.pop_ready(), Some((100, 'a')));
        assert_eq!(w.pop_ready(), None);
        assert_eq!(w.insert(99, 'o'), Insert::Old);
        assert_eq!(w.insert(101, 'b'), Insert::Stored);
        assert_eq!(w.pop_ready(), Some((101, 'b')));
        assert_eq!(w.pop_ready(), Some((102, 'c')));
        assert_eq!(w.start(), 103);
        assert_eq!(w.held(), 1);
        w.retain(|_, _| false);
        assert_eq!(w.held(), 0);
    }

    #[test]
    fn window_wraps() {
        let mut w = DataWindow::new(u32::MAX - 1);
        assert_eq!(w.insert(1, 3), Insert::Stored);
        assert_eq!(w.insert(u32::MAX, 1), Insert::Stored);
        assert_eq!(w.insert(0, 2), Insert::Stored);
        assert_eq!(w.insert(u32::MAX - 1, 0), Insert::Stored);
        let got: Vec<_> = std::iter::from_fn(|| w.pop_ready()).collect();
        assert_eq!(got, vec![(u32::MAX - 1, 0), (u32::MAX, 1), (0, 2), (1, 3)]);
        assert_eq!(w.insert(u32::MAX, 9), Insert::Old);
    }

    fn first(channel: u16, ty: u8, data: &[u8]) -> Vec<u8> {
        encode_data_payload(0, channel, Some(ty), data)
    }

    fn cont(channel: u16, data: &[u8]) -> Vec<u8> {
        encode_data_payload(0, channel, None, data)
    }

    #[test]
    fn reassembly_rules() {
        let mut r = Reassembler::new();
        assert_eq!(
            r.push(1, 1, &first(1, 0, b"hb")),
            Assembled::Message(DataMessage {
                channel: 1,
                data_type: 0,
                data: b"hb".to_vec()
            })
        );
        assert_eq!(r.push(1, 0, &first(1, 0, b"abc")), Assembled::Pending);
        assert_eq!(r.pending_channel(), Some(1));
        assert!(matches!(
            r.push(9, 1, &first(9, 0, b"x")),
            Assembled::Message(DataMessage { channel: 9, .. })
        ));
        assert_eq!(
            r.push(2, 0, &first(2, 0, b"zz")),
            Assembled::DroppedSecondStart
        );
        assert_eq!(r.push(1, 0, &cont(1, b"def")), Assembled::Pending);
        assert_eq!(
            r.push(1, 1, &cont(1, b"g")),
            Assembled::Message(DataMessage {
                channel: 1,
                data_type: 0,
                data: b"abcdefg".to_vec()
            })
        );
        assert_eq!(r.pending_channel(), None);
        assert_eq!(r.push(3, 0, &first(3, 7, b"q")), Assembled::Pending);
        assert_eq!(r.push(4, 1, &cont(4, b"")), Assembled::DroppedShort);
        assert_eq!(r.pending_channel(), None);
    }

    #[test]
    fn reassembly_limit() {
        let mut r = Reassembler::new();
        let big = vec![0u8; 600 * 1024];
        assert_eq!(r.push(1, 0, &first(1, 0, &big)), Assembled::Pending);
        assert_eq!(r.push(1, 0, &cont(1, &big)), Assembled::DroppedTooLarge);
        assert_eq!(r.pending_channel(), None);
    }
}
