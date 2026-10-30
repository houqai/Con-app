pub mod messages;

pub use messages::*;

pub const WIRE_VARINT: u8 = 0;
pub const WIRE_FIXED64: u8 = 1;
pub const WIRE_LEN: u8 = 2;
pub const WIRE_FIXED32: u8 = 5;

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum ProtoError {
    #[error("truncated protobuf data")]
    Truncated,
    #[error("varint too long")]
    VarintTooLong,
    #[error("unsupported wire type {0}")]
    BadWireType(u8),
    #[error("field {field} has wire type {got}, expected {expected}")]
    WrongWireType { field: u32, got: u8, expected: u8 },
    #[error("required field {field} of {message} is missing")]
    MissingRequired { message: &'static str, field: u32 },
    #[error("field number 0")]
    ZeroField,
}

pub fn put_varint(out: &mut Vec<u8>, mut v: u64) {
    while v >= 0x80 {
        out.push((v as u8) | 0x80);
        v >>= 7;
    }
    out.push(v as u8);
}

pub fn put_key(out: &mut Vec<u8>, field: u32, wire: u8) {
    put_varint(out, (u64::from(field) << 3) | u64::from(wire));
}

pub fn get_varint(data: &[u8], pos: &mut usize) -> Result<u64, ProtoError> {
    let mut v = 0u64;
    for i in 0..10 {
        let b = *data.get(*pos).ok_or(ProtoError::Truncated)?;
        *pos += 1;
        v |= u64::from(b & 0x7f) << (7 * i);
        if b & 0x80 == 0 {
            return Ok(v);
        }
    }
    Err(ProtoError::VarintTooLong)
}

fn read_fixed32(data: &[u8], pos: &mut usize) -> Result<u32, ProtoError> {
    let b = data.get(*pos..*pos + 4).ok_or(ProtoError::Truncated)?;
    *pos += 4;
    Ok(u32::from_le_bytes(b.try_into().expect("4 bytes")))
}

fn read_fixed64(data: &[u8], pos: &mut usize) -> Result<u64, ProtoError> {
    let b = data.get(*pos..*pos + 8).ok_or(ProtoError::Truncated)?;
    *pos += 8;
    Ok(u64::from_le_bytes(b.try_into().expect("8 bytes")))
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum RawValue<'a> {
    Varint(u64),
    Fixed64(u64),
    Len(&'a [u8]),
    Fixed32(u32),
}

impl RawValue<'_> {
    pub fn wire_type(&self) -> u8 {
        match self {
            RawValue::Varint(_) => WIRE_VARINT,
            RawValue::Fixed64(_) => WIRE_FIXED64,
            RawValue::Len(_) => WIRE_LEN,
            RawValue::Fixed32(_) => WIRE_FIXED32,
        }
    }
}

pub struct FieldReader<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> FieldReader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }

    pub fn next_field(&mut self) -> Result<Option<(u32, RawValue<'a>)>, ProtoError> {
        if self.pos >= self.data.len() {
            return Ok(None);
        }
        let key = get_varint(self.data, &mut self.pos)?;
        let field = u32::try_from(key >> 3).map_err(|_| ProtoError::Truncated)?;
        if field == 0 {
            return Err(ProtoError::ZeroField);
        }
        let wire = (key & 7) as u8;
        let value = match wire {
            WIRE_VARINT => RawValue::Varint(get_varint(self.data, &mut self.pos)?),
            WIRE_FIXED64 => RawValue::Fixed64(read_fixed64(self.data, &mut self.pos)?),
            WIRE_LEN => {
                let len = get_varint(self.data, &mut self.pos)?;
                let len = usize::try_from(len).map_err(|_| ProtoError::Truncated)?;
                let end = self.pos.checked_add(len).ok_or(ProtoError::Truncated)?;
                let b = self.data.get(self.pos..end).ok_or(ProtoError::Truncated)?;
                self.pos = end;
                RawValue::Len(b)
            }
            WIRE_FIXED32 => RawValue::Fixed32(read_fixed32(self.data, &mut self.pos)?),
            other => return Err(ProtoError::BadWireType(other)),
        };
        Ok(Some((field, value)))
    }
}

