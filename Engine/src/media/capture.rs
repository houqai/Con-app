use std::fs::OpenOptions;
use std::io::{BufWriter, Read, Write};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::mpsc::{sync_channel, SyncSender};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::JoinHandle;
use std::time::Instant;

use super::audio::{pcm_peak, pcm_rms, AudioFrame, AudioMode, AUDIO_HEADER_LEN};
use super::video::{DropReason, SampleKind, VideoSample};
use crate::log::Logger;
use crate::threads::{self, ThreadRole};
use crate::transport::packet::MediaKind;
use crate::transport::MediaPacket;
use crate::Codec;

pub const MAGIC: [u8; 8] = *b"CONVCAP1";
pub const VERSION: u16 = 1;
pub const FILE_HEADER_LEN: usize = 16;
pub const RECORD_HEADER_LEN: usize = 32;
const QUEUE: usize = 512;

pub mod kind {
    pub const PARAMETER_SETS: u8 = 0;
    pub const PICTURE: u8 = 1;
    pub const NOT_DELIVERED: u8 = 2;
    pub const START: u8 = 3;
}

pub mod flag {
    pub const KEYFRAME: u8 = 0x01;
    pub const RECOVERED: u8 = 0x02;
    pub const FEC_RECOVERED: u8 = 0x04;
    pub const ACCEPTED: u8 = 0x08;
    pub const REPEATED: u8 = 0x10;
    pub const UNCHECKED: u8 = 0x20;
    pub const DECODE_ONLY: u8 = 0x40;
}

fn codec_byte(c: Codec) -> u8 {
    match c {
        Codec::H264 => 0,
        Codec::H265 => 1,
        Codec::H265Hdr => 2,
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RecordHeader {
    pub length: u32,
    pub frame_index: u16,
    pub kind: u8,
    pub flags: u8,
    pub frames_lost: u32,
    pub profile: u8,
    pub codec: u8,
    pub reason: u8,
    pub width: u16,
    pub height: u16,
    pub sequence: u32,
    pub time_us: u64,
}

impl RecordHeader {
    pub fn encode(&self) -> [u8; RECORD_HEADER_LEN] {
        let mut b = [0u8; RECORD_HEADER_LEN];
        b[0..4].copy_from_slice(&self.length.to_le_bytes());
        b[4..6].copy_from_slice(&self.frame_index.to_le_bytes());
        b[6] = self.kind;
        b[7] = self.flags;
        b[8..12].copy_from_slice(&self.frames_lost.to_le_bytes());
        b[12] = self.profile;
        b[13] = self.codec;
        b[14] = self.reason;
        b[16..18].copy_from_slice(&self.width.to_le_bytes());
        b[18..20].copy_from_slice(&self.height.to_le_bytes());
        b[20..24].copy_from_slice(&self.sequence.to_le_bytes());
        b[24..32].copy_from_slice(&self.time_us.to_le_bytes());
        b
    }

    pub fn decode(b: &[u8]) -> Option<Self> {
        let b = b.get(..RECORD_HEADER_LEN)?;
        let u16_at = |o: usize| u16::from_le_bytes([b[o], b[o + 1]]);
        let u32_at = |o: usize| u32::from_le_bytes(b[o..o + 4].try_into().unwrap());
        Some(Self {
            length: u32_at(0),
            frame_index: u16_at(4),
            kind: b[6],
            flags: b[7],
            frames_lost: u32_at(8),
            profile: b[12],
            codec: b[13],
            reason: b[14],
            width: u16_at(16),
            height: u16_at(18),
            sequence: u32_at(20),
            time_us: u64::from_le_bytes(b[24..32].try_into().unwrap()),
        })
    }
}

fn header_bytes(magic: [u8; 8], version: u16, record_len: usize) -> [u8; FILE_HEADER_LEN] {
    let mut h = [0u8; FILE_HEADER_LEN];
    h[..8].copy_from_slice(&magic);
    h[8..10].copy_from_slice(&version.to_le_bytes());
    h[10..12].copy_from_slice(&(record_len as u16).to_le_bytes());
    h
}

pub fn file_header() -> [u8; FILE_HEADER_LEN] {
    header_bytes(MAGIC, VERSION, RECORD_HEADER_LEN)
}

struct Writer {
    tx: Option<SyncSender<Vec<u8>>>,
    thread: Option<JoinHandle<()>>,
    start: Instant,
    sequence: AtomicU32,
    skipped: Arc<AtomicU64>,
    label: &'static str,
    log: Logger,
}

impl Writer {
    fn open(path: &Path, header: &[u8], label: &'static str, log: Logger) -> std::io::Result<Self> {
        let mut file = OpenOptions::new()
            .read(true)
            .append(true)
            .create(true)
            .open(path)?;
        if file.metadata()?.len() == 0 {
            file.write_all(header)?;
        } else {
            let mut magic = [0u8; 8];
            file.read_exact(&mut magic)?;
            if magic[..] != header[..8] {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    format!("not a {label} file"),
                ));
            }
        }
        let (tx, rx) = sync_channel::<Vec<u8>>(QUEUE);
        let writer_log = log.clone();
        let thread = threads::spawn(ThreadRole::Capture, "con-capture", move || {
            let mut out = BufWriter::with_capacity(1 << 20, file);
            let mut failed = false;
            for record in rx {
                if failed {
                    continue;
                }
                if let Err(e) = out.write_all(&record) {
                    writer_log.warn(|| format!("{label}: writing failed: {e}"));
                    failed = true;
                }
            }
            if !failed {
                if let Err(e) = out.flush() {
                    writer_log.warn(|| format!("{label}: writing failed: {e}"));
                }
            }
        })?;
        Ok(Self {
            tx: Some(tx),
            thread: Some(thread),
            start: Instant::now(),
            sequence: AtomicU32::new(0),
            skipped: Arc::default(),
            label,
            log,
        })
    }

    fn record(&self, header: impl FnOnce(u32, u64) -> Vec<u8>, data: &[&[u8]]) {
        let sequence = self.sequence.fetch_add(1, Ordering::Relaxed);
        let time_us = self.start.elapsed().as_micros() as u64;
        let mut v = header(sequence, time_us);
        for d in data {
            v.extend_from_slice(d);
        }
        if let Some(tx) = &self.tx {
            if tx.try_send(v).is_err() {
                self.skipped.fetch_add(1, Ordering::Relaxed);
            }
        }
    }

    fn skipped(&self) -> u64 {
        self.skipped.load(Ordering::Relaxed)
    }

    fn close(&mut self, wait: bool) {
        self.tx = None;
        if let Some(t) = self.thread.take() {
            if wait {
                let _ = t.join();
            }
        }
        let skipped = self.skipped();
        let n = self.sequence.load(Ordering::Relaxed);
        let label = self.label;
        self.log.info(|| {
            format!(
                "{label} stopped: {n} records, {skipped} skipped because the writer fell behind"
            )
        });
    }
}

