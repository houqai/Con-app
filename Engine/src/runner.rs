use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use crate::crypto::random_bytes;
use crate::crypto::stream::EcdhKeyPair;
use crate::launch::{LaunchSpec, StreamChoice};
use crate::log::{LogLevel, LogSink, Logger};
use crate::media::capture::{AudioCaptureSlot, VideoCaptureSlot};
use crate::media::video::{MissingReference, MissingReferenceSlot};
use crate::media::{MediaConfig, MediaSink, MediaStats};
use crate::nettest::{self, NetworkTestConfig, NetworkTestResult};
use crate::session::{
    self, ControlEvent, ControlHandle, ControlTimeouts, EventSink, QuitReason, RequestTimeouts,
    SessionConfig,
};
use crate::stream::{self, StreamConfig, StreamEvent, StreamHandle, StreamTimeouts};
use crate::sync::lock;
use crate::transport::{
    CongestionConfig, HandshakeTiming, TransportStats, CONSOLE_LOSS_CEILING, NETWORK_TEST_PORT,
    STREAM_PORT,
};
use crate::{Codec, ConsoleKind, Stage, StopToken};

#[derive(Clone)]
pub struct ConsoleParams {
    pub host: String,
    pub kind: ConsoleKind,
    pub regist_key: [u8; 16],
    pub rp_key: [u8; 16],
    pub choice: StreamChoice,
    pub keyboard: bool,
    pub session_port: u16,
    pub network_test_port: u16,
    pub stream_port: u16,
    pub network_test: bool,
    pub network_test_timings: nettest::Timings,
    pub request_timeouts: RequestTimeouts,
    pub control_timeouts: ControlTimeouts,
}

impl ConsoleParams {
    pub fn new(
        host: impl Into<String>,
        kind: ConsoleKind,
        regist_key: [u8; 16],
        rp_key: [u8; 16],
        choice: StreamChoice,
    ) -> Self {
        Self {
            host: host.into(),
            kind,
            regist_key,
            rp_key,
            choice,
            keyboard: false,
            session_port: session::SESSION_PORT,
            network_test_port: NETWORK_TEST_PORT,
            stream_port: STREAM_PORT,
            network_test: true,
            network_test_timings: nettest::Timings::console(),
            request_timeouts: RequestTimeouts::default(),
            control_timeouts: ControlTimeouts::default(),
        }
    }
}

#[derive(Clone)]
pub struct CloudSlot {
    pub addr: SocketAddr,
    pub prefix: u8,
    pub ps5: bool,
    pub session_id: String,
    pub handshake_key: [u8; 16],
    pub launch_spec: String,
    pub mtu_in: Option<u32>,
    pub mtu_out: Option<u32>,
    pub rtt_us: Option<u64>,
    pub codec: Codec,
    pub max_fps: u32,
}

impl std::fmt::Debug for CloudSlot {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CloudSlot")
            .field("addr", &self.addr)
            .field("prefix", &self.prefix)
            .field("ps5", &self.ps5)
            .finish_non_exhaustive()
    }
}

#[derive(Clone)]
#[allow(clippy::large_enum_variant)]
pub enum Connection {
    Console(ConsoleParams),
    Cloud(CloudSlot),
}

#[derive(Clone)]
pub struct SessionRunnerConfig {
    pub connection: Connection,
    pub dualsense: bool,
    pub loss_ceiling: f64,
    pub stream_timeouts: StreamTimeouts,
    pub handshake: HandshakeTiming,
    pub discard_video: bool,
    pub discard_audio: bool,
    pub idr_on_fec_failure: bool,
    pub decode_audio: bool,
    pub capture: VideoCaptureSlot,
    pub audio_capture: AudioCaptureSlot,
    pub missing_reference: MissingReferenceSlot,
    pub log: Option<LogSink>,
    pub log_max: LogLevel,
}

impl SessionRunnerConfig {
    pub fn new(connection: Connection) -> Self {
        let loss_ceiling = match &connection {
            Connection::Cloud(s) if !s.ps5 => 0.02,
            _ => CONSOLE_LOSS_CEILING,
        };
        let dualsense = match &connection {
            Connection::Cloud(s) => s.ps5,
            Connection::Console(_) => true,
        };
        Self {
            connection,
            dualsense,
            loss_ceiling,
            stream_timeouts: StreamTimeouts::default(),
            handshake: HandshakeTiming::default(),
            discard_video: false,
            discard_audio: false,
            idr_on_fec_failure: false,
            decode_audio: cfg!(feature = "opus"),
            capture: VideoCaptureSlot::default(),
            audio_capture: AudioCaptureSlot::default(),
            missing_reference: MissingReferenceSlot::default(),
            log: None,
            log_max: LogLevel::Debug,
        }
    }

    fn media(&self, mut m: MediaConfig) -> MediaConfig {
        m.idr_on_fec_failure = self.idr_on_fec_failure;
        m.decode_audio = self.decode_audio && cfg!(feature = "opus");
        m
    }

