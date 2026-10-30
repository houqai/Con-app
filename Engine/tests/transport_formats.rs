mod common;
use common::hex;

use con_engine::crypto::stream::DirectionKeys;
use con_engine::proto::{
    client_disconnect, client_stream_info, controller_connection, AudioChannel, Bang, Big,
    ClientInfo, ConnectionQuality, CorruptFrame, Cursor, DebugCommand, DebugOverlay, DeepLink,
    DirectMessage, Disconnect, Envelope, EventCode, FpsChange, GkTrace, Info, Log, LogEntry,
    Message, MicConnection, MicInfo, PacketLoss, PeriodicTimestamp, PlayTimeLeft, ProtoError,
    ProtoMessage, Resolution, Senkusha, SenkushaBandwidth, SenkushaClientMtu, SenkushaEcho,
    SenkushaMtu, ServerMessage, ServerSettings, StreamInfo, TakionProtocolRequest,
    TakionProtocolRequestAck, Timer, VideoCapture, XmbCommand,
};
use con_engine::transport::crypt::{Opener, Sealer};
use con_engine::transport::packet::{
    encode_congestion, encode_feedback, encode_microphone, encode_probe, parse_control,
    parse_media, tag_layout, MediaKind, UnitWord,
};

fn shared_secret() -> [u8; 32] {
    std::array::from_fn(|i| i as u8)
}

fn handshake_key() -> [u8; 16] {
    std::array::from_fn(|i| 0xa0 + i as u8)
}

#[test]
fn tag_example_through_the_packet_api() {
    let packet = hex("00 11223344 00000000 00000040 00 01 000f 55667788 0001 0000 00 0803");
    assert_eq!(packet.len(), 28);
    let cp = parse_control(&packet).unwrap();
    assert_eq!(cp.payload.len(), 11);
    for (index, kp, expected) in [
        (2u8, 0x40u64, "7926cef1"),
        (3, 0x40, "16f7d264"),
        (2, 45001, "3d05f159"),
        (3, 45001, "a2e7ce3e"),
    ] {
        let keys = DirectionKeys::derive(&shared_secret(), &handshake_key(), index);
        let mut sealer = Sealer::starting_at(keys.clone(), kp);
        assert_eq!(sealer.allocate(2), kp);
        let mut p = packet.clone();
        p[5..9].copy_from_slice(&[0xde, 0xad, 0xbe, 0xef]);
        sealer.seal(&mut p, kp);
        assert_eq!(p[5..9], hex(expected)[..], "index {index} kp {kp}");
        assert_eq!(p[9..13], (kp as u32).to_be_bytes());
        let mut opener = Opener::new(keys);
        assert_eq!(opener.verify(&p), Some(kp));
        let mut bad = p.clone();
        bad[27] ^= 1;
        assert_eq!(
            Opener::new(DirectionKeys::derive(
                &shared_secret(),
                &handshake_key(),
                index
            ))
            .verify(&bad),
            None
        );
    }
}

#[test]
fn tag_layouts() {
    let l = tag_layout(0).unwrap();
    assert_eq!((l.gmac, l.key_pos, l.zero_key_pos), (5, 9, true));
    let l = tag_layout(2).unwrap();
    assert_eq!((l.gmac, l.key_pos, l.zero_key_pos), (10, 14, false));
    assert_eq!(tag_layout(3), tag_layout(2));
    let l = tag_layout(5).unwrap();
    assert_eq!((l.gmac, l.key_pos, l.zero_key_pos), (7, 11, true));
    let l = tag_layout(6).unwrap();
    assert_eq!((l.gmac, l.key_pos, l.zero_key_pos), (8, 4, false));
    assert_eq!(tag_layout(1), tag_layout(6));
    assert!(tag_layout(4).is_none() && tag_layout(8).is_none());
}

