#![cfg(feature = "opus")]

mod common;
use common::console::{
    answer_session_request, listener, serve_control, NONCE, REGIST, RP_KEY, SID,
};
use common::media::{audio_datagram, frame_units, tone, video_datagram};
use common::takion::FakeServer;

mod abi {
    pub use con_engine::ffi::abi::*;
    pub use con_engine::ffi::{ConCloudProbe, ConDiscovery, ConRegistration, ConSession};
}
mod capi;
use abi::*;
use capi::*;

use std::ffi::{c_char, c_void, CStr};
use std::io::{Read, Write};
use std::mem::{align_of, offset_of, size_of};
use std::net::{Ipv4Addr, TcpListener, UdpSocket};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicPtr, AtomicU32, Ordering};
use std::sync::{Arc, Mutex, RwLock, RwLockReadGuard};
use std::time::{Duration, Instant};

use base64::Engine as _;
use con_engine::crypto::regist::{pin_keys, unmask_pin_seed};
use con_engine::crypto::rp::RpCipher;
use con_engine::crypto::stream::{sign_public_key, EcdhKeyPair};
use con_engine::ffi::{quit_reason_code, stage_code};
use con_engine::media::feedback::{parse_history, HistoryEvent};
use con_engine::media::opus::OpusEncoder;
use con_engine::media::{capture, h26x};
use con_engine::proto::{Bang, Disconnect, Message, Resolution, StreamInfo};
use con_engine::registration::FILLER_LEN;
use con_engine::session::QuitReason;
use con_engine::transport::packet::{be32, packet_type};
use con_engine::{Stage, Target};

const ENGINE: &str = env!("CARGO_MANIFEST_DIR");

fn tmp() -> PathBuf {
    PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
}

fn leak<T: Default>() -> &'static T {
    Box::leak(Box::default())
}

static ENGINE_THREADS: RwLock<()> = RwLock::new(());

fn engine_threads() -> RwLockReadGuard<'static, ()> {
    ENGINE_THREADS.read().unwrap_or_else(|p| p.into_inner())
}

macro_rules! frozen {
    ($($t:ident { size $s:literal, align $a:literal $(, $f:ident: $o:literal)* })*) => {$(
        assert_eq!((size_of::<$t>(), align_of::<$t>()), ($s, $a), "{} size, align", stringify!($t));
        $(assert_eq!(offset_of!($t, $f), $o, "{}.{}", stringify!($t), stringify!($f));)*
    )*};
}

#[test]
#[cfg(target_pointer_width = "64")]
fn abi_2_layouts_are_unchanged() {
    assert_eq!(CON_ENGINE_ABI_VERSION, 2);
    frozen!(
        ConDiscoveryConfig { size 56, align 8, bind_address: 0, destination: 8,
            extra_destinations: 16, extra_destination_count: 24, initial_delay_ms: 32,
            period_ms: 36, drop_after_rounds: 40, max_consoles: 44, ps4_port: 48, ps5_port: 50,
            local_port_first: 52, local_port_last: 54 }
        ConDiscoveredHost { size 88, align 8, address: 0, host_id: 8, host_name: 16,
            host_type: 24, system_version: 32, protocol_version: 40, running_app_title_id: 48,
            running_app_name: 56, state: 64, kind: 68, generation: 72, target: 76, status: 80,
            request_port: 82 }
        ConRegistrationRequest { size 48, align 8, host: 0, pin: 8, online_id: 16, target: 24,
            probe_timeout_ms: 28, io_timeout_ms: 32, port: 36, account_id: 38 }
        ConRegistrationResult { size 120, align 8, error_text: 0, nickname: 8, ap_ssid: 16,
            ap_bssid: 24, ap_key: 32, ap_name: 40, key_type: 48, support_cmd: 56, status: 64,
            target: 68, http_status: 72, app_reason: 76, regist_key: 80, rp_key: 96, mac: 112,
            has_key_type: 118, has_support_cmd: 119 }
        ConConsoleConfig { size 72, align 8, host: 0, kind: 8, codec: 12, video_height: 16,
            max_fps: 20, bitrate_kbps: 24, session_port: 28, network_test_port: 30,
            stream_port: 32, auto_downgrade: 34, video_disabled: 35, keyboard: 36,
            network_test: 37, regist_key: 38, rp_key: 54 }
        ConCloudConfig { size 64, align 8, address: 0, session_id: 8, launch_spec: 16, codec: 24,
            max_fps: 28, mtu_in: 32, mtu_out: 36, rtt_us: 40, port: 44, prefix: 46, ps5: 47,
            handshake_key: 48 }
        ConSessionOptions { size 32, align 8, loss_ceiling: 0, video_capture_path: 8,
            dualsense: 16, log_level: 20, stats_interval_ms: 24, discard_video: 28,
            discard_audio: 29, idr_on_fec_failure: 30, decode_audio: 31 }
        ConLogEvent { size 16, align 8, text: 0, level: 8 }
        ConPinEvent { size 1, align 1, previous_wrong: 0 }
        ConKeyboardEvent { size 8, align 8, text: 0 }
        ConDisplayEvent { size 1, align 1, cannot_display: 0 }
        ConNetworkTestEvent { size 24, align 8, rtt_us: 0, rtt_samples: 8, mtu_in: 12,
            mtu_out: 16, fallback: 20 }
        ConVideoProfile { size 24, align 8, header: 0, header_size: 8, width: 16, height: 20 }
        ConStreamInfoEvent { size 72, align 8, profiles: 0, profile_count: 8, start_timeout: 16,
            afk_timeout: 24, afk_disconnect_timeout: 32, congestion_control_interval: 40,
            audio_rate: 48, audio_frame_size: 52, audio_channels: 56, audio_bits: 57,
            audio_header: 58 }
        ConConnectionQualityEvent { size 48, align 8, upstream_loss: 0, rtt: 8,
            target_bitrate: 16, upstream_bitrate: 24, loss: 32, disable_upstream_audio: 40 }
        ConCorruptFrameEvent { size 8, align 4, start: 0, end: 4 }
        ConCloudPreludeEvent { size 16, align 8, size: 0, msg_type: 8, has_stream_info: 12 }
        ConVideoEvent { size 56, align 8, data: 0, size: 8, padded_size: 16, frames_lost: 24,
            codec: 28, width: 32, height: 36, kind: 40, frame_index: 44, profile: 46,
            recovered: 47, fec_recovered: 48, keyframe: 49, accepted: 50, flags: 51 }
        ConAudioEvent { size 56, align 8, pcm: 0, pcm_count: 8, opus: 16, opus_size: 24,
            samples_per_channel: 32, sample_rate: 40, frame_index: 44, channels: 46, decoded: 47,
            concealed: 48 }
        ConHapticsEvent { size 24, align 8, pcm: 0, size: 8, sample_rate: 16, frame_index: 20,
            channels: 22 }
        ConRumbleEvent { size 2, align 1, left: 0, right: 1 }
        ConTriggerEffectsEvent { size 22, align 1, left: 0, right: 11 }
        ConLightBarEvent { size 3, align 1, r: 0, g: 1, b: 2 }
        ConPlayerIndexEvent { size 1, align 1, index: 0 }
        ConEffectIntensityEvent { size 8, align 4, kind: 0, value: 4 }
        ConFecFailureEvent { size 4, align 2, frame_index: 0, idr_requested: 2 }
        ConStats { size 416, align 8, rtt_latest_us: 0, rtt_median_us: 8, rtt_samples: 16,
            datagrams_sent: 24, datagrams_received: 32, retransmissions: 40, given_up: 48,
            tag_failures: 56, dropped: 64, held_media_dropped: 72, messages_delivered: 80,
            media_delivered: 88, congestion_reports: 96, report_received: 104, report_lost: 112,
            video_packets: 120, video_packets_dropped: 128, video_units_received: 136,
            video_units_rejected: 144, video_units_late: 152, video_profile_switches: 160,
            video_frames_complete: 168, video_frames_fec_recovered: 176,
            video_frames_fec_failed: 184, video_frames_failed: 192, video_frames_delivered: 200,
            video_frames_rejected: 208, video_frames_skipped_waiting_idr: 216,
            video_frames_reference_missing: 224, video_frames_reference_repaired: 232,
            video_frames_unchecked: 240, video_frames_lost: 248, video_corrupt_reports: 256,
            video_idr_requests: 264, video_bytes_delivered: 272, audio_datagrams: 280,
            audio_datagrams_dropped: 288, audio_frames_offered: 296, audio_frames_discarded: 304,
            audio_frames_played: 312, audio_frames_concealed: 320, audio_decode_errors: 328,
            haptics_datagrams: 336, haptics_frames: 344, haptics_dropped: 352,
            feedback_state_sent: 360, feedback_history_sent: 368, feedback_history_dropped: 376,
            feedback_refreshes: 384, measured_bitrate: 392, running_bitrate: 400,
            audio_decoded: 408 }
        ConStatsEvent { size 8, align 8, stats: 0 }
        ConQuitEvent { size 24, align 8, text: 0, reason: 8, stage: 12, is_error: 16 }
        ConEvent { size 80, align 8, type_: 0, data: 8 }
        ConTouch { size 6, align 2, id: 0, x: 2, y: 4 }
        ConControllerState { size 68, align 4, buttons: 0, left_x: 4, left_y: 6, right_x: 8,
            right_y: 10, touches: 12, gyro: 24, accel: 36, orientation: 48, l2: 64, r2: 65 }
        ConCloudProbeConfig { size 56, align 8, address: 0, credential: 8,
            connect_timeout_ms: 16, hello_echo_ms: 20, pings: 24, pong_timeout_ms: 28,
            mtu_attempts: 32, mtu_wait_min_ms: 36, mtu_wait_max_ms: 40, client_mtu_reply_ms: 44,
            port: 48, prefix: 50, measure_mtu: 51 }
        ConCloudProbeResult { size 160, align 8, rtt_us: 0, rtt_samples: 8, mtu_in: 12,
            mtu_out: 16, status: 20, stage: 24, hello_echoed: 28, error_text: 29 }
    );
    assert_eq!(
        (size_of::<ConEventData>(), align_of::<ConEventData>()),
        (72, 8)
    );
}

macro_rules! constant_table {
    ($($c:ident),* $(,)?) => {
        vec![$((stringify!($c), $c as i64)),*]
    };
}

