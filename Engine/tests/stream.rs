mod common;
use common::console::{
    answer_session_request, listener, serve_control, NONCE, REGIST, RP_KEY, SID,
};
use common::media::media_packet;
use common::senkusha::{fake as senkusha_fake, Behaviour};
use common::takion::FakeServer;

use std::net::{SocketAddr, UdpSocket};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use base64::Engine as _;
use con_engine::crypto::rp::RpCipher;
use con_engine::crypto::stream::{sign_public_key, verify_public_key_signature, EcdhKeyPair};
use con_engine::launch::StreamChoice;
use con_engine::media::RawSink;
use con_engine::nettest::{NetworkTestResult, Timings};
use con_engine::proto::{
    client_stream_info, Bang, Big, ControllerConnection, Disconnect, Message, Resolution,
    ServerSettings, StreamInfo,
};
use con_engine::runner::{
    CloudSlot, Connection, ConsoleParams, Session, SessionEvent, SessionRunnerConfig,
};
use con_engine::session::QuitReason;
use con_engine::stream::{StreamData, StreamEvent, StreamTimeouts};
use con_engine::transport::packet::{video_unit_word, MediaKind};
use con_engine::{Codec, ConsoleKind, Stage, Target};

const AUDIO_HEADER: [u8; 14] = [2, 16, 0, 0, 0xbb, 0x80, 0, 0, 1, 0xe0, 0, 0, 0, 0];

#[derive(Clone, Copy, PartialEq, Eq)]
enum End {
    ServerShutdown,
    WaitForClient,
}

struct Opts {
    prefix: u8,
    initial_tsn: Option<u32>,
    version: u32,
    cipher: Option<RpCipher>,
    hk: Option<[u8; 16]>,
    prelude: bool,
    accept_version: bool,
    send_stream_info: bool,
    end: End,
}

fn console_opts() -> Opts {
    Opts {
        prefix: 0,
        initial_tsn: None,
        version: 12,
        cipher: Some(RpCipher::for_session(Target::Ps5V1, &NONCE, &RP_KEY)),
        hk: None,
        prelude: false,
        accept_version: true,
        send_stream_info: true,
        end: End::ServerShutdown,
    }
}

fn cloud_opts() -> Opts {
    Opts {
        prefix: 1,
        initial_tsn: None,
        version: 9,
        cipher: None,
        hk: Some([0x5a; 16]),
        prelude: false,
        accept_version: true,
        send_stream_info: true,
        end: End::WaitForClient,
    }
}

#[derive(Debug, Default)]
struct Seen {
    big: Option<Big>,
    fragments: usize,
    first_fragment_len: usize,
    launch_json: Option<String>,
    replies: Vec<(u16, Message)>,
    heartbeats: usize,
    idr: usize,
    corrupt: Vec<(u32, u32)>,
    congestion: usize,
    tag_failures: u32,
    client_disconnect: Option<String>,
}

fn decode_launch(spec: &str, cipher: &RpCipher) -> (String, [u8; 16]) {
    let mut b = base64::engine::general_purpose::STANDARD
        .decode(spec)
        .unwrap();
    let ks = cipher.keystream(0, b.len());
    for (x, k) in b.iter_mut().zip(ks) {
        *x ^= k;
    }
    assert_eq!(b.pop(), Some(0), "terminating NUL");
    let json = String::from_utf8(b).unwrap();
    let at = json.find("\"handshakeKey\":\"").unwrap() + 16;
    let end = at + json[at..].find('"').unwrap();
    let hk = base64::engine::general_purpose::STANDARD
        .decode(&json[at..end])
        .unwrap();
    (json, hk.try_into().unwrap())
}

