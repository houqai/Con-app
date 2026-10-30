pub mod packet_type {
    pub const CONTROL: u8 = 0;
    pub const FEEDBACK_HISTORY: u8 = 1;
    pub const VIDEO: u8 = 2;
    pub const AUDIO: u8 = 3;
    pub const CONGESTION: u8 = 5;
    pub const FEEDBACK_STATE: u8 = 6;
}

pub mod chunk_type {
    pub const DATA: u8 = 0x00;
    pub const INIT: u8 = 0x01;
    pub const INIT_ACK: u8 = 0x02;
    pub const DATA_ACK: u8 = 0x03;
    pub const COOKIE_ECHO: u8 = 0x0a;
    pub const COOKIE_ACK: u8 = 0x0b;
}

pub mod data_type {
    pub const PROTOBUF: u8 = 0;
    pub const RUMBLE: u8 = 7;
    pub const PAD_INFO: u8 = 9;
    pub const TRIGGER_EFFECTS: u8 = 11;
}

pub const RECEIVER_WINDOW: u32 = 0x0001_9000;
pub const OUTBOUND_STREAMS: u16 = 100;
pub const INBOUND_STREAMS: u16 = 100;

pub const CONTROL_HEADER_LEN: usize = 17;
const CHUNK_OFFSET: usize = 13;
pub const FLAG_LAST_FRAGMENT: u8 = 0x01;
pub const DATA_FIRST_HEADER: usize = 9;
pub const DATA_CONT_HEADER: usize = 8;
pub const DATA_ACK_LEN: usize = 29;
pub const CONGESTION_LEN: usize = 15;
pub const FEEDBACK_HEADER_LEN: usize = 12;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TagLayout {
    pub gmac: usize,
    pub key_pos: usize,
    pub zero_key_pos: bool,
}

impl TagLayout {
    pub fn min_len(&self) -> usize {
        self.gmac.max(self.key_pos) + 4
    }
}

pub fn tag_layout(packet_type: u8) -> Option<TagLayout> {
    match packet_type {
        packet_type::CONTROL => Some(TagLayout {
            gmac: 5,
            key_pos: 9,
            zero_key_pos: true,
        }),
        packet_type::VIDEO | packet_type::AUDIO => Some(TagLayout {
            gmac: 10,
            key_pos: 14,
            zero_key_pos: false,
        }),
        packet_type::CONGESTION => Some(TagLayout {
            gmac: 7,
            key_pos: 11,
            zero_key_pos: true,
        }),
        packet_type::FEEDBACK_HISTORY | packet_type::FEEDBACK_STATE => Some(TagLayout {
            gmac: 8,
            key_pos: 4,
            zero_key_pos: false,
        }),
        _ => None,
    }
}

pub fn be16(d: &[u8], at: usize) -> u16 {
    u16::from_be_bytes([d[at], d[at + 1]])
}

pub fn be32(d: &[u8], at: usize) -> u32 {
    u32::from_be_bytes([d[at], d[at + 1], d[at + 2], d[at + 3]])
}

pub fn encode_control(tag: u32, chunk: u8, flags: u8, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(CONTROL_HEADER_LEN + payload.len());
    out.push(packet_type::CONTROL);
    out.extend_from_slice(&tag.to_be_bytes());
    out.extend_from_slice(&[0; 8]);
    out.push(chunk);
    out.push(flags);
    out.extend_from_slice(&((payload.len() + 4) as u16).to_be_bytes());
    out.extend_from_slice(payload);
    out
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ControlPacket<'a> {
    pub tag: u32,
    pub chunk: u8,
    pub flags: u8,
    pub payload: &'a [u8],
}

