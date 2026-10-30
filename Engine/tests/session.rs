mod common;
use common::console::{b64, listener, read_header, take_frame, NONCE, REGIST, RP_KEY, SID};
use common::hex;

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::Engine as _;
use con_engine::crypto::rp::RpCipher;
use con_engine::session::control::{
    build_control_request, encrypt_headers, parse_control_response,
};
use con_engine::session::messages::{
    decode_frame_header, encode_frame_header, fallback_session_id, feature_burst,
    keyboard_set_text_payload, mic_mute_payload, new_device_id, parse_keyboard_opened,
    parse_keyboard_text_changed, parse_session_id, ScreenGuard,
};
use con_engine::session::request::{
    build_request, evaluate, parse_session_response, target_for_console_version, Outcome,
    SessionResponse,
};
use con_engine::session::{
    request_session, start, ControlChannel, ControlConfig, ControlError, ControlEvent,
    ControlTimeouts, EventSink, QuitReason, RequestTimeouts, SessionConfig, SessionRequestError,
};
use con_engine::{ApplicationReason, Codec, ConsoleKind, ServerType, StopToken, Target};

fn unb64(s: &str) -> Vec<u8> {
    base64::engine::general_purpose::STANDARD.decode(s).unwrap()
}

#[test]
fn session_request_text_matches_the_example() {
    let addr: SocketAddr = "192.168.1.20:9295".parse().unwrap();
    assert_eq!(
        build_request(Target::Ps5V1, addr, &REGIST),
        "GET /sie/ps5/rp/sess/init HTTP/1.1\r\nHost: 192.168.1.20:9295\r\nUser-Agent: remoteplay Windows\r\nConnection: close\r\nContent-Length: 0\r\nRP-Registkey: 6131623263336434\r\nRp-Version: 1.0\r\n\r\n"
    );
    let v6: SocketAddr = "[fe80::1]:9295".parse().unwrap();
    assert!(build_request(Target::Ps4V8, v6, &REGIST)
        .starts_with("GET /sce/rp/session HTTP/1.1\r\nHost: fe80::1:9295\r\n"));
}

#[test]
fn session_response_parsing() {
    let ok = format!("HTTP/1.1 200 OK\r\nRP-Nonce: {}\r\n\r\n", b64(&NONCE));
    let r = parse_session_response(ok.as_bytes()).unwrap();
    assert_eq!(r.nonce, Some(NONCE));
    let short = format!("HTTP/1.1 200 OK\r\nRP-Nonce: {}\r\n\r\n", b64(&[1, 2, 3]));
    assert_eq!(
        parse_session_response(short.as_bytes()).unwrap().nonce,
        None
    );
    let err =
        b"HTTP/1.1 403 Forbidden\r\nrp-version: 9.0\r\nRP-Application-Reason: 0x80108b11\r\n\r\n";
    let r = parse_session_response(err).unwrap();
    assert_eq!(r.console_version.as_deref(), Some("9.0"));
    assert_eq!(r.reason, Some(ApplicationReason::VersionMismatch));
    assert!(parse_session_response(b"HTTP/1.1 200 OK\r\nX:\r\n\r\n").is_none());
}

fn resp(status: u16, version: Option<&str>, reason: Option<u32>) -> SessionResponse {
    SessionResponse {
        status,
        nonce: None,
        console_version: version.map(str::to_owned),
        reason: reason.map(ApplicationReason::from_code),
    }
}

#[test]
fn negotiation_rules() {
    use ConsoleKind::*;
    let r = resp(403, Some("9.0"), Some(0x80108b11));
    assert_eq!(
        evaluate(&r, Target::Ps4V10, Ps4, true),
        Outcome::Retry(Target::Ps4V9)
    );
    assert_eq!(
        evaluate(&r, Target::Ps4V10, Ps4, false),
        Outcome::Failed(SessionRequestError::VersionMismatch)
    );
    assert_eq!(
        evaluate(&r, Target::Ps4V9, Ps4, true),
        Outcome::Failed(SessionRequestError::VersionMismatch)
    );
    let bff = resp(403, Some("8.0"), Some(0x80108bff));
    assert_eq!(
        evaluate(&bff, Target::Ps4V10, Ps4, true),
        Outcome::Retry(Target::Ps4V8)
    );
    assert!(matches!(
        evaluate(&bff, Target::Ps4V10, Ps4, false),
        Outcome::Failed(SessionRequestError::Unknown(_))
    ));
    assert_eq!(
        evaluate(
            &resp(403, Some("7.0"), Some(0x80108b11)),
            Target::Ps4V10,
            Ps4,
            true
        ),
        Outcome::Failed(SessionRequestError::VersionMismatch)
    );
    assert_eq!(target_for_console_version(Ps5, "5.0"), Some(Target::Ps4V9));
    assert_eq!(target_for_console_version(Ps5, "2.0"), None);
    assert_eq!(target_for_console_version(Ps4, "1.0"), None);
    let in_use = resp(403, None, Some(0x80108b10));
    assert_eq!(
        evaluate(&in_use, Target::Ps5V1, Ps5, true),
        Outcome::Failed(SessionRequestError::InUse)
    );
    let crashed = resp(403, None, Some(0x80108b15));
    assert_eq!(
        evaluate(&crashed, Target::Ps5V1, Ps5, true),
        Outcome::Failed(SessionRequestError::Crashed)
    );
    for code in [0x80108b02, 0x80108b09, 0x12345678] {
        assert!(matches!(
            evaluate(&resp(403, None, Some(code)), Target::Ps5V1, Ps5, true),
            Outcome::Failed(SessionRequestError::Unknown(_))
        ));
    }
    assert!(matches!(
        evaluate(&resp(200, None, None), Target::Ps5V1, Ps5, true),
        Outcome::Failed(SessionRequestError::Unknown(_))
    ));
}