fn constants() -> Vec<(&'static str, i64)> {
    constant_table![
        CON_ENGINE_ABI_VERSION,
        CON_OK,
        CON_ERR_INVALID_ARGUMENT,
        CON_ERR_NOT_READY,
        CON_ERR_IO,
        CON_ERR_UNSUPPORTED,
        CON_ERR_BAD_CREDENTIAL,
        CON_ERR_SEND_FAILED,
        CON_ERR_PANIC,
        CON_CONSOLE_PS4,
        CON_CONSOLE_PS5,
        CON_TARGET_UNKNOWN,
        CON_TARGET_PS4_8,
        CON_TARGET_PS4_9,
        CON_TARGET_PS4_10,
        CON_TARGET_PS5_1,
        CON_CODEC_H264,
        CON_CODEC_H265,
        CON_CODEC_H265_HDR,
        CON_CONSOLE_STATE_READY,
        CON_CONSOLE_STATE_STANDBY,
        CON_CONSOLE_STATE_UNKNOWN,
        CON_LOG_NONE,
        CON_LOG_ERROR,
        CON_LOG_WARNING,
        CON_LOG_INFO,
        CON_LOG_DEBUG,
        CON_QUIT_STOPPED,
        CON_QUIT_SESSION_REQUEST_UNKNOWN,
        CON_QUIT_SESSION_REQUEST_CONNECTION_REFUSED,
        CON_QUIT_SESSION_REQUEST_IN_USE,
        CON_QUIT_SESSION_REQUEST_CRASHED,
        CON_QUIT_SESSION_REQUEST_VERSION_MISMATCH,
        CON_QUIT_CONTROL_UNKNOWN,
        CON_QUIT_CONTROL_CONNECT_FAILED,
        CON_QUIT_CONTROL_CONNECTION_REFUSED,
        CON_QUIT_STREAM_UNKNOWN,
        CON_QUIT_STREAM_REMOTE_DISCONNECTED,
        CON_QUIT_STREAM_REMOTE_SHUTDOWN,
        CON_QUIT_PSN_REGISTRATION_FAILED,
        CON_STAGE_UNKNOWN,
        CON_STAGE_SESSION_REQUEST,
        CON_STAGE_CONTROL,
        CON_STAGE_NETWORK_TEST,
        CON_STAGE_TRANSPORT,
        CON_STAGE_KEY_EXCHANGE,
        CON_STAGE_STREAM_INFO,
        CON_STAGE_STREAMING,
        CON_THREAD_IO,
        CON_THREAD_SENDER,
        CON_THREAD_SESSION,
        CON_THREAD_CONTROL,
        CON_THREAD_STATISTICS,
        CON_THREAD_DISCOVERY,
        CON_THREAD_REGISTRATION,
        CON_THREAD_PROBE,
        CON_THREAD_CAPTURE,
        CON_THREAD_HELPER,
        CON_BUTTON_CROSS,
        CON_BUTTON_CIRCLE,
        CON_BUTTON_SQUARE,
        CON_BUTTON_TRIANGLE,
        CON_BUTTON_LEFT,
        CON_BUTTON_RIGHT,
        CON_BUTTON_UP,
        CON_BUTTON_DOWN,
        CON_BUTTON_L1,
        CON_BUTTON_R1,
        CON_BUTTON_L3,
        CON_BUTTON_R3,
        CON_BUTTON_OPTIONS,
        CON_BUTTON_SHARE,
        CON_BUTTON_TOUCHPAD,
        CON_BUTTON_PS,
        CON_REGIST_OK,
        CON_REGIST_CANCELLED,
        CON_REGIST_INVALID_PIN,
        CON_REGIST_ACCOUNT_ID_REQUIRED,
        CON_REGIST_NO_PROBE_REPLY,
        CON_REGIST_CONNECT_FAILED,
        CON_REGIST_NETWORK,
        CON_REGIST_REJECTED,
        CON_REGIST_INVALID_RESPONSE,
        CON_REGIST_HOST_NOT_FOUND,
        CON_REGIST_INTERNAL,
        CON_EVENT_LOG,
        CON_EVENT_PIN_REQUESTED,
        CON_EVENT_KEYBOARD_OPENED,
        CON_EVENT_KEYBOARD_TEXT_CHANGED,
        CON_EVENT_KEYBOARD_CLOSED,
        CON_EVENT_CANNOT_DISPLAY,
        CON_EVENT_NETWORK_TEST,
        CON_EVENT_STREAM_INFO,
        CON_EVENT_CONNECTED,
        CON_EVENT_CONNECTION_QUALITY,
        CON_EVENT_SERVER_CORRUPT_FRAME,
        CON_EVENT_CLOUD_PRELUDE,
        CON_EVENT_VIDEO,
        CON_EVENT_AUDIO,
        CON_EVENT_HAPTICS,
        CON_EVENT_RUMBLE,
        CON_EVENT_TRIGGER_EFFECTS,
        CON_EVENT_LIGHT_BAR,
        CON_EVENT_PLAYER_INDEX,
        CON_EVENT_EFFECT_INTENSITY,
        CON_EVENT_MOTION_RESET,
        CON_EVENT_FEC_FAILURE,
        CON_EVENT_STATS,
        CON_EVENT_QUIT,
        CON_VIDEO_PARAMETER_SETS,
        CON_VIDEO_PICTURE,
        CON_VIDEO_FLAG_DECODE_ONLY,
        CON_INTENSITY_HAPTIC,
        CON_INTENSITY_TRIGGER,
        CON_MISSING_REFERENCE_WITHHOLD,
        CON_MISSING_REFERENCE_REPAIR_SHOW,
        CON_MISSING_REFERENCE_REPAIR_HIDE,
        CON_PROBE_OK,
        CON_PROBE_CANCELLED,
        CON_PROBE_HOST_NOT_FOUND,
        CON_PROBE_NO_CONNECTION,
        CON_PROBE_NO_RTT,
        CON_PROBE_NETWORK,
        CON_PROBE_INTERNAL,
        CON_PROBE_STAGE_CONNECT,
        CON_PROBE_STAGE_HELLO,
        CON_PROBE_STAGE_RTT,
        CON_PROBE_STAGE_MTU_IN,
        CON_PROBE_STAGE_MTU_OUT,
        CON_PROBE_STAGE_DONE,
    ]
}

#[test]
fn quit_reasons_and_stages_have_their_constants() {
    for (stage, code) in [
        (Stage::SessionRequest, CON_STAGE_SESSION_REQUEST),
        (Stage::Control, CON_STAGE_CONTROL),
        (Stage::NetworkTest, CON_STAGE_NETWORK_TEST),
        (Stage::Transport, CON_STAGE_TRANSPORT),
        (Stage::KeyExchange, CON_STAGE_KEY_EXCHANGE),
        (Stage::StreamInfo, CON_STAGE_STREAM_INFO),
        (Stage::Streaming, CON_STAGE_STREAMING),
    ] {
        assert_eq!(stage_code(stage), code);
    }
    for (reason, code) in [
        (QuitReason::Stopped, CON_QUIT_STOPPED),
        (
            QuitReason::SessionRequestUnknown,
            CON_QUIT_SESSION_REQUEST_UNKNOWN,
        ),
        (
            QuitReason::SessionRequestConnectionRefused,
            CON_QUIT_SESSION_REQUEST_CONNECTION_REFUSED,
        ),
        (
            QuitReason::SessionRequestInUse,
            CON_QUIT_SESSION_REQUEST_IN_USE,
        ),
        (
            QuitReason::SessionRequestCrashed,
            CON_QUIT_SESSION_REQUEST_CRASHED,
        ),
        (
            QuitReason::SessionRequestVersionMismatch,
            CON_QUIT_SESSION_REQUEST_VERSION_MISMATCH,
        ),
        (QuitReason::ControlUnknown, CON_QUIT_CONTROL_UNKNOWN),
        (
            QuitReason::ControlConnectFailed,
            CON_QUIT_CONTROL_CONNECT_FAILED,
        ),
        (
            QuitReason::ControlConnectionRefused,
            CON_QUIT_CONTROL_CONNECTION_REFUSED,
        ),
        (QuitReason::StreamUnknown, CON_QUIT_STREAM_UNKNOWN),
        (
            QuitReason::StreamRemoteDisconnected,
            CON_QUIT_STREAM_REMOTE_DISCONNECTED,
        ),
        (
            QuitReason::StreamRemoteShutdown,
            CON_QUIT_STREAM_REMOTE_SHUTDOWN,
        ),
        (
            QuitReason::PsnRegistrationFailed,
            CON_QUIT_PSN_REGISTRATION_FAILED,
        ),
    ] {
        assert_eq!(quit_reason_code(reason), code);
    }
}

fn generated_header() -> String {
    let config = cbindgen::Config::from_file(format!("{ENGINE}/cbindgen.toml")).unwrap();
    let mut out = Vec::new();
    cbindgen::Builder::new()
        .with_config(config)
        .with_src(format!("{ENGINE}/src/ffi/mod.rs"))
        .generate()
        .expect("cbindgen")
        .write(&mut out);
    String::from_utf8(out).unwrap()
}

fn header_defines(h: &str) -> Vec<(String, String)> {
    h.lines()
        .filter_map(|l| l.strip_prefix("#define "))
        .filter_map(|l| l.split_once(' '))
        .map(|(n, v)| (n.to_string(), v.trim().to_string()))
        .collect()
}

fn define_value(v: &str) -> i64 {
    let v = v.trim_start_matches('(').trim_end_matches(')');
    if let Some((a, b)) = v.split_once(" << ") {
        return define_value(a) << define_value(b);
    }
    v.trim_end_matches('u')
        .parse()
        .unwrap_or_else(|_| panic!("value {v:?}"))
}

fn header_functions(h: &str) -> Vec<String> {
    let mut names = Vec::new();
    for l in h.lines() {
        if l.starts_with(' ') || l.starts_with('#') || l.starts_with("typedef") {
            continue;
        }
        if let Some(open) = l.find("con_") {
            if let Some(len) = l[open..].find('(') {
                names.push(l[open..open + len].to_string());
            }
        }
    }
    names
}

#[test]
fn header_is_generated_from_the_rust_definitions() {
    let h = generated_header();
    assert!(h.starts_with("#pragma once\n"));
    assert!(
        !h.contains("//") && !h.contains("/*"),
        "comment in the header"
    );
    assert!(h.contains("#define CON_ENGINE_ABI_VERSION 2u"));

    let defines = header_defines(&h);
    let rust = constants();
    assert_eq!(
        defines.iter().map(|(n, _)| n.as_str()).collect::<Vec<_>>(),
        rust.iter().map(|(n, _)| *n).collect::<Vec<_>>(),
        "#define names in the generated header differ from constants()"
    );
    for ((name, value), (_, v)) in defines.iter().zip(&rust) {
        assert_eq!(define_value(value), *v, "{name} = {value}");
        let unsigned = !name.starts_with("CON_ERR_")
            && !name.starts_with("CON_LOG_")
            && !name.starts_with("CON_MISSING_REFERENCE_")
            && name != "CON_OK";
        assert_eq!(value.contains('u'), unsigned, "{name} = {value}");
    }

    let mut declared = header_functions(&h);
    let mut ours: Vec<String> = all_functions().iter().map(|(n, _)| n.to_string()).collect();
    declared.sort();
    ours.sort();
    assert_eq!(declared, ours);

    let out = PathBuf::from(format!("{ENGINE}/../work/engine-rust"));
    let mut shipped = vec![out.join("include/con_engine.h")];
    if let Ok(dir) = std::fs::read_dir(&out) {
        for e in dir.flatten() {
            shipped.push(e.path().join("include/con_engine.h"));
        }
    }
    for path in shipped.iter().filter(|p| p.exists()) {
        let text = std::fs::read_to_string(path).unwrap();
        assert!(
            text == h,
            "{} is out of date with src/ffi; run Engine/build.sh to regenerate it",
            path.display()
        );
    }
}

