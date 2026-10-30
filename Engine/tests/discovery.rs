use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket};
use std::sync::mpsc;
use std::time::Duration;

use con_engine::discovery::{
    generation, parse_search_response, search_message, wake, wake_credential, wakeup_message,
    ConsoleState, DiscoveredHost, DiscoveryConfig, DiscoveryService,
};
use con_engine::{ConsoleKind, Target};

const LOCAL: IpAddr = IpAddr::V4(Ipv4Addr::LOCALHOST);

fn key_text(t: &str) -> [u8; 16] {
    let mut k = [0u8; 16];
    k[..t.len()].copy_from_slice(t.as_bytes());
    k
}

#[test]
fn search_messages() {
    assert_eq!(
        search_message(ConsoleKind::Ps4),
        b"SRCH * HTTP/1.1\ndevice-discovery-protocol-version:00020020\n\0".to_vec()
    );
    assert_eq!(
        search_message(ConsoleKind::Ps5),
        b"SRCH * HTTP/1.1\ndevice-discovery-protocol-version:00030010\n\0".to_vec()
    );
}

#[test]
fn wake_credential_and_message() {
    assert_eq!(wake_credential(&key_text("1a2b3c4d")), Some(439_041_101));
    assert_eq!(wake_credential(&key_text("1a2b3c4d5")), None);
    assert_eq!(wake_credential(&key_text("xyz")), None);
    assert_eq!(wake_credential(&[0u8; 16]), None);
    assert_eq!(
        wakeup_message(ConsoleKind::Ps5, 439_041_101),
        b"WAKEUP * HTTP/1.1\nclient-type:vr\nauth-type:R\nmodel:w\napp-type:r\nuser-credential:439041101\ndevice-discovery-protocol-version:00030010\n\0".to_vec()
    );
}

const SAMPLE: &[u8] = b"HTTP/1.1 620 Server Standby\nhost-id:0123456789AB\nhost-type:PS5\nhost-name:Living room\nhost-request-port:997\ndevice-discovery-protocol-version:00030010\nsystem-version:08520011\n";

#[test]
fn parses_the_sample_response() {
    let h = parse_search_response(SAMPLE, LOCAL).unwrap();
    assert_eq!(h.status, 620);
    assert_eq!(h.state, ConsoleState::Standby);
    assert_eq!(h.host_id, "0123456789AB");
    assert_eq!(h.host_type.as_deref(), Some("PS5"));
    assert_eq!(h.host_name.as_deref(), Some("Living room"));
    assert_eq!(h.request_port, Some(997));
    assert_eq!(h.kind(), ConsoleKind::Ps5);
    assert_eq!(h.generation(), Some(Target::Ps5V1));
    assert_eq!(h.running_app_name, None);
}

#[test]
fn tolerant_parsing() {
    let d = b"HTTP/1.1 200 Ok\r\nhost-id:AB\r\nbroken\r\nhost-name:\r\n\r\nrunning-app-name: Game\r\n\0host-type:PS4";
    let h = parse_search_response(d, LOCAL).unwrap();
    assert_eq!(h.state, ConsoleState::Ready);
    assert_eq!(h.host_name, None);
    assert_eq!(h.running_app_name.as_deref(), Some("Game"));
    assert_eq!(h.host_type, None);
    assert_eq!(h.kind(), ConsoleKind::Ps4);
    assert!(parse_search_response(b"HTTP/1.1 200 Ok\nhost-name:x\n", LOCAL).is_none());
    assert!(parse_search_response(b"HTTP/1.0 200 Ok\nhost-id:x\n", LOCAL).is_none());
    let other = parse_search_response(b"HTTP/1.1 500 x\nhost-id:x\n", LOCAL).unwrap();
    assert_eq!(other.state, ConsoleState::Unknown);
}

#[test]
fn generation_rules() {
    use ConsoleKind::*;
    assert_eq!(generation(Ps5, "08520011"), Some(Target::Ps5V1));
    assert_eq!(generation(Ps5, "8050001"), Some(Target::Ps5V1));
    assert_eq!(generation(Ps5, "8050000"), None);
    assert_eq!(generation(Ps4, "08000000"), Some(Target::Ps4V10));
    assert_eq!(generation(Ps4, "07020001"), Some(Target::Ps4V9));
    assert_eq!(generation(Ps4, "06510011"), Some(Target::Ps4V8));
    assert_eq!(generation(Ps4, "0"), None);
    assert_eq!(generation(Ps4, "abc"), None);
    assert_eq!(generation(Ps4, "0752x9"), Some(Target::Ps4V8));
    assert_eq!(generation(Ps5, "07000000"), Some(Target::Ps4V9));
}

#[test]
fn unknown_generation_falls_back_to_protocol_version() {
    let mut h = parse_search_response(SAMPLE, LOCAL).unwrap();
    h.system_version = None;
    assert_eq!(h.generation(), None);
    assert_eq!(h.target(), Target::Ps5V1);
    h.protocol_version = Some("00020020".into());
    assert_eq!(h.target(), Target::Ps4V10);
}

