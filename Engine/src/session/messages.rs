use std::sync::OnceLock;
use std::time::Instant;

use base64::Engine as _;

use crate::crypto::random_bytes;

pub mod msg_type {
    pub const SCREEN_GUARD: u16 = 0x0001;
    pub const LOGIN_PIN_REQUEST: u16 = 0x0004;
    pub const LOGIN_RESULT: u16 = 0x0005;
    pub const KEYBOARD_ENABLE: u16 = 0x000d;
    pub const DUALSENSE_INFO: u16 = 0x0011;
    pub const DUALSENSE_ENABLE: u16 = 0x0013;
    pub const GO_HOME: u16 = 0x0014;
    pub const SCREEN_BLACKOUT: u16 = 0x0016;
    pub const KEYBOARD_ENABLE_TOGGLE: u16 = 0x0020;
    pub const KEYBOARD_OPENED: u16 = 0x0021;
    pub const KEYBOARD_CLOSED_REMOTELY: u16 = 0x0022;
    pub const KEYBOARD_SET_TEXT: u16 = 0x0023;
    pub const KEYBOARD_TEXT_CHANGED: u16 = 0x0024;
    pub const KEYBOARD_CLOSE: u16 = 0x0025;
    pub const MIC_CONNECT: u16 = 0x0030;
    pub const SESSION_ID: u16 = 0x0033;
    pub const MIC_MUTE: u16 = 0x0036;
    pub const SLEEP: u16 = 0x0050;
    pub const HEARTBEAT_REQUEST: u16 = 0x00fe;
    pub const HEARTBEAT_REPLY: u16 = 0x01fe;
    pub const BURST_CLOSER: u16 = 0x0910;
    pub const LOGIN_PIN: u16 = 0x8004;
}

