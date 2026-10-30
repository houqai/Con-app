mod common;
use common::media::{
    audio_datagram, body, frame_units, left_frequency, opus_tone_packets, packed_audio_datagram,
    packed_haptics_datagram, video_datagram,
};
use common::takion::FakeServer;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use con_engine::crypto::stream::{sign_public_key, EcdhKeyPair};
use con_engine::media::feedback::{
    button, encode_state, parse_history, ControllerState, HistoryEvent,
};
use con_engine::media::h26x::{self, CodecFamily};
use con_engine::media::video::MissingReference;
use con_engine::media::{
    capture, AudioFrame, DropReason, FeedbackEvent, HapticsFrame, MediaConfig, MediaSink,
    SampleKind, VideoSample,
};
use con_engine::proto::{Bang, ConnectionQuality, Disconnect, Message, Resolution, StreamInfo};
use con_engine::runner::{CloudSlot, Connection, Session, SessionEvent, SessionRunnerConfig};
use con_engine::session::QuitReason;
use con_engine::stream::{self, StreamConfig, StreamEvent, StreamHandle};
use con_engine::transport::packet::{be32, packet_type};
use con_engine::{Codec, StopToken};

const AUDIO_HEADER: [u8; 14] = [2, 16, 0, 0, 0xbb, 0x80, 0, 0, 1, 0xe0, 0, 0, 0, 1];
const HK: [u8; 16] = [0x3c; 16];

#[derive(Debug, Clone)]
struct Pic {
    kind: SampleKind,
    frame: u16,
    lost: u32,
    recovered: bool,
    fec: bool,
    key: bool,
    data: Vec<u8>,
}

#[derive(Default)]
struct App {
    video: Mutex<Vec<Pic>>,
    audio: Mutex<Vec<(u16, bool, Vec<i16>)>>,
    haptics: Mutex<Vec<u16>>,
    handle: Mutex<Option<StreamHandle>>,
    idr_from_callback: AtomicUsize,
    raw: AtomicUsize,
}

impl MediaSink for App {
    fn raw(&self, _d: &stream::StreamData) {
        self.raw.fetch_add(1, Ordering::SeqCst);
    }

    fn video(&self, s: &VideoSample<'_>) -> bool {
        self.video.lock().unwrap().push(Pic {
            kind: s.kind,
            frame: s.frame_index,
            lost: s.frames_lost,
            recovered: s.recovered,
            fec: s.fec_recovered,
            key: s.keyframe,
            data: s.data.to_vec(),
        });
        if s.recovered {
            if let Some(h) = self.handle.lock().unwrap().as_ref() {
                h.request_idr().unwrap();
                self.idr_from_callback.fetch_add(1, Ordering::SeqCst);
            }
        }
        true
    }

    fn audio(&self, f: &AudioFrame<'_>) {
        assert!(f.decoded);
        self.audio
            .lock()
            .unwrap()
            .push((f.frame_index, f.concealed, f.pcm.to_vec()));
    }

    fn haptics(&self, f: &HapticsFrame<'_>) {
        assert_eq!(f.pcm.len(), 120);
        self.haptics.lock().unwrap().push(f.frame_index);
    }
}

fn h265_picture(frame: u16, idr: bool, neg: &[bool]) -> Vec<u8> {
    h26x::build_h265_slice(idr, u32::from(frame) - 1, 8, neg, &body(500, frame as u8))
}

fn setup(s: &mut FakeServer, version: u32, initial_tsn: Option<u32>) {
    let w = Duration::from_secs(10);
    s.handshake(initial_tsn);
    let (_, big) = s.recv_proto(w).expect("hello");
    let Message::Big(big) = big else {
        panic!("expected BIG")
    };
    let client_pub = big.ecdh_public_key.clone().unwrap();
    let server = EcdhKeyPair::generate();
    let spub = server.public_key();
    let z = server.shared_secret(&client_pub).unwrap();
    s.send_proto(
        1,
        &Message::Bang(Bang {
            server_version: version,
            token: 1,
            encrypted_key_accepted: true,
            version_accepted: true,
            session_key: big.session_key.clone(),
            extended_info: None,
            server_version_string: None,
            ecdh_public_key: Some(spub.to_vec()),
            ecdh_signature: Some(sign_public_key(&HK, &spub).to_vec()),
        }),
    );
    s.install_keys(&z, &HK);
    s.send_proto(
        1,
        &Message::StreamInfo(StreamInfo {
            resolutions: vec![Resolution {
                width: 1920,
                height: 1080,
                video_header: h26x::build_h265_parameter_sets(8),
            }],
            audio_header: AUDIO_HEADER.to_vec(),
            ..Default::default()
        }),
    );
    for _ in 0..3 {
        s.recv_proto(w).expect("reply to stream info");
    }
}

