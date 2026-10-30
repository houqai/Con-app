use base64::Engine as _;

use crate::crypto::rp::RpCipher;
use crate::{Codec, ConsoleKind, ServerType, Target};

pub const MAX_JSON_LEN: usize = 1023;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum LaunchError {
    #[error("launch specification is {0} bytes, more than the limit of {max}", max = MAX_JSON_LEN)]
    TooLong(usize),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VideoPreset {
    pub width: u32,
    pub height: u32,
    pub bitrate_kbps: u32,
}

impl VideoPreset {
    pub const P360: Self = Self::new(640, 360, 2000);
    pub const P540: Self = Self::new(960, 540, 6000);
    pub const P720: Self = Self::new(1280, 720, 10000);
    pub const P1080: Self = Self::new(1920, 1080, 15000);

    const fn new(width: u32, height: u32, bitrate_kbps: u32) -> Self {
        Self {
            width,
            height,
            bitrate_kbps,
        }
    }

    pub fn for_height(height: u32) -> Self {
        match height {
            h if h >= 1080 => Self::P1080,
            h if h >= 720 => Self::P720,
            h if h >= 540 => Self::P540,
            _ => Self::P360,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StreamChoice {
    pub preset: VideoPreset,
    pub max_fps: u32,
    pub codec: Codec,
    pub auto_downgrade: bool,
}

impl StreamChoice {
    pub fn new(height: u32, fps: u32, codec: Codec) -> Self {
        Self {
            preset: VideoPreset::for_height(height),
            max_fps: if fps >= 60 { 60 } else { 30 },
            codec,
            auto_downgrade: true,
        }
    }

    pub fn video_disabled(codec: Codec) -> Self {
        Self {
            preset: VideoPreset::P360,
            max_fps: 0,
            codec,
            auto_downgrade: false,
        }
    }

    pub fn adjusted_for(self, server_type: ServerType) -> Self {
        let mut out = self;
        if server_type == ServerType::Ps4 && self.auto_downgrade && self.preset.height == 1080 {
            out.preset = VideoPreset::P720;
            out.max_fps = if self.max_fps == 60 { 60 } else { 30 };
        }
        if server_type.is_ps4() {
            out.codec = Codec::H264;
        }
        out
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct LaunchSpec {
    pub kind: ConsoleKind,
    pub width: u32,
    pub height: u32,
    pub max_fps: u32,
    pub bitrate_kbps: u32,
    pub mtu: u32,
    pub rtt_ms: u64,
    pub codec: Codec,
    pub handshake_key: [u8; 16],
}

impl std::fmt::Debug for LaunchSpec {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LaunchSpec")
            .field("kind", &self.kind)
            .field("width", &self.width)
            .field("height", &self.height)
            .field("max_fps", &self.max_fps)
            .field("bitrate_kbps", &self.bitrate_kbps)
            .field("mtu", &self.mtu)
            .field("rtt_ms", &self.rtt_ms)
            .field("codec", &self.codec)
            .finish_non_exhaustive()
    }
}

impl LaunchSpec {
    pub fn new(
        target: Target,
        choice: StreamChoice,
        mtu: u32,
        rtt_ms: u64,
        handshake_key: [u8; 16],
    ) -> Self {
        Self {
            kind: target.kind(),
            width: choice.preset.width,
            height: choice.preset.height,
            max_fps: choice.max_fps,
            bitrate_kbps: choice.preset.bitrate_kbps,
            mtu,
            rtt_ms,
            codec: choice.codec,
            handshake_key,
        }
    }

    pub fn to_json(&self) -> Result<String, LaunchError> {
        let ps5 = self.kind == ConsoleKind::Ps5;
        let handshake = base64::engine::general_purpose::STANDARD.encode(self.handshake_key);
        let mut s = String::with_capacity(1024);
        s.push_str("{\"sessionId\":\"sessionId4321\",");
        s.push_str(&format!(
            "\"streamResolutions\":[{{\"resolution\":{{\"width\":{},\"height\":{}}},\"maxFps\":{},\"score\":10}}],",
            self.width, self.height, self.max_fps
        ));
        s.push_str(&format!(
            "\"network\":{{\"bwKbpsSent\":{},\"bwLoss\":0.001000,\"mtu\":{},\"rtt\":{},\"ports\":[53,2053]}},",
            self.bitrate_kbps, self.mtu, self.rtt_ms
        ));
        s.push_str("\"slotId\":1,");
        s.push_str("\"appSpecification\":{\"minFps\":30,\"minBandwidth\":0,\"extTitleId\":\"ps3\",\"version\":1,\"timeLimit\":1,\"startTimeout\":100,\"afkTimeout\":100,\"afkTimeoutDisconnect\":100},");
        s.push_str(
            "\"konan\":{\"ps3AccessToken\":\"accessToken\",\"ps3RefreshToken\":\"refreshToken\"},",
        );
        s.push_str("\"requestGameSpecification\":{\"model\":\"bravia_tv\",\"platform\":\"android\",\"audioChannels\":\"5.1\",\"language\":\"sp\",\"acceptButton\":\"X\",\"connectedControllers\":[\"xinput\",\"ds3\",\"ds4\"],\"yuvCoefficient\":\"bt601\",\"videoEncoderProfile\":\"hw4.1\",\"audioEncoderProfile\":\"audio1\"");
        if ps5 {
            s.push_str(",\"adaptiveStreamMode\": \"resize\"");
        }
        s.push_str("},");
        s.push_str("\"userProfile\":{\"onlineId\":\"psnId\",\"npId\":\"npId\",\"region\":\"US\",\"languagesUsed\":[\"en\",\"jp\"]},");
        if ps5 {
            let (codec, range) = match self.codec {
                Codec::H264 => ("avc", "SDR"),
                Codec::H265 => ("hevc", "SDR"),
                Codec::H265Hdr => ("hevc", "HDR"),
            };
            s.push_str(&format!(
                "\"videoCodec\":\"{codec}\",\"dynamicRange\":\"{range}\","
            ));
        }
        s.push_str(&format!("\"handshakeKey\":\"{handshake}\"}}"));
        if s.len() > MAX_JSON_LEN {
            return Err(LaunchError::TooLong(s.len()));
        }
        Ok(s)
    }

    pub fn encode(&self, session_cipher: &RpCipher) -> Result<String, LaunchError> {
        Ok(session_cipher.encode_launch_spec(&self.to_json()?))
    }
}
