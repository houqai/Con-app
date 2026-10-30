use std::collections::{BTreeMap, VecDeque};
use std::net::{Ipv4Addr, SocketAddr, UdpSocket};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use con_engine::crypto::stream::{DirectionKeys, CLIENT_TO_CONSOLE, CONSOLE_TO_CLIENT};
use con_engine::proto::Message;
use con_engine::transport::crypt::{Opener, Sealer};
use con_engine::transport::packet::{
    chunk_type, encode_control, encode_data_payload, packet_type, parse_congestion, parse_control,
    parse_data_header, DataAck, Init, InitAck, FLAG_LAST_FRAGMENT,
};
use con_engine::transport::reorder::{Assembled, DataMessage, DataWindow, Insert, Reassembler};

pub struct FakeServer {
    pub sock: UdpSocket,
    pub peer: Option<SocketAddr>,
    pub prefix: u8,
    pub tag: u32,
    pub client_tag: u32,
    pub next_tsn: u32,
    window: Option<DataWindow<(u16, u8, Vec<u8>)>>,
    reasm: Reassembler,
    pub sealer: Option<Sealer>,
    pub opener: Option<Opener>,
    pub acked_by_client: Option<u32>,
    pub unacked: BTreeMap<u32, Vec<u8>>,
    pub retransmit: bool,
    last_retransmit: Instant,
    pub ack: bool,
    pub congestion: Vec<(u16, u16)>,
    pub acks_seen: Vec<Vec<u8>>,
    pub data_seen: Vec<Vec<u8>>,
    pub raw_seen: Vec<Vec<u8>>,
    pub messages: VecDeque<DataMessage>,
    pub tag_failures: u32,
}

impl FakeServer {
    pub fn bind() -> Self {
        Self {
            sock: UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap(),
            peer: None,
            prefix: 0,
            tag: 0x5151_0001,
            client_tag: 0,
            next_tsn: 0x5151_0001,
            window: None,
            reasm: Reassembler::new(),
            sealer: None,
            opener: None,
            acked_by_client: None,
            unacked: BTreeMap::new(),
            retransmit: true,
            last_retransmit: Instant::now(),
            ack: true,
            congestion: Vec::new(),
            acks_seen: Vec::new(),
            data_seen: Vec::new(),
            raw_seen: Vec::new(),
            messages: VecDeque::new(),
            tag_failures: 0,
        }
    }

    pub fn addr(&self) -> SocketAddr {
        self.sock.local_addr().unwrap()
    }

    pub fn recv_raw(&mut self, timeout: Duration) -> Option<Vec<u8>> {
        self.sock
            .set_read_timeout(Some(timeout.max(Duration::from_millis(1))))
            .unwrap();
        let mut buf = [0u8; 2048];
        match self.sock.recv_from(&mut buf) {
            Ok((n, from)) => {
                self.peer = Some(from);
                let mut d = buf[..n].to_vec();
                if self.prefix != 0 {
                    assert_eq!(&d[..4], &[0, 0, 0, self.prefix], "datagram prefix");
                    d.drain(..4);
                }
                Some(d)
            }
            Err(_) => None,
        }
    }

    pub fn send_raw(&self, d: &[u8]) {
        let _ = self.sock.send_to(d, self.peer.expect("peer known"));
    }

    fn wait_control(&mut self, deadline: Instant, chunk: u8, what: &str) -> Vec<u8> {
        loop {
            assert!(Instant::now() < deadline, "no {what}");
            let Some(d) = self.recv_raw(Duration::from_millis(100)) else {
                continue;
            };
            if d[0] == packet_type::CONGESTION {
                self.congestion.push(parse_congestion(&d).unwrap());
                continue;
            }
            if parse_control(&d).is_some_and(|cp| cp.chunk == chunk) {
                return d;
            }
        }
    }

    pub fn handshake(&mut self, initial_tsn: Option<u32>) -> Init {
        let deadline = Instant::now() + Duration::from_secs(10);
        let d = self.wait_control(deadline, chunk_type::INIT, "INIT");
        assert_eq!(d.len(), 33);
        let cp = parse_control(&d).unwrap();
        assert_eq!(cp.tag, 0);
        let init = Init::parse(cp.payload).unwrap();
        self.client_tag = init.tag;
        self.window = Some(DataWindow::new(init.initial_tsn));
        let announced = initial_tsn.unwrap_or(self.tag);
        self.next_tsn = announced;
        let ack = InitAck {
            init: Init {
                tag: self.tag,
                window: 0x19000,
                outbound_streams: 100,
                inbound_streams: 100,
                initial_tsn: announced,
            },
            cookie: [0xc0; 32],
        };
        self.send_raw(&ack.packet(init.tag));
        let d = self.wait_control(deadline, chunk_type::COOKIE_ECHO, "COOKIE-ECHO");
        assert_eq!(d.len(), 49);
        let cp = parse_control(&d).unwrap();
        assert_eq!(cp.tag, self.tag);
        assert_eq!(cp.payload, &[0xc0; 32]);
        self.send_raw(&encode_control(init.tag, chunk_type::COOKIE_ACK, 0, &[]));
        init
    }