    fn apply_to(&self, sc: &mut StreamConfig, log: &Logger) {
        sc.dualsense = self.dualsense;
        sc.timeouts = self.stream_timeouts;
        sc.handshake = self.handshake;
        sc.discard_video = self.discard_video;
        sc.discard_audio = self.discard_audio;
        sc.capture = self.capture.clone();
        sc.audio_capture = self.audio_capture.clone();
        sc.missing_reference = self.missing_reference.clone();
        sc.log = log.clone();
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum SessionEvent {
    Control(ControlEvent),
    NetworkTest {
        result: NetworkTestResult,
        fallback: bool,
    },
    Stream(StreamEvent),
    Quit {
        reason: QuitReason,
        text: Option<String>,
        stage: Stage,
    },
}

pub type SessionEventSink = Arc<dyn Fn(SessionEvent) + Send + Sync>;

#[derive(Default)]
struct Handles {
    control: Option<ControlHandle>,
    stream: Option<StreamHandle>,
}

pub struct Session {
    stop: StopToken,
    capture: VideoCaptureSlot,
    audio_capture: AudioCaptureSlot,
    missing_reference: MissingReferenceSlot,
    log: Logger,
    handles: Arc<Mutex<Handles>>,
    thread: Option<JoinHandle<()>>,
}

impl std::fmt::Debug for Session {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Session { .. }")
    }
}

impl Session {
    pub fn start(
        config: SessionRunnerConfig,
        events: SessionEventSink,
        media: Arc<dyn MediaSink>,
    ) -> Session {
        let stop = StopToken::new();
        let capture = config.capture.clone();
        let audio_capture = config.audio_capture.clone();
        let missing_reference = config.missing_reference.clone();
        let log = Logger::with_max(config.log.clone(), config.log_max);
        let handles = Arc::new(Mutex::new(Handles::default()));
        let thread = {
            let stop = stop.clone();
            let handles = handles.clone();
            let log = log.clone();
            crate::threads::spawn(
                crate::threads::ThreadRole::Session,
                "con-session",
                move || {
                    let (reason, text, stage) =
                        run_session(&config, &events, media, &handles, &stop, &log);
                    lock(&handles).stream = None;
                    events(SessionEvent::Quit {
                        reason,
                        text,
                        stage,
                    });
                },
            )
            .expect("spawning the session thread")
        };
        Session {
            stop,
            capture,
            audio_capture,
            missing_reference,
            log,
            handles,
            thread: Some(thread),
        }
    }

    pub fn stop(&self) {
        self.stop.stop();
    }

    pub fn join(mut self) {
        if let Some(h) = self.thread.take() {
            let _ = h.join();
        }
    }

    pub fn is_finished(&self) -> bool {
        self.thread.as_ref().is_none_or(|h| h.is_finished())
    }

    pub fn control(&self) -> Option<ControlHandle> {
        lock(&self.handles).control.clone()
    }

    pub fn stream(&self) -> Option<StreamHandle> {
        lock(&self.handles).stream.clone()
    }

    pub fn stats(&self) -> Option<TransportStats> {
        self.stream().map(|s| s.stats())
    }

    pub fn media_stats(&self) -> Option<MediaStats> {
        self.stream().map(|s| s.media_stats())
    }

    pub fn set_missing_reference(&self, policy: MissingReference) {
        self.missing_reference.set(policy);
    }

    pub fn set_video_capture(&self, path: Option<&std::path::Path>) -> std::io::Result<()> {
        match path {
            Some(p) => self.capture.start(p, self.log.clone()),
            None => {
                self.capture.stop();
                Ok(())
            }
        }
    }

