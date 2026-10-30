use std::cell::Cell;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

use crate::crypto::random_bytes;
use crate::log::Logger;
use crate::net::POLL_STEP;
use crate::proto::{
    client_disconnect, senkusha_command, Big, Envelope, Message, Senkusha, SenkushaClientMtu,
    SenkushaEcho, SenkushaMtu, TakionProtocolRequest,
};
use crate::transport::packet::{data_type, encode_probe, MediaKind};
use crate::transport::{
    DataMessage, Endpoint, Link, MediaPacket, Transport, TransportConfig, TransportError,
    TransportHandler,
};
use crate::StopToken;

const CHANNEL_MAIN: u16 = 1;
const CHANNEL_SENKUSHA: u16 = 8;
pub const PING_LEN: usize = 548;
const PROBE_FILLER: &[u8] = b"CONMTU";
const TAKION_VERSION: u32 = 9;
const HELLO_FIRST_FRAGMENT: usize = 518;
const HELLO_NEXT_FRAGMENT: usize = 519;
const PONG_TAG_OFFSET: usize = 22;
const IP_UDP_HEADER_LEN: u32 = 28;
const PROBE_UNIT_MASK: u16 = 0x7ff;

const MAX_MTU: u32 = 1454;
pub const FALLBACK_MTU: u32 = MAX_MTU;
pub const FALLBACK_RTT_US: u64 = 1000;
pub const CLOUD_DEFAULT_MTU_IN: u32 = MAX_MTU;
pub const CLOUD_DEFAULT_MTU_OUT: u32 = 1254;

#[derive(Clone, PartialEq, Eq)]
pub enum NetworkTestKind {
    Console,
    CloudProbe { credential: String },
}

impl std::fmt::Debug for NetworkTestKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            NetworkTestKind::Console => f.write_str("Console"),
            NetworkTestKind::CloudProbe { .. } => f.write_str("CloudProbe { .. }"),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Timings {
    pub connect: Duration,
    pub reply: Duration,
    pub hello_echo: Duration,
    pub pings: u32,
    pub pong: Duration,
    pub mtu_min: u32,
    pub mtu_max: u32,
    pub mtu_attempts: u32,
    pub mtu_wait_min: Duration,
    pub mtu_wait_max: Duration,
    pub client_mtu_reply: Duration,
}

impl Timings {
    pub fn console() -> Self {
        Self {
            connect: Duration::from_secs(30),
            reply: Duration::from_secs(5),
            hello_echo: Duration::from_secs(2),
            pings: 10,
            pong: Duration::from_secs(1),
            mtu_min: 576,
            mtu_max: MAX_MTU,
            mtu_attempts: 3,
            mtu_wait_min: Duration::from_millis(5),
            mtu_wait_max: Duration::from_millis(500),
            client_mtu_reply: Duration::from_secs(5),
        }
    }

