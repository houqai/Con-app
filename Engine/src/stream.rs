use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use crate::crypto::stream::{verify_public_key_signature, EcdhKeyPair, StreamKeys};
use crate::log::Logger;
use crate::media::capture::{AudioCaptureSlot, VideoCaptureSlot};
use crate::media::effects::EffectsState;
use crate::media::feedback::{ControllerState, FeedbackSender, FeedbackShared};
use crate::media::video::MissingReferenceSlot;
use crate::media::{
    FeedbackEvent, MediaActions, MediaConfig, MediaPipeline, MediaSink, MediaStats,
};
use crate::proto::{
    client_disconnect, client_stream_info, controller_connection, msg_type, Big, ConnectionQuality,
    CorruptFrame, Envelope, Message, Resolution, StreamInfo,
};
use crate::session::QuitReason;
use crate::transport::packet::data_type;
use crate::transport::{
    video, CongestionConfig, DataMessage, Endpoint, HandshakeTiming, Link, MediaPacket,
    RetransmitConfig, Transport, TransportConfig, TransportError, TransportHandler, TransportStats,
    CLOUD_RECV_BUFFER, CONSOLE_LOSS_CEILING, CONSOLE_RECV_BUFFER,
};
use crate::{Stage, StopToken};

pub const CHANNEL_MAIN: u16 = 1;
pub const CHANNEL_VIDEO: u16 = 2;
pub const CHANNEL_STREAM_INFO_ACK: u16 = 9;
pub const MAX_PROFILES: usize = 8;
pub const MAX_REASON: usize = 255;
pub const ENCRYPTED_KEY: [u8; 4] = [0, 0, 0, 0];
pub const PS4_TRANSPORT_VERSION: u32 = 9;
pub const PS5_TRANSPORT_VERSION: u32 = 12;
const STREAM_INFO_FIELD: u32 = 15;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StreamTimeouts {
    pub transport: Duration,
    pub bang: Duration,
    pub stream_info: Duration,
    pub heartbeat: Duration,
}

impl Default for StreamTimeouts {
    fn default() -> Self {
        Self {
            transport: Duration::from_secs(5),
            bang: Duration::from_secs(5),
            stream_info: Duration::from_secs(5),
            heartbeat: Duration::from_secs(1),
        }
    }
}

pub struct StreamConfig {
    pub endpoint: Endpoint,
    pub cloud: bool,
    pub prefix: u8,
    pub transport_version: u32,
    pub session_key: String,
    pub launch_spec: String,
    pub handshake_key: [u8; 16],
    pub ecdh: Option<EcdhKeyPair>,
    pub mtu_in: u32,
    pub mtu_out: u32,
    pub dont_fragment: bool,
    pub dualsense: bool,
    pub congestion: CongestionConfig,
    pub timeouts: StreamTimeouts,
    pub handshake: HandshakeTiming,
    pub retransmit: RetransmitConfig,
    pub client_tag: Option<u32>,
    pub discard_video: bool,
    pub discard_audio: bool,
    pub media: MediaConfig,
    pub capture: VideoCaptureSlot,
    pub audio_capture: AudioCaptureSlot,
    pub missing_reference: MissingReferenceSlot,
    pub initial_rtt_us: Option<u64>,
    pub log: Logger,
}

impl std::fmt::Debug for StreamConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("StreamConfig")
            .field("endpoint", &self.endpoint)
            .field("cloud", &self.cloud)
            .field("prefix", &self.prefix)
            .field("transport_version", &self.transport_version)
            .field("mtu_in", &self.mtu_in)
            .field("mtu_out", &self.mtu_out)
            .finish_non_exhaustive()
    }
}

