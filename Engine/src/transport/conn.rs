use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use super::crypt::{Opener, Sealer};
use super::loss::{report_values, AudioLossCounter, VideoLossCounter};
use super::packet::{
    chunk_type, encode_congestion, encode_control, encode_data_payload, encode_feedback,
    encode_microphone, microphone_payload_offset, packet_type, parse_control, parse_data_header,
    parse_media, DataAck, Init, InitAck, MediaHeader, MediaKind, UnitWord, FEEDBACK_HEADER_LEN,
    FLAG_LAST_FRAGMENT,
};
use super::reorder::{Assembled, DataMessage, DataWindow, Insert, Reassembler};
use super::sendbuf::{RttStats, SendBuffer};
use super::seq::tsn_after;
use super::video::{VideoReorder, VideoReorderStats};
use super::{
    CongestionConfig, Endpoint, HandshakeTiming, TransportConfig, TransportError, TransportStats,
    HELD_MEDIA_MAX, READ_BUFFER,
};
use crate::crypto::random_bytes;
use crate::crypto::stream::{DirectionKeys, StreamKeys};
use crate::log::Logger;
use crate::net::UdpSock;
use crate::sync::lock;
use crate::StopToken;

const POLL_CAP: Duration = Duration::from_millis(50);
const CHUNK_TYPE_OFFSET: usize = 13;