#[test]
fn quit_reasons() {
    assert!(!QuitReason::Stopped.is_error());
    assert!(!QuitReason::for_remote_disconnect("Server shutting down").is_error());
    assert_eq!(
        QuitReason::for_remote_disconnect("Bye"),
        QuitReason::StreamRemoteDisconnected
    );
    assert!(QuitReason::ControlConnectFailed.is_error());
    assert_eq!(
        QuitReason::from(&SessionRequestError::InUse),
        QuitReason::SessionRequestInUse
    );
    assert_eq!(
        QuitReason::from(&ControlError::Failed("x".into())),
        QuitReason::ControlUnknown
    );
}

#[test]
fn message_formats() {
    assert_eq!(
        encode_frame_header(16, 0x0036),
        [0, 0, 0, 16, 0, 0x36, 0, 0]
    );
    assert_eq!(
        decode_frame_header(&[0, 0, 1, 2, 0x80, 0x04, 9, 9]),
        (0x102, 0x8004)
    );
    assert_eq!(mic_mute_payload(true), [0, 1, 0, 0x59]);
    assert_eq!(mic_mute_payload(false), [0, 1, 1, 0x59]);
    let p = keyboard_set_text_payload(1, "hé");
    assert_eq!(p.len(), 36 + 3);
    assert_eq!(&p[..8], &[0, 0, 0, 1, 0, 0, 0, 3]);
    assert!(p[8..32].iter().all(|&b| b == 0));
    assert_eq!(&p[32..36], &[0, 0, 0, 3]);
    assert_eq!(&p[36..], "hé".as_bytes());

    let mut opened = vec![0u8; 28];
    opened.extend_from_slice(&5u32.to_be_bytes());
    opened.extend_from_slice(b"hello");
    assert_eq!(parse_keyboard_opened(&opened).as_deref(), Some("hello"));
    assert_eq!(parse_keyboard_opened(&opened[..31]), None);
    assert_eq!(parse_keyboard_opened(&opened[..34]).as_deref(), Some("he"));

    let mut changed = vec![0u8; 40];
    changed[3] = 7;
    changed[11] = 3;
    changed.extend_from_slice(b"abc");
    assert_eq!(
        parse_keyboard_text_changed(&changed),
        Some((7, "abc".into()))
    );
    assert_eq!(parse_keyboard_text_changed(&changed[..39]), None);

    let mut sid = vec![0x4a];
    sid.extend_from_slice(SID.as_bytes());
    assert_eq!(parse_session_id(&sid).as_deref(), Some(SID));
    assert_eq!(parse_session_id(&sid[..24]), None);
    assert_eq!(parse_session_id(&sid[..25]).as_deref(), Some(&SID[..24]));
    let mut long = vec![0x4a];
    long.extend(std::iter::repeat_n(b'a', 126));
    assert!(parse_session_id(&long).is_some());
    long.push(b'a');
    assert!(parse_session_id(&long).is_none());
    let mut bad = sid.clone();
    bad[5] = b'-';
    assert!(parse_session_id(&bad).is_none());
    assert!(parse_session_id(&[0x4a]).is_none());

    let d = new_device_id();
    assert_eq!(
        &d[..10],
        &[0x00, 0x18, 0x00, 0x00, 0x00, 0x07, 0x00, 0x40, 0x00, 0x80]
    );
    assert_eq!(&d[26..], &[0u8; 6]);
    assert_ne!(d, new_device_id());

    let f = fallback_session_id();
    let (secs, rnd) = f.split_at(f.len() - 64);
    assert!((1..=15).contains(&secs.len()));
    assert!(secs.bytes().all(|b| b.is_ascii_digit()));
    assert_eq!(unb64(rnd).len(), 48);

    let burst = feature_burst(true, true);
    let types: Vec<u16> = burst.iter().map(|(t, _)| *t).collect();
    assert_eq!(
        types,
        [0x0013, 0x0011, 0x000d, 0x0020, 0x0036, 0x0036, 0x0910]
    );
    let plain: Vec<u16> = feature_burst(false, false)
        .iter()
        .map(|(t, _)| *t)
        .collect();
    assert_eq!(plain, [0x0036, 0x0036, 0x0910]);
}