impl StreamConfig {
    pub fn console(
        addr: std::net::SocketAddr,
        transport_version: u32,
        session_key: String,
        launch_spec: String,
        handshake_key: [u8; 16],
    ) -> Self {
        Self {
            endpoint: Endpoint::Address(addr),
            cloud: false,
            prefix: 0,
            transport_version,
            session_key,
            launch_spec,
            handshake_key,
            ecdh: None,
            mtu_in: crate::nettest::FALLBACK_MTU,
            mtu_out: crate::nettest::FALLBACK_MTU,
            dont_fragment: true,
            dualsense: false,
            congestion: CongestionConfig::console(CONSOLE_LOSS_CEILING),
            timeouts: StreamTimeouts::default(),
            handshake: HandshakeTiming::default(),
            retransmit: RetransmitConfig::default(),
            client_tag: None,
            discard_video: false,
            discard_audio: false,
            media: MediaConfig::console(crate::Codec::H264, 60),
            capture: VideoCaptureSlot::default(),
            audio_capture: AudioCaptureSlot::default(),
            missing_reference: MissingReferenceSlot::default(),
            initial_rtt_us: None,
            log: Logger::default(),
        }
    }

    pub fn cloud(
        addr: std::net::SocketAddr,
        prefix: u8,
        transport_version: u32,
        session_key: String,
        launch_spec: String,
        handshake_key: [u8; 16],
    ) -> Self {
        Self {
            cloud: true,
            prefix,
            dont_fragment: false,
            ..Self::console(
                addr,
                transport_version,
                session_key,
                launch_spec,
                handshake_key,
            )
        }
    }

    pub fn fragment_sizes(&self) -> (usize, usize) {
        let m = self.mtu_in.min(self.mtu_out) as usize;
        if self.cloud {
            let b = m.saturating_sub(28);
            (b.saturating_sub(30), b.saturating_sub(29))
        } else {
            let b = m.saturating_sub(50);
            (b.saturating_sub(26), b.saturating_sub(25))
        }
    }