pub fn parse_control(d: &[u8]) -> Option<ControlPacket<'_>> {
    if d.len() < CONTROL_HEADER_LEN || d[0] & 0x0f != packet_type::CONTROL {
        return None;
    }
    let chunk_len = usize::from(be16(d, CHUNK_OFFSET + 2));
    if CHUNK_OFFSET + chunk_len != d.len() {
        return None;
    }
    Some(ControlPacket {
        tag: be32(d, 1),
        chunk: d[CHUNK_OFFSET],
        flags: d[CHUNK_OFFSET + 1],
        payload: &d[CONTROL_HEADER_LEN..],
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Init {
    pub tag: u32,
    pub window: u32,
    pub outbound_streams: u16,
    pub inbound_streams: u16,
    pub initial_tsn: u32,
}

impl Init {
    pub fn client(tag: u32) -> Self {
        Self {
            tag,
            window: RECEIVER_WINDOW,
            outbound_streams: OUTBOUND_STREAMS,
            inbound_streams: INBOUND_STREAMS,
            initial_tsn: tag,
        }
    }

    pub fn payload(&self) -> [u8; 16] {
        let mut p = [0u8; 16];
        p[0..4].copy_from_slice(&self.tag.to_be_bytes());
        p[4..8].copy_from_slice(&self.window.to_be_bytes());
        p[8..10].copy_from_slice(&self.outbound_streams.to_be_bytes());
        p[10..12].copy_from_slice(&self.inbound_streams.to_be_bytes());
        p[12..16].copy_from_slice(&self.initial_tsn.to_be_bytes());
        p
    }

    pub fn packet(&self) -> Vec<u8> {
        encode_control(0, chunk_type::INIT, 0, &self.payload())
    }

    pub fn parse(p: &[u8]) -> Option<Self> {
        if p.len() < 16 {
            return None;
        }
        Some(Self {
            tag: be32(p, 0),
            window: be32(p, 4),
            outbound_streams: be16(p, 8),
            inbound_streams: be16(p, 10),
            initial_tsn: be32(p, 12),
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InitAck {
    pub init: Init,
    pub cookie: [u8; 32],
}

impl InitAck {
    pub fn payload(&self) -> [u8; 48] {
        let mut p = [0u8; 48];
        p[..16].copy_from_slice(&self.init.payload());
        p[16..].copy_from_slice(&self.cookie);
        p
    }

    pub fn packet(&self, client_tag: u32) -> Vec<u8> {
        encode_control(client_tag, chunk_type::INIT_ACK, 0, &self.payload())
    }

    pub fn parse(p: &[u8]) -> Option<Self> {
        if p.len() < 48 {
            return None;
        }
        Some(Self {
            init: Init::parse(p)?,
            cookie: p[16..48].try_into().expect("32 bytes"),
        })
    }

    pub fn acceptable(&self) -> bool {
        self.init.tag != 0
            && (1..=INBOUND_STREAMS).contains(&self.init.outbound_streams)
            && self.init.inbound_streams >= OUTBOUND_STREAMS
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DataAck {
    pub cumulative_tsn: u32,
    pub window: u32,
    pub gap_blocks: u16,
    pub duplicates: u16,
}

impl DataAck {
    pub fn client(tsn: u32) -> Self {
        Self {
            cumulative_tsn: tsn,
            window: RECEIVER_WINDOW,
            gap_blocks: 0,
            duplicates: 0,
        }
    }

    pub fn payload(&self) -> [u8; 12] {
        let mut p = [0u8; 12];
        p[0..4].copy_from_slice(&self.cumulative_tsn.to_be_bytes());
        p[4..8].copy_from_slice(&self.window.to_be_bytes());
        p[8..10].copy_from_slice(&self.gap_blocks.to_be_bytes());
        p[10..12].copy_from_slice(&self.duplicates.to_be_bytes());
        p
    }

    pub fn packet(&self, peer_tag: u32) -> Vec<u8> {
        encode_control(peer_tag, chunk_type::DATA_ACK, 0, &self.payload())
    }

    pub fn parse(p: &[u8]) -> Option<Self> {
        if p.len() != 12 {
            return None;
        }
        let ack = Self {
            cumulative_tsn: be32(p, 0),
            window: be32(p, 4),
            gap_blocks: be16(p, 8),
            duplicates: be16(p, 10),
        };
        (ack.gap_blocks == 0).then_some(ack)
    }
}

pub fn encode_data_payload(tsn: u32, channel: u16, data_type: Option<u8>, data: &[u8]) -> Vec<u8> {
    let mut p = Vec::with_capacity(DATA_FIRST_HEADER + data.len());
    p.extend_from_slice(&tsn.to_be_bytes());
    p.extend_from_slice(&channel.to_be_bytes());
    p.extend_from_slice(&[0, 0]);
    if let Some(t) = data_type {
        p.push(t);
    }
    p.extend_from_slice(data);
    p
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DataHeader {
    pub tsn: u32,
    pub channel: u16,
}

pub fn parse_data_header(p: &[u8]) -> Option<DataHeader> {
    if p.len() < DATA_CONT_HEADER {
        return None;
    }
    Some(DataHeader {
        tsn: be32(p, 0),
        channel: be16(p, 4),
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MediaKind {
    Video,
    Audio,
    Haptics,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UnitWord {
    Video {
        unit_index: u16,
        units_total: u16,
        fec_units: u16,
    },
    Audio {
        unit_index: u8,
        units_total: u16,
        unit_size: u8,
        fec_units: u8,
        source_units: u8,
    },
}

impl UnitWord {
    pub fn video(w: u32) -> Self {
        UnitWord::Video {
            unit_index: (w >> 21) as u16,
            units_total: ((w >> 10) & 0x7ff) as u16 + 1,
            fec_units: (w & 0x3ff) as u16,
        }
    }

    pub fn audio(w: u32) -> Self {
        UnitWord::Audio {
            unit_index: (w >> 24) as u8,
            units_total: ((w >> 16) & 0xff) as u16 + 1,
            unit_size: (w >> 8) as u8,
            fec_units: ((w >> 4) & 0xf) as u8,
            source_units: (w & 0xf) as u8,
        }
    }

    pub fn unit_index(&self) -> u16 {
        match *self {
            UnitWord::Video { unit_index, .. } => unit_index,
            UnitWord::Audio { unit_index, .. } => u16::from(unit_index),
        }
    }
}

pub fn video_unit_word(unit_index: u16, units_total: u16, fec_units: u16) -> u32 {
    (u32::from(unit_index & 0x7ff) << 21)
        | (u32::from(units_total.wrapping_sub(1) & 0x7ff) << 10)
        | u32::from(fec_units & 0x3ff)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MediaHeader {
    pub kind: MediaKind,
    pub extended: bool,
    pub packet_index: u16,
    pub frame_index: u16,
    pub unit_word_raw: u32,
    pub unit_word: UnitWord,
    pub codec: u8,
    pub gmac: [u8; 4],
    pub key_pos: u32,
    pub adaptive_stream: Option<u8>,
    pub stream_marker: Option<u8>,
    pub payload_offset: usize,
}

pub fn parse_media(d: &[u8], version: u32) -> Option<MediaHeader> {
    let ty = *d.first()? & 0x0f;
    if ty != packet_type::VIDEO && ty != packet_type::AUDIO {
        return None;
    }
    if d.len() < 18 {
        return None;
    }
    let extended = d[0] & 0x10 != 0;
    let ext = if extended { 3 } else { 0 };
    let raw = be32(d, 5);
    let mut kind = if ty == packet_type::VIDEO {
        MediaKind::Video
    } else {
        MediaKind::Audio
    };
    let mut adaptive_stream = None;
    let mut stream_marker = None;
    let payload_offset = match (kind, version) {
        (MediaKind::Video, 7) => 21 + ext,
        (MediaKind::Video, _) => {
            if d.len() < 25 {
                return None;
            }
            adaptive_stream = Some(d[20] >> 5);
            21 + ext
        }
        (_, 7) => 18 + ext,
        (_, 12) => {
            if d.len() < 21 {
                return None;
            }
            let marker_at = 19 + ext;
            let marker = *d.get(marker_at)?;
            stream_marker = Some(marker);
            if marker == 0x02 {
                kind = MediaKind::Haptics;
            }
            marker_at + 1
        }
        _ => {
            if d.len() < 20 {
                return None;
            }
            19 + ext
        }
    };
    if d.len() < payload_offset {
        return None;
    }
    let unit_word = if version == 7 || kind == MediaKind::Video {
        UnitWord::video(raw)
    } else {
        UnitWord::audio(raw)
    };
    Some(MediaHeader {
        kind,
        extended,
        packet_index: be16(d, 1),
        frame_index: be16(d, 3),
        unit_word_raw: raw,
        unit_word,
        codec: d[9],
        gmac: d[10..14].try_into().expect("4 bytes"),
        key_pos: be32(d, 14),
        adaptive_stream,
        stream_marker,
        payload_offset,
    })
}

pub const MIC_UNIT_WORD: u32 = 0x0002_2821;
pub const MIC_CODEC: u8 = 5;

pub fn encode_microphone(counter: u16, ps5: bool, payload: &[u8]) -> Vec<u8> {
    let offset = microphone_payload_offset(ps5);
    let mut out = Vec::with_capacity(offset + payload.len());
    out.push(packet_type::AUDIO);
    out.extend_from_slice(&counter.to_be_bytes());
    out.extend_from_slice(&counter.wrapping_add(1).to_be_bytes());
    out.extend_from_slice(&MIC_UNIT_WORD.to_be_bytes());
    out.push(MIC_CODEC);
    out.resize(offset, 0);
    out.extend_from_slice(payload);
    out
}

pub fn microphone_payload_offset(ps5: bool) -> usize {
    if ps5 {
        20
    } else {
        19
    }
}

pub fn encode_congestion(received: u16, lost: u16) -> [u8; CONGESTION_LEN] {
    let mut p = [0u8; CONGESTION_LEN];
    p[0] = packet_type::CONGESTION;
    p[3..5].copy_from_slice(&received.to_be_bytes());
    p[5..7].copy_from_slice(&lost.to_be_bytes());
    p
}

pub fn parse_congestion(d: &[u8]) -> Option<(u16, u16)> {
    (d.len() == CONGESTION_LEN && d[0] == packet_type::CONGESTION).then(|| (be16(d, 3), be16(d, 5)))
}

pub fn encode_feedback(ty: u8, seq: u16, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(FEEDBACK_HEADER_LEN + payload.len());
    out.push(ty);
    out.extend_from_slice(&seq.to_be_bytes());
    out.push(0);
    out.extend_from_slice(&[0; 8]);
    out.extend_from_slice(payload);
    out
}

pub fn encode_probe(
    len: usize,
    frame_index: u16,
    unit_index: u16,
    tag: u32,
    filler: &[u8],
) -> Vec<u8> {
    let len = len.max(26);
    let mut out = vec![0u8; len];
    out[0] = packet_type::AUDIO;
    out[3..5].copy_from_slice(&frame_index.to_be_bytes());
    let word = video_unit_word(unit_index, 0x800, 0);
    out[5..9].copy_from_slice(&word.to_be_bytes());
    out[9] = 0xff;
    out[22..26].copy_from_slice(&tag.to_be_bytes());
    if !filler.is_empty() {
        for (i, b) in out[26..].iter_mut().enumerate() {
            *b = filler[i % filler.len()];
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handshake_packet_sizes() {
        let init = Init::client(0x1234_5678);
        let p = init.packet();
        assert_eq!(p.len(), 33);
        assert_eq!(&p[13..17], &[0x01, 0x00, 0x00, 0x14]);
        let ack = InitAck {
            init: Init::client(7),
            cookie: [9; 32],
        };
        assert_eq!(ack.packet(0x1234_5678).len(), 65);
        assert_eq!(
            encode_control(1, chunk_type::COOKIE_ECHO, 0, &[0; 32]).len(),
            49
        );
        assert_eq!(encode_control(1, chunk_type::COOKIE_ACK, 0, &[]).len(), 17);
        assert_eq!(DataAck::client(5).packet(1).len(), DATA_ACK_LEN);
    }
}
