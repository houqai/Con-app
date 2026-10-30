use std::ffi::{c_char, c_void};

pub const CON_ENGINE_ABI_VERSION: u32 = 2u32;

pub const CON_OK: i32 = 0;
pub const CON_ERR_INVALID_ARGUMENT: i32 = -1;
pub const CON_ERR_NOT_READY: i32 = -2;
pub const CON_ERR_IO: i32 = -3;
pub const CON_ERR_UNSUPPORTED: i32 = -4;
pub const CON_ERR_BAD_CREDENTIAL: i32 = -5;
pub const CON_ERR_SEND_FAILED: i32 = -6;
pub const CON_ERR_PANIC: i32 = -99;

pub const CON_CONSOLE_PS4: u32 = 0u32;
pub const CON_CONSOLE_PS5: u32 = 1u32;

pub const CON_TARGET_UNKNOWN: u32 = 0u32;
pub const CON_TARGET_PS4_8: u32 = 1u32;
pub const CON_TARGET_PS4_9: u32 = 2u32;
pub const CON_TARGET_PS4_10: u32 = 3u32;
pub const CON_TARGET_PS5_1: u32 = 4u32;

pub const CON_CODEC_H264: u32 = 0u32;
pub const CON_CODEC_H265: u32 = 1u32;
pub const CON_CODEC_H265_HDR: u32 = 2u32;

pub const CON_CONSOLE_STATE_READY: u32 = 0u32;
pub const CON_CONSOLE_STATE_STANDBY: u32 = 1u32;
pub const CON_CONSOLE_STATE_UNKNOWN: u32 = 2u32;

pub const CON_LOG_NONE: i32 = -1;
pub const CON_LOG_ERROR: i32 = 0;
pub const CON_LOG_WARNING: i32 = 1;
pub const CON_LOG_INFO: i32 = 2;
pub const CON_LOG_DEBUG: i32 = 3;

pub const CON_QUIT_STOPPED: u32 = 0u32;
pub const CON_QUIT_SESSION_REQUEST_UNKNOWN: u32 = 1u32;
pub const CON_QUIT_SESSION_REQUEST_CONNECTION_REFUSED: u32 = 2u32;
pub const CON_QUIT_SESSION_REQUEST_IN_USE: u32 = 3u32;
pub const CON_QUIT_SESSION_REQUEST_CRASHED: u32 = 4u32;
pub const CON_QUIT_SESSION_REQUEST_VERSION_MISMATCH: u32 = 5u32;
pub const CON_QUIT_CONTROL_UNKNOWN: u32 = 6u32;
pub const CON_QUIT_CONTROL_CONNECT_FAILED: u32 = 7u32;
pub const CON_QUIT_CONTROL_CONNECTION_REFUSED: u32 = 8u32;
pub const CON_QUIT_STREAM_UNKNOWN: u32 = 9u32;
pub const CON_QUIT_STREAM_REMOTE_DISCONNECTED: u32 = 10u32;
pub const CON_QUIT_STREAM_REMOTE_SHUTDOWN: u32 = 11u32;
pub const CON_QUIT_PSN_REGISTRATION_FAILED: u32 = 12u32;

pub const CON_STAGE_UNKNOWN: u32 = 0u32;
pub const CON_STAGE_SESSION_REQUEST: u32 = 1u32;
pub const CON_STAGE_CONTROL: u32 = 2u32;
pub const CON_STAGE_NETWORK_TEST: u32 = 3u32;
pub const CON_STAGE_TRANSPORT: u32 = 4u32;
pub const CON_STAGE_KEY_EXCHANGE: u32 = 5u32;
pub const CON_STAGE_STREAM_INFO: u32 = 6u32;
pub const CON_STAGE_STREAMING: u32 = 7u32;

pub const CON_THREAD_IO: u32 = 1u32;
pub const CON_THREAD_SENDER: u32 = 2u32;
pub const CON_THREAD_SESSION: u32 = 3u32;
pub const CON_THREAD_CONTROL: u32 = 4u32;
pub const CON_THREAD_STATISTICS: u32 = 5u32;
pub const CON_THREAD_DISCOVERY: u32 = 6u32;
pub const CON_THREAD_REGISTRATION: u32 = 7u32;
pub const CON_THREAD_PROBE: u32 = 8u32;
pub const CON_THREAD_CAPTURE: u32 = 9u32;
pub const CON_THREAD_HELPER: u32 = 10u32;