pub trait TransportHandler: Send + 'static {
    fn on_message(&mut self, link: &Link, message: DataMessage);

    fn on_media(&mut self, link: &Link, packet: MediaPacket) {
        let _ = (link, packet);
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MediaPacket {
    pub header: MediaHeader,
    pub key_position: u64,
    pub datagram: Vec<u8>,
}

impl MediaPacket {
    pub fn payload(&self) -> &[u8] {
        &self.datagram[self.header.payload_offset..]
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum LinkState {
    Handshaking,
    Established,
    Failed(String),
    Closed,
}

impl LinkState {
    fn is_down(&self) -> bool {
        matches!(self, LinkState::Failed(_) | LinkState::Closed)
    }
}

struct SendSide {
    state: LinkState,
    peer_tag: u32,
    next_tsn: u32,
    sealer: Option<Sealer>,
    buffer: SendBuffer,
    acked: Option<u32>,
    rtt: RttStats,
    state_seq: u16,
    history_seq: u16,
    mic_counter: u16,
    sent: u64,
    retransmissions: u64,
    given_up: u64,
    reports: u64,
    last_report: (u16, u16),
}

#[derive(Default)]
struct RecvStats {
    received: u64,
    tag_failures: u64,
    dropped: u64,
    held_media_dropped: u64,
    messages: u64,
    media: u64,
    video: VideoReorderStats,
    remote_key_position: u64,
}

struct Shared {
    sock: UdpSock,
    prefix: u8,
    send: Mutex<SendSide>,
    cond: Condvar,
    pending_remote: Mutex<Option<DirectionKeys>>,
    closing: AtomicBool,
    recv: Mutex<RecvStats>,
    log: Logger,
}

fn seal(side: &mut SendSide, packet: &mut [u8], len: u64) {
    if let Some(sealer) = side.sealer.as_mut() {
        let kp = sealer.allocate(len);
        sealer.seal(packet, kp);
    }
}

#[derive(Clone)]
pub struct Link {
    shared: Arc<Shared>,
}

impl std::fmt::Debug for Link {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Link { .. }")
    }
}

impl Link {
    fn side(&self) -> MutexGuard<'_, SendSide> {
        lock(&self.shared.send)
    }

    fn transmit(&self, side: &mut SendSide, packet: &[u8]) {
        let r = if self.shared.prefix != 0 {
            let mut b = Vec::with_capacity(packet.len() + 4);
            b.extend_from_slice(&[0, 0, 0, self.shared.prefix]);
            b.extend_from_slice(packet);
            self.shared.sock.send(&b)
        } else {
            self.shared.sock.send(packet)
        };
        side.sent += 1;
        if let Err(e) = r {
            self.shared
                .log
                .debug(|| format!("transport: send failed: {e}"));
        }
    }

    fn check_established(side: &SendSide) -> Result<(), TransportError> {
        match &side.state {
            LinkState::Established => Ok(()),
            LinkState::Handshaking => Err(TransportError::NotConnected),
            LinkState::Failed(_) | LinkState::Closed => Err(TransportError::Closed),
        }
    }

    pub fn is_established(&self) -> bool {
        self.side().state == LinkState::Established
    }

    pub fn failure(&self) -> Option<String> {
        match &self.side().state {
            LinkState::Failed(r) => Some(r.clone()),
            _ => None,
        }
    }

    pub fn is_down(&self) -> bool {
        self.side().state.is_down()
    }

    fn send_chunk(
        &self,
        side: &mut SendSide,
        channel: u16,
        flags: u8,
        data_type: Option<u8>,
        data: &[u8],
    ) -> (u32, bool) {
        self.send_chunk_copies(side, channel, flags, data_type, data, 1)
    }

    fn send_chunk_copies(
        &self,
        side: &mut SendSide,
        channel: u16,
        flags: u8,
        data_type: Option<u8>,
        data: &[u8],
        copies: usize,
    ) -> (u32, bool) {
        let tsn = side.next_tsn;
        side.next_tsn = tsn.wrapping_add(1);
        let payload = encode_data_payload(tsn, channel, data_type, data);
        let mut packet = encode_control(side.peer_tag, chunk_type::DATA, flags, &payload);
        seal(side, &mut packet, data.len() as u64);
        for _ in 0..copies.max(1) {
            self.transmit(side, &packet);
        }
        let stored = side.buffer.push(tsn, packet, Instant::now());
        (tsn, stored)
    }

    pub fn send_message_twice(
        &self,
        channel: u16,
        data_type: u8,
        data: &[u8],
    ) -> Result<u32, TransportError> {
        let mut side = self.side();
        Self::check_established(&side)?;
        let (tsn, stored) = self.send_chunk_copies(
            &mut side,
            channel,
            FLAG_LAST_FRAGMENT,
            Some(data_type),
            data,
            2,
        );
        if stored {
            Ok(tsn)
        } else {
            Err(TransportError::SendBufferFull)
        }
    }

    pub fn send_message(
        &self,
        channel: u16,
        data_type: u8,
        data: &[u8],
    ) -> Result<u32, TransportError> {
        self.send_fragmented(channel, data_type, data, usize::MAX, usize::MAX)
    }

    pub fn send_fragmented(
        &self,
        channel: u16,
        data_type: u8,
        data: &[u8],
        first_max: usize,
        cont_max: usize,
    ) -> Result<u32, TransportError> {
        let mut side = self.side();
        Self::check_established(&side)?;
        let first_max = first_max.max(1);
        let cont_max = cont_max.max(1);
        let mut all_stored = true;
        let last = if data.len() <= first_max {
            let (tsn, ok) = self.send_chunk(
                &mut side,
                channel,
                FLAG_LAST_FRAGMENT,
                Some(data_type),
                data,
            );
            all_stored &= ok;
            tsn
        } else {
            let (_, ok) =
                self.send_chunk(&mut side, channel, 0, Some(data_type), &data[..first_max]);
            all_stored &= ok;
            let mut rest = &data[first_max..];
            while rest.len() > cont_max {
                let (_, ok) = self.send_chunk(&mut side, channel, 0, None, &rest[..cont_max]);
                all_stored &= ok;
                rest = &rest[cont_max..];
            }
            let (tsn, ok) = self.send_chunk(&mut side, channel, FLAG_LAST_FRAGMENT, None, rest);
            all_stored &= ok;
            tsn
        };
        if all_stored {
            Ok(last)
        } else {
            Err(TransportError::SendBufferFull)
        }
    }

    pub fn wait_ack(
        &self,
        tsn: u32,
        timeout: Duration,
        stop: &StopToken,
    ) -> Result<(), TransportError> {
        let deadline = Instant::now() + timeout;
        let mut side = self.side();
        loop {
            if side.acked.is_some_and(|a| a == tsn || tsn_after(a, tsn)) {
                return Ok(());
            }
            if stop.is_stopped() {
                return Err(TransportError::Stopped);
            }
            if side.state.is_down() {
                return Err(TransportError::Closed);
            }
            let now = Instant::now();
            if now >= deadline {
                return Err(TransportError::Timeout("acknowledgement"));
            }
            side = self
                .shared
                .cond
                .wait_timeout(side, (deadline - now).min(POLL_CAP))
                .unwrap_or_else(|p| p.into_inner())
                .0;
        }
    }

    pub fn send_message_wait_ack(
        &self,
        channel: u16,
        data_type: u8,
        data: &[u8],
        timeout: Duration,
        stop: &StopToken,
    ) -> Result<(), TransportError> {
        let tsn = match self.send_message(channel, data_type, data) {
            Ok(t) => t,
            Err(TransportError::SendBufferFull) => self.side().next_tsn.wrapping_sub(1),
            Err(e) => return Err(e),
        };
        self.wait_ack(tsn, timeout, stop)
    }

    pub fn send_raw(&self, packet: &[u8]) -> Result<(), TransportError> {
        let mut side = self.side();
        if side.state.is_down() {
            return Err(TransportError::Closed);
        }
        self.transmit(&mut side, packet);
        Ok(())
    }

    fn send_encrypted_unreliable(
        &self,
        mut packet: Vec<u8>,
        payload_offset: usize,
    ) -> Result<(), TransportError> {
        let mut side = self.side();
        Self::check_established(&side)?;
        let n = (packet.len() - payload_offset) as u64;
        if let Some(sealer) = side.sealer.as_mut() {
            let kp = sealer.allocate(n + 16);
            sealer.encrypt_payload(&mut packet, payload_offset, kp);
            sealer.seal(&mut packet, kp);
        }
        self.transmit(&mut side, &packet);
        Ok(())
    }

    fn next_counter(&self, pick: impl FnOnce(&mut SendSide) -> &mut u16) -> u16 {
        let mut side = self.side();
        let counter = pick(&mut side);
        let v = *counter;
        *counter = v.wrapping_add(1);
        v
    }

    pub fn send_feedback_state(&self, payload: &[u8]) -> Result<(), TransportError> {
        let seq = self.next_counter(|s| &mut s.state_seq);
        let packet = encode_feedback(packet_type::FEEDBACK_STATE, seq, payload);
        self.send_encrypted_unreliable(packet, FEEDBACK_HEADER_LEN)
    }

    pub fn send_feedback_history(&self, payload: &[u8]) -> Result<(), TransportError> {
        let seq = self.next_counter(|s| &mut s.history_seq);
        let packet = encode_feedback(packet_type::FEEDBACK_HISTORY, seq, payload);
        self.send_encrypted_unreliable(packet, FEEDBACK_HEADER_LEN)
    }

    pub fn send_microphone(&self, payload: &[u8], ps5: bool) -> Result<(), TransportError> {
        let counter = self.next_counter(|s| &mut s.mic_counter);
        let packet = encode_microphone(counter, ps5, payload);
        self.send_encrypted_unreliable(packet, microphone_payload_offset(ps5))
    }

    pub fn install_keys(&self, keys: StreamKeys) {
        self.side().sealer = Some(Sealer::new(keys.local));
        *lock(&self.shared.pending_remote) = Some(keys.remote);
    }

    fn send_ack(&self, tsn: u32) {
        let mut side = self.side();
        let mut packet = DataAck::client(tsn).packet(side.peer_tag);
        let len = packet.len() as u64;
        seal(&mut side, &mut packet, len);
        self.transmit(&mut side, &packet);
    }

    fn send_congestion(&self, received: u16, lost: u16) {
        let mut side = self.side();
        let mut packet = encode_congestion(received, lost).to_vec();
        let len = packet.len() as u64;
        seal(&mut side, &mut packet, len);
        self.transmit(&mut side, &packet);
        side.reports += 1;
        side.last_report = (received, lost);
    }

    fn on_ack(&self, cumulative: u32, now: Instant) {
        let mut side = self.side();
        for sample in side.buffer.acknowledge(cumulative, now) {
            side.rtt.record(sample);
        }
        side.acked = Some(match side.acked {
            Some(a) if tsn_after(a, cumulative) => a,
            _ => cumulative,
        });
        drop(side);
        self.shared.cond.notify_all();
    }

    pub fn stats(&self) -> TransportStats {
        let side = self.side();
        let recv = lock(&self.shared.recv);
        TransportStats {
            rtt_latest_us: side.rtt.latest_us(),
            rtt_samples: side.rtt.samples(),
            rtt_median_us: side.rtt.median_us(),
            datagrams_sent: side.sent,
            datagrams_received: recv.received,
            retransmissions: side.retransmissions,
            given_up: side.given_up,
            tag_failures: recv.tag_failures,
            dropped: recv.dropped,
            held_media_dropped: recv.held_media_dropped,
            messages_delivered: recv.messages,
            media_delivered: recv.media,
            congestion_reports: side.reports,
            last_report: side.last_report,
            video: recv.video,
            local_key_position: side.sealer.as_ref().map_or(0, |s| s.position()),
            remote_key_position: recv.remote_key_position,
        }
    }
}

pub struct Transport {
    link: Link,
    thread: Option<JoinHandle<()>>,
}

impl std::fmt::Debug for Transport {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Transport { .. }")
    }
}