#[test]
fn protobuf_encodings_of_section_11() {
    let cases: Vec<(Message, &str)> = vec![
        (
            client_stream_info(),
            "08 0D 7A 10 12 0E 01 10 00 00 BB 80 00 00 01 E0 00 00 00 00",
        ),
        (Message::StreamInfoAck, "08 0E"),
        (Message::Heartbeat, "08 03"),
        (Message::IdrRequest, "08 19"),
        (controller_connection(true), "08 15 B2 01 04 10 01 18 06"),
        (controller_connection(false), "08 15 B2 01 04 10 01 18 02"),
        (
            Message::CorruptFrame(CorruptFrame { start: 5, end: 9 }),
            "08 05 32 04 08 05 10 09",
        ),
        (
            Message::TakionProtocolRequest(TakionProtocolRequest {
                supported_versions: vec![9],
            }),
            "08 1F FA 01 02 08 09",
        ),
        (
            Message::Senkusha(Senkusha {
                command: 0,
                echo: Some(SenkushaEcho { state: true }),
                ..Default::default()
            }),
            "08 0C 72 06 08 00 12 02 08 01",
        ),
    ];
    for (m, expected) in cases {
        let bytes = m.encode();
        assert_eq!(bytes, hex(expected), "{m:?}");
        assert_eq!(Message::decode(&bytes).unwrap(), m);
    }
    let d = client_disconnect().encode();
    assert_eq!(d.len(), 26);
    assert_eq!(&d[..6], &hex("08 08 52 16 0A 14")[..]);
    assert_eq!(&d[6..], b"Client Disconnecting");
}

#[test]
fn hello_outline() {
    let big = Message::Big(Big {
        version: 12,
        session_key: "SID".into(),
        launch_spec: "TGF1bmNo".into(),
        encrypted_key: vec![0; 4],
        ecdh_public_key: Some(vec![4; 65]),
        ecdh_signature: Some(vec![7; 32]),
    })
    .encode();
    let mut want = hex("08 00 12 7C");
    want.extend_from_slice(&hex("08 0C 12 03"));
    want.extend_from_slice(b"SID");
    want.extend_from_slice(&hex("1A 08"));
    want.extend_from_slice(b"TGF1bmNo");
    want.extend_from_slice(&hex("22 04 00 00 00 00 2A 41"));
    want.extend_from_slice(&[4; 65]);
    want.extend_from_slice(&hex("32 20"));
    want.extend_from_slice(&[7; 32]);
    assert_eq!(big, want);
    let nt = Message::Big(Big {
        version: 9,
        ..Default::default()
    })
    .encode();
    assert_eq!(nt, hex("08 00 12 08 08 09 12 00 1A 00 22 00"));
}