#[test]
fn screen_guard_and_blackout() {
    let mut d = ScreenGuard::default();
    assert_eq!(d.on_blackout(&[0, 0]), None);
    assert_eq!(d.on_guard(&[1]), None);
    assert_eq!(d.on_blackout(&[1, 0xff]), None);
    assert_eq!(d.on_blackout(&[0, 0]), Some(true));
    assert_eq!(d.on_blackout(&[0, 0]), None);
    assert_eq!(d.on_guard(&[0]), None);
    assert_eq!(d.on_blackout(&[1, 0xff]), None);
    assert_eq!(d.on_guard(&[0]), Some(false));
    assert_eq!(d.on_guard(&[]), None);
    assert_eq!(d.on_blackout(&[1]), None);
}

#[test]
fn control_headers_and_response() {
    let c = RpCipher::for_session(Target::Ps5V1, &NONCE, &RP_KEY);
    let did = new_device_id();
    let h = encrypt_headers(&c, Target::Ps5V1, &REGIST, &did, Codec::H265Hdr);
    assert_eq!(h.auth, "pyiUWcXRol4iGog9D7bVJw==");
    assert_eq!(h.os_type, "u94GJgtEC9J2AA==");
    assert_eq!(c.decrypted(1, &unb64(&h.did)), did.to_vec());
    assert_eq!(
        c.decrypted(3, &unb64(h.start_bitrate.as_ref().unwrap())),
        vec![0; 4]
    );
    assert_eq!(
        c.decrypted(4, &unb64(h.streaming_type.as_ref().unwrap())),
        vec![3, 0, 0, 0]
    );
    assert_eq!(h.next_counter, 5);
    let addr: SocketAddr = "192.168.1.20:9295".parse().unwrap();
    let text = build_control_request(Target::Ps5V1, addr, &h);
    let lines: Vec<&str> = text.split("\r\n").collect();
    assert_eq!(lines[0], "GET /sie/ps5/rp/sess/ctrl HTTP/1.1");
    assert_eq!(lines[3], "Connection: keep-alive");
    let names: Vec<&str> = lines[1..lines.len() - 2]
        .iter()
        .map(|l| l.split(':').next().unwrap())
        .collect();
    assert_eq!(
        names,
        [
            "Host",
            "User-Agent",
            "Connection",
            "Content-Length",
            "RP-Auth",
            "RP-Version",
            "RP-Did",
            "RP-ControllerType",
            "RP-ClientType",
            "RP-OSType",
            "RP-ConPath",
            "RP-StartBitrate",
            "RP-StreamingType"
        ]
    );
    assert!(text.ends_with("\r\n\r\n"));

    let old = encrypt_headers(&c, Target::Ps4V8, &REGIST, &did, Codec::H264);
    assert_eq!(
        (
            old.start_bitrate.is_none(),
            old.streaming_type.is_none(),
            old.next_counter
        ),
        (true, true, 3)
    );
    let p4 = encrypt_headers(&c, Target::Ps4V10, &REGIST, &did, Codec::H264);
    assert_eq!(
        (
            p4.start_bitrate.is_some(),
            p4.streaming_type.is_none(),
            p4.next_counter
        ),
        (true, true, 4)
    );

    let mut st = [0u8; 16];
    st[0] = 1;
    let enc = c.encrypted(0, &st);
    let header = format!(
        "HTTP/1.1 200 OK\r\nRP-Server-Type: {}\r\nRP-Prohibit: 1\r\n\r\n",
        b64(&enc)
    );
    let (info, consumed) = parse_control_response(header.as_bytes(), &c).unwrap();
    assert_eq!(info.server_type, Some(ServerType::Ps4Pro));
    assert!(info.prohibit && consumed);
    let (info, consumed) = parse_control_response(
        format!(
            "HTTP/1.1 200 OK\r\nRP-Server-Type: {}\r\n\r\n",
            b64(&[1; 8])
        )
        .as_bytes(),
        &c,
    )
    .unwrap();
    assert_eq!((info.server_type, consumed), (None, false));
    assert!(parse_control_response(
        format!(
            "HTTP/1.1 200 OK\r\nRP-Server-Type: {}\r\n\r\n",
            b64(&[1; 17])
        )
        .as_bytes(),
        &c
    )
    .is_err());
    assert!(parse_control_response(b"HTTP/1.1 200 OK\r\nRP-Server-Type: !!!\r\n\r\n", &c).is_err());
    assert!(parse_control_response(b"HTTP/1.1 403 Forbidden\r\n\r\n", &c).is_err());
}