impl Transport {
    pub fn start(
        config: TransportConfig,
        handler: Box<dyn TransportHandler>,
    ) -> Result<Transport, TransportError> {
        let io = |e: std::io::Error| TransportError::Io(e.to_string());
        let log = config.log.clone();
        let sock = match config.endpoint {
            Endpoint::Address(addr) => {
                let s = UdpSock::bind_for_peer(&addr).map_err(io)?;
                s.connect(addr).map_err(io)?;
                s
            }
            Endpoint::Socket(s) => {
                let s = UdpSock::from_std(s);
                let n = s
                    .drain(Duration::from_millis(200), Duration::from_secs(1))
                    .map_err(io)?;
                log.debug(|| format!("transport: drained {n} queued datagrams"));
                s
            }
        };
        if let Err(e) = sock.set_recv_buffer(config.recv_buffer) {
            log.debug(|| format!("transport: receive buffer not set: {e}"));
        }
        if let Err(e) = sock.set_dont_fragment(config.dont_fragment) {
            log.debug(|| format!("transport: don't-fragment not set: {e}"));
        }
        if let Err(e) = sock.set_interactive_video() {
            log.debug(|| format!("transport: service class not set: {e}"));
        }
        let own_tag = config
            .client_tag
            .filter(|t| *t != 0)
            .unwrap_or_else(|| loop {
                let t = u32::from_be_bytes(random_bytes());
                if t != 0 {
                    break t;
                }
            });
        let recv_sock = sock.try_clone().map_err(io)?;
        let shared = Arc::new(Shared {
            sock,
            prefix: config.prefix,
            send: Mutex::new(SendSide {
                state: LinkState::Handshaking,
                peer_tag: 0,
                next_tsn: own_tag,
                sealer: None,
                buffer: SendBuffer::new(config.retransmit),
                acked: None,
                rtt: RttStats::with_initial(config.initial_rtt_us.unwrap_or(0)),
                state_seq: 0,
                history_seq: 0,
                mic_counter: 0,
                sent: 0,
                retransmissions: 0,
                given_up: 0,
                reports: 0,
                last_report: (0, 0),
            }),
            cond: Condvar::new(),
            pending_remote: Mutex::new(None),
            closing: AtomicBool::new(false),
            recv: Mutex::new(RecvStats::default()),
            log: log.clone(),
        });
        let link = Link {
            shared: shared.clone(),
        };
        let now = Instant::now();
        let worker = Worker {
            link: link.clone(),
            sock: recv_sock,
            handler,
            own_tag,
            version: config.media_version,
            encrypted: config.encrypted,
            reorder_video: config.reorder_video,
            discard_video: config.discard_video,
            discard_audio: config.discard_audio,
            cloud_tsn: config.initial_tsn_from_init_ack,
            handshake: config.handshake,
            hs: Hs::Done,
            check_interval: config.retransmit.check_interval,
            congestion: config.congestion,
            window: DataWindow::new(0),
            reasm: Reassembler::new(),
            opener: None,
            last_delivered: None,
            held_media: VecDeque::new(),
            video: VideoReorder::new(config.video_wait),
            video_loss: VideoLossCounter::new(),
            audio_loss: AudioLossCounter::new(
                config.congestion.map(|c| c.audio).unwrap_or_default(),
            ),
            next_check: now,
            next_report: config.congestion.map(|c| now + c.interval),
            log,
            markers_seen: [false; 256],
        };
        let thread =
            crate::threads::spawn(crate::threads::ThreadRole::Io, "con-transport", move || {
                worker.run()
            })
            .map_err(io)?;
        Ok(Transport {
            link,
            thread: Some(thread),
        })
    }

