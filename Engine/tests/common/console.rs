use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpListener, TcpStream};
use std::time::Duration;

use base64::Engine as _;
use con_engine::crypto::rp::RpCipher;
use con_engine::session::messages::{
    decode_frame_header, encode_frame_header, msg_type, BURST_CLOSER_PAYLOAD, FRAME_HEADER_LEN,
    GO_HOME_PAYLOAD, MIC_CONNECT_PAYLOAD,
};

pub const REGIST: [u8; 16] = [
    0x61, 0x31, 0x62, 0x32, 0x63, 0x33, 0x64, 0x34, 0, 0, 0, 0, 0, 0, 0, 0,
];
pub const RP_KEY: [u8; 16] = [
    0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00,
];
pub const NONCE: [u8; 16] = [
    0x9c, 0x3e, 0x51, 0x07, 0xc2, 0x88, 0x1d, 0xf4, 0x6b, 0x20, 0xe7, 0x93, 0x4a, 0x0d, 0xb6, 0x75,
];
pub const SID: &str = "AbCdEfGhIjKlMnOpQrStUvWxYz012345";

pub fn b64(b: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(b)
}

pub fn listener() -> (TcpListener, SocketAddr) {
    let l = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    let a = l.local_addr().unwrap();
    (l, a)
}

pub fn read_header(s: &mut TcpStream) -> (String, Vec<u8>) {
    let mut data = Vec::new();
    let mut chunk = [0u8; 1024];
    loop {
        let n = s.read(&mut chunk).unwrap();
        assert!(n > 0, "client closed");
        data.extend_from_slice(&chunk[..n]);
        if let Some(p) = data.windows(4).position(|w| w == b"\r\n\r\n") {
            let rest = data.split_off(p + 4);
            return (String::from_utf8(data).unwrap(), rest);
        }
    }
}

pub fn answer_session_request(l: &TcpListener, version: &str) {
    let (mut s, _) = l.accept().unwrap();
    s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let _ = read_header(&mut s);
    let resp = format!(
        "HTTP/1.1 200 OK\r\nRP-Nonce: {}\r\nRP-Version: {version}\r\n\r\n",
        b64(&NONCE)
    );
    s.write_all(resp.as_bytes()).unwrap();
}

fn fixed_payload(ty: u16) -> Option<&'static [u8]> {
    match ty {
        msg_type::BURST_CLOSER => Some(&BURST_CLOSER_PAYLOAD),
        msg_type::GO_HOME => Some(&GO_HOME_PAYLOAD),
        msg_type::MIC_CONNECT => Some(&MIC_CONNECT_PAYLOAD),
        _ => None,
    }
}

pub fn take_frame(
    buf: &mut Vec<u8>,
    cipher: &RpCipher,
    counter: &mut u64,
) -> Option<(u16, Vec<u8>)> {
    if buf.len() < FRAME_HEADER_LEN {
        return None;
    }
    let h: [u8; FRAME_HEADER_LEN] = buf[..FRAME_HEADER_LEN].try_into().unwrap();
    let (len, ty) = decode_frame_header(&h);
    let end = FRAME_HEADER_LEN + len as usize;
    if buf.len() < end {
        return None;
    }
    let mut p = buf[FRAME_HEADER_LEN..end].to_vec();
    buf.drain(..end);
    if !p.is_empty() {
        cipher.decrypt(*counter, &mut p);
        *counter += 1;
    }
    Some((ty, p))
}

pub fn serve_control(
    l: &TcpListener,
    cipher: RpCipher,
    server_type: u8,
    client_counter: u64,
) -> Vec<u16> {
    let (mut s, _) = l.accept().unwrap();
    s.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
    let (_, mut buf) = read_header(&mut s);
    let mut v = [0u8; 16];
    v[0] = server_type;
    let resp = format!(
        "HTTP/1.1 200 OK\r\nRP-Server-Type: {}\r\n\r\n",
        b64(&cipher.encrypted(0, &v))
    );
    s.write_all(resp.as_bytes()).unwrap();
    let mut from_client = client_counter;
    let mut sid = vec![0x4a];
    sid.extend_from_slice(SID.as_bytes());
    cipher.encrypt(1, &mut sid);
    let mut out = encode_frame_header(sid.len() as u32, msg_type::SESSION_ID).to_vec();
    out.extend_from_slice(&sid);
    s.write_all(&out).unwrap();
    let mut types = Vec::new();
    let mut chunk = [0u8; 1024];
    loop {
        while let Some((ty, p)) = take_frame(&mut buf, &cipher, &mut from_client) {
            if let Some(expected) = fixed_payload(ty) {
                assert_eq!(p, expected, "payload of {ty:#06x}");
            }
            types.push(ty);
        }
        match s.read(&mut chunk) {
            Ok(0) | Err(_) => return types,
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
        }
    }
}
