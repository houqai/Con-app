use std::fmt;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ConsoleKind {
    Ps4,
    Ps5,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Target {
    Ps4V8,
    Ps4V9,
    Ps4V10,
    Ps5V1,
}

const HMAC_KEY_PS5: [u8; 16] = [
    0x46, 0x46, 0x87, 0xb3, 0x49, 0xca, 0x8c, 0xe8, 0x59, 0xc5, 0x27, 0x0f, 0x5d, 0x7a, 0x69, 0xd6,
];
const HMAC_KEY_PS4_V8: [u8; 16] = [
    0xac, 0x07, 0x88, 0x83, 0xc8, 0x3a, 0x1f, 0xe8, 0x11, 0x46, 0x3a, 0xf3, 0x9e, 0xe3, 0xe3, 0x77,
];
const HMAC_KEY_PS4_V10: [u8; 16] = [
    0x20, 0xd6, 0x6f, 0x59, 0x04, 0xea, 0x7c, 0x14, 0xe5, 0x57, 0xff, 0xc5, 0x2e, 0x48, 0x8a, 0xc8,
];

impl Target {
    pub fn initial(kind: ConsoleKind) -> Target {
        match kind {
            ConsoleKind::Ps4 => Target::Ps4V10,
            ConsoleKind::Ps5 => Target::Ps5V1,
        }
    }

    pub fn kind(self) -> ConsoleKind {
        match self {
            Target::Ps5V1 => ConsoleKind::Ps5,
            _ => ConsoleKind::Ps4,
        }
    }

    pub fn version_str(self) -> &'static str {
        match self {
            Target::Ps4V8 => "8.0",
            Target::Ps4V9 => "9.0",
            Target::Ps4V10 => "10.0",
            Target::Ps5V1 => "1.0",
        }
    }

    pub fn is_old_generation(self) -> bool {
        matches!(self, Target::Ps4V8 | Target::Ps4V9)
    }

    pub fn session_path(self) -> &'static str {
        match self {
            Target::Ps4V8 | Target::Ps4V9 => "/sce/rp/session",
            Target::Ps4V10 => "/sie/ps4/rp/sess/init",
            Target::Ps5V1 => "/sie/ps5/rp/sess/init",
        }
    }

    pub fn control_path(self) -> &'static str {
        match self {
            Target::Ps4V8 | Target::Ps4V9 => "/sce/rp/session/ctrl",
            Target::Ps4V10 => "/sie/ps4/rp/sess/ctrl",
            Target::Ps5V1 => "/sie/ps5/rp/sess/ctrl",
        }
    }

    pub fn registration_path(self) -> &'static str {
        match self {
            Target::Ps4V8 | Target::Ps4V9 => "/sce/rp/regist",
            Target::Ps4V10 => "/sie/ps4/rp/sess/rgst",
            Target::Ps5V1 => "/sie/ps5/rp/sess/rgst",
        }
    }

    pub fn iv_hmac_key(self) -> [u8; 16] {
        match self {
            Target::Ps5V1 => HMAC_KEY_PS5,
            Target::Ps4V8 | Target::Ps4V9 => HMAC_KEY_PS4_V8,
            Target::Ps4V10 => HMAC_KEY_PS4_V10,
        }
    }

    pub fn sends_start_bitrate(self) -> bool {
        matches!(self, Target::Ps4V10 | Target::Ps5V1)
    }

    pub fn sends_streaming_type(self) -> bool {
        matches!(self, Target::Ps5V1)
    }

    pub fn transport_version(self) -> u32 {
        match self.kind() {
            ConsoleKind::Ps4 => crate::stream::PS4_TRANSPORT_VERSION,
            ConsoleKind::Ps5 => crate::stream::PS5_TRANSPORT_VERSION,
        }
    }
}

impl fmt::Display for Target {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let family = match self.kind() {
            ConsoleKind::Ps4 => "PS4",
            ConsoleKind::Ps5 => "PS5",
        };
        write!(f, "{}/{}", family, self.version_str())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Default)]
pub enum Codec {
    #[default]
    H264,
    H265,
    H265Hdr,
}

impl Codec {
    pub fn streaming_type(self) -> u32 {
        match self {
            Codec::H264 => 1,
            Codec::H265 => 2,
            Codec::H265Hdr => 3,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ApplicationReason {
    InvalidPsnId,
    RegistrationFailed,
    InUse,
    VersionMismatch,
    Crashed,
    Unknown,
    Other(u32),
}

impl ApplicationReason {
    pub fn from_code(code: u32) -> Self {
        match code {
            0x8010_8b02 => Self::InvalidPsnId,
            0x8010_8b09 => Self::RegistrationFailed,
            0x8010_8b10 => Self::InUse,
            0x8010_8b11 => Self::VersionMismatch,
            0x8010_8b15 => Self::Crashed,
            0x8010_8bff => Self::Unknown,
            other => Self::Other(other),
        }
    }

    pub fn code(self) -> u32 {
        match self {
            Self::InvalidPsnId => 0x8010_8b02,
            Self::RegistrationFailed => 0x8010_8b09,
            Self::InUse => 0x8010_8b10,
            Self::VersionMismatch => 0x8010_8b11,
            Self::Crashed => 0x8010_8b15,
            Self::Unknown => 0x8010_8bff,
            Self::Other(c) => c,
        }
    }

    pub fn parse(text: &str) -> Option<Self> {
        let t = text.trim();
        let t = t
            .strip_prefix("0x")
            .or_else(|| t.strip_prefix("0X"))
            .unwrap_or(t);
        u32::from_str_radix(t, 16).ok().map(Self::from_code)
    }
}

impl fmt::Display for ApplicationReason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:08x}", self.code())
    }
}

pub fn regist_key_text(regist_key: &[u8; 16]) -> &[u8] {
    let end = regist_key.iter().position(|&b| b == 0).unwrap_or(16);
    &regist_key[..end]
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ServerType {
    Ps4,
    Ps4Pro,
    Ps5,
    Other(u8),
}

impl ServerType {
    pub fn from_byte(b: u8) -> Self {
        match b {
            0 => Self::Ps4,
            1 => Self::Ps4Pro,
            2 => Self::Ps5,
            other => Self::Other(other),
        }
    }

    pub fn is_ps4(self) -> bool {
        matches!(self, Self::Ps4 | Self::Ps4Pro)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Stage {
    SessionRequest,
    Control,
    NetworkTest,
    Transport,
    KeyExchange,
    StreamInfo,
    Streaming,
}
