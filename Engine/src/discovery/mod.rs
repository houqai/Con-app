mod service;

pub use service::{DiscoveryConfig, DiscoveryService};

use std::net::{IpAddr, SocketAddr};

use crate::http::{get_field, parse_response, Strictness};
use crate::net::UdpSock;
use crate::types::regist_key_text;
use crate::{ConsoleKind, Target};

pub const PS4_PORT: u16 = 987;
pub const PS5_PORT: u16 = 9302;
pub const PS4_PROTOCOL_VERSION: &str = "00020020";
pub const PS5_PROTOCOL_VERSION: &str = "00030010";
pub const CLIENT_PORTS: std::ops::RangeInclusive<u16> = 9303..=9319;
pub const MAX_RESPONSE_LEN: usize = 511;

pub fn protocol_version(kind: ConsoleKind) -> &'static str {
    match kind {
        ConsoleKind::Ps4 => PS4_PROTOCOL_VERSION,
        ConsoleKind::Ps5 => PS5_PROTOCOL_VERSION,
    }
}

pub fn console_port(kind: ConsoleKind) -> u16 {
    match kind {
        ConsoleKind::Ps4 => PS4_PORT,
        ConsoleKind::Ps5 => PS5_PORT,
    }
}

pub fn search_message(kind: ConsoleKind) -> Vec<u8> {
    let mut m = format!(
        "SRCH * HTTP/1.1\ndevice-discovery-protocol-version:{}\n",
        protocol_version(kind)
    )
    .into_bytes();
    m.push(0);
    m
}

#[derive(Debug, thiserror::Error)]
pub enum WakeError {
    #[error("the registration key cannot be turned into a wake credential")]
    BadCredential,
    #[error("sending the wake-up failed: {0}")]
    Io(#[from] std::io::Error),
}

pub fn wake_credential(regist_key: &[u8; 16]) -> Option<u64> {
    let text = regist_key_text(regist_key);
    if text.is_empty() || text.len() > 8 {
        return None;
    }
    let s = std::str::from_utf8(text).ok()?;
    if !s.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    u64::from_str_radix(s, 16).ok()
}

pub fn wakeup_message(kind: ConsoleKind, credential: u64) -> Vec<u8> {
    let mut m = format!(
        "WAKEUP * HTTP/1.1\nclient-type:vr\nauth-type:R\nmodel:w\napp-type:r\nuser-credential:{}\ndevice-discovery-protocol-version:{}\n",
        credential,
        protocol_version(kind)
    )
    .into_bytes();
    m.push(0);
    m
}

pub(crate) fn wake_datagram(
    kind: ConsoleKind,
    regist_key: &[u8; 16],
) -> Result<Vec<u8>, WakeError> {
    let credential = wake_credential(regist_key).ok_or(WakeError::BadCredential)?;
    Ok(wakeup_message(kind, credential))
}

pub fn wake(
    console: SocketAddr,
    kind: ConsoleKind,
    regist_key: &[u8; 16],
) -> Result<(), WakeError> {
    let datagram = wake_datagram(kind, regist_key)?;
    let sock = UdpSock::bind_for_peer(&console)?;
    sock.send_to(&datagram, console)?;
    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ConsoleState {
    Ready,
    Standby,
    Unknown,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DiscoveredHost {
    pub address: IpAddr,
    pub status: u16,
    pub state: ConsoleState,
    pub host_id: String,
    pub host_name: Option<String>,
    pub host_type: Option<String>,
    pub system_version: Option<String>,
    pub protocol_version: Option<String>,
    pub request_port: Option<u16>,
    pub running_app_title_id: Option<String>,
    pub running_app_name: Option<String>,
}

impl DiscoveredHost {
    pub fn kind(&self) -> ConsoleKind {
        if self.protocol_version.as_deref() == Some(PS5_PROTOCOL_VERSION) {
            ConsoleKind::Ps5
        } else {
            ConsoleKind::Ps4
        }
    }

    pub fn generation(&self) -> Option<Target> {
        generation(self.kind(), self.system_version.as_deref().unwrap_or(""))
    }

    pub fn target(&self) -> Target {
        self.generation()
            .unwrap_or_else(|| Target::initial(self.kind()))
    }
}

fn leading_decimal(text: &str) -> u64 {
    text.bytes()
        .take_while(u8::is_ascii_digit)
        .fold(0u64, |acc, d| {
            acc.saturating_mul(10).saturating_add((d - b'0') as u64)
        })
}

pub fn generation(kind: ConsoleKind, system_version: &str) -> Option<Target> {
    let n = leading_decimal(system_version);
    let ps5 = kind == ConsoleKind::Ps5;
    if ps5 && n >= 8_050_001 {
        Some(Target::Ps5V1)
    } else if ps5 && n >= 8_050_000 {
        None
    } else if n >= 8_000_000 {
        Some(Target::Ps4V10)
    } else if n >= 7_000_000 {
        Some(Target::Ps4V9)
    } else if n > 0 {
        Some(Target::Ps4V8)
    } else {
        None
    }
}

fn parse_port(text: &str) -> Option<u16> {
    let t = text.trim();
    let v = if let Some(h) = t.strip_prefix("0x").or_else(|| t.strip_prefix("0X")) {
        u32::from_str_radix(h, 16).ok()?
    } else if t.len() > 1 && t.starts_with('0') {
        u32::from_str_radix(&t[1..], 8).ok()?
    } else {
        t.parse().ok()?
    };
    u16::try_from(v).ok()
}

pub fn parse_search_response(datagram: &[u8], source: IpAddr) -> Option<DiscoveredHost> {
    let data = &datagram[..datagram.len().min(MAX_RESPONSE_LEN)];
    let data = match data.iter().position(|&b| b == 0) {
        Some(z) => &data[..z],
        None => data,
    };
    let header = parse_response(data, Strictness::Tolerant)?;
    let f = &header.fields;
    let get = |n: &str| get_field(f, n).map(str::to_owned);
    let host_id = get("host-id")?;
    let state = match header.status {
        200 => ConsoleState::Ready,
        620 => ConsoleState::Standby,
        _ => ConsoleState::Unknown,
    };
    Some(DiscoveredHost {
        address: source,
        status: header.status,
        state,
        host_id,
        host_name: get("host-name"),
        host_type: get("host-type"),
        system_version: get("system-version"),
        protocol_version: get("device-discovery-protocol-version"),
        request_port: get_field(f, "host-request-port").and_then(parse_port),
        running_app_title_id: get("running-app-titleid"),
        running_app_name: get("running-app-name"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn port_bases() {
        assert_eq!(parse_port("997"), Some(997));
        assert_eq!(parse_port("0x3e5"), Some(997));
        assert_eq!(parse_port("01745"), Some(997));
        assert_eq!(parse_port("0"), Some(0));
        assert_eq!(parse_port("70000"), None);
    }
}