fn samples() -> Vec<Message> {
    let ev = Some(EventCode {
        code: "E1".into(),
        name: Some("n".into()),
        description: None,
    });
    vec![
        Message::Big(Big {
            version: 9,
            session_key: "k".into(),
            launch_spec: "s".into(),
            encrypted_key: vec![0; 4],
            ecdh_public_key: Some(vec![4; 65]),
            ecdh_signature: Some(vec![1; 32]),
        }),
        Message::Bang(Bang {
            server_version: 12,
            token: u64::MAX,
            encrypted_key_accepted: true,
            version_accepted: true,
            session_key: "k".into(),
            extended_info: ev.clone(),
            server_version_string: Some("v".into()),
            ecdh_public_key: Some(vec![4; 65]),
            ecdh_signature: Some(vec![2; 32]),
        }),
        Message::Info(Info {
            mtu: 1454,
            fps: 60,
            ..Default::default()
        }),
        Message::Heartbeat,
        Message::PacketLoss(PacketLoss {
            start: 1,
            end: 2,
            packets_received: 3,
        }),
        Message::CorruptFrame(CorruptFrame {
            start: 0,
            end: 65535,
        }),
        Message::Cursor(Cursor {
            id: 1,
            width: 2,
            height: 3,
            hotspot_x: 4,
            hotspot_y: 5,
            pixels: Some(vec![9; 16]),
        }),
        Message::Timer(Timer {
            seconds_left: 10,
            total_seconds: 60,
        }),
        Message::Disconnect(Disconnect {
            reason: "Server shutting down".into(),
            extended_info: ev,
        }),
        Message::Log(Log {
            entries: vec![
                LogEntry {
                    timestamp: -5,
                    level: 3,
                    component: "c".into(),
                    message: "m".into(),
                    timestamp_double: Some(1.25),
                },
                LogEntry::default(),
            ],
        }),
        Message::HeaderRequest(Default::default()),
        Message::Debug(DebugCommand {
            debug_type: 0,
            overlay: Some(DebugOverlay {
                enable: Some(true),
                location: Some(3),
                ..Default::default()
            }),
            bitrate: None,
        }),
        Message::Senkusha(Senkusha {
            command: 1,
            echo: None,
            mtu: Some(SenkushaMtu {
                id: 7,
                requested_mtu: 1454,
                count: Some(1),
                ..Default::default()
            }),
            bandwidth: Some(SenkushaBandwidth {
                loss: Some(0.5),
                upstream: Some(false),
                ..Default::default()
            }),
            client_mtu: Some(SenkushaClientMtu {
                id: 2,
                requested_mtu: 1400,
                state: false,
                downstream_mtu: Some(1454),
            }),
        }),
        Message::StreamInfo(StreamInfo {
            resolutions: vec![
                Resolution {
                    width: 1920,
                    height: 1080,
                    video_header: vec![0, 0, 0, 1, 0x67],
                },
                Resolution {
                    width: 1280,
                    height: 720,
                    video_header: vec![],
                },
            ],
            audio_header: vec![2, 16, 0, 0, 0xbb, 0x80, 0, 0, 1, 0xe0, 0, 0, 0, 0],
            start_timeout: Some(1),
            afk_timeout: Some(2),
            afk_disconnect_timeout: Some(3),
            congestion_control_interval: Some(4),
            audio_channels: vec![AudioChannel {
                channel_type: 1,
                audio_header: vec![1, 2],
                raw_pcm: Some(true),
            }],
        }),
        Message::StreamInfoAck,
        Message::XmbCommand(XmbCommand {
            command: 2,
            player_id: Some(1),
        }),
        Message::ConnectionQuality(ConnectionQuality {
            target_bitrate: Some(10000),
            upstream_bitrate: Some(500),
            upstream_loss: Some(0.25),
            disable_upstream_audio: Some(false),
            rtt: Some(12.5),
            loss: Some(u64::MAX),
        }),
        Message::ClientMetric(Default::default()),
        Message::PlayTimeLeft(PlayTimeLeft {
            time_left: Some(5),
            reason: Some("r".into()),
        }),
        Message::ServerMessage(ServerMessage {
            payload: Some("p".into()),
        }),
        Message::FpsChange(FpsChange { fps: 30 }),
        controller_connection(true),
        Message::ClientInfo(ClientInfo {
            session_key: "k".into(),
            gcm_tag: Some(1),
            key_position: Some(2),
        }),
        Message::VideoCapture(VideoCapture {
            server_side: Some(true),
            idr_period: Some(0),
        }),
        Message::AudioCapture(Default::default()),
        Message::IdrRequest,
        Message::GkTrace(GkTrace {
            sequence_number: 1,
            gcm_tag: 2,
            key_position: 3,
        }),
        Message::PeriodicTimestamp(PeriodicTimestamp {
            timestamp_info: vec![1, 2, 3],
            version: 1,
        }),
        Message::ServerSettings(ServerSettings {
            idr_period: Some(60),
            send_periodic_timestamp: Some(true),
        }),
        Message::DirectMessage(DirectMessage {
            message_type: 0,
            destination: 1001,
            data: Some(
                DeepLink {
                    link_type: 5,
                    raw_data: Some("x".into()),
                    ..Default::default()
                }
                .encode(),
            ),
        }),
        Message::MicConnection(MicConnection {
            controller_id: -1,
            connected: true,
            result: None,
        }),
        Message::TakionProtocolRequest(TakionProtocolRequest {
            supported_versions: vec![7, 9, 12],
        }),
        Message::TakionProtocolRequestAck(TakionProtocolRequestAck { version: Some(9) }),
    ]
}

