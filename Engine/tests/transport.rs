mod common;
use common::media::media_packet;
use common::takion::{Action, Dir, FakeServer, Proxy};

use std::collections::BTreeSet;
use std::net::{Ipv4Addr, SocketAddr, UdpSocket};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::Arc;
use std::time::{Duration, Instant};

use con_engine::crypto::stream::{DirectionKeys, StreamKeys};
use con_engine::transport::crypt::Sealer;
use con_engine::transport::packet::{
    chunk_type, encode_control, parse_control, parse_data_header, video_unit_word, Init, InitAck,
    MediaKind, FLAG_LAST_FRAGMENT,
};
use con_engine::transport::{
    CongestionConfig, DataMessage, Endpoint, HandshakeTiming, Link, MediaPacket, RetransmitConfig,
    Transport, TransportConfig, TransportError, TransportHandler,
};
use con_engine::StopToken;

const SECOND: Duration = Duration::from_secs(1);

#[derive(Debug)]
enum Got {
    Msg(DataMessage),
    Media(MediaPacket),
}

struct H {
    tx: Sender<Got>,
    keys_on: Option<(u8, StreamKeys)>,
}

impl TransportHandler for H {
    fn on_message(&mut self, link: &Link, m: DataMessage) {
        if let Some((ty, keys)) = &self.keys_on {
            if m.data_type == *ty {
                link.install_keys(keys.clone());
            }
        }
        let _ = self.tx.send(Got::Msg(m));
    }
    fn on_media(&mut self, _link: &Link, p: MediaPacket) {
        let _ = self.tx.send(Got::Media(p));
    }
}

fn handler(keys_on: Option<(u8, StreamKeys)>) -> (Box<H>, Receiver<Got>) {
    let (tx, rx) = mpsc::channel();
    (Box::new(H { tx, keys_on }), rx)
}

fn config(addr: SocketAddr) -> TransportConfig {
    let mut c = TransportConfig::console_stream(addr, 12);
    c.encrypted = false;
    c.congestion = None;
    c.handshake = HandshakeTiming {
        attempt_timeout: Duration::from_millis(300),
        attempts: 3,
    };
    c
}

fn connect(server: &mut FakeServer, cfg: TransportConfig, h: Box<H>) -> Transport {
    let t = Transport::start(cfg, h).unwrap();
    server.handshake(None);
    t.wait_established(5 * SECOND, &StopToken::new()).unwrap();
    t
}

fn next_msg(rx: &Receiver<Got>) -> DataMessage {
    loop {
        match rx.recv_timeout(5 * SECOND).expect("message") {
            Got::Msg(m) => return m,
            Got::Media(_) => {}
        }
    }
}

fn next_media(rx: &Receiver<Got>) -> MediaPacket {
    loop {
        match rx.recv_timeout(5 * SECOND).expect("media") {
            Got::Media(p) => return p,
            Got::Msg(_) => {}
        }
    }
}

fn shared_secret() -> [u8; 32] {
    std::array::from_fn(|i| (i * 7) as u8)
}

const HANDSHAKE_KEY: [u8; 16] = [0x42; 16];

fn is_data(d: &[u8]) -> bool {
    parse_control(d).map(|c| c.chunk) == Some(chunk_type::DATA)
}

fn next_data(s: &mut FakeServer, what: &str) -> (Instant, Vec<u8>) {
    loop {
        let d = s.recv_raw(SECOND).expect(what);
        if is_data(&d) {
            return (Instant::now(), d);
        }
    }
}