pub trait FieldValue: Sized {
    const WIRE: u8;
    fn put(&self, out: &mut Vec<u8>);
    fn get(raw: RawValue<'_>) -> Result<Self, ProtoError>;
    fn get_packed(block: &[u8], out: &mut Vec<Self>) -> Result<(), ProtoError> {
        let mut pos = 0;
        while pos < block.len() {
            let raw = match Self::WIRE {
                WIRE_VARINT => RawValue::Varint(get_varint(block, &mut pos)?),
                WIRE_FIXED32 => RawValue::Fixed32(read_fixed32(block, &mut pos)?),
                WIRE_FIXED64 => RawValue::Fixed64(read_fixed64(block, &mut pos)?),
                other => return Err(ProtoError::BadWireType(other)),
            };
            out.push(Self::get(raw)?);
        }
        Ok(())
    }
}

fn wrong(raw: &RawValue<'_>, expected: u8) -> ProtoError {
    ProtoError::WrongWireType {
        field: 0,
        got: raw.wire_type(),
        expected,
    }
}

macro_rules! varint_value {
    ($t:ty, |$v:ident| $to:expr, |$w:ident| $from:expr) => {
        impl FieldValue for $t {
            const WIRE: u8 = WIRE_VARINT;
            fn put(&self, out: &mut Vec<u8>) {
                let $v = *self;
                put_varint(out, $to);
            }
            fn get(raw: RawValue<'_>) -> Result<Self, ProtoError> {
                match raw {
                    RawValue::Varint($w) => Ok($from),
                    other => Err(wrong(&other, WIRE_VARINT)),
                }
            }
        }
    };
}

varint_value!(u64, |v| v, |w| w);
varint_value!(u32, |v| u64::from(v), |w| w as u32);
varint_value!(i32, |v| i64::from(v) as u64, |w| w as i32);
varint_value!(i64, |v| v as u64, |w| w as i64);
varint_value!(bool, |v| u64::from(v), |w| w != 0);

impl FieldValue for f32 {
    const WIRE: u8 = WIRE_FIXED32;
    fn put(&self, out: &mut Vec<u8>) {
        out.extend_from_slice(&self.to_bits().to_le_bytes());
    }
    fn get(raw: RawValue<'_>) -> Result<Self, ProtoError> {
        match raw {
            RawValue::Fixed32(b) => Ok(f32::from_bits(b)),
            other => Err(wrong(&other, WIRE_FIXED32)),
        }
    }
}

impl FieldValue for f64 {
    const WIRE: u8 = WIRE_FIXED64;
    fn put(&self, out: &mut Vec<u8>) {
        out.extend_from_slice(&self.to_bits().to_le_bytes());
    }
    fn get(raw: RawValue<'_>) -> Result<Self, ProtoError> {
        match raw {
            RawValue::Fixed64(b) => Ok(f64::from_bits(b)),
            other => Err(wrong(&other, WIRE_FIXED64)),
        }
    }
}

impl FieldValue for Vec<u8> {
    const WIRE: u8 = WIRE_LEN;
    fn put(&self, out: &mut Vec<u8>) {
        put_varint(out, self.len() as u64);
        out.extend_from_slice(self);
    }
    fn get(raw: RawValue<'_>) -> Result<Self, ProtoError> {
        match raw {
            RawValue::Len(b) => Ok(b.to_vec()),
            other => Err(wrong(&other, WIRE_LEN)),
        }
    }
}

impl FieldValue for String {
    const WIRE: u8 = WIRE_LEN;
    fn put(&self, out: &mut Vec<u8>) {
        put_varint(out, self.len() as u64);
        out.extend_from_slice(self.as_bytes());
    }
    fn get(raw: RawValue<'_>) -> Result<Self, ProtoError> {
        match raw {
            RawValue::Len(b) => Ok(String::from_utf8_lossy(b).into_owned()),
            other => Err(wrong(&other, WIRE_LEN)),
        }
    }
}

pub trait ProtoMessage: Sized {
    const NAME: &'static str;
    fn encode_to(&self, out: &mut Vec<u8>);
    fn decode(data: &[u8]) -> Result<Self, ProtoError>;
    fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        self.encode_to(&mut out);
        out
    }
}