pub const CON_BUTTON_CROSS: u32 = 1u32 << 0;
pub const CON_BUTTON_CIRCLE: u32 = 1u32 << 1;
pub const CON_BUTTON_SQUARE: u32 = 1u32 << 2;
pub const CON_BUTTON_TRIANGLE: u32 = 1u32 << 3;
pub const CON_BUTTON_LEFT: u32 = 1u32 << 4;
pub const CON_BUTTON_RIGHT: u32 = 1u32 << 5;
pub const CON_BUTTON_UP: u32 = 1u32 << 6;
pub const CON_BUTTON_DOWN: u32 = 1u32 << 7;
pub const CON_BUTTON_L1: u32 = 1u32 << 8;
pub const CON_BUTTON_R1: u32 = 1u32 << 9;
pub const CON_BUTTON_L3: u32 = 1u32 << 10;
pub const CON_BUTTON_R3: u32 = 1u32 << 11;
pub const CON_BUTTON_OPTIONS: u32 = 1u32 << 12;
pub const CON_BUTTON_SHARE: u32 = 1u32 << 13;
pub const CON_BUTTON_TOUCHPAD: u32 = 1u32 << 14;
pub const CON_BUTTON_PS: u32 = 1u32 << 15;

pub const CON_REGIST_OK: u32 = 0u32;
pub const CON_REGIST_CANCELLED: u32 = 1u32;
pub const CON_REGIST_INVALID_PIN: u32 = 2u32;
pub const CON_REGIST_ACCOUNT_ID_REQUIRED: u32 = 3u32;
pub const CON_REGIST_NO_PROBE_REPLY: u32 = 4u32;
pub const CON_REGIST_CONNECT_FAILED: u32 = 5u32;
pub const CON_REGIST_NETWORK: u32 = 6u32;
pub const CON_REGIST_REJECTED: u32 = 7u32;
pub const CON_REGIST_INVALID_RESPONSE: u32 = 8u32;
pub const CON_REGIST_HOST_NOT_FOUND: u32 = 9u32;
pub const CON_REGIST_INTERNAL: u32 = 10u32;

pub const CON_EVENT_LOG: u32 = 1u32;
pub const CON_EVENT_PIN_REQUESTED: u32 = 2u32;
pub const CON_EVENT_KEYBOARD_OPENED: u32 = 3u32;
pub const CON_EVENT_KEYBOARD_TEXT_CHANGED: u32 = 4u32;
pub const CON_EVENT_KEYBOARD_CLOSED: u32 = 5u32;
pub const CON_EVENT_CANNOT_DISPLAY: u32 = 6u32;
pub const CON_EVENT_NETWORK_TEST: u32 = 7u32;
pub const CON_EVENT_STREAM_INFO: u32 = 8u32;
pub const CON_EVENT_CONNECTED: u32 = 9u32;
pub const CON_EVENT_CONNECTION_QUALITY: u32 = 10u32;
pub const CON_EVENT_SERVER_CORRUPT_FRAME: u32 = 11u32;
pub const CON_EVENT_CLOUD_PRELUDE: u32 = 12u32;
pub const CON_EVENT_VIDEO: u32 = 13u32;
pub const CON_EVENT_AUDIO: u32 = 14u32;
pub const CON_EVENT_HAPTICS: u32 = 15u32;
pub const CON_EVENT_RUMBLE: u32 = 16u32;
pub const CON_EVENT_TRIGGER_EFFECTS: u32 = 17u32;
pub const CON_EVENT_LIGHT_BAR: u32 = 18u32;
pub const CON_EVENT_PLAYER_INDEX: u32 = 19u32;
pub const CON_EVENT_EFFECT_INTENSITY: u32 = 20u32;
pub const CON_EVENT_MOTION_RESET: u32 = 21u32;
pub const CON_EVENT_FEC_FAILURE: u32 = 22u32;
pub const CON_EVENT_STATS: u32 = 23u32;
pub const CON_EVENT_QUIT: u32 = 24u32;

pub const CON_VIDEO_PARAMETER_SETS: u32 = 0u32;
pub const CON_VIDEO_PICTURE: u32 = 1u32;