#[test]
fn handshake_and_packet_layouts() {
    let mut s = FakeServer::bind();
    let mut cfg = config(s.addr());
    cfg.client_tag = Some(0x0102_0304);
    let (h, rx) = handler(None);
    let t = Transport::start(cfg, h).unwrap();
    let init = s.handshake(None);
    assert_eq!(
        init,
        Init {
            tag: 0x0102_0304,
            window: 0x19000,
            outbound_streams: 100,
            inbound_streams: 100,
            initial_tsn: 0x0102_0304
        }
    );
    t.wait_established(5 * SECOND, &StopToken::new()).unwrap();
    let link = t.link();
    let tsn = link.send_message(1, 0, &[0x08, 0x03]).unwrap();
    assert_eq!(tsn, 0x0102_0304);
    let m = s.recv_message(5 * SECOND).unwrap();
    assert_eq!((m.channel, m.data_type, m.data), (1, 0, vec![0x08, 0x03]));
    let d = &s.data_seen[0];
    assert_eq!(d.len(), 28);
    let cp = parse_control(d).unwrap();
    assert_eq!(cp.tag, s.tag);
    assert_eq!(cp.flags, FLAG_LAST_FRAGMENT);
    s.send_message(1, 0, &[1, 2, 3]);
    let m = next_msg(&rx);
    assert_eq!(m.data, vec![1, 2, 3]);
    let deadline = Instant::now() + 5 * SECOND;
    while s.acked_by_client.is_none() && Instant::now() < deadline {
        s.poll(SECOND);
    }
    assert_eq!(s.acked_by_client, Some(s.tag));
    assert_eq!(s.acks_seen[0].len(), 29);
    link.wait_ack(tsn, 5 * SECOND, &StopToken::new()).unwrap();
    t.close();
}

#[test]
fn handshake_retries_lost_packets() {
    let mut s = FakeServer::bind();
    let proxy = Proxy::start(
        s.addr(),
        Box::new(|dir, i, _| {
            if dir == Dir::ToServer && (i == 0 || i == 2) {
                Action::Drop
            } else {
                Action::Pass
            }
        }),
    );
    let (h, _rx) = handler(None);
    let start = Instant::now();
    let t = Transport::start(config(proxy.addr), h).unwrap();
    s.handshake(None);
    t.wait_established(5 * SECOND, &StopToken::new()).unwrap();
    assert!(start.elapsed() >= Duration::from_millis(550));
    assert_eq!(proxy.counts.lock().unwrap().0, 4);
}

#[test]
fn handshake_gives_up_after_three_attempts() {
    let silent = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    let mut cfg = config(silent.local_addr().unwrap());
    cfg.handshake.attempt_timeout = Duration::from_millis(100);
    let (h, _rx) = handler(None);
    let start = Instant::now();
    let r = Transport::connect(cfg, h, 5 * SECOND, &StopToken::new());
    assert!(matches!(r, Err(TransportError::Handshake(_))), "{r:?}");
    assert!(start.elapsed() >= Duration::from_millis(280));
    silent
        .set_read_timeout(Some(Duration::from_millis(50)))
        .unwrap();
    let mut buf = [0u8; 64];
    let mut inits = 0;
    while let Ok(n) = silent.recv(&mut buf) {
        assert_eq!(n, 33);
        inits += 1;
    }
    assert_eq!(inits, 3);
    let silent2 = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    let stop = StopToken::new();
    stop.stop();
    let (h, _rx) = handler(None);
    let r = Transport::connect(config(silent2.local_addr().unwrap()), h, 5 * SECOND, &stop);
    assert_eq!(r.err(), Some(TransportError::Stopped));
}