#[doc(hidden)]
pub mod field {
    use super::*;

    pub fn put_one<T: FieldValue>(out: &mut Vec<u8>, num: u32, v: &T) {
        put_key(out, num, T::WIRE);
        v.put(out);
    }

    pub fn put_opt<T: FieldValue>(out: &mut Vec<u8>, num: u32, v: &Option<T>) {
        if let Some(v) = v {
            put_one(out, num, v);
        }
    }

    pub fn put_rep<T: FieldValue>(out: &mut Vec<u8>, num: u32, v: &[T]) {
        for x in v {
            put_one(out, num, x);
        }
    }

    fn with_field_number(e: ProtoError, num: u32) -> ProtoError {
        match e {
            ProtoError::WrongWireType { got, expected, .. } => ProtoError::WrongWireType {
                field: num,
                got,
                expected,
            },
            other => other,
        }
    }

    pub fn get_one<T: FieldValue>(
        slot: &mut Option<T>,
        num: u32,
        raw: RawValue<'_>,
    ) -> Result<(), ProtoError> {
        *slot = Some(T::get(raw).map_err(|e| with_field_number(e, num))?);
        Ok(())
    }

    pub fn get_opt<T: FieldValue>(
        slot: &mut Option<T>,
        num: u32,
        raw: RawValue<'_>,
    ) -> Result<(), ProtoError> {
        if raw.wire_type() != T::WIRE {
            return Ok(());
        }
        get_one(slot, num, raw)
    }

    pub fn get_rep<T: FieldValue>(
        slot: &mut Vec<T>,
        num: u32,
        raw: RawValue<'_>,
    ) -> Result<(), ProtoError> {
        if let (RawValue::Len(block), true) = (raw, T::WIRE != WIRE_LEN) {
            return T::get_packed(block, slot).map_err(|e| with_field_number(e, num));
        }
        slot.push(T::get(raw).map_err(|e| with_field_number(e, num))?);
        Ok(())
    }

    pub fn required<T>(v: Option<T>, message: &'static str, num: u32) -> Result<T, ProtoError> {
        v.ok_or(ProtoError::MissingRequired {
            message,
            field: num,
        })
    }
}