#[test]
fn every_message_round_trips() {
    let all = samples();
    let mut types: Vec<u32> = all.iter().map(|m| m.msg_type()).collect();
    types.sort_unstable();
    types.dedup();
    assert_eq!(types, (0..=32).collect::<Vec<_>>(), "one sample per type");
    for m in all {
        let bytes = m.encode();
        let back = Message::decode(&bytes).unwrap_or_else(|e| panic!("{m:?}: {e}"));
        assert_eq!(back, m);
        let env = Envelope::decode(&bytes).unwrap();
        assert_eq!(env.msg_type, m.msg_type());
    }
    let mic = MicInfo {
        info_type: 1,
        controller_id: Some(-3),
        muted: Some(true),
        ..Default::default()
    };
    assert_eq!(MicInfo::decode(&mic.encode()).unwrap(), mic);
    assert_eq!(
        Message::decode(&hex("08 63")).unwrap(),
        Message::Unknown { msg_type: 99 }
    );
}

#[test]
fn decoder_rules() {
    let partial = hex("08 0C 10 01 18 01 20 01");
    assert_eq!(
        Bang::decode(&partial),
        Err(ProtoError::MissingRequired {
            message: "Bang",
            field: 5
        })
    );
    assert!(Message::decode(&hex("08 01")).is_err());
    assert!(Envelope::decode(&hex("7A 00")).is_err());
    let mut cf = CorruptFrame { start: 3, end: 4 }.encode();
    cf.extend_from_slice(&hex("78 05 82 01 02 AA BB"));
    assert_eq!(
        CorruptFrame::decode(&cf).unwrap(),
        CorruptFrame { start: 3, end: 4 }
    );
    assert_eq!(
        TakionProtocolRequest::decode(&hex("0A 02 09 0C"))
            .unwrap()
            .supported_versions,
        vec![9, 12]
    );
    assert!(CorruptFrame::decode(&hex("0A 01 00 10 01")).is_err());
    let cq = ConnectionQuality::decode(&hex("0A 01 00 10 07")).unwrap();
    assert_eq!(cq.target_bitrate, None);
    assert_eq!(cq.upstream_bitrate, Some(7));
    assert!(Message::decode(&hex("08 05 32 04 08 05")).is_err());
    let env = Envelope::decode(&hex("08 0D 12 00 7A 04 12 02 01 02")).unwrap();
    assert_eq!(env.payload, Some(hex("12 02 01 02")));
    assert_eq!(env.present, vec![2, 15]);
}

#[test]
fn worked_media_example() {
    let mut d = hex("02 0000 0001 00000401 03 094223ba 00000080 0398 00");
    d.extend_from_slice(&[0x55; 105]);
    let m = parse_media(&d, 9).unwrap();
    assert_eq!(m.kind, MediaKind::Video);
    assert_eq!((m.packet_index, m.frame_index), (0, 1));
    assert_eq!(
        m.unit_word,
        UnitWord::Video {
            unit_index: 0,
            units_total: 2,
            fec_units: 1
        }
    );
    assert_eq!(m.codec, 3);
    assert_eq!(m.gmac, [0x09, 0x42, 0x23, 0xba]);
    assert_eq!(m.key_pos, 0x80);
    assert_eq!(m.payload_offset, 21);
    assert_eq!(m.adaptive_stream, Some(0));
    assert_eq!(d.len() - m.payload_offset, 105);

    let mut d = hex("02 0001 0001 00200401 03 5a8b07c4 00000100 0000 00");
    d.extend_from_slice(&[0; 108]);
    let m = parse_media(&d, 9).unwrap();
    assert_eq!(m.unit_word.unit_index(), 1);
    assert_eq!(m.key_pos, 0x100);

    let mut d = hex("12 0002 0002 00004401 03 00000000 00000200 0000 00 000032");
    d.extend_from_slice(&[0; 4]);
    let m = parse_media(&d, 12).unwrap();
    assert!(m.extended);
    assert_eq!(m.frame_index, 2);
    assert_eq!(
        m.unit_word,
        UnitWord::Video {
            unit_index: 0,
            units_total: 18,
            fec_units: 1
        }
    );
    assert_eq!(m.payload_offset, 24);
    let mut d = hex("02 0000 0001 00000401 03 00000000 00000000 0000 A0");
    d.extend_from_slice(&[0; 4]);
    assert_eq!(parse_media(&d, 12).unwrap().adaptive_stream, Some(5));
    assert!(parse_media(&d[..24], 12).is_none());
}