#[test]
fn invalid_init_ack_is_a_failed_attempt_and_repeats_are_ignored() {
    let sock = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    let addr = sock.local_addr().unwrap();
    let (h, _rx) = handler(None);
    let t = Transport::start(config(addr), h).unwrap();
    sock.set_read_timeout(Some(2 * SECOND)).unwrap();
    let mut buf = [0u8; 256];
    let (n, client) = sock.recv_from(&mut buf).unwrap();
    let init = Init::parse(parse_control(&buf[..n]).unwrap().payload).unwrap();
    let mut bad = InitAck {
        init: Init {
            tag: 77,
            window: 0x19000,
            outbound_streams: 100,
            inbound_streams: 50,
            initial_tsn: 77,
        },
        cookie: [1; 32],
    };
    sock.send_to(&bad.packet(init.tag), client).unwrap();
    let (n, _) = sock.recv_from(&mut buf).unwrap();
    assert_eq!(parse_control(&buf[..n]).unwrap().chunk, chunk_type::INIT);
    bad.init.inbound_streams = 100;
    bad.init.tag = 0;
    sock.send_to(&bad.packet(init.tag), client).unwrap();
    let (n, _) = sock.recv_from(&mut buf).unwrap();
    assert_eq!(parse_control(&buf[..n]).unwrap().chunk, chunk_type::INIT);
    bad.init.tag = 77;
    sock.send_to(&bad.packet(init.tag), client).unwrap();
    let (n, _) = sock.recv_from(&mut buf).unwrap();
    let cp = parse_control(&buf[..n]).unwrap();
    assert_eq!(cp.chunk, chunk_type::COOKIE_ECHO);
    assert_eq!(cp.tag, 77);
    sock.send_to(&bad.packet(init.tag), client).unwrap();
    sock.send_to(
        &encode_control(init.tag, chunk_type::COOKIE_ACK, 0, &[]),
        client,
    )
    .unwrap();
    t.wait_established(2 * SECOND, &StopToken::new()).unwrap();
    sock.set_read_timeout(Some(Duration::from_millis(400)))
        .unwrap();
    while let Ok((n, _)) = sock.recv_from(&mut buf) {
        assert_ne!(
            parse_control(&buf[..n]).map(|c| c.chunk),
            Some(chunk_type::COOKIE_ECHO)
        );
    }
}

fn scramble(i: usize, dir: Dir) -> u64 {
    let mut z = (i as u64)
        .wrapping_add(if dir == Dir::ToServer { 0x5151 } else { 0xa7a7 })
        .wrapping_mul(0x9e37_79b9_7f4a_7c15);
    z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    z ^ (z >> 31)
}

#[test]
fn reliable_messages_survive_loss_duplication_and_reordering() {
    let mut s = FakeServer::bind();
    let proxy = Proxy::start(
        s.addr(),
        Box::new(|dir, i, _| {
            if i < 3 {
                return Action::Pass;
            }
            match (dir, scramble(i, dir) % 7) {
                (_, 1) => Action::Drop,
                (Dir::ToServer, 3) => Action::Duplicate,
                (Dir::ToClient, 4) => Action::Duplicate,
                (_, 5) => Action::Delay(2),
                _ => Action::Pass,
            }
        }),
    );
    let (h, rx) = handler(None);
    let t = Transport::start(config(proxy.addr), h).unwrap();
    s.handshake(None);
    t.wait_established(5 * SECOND, &StopToken::new()).unwrap();
    let link = t.link();

    let done = Arc::new(AtomicBool::new(false));
    let server_done = done.clone();
    let server = std::thread::spawn(move || {
        for i in 0..40u32 {
            s.send_message(1, 0, format!("s{i}").as_bytes());
        }
        let mut got = Vec::new();
        let deadline = Instant::now() + 20 * SECOND;
        while !server_done.load(Ordering::SeqCst) && Instant::now() < deadline {
            if let Some(m) = s.recv_message(Duration::from_millis(50)) {
                got.push(String::from_utf8(m.data).unwrap());
            }
        }
        (got, s)
    });

    for batch in 0..4 {
        let mut last = 0;
        for i in 0..10 {
            last = link
                .send_message(1, 0, format!("c{}", batch * 10 + i).as_bytes())
                .unwrap();
        }
        if let Err(e) = link.wait_ack(last, 10 * SECOND, &StopToken::new()) {
            panic!("batch {batch}: {e}; {:?}", link.stats());
        }
    }
    let mut from_server = Vec::new();
    while from_server.len() < 40 {
        from_server.push(String::from_utf8(next_msg(&rx).data).unwrap());
    }
    std::thread::sleep(Duration::from_millis(500));
    done.store(true, Ordering::SeqCst);
    let (got, s) = server.join().unwrap();
    assert_eq!(got, (0..40).map(|i| format!("c{i}")).collect::<Vec<_>>());
    assert_eq!(
        from_server,
        (0..40).map(|i| format!("s{i}")).collect::<Vec<_>>()
    );
    assert!(s.unacked.is_empty());
    let stats = link.stats();
    assert!(stats.retransmissions > 0, "{stats:?}");
    assert!(stats.rtt_samples > 0);
    assert!(rx.recv_timeout(Duration::from_millis(300)).is_err());
}