impl Drop for Writer {
    fn drop(&mut self) {
        if self.thread.is_some() {
            self.close(false);
        }
    }
}

pub trait Capture: Send + Sync + Sized {
    fn open(path: &Path, log: Logger) -> std::io::Result<Self>;
    fn begin(&self);
    fn finish(self);
}

pub struct VideoCapture {
    writer: Writer,
    wants_parameter_sets: AtomicBool,
}

impl std::fmt::Debug for VideoCapture {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("VideoCapture { .. }")
    }
}

impl Capture for VideoCapture {
    fn open(path: &Path, log: Logger) -> std::io::Result<Self> {
        Ok(Self {
            writer: Writer::open(path, &file_header(), "video capture", log)?,
            wants_parameter_sets: AtomicBool::new(true),
        })
    }

    fn begin(&self) {
        self.record(
            RecordHeader {
                kind: kind::START,
                profile: 0xff,
                ..Default::default()
            },
            &[],
        );
        self.writer.log.info(|| "video capture started".into());
    }

    fn finish(mut self) {
        self.writer.close(true);
    }
}

impl VideoCapture {
    fn record(&self, mut h: RecordHeader, data: &[u8]) {
        h.length = data.len() as u32;
        self.writer.record(
            |sequence, time_us| {
                h.sequence = sequence;
                h.time_us = time_us;
                h.encode().to_vec()
            },
            &[data],
        );
    }

