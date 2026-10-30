mod common;
use common::{hex, seq};

use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpListener, UdpSocket};
use std::time::Duration;

use con_engine::crypto::regist::{pin_keys, unmask_pin_seed};
use con_engine::crypto::rp::RpCipher;
use con_engine::registration::{
    account_id_be, account_id_le, parse_pin, parse_response_body, parse_response_header, register,
    Identity, RegistError, RegistRequest, RegistTimeouts, FILLER_LEN,
};
use con_engine::{ApplicationReason, ConsoleKind, StopToken, Target};

const ACCOUNT: [u8; 8] = [1, 2, 3, 4, 5, 6, 7, 8];
const PIN: u32 = 12_345_678;

fn request(target: Target) -> RegistRequest {
    let mut r = RegistRequest::new(target, Identity::AccountId(ACCOUNT), PIN);
    r.seed = seq(0);
    r
}

fn body_cipher(target: Target, body: &[u8]) -> ([u8; 16], RpCipher) {
    let c0 = body[0x18d] & 0x1f;
    let c1 = body[0] >> 3;
    let mut e = [0u8; 16];
    if target.is_old_generation() {
        e.copy_from_slice(&body[0x11c..0x12c]);
    } else {
        e[..8].copy_from_slice(&body[0x191..0x199]);
        e[8..].copy_from_slice(&body[0xc7..0xcf]);
    }
    let seed = unmask_pin_seed(target, &e, c1);
    let keys = pin_keys(target, PIN, &seed, c0, c1);
    (seed, RpCipher::new(keys.key, seed, target.iv_hmac_key()))
}