    pub fn connect(
        config: TransportConfig,
        handler: Box<dyn TransportHandler>,
        timeout: Duration,
        stop: &StopToken,
    ) -> Result<Transport, TransportError> {
        let t = Self::start(config, handler)?;
        t.wait_established(timeout, stop)?;
        Ok(t)
    }

    pub fn wait_established(
        &self,
        timeout: Duration,
        stop: &StopToken,
    ) -> Result<(), TransportError> {
        let deadline = Instant::now() + timeout;
        let mut side = self.link.side();
        loop {
            match &side.state {
                LinkState::Established => return Ok(()),
                LinkState::Failed(r) => return Err(TransportError::Handshake(r.clone())),
                LinkState::Closed => return Err(TransportError::Closed),
                LinkState::Handshaking => {}
            }
            if stop.is_stopped() {
                return Err(TransportError::Stopped);
            }
            let now = Instant::now();
            if now >= deadline {
                return Err(TransportError::Timeout("handshake"));
            }
            side = self
                .link
                .shared
                .cond
                .wait_timeout(side, (deadline - now).min(POLL_CAP))
                .unwrap_or_else(|p| p.into_inner())
                .0;
        }
    }

    pub fn link(&self) -> Link {
        self.link.clone()
    }

    pub fn close(self) {
        drop(self);
    }