#[test]
fn sequence_numbers_wrap() {
    let mut s = FakeServer::bind();
    s.tag = 0xffff_fff8;
    let mut cfg = config(s.addr());
    cfg.client_tag = Some(0xffff_fff5);
    let (h, rx) = handler(None);
    let t = connect(&mut s, cfg, h);
    let link = t.link();
    let mut last = 0;
    let mut got = Vec::new();
    for i in 0..20u8 {
        last = link.send_message(1, 0, &[i]).unwrap();
        s.send_message(1, 0, &[100 + i]);
        got.push(s.recv_message(5 * SECOND).unwrap().data[0]);
    }
    assert_eq!(last, 0xffff_fff5u32.wrapping_add(19));
    assert_eq!(got, (0..20).collect::<Vec<u8>>());
    let tsns: Vec<u32> = s
        .data_seen
        .iter()
        .map(|d| {
            parse_data_header(parse_control(d).unwrap().payload)
                .unwrap()
                .tsn
        })
        .collect();
    assert!(tsns.contains(&u32::MAX) && tsns.contains(&0));
    for i in 0..20u8 {
        assert_eq!(next_msg(&rx).data, vec![100 + i]);
    }
    link.wait_ack(last, 5 * SECOND, &StopToken::new()).unwrap();
}

#[test]
fn fragments_are_reassembled_per_channel() {
    let mut s = FakeServer::bind();
    let (h, rx) = handler(None);
    let cfg = config(s.addr());
    let t = connect(&mut s, cfg, h);
    let big: Vec<u8> = (0..5000u32).map(|i| (i % 251) as u8).collect();
    let (_, p) = s.build_chunk(1, 0, Some(0), &big[..1000]);
    s.send_raw(&p);
    s.send_message(9, 0, b"ack");
    let (_, p) = s.build_chunk(3, 0, Some(0), b"other");
    s.send_raw(&p);
    for (i, part) in big[1000..].chunks(1000).enumerate() {
        let flags = if i == 3 { FLAG_LAST_FRAGMENT } else { 0 };
        let (_, p) = s.build_chunk(1, flags, None, part);
        s.send_raw(&p);
    }
    let m = next_msg(&rx);
    assert_eq!((m.channel, m.data.as_slice()), (9, &b"ack"[..]));
    let m = next_msg(&rx);
    assert_eq!(m.channel, 1);
    assert_eq!(m.data, big);
    assert!(rx.recv_timeout(Duration::from_millis(200)).is_err());

    let link = t.link();
    let last = link.send_fragmented(1, 0, &big[..2300], 500, 600).unwrap();
    let m = s.recv_message(5 * SECOND).unwrap();
    assert_eq!(m.data, big[..2300]);
    let sizes: Vec<usize> = s.data_seen.iter().map(|d| d.len()).collect();
    assert_eq!(sizes, vec![26 + 500, 25 + 600, 25 + 600, 25 + 600]);
    link.wait_ack(last, 5 * SECOND, &StopToken::new()).unwrap();
}

