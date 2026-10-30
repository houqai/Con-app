use con_engine::fec;
use con_engine::transport::packet::video_unit_word;

#[allow(clippy::too_many_arguments)]
pub fn video_datagram(
    packet_index: u16,
    frame_index: u16,
    unit: u16,
    total: u16,
    fec_units: u16,
    adaptive_stream: u8,
    extended: bool,
    payload: &[u8],
) -> Vec<u8> {
    let mut d = vec![if extended { 0x12 } else { 0x02 }];
    d.extend_from_slice(&packet_index.to_be_bytes());
    d.extend_from_slice(&frame_index.to_be_bytes());
    d.extend_from_slice(&video_unit_word(unit, total, fec_units).to_be_bytes());
    d.push(3);
    d.extend_from_slice(&[0; 8]);
    d.extend_from_slice(&[0x03, 0x98, adaptive_stream << 5]);
    if extended {
        d.extend_from_slice(&[0x00, 0x20, 0x31]);
    }
    d.extend_from_slice(payload);
    d
}

pub fn frame_units(picture: &[u8], chunk: usize, m: usize) -> Vec<Vec<u8>> {
    let pieces: Vec<&[u8]> = picture.chunks(chunk).collect();
    let len = chunk + 2;
    let mut wire = Vec::new();
    let mut padded = Vec::new();
    for p in &pieces {
        let pad = len - (p.len() + 2);
        let mut u = (pad as u16).to_be_bytes().to_vec();
        u.extend_from_slice(p);
        wire.push(u.clone());
        u.resize(len, 0);
        padded.push(u);
    }
    if m > 0 {
        wire.extend(fec::encode(&padded, m).unwrap());
    }
    wire
}

#[allow(clippy::too_many_arguments)]
pub fn audio_datagram(
    version: u32,
    packet_index: u16,
    frame_index: u16,
    units_total: u8,
    unit_size: u8,
    redundant: u8,
    source: u8,
    codec: u8,
    haptics: bool,
    payload: &[u8],
) -> Vec<u8> {
    let word = (u32::from(units_total.wrapping_sub(1)) << 16)
        | (u32::from(unit_size) << 8)
        | (u32::from(redundant & 0xf) << 4)
        | u32::from(source & 0xf);
    media_packet(
        false,
        version,
        packet_index,
        frame_index,
        word,
        codec,
        haptics,
        payload,
    )
    .0
}

#[allow(clippy::too_many_arguments)]
pub fn media_packet(
    video: bool,
    version: u32,
    packet_index: u16,
    frame_index: u16,
    unit_word: u32,
    codec: u8,
    haptics: bool,
    payload: &[u8],
) -> (Vec<u8>, usize) {
    let mut d = vec![if video { 0x02 } else { 0x03 }];
    d.extend_from_slice(&packet_index.to_be_bytes());
    d.extend_from_slice(&frame_index.to_be_bytes());
    d.extend_from_slice(&unit_word.to_be_bytes());
    d.push(codec);
    d.extend_from_slice(&[0; 8]);
    if video {
        d.extend_from_slice(&[0, 0, 0]);
    } else {
        d.push(0);
        if version == 12 {
            d.push(if haptics { 0x02 } else { 0x00 });
        }
    }
    let off = d.len();
    d.extend_from_slice(payload);
    (d, off)
}

pub fn packed_audio_datagram(version: u32, frame: u16, packets: &[Vec<u8>]) -> Vec<u8> {
    let get = |i: u16| {
        if i >= 1 {
            packets[usize::from(i) - 1].clone()
        } else {
            vec![0; 80]
        }
    };
    let payload = [
        get(frame),
        get(frame.saturating_sub(2)),
        get(frame.saturating_sub(1)),
    ]
    .concat();
    audio_datagram(version, frame, frame, 3, 80, 2, 1, 5, false, &payload)
}

pub fn packed_haptics_datagram(packet_index: u16, frame: u16) -> Vec<u8> {
    let unit = |i: u16| vec![i as u8; 120];
    let payload = [
        unit(frame),
        unit(frame.wrapping_sub(2)),
        unit(frame.wrapping_sub(1)),
    ]
    .concat();
    audio_datagram(12, packet_index, frame, 3, 120, 2, 1, 0, true, &payload)
}

pub fn body(n: usize, seed: u8) -> Vec<u8> {
    (0..n)
        .map(|i| 0x20 + ((i * 7 + usize::from(seed) * 13) % 200) as u8)
        .collect()
}

#[cfg(feature = "opus")]
pub fn opus_tone_packets(frames: usize) -> Vec<Vec<u8>> {
    let mut enc = con_engine::media::opus::OpusEncoder::new(48000, 2, false, Some(64000)).unwrap();
    tone(440.0, frames)
        .iter()
        .map(|pcm| enc.encode(pcm, 400).unwrap())
        .collect()
}

pub fn tone(hz: f64, frames: usize) -> Vec<Vec<i16>> {
    (0..frames)
        .map(|f| {
            let mut v = Vec::with_capacity(960);
            for i in 0..480 {
                let t = (f * 480 + i) as f64 / 48000.0;
                let s = (t * hz * 2.0 * std::f64::consts::PI).sin() * 12000.0;
                v.push(s as i16);
                v.push(s as i16);
            }
            v
        })
        .collect()
}

pub fn left_frequency(pcm: &[i16]) -> f64 {
    let left: Vec<i16> = pcm.iter().step_by(2).copied().collect();
    let crossings = left.windows(2).filter(|w| w[0] < 0 && w[1] >= 0).count();
    crossings as f64 * 48000.0 / left.len() as f64
}
