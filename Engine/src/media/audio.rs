use crate::log::Logger;
use crate::transport::packet::{MediaHeader, UnitWord};
use crate::transport::seq::{idx_after, idx_before};

pub const AUDIO_HEADER_LEN: usize = 14;
pub const JITTER_SLOTS: usize = 8;
pub const JITTER_START: usize = 3;
pub const STARTUP_THRESHOLD: u16 = 32768;
pub const OPUS_CODEC: u8 = 5;
pub const HAPTICS_SAMPLE_RATE: u32 = 3000;
pub const HAPTICS_CHANNELS: u8 = 2;
pub const MAX_FRAME_SAMPLES: usize = 5760;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct AudioHeader {
    pub channels: u8,
    pub bits: u8,
    pub rate: u32,
    pub frame_size: u32,
    pub unknown: u32,
}

impl AudioHeader {
    pub fn parse(b: &[u8]) -> Option<Self> {
        if b.len() != AUDIO_HEADER_LEN {
            return None;
        }
        let be = |at: usize| u32::from_be_bytes([b[at], b[at + 1], b[at + 2], b[at + 3]]);
        Some(Self {
            channels: b[0],
            bits: b[1],
            rate: be(2),
            frame_size: be(6),
            unknown: be(10),
        })
    }

    pub fn to_bytes(&self) -> [u8; AUDIO_HEADER_LEN] {
        let mut b = [0u8; AUDIO_HEADER_LEN];
        b[0] = self.channels;
        b[1] = self.bits;
        b[2..6].copy_from_slice(&self.rate.to_be_bytes());
        b[6..10].copy_from_slice(&self.frame_size.to_be_bytes());
        b[10..14].copy_from_slice(&self.unknown.to_be_bytes());
        b
    }

    pub fn is_usable(&self) -> bool {
        (1..=8).contains(&self.channels)
            && (8000..=192_000).contains(&self.rate)
            && (1..=MAX_FRAME_SAMPLES as u32).contains(&self.frame_size)
    }
}

pub trait AudioDecoder: Send {
    fn decode(&mut self, packet: &[u8], out: &mut [i16]) -> Result<usize, String>;
}

pub fn pcm_peak(pcm: &[i16]) -> u16 {
    pcm.iter()
        .map(|&s| s.unsigned_abs())
        .max()
        .unwrap_or(0)
        .min(i16::MAX as u16)
}

pub fn pcm_rms(pcm: &[i16]) -> u16 {
    if pcm.is_empty() {
        return 0;
    }
    let sum: f64 = pcm.iter().map(|&s| f64::from(s) * f64::from(s)).sum();
    (sum / pcm.len() as f64)
        .sqrt()
        .round()
        .min(f64::from(i16::MAX)) as u16
}

pub const SILENCE_PEAK: u16 = 64;
pub const LEVEL_REPORT_FRAMES: u64 = 500;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AudioFrame<'a> {
    pub pcm: &'a [i16],
    pub opus: &'a [u8],
    pub decoded: bool,
    pub concealed: bool,
    pub decode_error: bool,
    pub frame_index: u16,
    pub channels: u8,
    pub sample_rate: u32,
    pub samples: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HapticsFrame<'a> {
    pub pcm: &'a [u8],
    pub frame_index: u16,
    pub sample_rate: u32,
    pub channels: u8,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Default)]
pub enum AudioMode {
    #[default]
    Packed,
    SingleUnit,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Default)]
pub enum HapticsMode {
    #[default]
    Console,
    Cloud,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Play {
    Frame(u16, Vec<u8>),
    Conceal(u16),
}

#[derive(Clone, Debug, Default)]
pub struct JitterBuffer {
    slots: Vec<(u16, Vec<u8>)>,
    next: Option<u16>,
    pub discarded: u64,
}

impl JitterBuffer {
    pub fn new() -> Self {
        Self::default()
    }

    fn newest(&self) -> Option<u16> {
        self.slots
            .iter()
            .map(|s| s.0)
            .reduce(|a, b| if idx_after(b, a) { b } else { a })
    }

    fn oldest(&self) -> Option<u16> {
        self.slots
            .iter()
            .map(|s| s.0)
            .reduce(|a, b| if idx_before(b, a) { b } else { a })
    }