fn layout_asserts() -> String {
    let mut a: Vec<String> = Vec::new();
    macro_rules! layout {
        ($($t:ident { $($f:ident),* $(,)? })*) => {$(
            a.push(format!(
                "_Static_assert(sizeof({t}) == {s} && _Alignof({t}) == {al}, \"{t}\");",
                t = stringify!($t), s = size_of::<$t>(), al = align_of::<$t>()
            ));
            $(a.push(format!(
                "_Static_assert(offsetof({t}, {f}) == {o}, \"{t}.{f}\");",
                t = stringify!($t), f = stringify!($f), o = offset_of!($t, $f)
            ));)*
        )*};
    }
    layout!(
        ConDiscoveryConfig { bind_address, destination, extra_destinations,
            extra_destination_count, initial_delay_ms, period_ms, drop_after_rounds,
            max_consoles, ps4_port, ps5_port, local_port_first, local_port_last }
        ConDiscoveredHost { address, host_id, host_name, host_type, system_version,
            protocol_version, running_app_title_id, running_app_name, state, kind, generation,
            target, status, request_port }
        ConRegistrationRequest { host, pin, online_id, target, probe_timeout_ms, io_timeout_ms,
            port, account_id }
        ConRegistrationResult { error_text, nickname, ap_ssid, ap_bssid, ap_key, ap_name,
            key_type, support_cmd, status, target, http_status, app_reason, regist_key, rp_key,
            mac, has_key_type, has_support_cmd }
        ConConsoleConfig { host, kind, codec, video_height, max_fps, bitrate_kbps, session_port,
            network_test_port, stream_port, auto_downgrade, video_disabled, keyboard,
            network_test, regist_key, rp_key }
        ConCloudConfig { address, session_id, launch_spec, codec, max_fps, mtu_in, mtu_out,
            rtt_us, port, prefix, ps5, handshake_key }
        ConSessionOptions { loss_ceiling, video_capture_path, dualsense, log_level,
            stats_interval_ms, discard_video, discard_audio, idr_on_fec_failure, decode_audio }
        ConLogEvent { text, level }
        ConPinEvent { previous_wrong }
        ConKeyboardEvent { text }
        ConDisplayEvent { cannot_display }
        ConNetworkTestEvent { rtt_us, rtt_samples, mtu_in, mtu_out, fallback }
        ConVideoProfile { header, header_size, width, height }
        ConStreamInfoEvent { profiles, profile_count, start_timeout, afk_timeout,
            afk_disconnect_timeout, congestion_control_interval, audio_rate, audio_frame_size,
            audio_channels, audio_bits, audio_header }
        ConConnectionQualityEvent { upstream_loss, rtt, target_bitrate, upstream_bitrate, loss,
            disable_upstream_audio }
        ConCorruptFrameEvent { start, end }
        ConCloudPreludeEvent { size, msg_type, has_stream_info }
        ConVideoEvent { data, size, padded_size, frames_lost, codec, width, height, kind,
            frame_index, profile, recovered, fec_recovered, keyframe, accepted, flags }
        ConAudioEvent { pcm, pcm_count, opus, opus_size, samples_per_channel, sample_rate,
            frame_index, channels, decoded, concealed }
        ConHapticsEvent { pcm, size, sample_rate, frame_index, channels }
        ConRumbleEvent { left, right }
        ConTriggerEffectsEvent { left, right }
        ConLightBarEvent { r, g, b }
        ConPlayerIndexEvent { index }
        ConEffectIntensityEvent { kind, value }
        ConFecFailureEvent { frame_index, idr_requested }
        ConStats { rtt_latest_us, rtt_median_us, rtt_samples, datagrams_sent, datagrams_received,
            retransmissions, given_up, tag_failures, dropped, held_media_dropped,
            messages_delivered, media_delivered, congestion_reports, report_received,
            report_lost, video_packets, video_packets_dropped, video_units_received,
            video_units_rejected, video_units_late, video_profile_switches,
            video_frames_complete, video_frames_fec_recovered, video_frames_fec_failed,
            video_frames_failed, video_frames_delivered, video_frames_rejected,
            video_frames_skipped_waiting_idr, video_frames_reference_missing,
            video_frames_reference_repaired, video_frames_unchecked, video_frames_lost,
            video_corrupt_reports, video_idr_requests, video_bytes_delivered, audio_datagrams,
            audio_datagrams_dropped, audio_frames_offered, audio_frames_discarded,
            audio_frames_played, audio_frames_concealed, audio_decode_errors, haptics_datagrams,
            haptics_frames, haptics_dropped, feedback_state_sent, feedback_history_sent,
            feedback_history_dropped, feedback_refreshes, measured_bitrate, running_bitrate,
            audio_decoded }
        ConStatsEvent { stats }
        ConQuitEvent { text, reason, stage, is_error }
        ConTouch { id, x, y }
        ConControllerState { buttons, left_x, left_y, right_x, right_y, touches, gyro, accel,
            orientation, l2, r2 }
        ConCloudProbeConfig { address, credential, connect_timeout_ms, hello_echo_ms, pings,
            pong_timeout_ms, mtu_attempts, mtu_wait_min_ms, mtu_wait_max_ms, client_mtu_reply_ms,
            port, prefix, measure_mtu }
        ConCloudProbeResult { rtt_us, rtt_samples, mtu_in, mtu_out, status, stage, hello_echoed,
            error_text }
    );
    a.push(format!(
        "_Static_assert(sizeof(ConEvent) == {} && offsetof(ConEvent, type) == {} && offsetof(ConEvent, data) == {} && sizeof(ConEventData) == {}, \"ConEvent\");",
        size_of::<ConEvent>(),
        offset_of!(ConEvent, type_),
        offset_of!(ConEvent, data),
        size_of::<ConEventData>()
    ));
    for (name, value) in constants() {
        a.push(format!("_Static_assert({name} == {value}LL, \"{name}\");"));
    }
    a.join("\n")
}