    fn shutdown(&mut self) {
        self.link.shared.closing.store(true, Ordering::SeqCst);
        {
            let mut side = self.link.side();
            if !matches!(side.state, LinkState::Failed(_)) {
                side.state = LinkState::Closed;
            }
        }
        self.link.shared.cond.notify_all();
        if let Some(h) = self.thread.take() {
            if h.thread().id() != std::thread::current().id() {
                let _ = h.join();
            }
        }
    }
}

impl Drop for Transport {
    fn drop(&mut self) {
        self.shutdown();
    }
}

enum Hs {
    Init {
        attempt: u32,
        sent: Instant,
        packet: Vec<u8>,
    },
    Cookie {
        attempt: u32,
        sent: Instant,
        packet: Vec<u8>,
    },
    Done,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Verified {
    NoKeys,
    Key(u64),
    BadTag,
}

struct Held {
    channel: u16,
    flags: u8,
    payload: Vec<u8>,
    raw: Option<Vec<u8>>,
}

struct Worker {
    link: Link,
    sock: UdpSock,
    handler: Box<dyn TransportHandler>,
    own_tag: u32,
    version: u32,
    encrypted: bool,
    reorder_video: bool,
    discard_video: bool,
    discard_audio: bool,
    cloud_tsn: bool,
    handshake: HandshakeTiming,
    hs: Hs,
    check_interval: Duration,
    congestion: Option<CongestionConfig>,
    window: DataWindow<Held>,
    reasm: Reassembler,
    opener: Option<Opener>,
    last_delivered: Option<u32>,
    held_media: VecDeque<Vec<u8>>,
    video: VideoReorder<MediaPacket>,
    video_loss: VideoLossCounter,
    audio_loss: AudioLossCounter,
    next_check: Instant,
    next_report: Option<Instant>,
    log: Logger,
    markers_seen: [bool; 256],
}

fn ceil_ms(d: Duration) -> Duration {
    let ms = d.as_micros().div_ceil(1000).max(1);
    Duration::from_millis(ms as u64)
}

impl Worker {
    fn recv_stats(&self) -> MutexGuard<'_, RecvStats> {
        lock(&self.link.shared.recv)
    }

    fn dropped(&self) {
        self.recv_stats().dropped += 1;
    }

    fn fail(&mut self, reason: String) {
        self.log.warn(|| format!("transport: {reason}"));
        let mut side = self.link.side();
        if side.state != LinkState::Closed {
            side.state = LinkState::Failed(reason);
        }
        drop(side);
        self.link.shared.cond.notify_all();
    }