    pub fn install_keys(&mut self, z: &[u8; 32], hk: &[u8; 16]) {
        self.sealer = Some(Sealer::new(DirectionKeys::derive(z, hk, CONSOLE_TO_CLIENT)));
        self.opener = Some(Opener::new(DirectionKeys::derive(z, hk, CLIENT_TO_CONSOLE)));
    }

    fn verify(&mut self, d: &[u8]) -> bool {
        match self.opener.as_mut() {
            Some(op) => {
                let ok = op.verify(d).is_some();
                if !ok {
                    self.tag_failures += 1;
                }
                ok
            }
            None => true,
        }
    }

    fn retransmit_due(&mut self) {
        if self.retransmit && self.last_retransmit.elapsed() >= Duration::from_millis(100) {
            self.last_retransmit = Instant::now();
            let pending: Vec<Vec<u8>> = self.unacked.values().cloned().collect();
            for p in pending {
                self.send_raw(&p);
            }
        }
    }

    pub fn poll(&mut self, timeout: Duration) -> bool {
        self.retransmit_due();
        let Some(d) = self.recv_raw(timeout.min(Duration::from_millis(20))) else {
            return false;
        };
        self.process(d);
        true
    }

    fn process(&mut self, d: Vec<u8>) {
        let kind = d[0] & 0x0f;
        if kind == packet_type::CONTROL
            && !parse_control(&d)
                .is_some_and(|cp| cp.chunk == chunk_type::DATA || cp.chunk == chunk_type::DATA_ACK)
        {
            return;
        }
        if !self.verify(&d) {
            return;
        }
        match kind {
            packet_type::CONTROL => {
                let cp = parse_control(&d).unwrap();
                match cp.chunk {
                    chunk_type::DATA => {
                        self.data_seen.push(d.clone());
                        let h = parse_data_header(cp.payload).unwrap();
                        let flags = cp.flags;
                        let payload = cp.payload.to_vec();
                        let w = self.window.as_mut().expect("handshake done");
                        match w.insert(h.tsn, (h.channel, flags, payload)) {
                            Insert::Stored => {
                                let mut last = None;
                                while let Some((tsn, (ch, fl, p))) = w.pop_ready() {
                                    last = Some(tsn);
                                    if let Assembled::Message(m) = self.reasm.push(ch, fl, &p) {
                                        self.messages.push_back(m);
                                    }
                                }
                                if self.ack {
                                    if let Some(t) = last {
                                        self.send_ack(t);
                                    }
                                }
                            }
                            Insert::Old if self.ack => {
                                let t = self.window.as_ref().unwrap().start().wrapping_sub(1);
                                self.send_ack(t);
                            }
                            _ => {}
                        }
                    }
                    chunk_type::DATA_ACK => {
                        self.acks_seen.push(d.clone());
                        let a = DataAck::parse(cp.payload).unwrap();
                        self.acked_by_client = Some(a.cumulative_tsn);
                        let c = a.cumulative_tsn;
                        self.unacked
                            .retain(|t, _| c.wrapping_sub(*t) >= 0x8000_0000 && *t != c);
                    }
                    _ => {}
                }
            }
            packet_type::CONGESTION => {
                self.congestion.push(parse_congestion(&d).unwrap());
            }
            _ => self.raw_seen.push(d),
        }
    }

    pub fn send_ack(&mut self, tsn: u32) {
        let mut p = DataAck::client(tsn).packet(self.client_tag);
        if let Some(s) = self.sealer.as_mut() {
            let kp = s.allocate(29);
            s.seal(&mut p, kp);
        }
        self.send_raw(&p);
    }

    pub fn build_chunk(
        &mut self,
        channel: u16,
        flags: u8,
        data_type: Option<u8>,
        data: &[u8],
    ) -> (u32, Vec<u8>) {
        let tsn = self.next_tsn;
        self.next_tsn = tsn.wrapping_add(1);
        let payload = encode_data_payload(tsn, channel, data_type, data);
        let mut p = encode_control(self.client_tag, chunk_type::DATA, flags, &payload);
        if let Some(s) = self.sealer.as_mut() {
            let kp = s.allocate(data.len() as u64);
            s.seal(&mut p, kp);
        }
        if self.retransmit {
            self.unacked.insert(tsn, p.clone());
        }
        (tsn, p)
    }

