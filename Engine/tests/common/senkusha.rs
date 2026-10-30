use std::time::{Duration, Instant};

use super::takion::FakeServer;
use con_engine::proto::{
    senkusha_command, Bang, Message, Senkusha, SenkushaClientMtu, TakionProtocolRequestAck,
};
use con_engine::transport::packet::packet_type;

const IP_UDP_OVERHEAD: u32 = 28;

#[derive(Default, Clone)]
pub struct Behaviour {
    pub cloud: bool,
    pub answer_protocol: bool,
    pub answer_mtu: bool,
    pub mtu_in_limit: u32,
    pub mtu_out_limit: u32,
    pub shift_pong: bool,
    pub bogus_first_pong: bool,
}

#[derive(Default, Debug)]
pub struct Seen {
    pub protocol_requests: usize,
    pub hello_session_key: Option<String>,
    pub hello_fragments: usize,
    pub mtu_requests: Vec<(u32, u32)>,
    pub client_mtu: Vec<SenkushaClientMtu>,
    pub echo_states: Vec<bool>,
    pub disconnect: Option<String>,
}

pub fn fake(b: Behaviour, prefix: u8) -> (std::net::SocketAddr, std::thread::JoinHandle<Seen>) {
    let mut s = FakeServer::bind();
    s.prefix = prefix;
    let addr = s.addr();
    let t = std::thread::spawn(move || {
        let mut seen = Seen::default();
        s.handshake(None);
        let mut echo = false;
        let mut first_pong = true;
        let deadline = Instant::now() + Duration::from_secs(30);
        while seen.disconnect.is_none() && Instant::now() < deadline {
            s.poll(Duration::from_millis(20));
            while let Some(m) = s.messages.pop_front() {
                let msg = Message::decode(&m.data).unwrap();
                match msg {
                    Message::TakionProtocolRequest(r) => {
                        assert_eq!(r.supported_versions, vec![9]);
                        assert_eq!(m.channel, 1);
                        seen.protocol_requests += 1;
                        if b.answer_protocol {
                            s.send_proto(
                                1,
                                &Message::TakionProtocolRequestAck(TakionProtocolRequestAck {
                                    version: Some(9),
                                }),
                            );
                        }
                    }
                    Message::Big(big) => {
                        assert_eq!(big.version, 9);
                        assert!(big.launch_spec.is_empty() && big.encrypted_key.is_empty());
                        assert!(big.ecdh_public_key.is_none());
                        seen.hello_session_key = Some(big.session_key.clone());
                        seen.hello_fragments = s.data_seen.len() - seen.protocol_requests;
                        if b.cloud {
                            s.send_message(1, 0, &m.data);
                        } else {
                            s.send_proto(
                                1,
                                &Message::Bang(Bang {
                                    server_version: 9,
                                    version_accepted: true,
                                    encrypted_key_accepted: true,
                                    ..Default::default()
                                }),
                            );
                        }
                    }
                    Message::Senkusha(c) => {
                        assert_eq!(m.channel, 8);
                        match c.command {
                            senkusha_command::ECHO => {
                                let on = c.echo.unwrap().state;
                                echo = on;
                                seen.echo_states.push(on);
                            }
                            senkusha_command::MTU => {
                                let mtu = c.mtu.unwrap();
                                assert_eq!(mtu.count, Some(1));
                                seen.mtu_requests.push((mtu.id, mtu.requested_mtu));
                                if b.answer_mtu && mtu.requested_mtu <= b.mtu_in_limit {
                                    let len = (mtu.requested_mtu - IP_UDP_OVERHEAD) as usize;
                                    let mut v = vec![0u8; len];
                                    v[0] = packet_type::VIDEO;
                                    v[3..5].copy_from_slice(&(mtu.id as u16).to_be_bytes());
                                    s.send_raw(&v);
                                }
                            }
                            senkusha_command::CLIENT_MTU => {
                                let cm = c.client_mtu.unwrap();
                                echo = cm.state;
                                if cm.id == 1 {
                                    assert!(cm.state);
                                    s.send_proto(
                                        8,
                                        &Message::Senkusha(Senkusha {
                                            command: senkusha_command::CLIENT_MTU,
                                            client_mtu: Some(SenkushaClientMtu {
                                                id: 1,
                                                requested_mtu: cm.requested_mtu,
                                                state: true,
                                                downstream_mtu: cm.downstream_mtu,
                                            }),
                                            ..Default::default()
                                        }),
                                    );
                                }
                                seen.client_mtu.push(cm);
                            }
                            other => panic!("unexpected command {other}"),
                        }
                    }
                    Message::Disconnect(d) => seen.disconnect = Some(d.reason),
                    other => panic!("unexpected {other:?}"),
                }
            }
            for d in std::mem::take(&mut s.raw_seen) {
                if d[0] != packet_type::AUDIO
                    || !echo
                    || d.len() as u32 + IP_UDP_OVERHEAD > b.mtu_out_limit
                {
                    continue;
                }
                if b.bogus_first_pong && first_pong {
                    let mut wrong = d.clone();
                    wrong[22] ^= 0xff;
                    s.send_raw(&wrong);
                }
                first_pong = false;
                if b.shift_pong {
                    let mut shifted = d[..18].to_vec();
                    shifted.push(0);
                    shifted.extend_from_slice(&d[18..]);
                    s.send_raw(&shifted);
                } else {
                    s.send_raw(&d);
                }
            }
        }
        seen
    });
    (addr, t)
}