    pub fn sample(&self, s: &VideoSample<'_>, accepted: bool) {
        let mut flags = 0;
        if s.keyframe {
            flags |= flag::KEYFRAME;
        }
        if s.recovered {
            flags |= flag::RECOVERED;
        }
        if s.fec_recovered {
            flags |= flag::FEC_RECOVERED;
        }
        if accepted {
            flags |= flag::ACCEPTED;
        }
        if s.unchecked {
            flags |= flag::UNCHECKED;
        }
        if s.decode_only {
            flags |= flag::DECODE_ONLY;
        }
        if s.kind == SampleKind::ParameterSets {
            self.wants_parameter_sets.store(false, Ordering::Relaxed);
        }
        self.record(
            RecordHeader {
                frame_index: s.frame_index,
                kind: match s.kind {
                    SampleKind::ParameterSets => kind::PARAMETER_SETS,
                    SampleKind::Picture => kind::PICTURE,
                },
                flags,
                frames_lost: s.frames_lost,
                profile: s.profile,
                codec: codec_byte(s.codec),
                width: s.width.min(0xffff) as u16,
                height: s.height.min(0xffff) as u16,
                ..Default::default()
            },
            s.data,
        );
    }

    pub fn not_delivered(&self, frame_index: u16, reason: DropReason, codec: Codec) {
        self.record(
            RecordHeader {
                frame_index,
                kind: kind::NOT_DELIVERED,
                profile: 0xff,
                codec: codec_byte(codec),
                reason: reason as u8,
                ..Default::default()
            },
            &[],
        );
    }

    pub fn wants_parameter_sets(&self) -> bool {
        self.wants_parameter_sets.load(Ordering::Relaxed)
    }

    pub fn repeat_parameter_sets(
        &self,
        profile: u8,
        width: u32,
        height: u32,
        codec: Codec,
        data: &[u8],
    ) {
        if !self.wants_parameter_sets.swap(false, Ordering::Relaxed) {
            return;
        }
        self.record(
            RecordHeader {
                kind: kind::PARAMETER_SETS,
                flags: flag::REPEATED,
                profile,
                codec: codec_byte(codec),
                width: width.min(0xffff) as u16,
                height: height.min(0xffff) as u16,
                ..Default::default()
            },
            data,
        );
    }
}

#[derive(Debug)]
pub struct CaptureSlot<C>(Arc<Mutex<Option<Arc<C>>>>);

impl<C> Clone for CaptureSlot<C> {
    fn clone(&self) -> Self {
        Self(self.0.clone())
    }
}

impl<C> Default for CaptureSlot<C> {
    fn default() -> Self {
        Self(Arc::default())
    }
}

pub type VideoCaptureSlot = CaptureSlot<VideoCapture>;
pub type AudioCaptureSlot = CaptureSlot<AudioCapture>;

impl<C: Capture> CaptureSlot<C> {
    fn lock(&self) -> MutexGuard<'_, Option<Arc<C>>> {
        crate::sync::lock(&self.0)
    }

    pub fn start(&self, path: &Path, log: Logger) -> std::io::Result<()> {
        let c = C::open(path, log)?;
        self.stop();
        c.begin();
        *self.lock() = Some(Arc::new(c));
        Ok(())
    }

    pub fn stop(&self) {
        let old = self.lock().take();
        if let Some(Ok(c)) = old.map(Arc::try_unwrap) {
            c.finish();
        }
    }

    pub fn current(&self) -> Option<Arc<C>> {
        self.lock().clone()
    }
}

pub const AUDIO_MAGIC: [u8; 8] = *b"CONACAP1";
pub const AUDIO_VERSION: u16 = 1;
pub const AUDIO_RECORD_HEADER_LEN: usize = 40;

pub mod audio_kind {
    pub const HEADER: u8 = 0;
    pub const DATAGRAM: u8 = 1;
    pub const FRAME: u8 = 2;
    pub const START: u8 = 3;
}

