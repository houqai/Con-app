use std::collections::VecDeque;
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::Arc;

use super::h26x::{self, CodecFamily, ParameterSets, SliceInfo, SliceKind};
use crate::fec;
use crate::log::Logger;
use crate::transport::loss::MAX_FRAME_UNITS;
use crate::transport::packet::{be16, MediaHeader, UnitWord};
use crate::transport::seq::{idx_after, idx_before};
use crate::Codec;

pub const REMEMBERED_REFERENCES: usize = 16;
pub const SAMPLE_PADDING: usize = 64;
pub const MAX_REFERENCE_DISTANCE: u32 = 15;
pub const WITHHOLD_KEYFRAME_AFTER_MS: u32 = 300;
pub const WITHHOLD_KEYFRAME_INTERVAL_MS: u32 = 2000;
pub const HIDE_KEYFRAME_AFTER_MS: u32 = 500;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum MissingReference {
    Withhold = 0,
    Repair = 1,
    #[default]
    Hide = 2,
}

impl MissingReference {
    fn from_u8(v: u8) -> Self {
        match v {
            0 => Self::Withhold,
            1 => Self::Repair,
            _ => Self::Hide,
        }
    }
}

#[derive(Clone, Debug)]
pub struct MissingReferenceSlot(Arc<AtomicU8>);

impl Default for MissingReferenceSlot {
    fn default() -> Self {
        Self::new(MissingReference::default())
    }
}

impl MissingReferenceSlot {
    pub fn new(policy: MissingReference) -> Self {
        Self(Arc::new(AtomicU8::new(policy as u8)))
    }

    pub fn set(&self, policy: MissingReference) {
        self.0.store(policy as u8, Ordering::Relaxed);
    }

