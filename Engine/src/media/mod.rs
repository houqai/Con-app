pub mod audio;
pub mod bits;
pub mod capture;
pub mod effects;
pub mod feedback;
pub mod h26x;
#[cfg(feature = "opus")]
pub mod opus;
pub mod video;

use std::sync::{Arc, Mutex};

pub use audio::{AudioFrame, AudioHeader, AudioMode, AudioStats, HapticsFrame, HapticsMode};
pub use effects::{FeedbackEvent, IntensityKind};
pub use feedback::{ControllerState, FeedbackStats, Touch};
pub use video::{DropReason, SampleKind, VideoSample, VideoStats};

use crate::log::Logger;
use crate::stream::{StreamData, StreamDataSink, StreamInfoEvent};
use crate::sync::lock;
use crate::transport::packet::MediaKind;
use crate::transport::MediaPacket;
use crate::Codec;

pub trait MediaSink: Send + Sync {
    fn raw(&self, _data: &StreamData) {}

    fn video(&self, _sample: &VideoSample<'_>) -> bool {
        true
    }

    fn audio(&self, _frame: &AudioFrame<'_>) {}

    fn haptics(&self, _frame: &HapticsFrame<'_>) {}
}

pub struct RawSink(pub StreamDataSink);

impl std::fmt::Debug for RawSink {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("RawSink")
    }
}

impl MediaSink for RawSink {
    fn raw(&self, data: &StreamData) {
        (self.0)(data.clone());
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MediaConfig {
    pub codec: Codec,
    pub max_fps: u32,
    pub idr_on_fec_failure: bool,
    pub decode_audio: bool,
    pub audio_mode: AudioMode,
    pub haptics_mode: HapticsMode,
}

impl MediaConfig {
    pub fn console(codec: Codec, max_fps: u32) -> Self {
        Self {
            codec,
            max_fps,
            idr_on_fec_failure: false,
            decode_audio: cfg!(feature = "opus"),
            audio_mode: AudioMode::Packed,
            haptics_mode: HapticsMode::Console,
        }
    }

    pub fn cloud(ps5: bool, codec: Codec, max_fps: u32) -> Self {
        Self {
            audio_mode: if ps5 {
                AudioMode::SingleUnit
            } else {
                AudioMode::Packed
            },
            haptics_mode: if ps5 {
                HapticsMode::Cloud
            } else {
                HapticsMode::Console
            },
            ..Self::console(codec, max_fps)
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct MediaStats {
    pub video: VideoStats,
    pub audio: AudioStats,
    pub feedback: FeedbackStats,
    pub measured_bitrate: u64,
    pub running_bitrate: u64,
    pub audio_decoded: bool,
}

pub trait MediaActions {
    fn report_corrupt(&mut self, start: u16, end: u16);
    fn request_idr(&mut self);
    fn fec_failure(&mut self, frame_index: u16, idr_requested: bool);
}

#[derive(Clone, Copy, Debug, Default)]
struct BitrateMeter {
    bytes: u64,
    pictures: u64,
}

impl BitrateMeter {
    fn value(&self, fps: u32) -> u64 {
        (self.bytes * 8 * u64::from(fps))
            .checked_div(self.pictures)
            .unwrap_or(0)
    }
}

pub struct MediaPipeline {
    config: MediaConfig,
    video: video::VideoReceiver,
    audio: audio::AudioReceiver,
    haptics: audio::HapticsReceiver,
    bitrate: BitrateMeter,
    measured_bitrate: u64,
    delivered_bytes_seen: u64,
    delivered_seen: u64,
    shared: Arc<Mutex<MediaStats>>,
    capture: capture::VideoCaptureSlot,
    audio_capture: capture::AudioCaptureSlot,
    missing_reference: video::MissingReferenceSlot,
    log: Logger,
}

impl std::fmt::Debug for MediaPipeline {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MediaPipeline")
            .field("config", &self.config)
            .finish_non_exhaustive()
    }
}

fn audio_receiver(config: &MediaConfig, raw: &[u8; 14], log: &Logger) -> audio::AudioReceiver {
    let header = AudioHeader::parse(raw).expect("14 bytes");
    log.info(|| {
        format!(
            "audio header: {} channels, {} bits, {} Hz, frame size {}, unknown {}",
            header.channels, header.bits, header.rate, header.frame_size, header.unknown
        )
    });
    let decoder = if !config.decode_audio {
        None
    } else if !header.is_usable() {
        log.warn(|| "audio: header out of range; passing Opus packets through undecoded".into());
        None
    } else {
        make_decoder(&header, log)
    };
    audio::AudioReceiver::new(header, config.audio_mode, decoder, log.clone())
}

#[cfg(feature = "opus")]
fn make_decoder(header: &AudioHeader, log: &Logger) -> Option<Box<dyn audio::AudioDecoder>> {
    match self::opus::OpusDecoder::new(header) {
        Ok(d) => Some(Box::new(d)),
        Err(e) => {
            log.warn(|| {
                format!("audio: opus decoder not created: {e}; passing packets through undecoded")
            });
            None
        }
    }
}

#[cfg(not(feature = "opus"))]
fn make_decoder(_header: &AudioHeader, log: &Logger) -> Option<Box<dyn audio::AudioDecoder>> {
    log.info(|| "audio: built without Opus; passing packets through undecoded".into());
    None
}

struct VideoOut<'a> {
    sink: &'a dyn MediaSink,
    actions: &'a mut dyn MediaActions,
    capture: Option<&'a capture::VideoCapture>,
    codec: Codec,
}

impl video::VideoOutput for VideoOut<'_> {
    fn sample(&mut self, sample: &VideoSample<'_>) -> bool {
        let accepted = self.sink.video(sample);
        if let Some(c) = self.capture {
            c.sample(sample, accepted);
        }
        accepted
    }

    fn dropped(&mut self, frame_index: u16, reason: DropReason) {
        if let Some(c) = self.capture {
            c.not_delivered(frame_index, reason, self.codec);
        }
    }

    fn report_corrupt(&mut self, start: u16, end: u16) {
        self.actions.report_corrupt(start, end);
    }

    fn request_idr(&mut self) {
        self.actions.request_idr();
    }

    fn fec_failure(&mut self, frame_index: u16, idr_requested: bool) {
        self.actions.fec_failure(frame_index, idr_requested);
    }
}

impl MediaPipeline {
    pub fn new(
        config: MediaConfig,
        info: &StreamInfoEvent,
        stats: Arc<Mutex<MediaStats>>,
        capture: capture::VideoCaptureSlot,
        audio_capture: capture::AudioCaptureSlot,
        missing_reference: video::MissingReferenceSlot,
        log: Logger,
    ) -> Self {
        let profiles = info
            .resolutions
            .iter()
            .map(|r| video::VideoProfile {
                width: r.width,
                height: r.height,
                header: r.video_header.clone(),
            })
            .collect();
        let video = video::VideoReceiver::new(
            video::VideoConfig {
                codec: config.codec,
                idr_on_fec_failure: config.idr_on_fec_failure,
                missing_reference: missing_reference.get(),
                frame_rate: config.max_fps,
            },
            profiles,
            log.clone(),
        );
        let audio = audio_receiver(&config, &info.audio_header, &log);
        let p = Self {
            config,
            video,
            audio,
            haptics: audio::HapticsReceiver::new(config.haptics_mode),
            bitrate: BitrateMeter::default(),
            measured_bitrate: 0,
            delivered_bytes_seen: 0,
            delivered_seen: 0,
            shared: stats,
            capture,
            audio_capture,
            missing_reference,
            log,
        };
        p.capture_audio_header(false);
        p.publish();
        p
    }

    pub fn reset_audio(&mut self, header: &[u8; 14]) {
        self.audio = audio_receiver(&self.config, header, &self.log);
        self.capture_audio_header(false);
        self.publish();
    }

    fn capture_audio_header(&self, repeated: bool) {
        if let Some(c) = self.audio_capture.current() {
            c.header(
                &self.audio.header().to_bytes(),
                self.audio.decodes(),
                self.audio.mode(),
                repeated,
            );
        }
    }

    pub fn on_connection_quality(&mut self) {
        self.measured_bitrate = self.bitrate.value(self.config.max_fps);
        self.bitrate = BitrateMeter::default();
        self.publish();
    }

    pub fn on_media(
        &mut self,
        p: &MediaPacket,
        sink: &dyn MediaSink,
        actions: &mut dyn MediaActions,
    ) {
        let payload = p.payload();
        match p.header.kind {
            MediaKind::Video => {
                let capture = self.capture.current();
                if let Some(c) = capture.as_deref().filter(|c| c.wants_parameter_sets()) {
                    if let Some((index, profile)) = self.video.current_profile() {
                        c.repeat_parameter_sets(
                            index,
                            profile.width,
                            profile.height,
                            self.config.codec,
                            &profile.header,
                        );
                    }
                }
                self.video
                    .set_missing_reference(self.missing_reference.get());
                let mut out = VideoOut {
                    sink,
                    actions,
                    capture: capture.as_deref(),
                    codec: self.config.codec,
                };
                self.video.on_packet(&p.header, payload, &mut out);
                let s = self.video.stats();
                if s.frames_delivered != self.delivered_seen {
                    self.bitrate.pictures += s.frames_delivered - self.delivered_seen;
                    self.bitrate.bytes += s.bytes_delivered - self.delivered_bytes_seen;
                    self.delivered_seen = s.frames_delivered;
                    self.delivered_bytes_seen = s.bytes_delivered;
                }
            }
            MediaKind::Audio => {
                let capture = self.audio_capture.current();
                if let Some(c) = capture.as_deref() {
                    if c.wants_header() {
                        self.capture_audio_header(true);
                    }
                    c.datagram(p);
                }
                self.audio.on_packet(&p.header, payload, &mut |f| {
                    sink.audio(f);
                    if let Some(c) = capture.as_deref() {
                        c.frame(f);
                    }
                });
            }
            MediaKind::Haptics => {
                if let Some(c) = self.audio_capture.current() {
                    c.datagram(p);
                }
                self.haptics
                    .on_packet(&p.header, payload, &mut |f| sink.haptics(f));
            }
        }
        self.publish();
    }

    pub fn stats(&self) -> MediaStats {
        let a = self.audio.stats();
        let h = self.haptics.stats();
        MediaStats {
            video: self.video.stats(),
            audio: AudioStats {
                haptics_datagrams: h.datagrams,
                haptics_frames: h.frames,
                haptics_dropped: h.dropped,
                ..a
            },
            feedback: FeedbackStats::default(),
            measured_bitrate: self.measured_bitrate,
            running_bitrate: self.bitrate.value(self.config.max_fps),
            audio_decoded: self.audio.decodes(),
        }
    }

    fn publish(&self) {
        let s = self.stats();
        let mut g = lock(&self.shared);
        let feedback = g.feedback;
        *g = MediaStats { feedback, ..s };
    }
}