    fn run(mut self) {
        let init = Init::client(self.own_tag).packet();
        self.send_handshake(&init);
        self.hs = Hs::Init {
            attempt: 1,
            sent: Instant::now(),
            packet: init,
        };
        let mut buf = vec![0u8; READ_BUFFER];
        loop {
            if self.link.shared.closing.load(Ordering::SeqCst) || self.link.is_down() {
                break;
            }
            let now = Instant::now();
            self.timers(now);
            if self.link.is_down() {
                break;
            }
            let wait = self.next_wake(Instant::now());
            match self.sock.recv(&mut buf, wait) {
                Ok(Some(n)) => {
                    let d = buf[..n].to_vec();
                    self.on_datagram(d, Instant::now());
                }
                Ok(None) => {}
                Err(e) => {
                    if !self.link.shared.closing.load(Ordering::SeqCst) {
                        self.fail(format!("receiving: {e}"));
                    }
                    break;
                }
            }
        }
    }

    fn send_handshake(&self, packet: &[u8]) {
        let mut side = self.link.side();
        self.link.transmit(&mut side, packet);
    }

    fn next_wake(&self, now: Instant) -> Duration {
        let mut next = now + POLL_CAP;
        match &self.hs {
            Hs::Init { sent, .. } | Hs::Cookie { sent, .. } => {
                next = next.min(*sent + self.handshake.attempt_timeout);
            }
            Hs::Done => {
                next = next.min(self.next_check);
                if let Some(d) = self.video.deadline() {
                    next = next.min(d);
                }
            }
        }
        if let Some(r) = self.next_report {
            next = next.min(r);
        }
        ceil_ms(next.saturating_duration_since(now))
    }

    fn timers(&mut self, now: Instant) {
        match &self.hs {
            Hs::Init { sent, .. } | Hs::Cookie { sent, .. } => {
                if now >= *sent + self.handshake.attempt_timeout {
                    self.failed_attempt(now);
                }
            }
            Hs::Done => {
                if now >= self.next_check {
                    self.next_check = now + self.check_interval;
                    let link = self.link.clone();
                    let mut side = link.side();
                    let r = side.buffer.check(now);
                    side.given_up += r.given_up as u64;
                    side.retransmissions += r.resend.len() as u64;
                    for d in &r.resend {
                        link.transmit(&mut side, d);
                    }
                }
                let mut out = Vec::new();
                self.video.poll(now, &mut out);
                self.recv_stats().video = self.video.stats();
                for p in out {
                    self.deliver_video(p);
                }
            }
        }
        if let (Some(at), Some(cfg)) = (self.next_report, self.congestion) {
            if now >= at {
                let next = at + cfg.interval;
                self.next_report = Some(if next <= now {
                    now + cfg.interval
                } else {
                    next
                });
                let (vr, vl) = self.video_loss.take();
                let (ar, al) = self.audio_loss.take();
                let (r, l) = report_values(vr + ar, vl + al, cfg.margin, cfg.ceiling);
                self.link.send_congestion(r, l);
            }
        }
    }

    fn failed_attempt(&mut self, now: Instant) {
        let max = self.handshake.attempts;
        let (step, attempt, packet) = match &self.hs {
            Hs::Init {
                attempt, packet, ..
            } => ("INIT-ACK", *attempt, packet.clone()),
            Hs::Cookie {
                attempt, packet, ..
            } => ("COOKIE-ACK", *attempt, packet.clone()),
            Hs::Done => return,
        };
        if attempt >= max {
            self.fail(format!("no valid {step} after {attempt} attempts"));
            return;
        }
        self.log
            .debug(|| format!("transport: no valid {step}, attempt {}", attempt + 1));
        self.send_handshake(&packet);
        self.hs = match self.hs {
            Hs::Init { .. } => Hs::Init {
                attempt: attempt + 1,
                sent: now,
                packet,
            },
            _ => Hs::Cookie {
                attempt: attempt + 1,
                sent: now,
                packet,
            },
        };
    }

    fn on_datagram(&mut self, d: Vec<u8>, now: Instant) {
        self.recv_stats().received += 1;
        match self.hs {
            Hs::Init { .. } => self.on_init_reply(&d, now),
            Hs::Cookie { .. } => self.on_cookie_reply(&d, now),
            Hs::Done => self.on_packet(d, now),
        }
    }