pub mod audio_flag {
    pub const DECODED: u8 = 0x01;
    pub const CONCEALED: u8 = 0x02;
    pub const DECODE_ERROR: u8 = 0x04;
    pub const HAPTICS: u8 = 0x08;
    pub const REPEATED: u8 = 0x10;
    pub const EXTENDED: u8 = 0x20;
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct AudioRecordHeader {
    pub length: u32,
    pub frame_index: u16,
    pub kind: u8,
    pub flags: u8,
    pub packet_index: u16,
    pub codec: u8,
    pub payload_offset: u8,
    pub unit_word: u32,
    pub peak: u16,
    pub rms: u16,
    pub samples: u16,
    pub packet_len: u16,
    pub channels: u8,
    pub layout: u8,
    pub sequence: u32,
    pub time_us: u64,
}

impl AudioRecordHeader {
    pub fn encode(&self) -> [u8; AUDIO_RECORD_HEADER_LEN] {
        let mut b = [0u8; AUDIO_RECORD_HEADER_LEN];
        b[0..4].copy_from_slice(&self.length.to_le_bytes());
        b[4..6].copy_from_slice(&self.frame_index.to_le_bytes());
        b[6] = self.kind;
        b[7] = self.flags;
        b[8..10].copy_from_slice(&self.packet_index.to_le_bytes());
        b[10] = self.codec;
        b[11] = self.payload_offset;
        b[12..16].copy_from_slice(&self.unit_word.to_le_bytes());
        b[16..18].copy_from_slice(&self.peak.to_le_bytes());
        b[18..20].copy_from_slice(&self.rms.to_le_bytes());
        b[20..22].copy_from_slice(&self.samples.to_le_bytes());
        b[22..24].copy_from_slice(&self.packet_len.to_le_bytes());
        b[24] = self.channels;
        b[25] = self.layout;
        b[28..32].copy_from_slice(&self.sequence.to_le_bytes());
        b[32..40].copy_from_slice(&self.time_us.to_le_bytes());
        b
    }

    pub fn decode(b: &[u8]) -> Option<Self> {
        let b = b.get(..AUDIO_RECORD_HEADER_LEN)?;
        let u16_at = |o: usize| u16::from_le_bytes([b[o], b[o + 1]]);
        let u32_at = |o: usize| u32::from_le_bytes(b[o..o + 4].try_into().unwrap());
        Some(Self {
            length: u32_at(0),
            frame_index: u16_at(4),
            kind: b[6],
            flags: b[7],
            packet_index: u16_at(8),
            codec: b[10],
            payload_offset: b[11],
            unit_word: u32_at(12),
            peak: u16_at(16),
            rms: u16_at(18),
            samples: u16_at(20),
            packet_len: u16_at(22),
            channels: b[24],
            layout: b[25],
            sequence: u32_at(28),
            time_us: u64::from_le_bytes(b[32..40].try_into().unwrap()),
        })
    }
}

pub fn audio_file_header() -> [u8; FILE_HEADER_LEN] {
    header_bytes(AUDIO_MAGIC, AUDIO_VERSION, AUDIO_RECORD_HEADER_LEN)
}

pub struct AudioCapture {
    writer: Writer,
    wants_header: AtomicBool,
}

impl std::fmt::Debug for AudioCapture {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("AudioCapture { .. }")
    }
}

impl Capture for AudioCapture {
    fn open(path: &Path, log: Logger) -> std::io::Result<Self> {
        Ok(Self {
            writer: Writer::open(path, &audio_file_header(), "audio capture", log)?,
            wants_header: AtomicBool::new(true),
        })
    }

    fn begin(&self) {
        self.record(
            AudioRecordHeader {
                kind: audio_kind::START,
                ..Default::default()
            },
            &[],
        );
        self.writer.log.info(|| "audio capture started".into());
    }

    fn finish(mut self) {
        self.writer.close(true);
    }
}

impl AudioCapture {
    fn record(&self, mut h: AudioRecordHeader, data: &[u8]) {
        h.length = data.len() as u32;
        self.writer.record(
            |sequence, time_us| {
                h.sequence = sequence;
                h.time_us = time_us;
                h.encode().to_vec()
            },
            &[data],
        );
    }

    pub fn header(
        &self,
        header: &[u8; AUDIO_HEADER_LEN],
        decoded: bool,
        mode: AudioMode,
        repeated: bool,
    ) {
        self.wants_header.store(false, Ordering::Relaxed);
        let mut flags = 0;
        if decoded {
            flags |= audio_flag::DECODED;
        }
        if repeated {
            flags |= audio_flag::REPEATED;
        }
        self.record(
            AudioRecordHeader {
                kind: audio_kind::HEADER,
                flags,
                channels: header[0],
                layout: match mode {
                    AudioMode::Packed => 0,
                    AudioMode::SingleUnit => 1,
                },
                ..Default::default()
            },
            header,
        );
    }

    pub fn wants_header(&self) -> bool {
        self.wants_header.load(Ordering::Relaxed)
    }