fn header_map(text: &str) -> HashMap<String, String> {
    text.split("\r\n")
        .skip(1)
        .filter_map(|l| l.split_once(": "))
        .map(|(a, b)| (a.to_string(), b.to_string()))
        .collect()
}

fn answer_session_request(l: &TcpListener, response: &str) -> String {
    let (mut s, _) = l.accept().unwrap();
    s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let (req, _) = read_header(&mut s);
    s.write_all(response.as_bytes()).unwrap();
    req
}

fn nonce_response() -> String {
    format!(
        "HTTP/1.1 200 OK\r\nRP-Nonce: {}\r\nRP-Version: 1.0\r\n\r\n",
        b64(&NONCE)
    )
}

struct FakeControl {
    s: TcpStream,
    cipher: RpCipher,
    to_client: u64,
    from_client: u64,
    buf: Vec<u8>,
    headers: HashMap<String, String>,
    request: String,
}

impl FakeControl {
    fn accept(
        l: &TcpListener,
        cipher: RpCipher,
        server_type: Option<u8>,
        extra_headers: &str,
        client_counter: u64,
    ) -> Self {
        let (mut s, _) = l.accept().unwrap();
        s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let (request, rest) = read_header(&mut s);
        let headers = header_map(&request);
        let mut resp = String::from("HTTP/1.1 200 OK\r\n");
        let mut to_client = 0;
        if let Some(t) = server_type {
            let mut v = [0u8; 16];
            v[0] = t;
            resp.push_str(&format!(
                "RP-Server-Type: {}\r\n",
                b64(&cipher.encrypted(0, &v))
            ));
            to_client = 1;
        }
        resp.push_str(extra_headers);
        resp.push_str("\r\n");
        let mut f = FakeControl {
            s,
            cipher,
            to_client,
            from_client: client_counter,
            buf: rest,
            headers,
            request,
        };
        let mut bytes = resp.into_bytes();
        bytes.extend_from_slice(&encode_frame_header(0, 0x00fe));
        f.s.write_all(&bytes).unwrap();
        f
    }

    fn send(&mut self, ty: u16, payload: &[u8]) {
        let mut body = payload.to_vec();
        if !body.is_empty() {
            self.cipher.encrypt(self.to_client, &mut body);
            self.to_client += 1;
        }
        let mut out = encode_frame_header(body.len() as u32, ty).to_vec();
        out.extend_from_slice(&body);
        self.s.write_all(&out).unwrap();
    }

    fn recv(&mut self) -> (u16, Vec<u8>) {
        let mut chunk = [0u8; 1024];
        loop {
            if let Some(frame) = take_frame(&mut self.buf, &self.cipher, &mut self.from_client) {
                return frame;
            }
            let n = self.s.read(&mut chunk).unwrap();
            assert!(n > 0, "client closed");
            self.buf.extend_from_slice(&chunk[..n]);
        }
    }

    fn expect(&mut self, ty: u16) -> Vec<u8> {
        let (t, p) = self.recv();
        assert_eq!(t, ty, "expected message {ty:#06x}, got {t:#06x}");
        p
    }
}

fn event_channel() -> (EventSink, Receiver<ControlEvent>) {
    let (tx, rx) = mpsc::channel();
    let tx = Mutex::new(tx);
    let sink: EventSink = Arc::new(move |e| {
        let _ = tx.lock().unwrap().send(e);
    });
    (sink, rx)
}

fn control_config(addr: SocketAddr, target: Target, cipher: &RpCipher) -> ControlConfig {
    ControlConfig {
        console_addr: addr,
        target,
        regist_key: REGIST,
        cipher: cipher.clone(),
        codec: Codec::H265,
        dualsense: true,
        keyboard: true,
        device_id: new_device_id(),
        timeouts: ControlTimeouts::default(),
    }
}

const WAIT: Duration = Duration::from_secs(5);