pub const CON_VIDEO_FLAG_DECODE_ONLY: u32 = 0x01u32;

pub const CON_INTENSITY_HAPTIC: u32 = 0u32;
pub const CON_INTENSITY_TRIGGER: u32 = 1u32;

pub const CON_MISSING_REFERENCE_WITHHOLD: i32 = 0;
pub const CON_MISSING_REFERENCE_REPAIR_SHOW: i32 = 1;
pub const CON_MISSING_REFERENCE_REPAIR_HIDE: i32 = 2;

pub const CON_PROBE_OK: u32 = 0u32;
pub const CON_PROBE_CANCELLED: u32 = 1u32;
pub const CON_PROBE_HOST_NOT_FOUND: u32 = 2u32;
pub const CON_PROBE_NO_CONNECTION: u32 = 3u32;
pub const CON_PROBE_NO_RTT: u32 = 4u32;
pub const CON_PROBE_NETWORK: u32 = 5u32;
pub const CON_PROBE_INTERNAL: u32 = 6u32;

pub const CON_PROBE_STAGE_CONNECT: u32 = 1u32;
pub const CON_PROBE_STAGE_HELLO: u32 = 2u32;
pub const CON_PROBE_STAGE_RTT: u32 = 3u32;
pub const CON_PROBE_STAGE_MTU_IN: u32 = 4u32;
pub const CON_PROBE_STAGE_MTU_OUT: u32 = 5u32;
pub const CON_PROBE_STAGE_DONE: u32 = 6u32;

