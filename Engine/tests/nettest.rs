mod common;
use common::senkusha::{fake, Behaviour};

use std::net::{Ipv4Addr, UdpSocket};
use std::time::{Duration, Instant};

use con_engine::nettest::{
    self, NetworkTestConfig, NetworkTestError, NetworkTestResult, TestStage, Timings,
};
use con_engine::StopToken;

fn quick_console() -> Timings {
    Timings {
        connect: Duration::from_secs(5),
        reply: Duration::from_millis(800),
        pong: Duration::from_millis(500),
        mtu_wait_min: Duration::from_millis(50),
        ..Timings::console()
    }
}

#[test]
fn console_test_measures_rtt_and_both_mtus() {
    let (addr, fake) = fake(
        Behaviour {
            answer_protocol: true,
            answer_mtu: true,
            mtu_in_limit: 1400,
            mtu_out_limit: 1300,
            bogus_first_pong: true,
            ..Default::default()
        },
        0,
    );
    let mut c = NetworkTestConfig::console(addr);
    c.timings = quick_console();
    let r = nettest::run(c, &StopToken::new()).unwrap();
    assert_eq!(r.mtu_in, 1400);
    assert_eq!(r.mtu_out, 1300);
    assert_eq!(r.rtt_samples, 10);
    assert!(r.rtt_us > 0 && r.rtt_us < 200_000, "{r:?}");
    let seen = fake.join().unwrap();
    assert_eq!(seen.protocol_requests, 1);
    assert_eq!(seen.hello_session_key.as_deref(), Some(""));
    assert_eq!(seen.echo_states, vec![true, false]);
    for (i, (id, _)) in seen.mtu_requests.iter().enumerate() {
        assert_eq!(*id, i as u32 + 1);
    }
    assert_eq!(&seen.mtu_requests[..3], &[(1, 1454), (2, 1454), (3, 1454)]);
    assert_eq!(seen.mtu_requests[3].1, 576 + (1454 - 576) / 2);
    assert_eq!(seen.client_mtu[0].requested_mtu, 1400);
    assert_eq!(seen.client_mtu[0].downstream_mtu, Some(1400));
    let last = seen.client_mtu.last().unwrap();
    assert_eq!((last.id, last.state, last.requested_mtu), (2, false, 1301));
    assert_eq!(seen.disconnect.as_deref(), Some("Client Disconnecting"));
}

#[test]
fn console_test_failure_gives_the_fallback() {
    let (addr, _fake) = fake(Behaviour::default(), 0);
    let mut c = NetworkTestConfig::console(addr);
    c.timings = quick_console();
    let r = nettest::run(c, &StopToken::new());
    assert_eq!(r, Err(NetworkTestError::NoReply("protocol request")));
    let f = NetworkTestResult::console_fallback();
    assert_eq!((f.mtu_in, f.mtu_out, f.rtt_us), (1454, 1454, 1000));
}

#[test]
fn console_test_without_pongs_fails() {
    let (addr, _fake) = fake(
        Behaviour {
            answer_protocol: true,
            mtu_out_limit: 0,
            ..Default::default()
        },
        0,
    );
    let mut c = NetworkTestConfig::console(addr);
    c.timings = Timings {
        pong: Duration::from_millis(100),
        ..quick_console()
    };
    assert_eq!(
        nettest::run(c, &StopToken::new()),
        Err(NetworkTestError::NoRtt)
    );
}

#[test]
fn stop_aborts_the_test() {
    let silent = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    let stop = StopToken::new();
    let s2 = stop.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(200));
        s2.stop();
    });
    let start = Instant::now();
    let r = nettest::run(
        NetworkTestConfig::console(silent.local_addr().unwrap()),
        &stop,
    );
    assert_eq!(r, Err(NetworkTestError::Stopped));
    assert!(start.elapsed() < Duration::from_secs(2));
}

#[test]
fn cloud_probe_variant() {
    let credential = "C".repeat(1500);
    let (addr, fake) = fake(
        Behaviour {
            cloud: true,
            answer_mtu: false,
            mtu_out_limit: 1454,
            shift_pong: true,
            ..Default::default()
        },
        1,
    );
    let mut c = NetworkTestConfig::cloud_probe(addr, credential.clone(), 1);
    c.timings.reply = Duration::from_millis(800);
    let r = nettest::run(c, &StopToken::new()).unwrap();
    assert_eq!(r.rtt_samples, 5);
    assert_eq!((r.mtu_in, r.mtu_out), (0, 0));
    assert_eq!(r.cloud_stream_mtus(), (1454, 1254));
    let seen = fake.join().unwrap();
    assert_eq!(seen.protocol_requests, 0);
    assert_eq!(seen.hello_session_key.as_deref(), Some(credential.as_str()));
    assert_eq!(seen.hello_fragments, 3);
    let sizes: Vec<u32> = seen.mtu_requests.iter().map(|m| m.1).collect();
    assert_eq!(sizes, vec![1454, 1454, 576, 576]);
    assert!(seen.client_mtu.is_empty());
}

#[test]
fn report_gives_the_stage_reached() {
    let (addr, _fake) = fake(
        Behaviour {
            answer_protocol: true,
            mtu_out_limit: 0,
            ..Default::default()
        },
        0,
    );
    let mut c = NetworkTestConfig::console(addr);
    c.timings = Timings {
        pong: Duration::from_millis(100),
        ..quick_console()
    };
    let r = nettest::run_report(c, &StopToken::new());
    assert_eq!(r.result, Err(NetworkTestError::NoRtt));
    assert_eq!(r.stage, TestStage::Rtt);
    assert_eq!(r.hello_echoed, None);

    let (addr, _fake) = fake(Behaviour::default(), 0);
    let mut c = NetworkTestConfig::console(addr);
    c.timings = quick_console();
    let r = nettest::run_report(c, &StopToken::new());
    assert_eq!(r.stage, TestStage::ProtocolRequest);

    let silent = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    let mut c = NetworkTestConfig::cloud_probe(silent.local_addr().unwrap(), "K".into(), 0);
    c.timings.connect = Duration::from_millis(300);
    let r = nettest::run_report(c, &StopToken::new());
    assert!(matches!(r.result, Err(NetworkTestError::Transport(_))));
    assert_eq!(r.stage, TestStage::Connect);

    for measure_mtu in [true, false] {
        let (addr, fake) = fake(
            Behaviour {
                cloud: true,
                answer_mtu: true,
                mtu_in_limit: 1400,
                mtu_out_limit: 1300,
                ..Default::default()
            },
            1,
        );
        let mut c = NetworkTestConfig::cloud_probe(addr, "CRED".into(), 1);
        c.measure_mtu = measure_mtu;
        let r = nettest::run_report(c, &StopToken::new());
        assert_eq!(r.stage, TestStage::Done);
        assert_eq!(r.hello_echoed, Some(true));
        let v = r.result.unwrap();
        assert_eq!(v.rtt_samples, 5);
        let seen = fake.join().unwrap();
        if measure_mtu {
            assert_eq!((v.mtu_in, v.mtu_out), (1400, 1300));
        } else {
            assert_eq!((v.mtu_in, v.mtu_out), (0, 0));
            assert!(seen.mtu_requests.is_empty() && seen.client_mtu.is_empty());
        }
        assert_eq!(seen.disconnect.as_deref(), Some("Client Disconnecting"));
    }
}