fn wait_until(limit: Duration, mut done: impl FnMut() -> bool) -> bool {
    let end = Instant::now() + limit;
    while !done() {
        if Instant::now() >= end {
            return false;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    true
}

#[test]
fn session_request_negotiates_down_to_ps4_9() {
    let (l, addr) = listener();
    let fake = std::thread::spawn(move || {
        let r1 = answer_session_request(
            &l,
            "HTTP/1.1 403 Forbidden\r\nRP-Version: 9.0\r\nRP-Application-Reason: 80108b11\r\n\r\n",
        );
        let r2 = answer_session_request(&l, &nonce_response());
        (r1, r2)
    });
    let grant = request_session(
        "127.0.0.1",
        addr.port(),
        ConsoleKind::Ps4,
        &REGIST,
        RequestTimeouts::default(),
        &StopToken::new(),
    )
    .unwrap();
    assert_eq!(grant.target, Target::Ps4V9);
    assert_eq!(grant.nonce, NONCE);
    assert_eq!(grant.console_addr, addr);
    let (r1, r2) = fake.join().unwrap();
    assert!(r1.starts_with("GET /sie/ps4/rp/sess/init HTTP/1.1\r\n"));
    assert!(r1.contains("Rp-Version: 10.0\r\n"));
    assert!(r1.contains(&format!("Host: 127.0.0.1:{}\r\n", addr.port())));
    assert!(r2.starts_with("GET /sce/rp/session HTTP/1.1\r\n"));
    assert!(r2.contains("Rp-Version: 9.0\r\n"));
}

#[test]
fn session_request_gives_up_after_three_attempts() {
    let (l, addr) = listener();
    let fake = std::thread::spawn(move || {
        for v in ["9.0", "8.0", "10.0"] {
            answer_session_request(
                &l,
                &format!("HTTP/1.1 403 Forbidden\r\nRP-Version: {v}\r\nRP-Application-Reason: 80108b11\r\n\r\n"),
            );
        }
    });
    let r = request_session(
        "127.0.0.1",
        addr.port(),
        ConsoleKind::Ps4,
        &REGIST,
        RequestTimeouts::default(),
        &StopToken::new(),
    );
    assert_eq!(r.unwrap_err(), SessionRequestError::VersionMismatch);
    assert!(
        wait_until(Duration::from_secs(5), || fake.is_finished()),
        "client stopped before the third attempt"
    );
    fake.join().unwrap();
}

#[test]
fn session_request_errors() {
    let (l, addr) = listener();
    let fake = std::thread::spawn(move || {
        answer_session_request(
            &l,
            "HTTP/1.1 403 Forbidden\r\nRP-Application-Reason: 80108b10\r\n\r\n",
        );
    });
    let r = request_session(
        "127.0.0.1",
        addr.port(),
        ConsoleKind::Ps5,
        &REGIST,
        RequestTimeouts::default(),
        &StopToken::new(),
    );
    assert_eq!(r.unwrap_err(), SessionRequestError::InUse);
    fake.join().unwrap();

    let (l, addr) = listener();
    drop(l);
    let r = request_session(
        "127.0.0.1",
        addr.port(),
        ConsoleKind::Ps5,
        &REGIST,
        RequestTimeouts::default(),
        &StopToken::new(),
    );
    assert_eq!(r.unwrap_err(), SessionRequestError::ConnectionRefused);

    let (l, addr) = listener();
    let stop = StopToken::new();
    let s2 = stop.clone();
    let t = std::thread::spawn(move || {
        let (_s, _) = l.accept().unwrap();
        std::thread::sleep(Duration::from_millis(150));
        s2.stop();
        std::thread::sleep(Duration::from_millis(300));
    });
    let r = request_session(
        "127.0.0.1",
        addr.port(),
        ConsoleKind::Ps5,
        &REGIST,
        RequestTimeouts::default(),
        &stop,
    );
    assert_eq!(r.unwrap_err(), SessionRequestError::Stopped);
    t.join().unwrap();
}

#[test]
fn control_channel_full_conversation_ps5() {
    let (l, addr) = listener();
    let cipher = RpCipher::for_session(Target::Ps5V1, &NONCE, &RP_KEY);
    let fc = cipher.clone();
    let (sink, events) = event_channel();
    let console = std::thread::spawn(move || FakeControl::accept(&l, fc, Some(2), "", 5));
    let config = control_config(addr, Target::Ps5V1, &cipher);
    let ctrl = ControlChannel::connect(&config, sink, &StopToken::new()).unwrap();
    let mut f = console.join().unwrap();

    assert!(f
        .request
        .starts_with("GET /sie/ps5/rp/sess/ctrl HTTP/1.1\r\n"));
    let h = &f.headers;
    assert_eq!(cipher.decrypted(0, &unb64(&h["RP-Auth"])), REGIST.to_vec());
    assert_eq!(
        cipher.decrypted(1, &unb64(&h["RP-Did"])),
        config.device_id.to_vec()
    );
    assert_eq!(
        cipher.decrypted(2, &unb64(&h["RP-OSType"])),
        b"Win10.0.0\0".to_vec()
    );
    assert_eq!(
        cipher.decrypted(3, &unb64(&h["RP-StartBitrate"])),
        vec![0; 4]
    );
    assert_eq!(
        cipher.decrypted(4, &unb64(&h["RP-StreamingType"])),
        vec![2, 0, 0, 0]
    );
    assert_eq!(h["RP-Version"], "1.0");
    assert_eq!(
        (
            h["RP-ControllerType"].as_str(),
            h["RP-ClientType"].as_str(),
            h["RP-ConPath"].as_str()
        ),
        ("3", "11", "1")
    );
    assert_eq!(ctrl.info().server_type, Some(ServerType::Ps5));
    assert!(!ctrl.info().prohibit);

    assert_eq!(f.expect(0x01fe), Vec::<u8>::new());

    let handle = ctrl.handle();
    let waiter = std::thread::spawn(move || handle.wait_session_id(&StopToken::new()));
    f.send(0x0004, &[]);
    assert_eq!(
        events.recv_timeout(WAIT).unwrap(),
        ControlEvent::PinRequested {
            previous_wrong: false
        }
    );
    ctrl.submit_pin("1234").unwrap();
    assert_eq!(f.expect(0x8004), b"1234".to_vec());
    assert_eq!(f.from_client, 6);
    f.send(0x0005, &[1]);
    assert_eq!(
        events.recv_timeout(WAIT).unwrap(),
        ControlEvent::PinRequested {
            previous_wrong: true
        }
    );
    ctrl.submit_pin("5678").unwrap();
    assert_eq!(f.expect(0x8004), b"5678".to_vec());
    f.send(0x0005, &[0]);
    let mut sid = vec![0x4a];
    sid.extend_from_slice(SID.as_bytes());
    f.send(0x0033, &sid);
    let id = waiter.join().unwrap().unwrap();
    assert_eq!(id.id, SID);
    assert!(!id.fallback);
    assert_eq!(ctrl.session_id().unwrap().id, SID);

    assert_eq!(f.expect(0x0013), vec![0x00, 0x40, 0x00]);
    assert_eq!(
        f.expect(0x0011),
        hex("a0 ab 51 bd d1 7e 00 00 ff ff ff ff ff 00 00 00")
    );
    assert_eq!(
        f.expect(0x000d),
        hex("00 00 00 01 00 00 05 ae 00 00 00 00 00 00 00 00")
    );
    assert_eq!(f.expect(0x0020), vec![0x01]);
    assert_eq!(f.expect(0x0036), vec![0x00, 0x01, 0x01, 0x59]);
    assert_eq!(f.expect(0x0036), vec![0x00, 0x01, 0x01, 0x59]);
    assert_eq!(f.expect(0x0910), vec![0, 0, 0, 0]);

    f.send(0x0001, &[1]);
    f.send(0x0016, &[0, 0]);
    assert_eq!(
        events.recv_timeout(WAIT).unwrap(),
        ControlEvent::CannotDisplay(true)
    );
    f.send(0x0016, &[1, 0xff]);
    f.send(0x0001, &[0]);
    assert_eq!(
        events.recv_timeout(WAIT).unwrap(),
        ControlEvent::CannotDisplay(false)
    );

    let mut opened = vec![0u8; 28];
    opened.extend_from_slice(&5u32.to_be_bytes());
    opened.extend_from_slice(b"hello");
    f.send(0x0021, &opened);
    assert_eq!(
        events.recv_timeout(WAIT).unwrap(),
        ControlEvent::KeyboardOpened("hello".into())
    );
    let mut changed = vec![0u8; 40];
    changed[11] = 3;
    changed.extend_from_slice(b"abc");
    f.send(0x0024, &changed);
    assert_eq!(
        events.recv_timeout(WAIT).unwrap(),
        ControlEvent::KeyboardTextChanged("abc".into())
    );
    f.send(0x0022, &[]);
    assert_eq!(
        events.recv_timeout(WAIT).unwrap(),
        ControlEvent::KeyboardClosedRemotely
    );
    f.send(0x7777, &[1, 2, 3]);

    ctrl.keyboard_set_text("hi").unwrap();
    assert_eq!(f.expect(0x0023), keyboard_set_text_payload(1, "hi"));
    ctrl.keyboard_set_text("hip").unwrap();
    assert_eq!(f.expect(0x0023), keyboard_set_text_payload(2, "hip"));
    ctrl.keyboard_accept().unwrap();
    assert_eq!(f.expect(0x0025), vec![0, 0, 0, 0]);
    ctrl.keyboard_cancel().unwrap();
    assert_eq!(f.expect(0x0025), vec![0, 0, 0, 1]);
    ctrl.set_microphone_muted(true).unwrap();
    assert_eq!(f.expect(0x0036), vec![0, 1, 0, 0x59]);
    ctrl.go_home().unwrap();
    assert_eq!(
        f.expect(0x0014),
        hex("00 ff 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
    );
    let before = f.from_client;
    ctrl.sleep().unwrap();
    assert_eq!(f.expect(0x0050), Vec::<u8>::new());
    assert_eq!(f.from_client, before);
    ctrl.microphone_connect().unwrap();
    assert_eq!(f.expect(0x0030), vec![0, 0]);

    f.send(0x00fe, &[]);
    assert_eq!(f.expect(0x01fe), Vec::<u8>::new());
    let mut other = vec![0x4a];
    other.extend_from_slice(b"ZZZZZZZZZZZZZZZZZZZZZZZZZZZZ");
    f.send(0x0033, &other);
    assert_eq!(f.expect(0x0013), vec![0x00, 0x40, 0x00]);
    assert_eq!(ctrl.session_id().unwrap().id, SID);

    f.send(0x0004, &[]);
    wait_until(Duration::from_secs(1), || ctrl.failure().is_some());
    assert!(matches!(ctrl.failure(), Some(ControlError::Failed(_))));
    ctrl.close();
}

#[test]
fn control_channel_old_ps4_without_server_type_and_invalid_id() {
    let (l, addr) = listener();
    let cipher = RpCipher::for_session(Target::Ps4V8, &NONCE, &RP_KEY);
    let fc = cipher.clone();
    let console =
        std::thread::spawn(move || FakeControl::accept(&l, fc, None, "RP-Prohibit: 1\r\n", 3));
    let (sink, events) = event_channel();
    let mut config = control_config(addr, Target::Ps4V8, &cipher);
    config.dualsense = false;
    config.keyboard = false;
    let ctrl = ControlChannel::connect(&config, sink, &StopToken::new()).unwrap();
    let mut f = console.join().unwrap();
    assert!(f
        .request
        .starts_with("GET /sce/rp/session/ctrl HTTP/1.1\r\n"));
    assert!(!f.headers.contains_key("RP-StartBitrate"));
    assert!(!f.headers.contains_key("RP-StreamingType"));
    assert_eq!(ctrl.info().server_type, None);
    assert_eq!(
        events.recv_timeout(WAIT).unwrap(),
        ControlEvent::CannotDisplay(true)
    );
    f.expect(0x01fe);

    assert_eq!(f.to_client, 0);
    f.send(0x0033, b"\x4ashort");
    let id = ctrl.wait_session_id(&StopToken::new()).unwrap();
    assert!(id.fallback);
    assert_eq!(f.expect(0x0036), vec![0, 1, 1, 0x59]);
    assert_eq!(f.from_client, 4);
    assert_eq!(f.expect(0x0036), vec![0, 1, 1, 0x59]);
    assert_eq!(f.expect(0x0910), vec![0; 4]);
    drop(ctrl);
}

#[test]
fn control_channel_fallback_after_timeout_and_remote_close() {
    let (l, addr) = listener();
    let cipher = RpCipher::for_session(Target::Ps4V10, &NONCE, &RP_KEY);
    let fc = cipher.clone();
    let console = std::thread::spawn(move || FakeControl::accept(&l, fc, Some(0), "", 4));
    let (sink, _events) = event_channel();
    let mut config = control_config(addr, Target::Ps4V10, &cipher);
    config.dualsense = false;
    config.keyboard = false;
    config.timeouts.session_id = Duration::from_millis(300);
    let ctrl = ControlChannel::connect(&config, sink, &StopToken::new()).unwrap();
    let mut f = console.join().unwrap();
    assert_eq!(ctrl.info().server_type, Some(ServerType::Ps4));
    f.expect(0x01fe);
    let id = ctrl.wait_session_id(&StopToken::new()).unwrap();
    assert!(id.fallback);
    assert_eq!(f.expect(0x0036), vec![0, 1, 1, 0x59]);
    assert_eq!(f.from_client, 5);
    f.expect(0x0036);
    f.expect(0x0910);

    drop(f);
    assert!(wait_until(Duration::from_secs(1), || ctrl.remote_closed()));
    assert_eq!(ctrl.failure(), None);
}

#[test]
fn control_request_is_resent_once_after_a_timeout() {
    let (l, addr) = listener();
    let cipher = RpCipher::for_session(Target::Ps5V1, &NONCE, &RP_KEY);
    let fc = cipher.clone();
    let console = std::thread::spawn(move || {
        let (mut s1, _) = l.accept().unwrap();
        s1.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let (first, _) = read_header(&mut s1);
        let f = FakeControl::accept(&l, fc, Some(2), "", 5);
        (first, f)
    });
    let (sink, _events) = event_channel();
    let mut config = control_config(addr, Target::Ps5V1, &cipher);
    config.timeouts.response = Duration::from_millis(300);
    let ctrl = ControlChannel::connect(&config, sink, &StopToken::new()).unwrap();
    let (first, f) = console.join().unwrap();
    assert_eq!(first, f.request, "the resend is byte-identical");
    assert_eq!(ctrl.info().server_type, Some(ServerType::Ps5));
}

#[test]
fn control_connect_failures() {
    let cipher = RpCipher::for_session(Target::Ps5V1, &NONCE, &RP_KEY);
    let (sink, _e) = event_channel();
    let (l, addr) = listener();
    let t =
        std::thread::spawn(move || answer_session_request(&l, "HTTP/1.1 403 Forbidden\r\n\r\n"));
    let r = ControlChannel::connect(
        &control_config(addr, Target::Ps5V1, &cipher),
        sink.clone(),
        &StopToken::new(),
    );
    assert!(matches!(r, Err(ControlError::ConnectFailed(_))));
    t.join().unwrap();
    let (l, addr) = listener();
    let t = std::thread::spawn(move || {
        let mut held = Vec::new();
        for _ in 0..2 {
            let (s, _) = l.accept().unwrap();
            held.push(s);
        }
        std::thread::sleep(Duration::from_millis(400));
    });
    let mut config = control_config(addr, Target::Ps5V1, &cipher);
    config.timeouts.response = Duration::from_millis(100);
    let r = ControlChannel::connect(&config, sink.clone(), &StopToken::new());
    assert!(matches!(r, Err(ControlError::ConnectFailed(_))));
    t.join().unwrap();
    let (l, addr) = listener();
    drop(l);
    let r = ControlChannel::connect(
        &control_config(addr, Target::Ps5V1, &cipher),
        sink,
        &StopToken::new(),
    );
    assert!(matches!(r, Err(ControlError::ConnectFailed(_))));
}

#[test]
fn oversize_message_fails_the_channel() {
    let (l, addr) = listener();
    let cipher = RpCipher::for_session(Target::Ps5V1, &NONCE, &RP_KEY);
    let fc = cipher.clone();
    let console = std::thread::spawn(move || FakeControl::accept(&l, fc, Some(2), "", 5));
    let (sink, _e) = event_channel();
    let ctrl = ControlChannel::connect(
        &control_config(addr, Target::Ps5V1, &cipher),
        sink,
        &StopToken::new(),
    )
    .unwrap();
    let mut f = console.join().unwrap();
    f.expect(0x01fe);
    f.s.write_all(&encode_frame_header(10_000_000, 0x0001))
        .unwrap();
    let r = ctrl.wait_session_id(&StopToken::new());
    assert!(matches!(r, Err(ControlError::Failed(_))));
}

#[test]
fn whole_session_start_against_a_fake_ps4() {
    let (l, addr) = listener();
    let console = std::thread::spawn(move || {
        let req = answer_session_request(&l, &nonce_response());
        let cipher = RpCipher::for_session(Target::Ps4V10, &NONCE, &RP_KEY);
        let mut f = FakeControl::accept(&l, cipher, Some(1), "", 4);
        f.expect(0x01fe);
        let mut sid = vec![0x4a];
        sid.extend_from_slice(SID.as_bytes());
        f.send(0x0033, &sid);
        f.expect(0x0036);
        f.expect(0x0036);
        f.expect(0x0910);
        (req, f)
    });
    let mut config = SessionConfig::new("127.0.0.1", ConsoleKind::Ps4, REGIST, RP_KEY);
    config.port = addr.port();
    let (sink, _events) = event_channel();
    let mut got_handle = false;
    let session = start(&config, sink, |_h| got_handle = true, &StopToken::new()).unwrap();
    assert!(got_handle);
    assert_eq!(session.target, Target::Ps4V10);
    assert_eq!(session.session_id.id, SID);
    assert_eq!(session.control.info().server_type, Some(ServerType::Ps4Pro));
    assert_eq!(
        session.cipher,
        RpCipher::for_session(Target::Ps4V10, &NONCE, &RP_KEY)
    );
    let (req, _f) = console.join().unwrap();
    assert!(req.contains("RP-Registkey: 6131623263336434\r\n"));
}

#[test]
fn session_start_reports_quit_reasons() {
    let (l, addr) = listener();
    let console = std::thread::spawn(move || {
        answer_session_request(&l, &nonce_response());
        answer_session_request(&l, "HTTP/1.1 500 Error\r\n\r\n");
    });
    let mut config = SessionConfig::new("127.0.0.1", ConsoleKind::Ps5, REGIST, RP_KEY);
    config.port = addr.port();
    let (sink, _e) = event_channel();
    let err = start(&config, sink.clone(), |_| {}, &StopToken::new())
        .err()
        .unwrap();
    assert_eq!(err.reason, QuitReason::ControlConnectFailed);
    console.join().unwrap();

    let stop = StopToken::new();
    stop.stop();
    let err = start(&config, sink, |_| {}, &stop).err().unwrap();
    assert_eq!(err.reason, QuitReason::Stopped);
}