fn stream_fake(o: Opts) -> (SocketAddr, JoinHandle<Seen>) {
    let mut s = FakeServer::bind();
    s.prefix = o.prefix;
    let addr = s.addr();
    let t = std::thread::spawn(move || {
        let mut seen = Seen::default();
        let w = Duration::from_secs(10);
        s.handshake(o.initial_tsn);
        let (ch, big) = s.recv_proto(w).expect("hello");
        assert_eq!(ch, 1);
        let Message::Big(big) = big else {
            panic!("expected BIG")
        };
        seen.fragments = s.data_seen.len();
        seen.first_fragment_len = s.data_seen[0].len();
        let hk = match &o.cipher {
            Some(c) => {
                let (json, hk) = decode_launch(&big.launch_spec, c);
                seen.launch_json = Some(json);
                hk
            }
            None => o.hk.unwrap(),
        };
        let client_pub = big.ecdh_public_key.clone().unwrap();
        assert_eq!(client_pub.len(), 65);
        assert!(verify_public_key_signature(
            &hk,
            &client_pub,
            big.ecdh_signature.as_deref().unwrap()
        ));
        seen.big = Some(big.clone());
        let server = EcdhKeyPair::generate();
        let spub = server.public_key();
        let z = server.shared_secret(&client_pub).unwrap();
        s.send_proto(
            1,
            &Message::Bang(Bang {
                server_version: o.version,
                token: 1,
                encrypted_key_accepted: true,
                version_accepted: o.accept_version,
                session_key: big.session_key.clone(),
                extended_info: None,
                server_version_string: Some("fake".into()),
                ecdh_public_key: Some(spub.to_vec()),
                ecdh_signature: Some(sign_public_key(&hk, &spub).to_vec()),
            }),
        );
        s.install_keys(&z, &hk);
        if !o.accept_version || !o.send_stream_info {
            s.pump(Duration::from_secs(2));
            return seen;
        }
        if o.prelude {
            s.send_proto(
                1,
                &Message::ServerSettings(ServerSettings {
                    idr_period: Some(60),
                    send_periodic_timestamp: None,
                }),
            );
        }
        s.send_proto(
            1,
            &Message::StreamInfo(StreamInfo {
                resolutions: vec![
                    Resolution {
                        width: 1280,
                        height: 720,
                        video_header: vec![0, 0, 0, 1, 0x67, 0x42],
                    },
                    Resolution {
                        width: 640,
                        height: 360,
                        video_header: vec![0, 0, 0, 1, 0x67, 0x43],
                    },
                ],
                audio_header: AUDIO_HEADER.to_vec(),
                ..Default::default()
            }),
        );
        for _ in 0..3 {
            seen.replies
                .push(s.recv_proto(w).expect("reply to stream info"));
        }
        let (v, off) = media_packet(
            true,
            o.version,
            0,
            1,
            video_unit_word(0, 1, 0),
            3,
            false,
            b"VIDEO-PAYLOAD",
        );
        let v = s.build_media(v, off);
        s.send_raw(&v);
        let (a, off) = media_packet(false, o.version, 0, 1, 0x0000_0a11, 5, false, b"AUDIO");
        let a = s.build_media(a, off);
        s.send_raw(&a);
        if o.version == 12 {
            let (hp, off) = media_packet(false, 12, 1, 2, 0x0000_0a11, 0, true, b"HAPTICS");
            let hp = s.build_media(hp, off);
            s.send_raw(&hp);
        }
        s.send_message(1, 7, &[0x00, 0x80, 0x40]);

        let collect = |s: &mut FakeServer, seen: &mut Seen, until: Instant| {
            while Instant::now() < until && seen.client_disconnect.is_none() {
                if let Some(m) = s.recv_message(Duration::from_millis(50)) {
                    match Message::decode(&m.data).unwrap() {
                        Message::Heartbeat => {
                            assert_eq!(m.channel, 1);
                            seen.heartbeats += 1;
                        }
                        Message::IdrRequest => {
                            assert_eq!(m.channel, 2);
                            seen.idr += 1;
                        }
                        Message::CorruptFrame(c) => {
                            assert_eq!(m.channel, 2);
                            seen.corrupt.push((c.start, c.end));
                        }
                        Message::Disconnect(d) => {
                            assert_eq!(m.channel, 1);
                            seen.client_disconnect = Some(d.reason);
                        }
                        other => panic!("unexpected {other:?}"),
                    }
                }
            }
        };
        match o.end {
            End::ServerShutdown => {
                collect(
                    &mut s,
                    &mut seen,
                    Instant::now() + Duration::from_millis(2300),
                );
                s.send_proto(
                    1,
                    &Message::Disconnect(Disconnect {
                        reason: "Server shutting down".into(),
                        extended_info: None,
                    }),
                );
                collect(&mut s, &mut seen, Instant::now() + Duration::from_secs(5));
            }
            End::WaitForClient => {
                collect(&mut s, &mut seen, Instant::now() + Duration::from_secs(20));
            }
        }
        seen.congestion = s.congestion.len();
        seen.tag_failures = s.tag_failures;
        seen
    });
    (addr, t)
}

type Events = Receiver<SessionEvent>;
type Data = Receiver<StreamData>;

fn start(config: SessionRunnerConfig) -> (Session, Events, Data) {
    let (etx, erx) = mpsc::channel();
    let (dtx, drx) = mpsc::channel();
    let etx = Mutex::new(etx);
    let dtx = Mutex::new(dtx);
    let session = Session::start(
        config,
        Arc::new(move |e| {
            let _ = etx.lock().unwrap().send(e);
        }),
        Arc::new(RawSink(Arc::new(move |d| {
            let _ = dtx.lock().unwrap().send(d);
        }))),
    );
    (session, erx, drx)
}