#[test]
fn retransmission_timing_rtt_and_giving_up() {
    let mut s = FakeServer::bind();
    s.ack = false;
    let (h, _rx) = handler(None);
    let cfg = config(s.addr());
    let t = connect(&mut s, cfg, h);
    let link = t.link();
    let tsn = link.send_message(1, 0, b"hello").unwrap();
    let mut seen: Vec<(Instant, Vec<u8>)> = Vec::new();
    while seen.len() < 3 {
        if let Some(d) = s.recv_raw(2 * SECOND) {
            if is_data(&d) {
                seen.push((Instant::now(), d));
            }
        } else {
            panic!("no retransmission");
        }
    }
    for w in seen.windows(2) {
        assert_eq!(w[0].1, w[1].1, "byte-identical");
        let gap = w[1].0 - w[0].0;
        assert!(
            gap >= Duration::from_millis(180) && gap <= Duration::from_millis(400),
            "{gap:?}"
        );
    }
    s.send_ack(tsn);
    link.wait_ack(tsn, SECOND, &StopToken::new()).unwrap();
    let st = link.stats();
    assert_eq!(st.rtt_samples, 1);
    assert!(st.rtt_latest_us >= 380_000, "{st:?}");
    assert!(st.retransmissions >= 2);
    drop(t);

    let mut s = FakeServer::bind();
    s.ack = false;
    let mut cfg = config(s.addr());
    cfg.retransmit = RetransmitConfig {
        capacity: 16,
        check_interval: Duration::from_millis(20),
        timeout: Duration::from_millis(30),
        max_retransmissions: 2,
    };
    let (h, _rx) = handler(None);
    let t = connect(&mut s, cfg, h);
    let link = t.link();
    link.send_message(1, 0, b"x").unwrap();
    let mut copies = 0;
    let end = Instant::now() + Duration::from_millis(600);
    while Instant::now() < end {
        if let Some(d) = s.recv_raw(Duration::from_millis(50)) {
            if is_data(&d) {
                copies += 1;
            }
        }
    }
    assert_eq!(copies, 3);
    let st = link.stats();
    assert_eq!(st.given_up, 1);
    assert_eq!(st.rtt_samples, 0);
}

#[test]
fn an_urgent_message_goes_twice_at_once() {
    let mut s = FakeServer::bind();
    s.ack = false;
    let (h, _rx) = handler(None);
    let cfg = config(s.addr());
    let t = connect(&mut s, cfg, h);
    let link = t.link();
    let tsn = link.send_message_twice(2, 0, b"broken frame").unwrap();
    let first = next_data(&mut s, "the message");
    let second = next_data(&mut s, "its copy");
    assert_eq!(first.1, second.1, "byte-identical, as a retransmission");
    assert!(
        second.0 - first.0 < Duration::from_millis(50),
        "the copy must be sent immediately, not after the retransmission timeout"
    );
    s.send_ack(tsn);
    link.wait_ack(tsn, SECOND, &StopToken::new()).unwrap();
    assert_eq!(
        link.stats().rtt_samples,
        1,
        "the immediate copy must not count as a retransmission for the RTT"
    );
}

#[test]
fn full_send_buffer_still_transmits_once() {
    let mut s = FakeServer::bind();
    s.ack = false;
    let (h, _rx) = handler(None);
    let cfg = config(s.addr());
    let t = connect(&mut s, cfg, h);
    let link = t.link();
    for i in 0..16u8 {
        link.send_message(1, 0, &[i]).unwrap();
    }
    assert_eq!(
        link.send_message(1, 0, &[16]),
        Err(TransportError::SendBufferFull)
    );
    let mut got = BTreeSet::new();
    let end = Instant::now() + Duration::from_millis(300);
    while Instant::now() < end {
        if let Some(d) = s.recv_raw(Duration::from_millis(50)) {
            if let Some(cp) = parse_control(&d) {
                if cp.chunk == chunk_type::DATA {
                    got.insert(cp.payload[8 + 1]);
                }
            }
        }
    }
    assert_eq!(got.len(), 17);
}

fn client_keys() -> StreamKeys {
    StreamKeys::derive(&shared_secret(), &HANDSHAKE_KEY)
}