    pub fn cloud() -> Self {
        Self {
            connect: Duration::from_secs(8),
            pings: 5,
            mtu_attempts: 2,
            mtu_wait_min: Duration::from_millis(200),
            mtu_wait_max: Duration::from_millis(1000),
            client_mtu_reply: Duration::from_millis(1500),
            ..Self::console()
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum TestStage {
    Connect,
    ProtocolRequest,
    Hello,
    Rtt,
    MtuIn,
    MtuOut,
    Done,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NetworkTestReport {
    pub result: Result<NetworkTestResult, NetworkTestError>,
    pub stage: TestStage,
    pub hello_echoed: Option<bool>,
}

#[derive(Debug)]
pub struct NetworkTestConfig {
    pub endpoint: Endpoint,
    pub prefix: u8,
    pub kind: NetworkTestKind,
    pub timings: Timings,
    pub measure_mtu: bool,
    pub log: Logger,
}

impl NetworkTestConfig {
    pub fn console(addr: std::net::SocketAddr) -> Self {
        Self {
            endpoint: Endpoint::Address(addr),
            prefix: 0,
            kind: NetworkTestKind::Console,
            timings: Timings::console(),
            measure_mtu: true,
            log: Logger::default(),
        }
    }

    pub fn cloud_probe(addr: std::net::SocketAddr, credential: String, prefix: u8) -> Self {
        Self {
            endpoint: Endpoint::Address(addr),
            prefix,
            kind: NetworkTestKind::CloudProbe { credential },
            timings: Timings::cloud(),
            measure_mtu: true,
            log: Logger::default(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct NetworkTestResult {
    pub rtt_us: u64,
    pub rtt_samples: u32,
    pub mtu_in: u32,
    pub mtu_out: u32,
}

impl NetworkTestResult {
    pub fn console_fallback() -> Self {
        Self {
            rtt_us: FALLBACK_RTT_US,
            rtt_samples: 0,
            mtu_in: FALLBACK_MTU,
            mtu_out: FALLBACK_MTU,
        }
    }

    pub fn cloud_stream_mtus(&self) -> (u32, u32) {
        (
            if self.mtu_in == 0 {
                CLOUD_DEFAULT_MTU_IN
            } else {
                self.mtu_in
            },
            if self.mtu_out == 0 {
                CLOUD_DEFAULT_MTU_OUT
            } else {
                self.mtu_out
            },
        )
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum NetworkTestError {
    #[error("stopped")]
    Stopped,
    #[error("transport: {0}")]
    Transport(#[from] TransportError),
    #[error("no answer to the {0}")]
    NoReply(&'static str),
    #[error("no round-trip sample")]
    NoRtt,
}

fn stopped_or_transport(e: TransportError) -> NetworkTestError {
    match e {
        TransportError::Stopped => NetworkTestError::Stopped,
        e => NetworkTestError::Transport(e),
    }
}

enum Incoming {
    Message(Envelope),
    Media(MediaPacket),
}

struct Forwarder(Sender<Incoming>);

impl TransportHandler for Forwarder {
    fn on_message(&mut self, _link: &Link, m: DataMessage) {
        if m.data_type != data_type::PROTOBUF {
            return;
        }
        if let Ok(env) = Envelope::decode(&m.data) {
            let _ = self.0.send(Incoming::Message(env));
        }
    }

    fn on_media(&mut self, _link: &Link, p: MediaPacket) {
        let _ = self.0.send(Incoming::Media(p));
    }
}

struct Test<'a> {
    link: Link,
    rx: Receiver<Incoming>,
    timings: Timings,
    cloud: bool,
    measure_mtu: bool,
    stop: &'a StopToken,
    log: Logger,
    stage: Cell<TestStage>,
    hello_echoed: Cell<Option<bool>>,
}

impl Test<'_> {
    fn wait_for<T>(
        &self,
        timeout: Duration,
        mut pick: impl FnMut(&Incoming) -> Option<T>,
    ) -> Result<Option<T>, NetworkTestError> {
        let deadline = Instant::now() + timeout;
        loop {
            if self.stop.is_stopped() {
                return Err(NetworkTestError::Stopped);
            }
            let now = Instant::now();
            if now >= deadline {
                return Ok(None);
            }
            match self.rx.recv_timeout((deadline - now).min(POLL_STEP)) {
                Ok(item) => {
                    if let Some(v) = pick(&item) {
                        return Ok(Some(v));
                    }
                }
                Err(RecvTimeoutError::Timeout) => {
                    if self.link.is_down() {
                        return Err(TransportError::Closed.into());
                    }
                }
                Err(RecvTimeoutError::Disconnected) => return Err(TransportError::Closed.into()),
            }
        }
    }

    fn send(&self, channel: u16, m: &Message) -> Result<u32, NetworkTestError> {
        Ok(self
            .link
            .send_message(channel, data_type::PROTOBUF, &m.encode())?)
    }

    fn send_wait_ack(&self, channel: u16, m: &Message) -> Result<(), NetworkTestError> {
        self.link
            .send_message_wait_ack(
                channel,
                data_type::PROTOBUF,
                &m.encode(),
                self.timings.reply,
                self.stop,
            )
            .map_err(stopped_or_transport)
    }

    fn echo(&self, on: bool) -> Result<(), NetworkTestError> {
        let m = Message::Senkusha(Senkusha {
            command: senkusha_command::ECHO,
            echo: Some(SenkushaEcho { state: on }),
            ..Default::default()
        });
        self.send_wait_ack(CHANNEL_SENKUSHA, &m)
    }

    fn is_pong(&self, p: &MediaPacket, unit: u16, tag: u32) -> bool {
        if p.header.kind == MediaKind::Video || p.header.frame_index != 0 {
            return false;
        }
        let d = &p.datagram;
        if d.len() < p.header.payload_offset + 8 {
            return false;
        }
        let tag_at = |o: usize| d.get(o..o + 4) == Some(&tag.to_be_bytes()[..]);
        if self.cloud {
            tag_at(PONG_TAG_OFFSET) || tag_at(PONG_TAG_OFFSET + 1)
        } else {
            p.header.unit_word.unit_index() == unit && tag_at(PONG_TAG_OFFSET)
        }
    }

    fn probe(
        &self,
        len: usize,
        unit: u16,
        wait: Duration,
        filler: &[u8],
    ) -> Result<Option<Duration>, NetworkTestError> {
        let tag = u32::from_be_bytes(random_bytes());
        let packet = encode_probe(len, 0, unit, tag, filler);
        let sent = Instant::now();
        self.link.send_raw(&packet)?;
        let got = self.wait_for(wait, |i| match i {
            Incoming::Media(p) if self.is_pong(p, unit, tag) => Some(()),
            _ => None,
        })?;
        Ok(got.map(|_| sent.elapsed()))
    }

    fn rtt(&self) -> Result<(u64, u32), NetworkTestError> {
        self.echo(true)?;
        let mut samples = Vec::new();
        for k in 0..self.timings.pings {
            if let Some(rtt) = self.probe(PING_LEN, k as u16, self.timings.pong, &[])? {
                samples.push(rtt);
            }
        }
        self.echo(false)?;
        if samples.is_empty() {
            return Err(NetworkTestError::NoRtt);
        }
        let total: u128 = samples.iter().map(|d| d.as_micros()).sum();
        let mean = (total / samples.len() as u128) as u64;
        Ok((mean, samples.len() as u32))
    }

    fn search(
        &self,
        first: u32,
        mut try_size: impl FnMut(u32) -> Result<bool, NetworkTestError>,
    ) -> Result<Option<(u32, u32)>, NetworkTestError> {
        let (mut min, mut max) = (self.timings.mtu_min, self.timings.mtu_max);
        let mut cur = first.clamp(min, max);
        let mut first_try = true;
        loop {
            let ok = try_size(cur)?;
            if ok {
                min = cur;
            } else {
                max = cur;
            }
            if !ok && first_try && self.cloud && (cur == min || !try_size(min)?) {
                return Ok(None);
            }
            first_try = false;
            if max.saturating_sub(min) <= 1 {
                return Ok(Some((min, max)));
            }
            cur = min + (max - min) / 2;
        }
    }

    fn mtu_in(&self, wait: Duration) -> Result<Option<u32>, NetworkTestError> {
        let mut id = 0u32;
        let r = self.search(self.timings.mtu_max, |cur| {
            for _ in 0..self.timings.mtu_attempts {
                id += 1;
                let m = Message::Senkusha(Senkusha {
                    command: senkusha_command::MTU,
                    mtu: Some(SenkushaMtu {
                        id,
                        requested_mtu: cur,
                        count: Some(1),
                        ..Default::default()
                    }),
                    ..Default::default()
                });
                self.send(CHANNEL_SENKUSHA, &m)?;
                let want = id as u16;
                let got = self.wait_for(wait, |i| match i {
                    Incoming::Media(p)
                        if p.header.kind == MediaKind::Video && p.header.frame_index == want =>
                    {
                        Some(())
                    }
                    _ => None,
                })?;
                if got.is_some() {
                    return Ok(true);
                }
            }
            Ok(false)
        })?;
        Ok(r.map(|(min, _)| min))
    }

    fn mtu_out(&self, inbound: u32, wait: Duration) -> Result<Option<u32>, NetworkTestError> {
        self.send(
            CHANNEL_SENKUSHA,
            &client_mtu_message(1, inbound, true, inbound),
        )?;
        let reply = self.wait_for(self.timings.client_mtu_reply, |i| match i {
            Incoming::Message(env) if env.msg_type == crate::proto::msg_type::SENKUSHA => {
                match Message::from_envelope(env) {
                    Ok(Message::Senkusha(s))
                        if s.command == senkusha_command::CLIENT_MTU
                            && s.client_mtu.as_ref().is_some_and(|c| c.id == 1) =>
                    {
                        Some(())
                    }
                    _ => None,
                }
            }
            _ => None,
        })?;
        if reply.is_none() {
            return Err(NetworkTestError::NoReply("client MTU command"));
        }
        let mut attempt = 0u16;
        let r = self.search(inbound, |cur| {
            for _ in 0..self.timings.mtu_attempts {
                let unit = attempt & PROBE_UNIT_MASK;
                attempt = attempt.wrapping_add(1);
                let len = cur.saturating_sub(IP_UDP_HEADER_LEN) as usize;
                if self.probe(len, unit, wait, PROBE_FILLER)?.is_some() {
                    return Ok(true);
                }
            }
            Ok(false)
        })?;
        let final_max = r.map_or(self.timings.mtu_max, |(_, max)| max);
        self.send_wait_ack(
            CHANNEL_SENKUSHA,
            &client_mtu_message(2, final_max, false, inbound),
        )?;
        Ok(r.map(|(min, _)| min))
    }

    fn run(&self, session_key: String) -> Result<NetworkTestResult, NetworkTestError> {
        if !self.cloud {
            self.stage.set(TestStage::ProtocolRequest);
            let req = Message::TakionProtocolRequest(TakionProtocolRequest {
                supported_versions: vec![TAKION_VERSION],
            });
            self.send(CHANNEL_MAIN, &req)?;
            let ack = self.wait_for(self.timings.reply, |i| match i {
                Incoming::Message(env)
                    if env.msg_type == crate::proto::msg_type::TAKIONPROTOCOLREQUESTACK =>
                {
                    Some(())
                }
                _ => None,
            })?;
            if ack.is_none() {
                return Err(NetworkTestError::NoReply("protocol request"));
            }
        }
        let hello = Message::Big(Big {
            version: TAKION_VERSION,
            session_key,
            launch_spec: String::new(),
            encrypted_key: Vec::new(),
            ecdh_public_key: None,
            ecdh_signature: None,
        })
        .encode();
        self.stage.set(TestStage::Hello);
        if self.cloud {
            match self.link.send_fragmented(
                CHANNEL_MAIN,
                data_type::PROTOBUF,
                &hello,
                HELLO_FIRST_FRAGMENT,
                HELLO_NEXT_FRAGMENT,
            ) {
                Ok(_) | Err(TransportError::SendBufferFull) => {}
                Err(e) => return Err(e.into()),
            }
            let echoed = self.wait_for(self.timings.hello_echo, |i| {
                matches!(i, Incoming::Message(_)).then_some(())
            })?;
            self.hello_echoed.set(Some(echoed.is_some()));
            self.log.debug(|| {
                format!(
                    "network test: hello echo {}",
                    if echoed.is_some() {
                        "received"
                    } else {
                        "missing"
                    }
                )
            });
        } else {
            self.link
                .send_message(CHANNEL_MAIN, data_type::PROTOBUF, &hello)?;
            let bang = self.wait_for(self.timings.reply, |i| match i {
                Incoming::Message(env)
                    if env.msg_type == crate::proto::msg_type::BANG && env.payload.is_some() =>
                {
                    Some(())
                }
                _ => None,
            })?;
            if bang.is_none() {
                return Err(NetworkTestError::NoReply("hello"));
            }
        }

        self.stage.set(TestStage::Rtt);
        let (rtt_us, rtt_samples) = self.rtt()?;
        let wait = Duration::from_micros(rtt_us.saturating_mul(5))
            .clamp(self.timings.mtu_wait_min, self.timings.mtu_wait_max);

        let (mtu_in, mtu_out) = if !self.measure_mtu {
            if self.cloud {
                (0, 0)
            } else {
                (self.timings.mtu_min, self.timings.mtu_min)
            }
        } else if self.cloud {
            self.stage.set(TestStage::MtuIn);
            let mtu_in = self.mtu_in(wait).unwrap_or_else(|e| {
                self.log.debug(|| format!("network test: inbound MTU: {e}"));
                None
            });
            let mtu_out = match mtu_in {
                Some(i) => {
                    self.stage.set(TestStage::MtuOut);
                    self.mtu_out(i, wait).unwrap_or_else(|e| {
                        self.log
                            .debug(|| format!("network test: outbound MTU: {e}"));
                        None
                    })
                }
                None => None,
            };
            (mtu_in.unwrap_or(0), mtu_out.unwrap_or(0))
        } else {
            self.stage.set(TestStage::MtuIn);
            let mtu_in = self.mtu_in(wait)?.unwrap_or(self.timings.mtu_min);
            self.stage.set(TestStage::MtuOut);
            let mtu_out = self.mtu_out(mtu_in, wait)?.unwrap_or(self.timings.mtu_min);
            (mtu_in, mtu_out)
        };
        if self.stop.is_stopped() {
            return Err(NetworkTestError::Stopped);
        }
        let _ = self.send(CHANNEL_MAIN, &client_disconnect());
        self.stage.set(TestStage::Done);
        Ok(NetworkTestResult {
            rtt_us,
            rtt_samples,
            mtu_in,
            mtu_out,
        })
    }
}

fn client_mtu_message(id: u32, requested: u32, state: bool, downstream: u32) -> Message {
    Message::Senkusha(Senkusha {
        command: senkusha_command::CLIENT_MTU,
        client_mtu: Some(SenkushaClientMtu {
            id,
            requested_mtu: requested,
            state,
            downstream_mtu: Some(downstream),
        }),
        ..Default::default()
    })
}

pub fn run(
    config: NetworkTestConfig,
    stop: &StopToken,
) -> Result<NetworkTestResult, NetworkTestError> {
    run_report(config, stop).result
}

pub fn run_report(config: NetworkTestConfig, stop: &StopToken) -> NetworkTestReport {
    let failed = |e: NetworkTestError| NetworkTestReport {
        result: Err(e),
        stage: TestStage::Connect,
        hello_echoed: None,
    };
    let cloud = matches!(config.kind, NetworkTestKind::CloudProbe { .. });
    let session_key = match &config.kind {
        NetworkTestKind::Console => String::new(),
        NetworkTestKind::CloudProbe { credential } => credential.clone(),
    };
    let mut tc = TransportConfig::network_test(match &config.endpoint {
        Endpoint::Address(a) => *a,
        Endpoint::Socket(s) => match s.peer_addr() {
            Ok(a) => a,
            Err(e) => return failed(TransportError::Io(e.to_string()).into()),
        },
    });
    tc.endpoint = config.endpoint;
    tc.prefix = config.prefix;
    tc.log = config.log.clone();
    if cloud {
        tc.media_version = TAKION_VERSION;
        tc.dont_fragment = false;
    }
    let (tx, rx) = mpsc::channel();
    let transport =
        match Transport::connect(tc, Box::new(Forwarder(tx)), config.timings.connect, stop) {
            Ok(t) => t,
            Err(e) => return failed(stopped_or_transport(e)),
        };
    let test = Test {
        link: transport.link(),
        rx,
        timings: config.timings,
        cloud,
        measure_mtu: config.measure_mtu,
        stop,
        log: config.log,
        stage: Cell::new(TestStage::Connect),
        hello_echoed: Cell::new(None),
    };
    let r = test.run(session_key);
    match &r {
        Ok(v) => test.log.info(|| {
            format!(
                "network test: rtt {} us ({} samples), mtu in {}, out {}",
                v.rtt_us, v.rtt_samples, v.mtu_in, v.mtu_out
            )
        }),
        Err(e) => test
            .log
            .info(|| format!("network test failed at {:?}: {e}", test.stage.get())),
    }
    transport.close();
    NetworkTestReport {
        result: r,
        stage: test.stage.get(),
        hello_echoed: test.hello_echoed.get(),
    }
}