fn cc(args: &[&str]) {
    let out = std::process::Command::new("cc")
        .args(args)
        .output()
        .expect("running cc");
    assert!(
        out.status.success(),
        "cc {:?} failed:\n{}{}",
        args,
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
}

#[test]
#[cfg(unix)]
fn header_compiles_with_the_rust_layouts() {
    let dir = tmp().join(format!("header-check-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("con_engine.h"), generated_header()).unwrap();
    let c = dir.join("layout.c");
    std::fs::write(
        &c,
        format!(
            "#include \"con_engine.h\"\n#include <stddef.h>\n{}\nint main(void) {{ return 0; }}\n",
            layout_asserts()
        ),
    )
    .unwrap();
    let include = format!("-I{}", dir.display());
    cc(&[
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-pedantic",
        &include,
        "-fsyntax-only",
        c.to_str().unwrap(),
    ]);
    let cpp = dir.join("header.cpp");
    std::fs::write(
        &cpp,
        "#include \"con_engine.h\"\nint main() { return con_engine_abi_version() == CON_ENGINE_ABI_VERSION ? 0 : 1; }\n",
    )
    .unwrap();
    cc(&[
        "-x",
        "c++",
        "-std=c++17",
        "-Wall",
        "-Wextra",
        "-Werror",
        &include,
        "-fsyntax-only",
        cpp.to_str().unwrap(),
    ]);
    let _ = std::fs::remove_dir_all(dir);
}

const SAMPLE: &[u8] = b"HTTP/1.1 620 Server Standby\nhost-id:0123456789AB\nhost-type:PS5\nhost-name:Living room\nhost-request-port:997\ndevice-discovery-protocol-version:00030010\nsystem-version:08520011\n";

#[derive(Default)]
struct HostsSeen {
    line: Mutex<Option<String>>,
}

unsafe extern "C" fn on_hosts(user: *mut c_void, hosts: *const ConDiscoveredHost, count: usize) {
    let seen: &HostsSeen = state(user);
    if hosts.is_null() {
        return;
    }
    for h in std::slice::from_raw_parts(hosts, count) {
        if text(h.host_id).as_deref() != Some("0123456789AB") {
            continue;
        }
        let mut line = seen.line.lock().unwrap();
        if line.is_none() {
            let s = |p| text(p).unwrap_or_else(|| "(null)".into());
            *line = Some(format!(
                "{}|{}|{}|state={}|kind={}|generation={}|target={}|status={}|port={}|app={}",
                s(h.address),
                s(h.host_id),
                s(h.host_name),
                h.state,
                h.kind,
                h.generation,
                h.target,
                h.status,
                h.request_port,
                s(h.running_app_name)
            ));
        }
    }
}

#[test]
fn c_abi_discovers_and_wakes() {
    let _threads = engine_threads();
    let sock = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    sock.set_read_timeout(Some(Duration::from_millis(50)))
        .unwrap();
    let port = sock.local_addr().unwrap().port();
    let stop = Arc::new(AtomicBool::new(false));
    let fake = {
        let stop = stop.clone();
        std::thread::spawn(move || {
            let mut wakeups = Vec::new();
            let mut searches = 0;
            let mut buf = [0u8; 1500];
            while !stop.load(Ordering::SeqCst) {
                if let Ok((n, from)) = sock.recv_from(&mut buf) {
                    let m = &buf[..n];
                    if m.starts_with(b"SRCH") {
                        searches += 1;
                        sock.send_to(SAMPLE, from).unwrap();
                    } else if m.starts_with(b"WAKEUP") {
                        wakeups.push(String::from_utf8_lossy(m).into_owned());
                    }
                }
            }
            (searches, wakeups)
        })
    };

    let seen: &'static HostsSeen = leak();
    unsafe {
        let mut cfg: ConDiscoveryConfig = std::mem::zeroed();
        assert_eq!(con_discovery_config_default(&mut cfg), CON_OK);
        assert_eq!(
            (cfg.ps4_port, cfg.ps5_port, cfg.period_ms),
            (987, 9302, 500)
        );
        let local = cstr("127.0.0.1");
        let extra = [local.as_ptr()];
        cfg.bind_address = local.as_ptr();
        cfg.destination = local.as_ptr();
        cfg.extra_destinations = extra.as_ptr();
        cfg.extra_destination_count = 1;
        cfg.ps4_port = port;
        cfg.ps5_port = port;
        cfg.initial_delay_ms = 20;
        cfg.period_ms = 100;
        let mut d: *mut ConDiscovery = std::ptr::null_mut();
        assert_eq!(
            con_discovery_start(&cfg, None, std::ptr::null_mut(), &mut d),
            CON_ERR_INVALID_ARGUMENT
        );
        assert!(d.is_null());
        let not_an_address = cstr("not an address");
        let bad = [not_an_address.as_ptr()];
        cfg.extra_destinations = bad.as_ptr();
        assert_eq!(
            con_discovery_start(&cfg, Some(on_hosts), user(seen), &mut d),
            CON_ERR_INVALID_ARGUMENT
        );
        cfg.extra_destinations = extra.as_ptr();
        assert_eq!(
            con_discovery_start(&cfg, Some(on_hosts), user(seen), &mut d),
            CON_OK
        );
        assert!(!d.is_null());
        assert!(wait(10_000, || seen.line.lock().unwrap().is_some()));
        assert_eq!(
            con_discovery_wake(d, local.as_ptr(), CON_CONSOLE_PS5, KEY_TEXT.as_ptr()),
            CON_OK
        );
        assert_eq!(
            con_discovery_wake(d, local.as_ptr(), 7, KEY_TEXT.as_ptr()),
            CON_ERR_INVALID_ARGUMENT
        );
        assert_eq!(
            con_wake(local.as_ptr(), port, CON_CONSOLE_PS4, KEY_TEXT.as_ptr()),
            CON_OK
        );
        let bad_key = *b"xyz\0\0\0\0\0\0\0\0\0\0\0\0\0";
        assert_eq!(
            con_wake(local.as_ptr(), port, CON_CONSOLE_PS4, bad_key.as_ptr()),
            CON_ERR_BAD_CREDENTIAL
        );
        con_discovery_stop(d);
        con_discovery_stop(std::ptr::null_mut());
    }
    std::thread::sleep(Duration::from_millis(100));
    stop.store(true, Ordering::SeqCst);
    let (searches, wakeups) = fake.join().unwrap();
    assert_eq!(
        seen.line.lock().unwrap().as_deref(),
        Some("127.0.0.1|0123456789AB|Living room|state=1|kind=1|generation=4|target=4|status=620|port=997|app=(null)")
    );
    assert!(searches >= 2);
    assert_eq!(wakeups.len(), 2, "{wakeups:?}");
    assert!(wakeups.iter().any(
        |w| w.contains("user-credential:439041101\ndevice-discovery-protocol-version:00030010")
    ));
    assert!(wakeups.iter().any(
        |w| w.contains("user-credential:439041101\ndevice-discovery-protocol-version:00020020")
    ));
}

const PS5_BODY: &str = "PS5-RegistKey: 3161326233633464\r\nRP-Key: 00112233445566778899AABBCCDDEEFF\r\nPS5-Mac: 0a1b2c3d4e5f\r\nPS5-Nickname: Living room\r\nRP-KeyType: 2\r\nAP-Ssid: net\r\nRP-SupportCmd: 0x1f\r\n";

fn registration_fake() -> (u16, std::thread::JoinHandle<String>) {
    let (listener, udp) = loop {
        let l = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        if let Ok(u) = UdpSocket::bind((Ipv4Addr::LOCALHOST, l.local_addr().unwrap().port())) {
            break (l, u);
        }
    };
    let port = listener.local_addr().unwrap().port();
    let t = std::thread::spawn(move || {
        let target = Target::Ps5V1;
        let mut buf = [0u8; 64];
        let (n, from) = udp.recv_from(&mut buf).unwrap();
        assert_eq!(&buf[..n], b"SRC3\0");
        udp.send_to(b"RES3", from).unwrap();
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
        let c0 = body[0x18d] & 0x1f;
        let c1 = body[0] >> 3;
        let mut e = [0u8; 16];
        e[..8].copy_from_slice(&body[0x191..0x199]);
        e[8..].copy_from_slice(&body[0xc7..0xcf]);
        let seed = unmask_pin_seed(target, &e, c1);
        let keys = pin_keys(target, 12_345_678, &seed, c0, c1);
        let cipher = RpCipher::new(keys.key, seed, target.iv_hmac_key());
        let inner = String::from_utf8(cipher.decrypted(0, &body[FILLER_LEN..])).unwrap();
        let enc = cipher.encrypted(0, PS5_BODY.as_bytes());
        let head = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", enc.len());
        s.write_all(head.as_bytes()).unwrap();
        s.write_all(&enc).unwrap();
        inner
    });
    (port, t)
}

type RegistCopy = (ConRegistrationResult, Option<String>, Option<String>);

#[derive(Default)]
struct RegistSeen {
    done: AtomicBool,
    result: Mutex<Option<RegistCopy>>,
}

unsafe extern "C" fn on_registration(user: *mut c_void, r: *const ConRegistrationResult) {
    let seen: &RegistSeen = state(user);
    let mut copy = *r;
    let nickname = text(copy.nickname);
    let error = text(copy.error_text);
    for p in [
        &mut copy.nickname,
        &mut copy.error_text,
        &mut copy.ap_ssid,
        &mut copy.ap_bssid,
        &mut copy.ap_key,
        &mut copy.ap_name,
    ] {
        *p = std::ptr::null();
    }
    *seen.result.lock().unwrap() = Some((copy, nickname, error));
    seen.done.store(true, Ordering::SeqCst);
}

fn register_once(req: &ConRegistrationRequest, cancel_after_ms: u64) -> RegistCopy {
    let seen: &'static RegistSeen = leak();
    unsafe {
        let mut r: *mut ConRegistration = std::ptr::null_mut();
        assert_eq!(
            con_registration_start(req, Some(on_registration), user(seen), &mut r),
            CON_OK
        );
        assert!(!r.is_null());
        if cancel_after_ms > 0 {
            std::thread::sleep(Duration::from_millis(cancel_after_ms));
            con_registration_cancel(r);
            assert!(wait(2_000, || seen.done.load(Ordering::SeqCst)));
        }
        assert!(wait(15_000, || seen.done.load(Ordering::SeqCst)));
        con_registration_free(r);
    }
    let result = seen.result.lock().unwrap().take();
    result.unwrap()
}

#[test]
fn c_abi_registers_rejects_a_bad_pin_and_cancels() {
    let _threads = engine_threads();
    let (port, fake) = registration_fake();
    let silent = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    let silent_port = silent.local_addr().unwrap().port();
    unsafe {
        let mut req: ConRegistrationRequest = std::mem::zeroed();
        assert_eq!(con_registration_request_default(&mut req), CON_OK);
        assert_eq!(
            (req.port, req.target, req.probe_timeout_ms),
            (9295, CON_TARGET_PS5_1, 3000)
        );
        let host = cstr("127.0.0.1");
        let pin = cstr("12345678");
        req.host = host.as_ptr();
        req.port = port;
        req.pin = pin.as_ptr();
        req.account_id = [1, 2, 3, 4, 5, 6, 7, 8];

        let (r, nickname, _) = register_once(&req, 0);
        assert_eq!(r.status, CON_REGIST_OK);
        assert_eq!(&r.regist_key[..8], b"1a2b3c4d");
        assert_eq!(r.mac, [0x0a, 0x1b, 0x2c, 0x3d, 0x4e, 0x5f]);
        assert_eq!(nickname.as_deref(), Some("Living room"));
        assert_eq!((r.key_type, r.has_key_type), (2, 1));
        assert_eq!((r.support_cmd, r.has_support_cmd), (31, 1));
        assert_eq!((r.rp_key[0], r.rp_key[1], r.rp_key[15]), (0x00, 0x11, 0xff));

        let short = cstr("123");
        req.pin = short.as_ptr();
        let (r, _, error) = register_once(&req, 0);
        assert_eq!(r.status, CON_REGIST_INVALID_PIN);
        assert!(error.unwrap().starts_with("the PIN must be 8"));

        req.pin = pin.as_ptr();
        req.port = silent_port;
        req.probe_timeout_ms = 10_000;
        let (r, _, _) = register_once(&req, 150);
        assert_eq!(r.status, CON_REGIST_CANCELLED);

        let mut handle = std::ptr::dangling_mut::<ConRegistration>();
        assert_eq!(
            con_registration_start(
                std::ptr::null(),
                Some(on_registration),
                std::ptr::null_mut(),
                &mut handle
            ),
            CON_ERR_INVALID_ARGUMENT
        );
        assert!(handle.is_null());
        con_registration_free(std::ptr::null_mut());
    }
    let inner = fake.join().unwrap();
    assert!(inner.ends_with("Np-AccountId: AQIDBAUGBwg=\r\n"), "{inner}");
    drop(silent);
}

const AUDIO_HEADER: [u8; 14] = [2, 16, 0, 0, 0xbb, 0x80, 0, 0, 1, 0xe0, 0, 0, 0, 1];

#[derive(Debug, Default)]
struct StreamSeen {
    launch_spec_len: usize,
    session_key: String,
    idr: usize,
    corrupt: Vec<(u32, u32)>,
    cross_pressed: bool,
    states: usize,
    disconnect: Option<String>,
    tag_failures: u32,
}

fn stream_setup(
    s: &mut FakeServer,
    version: u32,
    initial_tsn: Option<u32>,
    hk: Option<[u8; 16]>,
    cipher: Option<&RpCipher>,
    profile: Resolution,
    seen: &mut StreamSeen,
) {
    let w = Duration::from_secs(10);
    s.handshake(initial_tsn);
    let (_, big) = s.recv_proto(w).expect("hello");
    let Message::Big(big) = big else {
        panic!("expected BIG")
    };
    seen.launch_spec_len = big.launch_spec.len();
    seen.session_key = big.session_key.clone();
    let hk = hk.unwrap_or_else(|| {
        let mut b = base64::engine::general_purpose::STANDARD
            .decode(&big.launch_spec)
            .unwrap();
        let ks = cipher.unwrap().keystream(0, b.len());
        for (x, k) in b.iter_mut().zip(ks) {
            *x ^= k;
        }
        let json = String::from_utf8_lossy(&b).into_owned();
        let at = json.find("\"handshakeKey\":\"").unwrap() + 16;
        let end = at + json[at..].find('"').unwrap();
        base64::engine::general_purpose::STANDARD
            .decode(&json[at..end])
            .unwrap()
            .try_into()
            .unwrap()
    });
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
            ecdh_signature: Some(sign_public_key(&hk, &spub).to_vec()),
        }),
    );
    s.install_keys(&z, &hk);
    s.send_proto(
        1,
        &Message::StreamInfo(StreamInfo {
            resolutions: vec![profile],
            audio_header: AUDIO_HEADER.to_vec(),
            afk_timeout: Some(600),
            ..Default::default()
        }),
    );
    for _ in 0..3 {
        s.recv_proto(w).expect("reply to stream info");
    }
}