    fn parse_init_ack(&self, d: &[u8]) -> Option<InitAck> {
        let cp = parse_control(d)?;
        if cp.chunk != chunk_type::INIT_ACK || cp.flags != 0 || cp.tag != self.own_tag {
            return None;
        }
        InitAck::parse(cp.payload).filter(InitAck::acceptable)
    }

    fn on_init_reply(&mut self, d: &[u8], now: Instant) {
        let Some(ack) = self.parse_init_ack(d) else {
            self.failed_attempt(now);
            return;
        };
        let start = if self.cloud_tsn {
            ack.init.initial_tsn
        } else {
            ack.init.tag
        };
        self.window = DataWindow::new(start);
        self.link.side().peer_tag = ack.init.tag;
        let echo = encode_control(ack.init.tag, chunk_type::COOKIE_ECHO, 0, &ack.cookie);
        self.send_handshake(&echo);
        self.hs = Hs::Cookie {
            attempt: 1,
            sent: now,
            packet: echo,
        };
    }

    fn on_cookie_reply(&mut self, d: &[u8], now: Instant) {
        if d.len() > CHUNK_TYPE_OFFSET
            && d[0] & 0x0f == packet_type::CONTROL
            && d[CHUNK_TYPE_OFFSET] == chunk_type::INIT_ACK
        {
            return;
        }
        let valid = parse_control(d).is_some_and(|cp| {
            cp.chunk == chunk_type::COOKIE_ACK
                && cp.flags == 0
                && cp.tag == self.own_tag
                && cp.payload.is_empty()
        });
        if !valid {
            self.failed_attempt(now);
            return;
        }
        self.hs = Hs::Done;
        self.next_check = now + self.check_interval;
        {
            let mut side = self.link.side();
            if side.state == LinkState::Handshaking {
                side.state = LinkState::Established;
            }
        }
        self.link.shared.cond.notify_all();
        self.log.debug(|| "transport: connected".into());
    }

    fn on_packet(&mut self, d: Vec<u8>, now: Instant) {
        let Some(&b0) = d.first() else {
            self.dropped();
            return;
        };
        match b0 & 0x0f {
            packet_type::CONTROL => self.on_control(&d, now),
            packet_type::VIDEO | packet_type::AUDIO => self.on_media_datagram(d, now),
            _ => self.dropped(),
        }
    }

    fn verify(&mut self, d: &[u8]) -> Verified {
        let Some(op) = self.opener.as_mut() else {
            return Verified::NoKeys;
        };
        let key_position = op.verify(d);
        self.record_tag(key_position)
    }

    fn record_tag(&self, key_position: Option<u64>) -> Verified {
        let mut stats = self.recv_stats();
        match key_position {
            Some(kp) => {
                stats.remote_key_position = kp;
                Verified::Key(kp)
            }
            None => {
                stats.tag_failures += 1;
                Verified::BadTag
            }
        }
    }

    fn on_control(&mut self, d: &[u8], now: Instant) {
        let Some(cp) = parse_control(d) else {
            self.dropped();
            return;
        };
        if cp.tag != self.own_tag {
            self.dropped();
            return;
        }
        match cp.chunk {
            chunk_type::DATA => {
                let Some(h) = parse_data_header(cp.payload) else {
                    self.dropped();
                    return;
                };
                let checked = self.verify(d);
                if checked == Verified::BadTag {
                    return;
                }
                let raw = (checked == Verified::NoKeys && self.encrypted).then(|| d.to_vec());
                let held = Held {
                    channel: h.channel,
                    flags: cp.flags,
                    payload: cp.payload.to_vec(),
                    raw,
                };
                match self.window.insert(h.tsn, held) {
                    Insert::Stored => self.deliver_ready(now),
                    Insert::Old => {
                        if let Some(t) = self.last_delivered {
                            self.link.send_ack(t);
                        }
                    }
                    Insert::Duplicate | Insert::TooFar => self.dropped(),
                }
            }
            chunk_type::DATA_ACK => {
                if self.verify(d) == Verified::BadTag {
                    return;
                }
                match DataAck::parse(cp.payload) {
                    Some(ack) => self.link.on_ack(ack.cumulative_tsn, now),
                    None => self.dropped(),
                }
            }
            chunk_type::INIT_ACK | chunk_type::COOKIE_ACK => {}
            _ => self.dropped(),
        }
    }

