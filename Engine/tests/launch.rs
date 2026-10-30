mod common;
use common::seq;

use base64::Engine as _;
use con_engine::crypto::rp::RpCipher;
use con_engine::launch::{LaunchSpec, StreamChoice, VideoPreset};
use con_engine::{Codec, ServerType, Target};

const PS5_SAMPLE: &str = r#"{"sessionId":"sessionId4321","streamResolutions":[{"resolution":{"width":1920,"height":1080},"maxFps":60,"score":10}],"network":{"bwKbpsSent":15000,"bwLoss":0.001000,"mtu":1454,"rtt":1,"ports":[53,2053]},"slotId":1,"appSpecification":{"minFps":30,"minBandwidth":0,"extTitleId":"ps3","version":1,"timeLimit":1,"startTimeout":100,"afkTimeout":100,"afkTimeoutDisconnect":100},"konan":{"ps3AccessToken":"accessToken","ps3RefreshToken":"refreshToken"},"requestGameSpecification":{"model":"bravia_tv","platform":"android","audioChannels":"5.1","language":"sp","acceptButton":"X","connectedControllers":["xinput","ds3","ds4"],"yuvCoefficient":"bt601","videoEncoderProfile":"hw4.1","audioEncoderProfile":"audio1","adaptiveStreamMode": "resize"},"userProfile":{"onlineId":"psnId","npId":"npId","region":"US","languagesUsed":["en","jp"]},"videoCodec":"avc","dynamicRange":"SDR","handshakeKey":"oKGio6SlpqeoqaqrrK2urw=="}"#;

fn spec(target: Target, codec: Codec) -> LaunchSpec {
    LaunchSpec::new(
        target,
        StreamChoice::new(1080, 60, codec),
        1454,
        1,
        seq(0xa0),
    )
}

#[test]
fn ps5_json_matches_the_reference_sample() {
    let json = spec(Target::Ps5V1, Codec::H264).to_json().unwrap();
    assert_eq!(json, PS5_SAMPLE);
}

#[test]
fn ps4_json_omits_ps5_members() {
    let json = spec(Target::Ps4V10, Codec::H264).to_json().unwrap();
    let expected = PS5_SAMPLE
        .replace(",\"adaptiveStreamMode\": \"resize\"", "")
        .replace("\"videoCodec\":\"avc\",", "")
        .replace("\"dynamicRange\":\"SDR\",", "");
    assert_eq!(json, expected);
}

#[test]
fn codec_members_for_ps5() {
    let hevc = spec(Target::Ps5V1, Codec::H265).to_json().unwrap();
    assert!(hevc.contains("\"videoCodec\":\"hevc\",\"dynamicRange\":\"SDR\","));
    let hdr = spec(Target::Ps5V1, Codec::H265Hdr).to_json().unwrap();
    assert!(hdr.contains("\"videoCodec\":\"hevc\",\"dynamicRange\":\"HDR\","));
}

#[test]
fn presets_and_adjustments() {
    assert_eq!(VideoPreset::for_height(2160), VideoPreset::P1080);
    assert_eq!(VideoPreset::for_height(720), VideoPreset::P720);
    assert_eq!(VideoPreset::for_height(600), VideoPreset::P540);
    assert_eq!(VideoPreset::for_height(100), VideoPreset::P360);
    let c = StreamChoice::new(1080, 120, Codec::H265);
    assert_eq!(c.max_fps, 60);
    assert_eq!(StreamChoice::new(1080, 50, Codec::H264).max_fps, 30);

    let base = c.adjusted_for(ServerType::Ps4);
    assert_eq!(base.preset, VideoPreset::P720);
    assert_eq!(base.max_fps, 60);
    assert_eq!(base.codec, Codec::H264);

    let pro = c.adjusted_for(ServerType::Ps4Pro);
    assert_eq!(pro.preset, VideoPreset::P1080);
    assert_eq!(pro.codec, Codec::H264);

    let ps5 = c.adjusted_for(ServerType::Ps5);
    assert_eq!(ps5, c);

    let no_downgrade = StreamChoice {
        auto_downgrade: false,
        ..c
    };
    assert_eq!(
        no_downgrade.adjusted_for(ServerType::Ps4).preset,
        VideoPreset::P1080
    );

    let off = StreamChoice::video_disabled(Codec::H264);
    assert_eq!((off.preset, off.max_fps), (VideoPreset::P360, 0));
}

#[test]
fn encoded_spec_decrypts_back() {
    let cipher = RpCipher::new(seq(0x10), seq(0x20), Target::Ps5V1.iv_hmac_key());
    let s = spec(Target::Ps5V1, Codec::H264);
    let encoded = s.encode(&cipher).unwrap();
    let mut bytes = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .unwrap();
    let ks = cipher.keystream(0, bytes.len());
    bytes.iter_mut().zip(ks).for_each(|(b, k)| *b ^= k);
    assert_eq!(bytes.pop(), Some(0));
    assert_eq!(String::from_utf8(bytes).unwrap(), PS5_SAMPLE);
}