#[test]
fn ps4_9_request_vector() {
    let built = request(Target::Ps4V9).build().unwrap();
    assert_eq!(built.body.len(), 530);
    assert_eq!(
        &built.body[0x11c..0x12c],
        &hex("36 3b 4b ed 0a 6a df 52 2b d9 ca af 47 e5 17 d3")[..]
    );
    assert!(built.body[..0x11c].iter().all(|&b| b == 0x41));
    assert!(built.body[0x12c..FILLER_LEN].iter().all(|&b| b == 0x41));
    assert_eq!(
        &built.body[FILLER_LEN..],
        &hex("4f 4f ee 5a 69 27 ef 76 3f c4 3c 16 68 83 cd 97 56 0a 88 06 d4 d2 00 76 4d 71 51 9f b2 ce dc 8c
              bc 77 81 07 b1 86 6a 87 87 c0 81 e3 58 a0 a2 5c 7e 85")[..]
    );
    assert_eq!(
        String::from_utf8(built.header).unwrap(),
        "POST /sce/rp/regist HTTP/1.1\r\n HTTP/1.1\r\nHOST: 10.0.2.15\r\nUser-Agent: remoteplay Windows\r\nConnection: close\r\nContent-Length: 530\r\nRP-Version: 9.0\r\n\r\n"
    );
    assert_eq!(
        request(Target::Ps4V9).inner_header().unwrap(),
        "Client-Type: Windows\r\nNp-AccountId: AQIDBAUGBwg=\r\n"
    );
}

#[test]
fn ps4_10_request_vector() {
    let built = request(Target::Ps4V10).build().unwrap();
    assert_eq!(built.body.len(), 587);
    assert_eq!(&built.body[0xc7..0xcf], &hex("df 5e d5 a5 9c f7 7e 8f")[..]);
    assert_eq!(
        &built.body[0x191..0x199],
        &hex("88 14 27 27 c2 e3 73 71")[..]
    );
    assert_eq!(
        &built.body[FILLER_LEN..],
        &hex("d3 e9 9d e4 9e 5c 46 1f 99 89 86 ff c8 e7 34 0c 77 2c 4d c9 9d 2c 84 51 7a 9b c8 51 70 88 99 79
              c3 43 fc 2e 9a e2 58 69 52 12 b5 0b c3 72 5a 00 b5 fe 40 8b e1 9a d3 94 51 60 7a 27 4a 88 16 73
              bd e6 7b 2c 6c 9a 50 ca 65 ca 64 75 d5 48 53 23 9d 91 01 38 f8 e0 a5 3c 39 bd 00 9a 83 32 a2 45
              2e a5 09 00 49 cf d3 50 90 c4 fb")[..]
    );
    let header = String::from_utf8(built.header).unwrap();
    assert!(header.starts_with("POST /sie/ps4/rp/sess/rgst HTTP/1.1\r\n HTTP/1.1\r\n"));
    assert!(header.ends_with("Content-Length: 587\r\nRP-Version: 10.0\r\n\r\n"));
}

#[test]
fn ps5_request_vector() {
    let built = request(Target::Ps5V1).build().unwrap();
    assert_eq!(built.body.len(), 587);
    assert_eq!(&built.body[0xc7..0xcf], &hex("45 26 0d 8a ec 78 65 6c")[..]);
    assert_eq!(
        &built.body[0x191..0x199],
        &hex("7b 0a 38 8c fa d1 da 43")[..]
    );
    assert_eq!(
        &built.body[FILLER_LEN..],
        &hex("27 b3 66 fd b2 31 f7 ad 85 ea 2f 89 67 e9 c2 6b fb f7 3b b4 01 c2 50 59 1b b4 98 8c ba 55 1a 56
              fa 66 5f 6c df 8b 9f 21 87 d5 77 52 9e a6 8a c7 28 50 a8 29 02 04 1a e6 92 ce 2f 8d ff a7 19 d9
              63 4f f2 68 f4 e3 d1 98 02 f7 8b e8 65 6a e0 ab 0b 07 3c df 89 a1 96 b5 b4 3b d8 c4 9d a9 4f be
              5f 8c 69 80 17 02 d8 2a cc a4 60")[..]
    );
    assert!(String::from_utf8(built.header)
        .unwrap()
        .starts_with("POST /sie/ps5/rp/sess/rgst HTTP/1.1\r\n"));
}

#[test]
fn ps4_8_has_no_version_header_and_accepts_online_id() {
    let mut r = request(Target::Ps4V8);
    r.identity = Identity::OnlineId("player".into());
    let built = r.build().unwrap();
    let header = String::from_utf8(built.header).unwrap();
    assert!(!header.contains("RP-Version"));
    assert_eq!(
        built.body.len(),
        FILLER_LEN + "Client-Type: Windows\r\nNp-Online-Id: player\r\n".len()
    );
    let mut r5 = request(Target::Ps5V1);
    r5.identity = Identity::OnlineId("player".into());
    assert!(matches!(r5.build(), Err(RegistError::AccountIdRequired)));
}

#[test]
fn key_parameters_are_read_from_the_filler() {
    let mut r = request(Target::Ps5V1);
    for (i, b) in r.filler.iter_mut().enumerate() {
        *b = (i * 7 + 3) as u8;
    }
    let built = r.build().unwrap();
    let (seed, c) = body_cipher(Target::Ps5V1, &built.body);
    assert_eq!(seed, r.seed);
    assert_eq!(
        c.decrypted(0, &built.body[FILLER_LEN..]),
        r.inner_header().unwrap().into_bytes()
    );
}

#[test]
fn account_id_and_pin_helpers() {
    let id = 1_234_567_890_123_456_789u64;
    assert_eq!(
        account_id_le(id),
        [0x15, 0x81, 0xe9, 0x7d, 0xf4, 0x10, 0x22, 0x11]
    );
    assert_eq!(
        account_id_be(id),
        [0x11, 0x22, 0x10, 0xf4, 0x7d, 0xe9, 0x81, 0x15]
    );
    let mut r = request(Target::Ps5V1);
    r.identity = Identity::AccountId(account_id_le(id));
    assert!(r
        .inner_header()
        .unwrap()
        .contains("Np-AccountId: FYHpffQQIhE=\r\n"));
    assert_eq!(parse_pin("12345678"), Some(12_345_678));
    assert_eq!(parse_pin("00000001"), Some(1));
    assert_eq!(parse_pin("1234567"), None);
    assert_eq!(parse_pin("1234567a"), None);
}

const PS5_BODY: &str = "PS5-RegistKey: 3161326233633464\r\nRP-Key: 00112233445566778899AABBCCDDEEFF\r\nPS5-Mac: 0a1b2c3d4e5f\r\nPS5-Nickname: Living room\r\nRP-KeyType: 2\r\nAP-Ssid: net\r\nRP-SupportCmd: 0x1f\r\nUnknown-Field: ignored\r\n";

#[test]
fn response_body_parsing() {
    let r = parse_response_body(PS5_BODY.as_bytes(), Target::Ps5V1).unwrap();
    assert_eq!(&r.regist_key[..8], b"1a2b3c4d");
    assert_eq!(&r.regist_key[8..], &[0u8; 8]);
    assert_eq!(r.rp_key.to_vec(), hex("00112233445566778899aabbccddeeff"));
    assert_eq!(r.mac, [0x0a, 0x1b, 0x2c, 0x3d, 0x4e, 0x5f]);
    assert_eq!(r.nickname.as_deref(), Some("Living room"));
    assert_eq!(r.key_type, Some(2));
    assert_eq!(r.support_cmd, Some(0x1f));
    assert_eq!(r.ap_ssid.as_deref(), Some("net"));
    let dbg = format!("{r:?}");
    assert!(!dbg.contains("rp_key") && !dbg.contains("regist_key"));

    assert!(matches!(
        parse_response_body(PS5_BODY.as_bytes(), Target::Ps4V10),
        Err(RegistError::MissingField(_))
    ));
    let bad_rp = PS5_BODY.replace("RP-Key: 00112233445566778899AABBCCDDEEFF", "RP-Key: 0011");
    assert!(matches!(
        parse_response_body(bad_rp.as_bytes(), Target::Ps5V1),
        Err(RegistError::MissingField("RP key"))
    ));
    let bad_mac = PS5_BODY.replace("0a1b2c3d4e5f", "0a1b2c3d4e5g");
    assert!(matches!(
        parse_response_body(bad_mac.as_bytes(), Target::Ps5V1),
        Err(RegistError::MissingField("MAC address"))
    ));
    let long_name = PS5_BODY.replace("Living room", &"x".repeat(40));
    assert_eq!(
        parse_response_body(long_name.as_bytes(), Target::Ps5V1)
            .unwrap()
            .nickname,
        None
    );
}

#[test]
fn response_header_parsing() {
    assert_eq!(
        parse_response_header(b"HTTP/1.1 200 OK\r\nContent-Length: 120\r\n\r\n").unwrap(),
        120
    );
    assert!(matches!(
        parse_response_header(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"),
        Err(RegistError::InvalidResponse(_))
    ));
    match parse_response_header(
        b"HTTP/1.1 403 Forbidden\r\nRP-Application-Reason: 0x80108b09\r\n\r\n",
    ) {
        Err(RegistError::Rejected { status, reason }) => {
            assert_eq!(status, 403);
            assert_eq!(reason, Some(ApplicationReason::RegistrationFailed));
        }
        other => panic!("{other:?}"),
    }
}

fn bind_pair() -> (TcpListener, UdpSocket) {
    for _ in 0..50 {
        let l = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = l.local_addr().unwrap().port();
        if let Ok(u) = UdpSocket::bind((Ipv4Addr::LOCALHOST, port)) {
            return (l, u);
        }
    }
    panic!("no free port pair");
}

fn fake_console(target: Target, reject: bool) -> (SocketAddr, std::thread::JoinHandle<String>) {
    let (listener, udp) = bind_pair();
    let addr = listener.local_addr().unwrap();
    let t = std::thread::spawn(move || {
        let mut buf = [0u8; 64];
        let (n, from) = udp.recv_from(&mut buf).unwrap();
        let (probe, reply, prefix): (&[u8], &[u8], &str) = match target.kind() {
            ConsoleKind::Ps4 => (b"SRC2\0", b"RES2 extra", "PS4"),
            ConsoleKind::Ps5 => (b"SRC3\0", b"RES3 extra", "PS5"),
        };
        assert_eq!(&buf[..n], probe);
        udp.send_to(b"NOISE", from).unwrap();
        udp.send_to(reply, from).unwrap();

        let (mut s, _) = listener.accept().unwrap();
        s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut data = Vec::new();
        let mut chunk = [0u8; 1024];
        let header_end = loop {
            let n = s.read(&mut chunk).unwrap();
            data.extend_from_slice(&chunk[..n]);
            if let Some(p) = data.windows(4).position(|w| w == b"\r\n\r\n") {
                break p + 4;
            }
        };
        let header = String::from_utf8(data[..header_end].to_vec()).unwrap();
        let len: usize = header
            .lines()
            .find_map(|l| l.strip_prefix("Content-Length: "))
            .unwrap()
            .parse()
            .unwrap();
        while data.len() < header_end + len {
            let n = s.read(&mut chunk).unwrap();
            data.extend_from_slice(&chunk[..n]);
        }
        let body = &data[header_end..header_end + len];
        let (_, cipher) = body_cipher(target, body);
        let inner = String::from_utf8(cipher.decrypted(0, &body[FILLER_LEN..])).unwrap();

        if reject {
            s.write_all(b"HTTP/1.1 403 Forbidden\r\nRP-Application-Reason: 80108b09\r\n\r\n")
                .unwrap();
            return inner;
        }
        let reply = PS5_BODY.replace("PS5", prefix);
        let enc = cipher.encrypted(0, reply.as_bytes());
        let head = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", enc.len());
        let mut first = head.into_bytes();
        first.extend_from_slice(&enc[..10]);
        s.write_all(&first).unwrap();
        s.flush().unwrap();
        std::thread::sleep(Duration::from_millis(30));
        s.write_all(&enc[10..]).unwrap();
        inner
    });
    (addr, t)
}

#[test]
fn registers_with_fake_ps5() {
    let (addr, fake) = fake_console(Target::Ps5V1, false);
    let req = RegistRequest::new(Target::Ps5V1, Identity::AccountId(ACCOUNT), PIN);
    let r = register(addr, &req, RegistTimeouts::default(), &StopToken::new()).unwrap();
    assert_eq!(&r.regist_key[..8], b"1a2b3c4d");
    assert_eq!(r.mac, [0x0a, 0x1b, 0x2c, 0x3d, 0x4e, 0x5f]);
    assert_eq!(r.target, Target::Ps5V1);
    let inner = fake.join().unwrap();
    assert!(inner.ends_with("Np-AccountId: AQIDBAUGBwg=\r\n"));
}

#[test]
fn registers_with_fake_old_ps4() {
    let (addr, fake) = fake_console(Target::Ps4V9, false);
    let req = RegistRequest::new(Target::Ps4V9, Identity::AccountId(ACCOUNT), PIN);
    let r = register(addr, &req, RegistTimeouts::default(), &StopToken::new()).unwrap();
    assert_eq!(r.rp_key.to_vec(), hex("00112233445566778899aabbccddeeff"));
    assert_eq!(
        fake.join().unwrap(),
        "Client-Type: Windows\r\nNp-AccountId: AQIDBAUGBwg=\r\n"
    );
}

#[test]
fn rejection_carries_the_reason() {
    let (addr, fake) = fake_console(Target::Ps4V10, true);
    let req = RegistRequest::new(Target::Ps4V10, Identity::AccountId(ACCOUNT), PIN);
    match register(addr, &req, RegistTimeouts::default(), &StopToken::new()) {
        Err(RegistError::Rejected {
            status: 403,
            reason,
        }) => {
            assert_eq!(reason, Some(ApplicationReason::RegistrationFailed))
        }
        other => panic!("{other:?}"),
    }
    fake.join().unwrap();
}

#[test]
fn silent_console_and_stop() {
    let silent = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    let addr = silent.local_addr().unwrap();
    let req = RegistRequest::new(Target::Ps5V1, Identity::AccountId(ACCOUNT), PIN);
    let t = RegistTimeouts {
        probe: Duration::from_millis(200),
        ..RegistTimeouts::default()
    };
    assert!(matches!(
        register(addr, &req, t, &StopToken::new()),
        Err(RegistError::NoProbeReply)
    ));
    let stop = StopToken::new();
    stop.stop();
    assert!(matches!(
        register(addr, &req, RegistTimeouts::default(), &stop),
        Err(RegistError::Stopped)
    ));
}