pub type ConThreadCallback =
    Option<unsafe extern "C" fn(user: *mut c_void, role: u32, name: *const c_char)>;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConDiscoveryConfig {
    pub bind_address: *const c_char,
    pub destination: *const c_char,
    pub extra_destinations: *const *const c_char,
    pub extra_destination_count: usize,
    pub initial_delay_ms: u32,
    pub period_ms: u32,
    pub drop_after_rounds: u32,
    pub max_consoles: u32,
    pub ps4_port: u16,
    pub ps5_port: u16,
    pub local_port_first: u16,
    pub local_port_last: u16,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConDiscoveredHost {
    pub address: *const c_char,
    pub host_id: *const c_char,
    pub host_name: *const c_char,
    pub host_type: *const c_char,
    pub system_version: *const c_char,
    pub protocol_version: *const c_char,
    pub running_app_title_id: *const c_char,
    pub running_app_name: *const c_char,
    pub state: u32,
    pub kind: u32,
    pub generation: u32,
    pub target: u32,
    pub status: u16,
    pub request_port: u16,
}

pub type ConHostsCallback =
    Option<unsafe extern "C" fn(user: *mut c_void, hosts: *const ConDiscoveredHost, count: usize)>;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConRegistrationRequest {
    pub host: *const c_char,
    pub pin: *const c_char,
    pub online_id: *const c_char,
    pub target: u32,
    pub probe_timeout_ms: u32,
    pub io_timeout_ms: u32,
    pub port: u16,
    pub account_id: [u8; 8],
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConRegistrationResult {
    pub error_text: *const c_char,
    pub nickname: *const c_char,
    pub ap_ssid: *const c_char,
    pub ap_bssid: *const c_char,
    pub ap_key: *const c_char,
    pub ap_name: *const c_char,
    pub key_type: u64,
    pub support_cmd: u64,
    pub status: u32,
    pub target: u32,
    pub http_status: u32,
    pub app_reason: u32,
    pub regist_key: [u8; 16],
    pub rp_key: [u8; 16],
    pub mac: [u8; 6],
    pub has_key_type: u8,
    pub has_support_cmd: u8,
}

pub type ConRegistrationCallback =
    Option<unsafe extern "C" fn(user: *mut c_void, result: *const ConRegistrationResult)>;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConConsoleConfig {
    pub host: *const c_char,
    pub kind: u32,
    pub codec: u32,
    pub video_height: u32,
    pub max_fps: u32,
    pub bitrate_kbps: u32,
    pub session_port: u16,
    pub network_test_port: u16,
    pub stream_port: u16,
    pub auto_downgrade: u8,
    pub video_disabled: u8,
    pub keyboard: u8,
    pub network_test: u8,
    pub regist_key: [u8; 16],
    pub rp_key: [u8; 16],
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConCloudConfig {
    pub address: *const c_char,
    pub session_id: *const c_char,
    pub launch_spec: *const c_char,
    pub codec: u32,
    pub max_fps: u32,
    pub mtu_in: u32,
    pub mtu_out: u32,
    pub rtt_us: u32,
    pub port: u16,
    pub prefix: u8,
    pub ps5: u8,
    pub handshake_key: [u8; 16],
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConSessionOptions {
    pub loss_ceiling: f64,
    pub video_capture_path: *const c_char,
    pub dualsense: i32,
    pub log_level: i32,
    pub stats_interval_ms: u32,
    pub discard_video: u8,
    pub discard_audio: u8,
    pub idr_on_fec_failure: u8,
    pub decode_audio: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConLogEvent {
    pub text: *const c_char,
    pub level: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConPinEvent {
    pub previous_wrong: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConKeyboardEvent {
    pub text: *const c_char,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConDisplayEvent {
    pub cannot_display: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConNetworkTestEvent {
    pub rtt_us: u64,
    pub rtt_samples: u32,
    pub mtu_in: u32,
    pub mtu_out: u32,
    pub fallback: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConVideoProfile {
    pub header: *const u8,
    pub header_size: usize,
    pub width: u32,
    pub height: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConStreamInfoEvent {
    pub profiles: *const ConVideoProfile,
    pub profile_count: usize,
    pub start_timeout: i64,
    pub afk_timeout: i64,
    pub afk_disconnect_timeout: i64,
    pub congestion_control_interval: i64,
    pub audio_rate: u32,
    pub audio_frame_size: u32,
    pub audio_channels: u8,
    pub audio_bits: u8,
    pub audio_header: [u8; 14],
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConConnectionQualityEvent {
    pub upstream_loss: f64,
    pub rtt: f64,
    pub target_bitrate: i64,
    pub upstream_bitrate: i64,
    pub loss: i64,
    pub disable_upstream_audio: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConCorruptFrameEvent {
    pub start: u32,
    pub end: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConCloudPreludeEvent {
    pub size: usize,
    pub msg_type: u32,
    pub has_stream_info: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConVideoEvent {
    pub data: *const u8,
    pub size: usize,
    pub padded_size: usize,
    pub frames_lost: u32,
    pub codec: u32,
    pub width: u32,
    pub height: u32,
    pub kind: u32,
    pub frame_index: u16,
    pub profile: u8,
    pub recovered: u8,
    pub fec_recovered: u8,
    pub keyframe: u8,
    pub accepted: u8,
    pub flags: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConAudioEvent {
    pub pcm: *const i16,
    pub pcm_count: usize,
    pub opus: *const u8,
    pub opus_size: usize,
    pub samples_per_channel: usize,
    pub sample_rate: u32,
    pub frame_index: u16,
    pub channels: u8,
    pub decoded: u8,
    pub concealed: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConHapticsEvent {
    pub pcm: *const u8,
    pub size: usize,
    pub sample_rate: u32,
    pub frame_index: u16,
    pub channels: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConRumbleEvent {
    pub left: u8,
    pub right: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConTriggerEffectsEvent {
    pub left: [u8; 11],
    pub right: [u8; 11],
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConLightBarEvent {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConPlayerIndexEvent {
    pub index: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConEffectIntensityEvent {
    pub kind: u32,
    pub value: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConFecFailureEvent {
    pub frame_index: u16,
    pub idr_requested: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ConStats {
    pub rtt_latest_us: u64,
    pub rtt_median_us: u64,
    pub rtt_samples: u64,
    pub datagrams_sent: u64,
    pub datagrams_received: u64,
    pub retransmissions: u64,
    pub given_up: u64,
    pub tag_failures: u64,
    pub dropped: u64,
    pub held_media_dropped: u64,
    pub messages_delivered: u64,
    pub media_delivered: u64,
    pub congestion_reports: u64,
    pub report_received: u64,
    pub report_lost: u64,
    pub video_packets: u64,
    pub video_packets_dropped: u64,
    pub video_units_received: u64,
    pub video_units_rejected: u64,
    pub video_units_late: u64,
    pub video_profile_switches: u64,
    pub video_frames_complete: u64,
    pub video_frames_fec_recovered: u64,
    pub video_frames_fec_failed: u64,
    pub video_frames_failed: u64,
    pub video_frames_delivered: u64,
    pub video_frames_rejected: u64,
    pub video_frames_skipped_waiting_idr: u64,
    pub video_frames_reference_missing: u64,
    pub video_frames_reference_repaired: u64,
    pub video_frames_unchecked: u64,
    pub video_frames_lost: u64,
    pub video_corrupt_reports: u64,
    pub video_idr_requests: u64,
    pub video_bytes_delivered: u64,
    pub audio_datagrams: u64,
    pub audio_datagrams_dropped: u64,
    pub audio_frames_offered: u64,
    pub audio_frames_discarded: u64,
    pub audio_frames_played: u64,
    pub audio_frames_concealed: u64,
    pub audio_decode_errors: u64,
    pub haptics_datagrams: u64,
    pub haptics_frames: u64,
    pub haptics_dropped: u64,
    pub feedback_state_sent: u64,
    pub feedback_history_sent: u64,
    pub feedback_history_dropped: u64,
    pub feedback_refreshes: u64,
    pub measured_bitrate: u64,
    pub running_bitrate: u64,
    pub audio_decoded: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConStatsEvent {
    pub stats: *const ConStats,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConQuitEvent {
    pub text: *const c_char,
    pub reason: u32,
    pub stage: u32,
    pub is_error: u8,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub union ConEventData {
    pub log: ConLogEvent,
    pub pin: ConPinEvent,
    pub keyboard: ConKeyboardEvent,
    pub display: ConDisplayEvent,
    pub network_test: ConNetworkTestEvent,
    pub stream_info: ConStreamInfoEvent,
    pub connection_quality: ConConnectionQualityEvent,
    pub corrupt_frame: ConCorruptFrameEvent,
    pub cloud_prelude: ConCloudPreludeEvent,
    pub video: ConVideoEvent,
    pub audio: ConAudioEvent,
    pub haptics: ConHapticsEvent,
    pub rumble: ConRumbleEvent,
    pub trigger_effects: ConTriggerEffectsEvent,
    pub light_bar: ConLightBarEvent,
    pub player_index: ConPlayerIndexEvent,
    pub effect_intensity: ConEffectIntensityEvent,
    pub fec_failure: ConFecFailureEvent,
    pub stats: ConStatsEvent,
    pub quit: ConQuitEvent,
}

/// cbindgen:field-names=[type, data]
#[repr(C)]
#[derive(Clone, Copy)]
pub struct ConEvent {
    pub type_: u32,
    pub data: ConEventData,
}

pub type ConEventCallback = Option<unsafe extern "C" fn(user: *mut c_void, event: *mut ConEvent)>;

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ConTouch {
    pub id: i16,
    pub x: u16,
    pub y: u16,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ConControllerState {
    pub buttons: u32,
    pub left_x: i16,
    pub left_y: i16,
    pub right_x: i16,
    pub right_y: i16,
    pub touches: [ConTouch; 2],
    pub gyro: [f32; 3],
    pub accel: [f32; 3],
    pub orientation: [f32; 4],
    pub l2: u8,
    pub r2: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConCloudProbeConfig {
    pub address: *const c_char,
    pub credential: *const c_char,
    pub connect_timeout_ms: u32,
    pub hello_echo_ms: u32,
    pub pings: u32,
    pub pong_timeout_ms: u32,
    pub mtu_attempts: u32,
    pub mtu_wait_min_ms: u32,
    pub mtu_wait_max_ms: u32,
    pub client_mtu_reply_ms: u32,
    pub port: u16,
    pub prefix: u8,
    pub measure_mtu: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ConCloudProbeResult {
    pub rtt_us: u64,
    pub rtt_samples: u32,
    pub mtu_in: u32,
    pub mtu_out: u32,
    pub status: u32,
    pub stage: u32,
    pub hello_echoed: u8,
    pub error_text: [c_char; 128],
}

pub type ConCloudProbeCallback =
    Option<unsafe extern "C" fn(user: *mut c_void, result: *const ConCloudProbeResult)>;
