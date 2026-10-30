use std::io;
use std::net::SocketAddr;
use std::time::Duration;

use base64::Engine as _;

use crate::crypto::hex_encode;
use crate::http::{parse_response, Strictness};
use crate::net::{resolve, TcpConn};
use crate::types::regist_key_text;
use crate::{ApplicationReason, ConsoleKind, StopToken, Target};

pub const SESSION_PORT: u16 = 9295;
pub const MAX_ATTEMPTS: usize = 3;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum SessionRequestError {
    #[error("stopped")]
    Stopped,
    #[error("session request: connection refused")]
    ConnectionRefused,
    #[error("session request: Remote Play already in use")]
    InUse,
    #[error("session request: Remote Play crashed")]
    Crashed,
    #[error("session request: version mismatch")]
    VersionMismatch,
    #[error("session request: unknown error ({0})")]
    Unknown(String),
}

#[derive(Clone, Copy, Debug)]
pub struct RequestTimeouts {
    pub connect: Duration,
    pub send: Duration,
    pub response: Duration,
}

impl Default for RequestTimeouts {
    fn default() -> Self {
        Self {
            connect: Duration::from_secs(5),
            send: Duration::from_secs(5),
            response: Duration::from_secs(5),
        }
    }
}

pub fn build_request(target: Target, console: SocketAddr, regist_key: &[u8; 16]) -> String {
    format!(
        "GET {} HTTP/1.1\r\nHost: {}:{}\r\nUser-Agent: remoteplay Windows\r\nConnection: close\r\nContent-Length: 0\r\nRP-Registkey: {}\r\nRp-Version: {}\r\n\r\n",
        target.session_path(),
        console.ip(),
        console.port(),
        hex_encode(regist_key_text(regist_key)),
        target.version_str()
    )
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionResponse {
    pub status: u16,
    pub nonce: Option<[u8; 16]>,
    pub console_version: Option<String>,
    pub reason: Option<ApplicationReason>,
}

pub fn parse_session_response(header: &[u8]) -> Option<SessionResponse> {
    let h = parse_response(header, Strictness::Strict)?;
    let nonce = h
        .get("RP-Nonce")
        .and_then(|v| {
            base64::engine::general_purpose::STANDARD
                .decode(v.trim())
                .ok()
        })
        .and_then(|b| <[u8; 16]>::try_from(b).ok());
    Some(SessionResponse {
        status: h.status,
        nonce,
        console_version: h.get_ignore_case("RP-Version").map(str::to_owned),
        reason: h
            .get("RP-Application-Reason")
            .and_then(ApplicationReason::parse),
    })
}

pub fn target_for_console_version(kind: ConsoleKind, version: &str) -> Option<Target> {
    match (kind, version) {
        (ConsoleKind::Ps5, "1.0") => Some(Target::Ps5V1),
        (ConsoleKind::Ps4, "8.0") => Some(Target::Ps4V8),
        (ConsoleKind::Ps4, "9.0") => Some(Target::Ps4V9),
        (ConsoleKind::Ps4, "10.0") => Some(Target::Ps4V10),
        (_, "5.0") => Some(Target::Ps4V9),
        _ => None,
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    Granted([u8; 16]),
    Retry(Target),
    Failed(SessionRequestError),
}

pub fn evaluate(
    response: &SessionResponse,
    sent: Target,
    kind: ConsoleKind,
    may_negotiate: bool,
) -> Outcome {
    if response.status == 200 {
        return match response.nonce {
            Some(n) => Outcome::Granted(n),
            None => Outcome::Failed(SessionRequestError::Unknown(
                "200 without a valid nonce".into(),
            )),
        };
    }
    let reason = response.reason;
    let negotiable = matches!(
        reason,
        Some(ApplicationReason::VersionMismatch) | Some(ApplicationReason::Unknown)
    );
    if negotiable && may_negotiate {
        if let Some(v) = response.console_version.as_deref() {
            if v != sent.version_str() {
                return match target_for_console_version(kind, v) {
                    Some(t) => Outcome::Retry(t),
                    None => Outcome::Failed(SessionRequestError::VersionMismatch),
                };
            }
        }
    }
    Outcome::Failed(match reason {
        Some(ApplicationReason::VersionMismatch) => SessionRequestError::VersionMismatch,
        Some(ApplicationReason::InUse) => SessionRequestError::InUse,
        Some(ApplicationReason::Crashed) => SessionRequestError::Crashed,
        Some(r) => SessionRequestError::Unknown(format!("reason {r}")),
        None => SessionRequestError::Unknown(format!("status {}", response.status)),
    })
}

#[derive(Clone, PartialEq, Eq)]
pub struct SessionGrant {
    pub target: Target,
    pub nonce: [u8; 16],
    pub console_addr: SocketAddr,
}

impl std::fmt::Debug for SessionGrant {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SessionGrant")
            .field("target", &self.target)
            .field("console_addr", &self.console_addr)
            .finish_non_exhaustive()
    }
}

fn stopped_or_unknown(what: &str, e: io::Error) -> SessionRequestError {
    if e.kind() == io::ErrorKind::Interrupted {
        SessionRequestError::Stopped
    } else {
        SessionRequestError::Unknown(format!("{what}: {e}"))
    }
}

fn connect_any(
    addrs: &[SocketAddr],
    timeout: Duration,
    stop: &StopToken,
) -> Result<(TcpConn, SocketAddr), SessionRequestError> {
    let mut last_refused = false;
    for &a in addrs {
        if stop.is_stopped() {
            return Err(SessionRequestError::Stopped);
        }
        match TcpConn::connect(a, timeout) {
            Ok(c) => return Ok((c, a)),
            Err(e) => last_refused = e.kind() == io::ErrorKind::ConnectionRefused,
        }
    }
    Err(if last_refused {
        SessionRequestError::ConnectionRefused
    } else {
        SessionRequestError::Unknown("no address connected".into())
    })
}

pub fn request_session(
    host: &str,
    port: u16,
    kind: ConsoleKind,
    regist_key: &[u8; 16],
    timeouts: RequestTimeouts,
    stop: &StopToken,
) -> Result<SessionGrant, SessionRequestError> {
    let addrs =
        resolve(host, port).map_err(|e| SessionRequestError::Unknown(format!("resolving: {e}")))?;
    let mut target = Target::initial(kind);
    let mut chosen: Option<SocketAddr> = None;
    for attempt in 1..=MAX_ATTEMPTS {
        let candidates: &[SocketAddr] = match &chosen {
            Some(a) => std::slice::from_ref(a),
            None => &addrs,
        };
        let (mut conn, addr) = connect_any(candidates, timeouts.connect, stop)?;
        chosen = Some(addr);
        let request = build_request(target, addr, regist_key);
        conn.send_all(request.as_bytes(), timeouts.send)
            .map_err(|e| stopped_or_unknown("sending", e))?;
        let (header, _) = conn
            .read_header(timeouts.response, 4096, stop)
            .map_err(|e| stopped_or_unknown("receiving", e))?;
        conn.shutdown();
        let response = parse_session_response(&header)
            .ok_or_else(|| SessionRequestError::Unknown("unparsable response".into()))?;
        match evaluate(&response, target, kind, attempt < MAX_ATTEMPTS) {
            Outcome::Granted(nonce) => {
                return Ok(SessionGrant {
                    target,
                    nonce,
                    console_addr: addr,
                })
            }
            Outcome::Retry(t) => target = t,
            Outcome::Failed(e) => return Err(e),
        }
    }
    Err(SessionRequestError::VersionMismatch)
}