#[test]
fn keys_enable_authentication_and_release_held_packets() {
    let mut s = FakeServer::bind();
    s.retransmit = false;
    let mut cfg = config(s.addr());
    cfg.encrypted = true;
    let (h, rx) = handler(Some((0x42, client_keys())));
    let t = connect(&mut s, cfg, h);
    let link = t.link();
    let (_, key_msg) = s.build_chunk(1, FLAG_LAST_FRAGMENT, Some(0x42), b"KEY");
    s.install_keys(&shared_secret(), &HANDSHAKE_KEY);
    let (a1, off) = media_packet(false, 12, 0, 1, 0x0000_0a11, 5, false, &[0xa1; 40]);
    let a1 = s.build_media(a1, off);
    let (a2, off) = media_packet(false, 12, 1, 2, 0x0000_0a11, 5, false, &[0xa2; 40]);
    let a2 = s.build_media(a2, off);
    let (_, next) = s.build_chunk(1, FLAG_LAST_FRAGMENT, Some(0), b"after");
    let (_, good) = s.build_chunk(1, FLAG_LAST_FRAGMENT, Some(0), b"third");
    let mut bad = good.clone();
    bad[5] ^= 0xff;
    s.send_raw(&a1);
    s.send_raw(&a2);
    s.send_raw(&next);
    s.send_raw(&bad);
    std::thread::sleep(Duration::from_millis(50));
    assert!(rx.try_recv().is_err(), "nothing before the key message");
    s.send_raw(&key_msg);
    assert_eq!(next_msg_or_media(&rx), "msg:KEY");
    assert_eq!(next_msg_or_media(&rx), "media:a1");
    assert_eq!(next_msg_or_media(&rx), "media:a2");
    assert_eq!(next_msg_or_media(&rx), "msg:after");
    assert!(rx.recv_timeout(Duration::from_millis(200)).is_err());
    assert_eq!(link.stats().tag_failures, 1);
    s.send_raw(&good);
    assert_eq!(next_msg_or_media(&rx), "msg:third");
    s.pump(Duration::from_millis(300));
    assert_eq!(s.tag_failures, 0);
    assert!(!s.acks_seen.is_empty());
    let first = &s.acks_seen[0];
    assert_eq!(
        &first[9..13],
        &[0, 0, 0, 0],
        "first authenticated ack at key position 0"
    );
    assert_ne!(&first[5..9], &[0, 0, 0, 0]);
    let (_, mut forged) = s.build_chunk(1, FLAG_LAST_FRAGMENT, Some(0), b"forged");
    forged[30] ^= 1;
    s.send_raw(&forged);
    assert!(rx.recv_timeout(Duration::from_millis(200)).is_err());
    assert_eq!(link.stats().tag_failures, 2);
    link.send_message(1, 0, b"tagged").unwrap();
    let m = s.recv_message(5 * SECOND).unwrap();
    assert_eq!(m.data, b"tagged");
    assert_eq!(s.tag_failures, 0);
}

fn next_msg_or_media(rx: &Receiver<Got>) -> String {
    match rx.recv_timeout(5 * SECOND).expect("delivery") {
        Got::Msg(m) => format!("msg:{}", String::from_utf8_lossy(&m.data)),
        Got::Media(p) => {
            assert_eq!(p.header.kind, MediaKind::Audio);
            format!("media:a{}", p.payload()[0] & 0x0f)
        }
    }
}

#[test]
fn key_refresh_and_key_position_wrap() {
    let mut s = FakeServer::bind();
    let mut cfg = config(s.addr());
    cfg.encrypted = true;
    let (h, rx) = handler(Some((0x42, client_keys())));
    let t = connect(&mut s, cfg, h);
    let link = t.link();
    s.send_message(1, 0x42, b"KEY");
    s.install_keys(&shared_secret(), &HANDSHAKE_KEY);
    assert_eq!(next_msg(&rx).data, b"KEY");

    let payload: Vec<u8> = (0..1200u32).map(|i| (i * 3) as u8).collect();
    for i in 0..50u16 {
        let (p, off) = media_packet(false, 12, i, i + 1, 0x0000_0a11, 5, false, &payload);
        let p = s.build_media(p, off);
        s.send_raw(&p);
        let got = next_media(&rx);
        assert_eq!(got.payload(), &payload[..], "packet {i}");
        assert_eq!(got.header.packet_index, i);
    }
    assert!(link.stats().remote_key_position > 45_000);
    let keys = DirectionKeys::derive(&shared_secret(), &HANDSHAKE_KEY, 3);
    s.sealer = Some(Sealer::starting_at(keys, 0xffff_f000));
    for i in 0..6u16 {
        let (p, off) = media_packet(false, 12, 50 + i, 51 + i, 0x0000_0a11, 5, false, &payload);
        let p = s.build_media(p, off);
        s.send_raw(&p);
        assert_eq!(next_media(&rx).payload(), &payload[..]);
    }
    assert!(link.stats().remote_key_position > 0x1_0000_0000);
    s.send_message(1, 0, b"post-wrap");
    assert_eq!(next_msg(&rx).data, b"post-wrap");

    let state: Vec<u8> = (0..1000u32).map(|i| (i * 5) as u8).collect();
    for _ in 0..60 {
        link.send_feedback_state(&state).unwrap();
    }
    let end = Instant::now() + 3 * SECOND;
    while s.raw_seen.len() < 60 && Instant::now() < end {
        s.poll(Duration::from_millis(50));
    }
    assert_eq!(s.raw_seen.len(), 60);
    assert_eq!(s.tag_failures, 0);
    let ck = DirectionKeys::derive(&shared_secret(), &HANDSHAKE_KEY, 2);
    for (i, d) in s.raw_seen.iter().enumerate() {
        assert_eq!(u16::from_be_bytes([d[1], d[2]]), i as u16, "sequence");
        let kp = u32::from_be_bytes(d[4..8].try_into().unwrap()) as u64;
        let mut clear = d[12..].to_vec();
        ck.apply_keystream(kp + 16, &mut clear);
        assert_eq!(clear, state);
    }
    assert!(link.stats().local_key_position > 45_000);
}