fn events_until_quit(rx: &Events) -> Vec<SessionEvent> {
    let mut all = Vec::new();
    loop {
        let e = rx
            .recv_timeout(Duration::from_secs(30))
            .expect("quit event");
        let quit = matches!(e, SessionEvent::Quit { .. });
        all.push(e);
        if quit {
            return all;
        }
    }
}

fn wait_connected(rx: &Events, all: &mut Vec<SessionEvent>) {
    loop {
        let e = rx.recv_timeout(Duration::from_secs(30)).expect("connected");
        let done = matches!(e, SessionEvent::Stream(StreamEvent::Connected));
        assert!(!matches!(e, SessionEvent::Quit { .. }), "{e:?}");
        all.push(e);
        if done {
            return;
        }
    }
}

#[test]
fn console_session_from_request_to_remote_shutdown() {
    let (l, tcp) = listener();
    let control = std::thread::spawn(move || {
        answer_session_request(&l, "1.0");
        let cipher = RpCipher::for_session(Target::Ps5V1, &NONCE, &RP_KEY);
        serve_control(&l, cipher, 2, 5)
    });
    let (nt_addr, nt) = senkusha_fake(
        Behaviour {
            answer_protocol: true,
            answer_mtu: true,
            mtu_in_limit: 1000,
            mtu_out_limit: 1454,
            ..Default::default()
        },
        0,
    );
    let (st_addr, st) = stream_fake(console_opts());

    let mut params = ConsoleParams::new(
        "127.0.0.1",
        ConsoleKind::Ps5,
        REGIST,
        RP_KEY,
        StreamChoice::new(720, 60, Codec::H265),
    );
    params.session_port = tcp.port();
    params.network_test_port = nt_addr.port();
    params.stream_port = st_addr.port();
    params.network_test_timings = Timings {
        connect: Duration::from_secs(5),
        reply: Duration::from_secs(2),
        pong: Duration::from_millis(500),
        mtu_wait_min: Duration::from_millis(50),
        ..Timings::console()
    };
    let (session, events, data) = start(SessionRunnerConfig::new(Connection::Console(params)));
    let all = events_until_quit(&events);
    session.join();

    let kinds: Vec<&str> = all
        .iter()
        .map(|e| match e {
            SessionEvent::Control(_) => "control",
            SessionEvent::NetworkTest { .. } => "nettest",
            SessionEvent::Stream(StreamEvent::StreamInfo(_)) => "info",
            SessionEvent::Stream(StreamEvent::Connected) => "connected",
            SessionEvent::Stream(_) => "stream",
            SessionEvent::Quit { .. } => "quit",
        })
        .filter(|k| *k != "control" && *k != "stream")
        .collect();
    assert_eq!(kinds, vec!["nettest", "info", "connected", "quit"]);
    let SessionEvent::NetworkTest { result, fallback } = &all
        .iter()
        .find(|e| matches!(e, SessionEvent::NetworkTest { .. }))
        .unwrap()
    else {
        unreachable!()
    };
    assert!(!fallback);
    assert_eq!((result.mtu_in, result.mtu_out), (1000, 1453));
    let info = all
        .iter()
        .find_map(|e| match e {
            SessionEvent::Stream(StreamEvent::StreamInfo(i)) => Some(i.clone()),
            _ => None,
        })
        .unwrap();
    assert_eq!(info.resolutions.len(), 2);
    assert_eq!(info.resolutions[1].height, 360);
    assert_eq!(info.audio_header, AUDIO_HEADER);
    assert_eq!(
        all.last().unwrap(),
        &SessionEvent::Quit {
            reason: QuitReason::StreamRemoteShutdown,
            text: Some("Server shutting down".into()),
            stage: Stage::Streaming,
        }
    );

    let got: Vec<StreamData> = data.try_iter().collect();
    let media: Vec<(MediaKind, Vec<u8>)> = got
        .iter()
        .filter_map(|d| match d {
            StreamData::Media(p) => Some((p.header.kind, p.payload().to_vec())),
            _ => None,
        })
        .collect();
    assert!(media.contains(&(MediaKind::Video, b"VIDEO-PAYLOAD".to_vec())));
    assert!(media.contains(&(MediaKind::Audio, b"AUDIO".to_vec())));
    assert!(media.contains(&(MediaKind::Haptics, b"HAPTICS".to_vec())));
    assert!(got.contains(&StreamData::Feedback {
        data_type: 7,
        data: vec![0x00, 0x80, 0x40]
    }));

    let seen = st.join().unwrap();
    let big = seen.big.as_ref().unwrap();
    assert_eq!(big.version, 12);
    assert_eq!(big.session_key, SID);
    assert_eq!(big.encrypted_key, vec![0, 0, 0, 0]);
    assert!(seen.fragments >= 2, "{}", seen.fragments);
    assert_eq!(seen.first_fragment_len, 950);
    let json = seen.launch_json.unwrap();
    assert!(json.contains("\"mtu\":1000,"), "{json}");
    assert!(json.contains("\"videoCodec\":\"hevc\""));
    assert_eq!(seen.replies[0].0, 9);
    assert_eq!(seen.replies[0].1, Message::StreamInfoAck);
    assert_eq!(seen.replies[1].0, 1);
    assert_eq!(
        seen.replies[1].1,
        Message::ControllerConnection(ControllerConnection {
            controller_id: None,
            connected: Some(true),
            controller_type: Some(6)
        })
    );
    assert_eq!(seen.replies[2], (1, client_stream_info()));
    assert!(seen.heartbeats >= 2, "{}", seen.heartbeats);
    assert!(seen.congestion >= 5, "{}", seen.congestion);
    assert_eq!(seen.tag_failures, 0);
    assert_eq!(
        seen.client_disconnect.as_deref(),
        Some("Client Disconnecting")
    );
    let types = control.join().unwrap();
    assert!(!types.is_empty());
    let nt_seen = nt.join().unwrap();
    assert_eq!(nt_seen.disconnect.as_deref(), Some("Client Disconnecting"));
}