fn send_frame(
    s: &mut FakeServer,
    packet: &mut u16,
    frame: u16,
    picture: &[u8],
    m: usize,
    drop: &[usize],
    reverse: bool,
) {
    let units = frame_units(picture, 150, m);
    let n = units.len();
    let base = *packet;
    *packet = packet.wrapping_add(n as u16);
    let mut order: Vec<usize> = (0..n).collect();
    if reverse {
        order.reverse();
    }
    for u in order {
        if drop.contains(&u) {
            continue;
        }
        let d = video_datagram(
            base.wrapping_add(u as u16),
            frame,
            u as u16,
            n as u16,
            m as u16,
            0,
            false,
            &units[u],
        );
        let d = s.build_media(d, 21);
        s.send_raw(&d);
    }
}

#[derive(Default, Debug)]
struct Seen {
    corrupt: Vec<(u32, u32)>,
    idr: usize,
    states: Vec<Vec<u8>>,
    history: Vec<Vec<HistoryEvent>>,
    state_seqs: Vec<u16>,
    disconnect: bool,
    tag_failures: u32,
}

fn collect(s: &mut FakeServer, seen: &mut Seen, until: Instant) {
    while Instant::now() < until && !seen.disconnect {
        if let Some(m) = s.recv_message(Duration::from_millis(20)) {
            if m.data_type == 0 {
                match Message::decode(&m.data).unwrap() {
                    Message::CorruptFrame(c) => {
                        assert_eq!(m.channel, 2);
                        seen.corrupt.push((c.start, c.end));
                    }
                    Message::IdrRequest => seen.idr += 1,
                    Message::Disconnect(_) => seen.disconnect = true,
                    _ => {}
                }
            }
        }
        for mut d in std::mem::take(&mut s.raw_seen) {
            let ty = d[0];
            if ty != packet_type::FEEDBACK_STATE && ty != packet_type::FEEDBACK_HISTORY {
                continue;
            }
            let kp = u64::from(be32(&d, 4));
            s.opener.as_ref().unwrap().decrypt_payload(&mut d, 12, kp);
            if ty == packet_type::FEEDBACK_STATE {
                seen.state_seqs.push(u16::from_be_bytes([d[1], d[2]]));
                seen.states.push(d[12..].to_vec());
            } else {
                seen.history.push(parse_history(&d[12..]).expect("history"));
            }
        }
    }
    seen.tag_failures = s.tag_failures;
}