#[test]
fn video_is_reordered_with_the_head_of_line_wait() {
    let mut s = FakeServer::bind();
    let (h, rx) = handler(None);
    let cfg = config(s.addr());
    let t = connect(&mut s, cfg, h);
    let packets: Vec<Vec<u8>> = (0..6u16)
        .map(|u| {
            media_packet(
                true,
                12,
                u,
                1,
                video_unit_word(u, 6, 1),
                3,
                false,
                &[u as u8; 30],
            )
            .0
        })
        .collect();
    for i in [2usize, 0, 4, 1, 5, 3] {
        s.send_raw(&packets[i]);
    }
    for u in 0..6u16 {
        let p = next_media(&rx);
        assert_eq!(p.header.packet_index, u);
    }
    let p7 = media_packet(true, 12, 7, 2, video_unit_word(1, 2, 0), 3, false, &[7; 30]).0;
    let sent = Instant::now();
    s.send_raw(&p7);
    let p = next_media(&rx);
    assert_eq!(p.header.packet_index, 7);
    assert!(sent.elapsed() >= Duration::from_millis(15));
    let st = t.link().stats();
    assert_eq!(st.video.skipped, 1);
}

#[test]
fn congestion_reports_count_audio_and_video_loss() {
    let mut s = FakeServer::bind();
    let mut cfg = config(s.addr());
    cfg.congestion = Some(CongestionConfig {
        interval: Duration::from_millis(200),
        margin: 1,
        ceiling: 1.0,
        audio: Default::default(),
    });
    let (h, rx) = handler(None);
    let start = Instant::now();
    let t = Transport::start(cfg, h).unwrap();
    std::thread::sleep(Duration::from_millis(250));
    s.handshake(None);
    t.wait_established(5 * SECOND, &StopToken::new()).unwrap();
    assert!(!s.congestion.is_empty(), "reports before the handshake");
    s.congestion.clear();
    for (i, f) in [1u16, 2, 3, 5, 6, 8].iter().enumerate() {
        let p = media_packet(false, 12, i as u16, *f, 0x0000_0a11, 5, false, &[0; 10]).0;
        s.send_raw(&p);
    }
    for (idx, frame, unit, total, fec) in [
        (0u16, 10u16, 0u16, 3u16, 1u16),
        (2, 10, 2, 3, 1),
        (3, 11, 0, 1, 0),
    ] {
        let p = media_packet(
            true,
            12,
            idx,
            frame,
            video_unit_word(unit, total, fec),
            3,
            false,
            &[1; 30],
        )
        .0;
        s.send_raw(&p);
    }
    for _ in 0..9 {
        rx.recv_timeout(2 * SECOND).unwrap();
    }
    s.pump(Duration::from_millis(700));
    let (r, l): (u32, u32) = s.congestion.iter().fold((0, 0), |(a, b), (r, l)| {
        (a + u32::from(*r), b + u32::from(*l))
    });
    assert_eq!((r, l), (8, 3), "{:?}", s.congestion);
    let total = t.link().stats().congestion_reports;
    let secs = start.elapsed().as_secs_f64();
    assert!(
        (total as f64) >= secs * 5.0 - 2.0 && (total as f64) <= secs * 5.0 + 2.0,
        "{total} reports in {secs} s"
    );
}