    pub fn set_audio_capture(&self, path: Option<&std::path::Path>) -> std::io::Result<()> {
        match path {
            Some(p) => self.audio_capture.start(p, self.log.clone()),
            None => {
                self.audio_capture.stop();
                Ok(())
            }
        }
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.stop.stop();
        if let Some(h) = self.thread.take() {
            let _ = h.join();
        }
        self.capture.stop();
        self.audio_capture.stop();
    }
}

fn stream_events(events: &SessionEventSink) -> stream::StreamEventSink {
    let events = events.clone();
    Arc::new(move |e| events(SessionEvent::Stream(e)))
}

type Ended = (QuitReason, Option<String>, Stage);

fn run_session(
    config: &SessionRunnerConfig,
    events: &SessionEventSink,
    data: Arc<dyn MediaSink>,
    handles: &Arc<Mutex<Handles>>,
    stop: &StopToken,
    log: &Logger,
) -> Ended {
    match &config.connection {
        Connection::Console(c) => run_console(config, c, events, data, handles, stop, log),
        Connection::Cloud(slot) => {
            let mtu_in = slot
                .mtu_in
                .filter(|&m| m != 0)
                .unwrap_or(nettest::CLOUD_DEFAULT_MTU_IN);
            let mtu_out = slot
                .mtu_out
                .filter(|&m| m != 0)
                .unwrap_or(nettest::CLOUD_DEFAULT_MTU_OUT);
            log.info(|| {
                format!(
                    "cloud slot: mtu in {mtu_in}, out {mtu_out}, rtt {}",
                    slot.rtt_us.map_or("not measured".into(), |r| format!(
                        "{r} us (measured before streaming)"
                    ))
                )
            });
            let mut sc = StreamConfig::cloud(
                slot.addr,
                slot.prefix,
                if slot.ps5 {
                    stream::PS5_TRANSPORT_VERSION
                } else {
                    stream::PS4_TRANSPORT_VERSION
                },
                slot.session_id.clone(),
                slot.launch_spec.clone(),
                slot.handshake_key,
            );
            sc.mtu_in = mtu_in;
            sc.mtu_out = mtu_out;
            sc.congestion = CongestionConfig::cloud(config.loss_ceiling, slot.ps5);
            sc.media = config.media(MediaConfig::cloud(slot.ps5, slot.codec, slot.max_fps));
            sc.initial_rtt_us = slot.rtt_us;
            config.apply_to(&mut sc, log);
            let h = handles.clone();
            let o = stream::run(
                sc,
                stream_events(events),
                data,
                move |s| lock(&h).stream = Some(s),
                stop,
            );
            (o.reason, o.text, o.stage)
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn run_console(
    config: &SessionRunnerConfig,
    c: &ConsoleParams,
    events: &SessionEventSink,
    data: Arc<dyn MediaSink>,
    handles: &Arc<Mutex<Handles>>,
    stop: &StopToken,
    log: &Logger,
) -> Ended {
    let mut sc = SessionConfig::new(c.host.clone(), c.kind, c.regist_key, c.rp_key);
    sc.port = c.session_port;
    sc.codec = c.choice.codec;
    sc.dualsense = config.dualsense;
    sc.keyboard = c.keyboard;
    sc.request_timeouts = c.request_timeouts;
    sc.control_timeouts = c.control_timeouts;
    let sink: EventSink = {
        let events = events.clone();
        Arc::new(move |e| events(SessionEvent::Control(e)))
    };
    let started = {
        let h = handles.clone();
        match session::start(&sc, sink, move |ctl| lock(&h).control = Some(ctl), stop) {
            Ok(s) => s,
            Err(e) => {
                log.info(|| format!("session: {}", e.detail));
                lock(handles).control = None;
                return (e.reason, None, e.stage);
            }
        }
    };
    log.info(|| format!("session: target {}, control open", started.target));

    let (result, fallback) = if c.network_test {
        let mut nc = NetworkTestConfig::console(SocketAddr::new(
            started.console_addr.ip(),
            c.network_test_port,
        ));
        nc.timings = c.network_test_timings;
        nc.log = log.clone();
        match nettest::run(nc, stop) {
            Ok(r) => (r, false),
            Err(nettest::NetworkTestError::Stopped) => {
                return close_with(
                    handles,
                    started.control,
                    QuitReason::Stopped,
                    None,
                    Stage::NetworkTest,
                )
            }
            Err(_) => (NetworkTestResult::console_fallback(), true),
        }
    } else {
        (NetworkTestResult::console_fallback(), true)
    };
    events(SessionEvent::NetworkTest { result, fallback });
    if stop.is_stopped() {
        return close_with(
            handles,
            started.control,
            QuitReason::Stopped,
            None,
            Stage::NetworkTest,
        );
    }
    if let Some(f) = started.control.failure() {
        return close_with(
            handles,
            started.control,
            QuitReason::from(&f),
            None,
            Stage::NetworkTest,
        );
    }

    let handshake_key: [u8; 16] = random_bytes();
    let ecdh = EcdhKeyPair::generate();
    let choice = match started.control.info().server_type {
        Some(t) => c.choice.adjusted_for(t),
        None => c.choice,
    };
    let spec = LaunchSpec::new(
        started.target,
        choice,
        result.mtu_in,
        result.rtt_us / 1000,
        handshake_key,
    );
    let launch_spec = match spec.encode(&started.cipher) {
        Ok(s) => s,
        Err(e) => {
            log.warn(|| format!("session: launch specification: {e}"));
            return close_with(
                handles,
                started.control,
                QuitReason::StreamUnknown,
                None,
                Stage::Transport,
            );
        }
    };

    let mut stc = StreamConfig::console(
        SocketAddr::new(started.console_addr.ip(), c.stream_port),
        started.target.transport_version(),
        started.session_id.id.clone(),
        launch_spec,
        handshake_key,
    );
    stc.ecdh = Some(ecdh);
    stc.mtu_in = result.mtu_in;
    stc.mtu_out = result.mtu_out;
    stc.dont_fragment = !fallback;
    stc.congestion = CongestionConfig::console(config.loss_ceiling);
    stc.media = config.media(MediaConfig::console(choice.codec, choice.max_fps));
    config.apply_to(&mut stc, log);
    let h = handles.clone();
    let o = stream::run(
        stc,
        stream_events(events),
        data,
        move |s| lock(&h).stream = Some(s),
        stop,
    );
    close_with(handles, started.control, o.reason, o.text, o.stage)
}

fn close_with(
    handles: &Arc<Mutex<Handles>>,
    control: session::ControlChannel,
    reason: QuitReason,
    text: Option<String>,
    stage: Stage,
) -> Ended {
    {
        let mut h = lock(handles);
        h.control = None;
        h.stream = None;
    }
    control.close();
    (reason, text, stage)
}