fn stream_collect(
    s: &mut FakeServer,
    seen: &mut StreamSeen,
    until: Instant,
    done: impl Fn(&StreamSeen) -> bool,
) {
    while Instant::now() < until && seen.disconnect.is_none() && !done(seen) {
        if let Some(m) = s.recv_message(Duration::from_millis(20)) {
            if m.data_type == 0 {
                match Message::decode(&m.data).unwrap() {
                    Message::IdrRequest => seen.idr += 1,
                    Message::CorruptFrame(c) => seen.corrupt.push((c.start, c.end)),
                    Message::Disconnect(d) => seen.disconnect = Some(d.reason),
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
                seen.states += 1;
            } else if let Some(events) = parse_history(&d[12..]) {
                seen.cross_pressed |= events.iter().any(|e| {
                    matches!(
                        e,
                        HistoryEvent::Button {
                            code: 0x88,
                            value: Some(0xff),
                            ..
                        }
                    )
                });
            }
        }
    }
    seen.tag_failures = s.tag_failures;
}

fn h265_picture(frame: u16, idr: bool, neg: &[bool]) -> Vec<u8> {
    let body: Vec<u8> = (0..500)
        .map(|i| 0x20 + ((i * 11 + usize::from(frame) * 17) % 200) as u8)
        .collect();
    h26x::build_h265_slice(idr, u32::from(frame) - 1, 8, neg, &body)
}

fn send_picture(s: &mut FakeServer, packet: &mut u16, frame: u16, picture: &[u8]) {
    let units = frame_units(picture, 150, 1);
    let n = units.len();
    for (u, unit) in units.iter().enumerate() {
        let d = video_datagram(
            packet.wrapping_add(u as u16),
            frame,
            u as u16,
            n as u16,
            1,
            0,
            false,
            unit,
        );
        let d = s.build_media(d, 21);
        s.send_raw(&d);
    }
    *packet = packet.wrapping_add(n as u16);
}

type QuitCopy = (u32, u32, u8, Option<String>);

#[derive(Default)]
struct EventsSeen {
    session: AtomicPtr<ConSession>,
    connected: AtomicBool,
    quit_seen: AtomicBool,
    free_in_quit: AtomicBool,
    freed_in_callback: AtomicBool,
    events_after_quit: AtomicU32,
    log_lines: AtomicU32,
    stream_info: Mutex<Option<String>>,
    video_params: AtomicU32,
    video_pictures: AtomicU32,
    video_padding_bad: AtomicBool,
    keyframe_from_callback: AtomicBool,
    video_decode_only: AtomicU32,
    video_bad_flags: AtomicU32,
    audio_frames: AtomicU32,
    audio_decoded: AtomicU32,
    haptics_frames: AtomicU32,
    rumble: Mutex<Option<(u8, u8)>>,
    triggers_seen: AtomicBool,
    light_seen: AtomicBool,
    player_seen: AtomicBool,
    intensity_seen: AtomicBool,
    stats_events: AtomicU32,
    quit: Mutex<Option<QuitCopy>>,
}

impl EventsSeen {
    fn quit_line(&self) -> String {
        let q = self.quit.lock().unwrap().clone();
        let (reason, stage, is_error, text) = q.expect("no quit event");
        let name = |p: *const c_char| unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
        format!(
            "{reason} {} is_error={is_error} text={} stage={stage} {}",
            name(unsafe { con_quit_reason_name(reason) }),
            text.as_deref().unwrap_or("(none)"),
            name(unsafe { con_stage_name(stage) })
        )
    }
}

unsafe extern "C" fn on_event(user: *mut c_void, e: *mut ConEvent) {
    let seen: &EventsSeen = state(user);
    let e = &mut *e;
    if seen.quit_seen.load(Ordering::SeqCst) {
        seen.events_after_quit.fetch_add(1, Ordering::SeqCst);
    }
    match e.type_ {
        CON_EVENT_LOG => {
            seen.log_lines.fetch_add(1, Ordering::SeqCst);
        }
        CON_EVENT_STREAM_INFO => {
            let s = &e.data.stream_info;
            let first = (s.profile_count > 0).then(|| &*s.profiles);
            *seen.stream_info.lock().unwrap() = Some(format!(
                "profiles={} first={}x{} header={} audio={}/{}/{} afk={}",
                s.profile_count,
                first.map_or(0, |p| p.width),
                first.map_or(0, |p| p.height),
                first.map_or(0, |p| p.header_size),
                s.audio_channels,
                s.audio_rate,
                s.audio_frame_size,
                s.afk_timeout
            ));
        }
        CON_EVENT_CONNECTED => seen.connected.store(true, Ordering::SeqCst),
        CON_EVENT_VIDEO => {
            let v = &mut e.data.video;
            if v.padded_size != v.size + 64 || v.data.is_null() {
                seen.video_padding_bad.store(true, Ordering::SeqCst);
            } else {
                let all = std::slice::from_raw_parts(v.data, v.padded_size);
                if all[v.size..].iter().any(|&b| b != 0) {
                    seen.video_padding_bad.store(true, Ordering::SeqCst);
                }
            }
            let flags = u32::from(v.flags);
            if flags & !CON_VIDEO_FLAG_DECODE_ONLY != 0
                || (v.kind == CON_VIDEO_PARAMETER_SETS && flags != 0)
            {
                seen.video_bad_flags.fetch_add(1, Ordering::SeqCst);
            }
            if flags & CON_VIDEO_FLAG_DECODE_ONLY != 0 {
                seen.video_decode_only.fetch_add(1, Ordering::SeqCst);
            }
            if v.kind == CON_VIDEO_PARAMETER_SETS {
                seen.video_params.fetch_add(1, Ordering::SeqCst);
            } else {
                seen.video_pictures.fetch_add(1, Ordering::SeqCst);
                let s = seen.session.load(Ordering::SeqCst);
                if !s.is_null()
                    && !seen.keyframe_from_callback.load(Ordering::SeqCst)
                    && con_session_request_keyframe(s) == CON_OK
                {
                    seen.keyframe_from_callback.store(true, Ordering::SeqCst);
                }
            }
            v.accepted = 1;
        }
        CON_EVENT_AUDIO => {
            let a = &e.data.audio;
            seen.audio_frames.fetch_add(1, Ordering::SeqCst);
            if a.decoded != 0
                && !a.pcm.is_null()
                && a.pcm_count == a.samples_per_channel * usize::from(a.channels)
                && a.sample_rate == 48_000
            {
                seen.audio_decoded.fetch_add(1, Ordering::SeqCst);
            }
        }
        CON_EVENT_HAPTICS => {
            let h = &e.data.haptics;
            if h.size > 0 && !h.pcm.is_null() && h.sample_rate == 3000 {
                seen.haptics_frames.fetch_add(1, Ordering::SeqCst);
            }
        }
        CON_EVENT_RUMBLE => {
            *seen.rumble.lock().unwrap() = Some((e.data.rumble.left, e.data.rumble.right));
        }
        CON_EVENT_TRIGGER_EFFECTS => {
            let t = &e.data.trigger_effects;
            if t.left[0] == 0x21 && t.right[0] == 0x25 {
                seen.triggers_seen.store(true, Ordering::SeqCst);
            }
        }
        CON_EVENT_LIGHT_BAR => {
            if e.data.light_bar.r == 0xff {
                seen.light_seen.store(true, Ordering::SeqCst);
            }
        }
        CON_EVENT_PLAYER_INDEX => {
            if e.data.player_index.index == 2 {
                seen.player_seen.store(true, Ordering::SeqCst);
            }
        }
        CON_EVENT_EFFECT_INTENSITY => seen.intensity_seen.store(true, Ordering::SeqCst),
        CON_EVENT_STATS => {
            let st = e.data.stats.stats;
            if !st.is_null() && (*st).datagrams_received > 0 {
                seen.stats_events.fetch_add(1, Ordering::SeqCst);
            }
        }
        CON_EVENT_QUIT => {
            let q = &e.data.quit;
            *seen.quit.lock().unwrap() = Some((q.reason, q.stage, q.is_error, text(q.text)));
            if seen.free_in_quit.load(Ordering::SeqCst) {
                let s = seen.session.swap(std::ptr::null_mut(), Ordering::SeqCst);
                con_session_free(s);
                seen.freed_in_callback.store(true, Ordering::SeqCst);
            }
            seen.quit_seen.store(true, Ordering::SeqCst);
        }
        _ => {}
    }
}

struct ThreadsSeen {
    roles: AtomicU32,
    interactive: AtomicI32,
}

static THREADS: ThreadsSeen = ThreadsSeen {
    roles: AtomicU32::new(0),
    interactive: AtomicI32::new(-100),
};

unsafe extern "C" fn on_thread(user: *mut c_void, role: u32, name: *const c_char) {
    if user != user_of_threads()
        || name.is_null()
        || !CStr::from_ptr(name).to_bytes().starts_with(b"con-")
    {
        return;
    }
    if role < 32 {
        THREADS.roles.fetch_or(1 << role, Ordering::SeqCst);
    }
    if role == CON_THREAD_IO {
        THREADS
            .interactive
            .store(con_thread_set_interactive(), Ordering::SeqCst);
    }
}

fn user_of_threads() -> *mut c_void {
    user(&THREADS)
}

#[test]
fn c_abi_runs_a_console_session() {
    let _threads = ENGINE_THREADS.write().unwrap_or_else(|p| p.into_inner());
    let (l, tcp) = listener();
    let control = std::thread::spawn(move || {
        answer_session_request(&l, "1.0");
        let cipher = RpCipher::for_session(Target::Ps5V1, &NONCE, &RP_KEY);
        serve_control(&l, cipher, 2, 5)
    });
    let mut s = FakeServer::bind();
    let stream_port = s.addr().port();
    let mut enc = OpusEncoder::new(48000, 2, false, Some(64000)).unwrap();
    let opus: Vec<Vec<u8>> = tone(440.0, 30)
        .iter()
        .map(|p| enc.encode(p, 400).unwrap())
        .collect();
    let fake = std::thread::spawn(move || {
        let mut seen = StreamSeen::default();
        let cipher = RpCipher::for_session(Target::Ps5V1, &NONCE, &RP_KEY);
        let profile = Resolution {
            width: 1920,
            height: 1080,
            video_header: h26x::build_h265_parameter_sets(8),
        };
        stream_setup(&mut s, 12, None, None, Some(&cipher), profile, &mut seen);
        let mut vp = 0u16;
        send_picture(&mut s, &mut vp, 1, &h265_picture(1, true, &[]));
        send_picture(&mut s, &mut vp, 2, &h265_picture(2, false, &[true]));
        send_picture(&mut s, &mut vp, 3, &h265_picture(3, false, &[true]));
        for f in 1..=30u16 {
            let get = |i: u16| {
                if i >= 1 {
                    opus[usize::from(i) - 1].clone()
                } else {
                    vec![0; 80]
                }
            };
            let payload = [get(f), get(f.saturating_sub(2)), get(f.saturating_sub(1))].concat();
            let d = audio_datagram(12, f, f, 3, 80, 2, 1, 5, false, &payload);
            let d = s.build_media(d, 20);
            s.send_raw(&d);
        }
        for f in 1..=3u16 {
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
        stream_collect(
            &mut s,
            &mut seen,
            Instant::now() + Duration::from_secs(15),
            |x| x.idr >= 1 && x.cross_pressed,
        );
        stream_collect(
            &mut s,
            &mut seen,
            Instant::now() + Duration::from_millis(800),
            |_| false,
        );
        s.send_proto(
            1,
            &Message::Disconnect(Disconnect {
                reason: "Server shutting down".into(),
                extended_info: None,
            }),
        );
        stream_collect(
            &mut s,
            &mut seen,
            Instant::now() + Duration::from_secs(10),
            |_| false,
        );
        seen
    });

    let capture = tmp().join(format!("capture-{}.bin", std::process::id()));
    let not_capture = tmp().join(format!("not-capture-{}.txt", std::process::id()));
    let audio_capture = tmp().join(format!("audio-capture-{}.bin", std::process::id()));
    let _ = std::fs::remove_file(&capture);
    let _ = std::fs::remove_file(&audio_capture);
    std::fs::write(&not_capture, b"some other file").unwrap();

    let seen: &'static EventsSeen = leak();
    let capture_c = cstr(capture.to_str().unwrap());
    let not_capture_c = cstr(not_capture.to_str().unwrap());
    let audio_capture_c = cstr(audio_capture.to_str().unwrap());
    unsafe {
        assert_eq!(
            con_set_thread_callback(Some(on_thread), user_of_threads()),
            CON_OK
        );
        let mut cfg: ConConsoleConfig = std::mem::zeroed();
        assert_eq!(con_console_config_default(&mut cfg), CON_OK);
        assert_eq!(
            (cfg.session_port, cfg.stream_port, cfg.network_test),
            (9295, 9296, 1)
        );
        let host = cstr("127.0.0.1");
        cfg.host = host.as_ptr();
        cfg.kind = CON_CONSOLE_PS5;
        cfg.codec = CON_CODEC_H265;
        cfg.video_height = 1080;
        cfg.max_fps = 60;
        cfg.session_port = tcp.port();
        cfg.stream_port = stream_port;
        cfg.network_test = 0;
        cfg.regist_key = REGIST;
        cfg.rp_key = RP_KEY;
        let mut opt: ConSessionOptions = std::mem::zeroed();
        assert_eq!(con_session_options_default(&mut opt), CON_OK);
        assert_eq!(
            (opt.dualsense, opt.decode_audio, opt.log_level),
            (-1, 1, CON_LOG_INFO)
        );
        assert!(opt.video_capture_path.is_null());
        opt.log_level = CON_LOG_DEBUG;
        opt.stats_interval_ms = 100;
        opt.video_capture_path = capture_c.as_ptr();

        let mut s: *mut ConSession = std::ptr::null_mut();
        cfg.codec = 9;
        assert_eq!(
            con_session_start_console(&cfg, &opt, Some(on_event), user(seen), &mut s),
            CON_ERR_INVALID_ARGUMENT
        );
        assert!(s.is_null());
        cfg.codec = CON_CODEC_H265;
        assert_eq!(
            con_session_start_console(&cfg, &opt, Some(on_event), user(seen), &mut s),
            CON_OK
        );
        assert!(!s.is_null());
        seen.session.store(s, Ordering::SeqCst);
        assert_eq!(
            con_session_set_audio_capture(s, audio_capture_c.as_ptr()),
            CON_OK
        );
        assert_eq!(
            con_session_set_audio_capture(s, capture_c.as_ptr()),
            CON_ERR_IO
        );
        assert_eq!(
            con_session_set_audio_capture(std::ptr::null_mut(), audio_capture_c.as_ptr()),
            CON_ERR_INVALID_ARGUMENT
        );
        assert_eq!(
            con_session_set_reference_repair(s, CON_MISSING_REFERENCE_REPAIR_SHOW),
            CON_OK
        );
        assert_eq!(
            con_session_set_reference_repair(s, CON_MISSING_REFERENCE_WITHHOLD),
            CON_OK
        );
        assert_eq!(
            con_session_set_reference_repair(s, CON_MISSING_REFERENCE_REPAIR_HIDE),
            CON_OK
        );
        assert_eq!(
            con_session_set_reference_repair(std::ptr::null_mut(), 1),
            CON_ERR_INVALID_ARGUMENT
        );

        assert!(wait(20_000, || seen.connected.load(Ordering::SeqCst)));
        assert_eq!(
            con_session_set_video_capture(s, not_capture_c.as_ptr()),
            CON_ERR_IO
        );
        assert_eq!(
            con_session_set_video_capture(std::ptr::null_mut(), capture_c.as_ptr()),
            CON_ERR_INVALID_ARGUMENT
        );
        let mut st = ConStats::default();
        assert_eq!(con_session_stats(s, &mut st), CON_OK);
        let (mut withheld, mut periods) = (99u64, 99u64);
        assert_eq!(
            con_session_video_withheld(s, &mut withheld, &mut periods),
            CON_OK
        );
        assert_eq!((withheld, periods), (0, 0));
        assert_eq!(
            con_session_video_withheld(s, std::ptr::null_mut(), std::ptr::null_mut()),
            CON_OK
        );
        assert_eq!(
            con_session_video_withheld(std::ptr::null_mut(), &mut withheld, std::ptr::null_mut()),
            CON_ERR_INVALID_ARGUMENT
        );
        let (mut hidden, mut runs) = (99u64, 99u64);
        assert_eq!(con_session_video_hidden(s, &mut hidden, &mut runs), CON_OK);
        assert_eq!((hidden, runs), (0, 0));
        assert_eq!(
            con_session_video_hidden(s, std::ptr::null_mut(), std::ptr::null_mut()),
            CON_OK
        );
        assert_eq!(
            con_session_video_hidden(std::ptr::null_mut(), &mut hidden, std::ptr::null_mut()),
            CON_ERR_INVALID_ARGUMENT
        );
        let mut pad: ConControllerState = std::mem::zeroed();
        assert_eq!(con_controller_state_idle(&mut pad), CON_OK);
        assert_eq!(
            (pad.orientation[3], pad.accel[1], pad.touches[0].id),
            (1.0, 1.0, -1)
        );
        pad.buttons = CON_BUTTON_CROSS;
        pad.left_x = 12_000;
        assert_eq!(con_session_set_controller_state(s, &pad), CON_OK);
        assert_eq!(con_session_go_home(s), CON_OK);
        assert_eq!(con_session_microphone_connect(s), CON_OK);
        let mic: Vec<i16> = (0..960).map(|i| ((i % 48) * 400 - 9600) as i16).collect();
        assert_eq!(
            con_session_send_microphone_pcm(s, mic.as_ptr(), 960),
            CON_OK
        );
        assert_eq!(
            con_session_send_microphone_pcm(s, mic.as_ptr(), 100),
            CON_ERR_INVALID_ARGUMENT
        );

        assert!(wait(15_000, || seen.video_pictures.load(Ordering::SeqCst) >= 2));
        assert!(wait(15_000, || seen.audio_decoded.load(Ordering::SeqCst) >= 10));
        assert!(wait(15_000, || seen.haptics_frames.load(Ordering::SeqCst) >= 1));
        assert!(wait(15_000, || seen.rumble.lock().unwrap().is_some()));
        assert!(wait(15_000, || seen.triggers_seen.load(Ordering::SeqCst)));
        assert!(wait(15_000, || seen.stats_events.load(Ordering::SeqCst) >= 2));
        assert!(wait(30_000, || seen.quit_seen.load(Ordering::SeqCst)));

        assert_eq!(con_session_stats(s, &mut st), CON_ERR_NOT_READY);
        assert_eq!(con_session_request_keyframe(s), CON_ERR_NOT_READY);
        assert_eq!(
            con_session_video_withheld(s, &mut withheld, &mut periods),
            CON_ERR_NOT_READY
        );
        assert_eq!(
            con_session_video_hidden(s, &mut hidden, &mut runs),
            CON_ERR_NOT_READY
        );
        assert!(wait(2_000, || con_session_is_finished(s) == 1));
        assert_eq!(con_session_set_video_capture(s, std::ptr::null()), CON_OK);
        assert_eq!(con_session_set_audio_capture(s, std::ptr::null()), CON_OK);
        seen.session.store(std::ptr::null_mut(), Ordering::SeqCst);
        con_session_free(s);
        assert_eq!(con_set_thread_callback(None, std::ptr::null_mut()), CON_OK);
    }

    let seen_stream = fake.join().unwrap();
    let types = control.join().unwrap();
    assert_eq!(std::fs::read(&not_capture).unwrap(), b"some other file");
    let _ = std::fs::remove_file(&not_capture);
    let file = std::fs::read(&capture).unwrap();
    let _ = std::fs::remove_file(&capture);
    assert_eq!(&file[..16], &capture::file_header());
    let mut records = Vec::new();
    let mut at = 16;
    while at < file.len() {
        let h = capture::RecordHeader::decode(&file[at..]).unwrap();
        let data = file[at + 32..at + 32 + h.length as usize].to_vec();
        at += 32 + h.length as usize;
        records.push((h, data));
    }
    assert_eq!(at, file.len());
    let kinds: Vec<(u8, u16)> = records
        .iter()
        .map(|(h, _)| (h.kind, h.frame_index))
        .collect();
    assert_eq!(kinds, vec![(3, 0), (0, 1), (1, 1), (1, 2), (1, 3)]);
    assert!(records
        .iter()
        .enumerate()
        .all(|(i, (h, _))| h.sequence == i as u32));
    assert_eq!(records[1].1, h26x::build_h265_parameter_sets(8));
    assert_eq!(
        (records[1].0.width, records[1].0.height, records[1].0.codec),
        (1920, 1080, 1)
    );
    for (i, (h, data)) in records[2..].iter().enumerate() {
        let frame = i as u16 + 1;
        assert_eq!(
            *data,
            h265_picture(frame, frame == 1, if frame == 1 { &[] } else { &[true] })
        );
        let key = if frame == 1 {
            capture::flag::KEYFRAME
        } else {
            0
        };
        assert_eq!(h.flags, key | capture::flag::ACCEPTED);
    }
    assert!(records.windows(2).all(|w| w[0].0.time_us <= w[1].0.time_us));
    let file = std::fs::read(&audio_capture).unwrap();
    let _ = std::fs::remove_file(&audio_capture);
    assert_eq!(&file[..16], &capture::audio_file_header());
    let mut audio = Vec::new();
    let mut at = 16;
    while at < file.len() {
        let h = capture::AudioRecordHeader::decode(&file[at..]).unwrap();
        let start = at + capture::AUDIO_RECORD_HEADER_LEN;
        audio.push((h, file[start..start + h.length as usize].to_vec()));
        at = start + h.length as usize;
    }
    assert_eq!(at, file.len());
    use capture::{audio_flag, audio_kind};
    assert_eq!(audio[0].0.kind, audio_kind::START);
    assert_eq!(audio[1].0.kind, audio_kind::HEADER);
    assert_eq!(audio[1].1, AUDIO_HEADER);
    assert_eq!(audio[1].0.flags, audio_flag::DECODED);
    let datagrams: Vec<_> = audio
        .iter()
        .filter(|(h, _)| h.kind == audio_kind::DATAGRAM)
        .collect();
    assert!(datagrams
        .iter()
        .any(|(h, _)| h.flags & audio_flag::HAPTICS != 0));
    for (h, d) in &datagrams {
        assert_eq!(d[0] & 0x0f, 3, "audio datagram");
        assert!(usize::from(h.payload_offset) < d.len());
    }
    let frames: Vec<_> = audio
        .iter()
        .filter(|(h, _)| h.kind == audio_kind::FRAME)
        .collect();
    assert!(frames.len() >= 10);
    assert!(frames.iter().any(|(h, d)| h.flags == audio_flag::DECODED
        && h.peak > 1000
        && h.rms > 100
        && (h.samples, h.channels) == (480, 2)
        && usize::from(h.packet_len) == d.len()));
    assert!(audio
        .iter()
        .enumerate()
        .all(|(i, (h, _))| h.sequence == i as u32));
    let roles = THREADS.roles.load(Ordering::SeqCst);
    for r in [
        CON_THREAD_IO,
        CON_THREAD_SENDER,
        CON_THREAD_SESSION,
        CON_THREAD_CONTROL,
        CON_THREAD_STATISTICS,
        CON_THREAD_CAPTURE,
    ] {
        assert!(roles & (1 << r) != 0, "role {r} missing: {roles:#x}");
    }
    if cfg!(target_os = "macos") {
        assert_eq!(THREADS.interactive.load(Ordering::SeqCst), CON_OK);
    }
    assert_eq!(
        seen.stream_info.lock().unwrap().clone().unwrap(),
        format!(
            "profiles=1 first=1920x1080 header={} audio=2/48000/480 afk=600",
            h26x::build_h265_parameter_sets(8).len()
        )
    );
    assert_eq!(seen.video_params.load(Ordering::SeqCst), 1);
    assert_eq!(seen.video_pictures.load(Ordering::SeqCst), 3);
    assert!(!seen.video_padding_bad.load(Ordering::SeqCst));
    assert!(seen.keyframe_from_callback.load(Ordering::SeqCst));
    assert_eq!(seen.video_decode_only.load(Ordering::SeqCst), 0);
    assert_eq!(seen.video_bad_flags.load(Ordering::SeqCst), 0);
    assert_eq!(seen.haptics_frames.load(Ordering::SeqCst), 3);
    assert_eq!(*seen.rumble.lock().unwrap(), Some((192, 32)));
    assert!(seen.triggers_seen.load(Ordering::SeqCst));
    assert!(seen.light_seen.load(Ordering::SeqCst));
    assert!(seen.player_seen.load(Ordering::SeqCst));
    assert!(seen.intensity_seen.load(Ordering::SeqCst));
    assert!(seen.log_lines.load(Ordering::SeqCst) > 0);
    assert_eq!(seen.events_after_quit.load(Ordering::SeqCst), 0);
    assert_eq!(
        seen.quit_line(),
        "11 stream: remote shut down is_error=0 text=Server shutting down stage=7 streaming"
    );
    let seen = seen_stream;
    assert_eq!(seen.session_key, SID);
    assert!(seen.idr >= 1);
    assert!(seen.cross_pressed);
    assert!(seen.states >= 1);
    assert_eq!(seen.tag_failures, 0);
    assert_eq!(seen.disconnect.as_deref(), Some("Client Disconnecting"));
    assert!(types.contains(&0x0014), "go home: {types:x?}");
    assert!(types.contains(&0x0030), "microphone connect: {types:x?}");
}

#[test]
fn c_abi_runs_a_cloud_session() {
    let _threads = engine_threads();
    let mut s = FakeServer::bind();
    s.prefix = 1;
    let port = s.addr().port();
    let fake = std::thread::spawn(move || {
        let mut seen = StreamSeen::default();
        let profile = Resolution {
            width: 1280,
            height: 720,
            video_header: vec![0, 0, 0, 1, 0x67, 0x42],
        };
        stream_setup(
            &mut s,
            9,
            Some(0x7000),
            Some([0x5a; 16]),
            None,
            profile,
            &mut seen,
        );
        stream_collect(
            &mut s,
            &mut seen,
            Instant::now() + Duration::from_secs(30),
            |_| false,
        );
        seen
    });

    let seen: &'static EventsSeen = leak();
    unsafe {
        let mut cfg: ConCloudConfig = std::mem::zeroed();
        assert_eq!(con_cloud_config_default(&mut cfg), CON_OK);
        let address = cstr("127.0.0.1");
        let session_id = cstr("CLOUD-SESSION");
        let launch_spec = cstr("LAUNCH-SPEC-TEXT");
        cfg.address = address.as_ptr();
        cfg.port = port;
        cfg.prefix = 1;
        cfg.ps5 = 0;
        cfg.session_id = session_id.as_ptr();
        cfg.launch_spec = launch_spec.as_ptr();
        cfg.codec = CON_CODEC_H264;
        cfg.handshake_key = [0x5a; 16];
        assert_eq!(cfg.rtt_us, 0);
        cfg.rtt_us = 23_000;
        let mut h: *mut ConSession = std::ptr::null_mut();
        assert_eq!(
            con_session_start_cloud(&cfg, std::ptr::null(), None, user(seen), &mut h),
            CON_ERR_INVALID_ARGUMENT
        );
        assert_eq!(
            con_session_start_cloud(&cfg, std::ptr::null(), Some(on_event), user(seen), &mut h),
            CON_OK
        );
        seen.session.store(h, Ordering::SeqCst);
        assert!(wait(20_000, || seen.connected.load(Ordering::SeqCst)));
        assert_eq!(con_session_request_keyframe(h), CON_OK);
        assert_eq!(con_session_report_corrupt_frames(h, 3, 5), CON_OK);
        assert_eq!(con_session_go_home(h), CON_ERR_NOT_READY);
        let pin = cstr("1234");
        assert_eq!(con_session_submit_pin(h, pin.as_ptr()), CON_ERR_NOT_READY);
        std::thread::sleep(Duration::from_millis(300));
        seen.free_in_quit.store(true, Ordering::SeqCst);
        con_session_stop(h);
    }
    assert!(wait(15_000, || seen.quit_seen.load(Ordering::SeqCst)));
    assert!(wait(1_000, || seen
        .freed_in_callback
        .load(Ordering::SeqCst)));
    std::thread::sleep(Duration::from_millis(500));
    assert_eq!(
        seen.quit_line(),
        "0 stopped is_error=0 text=(none) stage=7 streaming"
    );
    assert_eq!(seen.events_after_quit.load(Ordering::SeqCst), 0);

    let seen = fake.join().unwrap();
    assert_eq!(seen.session_key, "CLOUD-SESSION");
    assert_eq!(seen.launch_spec_len, "LAUNCH-SPEC-TEXT".len());
    assert_eq!(seen.idr, 1);
    assert_eq!(seen.corrupt, vec![(3, 5)]);
    assert_eq!(seen.disconnect.as_deref(), Some("Client Disconnecting"));
    assert_eq!(seen.tag_failures, 0);
}

#[derive(Default)]
struct ProbeSeen {
    done: AtomicBool,
    result: Mutex<Option<ConCloudProbeResult>>,
}

unsafe extern "C" fn on_probe(user: *mut c_void, r: *const ConCloudProbeResult) {
    let seen: &ProbeSeen = state(user);
    *seen.result.lock().unwrap() = Some(*r);
    seen.done.store(true, Ordering::SeqCst);
}

fn probe_line(r: &ConCloudProbeResult) -> String {
    let error = unsafe { CStr::from_ptr(r.error_text.as_ptr()) }.to_string_lossy();
    format!(
        "status={} stage={} samples={} rtt={} mtu_in={} mtu_out={} echoed={} error={error}",
        r.status,
        r.stage,
        r.rtt_samples,
        if r.rtt_us > 0 { "yes" } else { "no" },
        r.mtu_in,
        r.mtu_out,
        r.hello_echoed
    )
}

#[test]
fn c_abi_probes_a_data_centre() {
    let _threads = engine_threads();
    let (addr, fake) = common::senkusha::fake(
        common::senkusha::Behaviour {
            cloud: true,
            answer_mtu: true,
            mtu_in_limit: 1400,
            mtu_out_limit: 1300,
            shift_pong: true,
            ..Default::default()
        },
        1,
    );
    let silent = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    let silent_port = silent.local_addr().unwrap().port();
    unsafe {
        let mut c: ConCloudProbeConfig = std::mem::zeroed();
        assert_eq!(con_cloud_probe_config_default(&mut c), CON_OK);
        assert_eq!(
            (
                c.connect_timeout_ms,
                c.pings,
                c.mtu_attempts,
                c.mtu_wait_min_ms,
                c.mtu_wait_max_ms,
                c.measure_mtu
            ),
            (8000, 5, 2, 200, 1000, 1)
        );
        let local = cstr("127.0.0.1");
        let credential = cstr("CREDENTIAL-1234");
        c.address = local.as_ptr();
        c.port = addr.port();
        c.prefix = 1;
        c.credential = credential.as_ptr();
        let seen: &'static ProbeSeen = leak();
        let mut p: *mut ConCloudProbe = std::ptr::null_mut();
        assert_eq!(
            con_cloud_probe_start(&c, Some(on_probe), user(seen), &mut p),
            CON_OK
        );
        assert!(!p.is_null());
        assert!(wait(60_000, || seen.done.load(Ordering::SeqCst)));
        con_cloud_probe_free(p);
        assert_eq!(
            probe_line(&seen.result.lock().unwrap().unwrap()),
            "status=0 stage=6 samples=5 rtt=yes mtu_in=1400 mtu_out=1300 echoed=1 error="
        );

        let mut r: ConCloudProbeResult = std::mem::zeroed();
        c.port = silent_port;
        c.connect_timeout_ms = 300;
        assert_eq!(con_cloud_probe_run(&c, &mut r), CON_OK);
        assert!(
            probe_line(&r).starts_with("status=3 stage=1 samples=0"),
            "{}",
            probe_line(&r)
        );

        let seen: &'static ProbeSeen = leak();
        c.connect_timeout_ms = 10_000;
        assert_eq!(
            con_cloud_probe_start(&c, Some(on_probe), user(seen), &mut p),
            CON_OK
        );
        std::thread::sleep(Duration::from_millis(150));
        con_cloud_probe_cancel(p);
        assert!(wait(3_000, || seen.done.load(Ordering::SeqCst)));
        con_cloud_probe_free(p);
        let line = probe_line(&seen.result.lock().unwrap().unwrap());
        assert!(line.starts_with("status=1 stage=1"), "{line}");

        let unknown = cstr("no-such-host.invalid");
        c.address = unknown.as_ptr();
        assert_eq!(con_cloud_probe_run(&c, &mut r), CON_OK);
        assert!(
            probe_line(&r).starts_with("status=2 stage=1"),
            "{}",
            probe_line(&r)
        );

        c.address = local.as_ptr();
        c.port = 0;
        assert_eq!(con_cloud_probe_run(&c, &mut r), CON_ERR_INVALID_ARGUMENT);
        c.port = silent_port;
        c.credential = std::ptr::null();
        p = std::ptr::dangling_mut::<ConCloudProbe>();
        assert_eq!(
            con_cloud_probe_start(&c, Some(on_probe), user(seen), &mut p),
            CON_ERR_INVALID_ARGUMENT
        );
        assert!(p.is_null());
        con_cloud_probe_free(std::ptr::null_mut());
    }
    let seen = fake.join().unwrap();
    assert_eq!(seen.hello_session_key.as_deref(), Some("CREDENTIAL-1234"));
    assert_eq!(seen.protocol_requests, 0);
    assert_eq!(seen.disconnect.as_deref(), Some("Client Disconnecting"));
}

#[test]
fn c_abi_self_test() {
    let _threads = engine_threads();
    let checks = selftest();
    assert!(
        checks.failures.is_empty(),
        "{:#?}\n{:#?}",
        checks.failures,
        checks.lines
    );
    assert_eq!(
        checks.lines[0],
        format!(
            "version {} abi {}",
            env!("CARGO_PKG_VERSION"),
            CON_ENGINE_ABI_VERSION
        )
    );
    assert!(
        checks
            .lines
            .iter()
            .any(|l| l.ends_with("stage=1 session request")),
        "{:?}",
        checks.lines
    );
}

#[test]
fn c_abi_rejects_bad_input() {
    let _threads = engine_threads();
    let null_s: *mut ConSession = std::ptr::null_mut();
    let bad_utf8 = [0xffu8, 0xfe, 0];
    let bad = bad_utf8.as_ptr() as *const c_char;
    let local = cstr("127.0.0.1");
    let seen: &'static EventsSeen = leak();
    let ev: ConEventCallback = Some(on_event);
    const E: i32 = CON_ERR_INVALID_ARGUMENT;
    unsafe {
        assert_eq!(con_discovery_config_default(std::ptr::null_mut()), E);
        assert_eq!(con_registration_request_default(std::ptr::null_mut()), E);
        assert_eq!(con_console_config_default(std::ptr::null_mut()), E);
        assert_eq!(con_cloud_config_default(std::ptr::null_mut()), E);
        assert_eq!(con_session_options_default(std::ptr::null_mut()), E);
        assert_eq!(con_controller_state_idle(std::ptr::null_mut()), E);
        assert_eq!(con_cloud_probe_config_default(std::ptr::null_mut()), E);

        assert_eq!(
            con_discovery_start(
                std::ptr::null(),
                Some(on_hosts),
                std::ptr::null_mut(),
                std::ptr::null_mut()
            ),
            E
        );
        let mut dc: ConDiscoveryConfig = std::mem::zeroed();
        con_discovery_config_default(&mut dc);
        dc.bind_address = bad;
        let mut d: *mut ConDiscovery = std::ptr::null_mut();
        assert_eq!(
            con_discovery_start(&dc, Some(on_hosts), user(leak::<HostsSeen>()), &mut d),
            E
        );
        dc.bind_address = local.as_ptr();
        dc.extra_destination_count = 3;
        assert_eq!(
            con_discovery_start(&dc, Some(on_hosts), user(leak::<HostsSeen>()), &mut d),
            E
        );
        assert!(d.is_null());
        assert_eq!(
            con_discovery_wake(
                std::ptr::null_mut(),
                local.as_ptr(),
                CON_CONSOLE_PS5,
                KEY_TEXT.as_ptr()
            ),
            E
        );
        assert_eq!(
            con_wake(std::ptr::null(), 1, CON_CONSOLE_PS5, KEY_TEXT.as_ptr()),
            E
        );
        assert_eq!(con_wake(bad, 1, CON_CONSOLE_PS5, KEY_TEXT.as_ptr()), E);
        assert_eq!(con_wake(local.as_ptr(), 1, 2, KEY_TEXT.as_ptr()), E);
        assert_eq!(
            con_wake(local.as_ptr(), 1, CON_CONSOLE_PS5, std::ptr::null()),
            E
        );
        con_discovery_stop(std::ptr::null_mut());

        let mut rq: ConRegistrationRequest = std::mem::zeroed();
        con_registration_request_default(&mut rq);
        let pin = cstr("12345678");
        rq.pin = pin.as_ptr();
        let rs = user(leak::<RegistSeen>());
        let mut r: *mut ConRegistration = std::ptr::null_mut();
        assert_eq!(
            con_registration_start(&rq, Some(on_registration), rs, &mut r),
            E,
            "no host"
        );
        rq.host = bad;
        assert_eq!(
            con_registration_start(&rq, Some(on_registration), rs, &mut r),
            E,
            "not UTF-8"
        );
        rq.host = local.as_ptr();
        rq.target = CON_TARGET_UNKNOWN;
        assert_eq!(
            con_registration_start(&rq, Some(on_registration), rs, &mut r),
            E,
            "target"
        );
        rq.target = CON_TARGET_PS5_1;
        assert_eq!(
            con_registration_start(&rq, None, rs, &mut r),
            E,
            "no callback"
        );
        assert_eq!(
            con_registration_start(&rq, Some(on_registration), rs, std::ptr::null_mut()),
            E
        );
        assert!(r.is_null());
        con_registration_cancel(std::ptr::null_mut());
        con_registration_free(std::ptr::null_mut());

        let mut cc: ConConsoleConfig = std::mem::zeroed();
        con_console_config_default(&mut cc);
        let mut s: *mut ConSession = std::ptr::null_mut();
        assert_eq!(
            con_session_start_console(&cc, std::ptr::null(), ev, user(seen), &mut s),
            E,
            "no host"
        );
        cc.host = bad;
        assert_eq!(
            con_session_start_console(&cc, std::ptr::null(), ev, user(seen), &mut s),
            E,
            "not UTF-8"
        );
        cc.host = local.as_ptr();
        cc.kind = 2;
        assert_eq!(
            con_session_start_console(&cc, std::ptr::null(), ev, user(seen), &mut s),
            E,
            "kind"
        );
        cc.kind = CON_CONSOLE_PS5;
        cc.codec = 3;
        assert_eq!(
            con_session_start_console(&cc, std::ptr::null(), ev, user(seen), &mut s),
            E,
            "codec"
        );
        cc.codec = CON_CODEC_H264;
        assert_eq!(
            con_session_start_console(&cc, std::ptr::null(), None, user(seen), &mut s),
            E
        );
        assert_eq!(
            con_session_start_console(&cc, std::ptr::null(), ev, user(seen), std::ptr::null_mut()),
            E
        );
        let mut opt: ConSessionOptions = std::mem::zeroed();
        con_session_options_default(&mut opt);
        opt.video_capture_path = bad;
        assert_eq!(
            con_session_start_console(&cc, &opt, ev, user(seen), &mut s),
            E,
            "capture path"
        );
        assert!(s.is_null());

        let mut cl: ConCloudConfig = std::mem::zeroed();
        con_cloud_config_default(&mut cl);
        let id = cstr("ID");
        let spec = cstr("SPEC");
        let long_id = cstr(&"x".repeat(128));
        cl.address = local.as_ptr();
        cl.session_id = id.as_ptr();
        cl.launch_spec = spec.as_ptr();
        assert_eq!(
            con_session_start_cloud(&cl, std::ptr::null(), ev, user(seen), &mut s),
            E,
            "port 0"
        );
        cl.port = 1;
        cl.session_id = long_id.as_ptr();
        assert_eq!(
            con_session_start_cloud(&cl, std::ptr::null(), ev, user(seen), &mut s),
            E,
            "id too long"
        );
        cl.session_id = id.as_ptr();
        cl.launch_spec = std::ptr::null();
        assert_eq!(
            con_session_start_cloud(&cl, std::ptr::null(), ev, user(seen), &mut s),
            E,
            "no launch spec"
        );
        cl.launch_spec = spec.as_ptr();
        cl.codec = 7;
        assert_eq!(
            con_session_start_cloud(&cl, std::ptr::null(), ev, user(seen), &mut s),
            E,
            "codec"
        );
        assert!(s.is_null());

        let mut st = ConStats::default();
        let mut pad: ConControllerState = std::mem::zeroed();
        con_controller_state_idle(&mut pad);
        let mic = [0i16; 480];
        let (mut a, mut b) = (0u64, 0u64);
        assert_eq!(con_session_is_finished(null_s), E);
        assert_eq!(con_session_submit_pin(null_s, pin.as_ptr()), E);
        assert_eq!(con_session_keyboard_set_text(null_s, pin.as_ptr()), E);
        assert_eq!(con_session_keyboard_accept(null_s), E);
        assert_eq!(con_session_keyboard_cancel(null_s), E);
        assert_eq!(con_session_sleep(null_s), E);
        assert_eq!(con_session_go_home(null_s), E);
        assert_eq!(con_session_microphone_connect(null_s), E);
        assert_eq!(con_session_set_microphone_muted(null_s, 1), E);
        assert_eq!(
            con_session_send_microphone_pcm(null_s, mic.as_ptr(), 480),
            E
        );
        assert_eq!(
            con_session_send_microphone_pcm(null_s, std::ptr::null(), 480),
            E
        );
        assert_eq!(con_session_send_microphone_pcm(null_s, mic.as_ptr(), 0), E);
        assert_eq!(con_session_set_controller_state(null_s, &pad), E);
        assert_eq!(con_session_request_keyframe(null_s), E);
        assert_eq!(con_session_report_corrupt_frames(null_s, 1, 2), E);
        assert_eq!(con_session_stats(null_s, &mut st), E);
        assert_eq!(con_session_set_video_capture(null_s, std::ptr::null()), E);
        assert_eq!(con_session_set_audio_capture(null_s, std::ptr::null()), E);
        assert_eq!(
            con_session_set_reference_repair(null_s, CON_MISSING_REFERENCE_REPAIR_HIDE),
            E
        );
        assert_eq!(con_session_video_hidden(null_s, &mut a, &mut b), E);
        assert_eq!(con_session_video_withheld(null_s, &mut a, &mut b), E);
        con_session_stop(null_s);
        con_session_free(null_s);

        cc.session_port = 1;
        assert_eq!(
            con_session_start_console(&cc, std::ptr::null(), ev, user(seen), &mut s),
            CON_OK
        );
        assert_eq!(con_session_submit_pin(s, std::ptr::null()), E);
        assert_eq!(con_session_submit_pin(s, bad), E);
        assert_eq!(con_session_keyboard_set_text(s, bad), E);
        assert_eq!(con_session_set_controller_state(s, std::ptr::null()), E);
        assert_eq!(con_session_stats(s, std::ptr::null_mut()), E);
        assert_eq!(con_session_set_video_capture(s, bad), E);
        assert_eq!(con_session_set_audio_capture(s, bad), E);
        con_session_free(s);

        let mut pc: ConCloudProbeConfig = std::mem::zeroed();
        con_cloud_probe_config_default(&mut pc);
        let mut pr: ConCloudProbeResult = std::mem::zeroed();
        assert_eq!(con_cloud_probe_run(std::ptr::null(), &mut pr), E);
        pc.address = local.as_ptr();
        pc.credential = pin.as_ptr();
        pc.port = 1;
        assert_eq!(con_cloud_probe_run(&pc, std::ptr::null_mut()), E);
        pc.address = bad;
        assert_eq!(con_cloud_probe_run(&pc, &mut pr), E);
        let mut p: *mut ConCloudProbe = std::ptr::null_mut();
        assert_eq!(
            con_cloud_probe_start(&pc, None, std::ptr::null_mut(), &mut p),
            E
        );
        assert!(p.is_null());
        con_cloud_probe_cancel(std::ptr::null_mut());
        con_cloud_probe_free(std::ptr::null_mut());

        assert_eq!(
            text(con_quit_reason_name(u32::MAX)).as_deref(),
            Some("unknown")
        );
        assert_eq!(text(con_stage_name(u32::MAX)).as_deref(), Some("unknown"));
    }
}