    pub fn offer(&mut self, index: u16, data: Vec<u8>, out: &mut Vec<Play>) {
        let old = self.next.is_some_and(|n| idx_before(index, n));
        if old || self.slots.iter().any(|s| s.0 == index) {
            self.discarded += 1;
            return;
        }
        if self.slots.len() >= JITTER_SLOTS {
            self.discarded += 1;
            let newest = self.newest().expect("jitter buffer is full");
            if !idx_before(index, newest) {
                return;
            }
            self.slots.retain(|s| s.0 != newest);
        }
        self.slots.push((index, data));
        self.play(out);
    }

    fn play(&mut self, out: &mut Vec<Play>) {
        if self.next.is_none() {
            if self.slots.len() < JITTER_START {
                return;
            }
            self.next = self.oldest();
        }
        while let Some(next) = self.next {
            if let Some(pos) = self.slots.iter().position(|s| s.0 == next) {
                let (i, d) = self.slots.swap_remove(pos);
                out.push(Play::Frame(i, d));
                self.next = Some(next.wrapping_add(1));
                continue;
            }
            let Some(newest) = self.newest() else {
                break;
            };
            if idx_after(newest, next)
                && (self.slots.len() < JITTER_START
                    || usize::from(newest.wrapping_sub(next)) >= JITTER_START)
            {
                out.push(Play::Conceal(next));
                self.next = Some(next.wrapping_add(1));
                continue;
            }
            break;
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct AudioStats {
    pub datagrams: u64,
    pub datagrams_dropped: u64,
    pub frames_offered: u64,
    pub frames_discarded: u64,
    pub frames_played: u64,
    pub frames_concealed: u64,
    pub decode_errors: u64,
    pub haptics_datagrams: u64,
    pub haptics_frames: u64,
    pub haptics_dropped: u64,
}

pub struct AudioReceiver {
    header: AudioHeader,
    mode: AudioMode,
    decoder: Option<Box<dyn AudioDecoder>>,
    jitter: JitterBuffer,
    startup: bool,
    newest_taken: Option<u16>,
    pcm: Vec<i16>,
    last_samples: usize,
    packed_seen: bool,
    level: LevelMeter,
    stats: AudioStats,
    log: Logger,
}

#[derive(Clone, Copy, Debug, Default)]
struct LevelMeter {
    frames: u64,
    peak: u16,
    packet_bytes: u64,
    packets: u64,
    zero_bytes: u64,
    first_byte: u8,
    reported: bool,
    silent_start: bool,
    silent_run: u64,
}

impl LevelMeter {
    fn take_packet_summary(&mut self) -> String {
        let mean = self.packet_bytes.checked_div(self.packets).unwrap_or(0);
        let zeros = (self.zero_bytes * 100)
            .checked_div(self.packet_bytes)
            .unwrap_or(0);
        let first = self.first_byte;
        (self.packets, self.packet_bytes, self.zero_bytes) = (0, 0, 0);
        format!(
            "Opus packets {mean} bytes on average, {zeros}% of their bytes zero, first byte 0x{first:02x}"
        )
    }

    fn update(&mut self, log: &Logger, index: u16, pcm: &[i16], packet: &[u8], frame_size: usize) {
        let peak = pcm_peak(pcm);
        self.frames += 1;
        self.peak = self.peak.max(peak);
        if let Some(&first) = packet.first() {
            self.packets += 1;
            self.packet_bytes += packet.len() as u64;
            self.zero_bytes += packet.iter().filter(|&&b| b == 0).count() as u64;
            self.first_byte = first;
        }
        self.silent_run = if peak <= SILENCE_PEAK {
            self.silent_run + 1
        } else {
            0
        };
        if !self.reported && self.frames >= LEVEL_REPORT_FRAMES {
            self.reported = true;
            self.silent_start = self.peak <= SILENCE_PEAK;
            let (frames, peak, samples) = (self.frames, self.peak, pcm.len());
            let packets = self.take_packet_summary();
            let silent = if peak <= SILENCE_PEAK {
                " (silent)"
            } else {
                ""
            };
            log.info(|| {
                format!(
                    "audio: level after {frames} frames: peak {peak}{silent}, {packets}, last frame {samples} samples (header frame size {frame_size})"
                )
            });
        } else if self.silent_start && peak > SILENCE_PEAK {
            self.silent_start = false;
            let frames = self.frames;
            log.info(|| format!("audio: sound starts at frame {index} (after {frames} frames)"));
            self.take_packet_summary();
        } else if self.reported && !self.silent_start && self.silent_run == LEVEL_REPORT_FRAMES {
            self.silent_start = true;
            let frames = self.frames;
            let packets = self.take_packet_summary();
            log.info(|| {
                format!(
                    "audio: silent since {LEVEL_REPORT_FRAMES} frames, at frame {index} (after {frames} frames): {packets}"
                )
            });
        } else if self.silent_run == 0 && self.packets >= LEVEL_REPORT_FRAMES {
            self.take_packet_summary();
        }
    }
}

impl std::fmt::Debug for AudioReceiver {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AudioReceiver")
            .field("header", &self.header)
            .field("mode", &self.mode)
            .field("decoder", &self.decoder.is_some())
            .finish_non_exhaustive()
    }
}

pub fn packed_indices(f: u16, s: usize, r: usize, startup: bool) -> Vec<Option<u16>> {
    let mut v = Vec::with_capacity(s + r);
    for u in 0..s {
        v.push(Some(f.wrapping_add(u as u16)));
    }
    for u in s..s + r {
        let back = (r - (u - s)) as u16;
        let skip = startup && i32::from(f) - i32::from(back) < 1;
        v.push((!skip).then(|| f.wrapping_sub(back)));
    }
    v
}

impl AudioReceiver {
    pub fn new(
        header: AudioHeader,
        mode: AudioMode,
        decoder: Option<Box<dyn AudioDecoder>>,
        log: Logger,
    ) -> Self {
        let cap = MAX_FRAME_SAMPLES * usize::from(header.channels.clamp(1, 8));
        Self {
            header,
            mode,
            decoder,
            jitter: JitterBuffer::new(),
            startup: true,
            newest_taken: None,
            pcm: vec![0; cap],
            last_samples: (header.frame_size as usize).clamp(1, MAX_FRAME_SAMPLES),
            packed_seen: false,
            level: LevelMeter::default(),
            stats: AudioStats::default(),
            log,
        }
    }

    pub fn header(&self) -> AudioHeader {
        self.header
    }

    pub fn mode(&self) -> AudioMode {
        self.mode
    }

    pub fn decodes(&self) -> bool {
        self.decoder.is_some()
    }

    pub fn stats(&self) -> AudioStats {
        AudioStats {
            frames_discarded: self.jitter.discarded,
            ..self.stats
        }
    }

    pub fn on_packet(
        &mut self,
        header: &MediaHeader,
        payload: &[u8],
        out: &mut dyn FnMut(&AudioFrame<'_>),
    ) {
        self.stats.datagrams += 1;
        if header.codec != OPUS_CODEC || payload.is_empty() {
            self.stats.datagrams_dropped += 1;
            return;
        }
        let f = header.frame_index;
        if f > STARTUP_THRESHOLD {
            self.startup = false;
        }
        let mut plays = Vec::new();
        let mode = match (self.mode, header.unit_word) {
            (
                AudioMode::SingleUnit,
                UnitWord::Audio {
                    units_total,
                    unit_size,
                    fec_units,
                    source_units,
                    ..
                },
            ) if units_total >= 2
                && source_units >= 1
                && unit_size > 0
                && u16::from(source_units) + u16::from(fec_units) == units_total
                && payload.len() == usize::from(unit_size) * usize::from(units_total) =>
            {
                if !self.packed_seen {
                    self.packed_seen = true;
                    self.log.info(|| {
                        format!(
                            "audio: cloud datagrams are packed ({source_units} new + {fec_units} copies of {unit_size} bytes), units are decoded separately"
                        )
                    });
                }
                AudioMode::Packed
            }
            (m, _) => m,
        };
        let upgraded = self.mode == AudioMode::SingleUnit && mode == AudioMode::Packed;
        match mode {
            AudioMode::SingleUnit => {
                if self.newest_taken.is_some_and(|n| !idx_after(f, n)) {
                    self.stats.datagrams_dropped += 1;
                    return;
                }
                self.newest_taken = Some(f);
                self.stats.frames_offered += 1;
                self.jitter.offer(f, payload.to_vec(), &mut plays);
            }
            AudioMode::Packed => {
                let UnitWord::Audio {
                    units_total,
                    unit_size,
                    fec_units,
                    source_units,
                    ..
                } = header.unit_word
                else {
                    self.stats.datagrams_dropped += 1;
                    return;
                };
                let (s, r, size) = (
                    usize::from(source_units),
                    usize::from(fec_units),
                    usize::from(unit_size),
                );
                if s + r != usize::from(units_total) || payload.len() != size * (s + r) {
                    self.stats.datagrams_dropped += 1;
                    self.log.debug(|| {
                        format!(
                            "audio: datagram size {} does not match {} units of {} bytes",
                            payload.len(),
                            units_total,
                            size
                        )
                    });
                    return;
                }
                let idx = packed_indices(f, s, r, self.startup);
                let mut order: Vec<usize> = (s..s + r).collect();
                order.extend(0..s);
                for u in order {
                    if let Some(i) = idx[u] {
                        self.stats.frames_offered += 1;
                        let unit = payload[u * size..(u + 1) * size].to_vec();
                        self.jitter.offer(i, unit, &mut plays);
                    }
                }
                if upgraded {
                    let newest = f.wrapping_add(s.saturating_sub(1) as u16);
                    if self.newest_taken.is_none_or(|n| idx_after(newest, n)) {
                        self.newest_taken = Some(newest);
                    }
                }
            }
        }
        for p in plays {
            self.play(p, out);
        }
    }

    fn play(&mut self, p: Play, out: &mut dyn FnMut(&AudioFrame<'_>)) {
        let (index, packet, mut concealed) = match p {
            Play::Frame(i, d) => (i, d, false),
            Play::Conceal(i) => (i, Vec::new(), true),
        };
        let frame_size = self.header.frame_size as usize;
        let ch = usize::from(self.header.channels.clamp(1, 8));
        let Some(dec) = self.decoder.as_mut() else {
            if concealed {
                self.stats.frames_concealed += 1;
            } else {
                self.stats.frames_played += 1;
            }
            out(&AudioFrame {
                pcm: &[],
                opus: &packet,
                decoded: false,
                concealed,
                decode_error: false,
                frame_index: index,
                channels: self.header.channels,
                sample_rate: self.header.rate,
                samples: frame_size,
            });
            return;
        };
        let conceal_len = self.last_samples * ch;
        let mut decode_error = false;
        let result = if concealed {
            dec.decode(&[], &mut self.pcm[..conceal_len])
        } else {
            dec.decode(&packet, &mut self.pcm)
        };
        let mut n = match result {
            Ok(n) => {
                if !concealed && n > 0 {
                    self.last_samples = n.min(MAX_FRAME_SAMPLES);
                }
                n
            }
            Err(e) => {
                self.stats.decode_errors += 1;
                if self.stats.decode_errors <= 10 || self.stats.decode_errors.is_power_of_two() {
                    let count = self.stats.decode_errors;
                    self.log.warn(|| {
                        format!(
                            "audio: opus decoder: frame {index} ({} bytes): {e} (error {count})",
                            packet.len()
                        )
                    });
                }
                concealed = true;
                decode_error = true;
                match dec.decode(&[], &mut self.pcm[..conceal_len]) {
                    Ok(n) => n,
                    Err(_) => return,
                }
            }
        };
        n = n.min(MAX_FRAME_SAMPLES).min(self.pcm.len() / ch);
        if concealed {
            self.stats.frames_concealed += 1;
        } else {
            self.stats.frames_played += 1;
        }
        let pcm = &self.pcm[..n * ch];
        self.level
            .update(&self.log, index, pcm, &packet, frame_size);
        out(&AudioFrame {
            pcm,
            opus: &packet,
            decoded: true,
            concealed,
            decode_error,
            frame_index: index,
            channels: self.header.channels,
            sample_rate: self.header.rate,
            samples: n,
        });
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct HapticsStats {
    pub datagrams: u64,
    pub frames: u64,
    pub dropped: u64,
}

#[derive(Debug, Default)]
pub struct HapticsReceiver {
    mode: HapticsMode,
    last: Option<u16>,
    startup: bool,
    stats: HapticsStats,
}

impl HapticsReceiver {
    pub fn new(mode: HapticsMode) -> Self {
        Self {
            mode,
            last: None,
            startup: true,
            stats: HapticsStats::default(),
        }
    }

    pub fn stats(&self) -> HapticsStats {
        self.stats
    }

    fn hand_over(&mut self, index: u16, unit: &[u8], out: &mut dyn FnMut(&HapticsFrame<'_>)) {
        if self.last.is_some_and(|l| !idx_after(index, l)) {
            self.stats.dropped += 1;
            return;
        }
        self.last = Some(index);
        self.stats.frames += 1;
        out(&HapticsFrame {
            pcm: unit,
            frame_index: index,
            sample_rate: HAPTICS_SAMPLE_RATE,
            channels: HAPTICS_CHANNELS,
        });
    }

    pub fn on_packet(
        &mut self,
        header: &MediaHeader,
        payload: &[u8],
        out: &mut dyn FnMut(&HapticsFrame<'_>),
    ) {
        self.stats.datagrams += 1;
        let UnitWord::Audio {
            units_total,
            unit_size,
            fec_units,
            source_units,
            ..
        } = header.unit_word
        else {
            self.stats.dropped += 1;
            return;
        };
        let (s, r, size) = (
            usize::from(source_units),
            usize::from(fec_units),
            usize::from(unit_size),
        );
        let f = header.frame_index;
        if f > STARTUP_THRESHOLD {
            self.startup = false;
        }
        let ok = match self.mode {
            HapticsMode::Console => {
                !payload.is_empty()
                    && s + r == usize::from(units_total)
                    && payload.len() == size * (s + r)
            }
            HapticsMode::Cloud => size != 0 && s != 0 && payload.len() == size * (s + r),
        };
        if !ok {
            self.stats.dropped += 1;
            return;
        }
        let idx = packed_indices(f, s, r, self.startup);
        let order: Vec<usize> = match self.mode {
            HapticsMode::Console => (0..s + r).collect(),
            HapticsMode::Cloud => (s..s + r).chain(0..s).collect(),
        };
        for u in order {
            match idx[u] {
                Some(i) => self.hand_over(i, &payload[u * size..(u + 1) * size], out),
                None => self.stats.dropped += 1,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_round_trip() {
        let b = [2, 16, 0, 0, 0xbb, 0x80, 0, 0, 1, 0xe0, 0, 0, 0, 1];
        let h = AudioHeader::parse(&b).unwrap();
        assert_eq!(
            h,
            AudioHeader {
                channels: 2,
                bits: 16,
                rate: 48000,
                frame_size: 480,
                unknown: 1
            }
        );
        assert_eq!(h.to_bytes(), b);
        assert!(h.is_usable());
        assert!(AudioHeader::parse(&b[..13]).is_none());
    }

    #[test]
    fn packed_layout_example() {
        assert_eq!(
            packed_indices(100, 1, 2, false),
            vec![Some(100), Some(98), Some(99)]
        );
        assert_eq!(packed_indices(1, 1, 2, true), vec![Some(1), None, None]);
        assert_eq!(packed_indices(2, 1, 2, true), vec![Some(2), None, Some(1)]);
        assert_eq!(
            packed_indices(1, 1, 2, false),
            vec![Some(1), Some(0xffff), Some(0)]
        );
    }

    fn frames(plays: &[Play]) -> Vec<(u16, bool)> {
        plays
            .iter()
            .map(|p| match p {
                Play::Frame(i, _) => (*i, false),
                Play::Conceal(i) => (*i, true),
            })
            .collect()
    }

    #[test]
    fn jitter_start_order_and_concealment() {
        let mut j = JitterBuffer::new();
        let mut out = Vec::new();
        j.offer(11, vec![], &mut out);
        j.offer(10, vec![], &mut out);
        assert!(out.is_empty());
        j.offer(12, vec![], &mut out);
        assert_eq!(frames(&out), vec![(10, false), (11, false), (12, false)]);
        out.clear();
        j.offer(12, vec![], &mut out);
        j.offer(9, vec![], &mut out);
        assert_eq!(j.discarded, 2);
        j.offer(14, vec![], &mut out);
        assert_eq!(frames(&out), vec![(13, true), (14, false)]);
    }

    #[test]
    fn jitter_gap_after_start() {
        let mut j = JitterBuffer::new();
        let mut out = Vec::new();
        for i in [1u16, 2, 3] {
            j.offer(i, vec![], &mut out);
        }
        assert_eq!(frames(&out), vec![(1, false), (2, false), (3, false)]);
        out.clear();
        j.offer(5, vec![], &mut out);
        assert_eq!(frames(&out), vec![(4, true), (5, false)]);
    }
}