pub const KEYBOARD_ENABLE_PAYLOAD: [u8; 16] = [
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x05, 0xae, 0, 0, 0, 0, 0, 0, 0, 0,
];
pub const DUALSENSE_INFO_PAYLOAD: [u8; 16] = [
    0xa0, 0xab, 0x51, 0xbd, 0xd1, 0x7e, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00,
];
pub const DUALSENSE_ENABLE_PAYLOAD: [u8; 3] = [0x00, 0x40, 0x00];
pub const GO_HOME_PAYLOAD: [u8; 16] = [0x00, 0xff, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
pub const KEYBOARD_TOGGLE_PAYLOAD: [u8; 1] = [0x01];
pub const MIC_CONNECT_PAYLOAD: [u8; 2] = [0x00, 0x00];
pub const BURST_CLOSER_PAYLOAD: [u8; 4] = [0x00, 0x00, 0x00, 0x00];

pub const FRAME_HEADER_LEN: usize = 8;

pub fn encode_frame_header(payload_len: u32, msg_type: u16) -> [u8; FRAME_HEADER_LEN] {
    let mut h = [0u8; FRAME_HEADER_LEN];
    h[..4].copy_from_slice(&payload_len.to_be_bytes());
    h[4..6].copy_from_slice(&msg_type.to_be_bytes());
    h
}

pub fn decode_frame_header(h: &[u8; FRAME_HEADER_LEN]) -> (u32, u16) {
    (
        u32::from_be_bytes([h[0], h[1], h[2], h[3]]),
        u16::from_be_bytes([h[4], h[5]]),
    )
}

pub fn mic_mute_payload(muted: bool) -> [u8; 4] {
    [0x00, 0x01, if muted { 0x00 } else { 0x01 }, 0x59]
}

pub fn keyboard_close_payload(accept: bool) -> [u8; 4] {
    [0, 0, 0, if accept { 0 } else { 1 }]
}

pub fn keyboard_set_text_payload(counter: u32, text: &str) -> Vec<u8> {
    let t = text.as_bytes();
    let len = t.len() as u32;
    let mut p = Vec::with_capacity(36 + t.len());
    p.extend_from_slice(&counter.to_be_bytes());
    p.extend_from_slice(&len.to_be_bytes());
    p.extend_from_slice(&[0u8; 24]);
    p.extend_from_slice(&len.to_be_bytes());
    p.extend_from_slice(t);
    p
}

pub fn parse_keyboard_opened(payload: &[u8]) -> Option<String> {
    if payload.len() < 32 {
        return None;
    }
    let t = u32::from_be_bytes([payload[28], payload[29], payload[30], payload[31]]) as usize;
    let end = 32usize.saturating_add(t).min(payload.len());
    Some(String::from_utf8_lossy(&payload[32..end]).into_owned())
}

pub fn parse_keyboard_text_changed(payload: &[u8]) -> Option<(u32, String)> {
    if payload.len() < 40 {
        return None;
    }
    let counter = u32::from_be_bytes([payload[0], payload[1], payload[2], payload[3]]);
    let t = u32::from_be_bytes([payload[8], payload[9], payload[10], payload[11]]) as usize;
    let end = 40usize.saturating_add(t).min(payload.len());
    Some((
        counter,
        String::from_utf8_lossy(&payload[40..end]).into_owned(),
    ))
}

pub const SESSION_ID_MIN: usize = 24;
pub const SESSION_ID_MAX: usize = 126;

pub fn parse_session_id(payload: &[u8]) -> Option<String> {
    if payload.len() < 2 {
        return None;
    }
    let id = &payload[1..];
    if id.len() < SESSION_ID_MIN || id.len() > SESSION_ID_MAX {
        return None;
    }
    if !id.iter().all(u8::is_ascii_alphanumeric) {
        return None;
    }
    Some(String::from_utf8_lossy(id).into_owned())
}

pub fn fallback_session_id() -> String {
    static ORIGIN: OnceLock<Instant> = OnceLock::new();
    let secs = ORIGIN.get_or_init(Instant::now).elapsed().as_secs();
    let rnd: [u8; 48] = random_bytes();
    format!(
        "{secs}{}",
        base64::engine::general_purpose::STANDARD.encode(rnd)
    )
}

pub fn new_device_id() -> [u8; 32] {
    let mut d = [0u8; 32];
    d[..10].copy_from_slice(&[0x00, 0x18, 0x00, 0x00, 0x00, 0x07, 0x00, 0x40, 0x00, 0x80]);
    d[10..26].copy_from_slice(&random_bytes::<16>());
    d
}

pub fn feature_burst(dualsense: bool, keyboard: bool) -> Vec<(u16, Vec<u8>)> {
    let mut out = Vec::new();
    if dualsense {
        out.push((
            msg_type::DUALSENSE_ENABLE,
            DUALSENSE_ENABLE_PAYLOAD.to_vec(),
        ));
        out.push((msg_type::DUALSENSE_INFO, DUALSENSE_INFO_PAYLOAD.to_vec()));
    }
    if keyboard {
        out.push((msg_type::KEYBOARD_ENABLE, KEYBOARD_ENABLE_PAYLOAD.to_vec()));
        out.push((
            msg_type::KEYBOARD_ENABLE_TOGGLE,
            KEYBOARD_TOGGLE_PAYLOAD.to_vec(),
        ));
    }
    out.push((msg_type::MIC_MUTE, mic_mute_payload(false).to_vec()));
    out.push((msg_type::MIC_MUTE, mic_mute_payload(false).to_vec()));
    out.push((msg_type::BURST_CLOSER, BURST_CLOSER_PAYLOAD.to_vec()));
    out
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ScreenGuard {
    armed: bool,
    blacked_out: bool,
}

impl ScreenGuard {
    pub fn on_guard(&mut self, payload: &[u8]) -> Option<bool> {
        match payload.first() {
            Some(0x01) => {
                self.armed = true;
                None
            }
            Some(0x00) if !self.blacked_out => {
                self.armed = false;
                Some(false)
            }
            _ => None,
        }
    }

    pub fn on_blackout(&mut self, payload: &[u8]) -> Option<bool> {
        if payload.len() < 2 {
            return None;
        }
        let ends_blackout = payload[0] == 0x01 && payload[1] == 0xff;
        if self.armed && !self.blacked_out && !ends_blackout {
            self.blacked_out = true;
            Some(true)
        } else if self.blacked_out && ends_blackout {
            self.blacked_out = false;
            None
        } else {
            None
        }
    }
}