#[test]
fn cloud_prefix_and_initial_tsn() {
    let mut s = FakeServer::bind();
    s.prefix = 1;
    let mut cfg = config(s.addr());
    cfg.prefix = 1;
    cfg.initial_tsn_from_init_ack = true;
    let (h, rx) = handler(None);
    let t = Transport::start(cfg, h).unwrap();
    s.handshake(Some(0x1000));
    t.wait_established(5 * SECOND, &StopToken::new()).unwrap();
    assert_eq!(s.next_tsn, 0x1000);
    s.send_message(1, 0, b"cloud");
    assert_eq!(next_msg(&rx).data, b"cloud");
    s.pump(Duration::from_millis(200));
    assert_eq!(s.acked_by_client, Some(0x1000));
    t.link().send_raw(&[0x03; 30]).unwrap();
    let d = s.recv_raw(SECOND).unwrap();
    assert_eq!(d, vec![0x03; 30]);
}

#[test]
fn an_empty_datagram_after_the_handshake_is_dropped() {
    let mut s = FakeServer::bind();
    let cfg = config(s.addr());
    let (h, rx) = handler(None);
    let t = connect(&mut s, cfg, h);
    s.send_raw(&[]);
    s.send_message(1, 0, b"after");
    assert_eq!(next_msg(&rx).data, b"after");
    assert!(t.link().is_established());
    assert_eq!(t.link().stats().dropped, 1);
}

#[test]
fn console_ignores_the_announced_initial_tsn() {
    let mut s = FakeServer::bind();
    let (h, rx) = handler(None);
    let t = Transport::start(config(s.addr()), h).unwrap();
    s.handshake(Some(0x2000));
    t.wait_established(5 * SECOND, &StopToken::new()).unwrap();
    s.retransmit = false;
    s.send_message(1, 0, b"x");
    assert!(rx.recv_timeout(Duration::from_millis(300)).is_err());
    s.next_tsn = s.tag;
    s.send_message(1, 0, b"y");
    assert_eq!(next_msg(&rx).data, b"y");
}

#[test]
fn supplied_socket_is_drained_before_the_handshake() {
    let mut s = FakeServer::bind();
    let sock = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    sock.connect(s.addr()).unwrap();
    for _ in 0..5 {
        s.sock
            .send_to(&[0xee; 40], sock.local_addr().unwrap())
            .unwrap();
    }
    let mut cfg = config(s.addr());
    cfg.endpoint = Endpoint::Socket(sock.try_clone().unwrap());
    let (h, rx) = handler(None);
    let t = Transport::start(cfg, h).unwrap();
    s.handshake(None);
    t.wait_established(5 * SECOND, &StopToken::new()).unwrap();
    s.send_message(1, 0, b"ok");
    assert_eq!(next_msg(&rx).data, b"ok");
    drop(t);
    sock.send(&[1, 2, 3]).unwrap();
}

#[test]
fn local_switches_discard_video_and_game_audio_but_not_haptics() {
    let mut s = FakeServer::bind();
    let mut cfg = config(s.addr());
    cfg.discard_video = true;
    cfg.discard_audio = true;
    let (h, rx) = handler(None);
    let _t = connect(&mut s, cfg, h);
    let v = media_packet(true, 12, 0, 1, video_unit_word(0, 1, 0), 3, false, &[1; 30]).0;
    let a = media_packet(false, 12, 0, 1, 0x0000_0a11, 5, false, &[2; 30]).0;
    let hp = media_packet(false, 12, 1, 2, 0x0000_0a11, 0, true, &[3; 30]).0;
    s.send_raw(&v);
    s.send_raw(&a);
    s.send_raw(&hp);
    let p = next_media(&rx);
    assert_eq!(p.header.kind, MediaKind::Haptics);
    assert!(rx.recv_timeout(Duration::from_millis(200)).is_err());
}