fn cloud_slot(addr: SocketAddr, launch_spec: String) -> CloudSlot {
    CloudSlot {
        addr,
        prefix: 1,
        ps5: false,
        session_id: "CLOUD-SESSION".into(),
        handshake_key: [0x5a; 16],
        launch_spec,
        mtu_in: None,
        mtu_out: None,
        rtt_us: Some(23_000),
        codec: Codec::H264,
        max_fps: 60,
    }
}

#[test]
fn cloud_session_stopped_by_the_application() {
    let spec: String = "L".repeat(3000);
    let (addr, st) = stream_fake(Opts {
        initial_tsn: Some(0x7000),
        prelude: true,
        ..cloud_opts()
    });
    let config = SessionRunnerConfig::new(Connection::Cloud(cloud_slot(addr, spec.clone())));
    assert!(!config.dualsense);
    assert_eq!(config.loss_ceiling, 0.02);
    let (session, events, data) = start(config);
    let mut all = Vec::new();
    wait_connected(&events, &mut all);
    assert!(all.iter().any(|e| matches!(
        e,
        SessionEvent::Stream(StreamEvent::CloudPrelude {
            msg_type: 28,
            has_stream_info: false,
            ..
        })
    )));
    let stream = session.stream().expect("stream handle");
    stream.request_idr().unwrap();
    stream.report_corrupt_frames(3, 5).unwrap();
    std::thread::sleep(Duration::from_millis(1200));
    let stats = session.stats().unwrap();
    assert!(stats.rtt_samples >= 1);
    assert!(stats.congestion_reports >= 5);
    session.stop();
    let rest = events_until_quit(&events);
    assert_eq!(
        rest.last().unwrap(),
        &SessionEvent::Quit {
            reason: QuitReason::Stopped,
            text: None,
            stage: Stage::Streaming,
        }
    );
    session.join();
    let seen = st.join().unwrap();
    let big = seen.big.unwrap();
    assert_eq!(big.version, 9);
    assert_eq!(big.session_key, "CLOUD-SESSION");
    assert_eq!(big.launch_spec, spec);
    assert_eq!(seen.first_fragment_len, 26 + 1196);
    assert_eq!(seen.fragments, 3);
    assert_eq!(
        seen.replies[1].1,
        Message::ControllerConnection(ControllerConnection {
            controller_id: None,
            connected: Some(true),
            controller_type: Some(2)
        })
    );
    assert_eq!(seen.idr, 1);
    assert_eq!(seen.corrupt, vec![(3, 5)]);
    assert_eq!(
        seen.client_disconnect.as_deref(),
        Some("Client Disconnecting")
    );
    assert_eq!(seen.tag_failures, 0);
    let got: Vec<StreamData> = data.try_iter().collect();
    assert!(got.iter().any(|d| matches!(
        d,
        StreamData::Media(p) if p.header.kind == MediaKind::Audio && p.payload() == b"AUDIO"
    )));
}

