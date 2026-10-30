use std::io;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use base64::Engine as _;

use super::messages::{
    decode_frame_header, encode_frame_header, fallback_session_id, feature_burst,
    keyboard_close_payload, keyboard_set_text_payload, mic_mute_payload, msg_type,
    parse_keyboard_opened, parse_keyboard_text_changed, parse_session_id, ScreenGuard,
    FRAME_HEADER_LEN, GO_HOME_PAYLOAD, MIC_CONNECT_PAYLOAD,
};
use crate::crypto::rp::RpCipher;
use crate::http::{parse_response, Strictness};
use crate::net::TcpConn;
use crate::{Codec, ServerType, StopToken, Target};

pub const MAX_PAYLOAD: usize = 64 * 1024;

const OS_TYPE: &[u8; 10] = b"Win10.0.0\0";

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ControlError {
    #[error("stopped")]
    Stopped,
    #[error("control: connect failed ({0})")]
    ConnectFailed(String),
    #[error("control: unknown error ({0})")]
    Failed(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ControlEvent {
    PinRequested { previous_wrong: bool },
    KeyboardOpened(String),
    KeyboardTextChanged(String),
    KeyboardClosedRemotely,
    CannotDisplay(bool),
}

pub type EventSink = Arc<dyn Fn(ControlEvent) + Send + Sync>;

#[derive(Clone, Copy, Debug)]
pub struct ControlTimeouts {
    pub connect: Duration,
    pub response: Duration,
    pub send: Duration,
    pub session_id: Duration,
}

impl Default for ControlTimeouts {
    fn default() -> Self {
        Self {
            connect: Duration::from_secs(5),
            response: Duration::from_secs(5),
            send: Duration::from_secs(5),
            session_id: Duration::from_secs(10),
        }
    }
}

#[derive(Clone)]
pub struct ControlConfig {
    pub console_addr: SocketAddr,
    pub target: Target,
    pub regist_key: [u8; 16],
    pub cipher: RpCipher,
    pub codec: Codec,
    pub dualsense: bool,
    pub keyboard: bool,
    pub device_id: [u8; 32],
    pub timeouts: ControlTimeouts,
}

impl std::fmt::Debug for ControlConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ControlConfig")
            .field("console_addr", &self.console_addr)
            .field("target", &self.target)
            .field("codec", &self.codec)
            .finish_non_exhaustive()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EncryptedHeaders {
    pub auth: String,
    pub did: String,
    pub os_type: String,
    pub start_bitrate: Option<String>,
    pub streaming_type: Option<String>,
    pub next_counter: u64,
}

pub fn encrypt_headers(
    cipher: &RpCipher,
    target: Target,
    regist_key: &[u8; 16],
    device_id: &[u8; 32],
    codec: Codec,
) -> EncryptedHeaders {
    let b64 = |b: Vec<u8>| base64::engine::general_purpose::STANDARD.encode(b);
    let mut c = 0u64;
    let mut next = |data: &[u8]| {
        let out = b64(cipher.encrypted(c, data));
        c += 1;
        out
    };
    let auth = next(regist_key);
    let did = next(device_id);
    let os_type = next(OS_TYPE);
    let start_bitrate = target.sends_start_bitrate().then(|| next(&[0u8; 4]));
    let streaming_type = target
        .sends_streaming_type()
        .then(|| next(&codec.streaming_type().to_le_bytes()));
    EncryptedHeaders {
        auth,
        did,
        os_type,
        start_bitrate,
        streaming_type,
        next_counter: c,
    }
}

pub fn build_control_request(target: Target, console: SocketAddr, h: &EncryptedHeaders) -> String {
    let mut s = format!(
        "GET {} HTTP/1.1\r\nHost: {}:{}\r\nUser-Agent: remoteplay Windows\r\nConnection: keep-alive\r\nContent-Length: 0\r\nRP-Auth: {}\r\nRP-Version: {}\r\nRP-Did: {}\r\nRP-ControllerType: 3\r\nRP-ClientType: 11\r\nRP-OSType: {}\r\nRP-ConPath: 1\r\n",
        target.control_path(),
        console.ip(),
        console.port(),
        h.auth,
        target.version_str(),
        h.did,
        h.os_type
    );
    if let Some(v) = &h.start_bitrate {
        s.push_str(&format!("RP-StartBitrate: {v}\r\n"));
    }
    if let Some(v) = &h.streaming_type {
        s.push_str(&format!("RP-StreamingType: {v}\r\n"));
    }
    s.push_str("\r\n");
    s
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ControlInfo {
    pub server_type: Option<ServerType>,
    pub prohibit: bool,
}

pub fn parse_control_response(
    header: &[u8],
    cipher: &RpCipher,
) -> Result<(ControlInfo, bool), ControlError> {
    let h = parse_response(header, Strictness::Tolerant)
        .ok_or_else(|| ControlError::ConnectFailed("unparsable response".into()))?;
    if h.status != 200 {
        return Err(ControlError::ConnectFailed(format!("status {}", h.status)));
    }
    let mut info = ControlInfo {
        server_type: None,
        prohibit: false,
    };
    let mut consumed = false;
    if let Some(v) = h.get("RP-Server-Type") {
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(v.trim())
            .map_err(|_| ControlError::ConnectFailed("malformed RP-Server-Type".into()))?;
        if bytes.len() > 16 {
            return Err(ControlError::ConnectFailed(
                "RP-Server-Type too long".into(),
            ));
        }
        if bytes.len() == 16 {
            let plain = cipher.decrypted(0, &bytes);
            info.server_type = Some(ServerType::from_byte(plain[0]));
            consumed = true;
        }
    }
    if let Some(v) = h.get("RP-Prohibit") {
        info.prohibit = v.trim().parse::<i64>().ok() == Some(1);
    }
    Ok((info, consumed))
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionId {
    pub id: String,
    pub fallback: bool,
}

struct Writer {
    conn: TcpConn,
    cipher: RpCipher,
    counter: u64,
    send_timeout: Duration,
}

impl Writer {
    fn send(&mut self, ty: u16, payload: &[u8]) -> io::Result<()> {
        let mut body = payload.to_vec();
        if !body.is_empty() {
            self.cipher.encrypt(self.counter, &mut body);
            self.counter += 1;
        }
        let header = encode_frame_header(body.len() as u32, ty);
        self.conn.send_all(&header, self.send_timeout)?;
        if !body.is_empty() {
            self.conn.send_all(&body, self.send_timeout)?;
        }
        Ok(())
    }
}

#[derive(Default)]
struct State {
    session_id: Option<SessionId>,
    pin_requests: u32,
    pin_outstanding: bool,
    wait_restart: Option<Instant>,
    failure: Option<ControlError>,
    remote_closed: bool,
    screen: ScreenGuard,
    keyboard_counter: u32,
}

struct Inner {
    writer: Mutex<Writer>,
    state: Mutex<State>,
    cond: Condvar,
    events: EventSink,
    dualsense: bool,
    keyboard: bool,
    closing: AtomicBool,
    session_id_timeout: Duration,
}

impl Inner {
    fn state(&self) -> MutexGuard<'_, State> {
        crate::sync::lock(&self.state)
    }

    fn send(&self, ty: u16, payload: &[u8]) -> Result<(), ControlError> {
        let mut w = crate::sync::lock(&self.writer);
        w.send(ty, payload)
            .map_err(|e| ControlError::Failed(format!("sending: {e}")))
    }

    fn send_feature_burst(&self) {
        for (ty, payload) in feature_burst(self.dualsense, self.keyboard) {
            if self.send(ty, &payload).is_err() {
                break;
            }
        }
    }

    fn fail(&self, reason: String) {
        let mut st = self.state();
        if st.failure.is_none() {
            st.failure = Some(ControlError::Failed(reason));
        }
        drop(st);
        self.cond.notify_all();
    }

    fn pin_requested(&self) {
        let mut st = self.state();
        let previous_wrong = st.pin_requests > 0;
        st.pin_requests += 1;
        st.pin_outstanding = true;
        drop(st);
        self.cond.notify_all();
        (self.events)(ControlEvent::PinRequested { previous_wrong });
    }

    fn dispatch(&self, ty: u16, payload: &[u8]) {
        match ty {
            msg_type::HEARTBEAT_REQUEST => {
                let _ = self.send(msg_type::HEARTBEAT_REPLY, &[]);
            }
            msg_type::SESSION_ID => {
                let mut st = self.state();
                if st.session_id.is_none() {
                    st.session_id = Some(match parse_session_id(payload) {
                        Some(id) => SessionId {
                            id,
                            fallback: false,
                        },
                        None => SessionId {
                            id: fallback_session_id(),
                            fallback: true,
                        },
                    });
                }
                drop(st);
                self.cond.notify_all();
                self.send_feature_burst();
            }
            msg_type::LOGIN_PIN_REQUEST => {
                if self.state().session_id.is_some() {
                    self.fail("login PIN request after the session id".into());
                } else {
                    self.pin_requested();
                }
            }
            msg_type::LOGIN_RESULT => {
                if payload.first() == Some(&1) && self.state().pin_requests > 0 {
                    self.pin_requested();
                }
            }
            msg_type::SCREEN_GUARD => {
                let n = self.state().screen.on_guard(payload);
                if let Some(v) = n {
                    (self.events)(ControlEvent::CannotDisplay(v));
                }
            }
            msg_type::SCREEN_BLACKOUT => {
                let n = self.state().screen.on_blackout(payload);
                if let Some(v) = n {
                    (self.events)(ControlEvent::CannotDisplay(v));
                }
            }
            msg_type::KEYBOARD_OPENED => {
                if let Some(text) = parse_keyboard_opened(payload) {
                    (self.events)(ControlEvent::KeyboardOpened(text));
                }
            }
            msg_type::KEYBOARD_TEXT_CHANGED => {
                if let Some((_, text)) = parse_keyboard_text_changed(payload) {
                    (self.events)(ControlEvent::KeyboardTextChanged(text));
                }
            }
            msg_type::KEYBOARD_CLOSED_REMOTELY => {
                (self.events)(ControlEvent::KeyboardClosedRemotely);
            }
            _ => {}
        }
    }
}

struct Reader {
    conn: TcpConn,
    cipher: RpCipher,
    counter: u64,
    buf: Vec<u8>,
    inner: Arc<Inner>,
}

impl Reader {
    fn run(mut self) {
        let mut chunk = [0u8; 4096];
        loop {
            while self.buf.len() >= FRAME_HEADER_LEN {
                let mut h = [0u8; FRAME_HEADER_LEN];
                h.copy_from_slice(&self.buf[..FRAME_HEADER_LEN]);
                let (len, ty) = decode_frame_header(&h);
                let len = len as usize;
                if len > MAX_PAYLOAD {
                    self.inner
                        .fail(format!("message of {len} bytes is too large"));
                    return;
                }
                if self.buf.len() < FRAME_HEADER_LEN + len {
                    break;
                }
                let mut payload: Vec<u8> =
                    self.buf[FRAME_HEADER_LEN..FRAME_HEADER_LEN + len].to_vec();
                self.buf.drain(..FRAME_HEADER_LEN + len);
                if !payload.is_empty() {
                    self.cipher.decrypt(self.counter, &mut payload);
                    self.counter += 1;
                }
                self.inner.dispatch(ty, &payload);
            }
            match self.conn.read_blocking(&mut chunk) {
                Ok(0) => {
                    self.inner.state().remote_closed = true;
                    self.inner.cond.notify_all();
                    return;
                }
                Ok(n) => self.buf.extend_from_slice(&chunk[..n]),
                Err(e) => {
                    if !self.inner.closing.load(Ordering::SeqCst) {
                        self.inner.fail(format!("receiving: {e}"));
                    }
                    return;
                }
            }
        }
    }
}

pub struct ControlChannel {
    handle: ControlHandle,
    reader: Option<JoinHandle<()>>,
    info: ControlInfo,
}

#[derive(Clone)]
pub struct ControlHandle {
    inner: Arc<Inner>,
}

impl std::ops::Deref for ControlChannel {
    type Target = ControlHandle;
    fn deref(&self) -> &ControlHandle {
        &self.handle
    }
}

fn connect_failed(what: &str, e: io::Error) -> ControlError {
    if e.kind() == io::ErrorKind::Interrupted {
        ControlError::Stopped
    } else {
        ControlError::ConnectFailed(format!("{what}: {e}"))
    }
}

impl ControlChannel {
    pub fn connect(
        config: &ControlConfig,
        events: EventSink,
        stop: &StopToken,
    ) -> Result<ControlChannel, ControlError> {
        let t = config.timeouts;
        let headers = encrypt_headers(
            &config.cipher,
            config.target,
            &config.regist_key,
            &config.device_id,
            config.codec,
        );
        let request = build_control_request(config.target, config.console_addr, &headers);

        let mut attempt = 0;
        let (conn, header, rest) = loop {
            attempt += 1;
            if stop.is_stopped() {
                return Err(ControlError::Stopped);
            }
            let mut conn = TcpConn::connect(config.console_addr, t.connect)
                .map_err(|e| connect_failed("connecting", e))?;
            conn.send_all(request.as_bytes(), t.send)
                .map_err(|e| connect_failed("sending", e))?;
            match conn.read_header(t.response, 8192, stop) {
                Ok((h, r)) => break (conn, h, r),
                Err(e) if e.kind() == io::ErrorKind::TimedOut && attempt == 1 => {
                    conn.shutdown();
                }
                Err(e) => return Err(connect_failed("receiving", e)),
            }
        };
        let (info, consumed) = parse_control_response(&header, &config.cipher)?;

        let reader_conn = conn.try_clone().map_err(|e| connect_failed("socket", e))?;
        let inner = Arc::new(Inner {
            writer: Mutex::new(Writer {
                conn,
                cipher: config.cipher.clone(),
                counter: headers.next_counter,
                send_timeout: t.send,
            }),
            state: Mutex::new(State::default()),
            cond: Condvar::new(),
            events,
            dualsense: config.dualsense,
            keyboard: config.keyboard,
            closing: AtomicBool::new(false),
            session_id_timeout: t.session_id,
        });
        if info.prohibit {
            (inner.events)(ControlEvent::CannotDisplay(true));
        }
        let reader = Reader {
            conn: reader_conn,
            cipher: config.cipher.clone(),
            counter: u64::from(consumed),
            buf: rest,
            inner: inner.clone(),
        };
        let handle = crate::threads::spawn(
            crate::threads::ThreadRole::Control,
            "con-control",
            move || reader.run(),
        )
        .map_err(|e| connect_failed("thread", e))?;
        Ok(ControlChannel {
            handle: ControlHandle { inner },
            reader: Some(handle),
            info,
        })
    }

    pub fn info(&self) -> ControlInfo {
        self.info
    }

    pub fn handle(&self) -> ControlHandle {
        self.handle.clone()
    }

    pub fn close(self) {
        drop(self);
    }

    fn shutdown(&mut self) {
        let inner = &self.handle.inner;
        inner.closing.store(true, Ordering::SeqCst);
        {
            let w = crate::sync::lock(&inner.writer);
            w.conn.shutdown();
        }
        inner.cond.notify_all();
        if let Some(h) = self.reader.take() {
            if h.thread().id() != std::thread::current().id() {
                let _ = h.join();
            }
        }
    }
}

impl ControlHandle {
    pub fn session_id(&self) -> Option<SessionId> {
        self.inner.state().session_id.clone()
    }

    pub fn failure(&self) -> Option<ControlError> {
        self.inner.state().failure.clone()
    }

    pub fn remote_closed(&self) -> bool {
        self.inner.state().remote_closed
    }

    pub fn wait_session_id(&self, stop: &StopToken) -> Result<SessionId, ControlError> {
        let start = Instant::now();
        let mut st = self.inner.state();
        loop {
            if stop.is_stopped() {
                return Err(ControlError::Stopped);
            }
            if let Some(f) = &st.failure {
                return Err(f.clone());
            }
            if self.inner.closing.load(Ordering::SeqCst) {
                return Err(ControlError::Failed("control channel closed".into()));
            }
            if let Some(id) = &st.session_id {
                return Ok(id.clone());
            }
            let wait = if st.pin_outstanding {
                Duration::from_millis(50)
            } else {
                let since = st.wait_restart.map_or(start, |r| r.max(start));
                let deadline = since + self.inner.session_id_timeout;
                let now = Instant::now();
                if now >= deadline {
                    let id = SessionId {
                        id: fallback_session_id(),
                        fallback: true,
                    };
                    st.session_id = Some(id.clone());
                    drop(st);
                    self.inner.send_feature_burst();
                    return Ok(id);
                }
                (deadline - now).min(Duration::from_millis(50))
            };
            st = self
                .inner
                .cond
                .wait_timeout(st, wait)
                .unwrap_or_else(|p| p.into_inner())
                .0;
        }
    }

    pub fn submit_pin(&self, pin: &str) -> Result<(), ControlError> {
        self.inner.send(msg_type::LOGIN_PIN, pin.as_bytes())?;
        let mut st = self.inner.state();
        st.pin_outstanding = false;
        st.wait_restart = Some(Instant::now());
        drop(st);
        self.inner.cond.notify_all();
        Ok(())
    }

    pub fn sleep(&self) -> Result<(), ControlError> {
        self.inner.send(msg_type::SLEEP, &[])
    }

    pub fn go_home(&self) -> Result<(), ControlError> {
        self.inner.send(msg_type::GO_HOME, &GO_HOME_PAYLOAD)
    }

    pub fn microphone_connect(&self) -> Result<(), ControlError> {
        self.inner.send(msg_type::MIC_CONNECT, &MIC_CONNECT_PAYLOAD)
    }

    pub fn set_microphone_muted(&self, muted: bool) -> Result<(), ControlError> {
        self.inner
            .send(msg_type::MIC_MUTE, &mic_mute_payload(muted))
    }

    pub fn keyboard_set_text(&self, text: &str) -> Result<(), ControlError> {
        let counter = {
            let mut st = self.inner.state();
            st.keyboard_counter += 1;
            st.keyboard_counter
        };
        self.inner.send(
            msg_type::KEYBOARD_SET_TEXT,
            &keyboard_set_text_payload(counter, text),
        )
    }

    pub fn keyboard_accept(&self) -> Result<(), ControlError> {
        self.inner
            .send(msg_type::KEYBOARD_CLOSE, &keyboard_close_payload(true))
    }

    pub fn keyboard_cancel(&self) -> Result<(), ControlError> {
        self.inner
            .send(msg_type::KEYBOARD_CLOSE, &keyboard_close_payload(false))
    }
}

impl Drop for ControlChannel {
    fn drop(&mut self) {
        self.shutdown();
    }
}
