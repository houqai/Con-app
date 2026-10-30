pub mod crypt;
pub mod loss;
pub mod packet;
pub mod reorder;
pub mod sendbuf;
pub mod seq;
pub mod video;

mod conn;

pub use conn::{Link, MediaPacket, Transport, TransportHandler};
pub use loss::AudioCounting;
pub use reorder::DataMessage;
pub use sendbuf::RetransmitConfig;

use std::net::SocketAddr;
use std::time::Duration;

use crate::log::Logger;

pub const STREAM_PORT: u16 = 9296;
pub const NETWORK_TEST_PORT: u16 = 9297;
pub const CONSOLE_RECV_BUFFER: usize = 0x19000;
pub const CLOUD_RECV_BUFFER: usize = 0x40_0000;
pub const READ_BUFFER: usize = 1500;
pub const HELD_MEDIA_MAX: usize = 32;
pub const CONSOLE_LOSS_CEILING: f64 = 0.04;

#[derive(Debug)]
pub enum Endpoint {
    Address(SocketAddr),
    Socket(std::net::UdpSocket),
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CongestionConfig {
    pub interval: Duration,
    pub margin: u32,
    pub ceiling: f64,
    pub audio: AudioCounting,
}

impl CongestionConfig {
    pub fn console(ceiling: f64) -> Self {
        Self {
            interval: Duration::from_millis(200),
            margin: 1,
            ceiling,
            audio: AudioCounting::PerPacket,
        }
    }

    pub fn cloud(ceiling: f64, ps5: bool) -> Self {
        Self {
            interval: Duration::from_millis(200),
            margin: 3,
            ceiling,
            audio: if ps5 {
                AudioCounting::PerNewFrame
            } else {
                AudioCounting::PerPacket
            },
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HandshakeTiming {
    pub attempt_timeout: Duration,
    pub attempts: u32,
}

impl Default for HandshakeTiming {
    fn default() -> Self {
        Self {
            attempt_timeout: Duration::from_secs(5),
            attempts: 3,
        }
    }
}

#[derive(Debug)]
pub struct TransportConfig {
    pub endpoint: Endpoint,
    pub prefix: u8,
    pub media_version: u32,
    pub encrypted: bool,
    pub initial_tsn_from_init_ack: bool,
    pub reorder_video: bool,
    pub video_wait: Duration,
    pub recv_buffer: usize,
    pub dont_fragment: bool,
    pub congestion: Option<CongestionConfig>,
    pub handshake: HandshakeTiming,
    pub retransmit: RetransmitConfig,
    pub client_tag: Option<u32>,
    pub discard_video: bool,
    pub discard_audio: bool,
    pub initial_rtt_us: Option<u64>,
    pub log: Logger,
}

impl TransportConfig {
    pub fn console_stream(addr: SocketAddr, media_version: u32) -> Self {
        Self {
            endpoint: Endpoint::Address(addr),
            prefix: 0,
            media_version,
            encrypted: true,
            initial_tsn_from_init_ack: false,
            reorder_video: true,
            video_wait: video::CONSOLE_VIDEO_WAIT,
            recv_buffer: CONSOLE_RECV_BUFFER,
            dont_fragment: true,
            congestion: Some(CongestionConfig::console(CONSOLE_LOSS_CEILING)),
            handshake: HandshakeTiming::default(),
            retransmit: RetransmitConfig::default(),
            client_tag: None,
            discard_video: false,
            discard_audio: false,
            initial_rtt_us: None,
            log: Logger::default(),
        }
    }

    pub fn network_test(addr: SocketAddr) -> Self {
        Self {
            encrypted: false,
            reorder_video: false,
            congestion: None,
            ..Self::console_stream(addr, 7)
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum TransportError {
    #[error("stopped")]
    Stopped,
    #[error("socket: {0}")]
    Io(String),
    #[error("handshake failed: {0}")]
    Handshake(String),
    #[error("timed out: {0}")]
    Timeout(&'static str),
    #[error("transport closed")]
    Closed,
    #[error("not connected")]
    NotConnected,
    #[error("send buffer full")]
    SendBufferFull,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct TransportStats {
    pub rtt_latest_us: u64,
    pub rtt_samples: u64,
    pub rtt_median_us: u64,
    pub datagrams_sent: u64,
    pub datagrams_received: u64,
    pub retransmissions: u64,
    pub given_up: u64,
    pub tag_failures: u64,
    pub dropped: u64,
    pub held_media_dropped: u64,
    pub messages_delivered: u64,
    pub media_delivered: u64,
    pub congestion_reports: u64,
    pub last_report: (u16, u16),
    pub video: video::VideoReorderStats,
    pub local_key_position: u64,
    pub remote_key_position: u64,
}