fn wait_for(what: &str, mut f: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(15);
    while !f() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn wait_event(
    rx: &Receiver<StreamEvent>,
    all: &mut Vec<StreamEvent>,
    f: impl Fn(&StreamEvent) -> bool,
) {
    loop {
        let e = rx.recv_timeout(Duration::from_secs(15)).expect("event");
        let done = f(&e);
        all.push(e);
        if done {
            return;
        }
    }
}

#[test]
fn console_stream_end_to_end() {
    let mut s = FakeServer::bind();
    let addr = s.addr();
    let pk = opus_tone_packets(30);
    let fake = std::thread::spawn(move || {
        let mut seen = Seen::default();
        setup(&mut s, 12, None);
        let mut vp = 0u16;
        for (frame, idr, neg, m, drop, reverse) in [
            (1, true, &[][..], 1, &[][..], false),
            (2, false, &[true][..], 2, &[][..], true),
            (3, false, &[true][..], 2, &[1][..], false),
            (4, false, &[true][..], 1, &[0, 2][..], false),
            (5, false, &[true, true][..], 1, &[][..], false),
            (6, false, &[true][..], 1, &[][..], false),
            (7, false, &[true][..], 1, &[][..], false),
            (8, false, &[true][..], 1, &[][..], false),
        ] {
            let picture = h265_picture(frame, idr, neg);
            send_frame(&mut s, &mut vp, frame, &picture, m, drop, reverse);
        }
        for f in 1..=30u16 {
            if f == 12 {
                continue;
            }
            let d = packed_audio_datagram(12, f, &pk);
            let d = s.build_media(d, 20);
            s.send_raw(&d);
        }
        for f in 1..=5u16 {
            let payload = [vec![f as u8; 120], vec![0; 120], vec![0; 120]].concat();
            let d = audio_datagram(12, 100 + f, f, 3, 120, 2, 1, 0, true, &payload);
            let d = s.build_media(d, 20);
            s.send_raw(&d);
        }
        s.send_message(1, 7, &[0x00, 0xc0, 0x20]);
        let mut pad = vec![0u8; 25];
        pad[8] = 2;
        pad[9] = 0xff;
        s.send_message(1, 9, &pad);
        let mut trig = vec![0u8; 25];
        trig[1] = 0x21;
        trig[2] = 0x25;
        s.send_message(1, 11, &trig);
        collect(
            &mut s,
            &mut seen,
            Instant::now() + Duration::from_millis(300),
        );
        s.send_proto(
            1,
            &Message::ConnectionQuality(ConnectionQuality {
                target_bitrate: Some(15000),
                ..Default::default()
            }),
        );
        collect(&mut s, &mut seen, Instant::now() + Duration::from_secs(20));
        seen
    });

    let app = Arc::new(App::default());
    let (etx, erx) = mpsc::channel();
    let etx = Mutex::new(etx);
    let stop = StopToken::new();
    let mut config = StreamConfig::console(addr, 12, "SESSION".into(), "SPEC".into(), HK);
    config.dualsense = true;
    config.media = MediaConfig::console(Codec::H265, 60);
    config.missing_reference.set(MissingReference::Repair);
    let capture_path = std::path::PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join(format!("media-capture-{}.bin", std::process::id()));
    let _ = std::fs::remove_file(&capture_path);
    config
        .capture
        .start(&capture_path, Default::default())
        .unwrap();
    let capture_slot = config.capture.clone();
    let runner = {
        let app = app.clone();
        let stop = stop.clone();
        std::thread::spawn(move || {
            let sink: Arc<dyn MediaSink> = app.clone();
            stream::run(
                config,
                Arc::new(move |e| {
                    let _ = etx.lock().unwrap().send(e);
                }),
                sink,
                |h| *app.handle.lock().unwrap() = Some(h),
                &stop,
            )
        })
    };
    let mut events = Vec::new();
    wait_event(&erx, &mut events, |e| matches!(e, StreamEvent::Connected));
    let pressed = ControllerState {
        buttons: button::CROSS,
        left_x: 12000,
        left_y: -3000,
        ..ControllerState::IDLE
    };
    let handle = app.handle.lock().unwrap().clone().unwrap();
    handle.set_controller_state(pressed);

    wait_for("pictures", || app.video.lock().unwrap().len() >= 8);
    wait_for("audio", || app.audio.lock().unwrap().len() >= 30);
    wait_for("haptics", || app.haptics.lock().unwrap().len() >= 5);
    wait_for("measured bitrate", || {
        handle.media_stats().measured_bitrate > 0
    });
    std::thread::sleep(Duration::from_millis(500));
    let stats = handle.media_stats();
    stop.stop();
    let outcome = runner.join().unwrap();
    assert_eq!(outcome.reason, QuitReason::Stopped);
    let seen = fake.join().unwrap();
    while let Ok(e) = erx.try_recv() {
        events.push(e);
    }

    let video = app.video.lock().unwrap().clone();
    assert_eq!(video[0].kind, SampleKind::ParameterSets);
    assert_eq!(video[0].data, h26x::build_h265_parameter_sets(8));
    let pics: Vec<(u16, u32, bool, bool, bool)> = video[1..]
        .iter()
        .map(|p| (p.frame, p.lost, p.recovered, p.fec, p.key))
        .collect();
    assert_eq!(
        pics,
        vec![
            (1, 0, false, false, true),
            (2, 0, false, false, false),
            (3, 0, false, true, false),
            (5, 1, true, false, false),
            (6, 0, false, false, false),
            (7, 0, false, false, false),
            (8, 0, false, false, false),
        ]
    );
    assert_eq!(video[1].data, h265_picture(1, true, &[]));
    assert_eq!(video[3].data, h265_picture(3, false, &[true]));
    let sets = h26x::ParameterSets::parse(CodecFamily::H265, &video[0].data);
    let r = h26x::first_slice(CodecFamily::H265, &video[4].data).unwrap();
    let s5 = h26x::parse_slice(CodecFamily::H265, &sets, &video[4].data[r]).unwrap();
    assert_eq!(s5.reference, Some(1));
    assert_eq!(stats.video.frames_fec_recovered, 1);
    assert_eq!(stats.video.frames_fec_failed, 1);
    assert_eq!(stats.video.frames_reference_repaired, 1);
    assert!(stats.measured_bitrate > 0);

    capture_slot.stop();
    let file = std::fs::read(&capture_path).unwrap();
    let _ = std::fs::remove_file(&capture_path);
    let mut at = capture::FILE_HEADER_LEN;
    let mut records = Vec::new();
    while at < file.len() {
        let h = capture::RecordHeader::decode(&file[at..]).unwrap();
        let start = at + capture::RECORD_HEADER_LEN;
        let end = start + h.length as usize;
        records.push((h, file[start..end].to_vec()));
        at = end;
    }
    use capture::flag::{ACCEPTED, FEC_RECOVERED, KEYFRAME, RECOVERED};
    let got: Vec<(u8, u16, u8, u8, u32)> = records
        .iter()
        .map(|(h, _)| (h.kind, h.frame_index, h.flags, h.reason, h.frames_lost))
        .collect();
    assert_eq!(
        got,
        vec![
            (capture::kind::START, 0, 0, 0, 0),
            (capture::kind::PARAMETER_SETS, 1, ACCEPTED, 0, 0),
            (capture::kind::PICTURE, 1, KEYFRAME | ACCEPTED, 0, 0),
            (capture::kind::PICTURE, 2, ACCEPTED, 0, 0),
            (capture::kind::PICTURE, 3, FEC_RECOVERED | ACCEPTED, 0, 0),
            (
                capture::kind::NOT_DELIVERED,
                4,
                0,
                DropReason::FecFailed as u8,
                0
            ),
            (capture::kind::PICTURE, 5, RECOVERED | ACCEPTED, 0, 1),
            (capture::kind::PICTURE, 6, ACCEPTED, 0, 0),
            (capture::kind::PICTURE, 7, ACCEPTED, 0, 0),
            (capture::kind::PICTURE, 8, ACCEPTED, 0, 0),
        ]
    );
    let delivered: Vec<&Vec<u8>> = records
        .iter()
        .filter(|(h, _)| h.kind != capture::kind::START && h.kind != capture::kind::NOT_DELIVERED)
        .map(|(_, data)| data)
        .collect();
    assert_eq!(delivered, video.iter().map(|v| &v.data).collect::<Vec<_>>());
    assert!(events.contains(&StreamEvent::FecFailure {
        frame_index: 4,
        idr_requested: false
    }));
    assert_eq!(seen.corrupt, vec![(4, 4), (4, 4)]);
    assert_eq!(app.idr_from_callback.load(Ordering::SeqCst), 1);
    assert_eq!(seen.idr, 1);

    let audio = app.audio.lock().unwrap().clone();
    let idx: Vec<u16> = audio.iter().map(|a| a.0).collect();
    assert_eq!(idx, (1..=30).collect::<Vec<u16>>());
    assert!(audio.iter().all(|a| !a.1));
    let pcm: Vec<i16> = audio[5..].iter().flat_map(|a| a.2.clone()).collect();
    let hz = left_frequency(&pcm);
    assert!((hz - 440.0).abs() < 15.0, "{hz}");
    assert_eq!(*app.haptics.lock().unwrap(), vec![1, 2, 3, 4, 5]);
    assert!(app.raw.load(Ordering::SeqCst) > 60);

    let fb: Vec<FeedbackEvent> = events
        .iter()
        .filter_map(|e| match e {
            StreamEvent::Feedback(f) => Some(*f),
            _ => None,
        })
        .collect();
    assert!(fb.contains(&FeedbackEvent::Rumble {
        left: 0xc0,
        right: 0x20
    }));
    assert!(fb.contains(&FeedbackEvent::PlayerIndex(2)));
    assert!(fb.contains(&FeedbackEvent::LightBar {
        r: 0xff,
        g: 0,
        b: 0
    }));
    assert!(fb.iter().any(|e| matches!(
        e,
        FeedbackEvent::TriggerEffects { left, right } if left[0] == 0x21 && right[0] == 0x25
    )));

    assert!(seen.states.len() >= 3, "{}", seen.states.len());
    assert!(seen.states.iter().all(|p| p.len() == 28));
    assert_eq!(seen.state_seqs[0], 0);
    assert!(seen.state_seqs.windows(2).all(|w| w[1] == w[0] + 1));
    assert!(seen.states.contains(&encode_state(&pressed, 12)));
    let cross = HistoryEvent::Button {
        code: 0x88,
        value: Some(0xff),
        pressed: true,
    };
    assert!(seen.history.iter().any(|h| h.first() == Some(&cross)));
    assert!(seen.history.iter().filter(|h| h.len() >= 18).count() >= 2);
    let fs = handle.media_stats().feedback;
    assert!(fs.refreshes >= 2 && fs.state_sent >= 3);
    assert_eq!(seen.tag_failures, 0);
    assert!(seen.disconnect);
}

#[test]
fn ps5_cloud_session_media() {
    let mut s = FakeServer::bind();
    let addr = s.addr();
    let pk = opus_tone_packets(12);
    let fake = std::thread::spawn(move || {
        let mut seen = Seen::default();
        setup(&mut s, 12, Some(0x4000));
        let mut vp = 0u16;
        send_frame(
            &mut s,
            &mut vp,
            1,
            &h265_picture(1, true, &[]),
            1,
            &[],
            false,
        );
        send_frame(
            &mut s,
            &mut vp,
            2,
            &h265_picture(2, false, &[true]),
            1,
            &[],
            false,
        );
        let mut pi = 0u16;
        for g in 1..=10u16 {
            for f in g..g + 3 {
                pi += 1;
                if pi == 5 {
                    continue;
                }
                let d = audio_datagram(12, pi, f, 1, 0, 0, 1, 5, false, &pk[usize::from(f) - 1]);
                let d = s.build_media(d, 20);
                s.send_raw(&d);
            }
        }
        for f in 1..=6u16 {
            if f == 3 {
                continue;
            }
            let d = packed_haptics_datagram(200 + f, f);
            let d = s.build_media(d, 20);
            s.send_raw(&d);
        }
        collect(
            &mut s,
            &mut seen,
            Instant::now() + Duration::from_millis(1500),
        );
        s.send_proto(
            1,
            &Message::Disconnect(Disconnect {
                reason: "Server shutting down".into(),
                extended_info: None,
            }),
        );
        collect(&mut s, &mut seen, Instant::now() + Duration::from_secs(10));
        seen
    });
    let slot = CloudSlot {
        addr,
        prefix: 0,
        ps5: true,
        session_id: "PS5-CLOUD".into(),
        handshake_key: HK,
        launch_spec: "SPEC".into(),
        mtu_in: None,
        mtu_out: None,
        rtt_us: None,
        codec: Codec::H265,
        max_fps: 60,
    };
    let app = Arc::new(App::default());
    let (etx, erx) = mpsc::channel();
    let etx = Mutex::new(etx);
    let session = Session::start(
        SessionRunnerConfig::new(Connection::Cloud(slot)),
        Arc::new(move |e| {
            let _ = etx.lock().unwrap().send(e);
        }),
        app.clone(),
    );
    let quit = loop {
        let e = erx.recv_timeout(Duration::from_secs(30)).expect("quit");
        if let SessionEvent::Quit { reason, .. } = e {
            break reason;
        }
    };
    session.join();
    assert_eq!(quit, QuitReason::StreamRemoteShutdown);
    let seen = fake.join().unwrap();
    assert!(seen.disconnect);
    let video = app.video.lock().unwrap().clone();
    assert_eq!(
        video.iter().map(|p| (p.kind, p.frame)).collect::<Vec<_>>(),
        vec![
            (SampleKind::ParameterSets, 1),
            (SampleKind::Picture, 1),
            (SampleKind::Picture, 2)
        ]
    );
    let audio = app.audio.lock().unwrap().clone();
    assert_eq!(
        audio.iter().map(|a| a.0).collect::<Vec<_>>(),
        (1..=12).collect::<Vec<u16>>()
    );
    assert!(audio.iter().all(|a| !a.1));
    assert_eq!(*app.haptics.lock().unwrap(), (1..=6).collect::<Vec<u16>>());
}