#[test]
fn stream_setup_failures() {
    let (addr, st) = stream_fake(Opts {
        accept_version: false,
        send_stream_info: false,
        ..cloud_opts()
    });
    let (session, events, _data) = start(SessionRunnerConfig::new(Connection::Cloud(cloud_slot(
        addr,
        "x".into(),
    ))));
    let all = events_until_quit(&events);
    assert_eq!(
        all.last().unwrap(),
        &SessionEvent::Quit {
            reason: QuitReason::StreamUnknown,
            text: None,
            stage: Stage::KeyExchange,
        }
    );
    session.join();
    st.join().unwrap();

    let (addr, st) = stream_fake(Opts {
        send_stream_info: false,
        ..cloud_opts()
    });
    let mut config = SessionRunnerConfig::new(Connection::Cloud(cloud_slot(addr, "x".into())));
    config.stream_timeouts = StreamTimeouts {
        stream_info: Duration::from_millis(400),
        ..Default::default()
    };
    let started = Instant::now();
    let (session, events, _data) = start(config);
    let all = events_until_quit(&events);
    assert!(matches!(
        all.last().unwrap(),
        SessionEvent::Quit {
            reason: QuitReason::StreamUnknown,
            stage: Stage::StreamInfo,
            ..
        }
    ));
    assert!(started.elapsed() < Duration::from_secs(3));
    session.join();
    st.join().unwrap();

    let silent = UdpSocket::bind("127.0.0.1:0").unwrap();
    let mut config = SessionRunnerConfig::new(Connection::Cloud(cloud_slot(
        silent.local_addr().unwrap(),
        "x".into(),
    )));
    config.stream_timeouts.transport = Duration::from_millis(300);
    let (session, events, _data) = start(config);
    let all = events_until_quit(&events);
    assert!(matches!(
        all.last().unwrap(),
        SessionEvent::Quit {
            reason: QuitReason::StreamUnknown,
            stage: Stage::Transport,
            ..
        }
    ));
    session.join();

    let silent = UdpSocket::bind("127.0.0.1:0").unwrap();
    let (session, events, _data) = start(SessionRunnerConfig::new(Connection::Cloud(cloud_slot(
        silent.local_addr().unwrap(),
        "x".into(),
    ))));
    std::thread::sleep(Duration::from_millis(100));
    session.stop();
    let all = events_until_quit(&events);
    assert_eq!(
        all.last().unwrap(),
        &SessionEvent::Quit {
            reason: QuitReason::Stopped,
            text: None,
            stage: Stage::Transport,
        }
    );
}

#[test]
fn console_network_test_fallback_and_request_failure() {
    let (l, tcp) = listener();
    let control = std::thread::spawn(move || {
        answer_session_request(&l, "1.0");
        let cipher = RpCipher::for_session(Target::Ps5V1, &NONCE, &RP_KEY);
        serve_control(&l, cipher, 2, 5)
    });
    let silent = UdpSocket::bind("127.0.0.1:0").unwrap();
    let (st_addr, st) = stream_fake(console_opts());
    let mut params = ConsoleParams::new(
        "127.0.0.1",
        ConsoleKind::Ps5,
        REGIST,
        RP_KEY,
        StreamChoice::new(1080, 60, Codec::H264),
    );
    params.session_port = tcp.port();
    params.network_test_port = silent.local_addr().unwrap().port();
    params.stream_port = st_addr.port();
    params.network_test_timings.connect = Duration::from_millis(400);
    let (session, events, _data) = start(SessionRunnerConfig::new(Connection::Console(params)));
    let all = events_until_quit(&events);
    session.join();
    assert!(all.contains(&SessionEvent::NetworkTest {
        result: NetworkTestResult::console_fallback(),
        fallback: true
    }));
    let seen = st.join().unwrap();
    let json = seen.launch_json.unwrap();
    assert!(json.contains("\"mtu\":1454,\"rtt\":1,"), "{json}");
    assert!(seen.first_fragment_len <= 26 + 1378);
    control.join().unwrap();

    let (l, tcp) = listener();
    drop(l);
    let mut params = ConsoleParams::new(
        "127.0.0.1",
        ConsoleKind::Ps4,
        REGIST,
        RP_KEY,
        StreamChoice::new(720, 60, Codec::H264),
    );
    params.session_port = tcp.port();
    let (session, events, _data) = start(SessionRunnerConfig::new(Connection::Console(params)));
    let all = events_until_quit(&events);
    assert!(matches!(
        all.last().unwrap(),
        SessionEvent::Quit {
            reason: QuitReason::SessionRequestConnectionRefused,
            stage: Stage::SessionRequest,
            ..
        }
    ));
    session.join();
}
