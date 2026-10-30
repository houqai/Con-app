use std::io;
use std::net::SocketAddr;
use std::time::{Duration, Instant};

use base64::Engine as _;

use crate::crypto::regist::{cipher as regist_cipher, pin_keys};
use crate::crypto::rp::RpCipher;
use crate::crypto::{hex_decode, random_bytes};
use crate::http::{get_field, parse_fields, parse_response, Strictness};
use crate::net::{TcpConn, UdpSock, POLL_STEP};
use crate::{ApplicationReason, ConsoleKind, StopToken, Target};

pub const REGIST_PORT: u16 = 9295;
pub const FILLER_LEN: usize = 0x1e0;
pub const CLIENT_TYPE_NEW: &str =
    "dabfa2ec873de5839bee8d3f4c0239c4282c07c25c6077a2931afcf0adc0d34f";
pub const LAN_HOST: &str = "10.0.2.15";
const MAX_RESPONSE: usize = 64 * 1024;
const SECOND_REQUEST_LINE: &str = " HTTP/1.1\r\n";

#[derive(Debug, thiserror::Error)]
pub enum RegistError {
    #[error("stopped")]
    Stopped,
    #[error("the PIN must be 8 decimal digits")]
    InvalidPin,
    #[error("this console needs the PSN account id")]
    AccountIdRequired,
    #[error(
        "the console did not answer the probe (it may be off, on another network, or not showing the Link Device screen)"
    )]
    NoProbeReply,
    #[error("connecting failed: {0}")]
    Connect(#[source] io::Error),
    #[error("network error: {0}")]
    Io(#[source] io::Error),
    #[error("the console refused the registration (status {status}, reason {reason:?})")]
    Rejected {
        status: u16,
        reason: Option<ApplicationReason>,
    },
    #[error("invalid response: {0}")]
    InvalidResponse(&'static str),
    #[error("response lacks a valid {0}")]
    MissingField(&'static str),
}

fn io_err(e: io::Error) -> RegistError {
    if e.kind() == io::ErrorKind::Interrupted {
        RegistError::Stopped
    } else {
        RegistError::Io(e)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Identity {
    AccountId([u8; 8]),
    OnlineId(String),
}

pub fn account_id_le(account_id: u64) -> [u8; 8] {
    account_id.to_le_bytes()
}

pub fn account_id_be(account_id: u64) -> [u8; 8] {
    account_id.to_be_bytes()
}

pub fn parse_pin(text: &str) -> Option<u32> {
    let t = text.trim();
    if t.len() != 8 || !t.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    t.parse().ok()
}

#[derive(Clone)]
pub struct RegistRequest {
    pub target: Target,
    pub identity: Identity,
    pub pin: u32,
    pub seed: [u8; 16],
    pub filler: [u8; FILLER_LEN],
    pub host: String,
}

impl std::fmt::Debug for RegistRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RegistRequest")
            .field("target", &self.target)
            .finish_non_exhaustive()
    }
}

#[derive(Clone, Debug)]
pub struct BuiltRequest {
    pub header: Vec<u8>,
    pub body: Vec<u8>,
    pub cipher: RpCipher,
}

impl RegistRequest {
    pub fn new(target: Target, identity: Identity, pin: u32) -> Self {
        Self {
            target,
            identity,
            pin,
            seed: random_bytes(),
            filler: [0x41; FILLER_LEN],
            host: LAN_HOST.to_string(),
        }
    }

    pub fn inner_header(&self) -> Result<String, RegistError> {
        let b64 = |id: &[u8; 8]| base64::engine::general_purpose::STANDARD.encode(id);
        match (&self.identity, self.target.is_old_generation()) {
            (Identity::AccountId(id), false) => Ok(format!(
                "Client-Type: {CLIENT_TYPE_NEW}\r\nNp-AccountId: {}\r\n",
                b64(id)
            )),
            (Identity::AccountId(id), true) => Ok(format!(
                "Client-Type: Windows\r\nNp-AccountId: {}\r\n",
                b64(id)
            )),
            (Identity::OnlineId(name), true) => {
                Ok(format!("Client-Type: Windows\r\nNp-Online-Id: {name}\r\n"))
            }
            (Identity::OnlineId(_), false) => Err(RegistError::AccountIdRequired),
        }
    }

    pub fn build(&self) -> Result<BuiltRequest, RegistError> {
        if self.pin > 99_999_999 {
            return Err(RegistError::InvalidPin);
        }
        let mut body = self.filler.to_vec();
        let c0 = body[0x18d] & 0x1f;
        let c1 = body[0] >> 3;
        let keys = pin_keys(self.target, self.pin, &self.seed, c0, c1);
        let masked = keys.masked_seed;
        if self.target.is_old_generation() {
            body[0x11c..0x12c].copy_from_slice(&masked);
        } else {
            body[0x0c7..0x0cf].copy_from_slice(&masked[8..16]);
            body[0x191..0x199].copy_from_slice(&masked[0..8]);
        }
        let cipher = regist_cipher(self.target, &keys, &self.seed);
        let mut inner = self.inner_header()?.into_bytes();
        cipher.encrypt(0, &mut inner);
        body.extend_from_slice(&inner);

        let mut header = format!(
            "POST {} HTTP/1.1\r\n{SECOND_REQUEST_LINE}HOST: {}\r\nUser-Agent: remoteplay Windows\r\nConnection: close\r\nContent-Length: {}\r\n",
            self.target.registration_path(),
            self.host,
            body.len()
        );
        if self.target != Target::Ps4V8 {
            header.push_str(&format!("RP-Version: {}\r\n", self.target.version_str()));
        }
        header.push_str("\r\n");
        Ok(BuiltRequest {
            header: header.into_bytes(),
            body,
            cipher,
        })
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct Registration {
    pub target: Target,
    pub regist_key: [u8; 16],
    pub rp_key: [u8; 16],
    pub mac: [u8; 6],
    pub nickname: Option<String>,
    pub key_type: Option<u64>,
    pub ap_ssid: Option<String>,
    pub ap_bssid: Option<String>,
    pub ap_key: Option<String>,
    pub ap_name: Option<String>,
    pub support_cmd: Option<u64>,
}

impl std::fmt::Debug for Registration {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Registration")
            .field("target", &self.target)
            .field("mac", &self.mac)
            .field("nickname", &self.nickname)
            .finish_non_exhaustive()
    }
}

fn parse_integer(text: &str) -> Option<u64> {
    let t = text.trim();
    match t.strip_prefix("0x").or_else(|| t.strip_prefix("0X")) {
        Some(h) => u64::from_str_radix(h, 16).ok(),
        None => t.parse().ok(),
    }
}

fn limited_text(fields: &[(String, String)], name: &str, limit: usize) -> Option<String> {
    get_field(fields, name)
        .filter(|v| v.len() < limit)
        .map(str::to_owned)
}

pub fn parse_response_body(plaintext: &[u8], target: Target) -> Result<Registration, RegistError> {
    let fields = parse_fields(plaintext, Strictness::Tolerant)
        .ok_or(RegistError::InvalidResponse("body"))?;
    let prefix = match target.kind() {
        ConsoleKind::Ps4 => "PS4",
        ConsoleKind::Ps5 => "PS5",
    };
    let regist_key = get_field(&fields, &format!("{prefix}-RegistKey"))
        .filter(|v| v.len() <= 32)
        .and_then(hex_decode)
        .map(|b| {
            let mut k = [0u8; 16];
            k[..b.len()].copy_from_slice(&b);
            k
        })
        .ok_or(RegistError::MissingField("registration key"))?;
    let rp_key: [u8; 16] = get_field(&fields, "RP-Key")
        .filter(|v| v.len() == 32)
        .and_then(hex_decode)
        .and_then(|b| b.try_into().ok())
        .ok_or(RegistError::MissingField("RP key"))?;
    let mac: [u8; 6] = get_field(&fields, &format!("{prefix}-Mac"))
        .filter(|v| v.len() == 12)
        .and_then(hex_decode)
        .and_then(|b| b.try_into().ok())
        .ok_or(RegistError::MissingField("MAC address"))?;
    Ok(Registration {
        target,
        regist_key,
        rp_key,
        mac,
        nickname: limited_text(&fields, &format!("{prefix}-Nickname"), 32),
        key_type: get_field(&fields, "RP-KeyType").and_then(parse_integer),
        ap_ssid: limited_text(&fields, "AP-Ssid", 48),
        ap_bssid: limited_text(&fields, "AP-Bssid", 32),
        ap_key: limited_text(&fields, "AP-Key", 80),
        ap_name: limited_text(&fields, "AP-Name", 32),
        support_cmd: get_field(&fields, "RP-SupportCmd").and_then(parse_integer),
    })
}

pub fn parse_response_header(header: &[u8]) -> Result<usize, RegistError> {
    let h = parse_response(header, Strictness::Tolerant)
        .ok_or(RegistError::InvalidResponse("status line"))?;
    if h.status != 200 {
        return Err(RegistError::Rejected {
            status: h.status,
            reason: h
                .get("RP-Application-Reason")
                .and_then(ApplicationReason::parse),
        });
    }
    let len: usize = h
        .get_ignore_case("Content-Length")
        .and_then(|v| v.trim().parse().ok())
        .ok_or(RegistError::InvalidResponse("Content-Length"))?;
    if len == 0 || len > MAX_RESPONSE {
        return Err(RegistError::InvalidResponse("Content-Length"));
    }
    Ok(len)
}

#[derive(Clone, Copy, Debug)]
pub struct RegistTimeouts {
    pub probe: Duration,
    pub pause: Duration,
    pub io: Duration,
}

impl Default for RegistTimeouts {
    fn default() -> Self {
        Self {
            probe: Duration::from_secs(3),
            pause: Duration::from_millis(100),
            io: Duration::from_secs(3),
        }
    }
}

fn probe_message(kind: ConsoleKind) -> &'static [u8] {
    match kind {
        ConsoleKind::Ps4 => b"SRC2\0",
        ConsoleKind::Ps5 => b"SRC3\0",
    }
}

fn probe_reply_prefix(kind: ConsoleKind) -> &'static [u8] {
    match kind {
        ConsoleKind::Ps4 => b"RES2",
        ConsoleKind::Ps5 => b"RES3",
    }
}

pub fn register(
    console: SocketAddr,
    request: &RegistRequest,
    timeouts: RegistTimeouts,
    stop: &StopToken,
) -> Result<Registration, RegistError> {
    let built = request.build()?;
    let kind = request.target.kind();

    let sock = UdpSock::bind_for_peer(&console).map_err(RegistError::Io)?;
    sock.connect(console).map_err(RegistError::Io)?;
    sock.send(probe_message(kind)).map_err(RegistError::Io)?;
    let deadline = Instant::now() + timeouts.probe;
    let mut buf = [0u8; 255];
    let tcp_addr = loop {
        if stop.is_stopped() {
            return Err(RegistError::Stopped);
        }
        let now = Instant::now();
        if now >= deadline {
            return Err(RegistError::NoProbeReply);
        }
        let wait = (deadline - now).min(POLL_STEP);
        if let Some((n, from)) = sock.recv_from(&mut buf, wait).map_err(RegistError::Io)? {
            if n >= 4 && &buf[..4] == probe_reply_prefix(kind) {
                break from;
            }
        }
    };
    drop(sock);

    if !stop.sleep(timeouts.pause) {
        return Err(RegistError::Stopped);
    }

    let mut conn = TcpConn::connect(tcp_addr, timeouts.io).map_err(RegistError::Connect)?;
    if stop.is_stopped() {
        return Err(RegistError::Stopped);
    }
    conn.send_all(&built.header, timeouts.io).map_err(io_err)?;
    conn.send_all(&built.body, timeouts.io).map_err(io_err)?;
    let (header, mut body) = conn
        .read_header(timeouts.io, MAX_RESPONSE, stop)
        .map_err(io_err)?;
    let len = parse_response_header(&header)?;
    conn.read_to_len(&mut body, len, timeouts.io, stop)
        .map_err(io_err)?;
    body.truncate(len);
    conn.shutdown();

    built.cipher.decrypt(0, &mut body);
    parse_response_body(&body, request.target)
}