    pub fn send_message(&mut self, channel: u16, data_type: u8, data: &[u8]) -> u32 {
        let (tsn, p) = self.build_chunk(channel, FLAG_LAST_FRAGMENT, Some(data_type), data);
        self.send_raw(&p);
        tsn
    }

    pub fn send_proto(&mut self, channel: u16, m: &Message) -> u32 {
        self.send_message(channel, 0, &m.encode())
    }

    pub fn build_media(&mut self, mut packet: Vec<u8>, payload_offset: usize) -> Vec<u8> {
        if let Some(s) = self.sealer.as_mut() {
            let n = (packet.len() - payload_offset) as u64;
            let kp = s.allocate(n + 16);
            s.encrypt_payload(&mut packet, payload_offset, kp);
            s.seal(&mut packet, kp);
        }
        packet
    }

    pub fn recv_message(&mut self, timeout: Duration) -> Option<DataMessage> {
        let deadline = Instant::now() + timeout;
        loop {
            if let Some(m) = self.messages.pop_front() {
                return Some(m);
            }
            if Instant::now() >= deadline {
                return None;
            }
            self.poll(deadline - Instant::now());
        }
    }

    pub fn recv_proto(&mut self, timeout: Duration) -> Option<(u16, Message)> {
        let m = self.recv_message(timeout)?;
        assert_eq!(m.data_type, 0, "protobuf data type");
        Some((
            m.channel,
            Message::decode(&m.data).expect("decodable message"),
        ))
    }

    pub fn pump(&mut self, d: Duration) {
        let end = Instant::now() + d;
        while Instant::now() < end {
            self.poll(end - Instant::now());
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Pass,
    Drop,
    Duplicate,
    Delay(usize),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dir {
    ToServer,
    ToClient,
}

pub type Policy = Box<dyn FnMut(Dir, usize, &[u8]) -> Action + Send>;

pub struct Proxy {
    pub addr: SocketAddr,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
    pub counts: Arc<Mutex<(usize, usize)>>,
}

impl Proxy {
    pub fn start(server: SocketAddr, mut policy: Policy) -> Self {
        let sock = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let addr = sock.local_addr().unwrap();
        sock.set_read_timeout(Some(Duration::from_millis(5)))
            .unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let counts = Arc::new(Mutex::new((0, 0)));
        let thread = {
            let stop = stop.clone();
            let counts = counts.clone();
            std::thread::spawn(move || {
                let mut client: Option<SocketAddr> = None;
                let mut held: Vec<(Dir, usize, Vec<u8>)> = Vec::new();
                let mut buf = [0u8; 4096];
                let mut idle = 0;
                let dest = |d: Dir, client: Option<SocketAddr>| match d {
                    Dir::ToServer => Some(server),
                    Dir::ToClient => client,
                };
                while !stop.load(Ordering::SeqCst) {
                    let got = sock.recv_from(&mut buf);
                    let (dir, data) = match got {
                        Ok((n, from)) => {
                            idle = 0;
                            if from == server {
                                (Dir::ToClient, buf[..n].to_vec())
                            } else {
                                client = Some(from);
                                (Dir::ToServer, buf[..n].to_vec())
                            }
                        }
                        Err(_) => {
                            idle += 1;
                            if idle > 20 && !held.is_empty() {
                                for (d, _, p) in held.drain(..) {
                                    if let Some(to) = dest(d, client) {
                                        let _ = sock.send_to(&p, to);
                                    }
                                }
                            }
                            continue;
                        }
                    };
                    let Some(to) = dest(dir, client) else {
                        continue;
                    };
                    let index = {
                        let mut c = counts.lock().unwrap();
                        let i = match dir {
                            Dir::ToServer => &mut c.0,
                            Dir::ToClient => &mut c.1,
                        };
                        *i += 1;
                        *i - 1
                    };
                    match policy(dir, index, &data) {
                        Action::Pass => {
                            let _ = sock.send_to(&data, to);
                        }
                        Action::Drop => {}
                        Action::Duplicate => {
                            let _ = sock.send_to(&data, to);
                            let _ = sock.send_to(&data, to);
                        }
                        Action::Delay(n) => held.push((dir, n, data)),
                    }
                    let mut i = 0;
                    while i < held.len() {
                        if held[i].0 == dir {
                            if held[i].1 == 0 {
                                let (_, _, p) = held.remove(i);
                                let _ = sock.send_to(&p, to);
                                continue;
                            }
                            held[i].1 -= 1;
                        }
                        i += 1;
                    }
                }
            })
        };
        Self {
            addr,
            stop,
            thread: Some(thread),
            counts,
        }
    }
}

impl Drop for Proxy {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}