    fn deliver_ready(&mut self, now: Instant) {
        let mut last = None;
        while let Some((tsn, held)) = self.window.pop_ready() {
            last = Some(tsn);
            match self.reasm.push(held.channel, held.flags, &held.payload) {
                Assembled::Message(m) => {
                    self.recv_stats().messages += 1;
                    self.handler.on_message(&self.link, m);
                    self.after_handler(now);
                }
                Assembled::Pending => {}
                other => {
                    self.log.debug(|| {
                        format!("transport: fragment of TSN {tsn:#x} dropped ({other:?})")
                    });
                    self.dropped();
                }
            }
        }
        if let Some(t) = last {
            self.last_delivered = Some(t);
            self.link.send_ack(t);
        }
    }

    fn after_handler(&mut self, now: Instant) {
        let keys = lock(&self.link.shared.pending_remote).take();
        let Some(keys) = keys else {
            return;
        };
        let mut opener = Opener::new(keys);
        let mut failures = 0u64;
        self.window.retain(|_, held| match held.raw.take() {
            Some(raw) => {
                let ok = opener.verify(&raw).is_some();
                failures += u64::from(!ok);
                ok
            }
            None => true,
        });
        self.opener = Some(opener);
        self.recv_stats().tag_failures += failures;
        let held: Vec<Vec<u8>> = self.held_media.drain(..).collect();
        for d in held {
            self.on_media_datagram(d, now);
        }
    }

    fn on_media_datagram(&mut self, mut d: Vec<u8>, now: Instant) {
        let Some(h) = parse_media(&d, self.version) else {
            self.dropped();
            return;
        };
        if (self.discard_video && h.kind == MediaKind::Video)
            || (self.discard_audio && h.kind == MediaKind::Audio)
        {
            return;
        }
        let key_position = if self.encrypted {
            let Some(opener) = self.opener.as_mut() else {
                if self.held_media.len() >= HELD_MEDIA_MAX {
                    self.recv_stats().held_media_dropped += 1;
                } else {
                    self.held_media.push_back(d);
                }
                return;
            };
            let key_position = opener.verify(&d);
            if let Some(kp) = key_position {
                opener.decrypt_payload(&mut d, h.payload_offset, kp);
            }
            let Verified::Key(kp) = self.record_tag(key_position) else {
                return;
            };
            kp
        } else {
            u64::from(h.key_pos)
        };
        let packet = MediaPacket {
            header: h,
            key_position,
            datagram: d,
        };
        match h.kind {
            MediaKind::Video if self.reorder_video => {
                let mut out = Vec::new();
                self.video.push(
                    h.packet_index,
                    h.unit_word.unit_index(),
                    packet,
                    now,
                    &mut out,
                );
                self.recv_stats().video = self.video.stats();
                for p in out {
                    self.deliver_video(p);
                }
            }
            MediaKind::Video => self.deliver_video(packet),
            MediaKind::Audio => {
                if let Some(marker) = h.stream_marker {
                    if !self.markers_seen[usize::from(marker)] {
                        self.markers_seen[usize::from(marker)] = true;
                        self.log
                            .info(|| format!("audio: stream marker 0x{marker:02x} seen"));
                    }
                }
                if self.congestion.is_some() && packet.datagram.len() > h.payload_offset {
                    self.audio_loss.count(h.frame_index);
                }
                self.deliver_media(packet);
            }
            MediaKind::Haptics => self.deliver_media(packet),
        }
    }

    fn deliver_video(&mut self, p: MediaPacket) {
        if let UnitWord::Video {
            unit_index,
            units_total,
            fec_units,
        } = p.header.unit_word
        {
            self.video_loss
                .count(p.header.frame_index, unit_index, units_total, fec_units);
        }
        self.deliver_media(p);
    }

    fn deliver_media(&mut self, p: MediaPacket) {
        self.recv_stats().media += 1;
        self.handler.on_media(&self.link, p);
    }
}