    fn transport_config(&self, endpoint: Endpoint) -> TransportConfig {
        TransportConfig {
            endpoint,
            prefix: self.prefix,
            media_version: self.transport_version,
            encrypted: true,
            initial_tsn_from_init_ack: self.cloud,
            reorder_video: true,
            video_wait: if self.cloud {
                video::CLOUD_VIDEO_WAIT
            } else {
                video::CONSOLE_VIDEO_WAIT
            },
            recv_buffer: if self.cloud {
                CLOUD_RECV_BUFFER
            } else {
                CONSOLE_RECV_BUFFER
            },
            dont_fragment: self.dont_fragment,
            congestion: Some(self.congestion),
            handshake: self.handshake,
            retransmit: self.retransmit,
            client_tag: self.client_tag,
            discard_video: self.discard_video,
            discard_audio: self.discard_audio,
            initial_rtt_us: self.initial_rtt_us,
            log: self.log.clone(),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct StreamInfoEvent {
    pub resolutions: Vec<Resolution>,
    pub audio_header: [u8; 14],
    pub start_timeout: Option<u32>,
    pub afk_timeout: Option<u32>,
    pub afk_disconnect_timeout: Option<u32>,
    pub congestion_control_interval: Option<u32>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum StreamEvent {
    StreamInfo(StreamInfoEvent),
    Connected,
    ConnectionQuality(ConnectionQuality),
    ServerCorruptFrame(CorruptFrame),
    CloudPrelude {
        msg_type: u32,
        has_stream_info: bool,
        size: usize,
    },
    Feedback(FeedbackEvent),
    FecFailure {
        frame_index: u16,
        idr_requested: bool,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StreamData {
    Media(MediaPacket),
    Feedback { data_type: u8, data: Vec<u8> },
}

pub type StreamEventSink = Arc<dyn Fn(StreamEvent) + Send + Sync>;
pub type StreamDataSink = Arc<dyn Fn(StreamData) + Send + Sync>;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StreamOutcome {
    pub reason: QuitReason,
    pub text: Option<String>,
    pub detail: String,
    pub stage: Stage,
}

#[derive(Clone, Debug)]
pub struct StreamHandle {
    link: Link,
    ps5: bool,
    feedback: Arc<FeedbackShared>,
    media_stats: Arc<Mutex<MediaStats>>,
    #[cfg(feature = "opus")]
    mic: Arc<Mutex<Option<crate::media::opus::MicrophonePacker>>>,
}

impl StreamHandle {
    pub fn request_idr(&self) -> Result<(), TransportError> {
        self.send(CHANNEL_VIDEO, &Message::IdrRequest)
    }

    pub fn report_corrupt_frames(&self, start: u16, end: u16) -> Result<(), TransportError> {
        self.send(
            CHANNEL_VIDEO,
            &Message::CorruptFrame(CorruptFrame {
                start: u32::from(start),
                end: u32::from(end),
            }),
        )
    }

    fn send(&self, channel: u16, m: &Message) -> Result<(), TransportError> {
        self.link
            .send_message(channel, data_type::PROTOBUF, &m.encode())
            .map(|_| ())
    }

    pub fn send_microphone(&self, payload: &[u8]) -> Result<(), TransportError> {
        self.link.send_microphone(payload, self.ps5)
    }

    #[cfg(feature = "opus")]
    pub fn send_microphone_pcm(&self, pcm: &[i16]) -> Result<bool, String> {
        let mut g = crate::sync::lock(&self.mic);
        if g.is_none() {
            *g = Some(crate::media::opus::MicrophonePacker::new()?);
        }
        let payload = g.as_mut().expect("packer").push(pcm)?;
        drop(g);
        match payload {
            Some(p) => self
                .send_microphone(&p)
                .map(|_| true)
                .map_err(|e| e.to_string()),
            None => Ok(false),
        }
    }

    pub fn set_controller_state(&self, state: ControllerState) {
        self.feedback.set_state(state);
    }

    pub fn stats(&self) -> TransportStats {
        self.link.stats()
    }

    pub fn media_stats(&self) -> MediaStats {
        let mut s = *crate::sync::lock(&self.media_stats);
        s.feedback = self.feedback.stats();
        s
    }
}

#[derive(Default)]
struct State {
    bang: Option<Result<(), String>>,
    early_info: Option<Result<StreamInfo, String>>,
    info: Option<Result<StreamInfo, String>>,
    info_taken: bool,
    disconnect: Option<String>,
}

struct Shared {
    state: Mutex<State>,
    cond: Condvar,
}

impl Shared {
    fn lock(&self) -> MutexGuard<'_, State> {
        crate::sync::lock(&self.state)
    }
}

struct Handler {
    shared: Arc<Shared>,
    ecdh: EcdhKeyPair,
    handshake_key: [u8; 16],
    cloud: bool,
    events: StreamEventSink,
    sink: Arc<dyn MediaSink>,
    media_config: MediaConfig,
    media: Option<MediaPipeline>,
    media_stats: Arc<Mutex<MediaStats>>,
    capture: VideoCaptureSlot,
    audio_capture: AudioCaptureSlot,
    missing_reference: MissingReferenceSlot,
    effects: EffectsState,
    log: Logger,
}

struct Actions<'a> {
    link: &'a Link,
    events: &'a StreamEventSink,
    log: &'a Logger,
}

impl MediaActions for Actions<'_> {
    fn report_corrupt(&mut self, start: u16, end: u16) {
        let m = Message::CorruptFrame(CorruptFrame {
            start: u32::from(start),
            end: u32::from(end),
        });
        if let Err(e) =
            self.link
                .send_message_twice(CHANNEL_VIDEO, data_type::PROTOBUF, &m.encode())
        {
            self.log
                .debug(|| format!("video: corrupt-frame report failed: {e}"));
        }
    }

    fn request_idr(&mut self) {
        if let Err(e) = self.link.send_message_twice(
            CHANNEL_VIDEO,
            data_type::PROTOBUF,
            &Message::IdrRequest.encode(),
        ) {
            self.log.debug(|| format!("video: IDR request failed: {e}"));
        }
    }

    fn fec_failure(&mut self, frame_index: u16, idr_requested: bool) {
        (self.events)(StreamEvent::FecFailure {
            frame_index,
            idr_requested,
        });
    }
}

fn decode_info(env: &Envelope) -> Result<StreamInfo, String> {
    match Message::from_envelope(env) {
        Ok(Message::StreamInfo(i)) => Ok(i),
        Ok(_) => Err("not a stream info message".into()),
        Err(e) => Err(format!("stream info: {e}")),
    }
}

impl Handler {
    fn media_for(&mut self, info: &StreamInfo) {
        match &mut self.media {
            Some(m) => {
                if let Ok(h) = <[u8; 14]>::try_from(info.audio_header.as_slice()) {
                    self.log
                        .info(|| "stream: new stream info, restarting audio".into());
                    m.reset_audio(&h);
                }
            }
            None => {
                if let Ok(ev) = accept_stream_info(info.clone()) {
                    self.media = Some(MediaPipeline::new(
                        self.media_config,
                        &ev,
                        self.media_stats.clone(),
                        self.capture.clone(),
                        self.audio_capture.clone(),
                        self.missing_reference.clone(),
                        self.log.clone(),
                    ));
                }
            }
        }
    }

    fn on_bang(&self, link: &Link, env: &Envelope) -> Result<(), String> {
        let bang = match Message::from_envelope(env) {
            Ok(Message::Bang(b)) => b,
            Ok(_) => return Err("not a BANG".into()),
            Err(e) => return Err(format!("BANG: {e}")),
        };
        if !bang.version_accepted {
            return Err("server did not accept the version".into());
        }
        if !bang.encrypted_key_accepted {
            return Err("server did not accept the encrypted key".into());
        }
        let (Some(public), Some(signature)) = (&bang.ecdh_public_key, &bang.ecdh_signature) else {
            return Err("BANG without server public key or signature".into());
        };
        if public.is_empty() || signature.is_empty() {
            return Err("BANG with empty server public key or signature".into());
        }
        if !verify_public_key_signature(&self.handshake_key, public, signature) {
            self.log
                .debug(|| "stream: server key signature does not match".into());
        }
        let keys = StreamKeys::from_exchange(&self.ecdh, public, &self.handshake_key)
            .map_err(|e| format!("key exchange: {e}"))?;
        link.install_keys(keys);
        self.log.info(|| {
            format!(
                "stream: BANG, server version {}{}",
                bang.server_version,
                bang.server_version_string
                    .as_deref()
                    .map(|s| format!(" ({s})"))
                    .unwrap_or_default()
            )
        });
        Ok(())
    }
}

impl TransportHandler for Handler {
    fn on_message(&mut self, link: &Link, m: DataMessage) {
        match m.data_type {
            data_type::PROTOBUF => {}
            data_type::RUMBLE | data_type::PAD_INFO | data_type::TRIGGER_EFFECTS => {
                let effects = self.effects.on_message(m.data_type, &m.data);
                self.sink.raw(&StreamData::Feedback {
                    data_type: m.data_type,
                    data: m.data,
                });
                for e in effects {
                    (self.events)(StreamEvent::Feedback(e));
                }
                return;
            }
            _ => return,
        }
        let env = match Envelope::decode(&m.data) {
            Ok(e) => e,
            Err(e) => {
                self.log
                    .debug(|| format!("stream: undecodable message ({e})"));
                return;
            }
        };
        let shared = self.shared.clone();
        let mut st = shared.lock();
        match env.msg_type {
            msg_type::DISCONNECT => {
                let mut reason = match Message::from_envelope(&env) {
                    Ok(Message::Disconnect(d)) => d.reason,
                    _ => String::new(),
                };
                if reason.len() > MAX_REASON {
                    let mut cut = MAX_REASON;
                    while !reason.is_char_boundary(cut) {
                        cut -= 1;
                    }
                    reason.truncate(cut);
                }
                self.log
                    .info(|| format!("stream: server disconnected: {reason}"));
                st.disconnect.get_or_insert(reason);
            }
            msg_type::BANG if st.bang.is_none() => {
                let r = self.on_bang(link, &env);
                if r.is_ok() {
                    if let Some(Ok(info)) = &st.early_info {
                        let info = info.clone();
                        self.media_for(&info);
                    }
                }
                st.bang = Some(r);
            }
            msg_type::STREAMINFO => match &st.bang {
                None => {
                    if st.early_info.is_none() {
                        st.early_info = Some(decode_info(&env));
                    }
                }
                Some(Ok(())) => {
                    let info = decode_info(&env);
                    if let Ok(i) = &info {
                        self.media_for(i);
                    }
                    if st.info.is_none() && !st.info_taken {
                        st.info = Some(info);
                    }
                }
                _ => {}
            },
            other => {
                drop(st);
                match Message::from_envelope(&env) {
                    Ok(Message::ConnectionQuality(q)) => {
                        self.log
                            .debug(|| format!("stream: connection quality {q:?}"));
                        if let Some(m) = self.media.as_mut() {
                            m.on_connection_quality();
                        }
                        (self.events)(StreamEvent::ConnectionQuality(q));
                    }
                    Ok(Message::CorruptFrame(c)) => {
                        self.log.debug(|| {
                            format!("stream: server corrupt frame {}-{}", c.start, c.end)
                        });
                        (self.events)(StreamEvent::ServerCorruptFrame(c));
                    }
                    _ => {
                        let st = self.shared.lock();
                        let waiting_info =
                            matches!(st.bang, Some(Ok(()))) && !st.info_taken && st.info.is_none();
                        drop(st);
                        if self.cloud && waiting_info {
                            let has = env.present.contains(&STREAM_INFO_FIELD);
                            let size = m.data.len();
                            self.log.info(|| {
                                format!(
                                    "stream: cloud message type {other} before stream info \
                                     ({size} bytes, carries stream info: {has})"
                                )
                            });
                            (self.events)(StreamEvent::CloudPrelude {
                                msg_type: other,
                                has_stream_info: has,
                                size,
                            });
                        }
                    }
                }
                return;
            }
        }
        drop(st);
        self.shared.cond.notify_all();
    }

    fn on_media(&mut self, link: &Link, packet: MediaPacket) {
        let d = StreamData::Media(packet);
        self.sink.raw(&d);
        let StreamData::Media(p) = &d else {
            return;
        };
        if let Some(m) = self.media.as_mut() {
            let mut actions = Actions {
                link,
                events: &self.events,
                log: &self.log,
            };
            m.on_media(p, &*self.sink, &mut actions);
        }
    }
}

enum Wait<T> {
    Got(T),
    Disconnect(String),
    Stopped,
    Down,
    Timeout,
}

fn wait_for<T>(
    shared: &Shared,
    link: &Link,
    timeout: Duration,
    stop: &StopToken,
    mut pick: impl FnMut(&mut State) -> Option<T>,
) -> Wait<T> {
    let deadline = Instant::now() + timeout;
    let mut st = shared.lock();
    loop {
        if let Some(r) = st.disconnect.clone() {
            return Wait::Disconnect(r);
        }
        if let Some(v) = pick(&mut st) {
            return Wait::Got(v);
        }
        if stop.is_stopped() {
            return Wait::Stopped;
        }
        if link.is_down() {
            return Wait::Down;
        }
        let now = Instant::now();
        if now >= deadline {
            return Wait::Timeout;
        }
        st = shared
            .cond
            .wait_timeout(st, (deadline - now).min(Duration::from_millis(50)))
            .unwrap_or_else(|p| p.into_inner())
            .0;
    }
}

fn outcome(reason: QuitReason, text: Option<String>, detail: impl Into<String>) -> StreamOutcome {
    StreamOutcome {
        reason,
        text,
        detail: detail.into(),
        stage: Stage::Transport,
    }
}

fn wait_outcome<T>(w: Wait<T>, what: &str) -> Result<T, StreamOutcome> {
    match w {
        Wait::Got(v) => Ok(v),
        Wait::Disconnect(r) => Err(outcome(
            QuitReason::for_remote_disconnect(&r),
            Some(r),
            format!("server disconnected while waiting for {what}"),
        )),
        Wait::Stopped => Err(outcome(QuitReason::Stopped, None, "stopped")),
        Wait::Down => Err(outcome(
            QuitReason::StreamUnknown,
            None,
            format!("transport failed while waiting for {what}"),
        )),
        Wait::Timeout => Err(outcome(
            QuitReason::StreamUnknown,
            None,
            format!("no {what} in time"),
        )),
    }
}

pub fn accept_stream_info(info: StreamInfo) -> Result<StreamInfoEvent, String> {
    let audio_header: [u8; 14] = info
        .audio_header
        .as_slice()
        .try_into()
        .map_err(|_| format!("audio header of {} bytes", info.audio_header.len()))?;
    let mut resolutions = info.resolutions;
    resolutions.truncate(MAX_PROFILES);
    Ok(StreamInfoEvent {
        resolutions,
        audio_header,
        start_timeout: info.start_timeout,
        afk_timeout: info.afk_timeout,
        afk_disconnect_timeout: info.afk_disconnect_timeout,
        congestion_control_interval: info.congestion_control_interval,
    })
}

pub fn run(
    mut config: StreamConfig,
    events: StreamEventSink,
    sink: Arc<dyn MediaSink>,
    on_ready: impl FnOnce(StreamHandle),
    stop: &StopToken,
) -> StreamOutcome {
    let log = config.log.clone();
    let shared = Arc::new(Shared {
        state: Mutex::new(State::default()),
        cond: Condvar::new(),
    });
    let ecdh = config.ecdh.take().unwrap_or_else(EcdhKeyPair::generate);
    let public = ecdh.public_key();
    let signature = crate::crypto::stream::sign_public_key(&config.handshake_key, &public);
    let media_stats = Arc::new(Mutex::new(MediaStats::default()));
    let feedback = Arc::new(FeedbackShared::default());
    let handler = Handler {
        shared: shared.clone(),
        ecdh,
        handshake_key: config.handshake_key,
        cloud: config.cloud,
        events: events.clone(),
        sink,
        media_config: config.media,
        media: None,
        media_stats: media_stats.clone(),
        capture: config.capture.clone(),
        audio_capture: config.audio_capture.clone(),
        missing_reference: config.missing_reference.clone(),
        effects: EffectsState::new(),
        log: log.clone(),
    };
    let endpoint = std::mem::replace(
        &mut config.endpoint,
        Endpoint::Address(([0, 0, 0, 0], 0).into()),
    );
    let transport = match Transport::start(config.transport_config(endpoint), Box::new(handler)) {
        Ok(t) => t,
        Err(e) => return outcome(QuitReason::StreamUnknown, None, e.to_string()),
    };
    let link = transport.link();
    on_ready(StreamHandle {
        link: link.clone(),
        ps5: config.transport_version == PS5_TRANSPORT_VERSION,
        feedback: feedback.clone(),
        media_stats,
        #[cfg(feature = "opus")]
        mic: Arc::new(Mutex::new(None)),
    });

    let mut stage = Stage::Transport;
    let Err(mut end) = run_phases(
        &config, &shared, &link, &transport, &events, &feedback, &public, &signature, stop,
        &mut stage,
    );
    end.stage = stage;
    if link.is_established() {
        let _ = link.send_message(
            CHANNEL_MAIN,
            data_type::PROTOBUF,
            &client_disconnect().encode(),
        );
    }
    transport.close();
    log.info(|| {
        format!(
            "stream ended: {:?} at {:?} ({})",
            end.reason, end.stage, end.detail
        )
    });
    end
}

#[allow(clippy::too_many_arguments)]
fn run_phases(
    config: &StreamConfig,
    shared: &Shared,
    link: &Link,
    transport: &Transport,
    events: &StreamEventSink,
    feedback: &Arc<FeedbackShared>,
    public: &[u8; 65],
    signature: &[u8; 32],
    stop: &StopToken,
    stage: &mut Stage,
) -> Result<std::convert::Infallible, StreamOutcome> {
    let log = &config.log;
    let t = config.timeouts;
    match transport.wait_established(t.transport, stop) {
        Ok(()) => {}
        Err(TransportError::Stopped) => return Err(outcome(QuitReason::Stopped, None, "stopped")),
        Err(e) => {
            return Err(outcome(
                QuitReason::StreamUnknown,
                None,
                format!("transport: {e}"),
            ))
        }
    }
    log.info(|| "stream: transport connected".into());
    *stage = Stage::KeyExchange;

    let big = Message::Big(Big {
        version: config.transport_version,
        session_key: config.session_key.clone(),
        launch_spec: config.launch_spec.clone(),
        encrypted_key: ENCRYPTED_KEY.to_vec(),
        ecdh_public_key: Some(public.to_vec()),
        ecdh_signature: Some(signature.to_vec()),
    })
    .encode();
    let (first, cont) = config.fragment_sizes();
    match link.send_fragmented(CHANNEL_MAIN, data_type::PROTOBUF, &big, first, cont) {
        Ok(_) => {}
        Err(TransportError::SendBufferFull) => {
            log.warn(|| {
                "stream: BIG larger than the send buffer; not all fragments are retransmitted"
                    .into()
            });
        }
        Err(e) => {
            return Err(outcome(
                QuitReason::StreamUnknown,
                None,
                format!("sending BIG: {e}"),
            ))
        }
    }

    let bang = wait_outcome(
        wait_for(shared, link, t.bang, stop, |s| s.bang.clone()),
        "BANG",
    )?;
    if let Err(e) = bang {
        return Err(outcome(QuitReason::StreamUnknown, None, e));
    }
    *stage = Stage::StreamInfo;

    let info = wait_outcome(
        wait_for(shared, link, t.stream_info, stop, |s| {
            let i = s.early_info.take().or_else(|| s.info.take());
            if i.is_some() {
                s.info_taken = true;
            }
            i
        }),
        "stream info",
    )?;
    let info = info
        .and_then(accept_stream_info)
        .map_err(|e| outcome(QuitReason::StreamUnknown, None, e))?;
    log.info(|| {
        let r: Vec<String> = info
            .resolutions
            .iter()
            .map(|r| format!("{}x{}", r.width, r.height))
            .collect();
        format!("stream: stream info, profiles {}", r.join(", "))
    });
    let send = |channel: u16, m: Message| {
        link.send_message(channel, data_type::PROTOBUF, &m.encode())
            .map(|_| ())
            .map_err(|e| outcome(QuitReason::StreamUnknown, None, format!("sending: {e}")))
    };
    send(CHANNEL_STREAM_INFO_ACK, Message::StreamInfoAck)?;
    send(CHANNEL_MAIN, controller_connection(config.dualsense))?;
    send(CHANNEL_MAIN, client_stream_info())?;
    let _feedback = FeedbackSender::start(
        feedback.clone(),
        link.clone(),
        config.transport_version,
        log.clone(),
    );
    *stage = Stage::Streaming;
    events(StreamEvent::StreamInfo(info));
    events(StreamEvent::Connected);

    let mut next_heartbeat = Instant::now() + t.heartbeat;
    loop {
        let now = Instant::now();
        if now >= next_heartbeat {
            next_heartbeat = now + t.heartbeat;
            if let Err(e) = link.send_message(
                CHANNEL_MAIN,
                data_type::PROTOBUF,
                &Message::Heartbeat.encode(),
            ) {
                log.debug(|| format!("stream: heartbeat failed: {e}"));
            }
        }
        match wait_for(
            shared,
            link,
            next_heartbeat.saturating_duration_since(Instant::now()),
            stop,
            |_| None::<()>,
        ) {
            Wait::Timeout | Wait::Got(()) => {}
            Wait::Stopped => return Err(outcome(QuitReason::Stopped, None, "stopped")),
            Wait::Disconnect(r) => {
                return Err(outcome(
                    QuitReason::for_remote_disconnect(&r),
                    Some(r),
                    "server disconnected",
                ))
            }
            Wait::Down => {
                let why = link.failure().unwrap_or_else(|| "closed".into());
                return Err(outcome(
                    QuitReason::StreamUnknown,
                    None,
                    format!("transport: {why}"),
                ));
            }
        }
    }
}