    pub fn get(&self) -> MissingReference {
        MissingReference::from_u8(self.0.load(Ordering::Relaxed))
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VideoProfile {
    pub width: u32,
    pub height: u32,
    pub header: Vec<u8>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum SampleKind {
    ParameterSets = 0,
    Picture = 1,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VideoSample<'a> {
    pub kind: SampleKind,
    pub data: &'a [u8],
    pub padded: &'a [u8],
    pub frame_index: u16,
    pub frames_lost: u32,
    pub recovered: bool,
    pub fec_recovered: bool,
    pub keyframe: bool,
    pub unchecked: bool,
    pub decode_only: bool,
    pub codec: Codec,
    pub profile: u8,
    pub width: u32,
    pub height: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum DropReason {
    FecFailed = 1,
    ReferenceMissing = 2,
    WaitingForIdr = 3,
    InvalidFrame = 4,
}

pub trait VideoOutput {
    fn sample(&mut self, sample: &VideoSample<'_>) -> bool;
    fn report_corrupt(&mut self, start: u16, end: u16);
    fn request_idr(&mut self);
    fn fec_failure(&mut self, _frame_index: u16, _idr_requested: bool) {}
    fn dropped(&mut self, _frame_index: u16, _reason: DropReason) {}
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VideoConfig {
    pub codec: Codec,
    pub idr_on_fec_failure: bool,
    pub missing_reference: MissingReference,
    pub frame_rate: u32,
}

impl VideoConfig {
    pub fn new(codec: Codec) -> Self {
        Self {
            codec,
            idr_on_fec_failure: false,
            missing_reference: MissingReference::Hide,
            frame_rate: 60,
        }
    }

    fn frames(&self, ms: u32) -> u16 {
        let fps = if self.frame_rate == 0 {
            60
        } else {
            self.frame_rate
        };
        (u64::from(ms) * u64::from(fps))
            .div_ceil(1000)
            .clamp(1, u64::from(u16::MAX / 2)) as u16
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct VideoStats {
    pub packets: u64,
    pub packets_dropped: u64,
    pub units_received: u64,
    pub units_rejected: u64,
    pub units_late: u64,
    pub profile_switches: u64,
    pub frames_complete: u64,
    pub frames_fec_recovered: u64,
    pub frames_fec_failed: u64,
    pub frames_failed: u64,
    pub frames_delivered: u64,
    pub frames_rejected: u64,
    pub frames_skipped_waiting_idr: u64,
    pub frames_reference_missing: u64,
    pub frames_withheld: u64,
    pub withhold_periods: u64,
    pub frames_reference_repaired: u64,
    pub frames_hidden: u64,
    pub hide_runs: u64,
    pub frames_unchecked: u64,
    pub frames_lost: u64,
    pub corrupt_reports: u64,
    pub idr_requests: u64,
    pub bytes_delivered: u64,
}

#[derive(Debug)]
struct Frame {
    index: u16,
    valid: bool,
    k: usize,
    len: Option<usize>,
    units: Vec<Option<Vec<u8>>>,
    source_received: usize,
    fec_received: usize,
    flushed: bool,
}

struct Profile {
    profile: VideoProfile,
    sets: ParameterSets,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Remembered {
    frame: u16,
    pic_id: Option<i64>,
    reference: bool,
    tainted: bool,
    epoch: u32,
}

#[derive(Clone, Copy, Debug)]
struct Run {
    first: u16,
    count: u32,
    dropped: u32,
    numbering_broken: bool,
    last_request: Option<u16>,
}

impl Run {
    fn new(first: u16) -> Self {
        Self {
            first,
            count: 0,
            dropped: 0,
            numbering_broken: false,
            last_request: None,
        }
    }
}

pub struct VideoReceiver {
    config: VideoConfig,
    family: CodecFamily,
    profiles: Vec<Profile>,
    current_profile: Option<usize>,
    frame: Option<Frame>,
    last_complete: u16,
    references: VecDeque<Remembered>,
    prev_id: Option<(u32, i64)>,
    prev_frame: Option<u16>,
    stream_prev_id: Option<(u32, i64)>,
    waiting_idr: bool,
    lost_since_delivery: u32,
    missing_through: Option<u16>,
    withholding: Option<Run>,
    hiding: Option<Run>,
    epoch: u32,
    stats: VideoStats,
    log: Logger,
}

impl std::fmt::Debug for VideoReceiver {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VideoReceiver")
            .field("profiles", &self.profiles.len())
            .field("current_profile", &self.current_profile)
            .field("last_complete", &self.last_complete)
            .finish_non_exhaustive()
    }
}

fn padded(data: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(data.len() + SAMPLE_PADDING);
    v.extend_from_slice(data);
    v.resize(data.len() + SAMPLE_PADDING, 0);
    v
}

impl VideoReceiver {
    pub fn new(config: VideoConfig, profiles: Vec<VideoProfile>, log: Logger) -> Self {
        let family = CodecFamily::from(config.codec);
        let profiles = profiles
            .into_iter()
            .map(|p| Profile {
                sets: ParameterSets::parse(family, &p.header),
                profile: p,
            })
            .collect();
        Self {
            config,
            family,
            profiles,
            current_profile: None,
            frame: None,
            last_complete: 0,
            references: VecDeque::with_capacity(REMEMBERED_REFERENCES),
            prev_id: None,
            prev_frame: None,
            stream_prev_id: None,
            waiting_idr: false,
            lost_since_delivery: 0,
            missing_through: None,
            withholding: None,
            hiding: None,
            epoch: 0,
            stats: VideoStats::default(),
            log,
        }
    }

    pub fn stats(&self) -> VideoStats {
        self.stats
    }

    pub fn last_complete(&self) -> u16 {
        self.last_complete
    }

    pub fn current_profile(&self) -> Option<(u8, &VideoProfile)> {
        let i = self.current_profile?;
        Some((i as u8, &self.profiles.get(i)?.profile))
    }

    pub fn waiting_for_idr(&self) -> bool {
        self.waiting_idr
    }

    pub fn withholding(&self) -> bool {
        self.withholding.is_some()
    }

    pub fn hiding(&self) -> bool {
        self.hiding.is_some()
    }

    pub fn missing_reference(&self) -> MissingReference {
        self.config.missing_reference
    }

    pub fn set_missing_reference(&mut self, policy: MissingReference) {
        self.config.missing_reference = policy;
    }

    pub fn on_packet(&mut self, header: &MediaHeader, payload: &[u8], out: &mut dyn VideoOutput) {
        let UnitWord::Video {
            unit_index,
            units_total,
            fec_units,
        } = header.unit_word
        else {
            return;
        };
        self.stats.packets += 1;
        let Some(asi) = header.adaptive_stream else {
            self.stats.packets_dropped += 1;
            return;
        };
        let f = header.frame_index;
        if let Some(cur) = &self.frame {
            if idx_before(f, cur.index) {
                self.stats.packets_dropped += 1;
                return;
            }
        }
        let profile = usize::from(asi);
        if self.current_profile != Some(profile) {
            if profile >= self.profiles.len() {
                self.stats.packets_dropped += 1;
                return;
            }
            if self.frame.as_ref().is_some_and(|cur| cur.index != f) {
                self.close_frame(out);
            }
            self.switch_profile(profile, f, out);
        }
        if self.frame.as_ref().is_none_or(|cur| cur.index != f) {
            self.close_frame(out);
            let next = self.last_complete.wrapping_add(1);
            if idx_after(f, next) {
                self.report(next, f.wrapping_sub(1), out);
            }
            self.frame = Some(Self::new_frame(f, units_total, fec_units));
        }
        self.store(unit_index, payload, out);
    }

    fn report(&mut self, start: u16, end: u16, out: &mut dyn VideoOutput) {
        self.stats.corrupt_reports += 1;
        self.log
            .debug(|| format!("video: corrupt frames {start}–{end} reported"));
        out.report_corrupt(start, end);
    }

    fn switch_profile(&mut self, index: usize, frame_index: u16, out: &mut dyn VideoOutput) {
        self.current_profile = Some(index);
        self.stats.profile_switches += 1;
        self.references.clear();
        self.prev_id = None;
        self.prev_frame = None;
        self.stream_prev_id = None;
        let p = &self.profiles[index];
        self.log.info(|| {
            format!(
                "video: profile {index} ({}x{}){}",
                p.profile.width,
                p.profile.height,
                if p.sets.readable() {
                    ""
                } else {
                    ", parameter sets unreadable"
                }
            )
        });
        let buf = padded(&p.profile.header);
        let n = p.profile.header.len();
        let sample = VideoSample {
            kind: SampleKind::ParameterSets,
            data: &buf[..n],
            padded: &buf,
            frame_index,
            frames_lost: 0,
            recovered: false,
            fec_recovered: false,
            keyframe: false,
            unchecked: false,
            decode_only: false,
            codec: self.config.codec,
            profile: index as u8,
            width: p.profile.width,
            height: p.profile.height,
        };
        let _ = out.sample(&sample);
    }

    fn new_frame(index: u16, total: u16, fec: u16) -> Frame {
        let n = usize::from(total);
        let m = usize::from(fec);
        let valid = n > m && n <= usize::from(MAX_FRAME_UNITS);
        Frame {
            index,
            valid,
            k: n.saturating_sub(m),
            len: None,
            units: if valid { vec![None; n] } else { Vec::new() },
            source_received: 0,
            fec_received: 0,
            flushed: false,
        }
    }

    fn store(&mut self, unit: u16, payload: &[u8], out: &mut dyn VideoOutput) {
        let Some(fr) = self.frame.as_mut() else {
            return;
        };
        if !fr.valid {
            self.stats.units_rejected += 1;
            return;
        }
        let u = usize::from(unit);
        let n = fr.units.len();
        let source = u < fr.k;
        let unit_len = if source {
            if payload.len() < 2 {
                None
            } else {
                Some(payload.len() + usize::from(be16(payload, 0)))
            }
        } else {
            Some(payload.len())
        };
        let ok = u < n
            && !payload.is_empty()
            && unit_len.is_some()
            && fr.units[u].is_none()
            && match fr.len {
                Some(l) => payload.len() <= l,
                None => unit_len != Some(0),
            };
        if !ok {
            self.stats.units_rejected += 1;
            return;
        }
        if fr.len.is_none() {
            fr.len = unit_len;
        }
        fr.units[u] = Some(payload.to_vec());
        if source {
            fr.source_received += 1;
        } else {
            fr.fec_received += 1;
        }
        self.stats.units_received += 1;
        if fr.flushed {
            self.stats.units_late += 1;
            return;
        }
        if fr.source_received + fr.fec_received >= fr.k || u == n - 1 {
            self.flush(out);
        }
    }

    fn close_frame(&mut self, out: &mut dyn VideoOutput) {
        if self.frame.as_ref().is_some_and(|f| !f.flushed) {
            self.flush(out);
        }
    }

    fn flush(&mut self, out: &mut dyn VideoOutput) {
        let Some(fr) = self.frame.as_mut() else {
            return;
        };
        fr.flushed = true;
        let index = fr.index;
        if !fr.valid {
            self.stats.frames_failed += 1;
            self.log
                .debug(|| format!("video: frame {index} dropped: invalid unit counts"));
            out.dropped(index, DropReason::InvalidFrame);
            return;
        }
        let k = fr.k;
        let len = fr.len.unwrap_or(0);
        let mut fec_recovered = false;
        let picture: Option<Vec<u8>> = if fr.source_received == k {
            self.stats.frames_complete += 1;
            Some(assemble(fr.units[..k].iter().map(|u| u.as_deref())))
        } else if fr.source_received + fr.fec_received >= k {
            match recover_units(fr, len) {
                Ok(sources) => {
                    fec_recovered = true;
                    self.stats.frames_fec_recovered += 1;
                    Some(assemble(sources.iter().map(|u| Some(u.as_slice()))))
                }
                Err(e) => {
                    self.log
                        .debug(|| format!("video: FEC of frame {index} failed: {e}"));
                    None
                }
            }
        } else {
            None
        };
        match picture {
            Some(p) => self.deliver_picture(index, p, fec_recovered, out),
            None => self.fec_failed(index, out),
        }
    }

    fn fec_failed(&mut self, index: u16, out: &mut dyn VideoOutput) {
        self.stats.frames_fec_failed += 1;
        let first = self.last_complete.wrapping_add(1);
        self.report(first, index, out);
        let mut requested = false;
        if self.config.idr_on_fec_failure && !self.waiting_idr {
            out.request_idr();
            self.stats.idr_requests += 1;
            self.waiting_idr = true;
            requested = true;
        }
        out.fec_failure(index, requested);
        out.dropped(index, DropReason::FecFailed);
        let counted_from = match self.missing_through {
            Some(m) if !idx_before(m, first) => m.wrapping_add(1),
            _ => first,
        };
        let lost = u32::from(index.wrapping_sub(counted_from)) + 1;
        self.lost_since_delivery += lost;
        self.stats.frames_lost += u64::from(lost);
        self.log.debug(|| {
            format!("video: frame {index} lost (FEC failed), {lost} frames since last complete")
        });
        self.run_keyframe(index, out);
    }

    fn deliver_picture(
        &mut self,
        index: u16,
        picture: Vec<u8>,
        fec_recovered: bool,
        out: &mut dyn VideoOutput,
    ) {
        let profile_index = self.current_profile.unwrap_or(0);
        let no_sets = ParameterSets::default();
        let sets = self
            .profiles
            .get(profile_index)
            .map_or(&no_sets, |p| &p.sets);
        let family = self.family;
        let slice_nals: Vec<std::ops::Range<usize>> = h26x::nal_units(&picture)
            .into_iter()
            .filter(|r| {
                h26x::nal_type(family, &picture[r.clone()])
                    .is_some_and(|t| h26x::is_slice(family, t))
            })
            .collect();
        let parsed: Vec<Option<SliceInfo>> = slice_nals
            .iter()
            .map(|r| h26x::parse_slice(family, sets, &picture[r.clone()]))
            .filter(|s| !s.as_ref().is_some_and(|s| s.dependent))
            .collect();
        let slice = parsed
            .iter()
            .flatten()
            .find(|s| s.kind == SliceKind::P)
            .cloned()
            .or_else(|| parsed.first().cloned().flatten());
        let all_intra = !parsed.is_empty()
            && parsed
                .iter()
                .all(|s| s.as_ref().is_some_and(|s| s.kind == SliceKind::I));
        let nal_type = slice_nals
            .first()
            .and_then(|r| h26x::nal_type(family, &picture[r.clone()]));
        let keyframe = nal_type.is_some_and(|t| h26x::is_keyframe_type(family, t));

        let this_id = slice.as_ref().and_then(|s| self.unwrap_id(self.prev_id, s));
        let stream_id = slice
            .as_ref()
            .and_then(|s| self.unwrap_id(self.stream_prev_id, s));
        if let Some(s) = &slice {
            if let (Some(raw), Some(id)) = (s.pic_id, stream_id) {
                if self.advances_prev_id(s) {
                    self.stream_prev_id = Some((raw, id));
                }
            }
        }

        let policy = self.config.missing_reference;
        if policy != MissingReference::Hide {
            self.hiding = None;
        }
        let mut renumbered = false;
        let (mut picture, recovered) = if self.waiting_idr {
            let intra = keyframe || all_intra;
            if !intra {
                self.stats.frames_skipped_waiting_idr += 1;
                out.dropped(index, DropReason::WaitingForIdr);
                return;
            }
            self.waiting_idr = false;
            (picture, false)
        } else {
            let checked = match policy {
                MissingReference::Withhold => {
                    if !keyframe && !self.numbering_kept(index, slice.as_ref(), this_id, stream_id)
                    {
                        self.reference_missing(index, true, out);
                        return;
                    }
                    self.references_complete(index, slice.as_ref(), this_id)
                        .then_some((picture, false))
                }
                MissingReference::Repair | MissingReference::Hide => {
                    renumbered = policy == MissingReference::Hide
                        && !keyframe
                        && !self.numbering_kept(index, slice.as_ref(), this_id, stream_id);
                    self.check_references(index, picture, slice.as_ref(), this_id, sets)
                }
            };
            match checked {
                Some(v) => v,
                None => {
                    self.reference_missing(index, renumbered, out);
                    return;
                }
            }
        };
        let epoch = if renumbered {
            self.epoch.wrapping_add(1)
        } else {
            self.epoch
        };
        let tainted = !keyframe
            && (recovered
                || self.references_tainted(index, slice.as_ref(), this_id, all_intra, epoch));
        let decode_only = policy == MissingReference::Hide && tainted;
        if recovered {
            self.stats.frames_reference_repaired += 1;
            self.log
                .debug(|| format!("video: frame {index} reference repaired"));
        }
        if let Some(s) = &slice {
            if let (Some(raw), Some(id)) = (s.pic_id, this_id) {
                if self.advances_prev_id(s) {
                    self.prev_id = Some((raw, id));
                    self.prev_frame = Some(index);
                }
            }
        }
        let unchecked = !keyframe
            && match &slice {
                None => true,
                Some(s) => match s.kind {
                    SliceKind::I => false,
                    SliceKind::Other => true,
                    SliceKind::P => match family {
                        CodecFamily::H264 => s.reference.is_none(),
                        CodecFamily::H265 => !s.rps_known || !s.uses_references(),
                    },
                },
            };
        if unchecked {
            if self.stats.frames_unchecked == 0 {
                self.log.info(|| {
                    format!(
                        "video: frame {index}: references not readable ({}); delivering pictures unchecked",
                        match &slice {
                            None => "slice header not parsed".to_string(),
                            Some(s) => format!("NAL type {}", s.nal_type),
                        }
                    )
                });
            }
            self.stats.frames_unchecked += 1;
        }

        let (width, height) = self
            .profiles
            .get(profile_index)
            .map_or((0, 0), |p| (p.profile.width, p.profile.height));
        let n = picture.len();
        picture.resize(n + SAMPLE_PADDING, 0);
        let sample = VideoSample {
            kind: SampleKind::Picture,
            data: &picture[..n],
            padded: &picture,
            frame_index: index,
            frames_lost: self.lost_since_delivery,
            recovered,
            fec_recovered,
            keyframe,
            unchecked,
            decode_only,
            codec: self.config.codec,
            profile: profile_index as u8,
            width,
            height,
        };
        let accepted = out.sample(&sample);
        self.lost_since_delivery = 0;
        self.stats.frames_delivered += 1;
        self.stats.bytes_delivered += n as u64;
        self.epoch = epoch;
        if decode_only {
            self.stats.frames_hidden += 1;
            self.log.debug(|| {
                format!(
                    "video: frame {index} decoded hidden ({})",
                    if recovered {
                        "reference rewritten"
                    } else {
                        "references a corrupted picture"
                    }
                )
            });
            self.not_shown(index, true, renumbered, out);
        } else if accepted {
            if let Some(r) = self.hiding.take() {
                self.log.info(|| {
                    format!(
                        "video: display resumes at frame {index} ({}) after {} pictures hidden and {} not delivered from frame {}",
                        if keyframe { "keyframe" } else { "all references genuine" },
                        r.count,
                        r.dropped,
                        r.first
                    )
                });
            }
        }
        if accepted {
            if let Some(w) = self.withholding.take() {
                self.log.info(|| {
                    format!(
                        "video: delivery resumes at frame {index} ({}) after {} pictures withheld from frame {}",
                        if keyframe { "keyframe" } else { "all references present" },
                        w.count,
                        w.first
                    )
                });
            }
            if keyframe {
                self.references.clear();
            } else if let (Some(s), Some(id)) = (&slice, this_id) {
                if family == CodecFamily::H265 && s.rps_known && s.long_terms.is_some() {
                    self.keep_only_rps(s, id);
                }
            }
            if self.references.len() == REMEMBERED_REFERENCES {
                self.references.pop_back();
            }
            self.references.push_front(Remembered {
                frame: index,
                pic_id: this_id,
                reference: slice.as_ref().is_none_or(|s| s.is_reference),
                tainted,
                epoch,
            });
            self.last_complete = index;
        } else {
            self.stats.frames_rejected += 1;
        }
    }

    fn reference_missing(&mut self, index: u16, numbering_broken: bool, out: &mut dyn VideoOutput) {
        self.stats.frames_reference_missing += 1;
        self.lost_since_delivery += 1;
        self.stats.frames_lost += 1;
        self.missing_through = Some(index);
        out.dropped(index, DropReason::ReferenceMissing);
        let policy = self.config.missing_reference;
        if policy != MissingReference::Withhold {
            self.log
                .debug(|| format!("video: frame {index} dropped, reference missing"));
            if policy == MissingReference::Hide {
                self.not_shown(index, false, numbering_broken, out);
            }
            return;
        }
        self.stats.frames_withheld += 1;
        if numbering_broken && !self.withholding.is_some_and(|w| w.numbering_broken) {
            self.log.info(|| {
                format!(
                    "video: frame {index}: too many frames since the last picture the decoder got (frame {}) for its picture numbering; withheld until a keyframe",
                    self.prev_frame.map_or("none".to_string(), |f| f.to_string())
                )
            });
        }
        match &mut self.withholding {
            Some(w) => {
                w.count += 1;
                w.numbering_broken |= numbering_broken;
            }
            None => {
                self.stats.withhold_periods += 1;
                self.withholding = Some(Run {
                    count: 1,
                    numbering_broken,
                    ..Run::new(index)
                });
                self.log.info(|| {
                    format!(
                        "video: frame {index} uses a picture the decoder does not have; pictures are withheld until one has all its references"
                    )
                });
            }
        }
        self.log
            .debug(|| format!("video: frame {index} withheld, reference missing"));
        self.run_keyframe(index, out);
    }

    fn not_shown(
        &mut self,
        index: u16,
        hidden: bool,
        numbering_broken: bool,
        out: &mut dyn VideoOutput,
    ) {
        let run = match &mut self.hiding {
            Some(r) => r,
            None => {
                self.stats.hide_runs += 1;
                self.log.info(|| {
                    format!(
                        "video: frame {index} {}; the picture shown is kept until one whose references are all genuine",
                        if hidden {
                            "decoded hidden (its content is wrong)"
                        } else {
                            "not delivered (reference missing)"
                        }
                    )
                });
                self.hiding.insert(Run::new(index))
            }
        };
        if hidden {
            run.count += 1;
        } else {
            run.dropped += 1;
        }
        if numbering_broken && !run.numbering_broken {
            run.numbering_broken = true;
            self.log.info(|| {
                format!(
                    "video: frame {index}: too many frames since the last picture the decoder got for its picture numbering; hidden until a keyframe"
                )
            });
        }
        self.run_keyframe(index, out);
    }

    fn run_keyframe(&mut self, index: u16, out: &mut dyn VideoOutput) {
        let (after_ms, what) = if self.withholding.is_some() {
            (WITHHOLD_KEYFRAME_AFTER_MS, "withheld")
        } else {
            (HIDE_KEYFRAME_AFTER_MS, "hidden")
        };
        let after = self.config.frames(after_ms);
        let interval = self.config.frames(WITHHOLD_KEYFRAME_INTERVAL_MS);
        let Some(w) = self.withholding.as_mut().or(self.hiding.as_mut()) else {
            return;
        };
        if self.waiting_idr || !(w.numbering_broken || index.wrapping_sub(w.first) >= after) {
            return;
        }
        if w.last_request
            .is_some_and(|last| index.wrapping_sub(last) < interval)
        {
            return;
        }
        w.last_request = Some(index);
        let w = *w;
        self.stats.idr_requests += 1;
        out.request_idr();
        self.log.info(|| {
            format!(
                "video: keyframe requested at frame {index}, {} pictures {what} since frame {}{}",
                w.count,
                w.first,
                if w.dropped > 0 {
                    format!(", {} not delivered", w.dropped)
                } else {
                    String::new()
                }
            )
        });
    }

    fn numbering_kept(
        &self,
        index: u16,
        slice: Option<&SliceInfo>,
        this_id: Option<i64>,
        stream_id: Option<i64>,
    ) -> bool {
        let Some(s) = slice else {
            return true;
        };
        if let (Some(a), Some(b)) = (this_id, stream_id) {
            if a != b {
                return false;
            }
        }
        let m = s.pic_id_modulus;
        let limit = match self.family {
            CodecFamily::H265 => m / 2,
            CodecFamily::H264 => m.saturating_sub(1),
        };
        match self.prev_frame {
            Some(prev) if m > 0 => u32::from(index.wrapping_sub(prev)) <= limit,
            _ => true,
        }
    }

    fn references_complete(
        &self,
        index: u16,
        slice: Option<&SliceInfo>,
        this_id: Option<i64>,
    ) -> bool {
        let Some(s) = slice.filter(|s| s.kind == SliceKind::P) else {
            return true;
        };
        if self.family == CodecFamily::H264 {
            let Some(first) = s.reference else {
                return true;
            };
            let (frame, pic_id) = h264_reference(index, first, this_id);
            return self.remembered(frame, pic_id);
        }
        if !s.rps_known {
            return true;
        }
        let negatives = s.negatives.iter().enumerate().all(|(i, &(d, used))| {
            !used || {
                self.remembered(preceding_frame(index, i), this_id.map(|t| t + i64::from(d)))
            }
        });
        let positives = this_id.is_none_or(|t| {
            s.positives
                .iter()
                .all(|&(d, used)| !used || self.remembered(index, Some(t + i64::from(d))))
        });
        let long_terms =
            s.long_terms.iter().flatten().all(|l| {
                !l.used || self.long_term_present(this_id, s.pic_id_modulus, l) != Some(None)
            });
        negatives && positives && long_terms
    }

    fn references_tainted(
        &self,
        index: u16,
        slice: Option<&SliceInfo>,
        this_id: Option<i64>,
        all_intra: bool,
        epoch: u32,
    ) -> bool {
        let bad = |e: Option<&Remembered>| e.is_none_or(|e| e.tainted || e.epoch != epoch);
        let unknown = || {
            self.references
                .iter()
                .filter(|e| e.reference)
                .any(|e| e.tainted || e.epoch != epoch)
        };
        if all_intra {
            return false;
        }
        let Some(s) = slice else {
            return unknown();
        };
        match s.kind {
            SliceKind::I => return false,
            SliceKind::Other => return unknown(),
            SliceKind::P => {}
        }
        if self.family == CodecFamily::H264 {
            let Some(first) = s.reference else {
                return unknown();
            };
            let (frame, pic_id) = h264_reference(index, first, this_id);
            return bad(self.entry(frame, pic_id));
        }
        if !s.rps_known || !s.uses_references() {
            return unknown();
        }
        let negatives = s
            .negatives
            .iter()
            .enumerate()
            .filter(|(_, n)| n.1)
            .any(|(i, &(d, _))| {
                bad(self.entry(preceding_frame(index, i), this_id.map(|t| t + i64::from(d))))
            });
        let positives = s
            .positives
            .iter()
            .filter(|p| p.1)
            .any(|&(d, _)| match this_id {
                Some(t) => bad(self.entry(index, Some(t + i64::from(d)))),
                None => unknown(),
            });
        let long_terms = s.long_terms.iter().flatten().filter(|l| l.used).any(|l| {
            match self.long_term_present(this_id, s.pic_id_modulus, l) {
                Some(Some(poc)) => bad(self.entry(index, Some(poc))),
                Some(None) => true,
                None => unknown(),
            }
        });
        negatives || positives || long_terms
    }

    fn unwrap_id(&self, prev_id: Option<(u32, i64)>, s: &SliceInfo) -> Option<i64> {
        let raw = i64::from(s.pic_id?);
        let m = i64::from(s.pic_id_modulus);
        if m == 0 {
            return None;
        }
        match self.family {
            CodecFamily::H265 => {
                let reset =
                    (16..=20).contains(&s.nal_type) || (s.nal_type == 21 && prev_id.is_none());
                let Some((prev_lsb, prev)) = prev_id.filter(|_| !reset) else {
                    return Some(raw);
                };
                let prev_lsb = i64::from(prev_lsb);
                let prev_msb = prev - prev_lsb;
                let msb = if raw < prev_lsb && prev_lsb - raw >= m / 2 {
                    prev_msb + m
                } else if raw > prev_lsb && raw - prev_lsb > m / 2 {
                    prev_msb - m
                } else {
                    prev_msb
                };
                Some(msb + raw)
            }
            CodecFamily::H264 => {
                let Some((prev_raw, prev)) = prev_id.filter(|_| s.nal_type != 5) else {
                    return Some(raw);
                };
                Some(prev + (raw - i64::from(prev_raw)).rem_euclid(m))
            }
        }
    }

    fn advances_prev_id(&self, s: &SliceInfo) -> bool {
        match self.family {
            CodecFamily::H264 => true,
            CodecFamily::H265 => {
                let t = s.nal_type;
                s.temporal_id == 0 && !(6..=9).contains(&t) && !(t <= 14 && t.is_multiple_of(2))
            }
        }
    }

    fn keep_only_rps(&mut self, s: &SliceInfo, poc: i64) {
        let m = i64::from(s.pic_id_modulus);
        let st: Vec<i64> = s
            .negatives
            .iter()
            .chain(&s.positives)
            .map(|&(d, _)| poc + i64::from(d))
            .collect();
        let lts = s.long_terms.as_deref().unwrap_or(&[]);
        self.references.retain(|e| {
            let Some(id) = e.pic_id else {
                return true;
            };
            st.contains(&id)
                || lts.iter().any(|l| match l.msb_cycle {
                    Some(c) => long_term_poc(poc, m, l.poc_lsb, c) == id,
                    None => m > 0 && id.rem_euclid(m) == i64::from(l.poc_lsb),
                })
        });
    }

    fn remembered(&self, frame: u16, pic_id: Option<i64>) -> bool {
        self.entry(frame, pic_id).is_some()
    }

    fn entry(&self, frame: u16, pic_id: Option<i64>) -> Option<&Remembered> {
        self.references
            .iter()
            .filter(|e| e.reference)
            .find(|e| match (e.pic_id, pic_id) {
                (Some(a), Some(b)) => a == b,
                _ => e.frame == frame,
            })
    }

    fn long_term_present(
        &self,
        this: Option<i64>,
        modulus: u32,
        l: &h26x::LongTermRef,
    ) -> Option<Option<i64>> {
        let this = this?;
        let m = i64::from(modulus);
        if m == 0 {
            return None;
        }
        let mut ids = self
            .references
            .iter()
            .filter(|e| e.reference)
            .filter_map(|e| e.pic_id);
        Some(match l.msb_cycle {
            Some(c) => {
                let want = long_term_poc(this, m, l.poc_lsb, c);
                ids.find(|&id| id == want)
            }
            None => ids
                .filter(|id| id.rem_euclid(m) == i64::from(l.poc_lsb))
                .max(),
        })
    }

    fn check_references(
        &self,
        index: u16,
        picture: Vec<u8>,
        slice: Option<&SliceInfo>,
        this_id: Option<i64>,
        sets: &ParameterSets,
    ) -> Option<(Vec<u8>, bool)> {
        let Some(s) = slice.filter(|s| s.kind == SliceKind::P) else {
            return Some((picture, false));
        };
        if self.family == CodecFamily::H264 {
            let Some(first) = s.reference else {
                return Some((picture, false));
            };
            let (frame, pic_id) = h264_reference(index, first, this_id);
            return self.remembered(frame, pic_id).then_some((picture, false));
        }
        if !s.rps_known {
            return Some((picture, false));
        }
        let present = |i: usize| {
            self.remembered(
                preceding_frame(index, i),
                this_id.map(|t| t + i64::from(s.negatives[i].0)),
            )
        };
        let n = s.negatives.len();
        let lts: &[h26x::LongTermRef] = s.long_terms.as_deref().unwrap_or(&[]);
        let lt_state: Vec<Option<Option<i64>>> = lts
            .iter()
            .map(|l| self.long_term_present(this_id, s.pic_id_modulus, l))
            .collect();
        let positive_missing = this_id.is_some_and(|t| {
            s.positives
                .iter()
                .any(|&(d, u)| u && !self.remembered(index, Some(t + i64::from(d))))
        });
        if positive_missing {
            return None;
        }
        let mut used: Vec<bool> = s.negatives.iter().map(|&(_, u)| u).collect();
        let mut used_lt: Vec<bool> = lts.iter().map(|l| l.used).collect();
        let mut changed = false;
        let limit = n.min(MAX_REFERENCE_DISTANCE as usize + 1);
        let mut from = 0;
        if let Some(first) = s.reference.map(|r| r as usize) {
            if !present(first) {
                from = first + 1;
                match (from..limit).find(|&i| present(i)) {
                    Some(pick) => {
                        for u in used.iter_mut().take(pick) {
                            *u = false;
                        }
                        used[pick] = true;
                    }
                    None => used.iter_mut().for_each(|u| *u = false),
                }
                changed = true;
            }
        }
        for (i, u) in used.iter_mut().enumerate() {
            if *u && !present(i) {
                *u = false;
                changed = true;
            }
        }
        for (u, state) in used_lt.iter_mut().zip(&lt_state) {
            if *u && *state == Some(None) {
                *u = false;
                changed = true;
            }
        }
        let positives_used = s.positives.iter().any(|p| p.1);
        if !used.iter().any(|&u| u) && !used_lt.iter().any(|&u| u) && !positives_used {
            if let Some(pick) = (from..limit).find(|&i| present(i)) {
                used[pick] = true;
            } else {
                let pick = lts
                    .iter()
                    .zip(&lt_state)
                    .enumerate()
                    .filter(|(_, (l, _))| l.used_flag_position.is_some())
                    .filter_map(|(j, (_, st))| st.flatten().map(|poc| (j, poc)))
                    .max_by_key(|&(_, poc)| poc)
                    .map(|(j, _)| j)?;
                used_lt[pick] = true;
            }
            changed = true;
        }
        if !changed {
            return Some((picture, false));
        }
        let count = |st: &[bool], lt: &[bool]| {
            st.iter().chain(lt).filter(|&&u| u).count() + usize::from(positives_used)
        };
        let before = count(
            &s.negatives.iter().map(|n| n.1).collect::<Vec<_>>(),
            &lts.iter().map(|l| l.used).collect::<Vec<_>>(),
        );
        if s.lists_modification_present == Some(true) && before != count(&used, &used_lt) {
            return None;
        }
        let lt_flags = s.long_terms.is_some().then_some(used_lt.as_slice());
        h26x::rewrite_references(sets, &picture, &used, lt_flags).map(|p| (p, true))
    }
}

fn preceding_frame(index: u16, distance: usize) -> u16 {
    index.wrapping_sub(distance as u16).wrapping_sub(1)
}

fn h264_reference(index: u16, first: u32, this_id: Option<i64>) -> (u16, Option<i64>) {
    (
        preceding_frame(index, first as usize),
        this_id.map(|t| t - i64::from(first) - 1),
    )
}

fn long_term_poc(this: i64, modulus: i64, poc_lsb: u32, cycle: u32) -> i64 {
    this - i64::from(cycle) * modulus - this.rem_euclid(modulus) + i64::from(poc_lsb)
}

fn assemble<'a>(units: impl Iterator<Item = Option<&'a [u8]>>) -> Vec<u8> {
    let mut out = Vec::new();
    for u in units.flatten() {
        if u.len() > 2 {
            out.extend_from_slice(&u[2..]);
        }
    }
    out
}

fn recover_units(fr: &Frame, len: usize) -> Result<Vec<Vec<u8>>, String> {
    if len < 2 {
        return Err("unit length below 2".into());
    }
    let mut units: Vec<Option<Vec<u8>>> = fr
        .units
        .iter()
        .map(|u| {
            u.as_ref().map(|d| {
                let mut v = d.clone();
                v.resize(len, 0);
                v
            })
        })
        .collect();
    fec::recover(&mut units, fr.k).map_err(|e| e.to_string())?;
    let mut sources = Vec::with_capacity(fr.k);
    for (j, slot) in units.into_iter().take(fr.k).enumerate() {
        match &fr.units[j] {
            Some(orig) => sources.push(orig.clone()),
            None => {
                let mut v = slot.ok_or("source unit not restored")?;
                let p = usize::from(be16(&v, 0));
                if p < len {
                    v.truncate(len - p);
                }
                sources.push(v);
            }
        }
    }
    Ok(sources)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn withholding_times_in_frames() {
        let at = |frame_rate| VideoConfig {
            frame_rate,
            ..VideoConfig::new(Codec::H265)
        };
        assert_eq!(at(60).frames(WITHHOLD_KEYFRAME_AFTER_MS), 18);
        assert_eq!(at(30).frames(WITHHOLD_KEYFRAME_AFTER_MS), 9);
        assert_eq!(at(0).frames(WITHHOLD_KEYFRAME_AFTER_MS), 18);
        assert_eq!(at(60).frames(WITHHOLD_KEYFRAME_INTERVAL_MS), 120);
        assert_eq!(at(60).frames(HIDE_KEYFRAME_AFTER_MS), 30);
        assert_eq!(at(30).frames(HIDE_KEYFRAME_AFTER_MS), 15);
    }

    #[test]
    fn missing_reference_slot_is_shared_between_clones() {
        let slot = MissingReferenceSlot::default();
        assert_eq!(slot.get(), MissingReference::Hide);
        let other = slot.clone();
        other.set(MissingReference::Repair);
        assert_eq!(slot.get(), MissingReference::Repair);
        other.set(MissingReference::Withhold);
        assert_eq!(slot.get(), MissingReference::Withhold);
        assert_eq!(MissingReference::from_u8(7), MissingReference::Hide);
    }
}