#[test]
fn wake_sends_one_datagram() {
    let console = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    console
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    wake(
        console.local_addr().unwrap(),
        ConsoleKind::Ps4,
        &key_text("1a2b3c4d"),
    )
    .unwrap();
    let mut buf = [0u8; 512];
    let n = console.recv(&mut buf).unwrap();
    assert_eq!(
        &buf[..n],
        &wakeup_message(ConsoleKind::Ps4, 439_041_101)[..]
    );
    assert!(wake(
        console.local_addr().unwrap(),
        ConsoleKind::Ps4,
        &key_text("nothex!")
    )
    .is_err());
}

fn fake_console(
    reply: &'static [u8],
) -> (
    SocketAddr,
    mpsc::Receiver<Vec<u8>>,
    std::thread::JoinHandle<()>,
) {
    let sock = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    sock.set_read_timeout(Some(Duration::from_millis(100)))
        .unwrap();
    let addr = sock.local_addr().unwrap();
    let (tx, rx) = mpsc::channel();
    let t = std::thread::spawn(move || {
        let mut buf = [0u8; 1500];
        let mut idle = 0;
        while idle < 30 {
            match sock.recv_from(&mut buf) {
                Ok((n, from)) => {
                    idle = 0;
                    let msg = buf[..n].to_vec();
                    if msg.starts_with(b"SRCH") {
                        sock.send_to(reply, from).unwrap();
                    }
                    if tx.send(msg).is_err() {
                        return;
                    }
                }
                Err(_) => idle += 1,
            }
        }
    });
    (addr, rx, t)
}

#[test]
fn service_finds_a_console_and_sends_wake() {
    let (addr, searches, _t) = fake_console(SAMPLE);
    let config = DiscoveryConfig {
        destination: LOCAL,
        ps4_port: addr.port(),
        ps5_port: addr.port(),
        initial_delay: Duration::from_millis(20),
        period: Duration::from_millis(60),
        bind_address: LOCAL,
        ..DiscoveryConfig::default()
    };
    let (tx, rx) = mpsc::channel::<Vec<DiscoveredHost>>();
    let service = DiscoveryService::start(
        config,
        Box::new(move |hosts| {
            let _ = tx.send(hosts.to_vec());
        }),
    )
    .unwrap();
    let local = service.local_addr().unwrap();
    assert_ne!(local.port(), 0);

    let found = rx.recv_timeout(Duration::from_secs(3)).unwrap();
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].host_id, "0123456789AB");
    assert_eq!(found[0].address, LOCAL);

    let mut seen_ps4 = false;
    let mut seen_ps5 = false;
    while !(seen_ps4 && seen_ps5) {
        let m = searches.recv_timeout(Duration::from_secs(2)).unwrap();
        seen_ps4 |= m == search_message(ConsoleKind::Ps4);
        seen_ps5 |= m == search_message(ConsoleKind::Ps5);
    }

    service
        .wake(LOCAL, ConsoleKind::Ps5, &key_text("1a2b3c4d"))
        .unwrap();
    loop {
        let m = searches.recv_timeout(Duration::from_secs(2)).unwrap();
        if m.starts_with(b"WAKEUP") {
            assert_eq!(m, wakeup_message(ConsoleKind::Ps5, 439_041_101));
            break;
        }
    }
    service.stop();
}

#[test]
fn service_drops_silent_consoles_after_k_rounds() {
    let sock = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    let addr = sock.local_addr().unwrap();
    let t = std::thread::spawn(move || {
        let mut buf = [0u8; 1500];
        let (_, from) = sock.recv_from(&mut buf).unwrap();
        sock.send_to(SAMPLE, from).unwrap();
    });
    let config = DiscoveryConfig {
        destination: LOCAL,
        ps4_port: addr.port(),
        ps5_port: 9,
        initial_delay: Duration::from_millis(10),
        period: Duration::from_millis(40),
        bind_address: LOCAL,
        ..DiscoveryConfig::default()
    };
    let (tx, rx) = mpsc::channel::<usize>();
    let service = DiscoveryService::start(
        config,
        Box::new(move |hosts| {
            let _ = tx.send(hosts.len());
        }),
    )
    .unwrap();
    assert_eq!(rx.recv_timeout(Duration::from_secs(3)).unwrap(), 1);
    assert_eq!(rx.recv_timeout(Duration::from_secs(3)).unwrap(), 0);
    t.join().unwrap();
    drop(service);
}

#[test]
fn destinations_include_extra_broadcasts_without_duplicates() {
    let c = DiscoveryConfig {
        extra_destinations: vec![
            "192.168.1.255".parse().unwrap(),
            "255.255.255.255".parse().unwrap(),
            "10.0.0.255".parse().unwrap(),
        ],
        ..DiscoveryConfig::default()
    };
    let d: Vec<String> = c.destinations().iter().map(ToString::to_string).collect();
    assert_eq!(d, ["255.255.255.255", "192.168.1.255", "10.0.0.255"]);
}