    pub fn datagram(&self, p: &MediaPacket) {
        let h = &p.header;
        let mut flags = 0;
        if h.kind == MediaKind::Haptics {
            flags |= audio_flag::HAPTICS;
        }
        if h.extended {
            flags |= audio_flag::EXTENDED;
        }
        self.record(
            AudioRecordHeader {
                frame_index: h.frame_index,
                kind: audio_kind::DATAGRAM,
                flags,
                packet_index: h.packet_index,
                codec: h.codec,
                payload_offset: h.payload_offset.min(255) as u8,
                unit_word: h.unit_word_raw,
                ..Default::default()
            },
            &p.datagram,
        );
    }

    pub fn frame(&self, f: &AudioFrame<'_>) {
        let mut flags = 0;
        if f.decoded {
            flags |= audio_flag::DECODED;
        }
        if f.concealed {
            flags |= audio_flag::CONCEALED;
        }
        if f.decode_error {
            flags |= audio_flag::DECODE_ERROR;
        }
        self.record(
            AudioRecordHeader {
                frame_index: f.frame_index,
                kind: audio_kind::FRAME,
                flags,
                peak: pcm_peak(f.pcm),
                rms: pcm_rms(f.pcm),
                samples: f.samples.min(0xffff) as u16,
                packet_len: f.opus.len().min(0xffff) as u16,
                channels: f.channels,
                ..Default::default()
            },
            if f.concealed { &[] } else { f.opus },
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn records_append_and_refusal() {
        let dir = std::env::temp_dir().join(format!("con-capture-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("cap.bin");
        let slot = VideoCaptureSlot::default();
        for round in 0..2u16 {
            slot.start(&path, Logger::default()).unwrap();
            let c = slot.current().unwrap();
            c.not_delivered(40 + round, DropReason::ReferenceMissing, Codec::H265);
            c.repeat_parameter_sets(2, 1920, 1080, Codec::H265, &[0, 0, 0, 1, 0x40, 1]);
            c.repeat_parameter_sets(2, 1920, 1080, Codec::H265, &[9]);
            let pic = [0u8, 0, 1, 2, 0, 0];
            c.sample(
                &VideoSample {
                    kind: SampleKind::Picture,
                    data: &pic[..4],
                    padded: &pic,
                    frame_index: 50 + round,
                    frames_lost: 0,
                    recovered: true,
                    fec_recovered: false,
                    keyframe: false,
                    unchecked: false,
                    decode_only: true,
                    codec: Codec::H265,
                    profile: 2,
                    width: 1920,
                    height: 1080,
                },
                true,
            );
            drop(c);
            slot.stop();
        }
        let f = std::fs::read(&path).unwrap();
        assert_eq!(f[..16], file_header());
        let mut at = 16;
        let mut got = Vec::new();
        while at < f.len() {
            let h = RecordHeader::decode(&f[at..]).unwrap();
            got.push((
                h.kind,
                h.frame_index,
                h.reason,
                h.flags,
                h.sequence,
                h.length,
            ));
            at += RECORD_HEADER_LEN + h.length as usize;
        }
        assert_eq!(at, f.len());
        let round = |n: u16| {
            vec![
                (kind::START, 0, 0, 0, 0, 0),
                (kind::NOT_DELIVERED, 40 + n, 2, 0, 1, 0),
                (kind::PARAMETER_SETS, 0, 0, flag::REPEATED, 2, 6),
                (
                    kind::PICTURE,
                    50 + n,
                    0,
                    flag::RECOVERED | flag::ACCEPTED | flag::DECODE_ONLY,
                    3,
                    4,
                ),
            ]
        };
        assert_eq!(got, [round(0), round(1)].concat());
        let other = dir.join("other.txt");
        std::fs::write(&other, b"hello").unwrap();
        assert!(slot.start(&other, Logger::default()).is_err());
        assert_eq!(std::fs::read(&other).unwrap(), b"hello");
        assert!(slot.current().is_none());
        let _ = std::fs::remove_dir_all(&dir);
        let h = RecordHeader {
            length: 7,
            frame_index: 65535,
            kind: 1,
            flags: 0x0f,
            frames_lost: 3,
            profile: 1,
            codec: 2,
            reason: 0,
            width: 3840,
            height: 2160,
            sequence: 99,
            time_us: 1 << 40,
        };
        assert_eq!(RecordHeader::decode(&h.encode()), Some(h));
    }

    #[test]
    fn audio_records_and_refusal() {
        let dir =
            std::env::temp_dir().join(format!("con-audio-capture-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("audio.bin");
        let video = dir.join("video.bin");
        let slot = AudioCaptureSlot::default();
        slot.start(&path, Logger::default()).unwrap();
        let c = slot.current().unwrap();
        assert!(c.wants_header());
        let header = [2, 16, 0, 0, 0xbb, 0x80, 0, 0, 1, 0xe0, 0, 0, 0, 1];
        c.header(&header, true, AudioMode::SingleUnit, true);
        assert!(!c.wants_header());
        let mut d = vec![0x03, 0, 7, 0, 9, 0x00, 0x02, 0x50, 0x21, 5];
        d.extend_from_slice(&[0; 9]);
        d.push(0);
        d.extend_from_slice(&[0xaa; 6]);
        let p = MediaPacket {
            header: crate::transport::packet::parse_media(&d, 12).unwrap(),
            key_position: 0,
            datagram: d.clone(),
        };
        c.datagram(&p);
        let pcm = [100i16, -300, 200, 0];
        c.frame(&AudioFrame {
            pcm: &pcm,
            opus: &[1, 2, 3],
            decoded: true,
            concealed: false,
            decode_error: false,
            frame_index: 9,
            channels: 2,
            sample_rate: 48000,
            samples: 2,
        });
        c.frame(&AudioFrame {
            pcm: &[0; 4],
            opus: &[],
            decoded: true,
            concealed: true,
            decode_error: true,
            frame_index: 10,
            channels: 2,
            sample_rate: 48000,
            samples: 2,
        });
        drop(c);
        slot.stop();
        VideoCaptureSlot::default()
            .start(&video, Logger::default())
            .unwrap();
        assert!(slot.start(&video, Logger::default()).is_err());
        assert!(VideoCaptureSlot::default()
            .start(&path, Logger::default())
            .is_err());

        let f = std::fs::read(&path).unwrap();
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(f[..16], audio_file_header());
        let mut at = 16;
        let mut got = Vec::new();
        while at < f.len() {
            let h = AudioRecordHeader::decode(&f[at..]).unwrap();
            let start = at + AUDIO_RECORD_HEADER_LEN;
            got.push((h, f[start..start + h.length as usize].to_vec()));
            at = start + h.length as usize;
        }
        assert_eq!(at, f.len());
        let kinds: Vec<(u8, u8, u32)> = got
            .iter()
            .map(|(h, _)| (h.kind, h.flags, h.sequence))
            .collect();
        assert_eq!(
            kinds,
            vec![
                (audio_kind::START, 0, 0),
                (
                    audio_kind::HEADER,
                    audio_flag::DECODED | audio_flag::REPEATED,
                    1
                ),
                (audio_kind::DATAGRAM, 0, 2),
                (audio_kind::FRAME, audio_flag::DECODED, 3),
                (
                    audio_kind::FRAME,
                    audio_flag::DECODED | audio_flag::CONCEALED | audio_flag::DECODE_ERROR,
                    4
                ),
            ]
        );
        assert_eq!((got[1].0.channels, got[1].0.layout), (2, 1));
        assert_eq!(got[1].1, header);
        let dg = &got[2].0;
        assert_eq!(
            (
                dg.packet_index,
                dg.frame_index,
                dg.codec,
                dg.payload_offset,
                dg.unit_word
            ),
            (7, 9, 5, 20, 0x0002_5021)
        );
        assert_eq!(got[2].1, d);
        let fr = &got[3].0;
        assert_eq!(
            (
                fr.frame_index,
                fr.peak,
                fr.rms,
                fr.samples,
                fr.packet_len,
                fr.channels
            ),
            (9, 300, 187, 2, 3, 2)
        );
        assert_eq!(got[3].1, [1, 2, 3]);
        assert!(got[4].1.is_empty());
        let h = AudioRecordHeader {
            length: 5,
            frame_index: 65535,
            kind: 2,
            flags: 0x3f,
            packet_index: 513,
            codec: 5,
            payload_offset: 23,
            unit_word: 0xdead_beef,
            peak: 32767,
            rms: 1234,
            samples: 960,
            packet_len: 321,
            channels: 2,
            layout: 1,
            sequence: 77,
            time_us: 1 << 41,
        };
        assert_eq!(AudioRecordHeader::decode(&h.encode()), Some(h));
    }
}