#[test]
fn audio_headers_by_version() {
    let base = hex("03 0010 0020 02010a21 05 00000000 00000000 07");
    let mut d = base.clone();
    assert!(parse_media(&d, 9).is_none());
    d.push(0xaa);
    let m = parse_media(&d, 9).unwrap();
    assert_eq!(m.kind, MediaKind::Audio);
    assert_eq!(m.payload_offset, 19);
    assert_eq!(
        m.unit_word,
        UnitWord::Audio {
            unit_index: 2,
            units_total: 2,
            unit_size: 0x0a,
            fec_units: 2,
            source_units: 1
        }
    );
    let mut d = base.clone();
    d.extend_from_slice(&[0x02, 0xaa]);
    let m = parse_media(&d, 12).unwrap();
    assert_eq!(m.kind, MediaKind::Haptics);
    assert_eq!(m.payload_offset, 20);
    d[19] = 0x00;
    assert_eq!(parse_media(&d, 12).unwrap().kind, MediaKind::Audio);
    let mut d = base.clone();
    d[0] = 0x13;
    d.extend_from_slice(&[1, 2, 3, 0x02, 0xaa]);
    let m = parse_media(&d, 12).unwrap();
    assert_eq!(m.kind, MediaKind::Haptics);
    assert_eq!(m.payload_offset, 23);
    let p = encode_probe(548, 0, 3, 0x0102_0304, &[]);
    let m = parse_media(&p, 7).unwrap();
    assert_eq!(m.payload_offset, 18);
    assert_eq!(m.unit_word.unit_index(), 3);
    assert_eq!(&p[22..26], &[1, 2, 3, 4]);
    assert_eq!(p.len(), 548);
    assert_eq!(&p[5..10], &hex("00 7F FC 00 FF")[..]);
}

#[test]
fn client_packet_layouts() {
    let mic = encode_microphone(5, true, &[0xee; 120]);
    assert_eq!(
        &mic[..20],
        &hex("03 0005 0006 00022821 05 00000000 00000000 00 00")[..]
    );
    assert_eq!(mic.len(), 140);
    let mic4 = encode_microphone(0xffff, false, &[0xee; 120]);
    assert_eq!(
        &mic4[..19],
        &hex("03 ffff 0000 00022821 05 00000000 00000000 00")[..]
    );
    assert_eq!(
        encode_congestion(1000, 40),
        hex("05 0000 03E8 0028 00000000 00000000")[..]
    );
    let fb = encode_feedback(6, 7, &[1, 2, 3]);
    assert_eq!(fb, hex("06 0007 00 00000000 00000000 010203"));
}

#[test]
fn feedback_and_microphone_are_encrypted_at_key_position_plus_16() {
    let keys = DirectionKeys::derive(&shared_secret(), &handshake_key(), 2);
    let mut sealer = Sealer::new(keys.clone());
    let payload = [0x11u8; 28];
    let mut p = encode_feedback(6, 0, &payload);
    sealer.allocate(29);
    let kp = sealer.allocate(payload.len() as u64 + 16);
    assert_eq!(kp, 42);
    sealer.encrypt_payload(&mut p, 12, kp);
    sealer.seal(&mut p, kp);
    assert_eq!(&p[4..8], &42u32.to_be_bytes());
    let mut clear = p[12..].to_vec();
    keys.apply_keystream(kp + 16, &mut clear);
    assert_eq!(clear, payload);
    let mut opener = Opener::new(keys);
    assert_eq!(opener.verify(&p), Some(42));
}