macro_rules! proto_message {
    (
        pub struct $name:ident {
            $( $num:literal $card:ident $field:ident : $ty:ty ),* $(,)?
        }
    ) => {
        #[derive(Clone, Debug, Default, PartialEq)]
        pub struct $name {
            $( pub $field: proto_message!(@ty $card $ty), )*
        }

        impl $crate::proto::ProtoMessage for $name {
            const NAME: &'static str = stringify!($name);

            fn encode_to(&self, out: &mut Vec<u8>) {
                $( proto_message!(@put $card out, $num, &self.$field); )*
            }

            fn decode(data: &[u8]) -> Result<Self, $crate::proto::ProtoError> {
                $( let mut $field: proto_message!(@acc $card $ty) = Default::default(); )*
                let mut reader = $crate::proto::FieldReader::new(data);
                while let Some((num, raw)) = reader.next_field()? {
                    match num {
                        $( $num => proto_message!(@get $card &mut $field, $num, raw)?, )*
                        _ => {}
                    }
                }
                Ok(Self {
                    $( $field: proto_message!(@fin $card $field, $num), )*
                })
            }
        }

        impl $crate::proto::FieldValue for $name {
            const WIRE: u8 = $crate::proto::WIRE_LEN;
            fn put(&self, out: &mut Vec<u8>) {
                let body = $crate::proto::ProtoMessage::encode(self);
                $crate::proto::put_varint(out, body.len() as u64);
                out.extend_from_slice(&body);
            }
            fn get(raw: $crate::proto::RawValue<'_>) -> Result<Self, $crate::proto::ProtoError> {
                match raw {
                    $crate::proto::RawValue::Len(b) => {
                        <Self as $crate::proto::ProtoMessage>::decode(b)
                    }
                    other => Err($crate::proto::wrong(&other, $crate::proto::WIRE_LEN)),
                }
            }
        }
    };

    (@ty req $ty:ty) => { $ty };
    (@ty opt $ty:ty) => { Option<$ty> };
    (@ty rep $ty:ty) => { Vec<$ty> };

    (@acc req $ty:ty) => { Option<$ty> };
    (@acc opt $ty:ty) => { Option<$ty> };
    (@acc rep $ty:ty) => { Vec<$ty> };

    (@put req $out:ident, $num:literal, $v:expr) => {
        $crate::proto::field::put_one($out, $num, $v)
    };
    (@put opt $out:ident, $num:literal, $v:expr) => {
        $crate::proto::field::put_opt($out, $num, $v)
    };
    (@put rep $out:ident, $num:literal, $v:expr) => {
        $crate::proto::field::put_rep($out, $num, $v)
    };

    (@get req $slot:expr, $num:literal, $raw:ident) => {
        $crate::proto::field::get_one($slot, $num, $raw)
    };
    (@get opt $slot:expr, $num:literal, $raw:ident) => {
        $crate::proto::field::get_opt($slot, $num, $raw)
    };
    (@get rep $slot:expr, $num:literal, $raw:ident) => {
        $crate::proto::field::get_rep($slot, $num, $raw)
    };

    (@fin req $field:ident, $num:literal) => {
        $crate::proto::field::required($field, Self::NAME, $num)?
    };
    (@fin opt $field:ident, $num:literal) => { $field };
    (@fin rep $field:ident, $num:literal) => { $field };
}

pub(crate) use proto_message;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn varints() {
        for v in [0u64, 1, 127, 128, 300, u32::MAX as u64, u64::MAX] {
            let mut b = Vec::new();
            put_varint(&mut b, v);
            let mut p = 0;
            assert_eq!(get_varint(&b, &mut p).unwrap(), v);
            assert_eq!(p, b.len());
        }
        let mut b = Vec::new();
        put_varint(&mut b, 300);
        assert_eq!(b, [0xac, 0x02]);
        let mut b = Vec::new();
        (-1i32).put(&mut b);
        assert_eq!(b.len(), 10);
        assert_eq!(i32::get(RawValue::Varint(u64::MAX)).unwrap(), -1);
        assert_eq!(
            get_varint(&[0x80; 11], &mut 0),
            Err(ProtoError::VarintTooLong)
        );
        assert_eq!(get_varint(&[0x80], &mut 0), Err(ProtoError::Truncated));
    }

    #[test]
    fn reader_handles_all_wire_types() {
        let mut b = Vec::new();
        put_key(&mut b, 1, WIRE_VARINT);
        put_varint(&mut b, 5);
        put_key(&mut b, 2, WIRE_FIXED64);
        b.extend_from_slice(&1.5f64.to_bits().to_le_bytes());
        put_key(&mut b, 3, WIRE_LEN);
        b.extend_from_slice(&[2, 0xaa, 0xbb]);
        put_key(&mut b, 4, WIRE_FIXED32);
        b.extend_from_slice(&0.25f32.to_bits().to_le_bytes());
        let mut r = FieldReader::new(&b);
        assert_eq!(r.next_field().unwrap(), Some((1, RawValue::Varint(5))));
        assert_eq!(
            r.next_field().unwrap(),
            Some((2, RawValue::Fixed64(1.5f64.to_bits())))
        );
        assert_eq!(
            r.next_field().unwrap(),
            Some((3, RawValue::Len(&[0xaa, 0xbb])))
        );
        assert_eq!(
            r.next_field().unwrap(),
            Some((4, RawValue::Fixed32(0.25f32.to_bits())))
        );
        assert_eq!(r.next_field().unwrap(), None);
        assert!(FieldReader::new(&[0x0b]).next_field().is_err());
        assert!(FieldReader::new(&[0x1a, 0x05, 0x00]).next_field().is_err());
    }
}
