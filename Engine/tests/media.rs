mod common;
use common::hex;
use common::media::{
    audio_datagram, body, frame_units, left_frequency, opus_tone_packets, packed_audio_datagram,
    packed_haptics_datagram, tone, video_datagram,
};

use std::collections::HashSet;
use std::sync::{Arc, Mutex};

use con_engine::log::Logger;
use con_engine::media::audio::{
    AudioDecoder, AudioFrame, AudioHeader, AudioMode, AudioReceiver, HapticsMode, HapticsReceiver,
};
use con_engine::media::effects::{parse_pad_info, EffectsState, FeedbackEvent, IntensityKind};
use con_engine::media::feedback::{
    button, compress_orientation, decompress_orientation, diff_events, encode_state, parse_history,
    ControllerState, History, HistoryEvent, Touch,
};
use con_engine::media::h26x::{self, CodecFamily, SliceKind};
use con_engine::media::opus::{MicrophonePacker, OpusDecoder, OpusEncoder};
use con_engine::media::video::{
    DropReason, MissingReference, SampleKind, VideoConfig, VideoOutput, VideoProfile,
    VideoReceiver, VideoSample, SAMPLE_PADDING,
};
use con_engine::transport::loss::{AudioCounting, AudioLossCounter};
use con_engine::transport::packet::{parse_media, MediaKind, UnitWord};
use con_engine::Codec;

#[test]
fn media_headers_for_every_version() {
    let mut d1 = hex("02 0000 0001 00000401 03 094223ba 00000080 0398 00");
    d1.extend_from_slice(&[0xee; 105]);
    let mut d2 = hex("02 0001 0001 00200401 03 5a8b07c4 00000100 0000 00");
    d2.extend_from_slice(&[0xee; 108]);
    for version in [9, 12] {
        let h = parse_media(&d1, version).unwrap();
        assert_eq!(h.kind, MediaKind::Video);
        assert_eq!((h.packet_index, h.frame_index), (0, 1));
        assert_eq!(
            h.unit_word,
            UnitWord::Video {
                unit_index: 0,
                units_total: 2,
                fec_units: 1
            }
        );
        assert_eq!((h.codec, h.key_pos), (3, 0x80));
        assert_eq!(h.adaptive_stream, Some(0));
        assert_eq!(h.payload_offset, 21);
        assert_eq!(d1.len() - h.payload_offset, 105);
        let h2 = parse_media(&d2, version).unwrap();
        assert_eq!(h2.unit_word.unit_index(), 1);
        assert_eq!(h2.key_pos, 0x100);
    }
    let mut d3 = hex("12 0002 0002 00004401 03 00000000 00000000 0000 00 003231");
    d3.push(0x77);
    let h3 = parse_media(&d3, 12).unwrap();
    assert!(h3.extended);
    assert_eq!(
        h3.unit_word,
        UnitWord::Video {
            unit_index: 0,
            units_total: 18,
            fec_units: 1
        }
    );
    assert_eq!(h3.payload_offset, 24);
    let v = video_datagram(5, 9, 0, 1, 0, 6, false, b"xyzw");
    assert_eq!(parse_media(&v, 12).unwrap().adaptive_stream, Some(6));
    assert!(parse_media(&v[..24], 12).is_none());

    let a9 = audio_datagram(9, 1, 7, 3, 80, 2, 1, 5, false, &[0x11; 240]);
    let h = parse_media(&a9, 9).unwrap();
    assert_eq!(h.kind, MediaKind::Audio);
    assert_eq!(h.payload_offset, 19);
    assert_eq!(
        h.unit_word,
        UnitWord::Audio {
            unit_index: 0,
            units_total: 3,
            unit_size: 80,
            fec_units: 2,
            source_units: 1
        }
    );
    assert!(parse_media(&a9[..19], 9).is_none());
    let mut a9x = a9.clone();
    a9x[0] |= 0x10;
    assert_eq!(parse_media(&a9x, 9).unwrap().payload_offset, 22);

    let a12 = audio_datagram(12, 1, 7, 1, 4, 0, 1, 5, false, &[1, 2, 3, 4]);
    let h = parse_media(&a12, 12).unwrap();
    assert_eq!((h.kind, h.payload_offset), (MediaKind::Audio, 20));
    let hp = audio_datagram(12, 1, 7, 1, 4, 0, 1, 0, true, &[1, 2, 3, 4]);
    assert_eq!(parse_media(&hp, 12).unwrap().kind, MediaKind::Haptics);
    let mut ext = hex("13 0001 0007 00000401 05 00000000 00000000 00 000000 02");
    ext.extend_from_slice(&[9; 4]);
    let h = parse_media(&ext, 12).unwrap();
    assert_eq!((h.kind, h.payload_offset), (MediaKind::Haptics, 23));
    assert!(parse_media(&a12[..20], 12).is_none());

    let mut a7 = hex("03 0000 0004 007ffc00 ff 00000000 00000000");
    a7.extend_from_slice(&[0; 8]);
    let h = parse_media(&a7, 7).unwrap();
    assert_eq!(h.payload_offset, 18);
    assert_eq!(
        h.unit_word,
        UnitWord::Video {
            unit_index: 3,
            units_total: 2048,
            fec_units: 0
        }
    );
    let mut v7 = hex("02 0000 0001 00000000 00 00000000 00000000 000000");
    v7.push(1);
    assert_eq!(parse_media(&v7, 7).unwrap().payload_offset, 21);
}

#[derive(Debug, Clone)]
struct Got {
    kind: SampleKind,
    data: Vec<u8>,
    frame: u16,
    lost: u32,
    recovered: bool,
    fec: bool,
    key: bool,
    hidden: bool,
    profile: u8,
}

#[derive(Default)]
struct Rec {
    samples: Vec<Got>,
    corrupt: Vec<(u16, u16)>,
    idr: usize,
    fec_failures: Vec<(u16, bool)>,
    reject: HashSet<u16>,
    drops: Vec<(u16, DropReason)>,
    order: Vec<String>,
}

impl Rec {
    fn pictures(&self) -> Vec<&Got> {
        self.samples
            .iter()
            .filter(|s| s.kind == SampleKind::Picture)
            .collect()
    }
}

impl VideoOutput for Rec {
    fn sample(&mut self, s: &VideoSample<'_>) -> bool {
        assert_eq!(s.padded.len(), s.data.len() + SAMPLE_PADDING);
        assert_eq!(&s.padded[..s.data.len()], s.data);
        assert!(s.padded[s.data.len()..].iter().all(|&b| b == 0));
        self.order.push(match s.kind {
            SampleKind::ParameterSets => format!("ps {}", s.profile),
            SampleKind::Picture => format!("pic {}", s.frame_index),
        });
        self.samples.push(Got {
            kind: s.kind,
            data: s.data.to_vec(),
            frame: s.frame_index,
            lost: s.frames_lost,
            recovered: s.recovered,
            fec: s.fec_recovered,
            key: s.keyframe,
            hidden: s.decode_only,
            profile: s.profile,
        });
        !(s.kind == SampleKind::Picture && self.reject.contains(&s.frame_index))
    }

    fn report_corrupt(&mut self, start: u16, end: u16) {
        self.corrupt.push((start, end));
    }

    fn request_idr(&mut self) {
        self.idr += 1;
    }

    fn fec_failure(&mut self, frame_index: u16, idr_requested: bool) {
        self.fec_failures.push((frame_index, idr_requested));
        self.order.push(format!("fec {frame_index}"));
    }

    fn dropped(&mut self, frame_index: u16, reason: DropReason) {
        self.drops.push((frame_index, reason));
        self.order.push(format!("drop {frame_index}"));
    }
}

struct Feeder {
    rx: VideoReceiver,
    rec: Rec,
    packet: u16,
}

#[derive(Clone, Default)]
struct Delivery {
    drop: Vec<usize>,
    order: Option<Vec<usize>>,
    duplicate: Vec<usize>,
    asi: u8,
}

impl Feeder {
    fn new(codec: Codec, profiles: Vec<VideoProfile>, idr_on_fec_failure: bool) -> Self {
        Self {
            rx: VideoReceiver::new(
                VideoConfig {
                    idr_on_fec_failure,
                    ..VideoConfig::new(codec)
                },
                profiles,
                Logger::default(),
            ),
            rec: Rec::default(),
            packet: 0,
        }
    }

    fn repairing(mut self) -> Self {
        self.rx.set_missing_reference(MissingReference::Repair);
        self
    }

    fn withholding(mut self) -> Self {
        self.rx.set_missing_reference(MissingReference::Withhold);
        self
    }

    fn offer(&mut self, d: &[u8]) {
        let h = parse_media(d, 12).unwrap();
        self.rx.on_packet(&h, &d[h.payload_offset..], &mut self.rec);
    }

    fn frame(&mut self, frame: u16, picture: &[u8], chunk: usize, m: usize, how: &Delivery) {
        let units = frame_units(picture, chunk, m);
        let n = units.len();
        let base = self.packet;
        self.packet = self.packet.wrapping_add(n as u16);
        let order = how.order.clone().unwrap_or_else(|| (0..n).collect());
        for u in order {
            if how.drop.contains(&u) {
                continue;
            }
            let d = video_datagram(
                base.wrapping_add(u as u16),
                frame,
                u as u16,
                n as u16,
                m as u16,
                how.asi,
                false,
                &units[u],
            );
            self.offer(&d);
            if how.duplicate.contains(&u) {
                self.offer(&d);
            }
        }
    }
}

fn h264_profile() -> VideoProfile {
    VideoProfile {
        width: 1280,
        height: 720,
        header: [h26x::build_h264_sps(8), h26x::build_h264_pps()].concat(),
    }
}

fn h264_picture(frame: u16, idr: bool, distance: u32, size: usize) -> Vec<u8> {
    h26x::build_h264_slice(
        idr,
        u32::from(frame) & 0xff,
        8,
        distance,
        &body(size, frame as u8),
    )
}

#[test]
fn complete_frames_parameter_sets_first_and_padding() {
    let mut f = Feeder::new(Codec::H264, vec![h264_profile()], false);
    let pics: Vec<Vec<u8>> = (1..=4)
        .map(|i| h264_picture(i, i == 1, 0, 300 + usize::from(i) * 37))
        .collect();
    for (i, p) in pics.iter().enumerate() {
        f.frame(i as u16 + 1, p, 100, 2, &Delivery::default());
    }
    let s = &f.rec.samples;
    assert_eq!(s[0].kind, SampleKind::ParameterSets);
    assert_eq!(s[0].data, h264_profile().header);
    let pictures = f.rec.pictures();
    assert_eq!(pictures.len(), 4);
    for (i, g) in pictures.iter().enumerate() {
        assert_eq!(g.data, pics[i]);
        assert_eq!(g.frame, i as u16 + 1);
        assert_eq!(g.lost, 0);
        assert!(!g.fec && !g.recovered);
        assert_eq!(g.key, i == 0);
    }
    assert!(f.rec.corrupt.is_empty());
    let st = f.rx.stats();
    assert_eq!(st.frames_complete, 4);
    assert_eq!(st.frames_delivered, 4);
    assert_eq!(st.units_late, 8);
    assert_eq!(f.rx.last_complete(), 4);
}

#[test]
fn fec_recovers_lost_units_reordered_and_duplicated() {
    let mut f = Feeder::new(Codec::H264, vec![h264_profile()], false);
    let p1 = h264_picture(1, true, 0, 700);
    let p2 = h264_picture(2, false, 0, 650);
    let p3 = h264_picture(3, false, 0, 900);
    f.frame(1, &p1, 100, 3, &Delivery::default());
    f.frame(
        2,
        &p2,
        100,
        3,
        &Delivery {
            drop: vec![0, 3, 6],
            order: Some(vec![2, 8, 1, 5, 4, 7, 9]),
            ..Default::default()
        },
    );
    f.frame(
        3,
        &p3,
        100,
        2,
        &Delivery {
            order: Some(vec![4, 0, 8, 2, 1, 6, 3, 5, 7, 9, 10]),
            duplicate: vec![0, 2],
            ..Default::default()
        },
    );
    let pics = f.rec.pictures();
    assert_eq!(pics.len(), 3, "{:?} {:?}", f.rx.stats(), f.rec.corrupt);
    assert_eq!(pics[1].data, p2);
    assert!(pics[1].fec);
    assert_eq!(pics[2].data, p3);
    assert!(!pics[2].fec);
    let st = f.rx.stats();
    assert_eq!(st.frames_fec_recovered, 1);
    assert_eq!(st.units_rejected, 2);
    assert!(f.rec.corrupt.is_empty());
}

#[test]
fn fec_failure_reports_and_counts_lost_frames() {
    let mut f = Feeder::new(Codec::H264, vec![h264_profile()], false);
    f.frame(
        1,
        &h264_picture(1, true, 0, 300),
        100,
        1,
        &Delivery::default(),
    );
    f.frame(
        2,
        &h264_picture(2, false, 0, 400),
        100,
        1,
        &Delivery {
            drop: vec![1, 2],
            ..Default::default()
        },
    );
    assert_eq!(f.rec.corrupt, vec![(2, 2)]);
    assert_eq!(f.rec.fec_failures, vec![(2, false)]);
    assert_eq!(f.rec.idr, 0);
    f.frame(
        3,
        &h264_picture(3, true, 0, 300),
        100,
        1,
        &Delivery::default(),
    );
    assert_eq!(f.rec.corrupt, vec![(2, 2), (2, 2)]);
    let pics = f.rec.pictures();
    assert_eq!(pics.len(), 2);
    assert_eq!((pics[1].frame, pics[1].lost), (3, 1));
    f.frame(
        5,
        &h264_picture(5, true, 0, 300),
        100,
        1,
        &Delivery::default(),
    );
    assert_eq!(f.rec.corrupt.last(), Some(&(4, 4)));
    let st = f.rx.stats();
    assert_eq!(st.frames_fec_failed, 1);
    assert_eq!(st.frames_lost, 1);
    assert_eq!(st.corrupt_reports, 3);
}

#[test]
fn frame_without_enough_units_fails_when_the_next_starts() {
    let mut f = Feeder::new(Codec::H264, vec![h264_profile()], false);
    f.frame(
        1,
        &h264_picture(1, true, 0, 300),
        100,
        1,
        &Delivery::default(),
    );
    f.frame(
        2,
        &h264_picture(2, true, 0, 300),
        100,
        1,
        &Delivery {
            drop: vec![3, 4],
            ..Default::default()
        },
    );
    assert!(f.rec.corrupt.is_empty());
    f.frame(
        3,
        &h264_picture(3, true, 0, 300),
        100,
        1,
        &Delivery::default(),
    );
    assert_eq!(f.rec.corrupt, vec![(2, 2), (2, 2)]);
    assert_eq!(f.rec.pictures().last().unwrap().lost, 1);
}

#[test]
fn idr_request_on_fec_failure_and_waiting_for_the_keyframe() {
    let mut f = Feeder::new(Codec::H264, vec![h264_profile()], true);
    f.frame(
        1,
        &h264_picture(1, true, 0, 300),
        100,
        1,
        &Delivery::default(),
    );
    let lose_two = Delivery {
        drop: vec![0, 1],
        ..Default::default()
    };
    f.frame(2, &h264_picture(2, false, 0, 300), 100, 1, &lose_two);
    assert_eq!(f.rec.idr, 1);
    assert_eq!(f.rec.fec_failures, vec![(2, true)]);
    assert!(f.rx.waiting_for_idr());
    f.frame(3, &h264_picture(3, false, 0, 300), 100, 1, &lose_two);
    assert_eq!(f.rec.idr, 1);
    assert_eq!(f.rec.fec_failures, vec![(2, true), (3, false)]);
    f.frame(
        4,
        &h264_picture(4, false, 0, 300),
        100,
        1,
        &Delivery::default(),
    );
    assert_eq!(f.rec.pictures().len(), 1);
    f.frame(
        5,
        &h264_picture(5, true, 0, 300),
        100,
        1,
        &Delivery::default(),
    );
    let pics = f.rec.pictures();
    assert_eq!(pics.len(), 2);
    assert_eq!(pics[1].frame, 5);
    assert!(pics[1].key);
    assert_eq!(pics[1].lost, 3);
    assert!(!f.rx.waiting_for_idr());
    assert_eq!(f.rx.stats().frames_skipped_waiting_idr, 1);
}

#[test]
fn h264_missing_reference_drops_the_picture() {
    let mut f = Feeder::new(Codec::H264, vec![h264_profile()], false);
    f.frame(
        1,
        &h264_picture(1, true, 0, 300),
        100,
        1,
        &Delivery::default(),
    );
    f.frame(
        2,
        &h264_picture(2, false, 0, 300),
        100,
        1,
        &Delivery::default(),
    );
    f.frame(
        4,
        &h264_picture(4, false, 0, 300),
        100,
        1,
        &Delivery::default(),
    );
    f.frame(
        5,
        &h264_picture(5, false, 2, 300),
        100,
        1,
        &Delivery::default(),
    );
    let pics = f.rec.pictures();
    assert_eq!(
        pics.iter().map(|g| (g.frame, g.lost)).collect::<Vec<_>>(),
        vec![(1, 0), (2, 0), (5, 1)]
    );
    assert_eq!(f.rec.corrupt, vec![(3, 3), (3, 4)]);
    assert_eq!(f.rx.stats().frames_reference_missing, 1);
}

#[test]
fn rejected_pictures_are_not_references() {
    let mut f = Feeder::new(Codec::H264, vec![h264_profile()], false);
    f.rec.reject.insert(2);
    f.frame(
        1,
        &h264_picture(1, true, 0, 300),
        100,
        1,
        &Delivery::default(),
    );
    f.frame(
        2,
        &h264_picture(2, false, 0, 300),
        100,
        1,
        &Delivery::default(),
    );
    f.frame(
        3,
        &h264_picture(3, false, 0, 300),
        100,
        1,
        &Delivery::default(),
    );
    assert_eq!(f.rec.corrupt, vec![(2, 2)]);
    assert_eq!(f.rec.pictures().len(), 2);
    assert_eq!(f.rx.stats().frames_rejected, 1);
    assert_eq!(f.rx.last_complete(), 1);
}

#[test]
fn h265_reference_rewrite() {
    let header = h26x::build_h265_parameter_sets(8);
    let profile = VideoProfile {
        width: 1920,
        height: 1080,
        header: header.clone(),
    };
    let sets = h26x::ParameterSets::parse(CodecFamily::H265, &header);
    let mut f = Feeder::new(Codec::H265, vec![profile], false).repairing();
    let pic = |frame: u16, idr: bool, neg: &[bool]| {
        h26x::build_h265_slice(idr, u32::from(frame) - 1, 8, neg, &body(400, frame as u8))
    };
    f.frame(1, &pic(1, true, &[]), 120, 1, &Delivery::default());
    f.frame(2, &pic(2, false, &[true]), 120, 1, &Delivery::default());
    f.frame(
        4,
        &pic(4, false, &[true, true, false]),
        120,
        1,
        &Delivery::default(),
    );
    let pics = f.rec.pictures();
    assert_eq!(pics.len(), 3);
    let g = pics[2];
    assert_eq!((g.frame, g.recovered, g.lost), (4, true, 0));
    let r = h26x::first_slice(CodecFamily::H265, &g.data).unwrap();
    let s = h26x::parse_slice(CodecFamily::H265, &sets, &g.data[r]).unwrap();
    assert_eq!(s.reference, Some(1));
    assert_eq!(g.data.len(), pic(4, false, &[true, true, false]).len());
    assert_eq!(f.rx.stats().frames_reference_repaired, 1);
    f.frame(6, &pic(6, false, &[true]), 120, 1, &Delivery::default());
    assert_eq!(f.rec.pictures().len(), 3);
    assert_eq!(f.rx.stats().frames_reference_missing, 1);
}

fn h265_feeder(b: &h26x::H265Build) -> Feeder {
    let profile = VideoProfile {
        width: b.width,
        height: b.height,
        header: h26x::build_h265_parameter_sets_with(b),
    };
    Feeder::new(Codec::H265, vec![profile], false)
}

fn h265_slices(
    b: &h26x::H265Build,
    frame: u16,
    idr: bool,
    negatives: &[(u32, bool)],
    slices: u32,
    intra_first: bool,
) -> Vec<u8> {
    let mut pic = Vec::new();
    for i in 0..slices {
        pic.extend(h26x::build_h265_slice_with(
            b,
            &h26x::H265SliceSpec {
                idr,
                intra: !idr && i == 0 && slices > 1 && intra_first,
                poc_lsb: u32::from(frame) - 1,
                address: i * 50,
                negatives,
                body: &body(150, frame as u8 + i as u8),
            },
        ));
    }
    pic
}

fn h265_used_flags(b: &h26x::H265Build, picture: &[u8]) -> Vec<Vec<bool>> {
    let sets =
        h26x::ParameterSets::parse(CodecFamily::H265, &h26x::build_h265_parameter_sets_with(b));
    h26x::nal_units(picture)
        .into_iter()
        .map(|r| {
            let s = h26x::parse_slice(CodecFamily::H265, &sets, &picture[r]).unwrap();
            s.negatives.iter().map(|n| n.1).collect()
        })
        .collect()
}

#[test]
fn h265_rewrite_covers_every_slice() {
    let b = h26x::H265Build::new(8);
    let mut f = h265_feeder(&b).repairing();
    let send = |f: &mut Feeder, frame: u16, idr: bool, neg: &[(u32, bool)]| {
        f.frame(
            frame,
            &h265_slices(&b, frame, idr, neg, 3, false),
            120,
            1,
            &Delivery::default(),
        );
    };
    send(&mut f, 1, true, &[]);
    send(&mut f, 2, false, &[(0, true)]);
    send(&mut f, 4, false, &[(0, true), (0, false)]);
    let pics = f.rec.pictures();
    assert_eq!(pics.len(), 3);
    assert!(pics[2].recovered);
    assert_eq!(
        h265_used_flags(&b, &pics[2].data),
        vec![vec![false, true]; 3]
    );
    assert_eq!(f.rx.stats().frames_reference_repaired, 1);
    assert_eq!(f.rx.stats().frames_unchecked, 0);
    let mut broken = vec![0, 0, 0, 1, 0x02, 0x01, 0x80];
    broken.extend(body(300, 9));
    f.frame(5, &broken, 120, 1, &Delivery::default());
    assert_eq!(f.rec.pictures().len(), 4);
    assert_eq!(f.rx.stats().frames_unchecked, 1);
}

#[test]
fn h265_intra_refresh_picture_is_checked() {
    let b = h26x::H265Build::new(8);
    let mut f = h265_feeder(&b).repairing();
    let send = |f: &mut Feeder, frame: u16, idr: bool, neg: &[(u32, bool)]| {
        let pic = h265_slices(&b, frame, idr, neg, 2, true);
        f.frame(frame, &pic, 120, 1, &Delivery::default());
    };
    send(&mut f, 1, true, &[]);
    send(&mut f, 2, false, &[(0, true)]);
    send(&mut f, 4, false, &[(0, true), (0, false)]);
    send(&mut f, 6, false, &[(0, true)]);
    let pics = f.rec.pictures();
    assert_eq!(
        pics.iter().map(|g| g.frame).collect::<Vec<_>>(),
        vec![1, 2, 4]
    );
    assert!(pics[2].recovered);
    assert_eq!(
        h265_used_flags(&b, &pics[2].data),
        vec![vec![false, true]; 2]
    );
    assert_eq!(f.rec.drops, vec![(6, DropReason::ReferenceMissing)]);
}

#[test]
fn h264_non_reference_pictures_are_no_references() {
    let mut f = Feeder::new(Codec::H264, vec![h264_profile()], false);
    let pic = |frame: u16, idr: bool, reference: bool, frame_num: u32, distance: u32| {
        h26x::build_h264_slice_with(
            idr,
            reference,
            frame_num,
            8,
            distance,
            &body(200, frame as u8),
        )
    };
    f.frame(1, &pic(1, true, true, 0, 0), 100, 1, &Delivery::default());
    f.frame(3, &pic(3, false, false, 2, 1), 100, 1, &Delivery::default());
    f.frame(4, &pic(4, false, true, 2, 0), 100, 1, &Delivery::default());
    let pics = f.rec.pictures();
    assert_eq!(pics.iter().map(|g| g.frame).collect::<Vec<_>>(), vec![1, 3]);
    assert_eq!(f.rec.drops, vec![(4, DropReason::ReferenceMissing)]);
}

#[test]
fn h264_frame_num_wrap_is_no_reference() {
    let profile = VideoProfile {
        width: 1280,
        height: 720,
        header: [h26x::build_h264_sps(4), h26x::build_h264_pps()].concat(),
    };
    let mut f = Feeder::new(Codec::H264, vec![profile], false);
    for frame in 1u16..=20 {
        if frame == 18 {
            continue;
        }
        let pic = h26x::build_h264_slice(
            frame == 1,
            u32::from(frame - 1) & 15,
            4,
            0,
            &body(200, frame as u8),
        );
        f.frame(frame, &pic, 100, 1, &Delivery::default());
    }
    assert_eq!(
        f.rec.drops,
        vec![
            (19, DropReason::ReferenceMissing),
            (20, DropReason::ReferenceMissing)
        ]
    );
}

#[test]
fn h265_missing_second_reference_is_cleared() {
    let b = h26x::H265Build::new(8);
    let mut f = h265_feeder(&b).repairing();
    f.rec.reject.insert(2);
    for (frame, idr, neg) in [
        (1u16, true, vec![]),
        (2, false, vec![(0, true)]),
        (3, false, vec![(0, false), (0, true)]),
        (4, false, vec![(0, true), (0, true)]),
    ] {
        f.frame(
            frame,
            &h265_slices(&b, frame, idr, &neg, 1, false),
            120,
            1,
            &Delivery::default(),
        );
    }
    let pics = f.rec.pictures();
    assert_eq!(
        pics.iter().map(|g| g.frame).collect::<Vec<_>>(),
        vec![1, 2, 3, 4]
    );
    assert!(!pics[2].recovered && pics[3].recovered);
    assert_eq!(h265_used_flags(&b, &pics[3].data), vec![vec![true, false]]);
}

#[test]
fn h265_references_by_picture_order_count() {
    let b = h26x::H265Build::new(8);
    let mut f = h265_feeder(&b).repairing();
    f.rec.reject.insert(2);
    for (frame, idr, neg) in [
        (1u16, true, vec![]),
        (2, false, vec![(0, true)]),
        (3, false, vec![(1, true)]),
    ] {
        f.frame(
            frame,
            &h265_slices(&b, frame, idr, &neg, 1, false),
            120,
            1,
            &Delivery::default(),
        );
    }
    let five = h265_slices(&b, 5, false, &[(0, true), (1, false)], 1, false);
    f.frame(5, &five, 120, 1, &Delivery::default());
    let six = h265_slices(&b, 6, false, &[(0, true), (1, false)], 1, false);
    f.frame(6, &six, 120, 1, &Delivery::default());
    let pics = f.rec.pictures();
    assert_eq!(
        pics.iter().map(|g| g.frame).collect::<Vec<_>>(),
        vec![1, 2, 3, 6]
    );
    assert_eq!(f.rec.drops, vec![(5, DropReason::ReferenceMissing)]);
    assert_eq!(h265_used_flags(&b, &pics[3].data), vec![vec![false, true]]);
}

#[test]
fn h265_rewrite_keeps_the_used_count_with_list_modification() {
    let b = h26x::H265Build {
        lists_modification_present: true,
        ..h26x::H265Build::new(8)
    };
    let mut f = h265_feeder(&b).repairing();
    let send = |f: &mut Feeder, frame: u16, idr: bool, neg: &[(u32, bool)]| {
        f.frame(
            frame,
            &h265_slices(&b, frame, idr, neg, 1, false),
            120,
            1,
            &Delivery::default(),
        );
    };
    send(&mut f, 1, true, &[]);
    send(&mut f, 2, false, &[(0, true)]);
    send(&mut f, 4, false, &[(0, true), (0, false)]);
    send(&mut f, 6, false, &[(0, true), (0, true)]);
    let pics = f.rec.pictures();
    assert_eq!(
        pics.iter().map(|g| g.frame).collect::<Vec<_>>(),
        vec![1, 2, 4]
    );
    assert!(pics[2].recovered);
    assert_eq!(f.rec.drops, vec![(6, DropReason::ReferenceMissing)]);
}

const PS5_CLOUD_PARAMETER_SETS: &str = "0000000140010c01ffff016000000300b0000003000003007b1302\
    4000000001420101016000000300b0000003000003007ba003c0801107cbc4e490a54ee02d4040404100000fa4\
    0003a9804120000000014401c0f3c04c90";

const PS5_CLOUD_RUN_A: &[(u16, &str)] = &[
    (1307, "2801ae"),
    (1308, "0201d09770a068"),
    (1309, "0201d11760e148"),
    (1310, "0201d19760e148"),
    (1311, "0201d21760e148"),
    (1312, "0201d29760e148"),
    (1313, "0201d31760e148"),
    (1314, "0201d39760e148"),
    (1315, "0201d41760e148"),
    (1316, "0201d49760e148"),
    (1317, "0201d51770c1a0"),
    (1318, "0201d59770c1a0"),
    (1319, "0201d61770c1a0"),
    (1320, "0201d69770c1a0"),
    (1321, "0201d71770c1a0"),
    (1322, "0201d79770c1a0"),
    (1323, "0201d01770a068"),
    (1324, "0201d09770a068"),
    (1327, "0201d21760e148"),
    (1328, "0201d29760e148"),
    (1329, "0201d31760e148"),
    (1330, "0201d39760e148"),
    (1331, "0201d41760e148"),
    (1332, "0201d49760e148"),
    (1333, "0201d51770c1a0"),
    (1334, "0201d59770c1a0"),
    (1335, "0201d61770c1a0"),
    (1336, "0201d69641d0"),
    (1337, "0201d71641d0"),
    (1338, "0201d79740d0"),
    (1339, "0201d01641a4"),
    (1340, "0201d09641a4"),
];

const PS5_CLOUD_RUN_B: &[(u16, &str)] = &[
    (3568, "2801ae"),
    (3569, "0201d09770a068"),
    (3570, "0201d11760e148"),
    (3571, "0201d19760e148"),
    (3572, "0201d21760e148"),
    (3573, "0201d29760e148"),
    (3574, "0201d31760e148"),
    (3575, "0201d39760e148"),
    (3576, "0201d41760e148"),
    (3577, "0201d49760e148"),
    (3578, "0201d51770c1a0"),
    (3580, "0201d61770c1a0"),
    (3581, "0201d69770c1a0"),
    (3582, "0201d71770c1a0"),
    (3583, "0201d79770c1a0"),
    (3584, "0201d01770a068"),
    (3585, "0201d09770a068"),
    (3586, "0201d11760e148"),
    (3587, "0201d19651a4"),
    (3588, "0201d21651a4"),
    (3589, "0201d29651a4"),
    (3591, "0201d39651a4"),
    (3592, "0201d41750a4"),
];

#[derive(Default)]
struct StrictH265Decoder {
    sets: h26x::ParameterSets,
    idr_frame: u16,
    prev: Option<(u32, i64)>,
    dpb: Vec<(i64, u16)>,
    accepted: Vec<u16>,
    rejected: Vec<u16>,
    recovered: Vec<u16>,
    wrong_reference: Vec<u16>,
    wrong_content: Vec<u16>,
    hidden: Vec<u16>,
    shown: Vec<u16>,
    drops: Vec<(u16, DropReason)>,
    used: Vec<(u16, Vec<bool>, Vec<bool>)>,
    lost: Vec<(u16, u32)>,
    resolved: Vec<(u16, Vec<u16>)>,
    idr: usize,
}

impl StrictH265Decoder {
    fn poc(&self, lsb: u32, m: i64) -> i64 {
        let Some((prev_lsb, prev)) = self.prev else {
            return i64::from(lsb);
        };
        let (lsb, prev_lsb) = (i64::from(lsb), i64::from(prev_lsb));
        let prev_msb = prev - prev_lsb;
        let msb = if lsb < prev_lsb && prev_lsb - lsb >= m / 2 {
            prev_msb + m
        } else if lsb > prev_lsb && lsb - prev_lsb > m / 2 {
            prev_msb - m
        } else {
            prev_msb
        };
        msb + lsb
    }
}

impl VideoOutput for StrictH265Decoder {
    fn sample(&mut self, s: &VideoSample<'_>) -> bool {
        if s.kind == SampleKind::ParameterSets {
            self.sets = h26x::ParameterSets::parse(CodecFamily::H265, s.data);
            return true;
        }
        let r = h26x::first_slice(CodecFamily::H265, s.data).unwrap();
        let info = h26x::parse_slice(CodecFamily::H265, &self.sets, &s.data[r]).unwrap();
        self.lost.push((s.frame_index, s.frames_lost));
        if s.recovered {
            self.recovered.push(s.frame_index);
        }
        let lts = info.long_terms.clone().unwrap_or_default();
        self.used.push((
            s.frame_index,
            info.negatives.iter().map(|n| n.1).collect(),
            lts.iter().map(|l| l.used).collect(),
        ));
        let lsb = info.pic_id.unwrap();
        if s.keyframe {
            assert!(!s.decode_only, "keyframe {} hidden", s.frame_index);
            self.idr_frame = s.frame_index;
            self.dpb = vec![(0, s.frame_index)];
            self.prev = Some((lsb, 0));
            self.accepted.push(s.frame_index);
            self.shown.push(s.frame_index);
            return true;
        }
        let m = i64::from(info.pic_id_modulus);
        let poc = self.poc(lsb, m);
        self.prev = Some((lsb, poc));
        let meant = i64::from(s.frame_index.wrapping_sub(self.idr_frame));
        let lt_poc = |l: &h26x::LongTermRef, p: i64| -> Option<i64> {
            l.msb_cycle
                .map(|c| p - i64::from(c) * m - p.rem_euclid(m) + i64::from(l.poc_lsb))
        };
        let find = |p: i64| self.dpb.iter().find(|e| e.0 == p).map(|e| e.1);
        let mut refs = Vec::new();
        let mut ok = info.uses_references();
        let mut wrong = false;
        let frame_of = |p: i64| self.idr_frame.wrapping_add(p as u16);
        for &(d, _) in info.negatives.iter().filter(|n| n.1) {
            match find(poc + i64::from(d)) {
                Some(f) => {
                    wrong |= f != frame_of(meant + i64::from(d));
                    refs.push(f);
                }
                None => ok = false,
            }
        }
        for l in lts.iter().filter(|l| l.used) {
            let got = match lt_poc(l, poc) {
                Some(p) => find(p),
                None => self
                    .dpb
                    .iter()
                    .find(|e| e.0.rem_euclid(m) == i64::from(l.poc_lsb))
                    .map(|e| e.1),
            };
            match got {
                Some(f) => {
                    if let Some(p) = lt_poc(l, meant) {
                        wrong |= f != frame_of(p);
                    }
                    refs.push(f);
                }
                None => ok = false,
            }
        }
        if !ok {
            self.rejected.push(s.frame_index);
            return false;
        }
        if wrong && !s.recovered {
            self.wrong_reference.push(s.frame_index);
        }
        if s.recovered || wrong || refs.iter().any(|f| self.wrong_content.contains(f)) {
            self.wrong_content.push(s.frame_index);
        }
        if s.decode_only {
            self.hidden.push(s.frame_index);
        } else {
            self.shown.push(s.frame_index);
        }
        let keep: Vec<i64> = info
            .negatives
            .iter()
            .map(|&(d, _)| poc + i64::from(d))
            .chain(lts.iter().filter_map(|l| lt_poc(l, poc)))
            .collect();
        let keep_lsb: Vec<i64> = lts
            .iter()
            .filter(|l| l.msb_cycle.is_none())
            .map(|l| i64::from(l.poc_lsb))
            .collect();
        self.dpb
            .retain(|e| keep.contains(&e.0) || keep_lsb.contains(&e.0.rem_euclid(m)));
        self.dpb.push((poc, s.frame_index));
        self.accepted.push(s.frame_index);
        self.resolved.push((s.frame_index, refs));
        true
    }

    fn report_corrupt(&mut self, _start: u16, _end: u16) {}

    fn request_idr(&mut self) {
        self.idr += 1;
    }

    fn dropped(&mut self, frame_index: u16, reason: DropReason) {
        self.drops.push((frame_index, reason));
    }
}

fn play_ps5_cloud_run(
    run: &[(u16, &str)],
    lost: &[u16],
    policy: MissingReference,
) -> (StrictH265Decoder, VideoReceiver) {
    let profile = VideoProfile {
        width: 1920,
        height: 1080,
        header: hex(PS5_CLOUD_PARAMETER_SETS),
    };
    let mut rx = VideoReceiver::new(
        VideoConfig {
            missing_reference: policy,
            ..VideoConfig::new(Codec::H265)
        },
        vec![profile],
        Logger::default(),
    );
    let mut dec = StrictH265Decoder::default();
    let mut packet = 0u16;
    let mut send = |rx: &mut VideoReceiver,
                    dec: &mut StrictH265Decoder,
                    frame: u16,
                    pic: &[u8],
                    drop: &[usize]| {
        let units = frame_units(pic, 100, 1);
        let n = units.len();
        for (u, unit) in units.iter().enumerate() {
            if !drop.contains(&u) {
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
                let h = parse_media(&d, 12).unwrap();
                rx.on_packet(&h, &d[h.payload_offset..], dec);
            }
        }
        packet = packet.wrapping_add(n as u16);
    };
    let mut prev: Option<u16> = None;
    for &(frame, header) in run {
        for &l in lost {
            if prev.is_some_and(|p| p < l) && l < frame {
                send(&mut rx, &mut dec, l, &[0x55; 250], &[1, 2]);
            }
        }
        let mut pic = vec![0, 0, 0, 1];
        pic.extend(hex(header));
        pic.extend(body(240, frame as u8));
        send(&mut rx, &mut dec, frame, &pic, &[]);
        prev = Some(frame);
    }
    (dec, rx)
}

#[test]
fn ps5_cloud_headers_parse() {
    let sets = h26x::ParameterSets::parse(CodecFamily::H265, &hex(PS5_CLOUD_PARAMETER_SETS));
    let sps = &sets.h265_sps[0];
    assert_eq!(sps.log2_max_poc_lsb, 4);
    assert_eq!(sps.rps_sets, Some(vec![]));
    assert_eq!(
        sps.long_term,
        Some(h26x::LongTermSps {
            present: true,
            pictures: vec![]
        })
    );
    let slice = |h: &str| {
        let nal = [hex(h), body(40, 1)].concat();
        h26x::parse_slice(CodecFamily::H265, &sets, &nal).unwrap()
    };
    let lt = |s: &h26x::SliceInfo| -> Vec<(u32, Option<u32>, bool)> {
        s.long_terms
            .as_ref()
            .unwrap()
            .iter()
            .map(|l| (l.poc_lsb, l.msb_cycle, l.used))
            .collect()
    };
    let s = slice("0201d21760e148");
    assert_eq!(
        (s.kind, s.pic_id, s.temporal_id),
        (SliceKind::P, Some(4), 0)
    );
    assert_eq!(
        (s.negatives.clone(), s.reference),
        (vec![(-1, true)], Some(0))
    );
    assert_eq!(lt(&s), vec![(0, Some(0), false), (8, Some(1), false)]);
    let s = slice("0201d69641d0");
    assert_eq!((s.pic_id, s.reference), (Some(13), None));
    assert_eq!(s.negatives, vec![(-1, false)]);
    assert_eq!(lt(&s), vec![(0, Some(0), true)]);
    assert!(s.uses_references());
}

#[test]
fn ps5_cloud_loss_uses_a_long_term_picture() {
    let (dec, _) = play_ps5_cloud_run(PS5_CLOUD_RUN_A, &[1325, 1326], MissingReference::Repair);
    assert_eq!(dec.rejected, Vec::<u16>::new());
    assert_eq!(dec.wrong_reference, Vec::<u16>::new());
    assert_eq!(
        dec.drops,
        vec![(1325, DropReason::FecFailed), (1326, DropReason::FecFailed)]
    );
    assert_eq!(dec.recovered, vec![1327]);
    let expected: Vec<u16> = PS5_CLOUD_RUN_A.iter().map(|r| r.0).collect();
    assert_eq!(dec.accepted, expected);
    let u = dec.used.iter().find(|u| u.0 == 1327).unwrap();
    assert_eq!((u.1.clone(), u.2.clone()), (vec![false], vec![true, false]));

    let (dec, _) = play_ps5_cloud_run(PS5_CLOUD_RUN_B, &[3579, 3590], MissingReference::Repair);
    assert_eq!(dec.rejected, Vec::<u16>::new());
    assert_eq!(dec.recovered, vec![3580]);
    let expected: Vec<u16> = PS5_CLOUD_RUN_B.iter().map(|r| r.0).collect();
    assert_eq!(dec.accepted, expected);
    let u = dec.used.iter().find(|u| u.0 == 3580).unwrap();
    assert_eq!((u.1.clone(), u.2.clone()), (vec![false], vec![true, false]));
    let u = dec.used.iter().find(|u| u.0 == 3591).unwrap();
    assert_eq!((u.1.clone(), u.2.clone()), (vec![false], vec![true]));
}

#[test]
fn ps5_cloud_loss_is_withheld_until_a_keyframe() {
    let mut run: Vec<(u16, &str)> = PS5_CLOUD_RUN_A.to_vec();
    run.extend([(1341, "2801ae"), (1342, "0201d09770a068")]);
    let (dec, rx) = play_ps5_cloud_run(&run, &[1325, 1326], MissingReference::Withhold);
    assert_eq!(dec.rejected, Vec::<u16>::new());
    assert_eq!(dec.wrong_reference, Vec::<u16>::new());
    assert_eq!(dec.recovered, Vec::<u16>::new());
    let withheld: Vec<u16> = (1327..=1340).collect();
    let mut drops = vec![(1325, DropReason::FecFailed), (1326, DropReason::FecFailed)];
    drops.extend(withheld.iter().map(|&f| (f, DropReason::ReferenceMissing)));
    assert_eq!(dec.drops, drops);
    let expected: Vec<u16> = run
        .iter()
        .map(|r| r.0)
        .filter(|f| !withheld.contains(f))
        .collect();
    assert_eq!(dec.accepted, expected);
    assert_eq!(dec.idr, 1);
    assert!(dec.lost.contains(&(1341, 17)));
    assert!(dec.lost.contains(&(1342, 0)));
    let st = rx.stats();
    assert_eq!(
        (
            st.frames_withheld,
            st.withhold_periods,
            st.frames_reference_missing
        ),
        (14, 1, 14)
    );
    assert_eq!((st.frames_reference_repaired, st.idr_requests), (0, 1));
    assert_eq!(st.frames_lost, 17);
    assert!(!rx.withholding());

    let mut run: Vec<(u16, &str)> = PS5_CLOUD_RUN_B.to_vec();
    run.extend([(3593, "2801ae"), (3594, "0201d09770a068")]);
    let (dec, rx) = play_ps5_cloud_run(&run, &[3579, 3590], MissingReference::Withhold);
    assert_eq!(dec.rejected, Vec::<u16>::new());
    assert_eq!(dec.wrong_reference, Vec::<u16>::new());
    let withheld: Vec<u16> = (3580..=3592).filter(|&f| f != 3590).collect();
    let mut drops = vec![(3579, DropReason::FecFailed)];
    drops.extend((3580..=3589).map(|f| (f, DropReason::ReferenceMissing)));
    drops.push((3590, DropReason::FecFailed));
    drops.extend([3591, 3592].map(|f| (f, DropReason::ReferenceMissing)));
    assert_eq!(dec.drops, drops);
    let expected: Vec<u16> = run
        .iter()
        .map(|r| r.0)
        .filter(|f| !withheld.contains(f))
        .collect();
    assert_eq!(dec.accepted, expected);
    assert_eq!(dec.idr, 1);
    assert!(dec.lost.contains(&(3593, 14)));
    let st = rx.stats();
    assert_eq!((st.frames_withheld, st.withhold_periods), (12, 1));

    let lost: Vec<u16> = (1325..=1335).collect();
    let (dec, rx) = play_ps5_cloud_run(PS5_CLOUD_RUN_A, &lost, MissingReference::Withhold);
    assert_eq!(dec.wrong_reference, Vec::<u16>::new());
    assert_eq!(*dec.accepted.last().unwrap(), 1324);
    assert_eq!(dec.drops[11], (1336, DropReason::ReferenceMissing));
    assert_eq!((dec.idr, rx.stats().withhold_periods), (1, 1));
}

#[test]
fn ps5_cloud_recovery_picture_after_a_gap_is_misnumbered() {
    let mut dec = StrictH265Decoder::default();
    let sets = hex(PS5_CLOUD_PARAMETER_SETS);
    let feed = |dec: &mut StrictH265Decoder, kind: SampleKind, frame: u16, data: &[u8]| {
        let padded = [data, &[0u8; SAMPLE_PADDING][..]].concat();
        dec.sample(&VideoSample {
            kind,
            data,
            padded: &padded,
            frame_index: frame,
            frames_lost: 0,
            recovered: false,
            fec_recovered: false,
            keyframe: kind == SampleKind::Picture && frame == 1307,
            unchecked: false,
            decode_only: false,
            codec: Codec::H265,
            profile: 0,
            width: 1920,
            height: 1080,
        })
    };
    feed(&mut dec, SampleKind::ParameterSets, 1307, &sets);
    for &(frame, header) in PS5_CLOUD_RUN_A
        .iter()
        .filter(|r| r.0 <= 1324 || r.0 == 1336)
    {
        let pic = [&[0, 0, 0, 1][..], &hex(header), &body(240, frame as u8)].concat();
        assert!(feed(&mut dec, SampleKind::Picture, frame, &pic));
    }
    assert_eq!(dec.wrong_reference, vec![1336]);
    assert_eq!(dec.resolved.last(), Some(&(1336, vec![1307])));
    assert!(dec.resolved.contains(&(1324, vec![1323])));
}

#[test]
fn ps5_cloud_loss_is_hidden_until_the_recovery_picture() {
    assert_eq!(
        VideoConfig::new(Codec::H265).missing_reference,
        MissingReference::Hide
    );
    for (run, lost, hidden, recovery) in [
        (
            PS5_CLOUD_RUN_A,
            &[1325u16, 1326][..],
            1327u16..=1335,
            1336u16,
        ),
        (PS5_CLOUD_RUN_B, &[3579, 3590][..], 3580..=3586, 3587),
    ] {
        let (dec, rx) = play_ps5_cloud_run(run, lost, MissingReference::Hide);
        let hidden: Vec<u16> = hidden.collect();
        assert_eq!(dec.rejected, Vec::<u16>::new());
        assert_eq!(dec.wrong_reference, Vec::<u16>::new());
        let all: Vec<u16> = run.iter().map(|r| r.0).collect();
        assert_eq!(dec.accepted, all);
        assert_eq!(
            dec.drops,
            lost.iter()
                .map(|&f| (f, DropReason::FecFailed))
                .collect::<Vec<_>>()
        );
        assert_eq!(dec.recovered, vec![hidden[0]]);
        assert_eq!(dec.hidden, hidden);
        assert_eq!(dec.wrong_content, hidden);
        let shown: Vec<u16> = all
            .iter()
            .copied()
            .filter(|f| !hidden.contains(f))
            .collect();
        assert_eq!(dec.shown, shown);
        assert!(dec.shown.contains(&recovery));
        let u = dec.used.iter().find(|u| u.0 == recovery).unwrap();
        assert!(!u.1.iter().any(|&x| x) && u.2.iter().any(|&x| x));
        assert_eq!(dec.idr, 0);
        let st = rx.stats();
        assert_eq!(
            (st.frames_hidden, st.hide_runs, st.idr_requests),
            (hidden.len() as u64, 1, 0)
        );
        assert_eq!(
            (
                st.frames_reference_repaired,
                st.frames_withheld,
                st.frames_reference_missing
            ),
            (1, 0, 0)
        );
        assert_eq!(st.frames_delivered, all.len() as u64);
        assert!(!rx.hiding());
    }

    let lost: Vec<u16> = (1325..=1335).collect();
    let mut run: Vec<(u16, &str)> = PS5_CLOUD_RUN_A
        .iter()
        .copied()
        .filter(|r| !lost.contains(&r.0))
        .collect();
    run.extend([(1341, "2801ae"), (1342, "0201d09770a068")]);
    let (dec, rx) = play_ps5_cloud_run(&run, &lost, MissingReference::Hide);
    assert_eq!(dec.rejected, Vec::<u16>::new());
    assert!(
        dec.shown.iter().all(|&f| f <= 1324 || f >= 1341),
        "{:?}",
        dec.shown
    );
    assert!(dec.shown.ends_with(&[1341, 1342]));
    assert_eq!(dec.hidden, (1336..=1340).collect::<Vec<_>>());
    assert_eq!(dec.wrong_content, dec.hidden);
    assert_eq!(
        dec.resolved.iter().find(|r| r.0 == 1336),
        Some(&(1336, vec![1307]))
    );
    assert!(
        dec.wrong_content.iter().all(|f| !dec.shown.contains(f)),
        "{:?}",
        dec.wrong_content
    );
    assert_eq!(dec.idr, 1);
    assert_eq!(rx.stats().hide_runs, 1);
    assert!(!rx.hiding());
}

fn feeder_for(codec: Codec, b: &h26x::H265Build) -> Feeder {
    match codec {
        Codec::H264 => Feeder::new(Codec::H264, vec![h264_profile()], false),
        _ => h265_feeder(b),
    }
}

fn picture_for(
    codec: Codec,
    b: &h26x::H265Build,
    frame: u16,
    idr: bool,
    key: u16,
    negatives: &[(u32, bool)],
) -> Vec<u8> {
    match codec {
        Codec::H264 => h26x::build_h264_slice(
            idr,
            u32::from(frame - 1) & 0xff,
            8,
            0,
            &body(200, frame as u8),
        ),
        _ => h26x::build_h265_slice_with(
            b,
            &h26x::H265SliceSpec {
                idr,
                intra: false,
                poc_lsb: u32::from(frame - if frame >= key { key } else { 1 }),
                address: 0,
                negatives: if idr { &[] } else { negatives },
                body: &body(150, frame as u8),
            },
        ),
    }
}

#[test]
fn hidden_run_without_recovery_requests_a_keyframe_after_500_ms() {
    const KEY: u16 = 170;
    for codec in [Codec::H264, Codec::H265] {
        let b = h26x::H265Build::new(8);
        let mut f = feeder_for(codec, &b);
        assert_eq!(f.rx.missing_reference(), MissingReference::Hide);
        let pic = |frame: u16, idr: bool| {
            picture_for(codec, &b, frame, idr, KEY, &[(0, true), (0, false)])
        };
        let lose = Delivery {
            drop: vec![0, 1],
            ..Default::default()
        };
        for frame in 1u16..=3 {
            f.frame(frame, &pic(frame, frame == 1), 100, 1, &Delivery::default());
        }
        f.frame(4, &pic(4, false), 100, 1, &lose);
        for frame in 5u16..KEY {
            f.frame(frame, &pic(frame, false), 100, 1, &Delivery::default());
            assert!(f.rx.hiding(), "{codec:?} frame {frame}");
            let expected = match frame {
                ..35 => 0,
                35..155 => 1,
                _ => 2,
            };
            assert_eq!(f.rec.idr, expected, "{codec:?} frame {frame}");
        }
        f.frame(KEY, &pic(KEY, true), 100, 1, &Delivery::default());
        f.frame(KEY + 1, &pic(KEY + 1, false), 100, 1, &Delivery::default());
        assert!(!f.rx.hiding(), "{codec:?}");
        assert_eq!(f.rec.idr, 2);
        let pics = f.rec.pictures();
        let shown: Vec<(u16, u32)> = pics
            .iter()
            .filter(|g| !g.hidden)
            .map(|g| (g.frame, g.lost))
            .collect();
        let hidden: Vec<u16> = pics.iter().filter(|g| g.hidden).map(|g| g.frame).collect();
        let st = f.rx.stats();
        assert_eq!((st.hide_runs, st.idr_requests), (1, 2), "{codec:?}");
        match codec {
            Codec::H264 => {
                assert_eq!(
                    shown,
                    vec![(1, 0), (2, 0), (3, 0), (KEY, 166), (KEY + 1, 0)]
                );
                assert!(hidden.is_empty());
                assert_eq!((st.frames_hidden, st.frames_reference_missing), (0, 165));
            }
            _ => {
                assert_eq!(shown, vec![(1, 0), (2, 0), (3, 0), (KEY, 0), (KEY + 1, 0)]);
                assert_eq!(hidden, (5..KEY).collect::<Vec<_>>());
                assert!(pics.iter().find(|g| g.frame == 5).unwrap().recovered);
                assert_eq!((st.frames_hidden, st.frames_reference_missing), (165, 0));
                assert_eq!(st.frames_reference_repaired, 1);
            }
        }
    }
}

#[test]
fn withholding_requests_a_keyframe_after_300_ms() {
    const KEY: u16 = 61;
    for codec in [Codec::H264, Codec::H265] {
        let b = h26x::H265Build::new(8);
        let mut f = feeder_for(codec, &b).withholding();
        let pic = |frame: u16, idr: bool| picture_for(codec, &b, frame, idr, KEY, &[(0, true)]);
        let lose = Delivery {
            drop: vec![0, 1],
            ..Default::default()
        };
        for frame in 1u16..=3 {
            f.frame(frame, &pic(frame, frame == 1), 100, 1, &Delivery::default());
        }
        f.frame(4, &pic(4, false), 100, 1, &lose);
        for frame in 5u16..=22 {
            if frame == 10 {
                f.frame(frame, &pic(frame, false), 100, 1, &lose);
            } else {
                f.frame(frame, &pic(frame, false), 100, 1, &Delivery::default());
            }
            assert!(f.rx.withholding(), "{codec:?} frame {frame}");
            assert_eq!(f.rec.idr, 0, "{codec:?} frame {frame}");
        }
        f.frame(23, &pic(23, false), 100, 1, &Delivery::default());
        assert_eq!(f.rec.idr, 1, "{codec:?}");
        for frame in 24u16..KEY {
            f.frame(frame, &pic(frame, false), 100, 1, &Delivery::default());
        }
        assert_eq!(f.rec.idr, 1, "{codec:?}");
        assert_eq!(f.rx.stats().idr_requests, 1);
        assert_eq!(f.rec.pictures().len(), 3);
        f.frame(KEY, &pic(KEY, true), 100, 1, &Delivery::default());
        f.frame(KEY + 1, &pic(KEY + 1, false), 100, 1, &Delivery::default());
        assert!(!f.rx.withholding(), "{codec:?} {:?}", f.rec.order);
        let pics = f.rec.pictures();
        assert_eq!(
            pics.iter()
                .map(|g| (g.frame, g.lost, g.key))
                .collect::<Vec<_>>(),
            vec![
                (1, 0, true),
                (2, 0, false),
                (3, 0, false),
                (KEY, 57, true),
                (KEY + 1, 0, false)
            ],
            "{codec:?}"
        );
        let st = f.rx.stats();
        assert_eq!(
            (st.frames_withheld, st.withhold_periods),
            (55, 1),
            "{codec:?}"
        );
        assert_eq!(st.frames_reference_repaired, 0);
        let mut g = feeder_for(codec, &b).repairing();
        g.frame(1, &pic(1, true), 100, 1, &Delivery::default());
        g.frame(2, &pic(2, false), 100, 1, &lose);
        for frame in 3u16..=40 {
            g.frame(frame, &pic(frame, false), 100, 1, &Delivery::default());
        }
        assert_eq!(
            (g.rec.idr, g.rx.stats().frames_withheld),
            (0, 0),
            "{codec:?}"
        );
        assert_eq!(g.rx.stats().frames_reference_missing, 38, "{codec:?}");
    }
}

#[test]
fn profile_switch_order_and_references() {
    let p0 = h264_profile();
    let p1 = VideoProfile {
        width: 640,
        height: 360,
        header: [h26x::build_h264_sps(8), h26x::build_h264_pps()].concat(),
    };
    let mut f = Feeder::new(Codec::H264, vec![p0, p1], false);
    f.frame(
        1,
        &h264_picture(1, true, 0, 200),
        100,
        1,
        &Delivery::default(),
    );
    f.frame(
        2,
        &h264_picture(2, false, 0, 250),
        100,
        1,
        &Delivery {
            drop: vec![1, 2, 3],
            ..Default::default()
        },
    );
    let on1 = Delivery {
        asi: 1,
        ..Default::default()
    };
    f.frame(3, &h264_picture(3, false, 1, 200), 100, 1, &on1);
    f.frame(4, &h264_picture(4, true, 0, 200), 100, 1, &on1);
    f.frame(5, &h264_picture(5, false, 0, 200), 100, 1, &on1);
    assert_eq!(
        f.rec.order,
        vec!["ps 0", "pic 1", "fec 2", "drop 2", "ps 1", "drop 3", "pic 4", "pic 5"]
    );
    assert_eq!(f.rec.drops[1], (3, DropReason::ReferenceMissing));
}

#[test]
fn profile_switching() {
    let p0 = h264_profile();
    let p1 = VideoProfile {
        width: 640,
        height: 360,
        header: [h26x::build_h264_sps(6), h26x::build_h264_pps()].concat(),
    };
    let mut f = Feeder::new(Codec::H264, vec![p0.clone(), p1.clone()], false);
    f.frame(
        1,
        &h264_picture(1, true, 0, 200),
        100,
        1,
        &Delivery::default(),
    );
    f.frame(
        2,
        &h264_picture(2, false, 0, 200),
        100,
        1,
        &Delivery::default(),
    );
    let pic3 = h26x::build_h264_slice(true, 0, 6, 0, &body(200, 3));
    let on1 = Delivery {
        asi: 1,
        ..Default::default()
    };
    f.frame(3, &pic3, 100, 1, &on1);
    let pic4 = h26x::build_h264_slice(false, 1, 6, 0, &body(200, 4));
    f.frame(4, &pic4, 100, 1, &on1);
    f.frame(
        5,
        &h264_picture(5, true, 0, 200),
        100,
        1,
        &Delivery {
            asi: 5,
            ..Default::default()
        },
    );
    let kinds: Vec<(SampleKind, u8, u16)> = f
        .rec
        .samples
        .iter()
        .map(|s| (s.kind, s.profile, s.frame))
        .collect();
    use SampleKind::{ParameterSets as Ps, Picture as Pic};
    assert_eq!(
        kinds,
        vec![
            (Ps, 0, 1),
            (Pic, 0, 1),
            (Pic, 0, 2),
            (Ps, 1, 3),
            (Pic, 1, 3),
            (Pic, 1, 4)
        ]
    );
    assert_eq!(f.rec.samples[3].data, p1.header);
    assert_eq!(f.rx.stats().frames_reference_missing, 0);
    assert_eq!(f.rx.stats().profile_switches, 2);
    assert!(f.rx.stats().packets_dropped >= 3);
}

#[test]
fn invalid_frame_sizes_and_wraparound() {
    let mut f = Feeder::new(Codec::H264, vec![h264_profile()], false);
    f.frame(
        65534,
        &h264_picture(1, true, 0, 300),
        100,
        1,
        &Delivery::default(),
    );
    assert!(f.rec.corrupt.is_empty());
    let d = video_datagram(100, 65535, 0, 600, 1, 0, false, &[0, 0, 1, 2]);
    f.offer(&d);
    let d = video_datagram(101, 0, 0, 2, 2, 0, false, &[1, 2, 3, 4]);
    f.offer(&d);
    f.frame(
        1,
        &h264_picture(1, true, 0, 300),
        100,
        1,
        &Delivery::default(),
    );
    assert_eq!(f.rec.corrupt, vec![(65535, 65535), (65535, 0)]);
    assert_eq!(f.rx.stats().frames_failed, 2);
    assert_eq!(
        f.rec.pictures().iter().map(|g| g.frame).collect::<Vec<_>>(),
        vec![65534, 1]
    );
    let before = f.rx.stats().packets_dropped;
    let d = video_datagram(200, 0, 0, 2, 1, 0, false, &[0, 0, 1, 2]);
    f.offer(&d);
    assert_eq!(f.rx.stats().packets_dropped, before + 1);
}

#[test]
fn one_byte_fec_unit_fails_the_frame() {
    let mut f = Feeder::new(Codec::H264, vec![h264_profile()], false);
    f.frame(
        1,
        &h264_picture(1, true, 0, 300),
        100,
        1,
        &Delivery::default(),
    );
    let d = video_datagram(f.packet, 2, 1, 2, 1, 0, true, &[0x55]);
    f.offer(&d);
    assert_eq!(f.rec.fec_failures, vec![(2, false)]);
    let st = f.rx.stats();
    assert_eq!((st.frames_fec_recovered, st.frames_fec_failed), (0, 1));
    assert_eq!(
        f.rec.pictures().iter().map(|g| g.frame).collect::<Vec<_>>(),
        vec![1]
    );
}

const HEADER: AudioHeader = AudioHeader {
    channels: 2,
    bits: 16,
    rate: 48000,
    frame_size: 480,
    unknown: 1,
};

fn packets(frames: usize) -> Vec<Vec<u8>> {
    let packets = opus_tone_packets(frames);
    for p in &packets {
        assert_eq!(p.len(), 80, "CBR frame size");
    }
    packets
}

fn packed(version: u32, pk: &[Vec<u8>]) -> Vec<Vec<u8>> {
    (1..=pk.len() as u16)
        .map(|f| packed_audio_datagram(version, f, pk))
        .collect()
}

struct Played {
    frames: Vec<(u16, bool, usize)>,
    pcm: Vec<i16>,
    opus: Vec<Vec<u8>>,
}

fn run_audio(rx: &mut AudioReceiver, version: u32, datagrams: &[Vec<u8>]) -> Played {
    let mut p = Played {
        frames: Vec::new(),
        pcm: Vec::new(),
        opus: Vec::new(),
    };
    for d in datagrams {
        let h = parse_media(d, version).unwrap();
        rx.on_packet(&h, &d[h.payload_offset..], &mut |f: &AudioFrame<'_>| {
            p.frames.push((f.frame_index, f.concealed, f.samples));
            p.pcm.extend_from_slice(f.pcm);
            p.opus.push(f.opus.to_vec());
            assert_eq!((f.channels, f.sample_rate), (2, 48000));
        });
    }
    p
}

#[test]
fn packed_audio_with_losses_duplicates_and_opus_tone() {
    let n = 60;
    let pk = packets(n);
    let all = packed(9, &pk);
    let lost = [10usize, 20, 21, 30, 31, 32];
    let mut sent = Vec::new();
    let mut loss = AudioLossCounter::new(AudioCounting::PerPacket);
    for (i, d) in all.iter().enumerate() {
        let f = i + 1;
        if lost.contains(&f) {
            continue;
        }
        sent.push(d.clone());
        loss.count(f as u16);
        if f == 40 {
            sent.push(d.clone());
            loss.count(f as u16);
        }
    }
    let dec = OpusDecoder::new(&HEADER).unwrap();
    let mut rx = AudioReceiver::new(
        HEADER,
        AudioMode::Packed,
        Some(Box::new(dec)),
        Logger::default(),
    );
    let played = run_audio(&mut rx, 9, &sent);
    let idx: Vec<u16> = played.frames.iter().map(|f| f.0).collect();
    assert_eq!(idx, (1..=n as u16).collect::<Vec<_>>());
    let concealed: Vec<u16> = played.frames.iter().filter(|f| f.1).map(|f| f.0).collect();
    assert_eq!(concealed, vec![30]);
    assert!(played.frames.iter().all(|f| f.2 == 480));
    assert_eq!(played.pcm.len(), n * 960);
    let hz = left_frequency(&played.pcm[960 * 5..960 * 25]);
    assert!((hz - 440.0).abs() < 15.0, "{hz}");
    let st = rx.stats();
    assert_eq!(st.frames_concealed, 1);
    assert_eq!(st.frames_played, n as u64 - 1);
    assert_eq!(loss.take(), ((n - 6 + 1) as u32, 5));
}

#[test]
fn packed_audio_checks_and_codec() {
    let pk = packets(3);
    let mut rx = AudioReceiver::new(HEADER, AudioMode::Packed, None, Logger::default());
    let good = packed(12, &pk);
    let bad = vec![
        audio_datagram(12, 1, 1, 3, 80, 2, 1, 3, false, &[0; 240]),
        audio_datagram(12, 1, 1, 3, 80, 2, 1, 5, false, &[0; 239]),
        audio_datagram(12, 1, 1, 2, 80, 2, 1, 5, false, &[0; 240]),
    ];
    let p = run_audio(&mut rx, 12, &bad);
    assert!(p.frames.is_empty());
    assert_eq!(rx.stats().datagrams_dropped, 3);
    let p = run_audio(&mut rx, 12, &good);
    assert_eq!(
        p.frames.iter().map(|f| f.0).collect::<Vec<_>>(),
        vec![1, 2, 3]
    );
    assert_eq!(p.opus, pk);
    assert!(p.pcm.is_empty());
}

#[test]
fn single_unit_cloud_audio_takes_each_frame_once() {
    let n = 30;
    let pk = packets(n + 2);
    let mut datagrams = Vec::new();
    let mut pi = 0u16;
    for g in 1..=n {
        for f in g..g + 3 {
            datagrams.push((f, pk[f - 1].clone(), pi));
            pi += 1;
        }
    }
    let lost_packets = [4u16, 5, 40];
    let mut sent = Vec::new();
    let mut loss = AudioLossCounter::new(AudioCounting::PerNewFrame);
    for (f, p, pi) in &datagrams {
        if lost_packets.contains(pi) {
            continue;
        }
        sent.push(audio_datagram(12, *pi, *f as u16, 1, 0, 0, 1, 5, false, p));
        loss.count(*f as u16);
    }
    let dec = OpusDecoder::new(&HEADER).unwrap();
    let mut rx = AudioReceiver::new(
        HEADER,
        AudioMode::SingleUnit,
        Some(Box::new(dec)),
        Logger::default(),
    );
    let played = run_audio(&mut rx, 12, &sent);
    let idx: Vec<u16> = played.frames.iter().map(|f| f.0).collect();
    assert_eq!(idx, (1..=(n + 2) as u16).collect::<Vec<_>>());
    assert!(played.frames.iter().all(|f| !f.1));
    let hz = left_frequency(&played.pcm[960 * 5..]);
    assert!((hz - 440.0).abs() < 15.0, "{hz}");
    assert_eq!(loss.take(), ((n + 2) as u32, 0));
}

fn captured_log() -> (Logger, Arc<Mutex<Vec<String>>>) {
    let lines = Arc::new(Mutex::new(Vec::new()));
    let l = lines.clone();
    (
        Logger::new(Some(Arc::new(move |_, line: &str| {
            l.lock().unwrap().push(line.to_string())
        }))),
        lines,
    )
}

#[test]
fn single_unit_mode_unpacks_packed_cloud_datagrams() {
    let n = 40;
    let pk = packets(n + 1);
    let mut sent: Vec<Vec<u8>> = packed(12, &pk[..n]);
    sent.remove(9);
    sent.push(audio_datagram(
        12,
        100,
        n as u16,
        1,
        0,
        0,
        1,
        5,
        false,
        &pk[n - 1],
    ));
    sent.push(audio_datagram(
        12,
        101,
        n as u16 + 1,
        1,
        0,
        0,
        1,
        5,
        false,
        &pk[n],
    ));
    let (log, lines) = captured_log();
    let dec = OpusDecoder::new(&HEADER).unwrap();
    let mut rx = AudioReceiver::new(HEADER, AudioMode::SingleUnit, Some(Box::new(dec)), log);
    let played = run_audio(&mut rx, 12, &sent);
    let idx: Vec<u16> = played.frames.iter().map(|f| f.0).collect();
    assert_eq!(idx, (1..=n as u16 + 1).collect::<Vec<_>>());
    assert!(played.frames.iter().all(|f| !f.1), "nothing concealed");
    assert_eq!(played.opus, pk);
    let hz = left_frequency(&played.pcm[960 * 5..]);
    assert!((hz - 440.0).abs() < 15.0, "{hz}");
    assert_eq!(rx.stats().decode_errors, 0);
    let lines = lines.lock().unwrap();
    assert_eq!(
        lines
            .iter()
            .filter(|l| l.starts_with("audio: cloud datagrams are packed"))
            .collect::<Vec<_>>(),
        vec!["audio: cloud datagrams are packed (1 new + 2 copies of 80 bytes), units are decoded separately"]
    );
}

#[test]
fn packets_longer_than_the_header_frame_size_are_decoded() {
    let mut enc = OpusEncoder::new(48000, 2, false, Some(64000)).unwrap();
    let t = tone(440.0, 16);
    let pk: Vec<Vec<u8>> = t
        .chunks(2)
        .map(|two| enc.encode(&two.concat(), 400).unwrap())
        .collect();
    let sent: Vec<Vec<u8>> = pk
        .iter()
        .enumerate()
        .filter(|(i, _)| *i != 4)
        .map(|(i, p)| audio_datagram(12, i as u16, i as u16 + 1, 1, 0, 0, 1, 5, false, p))
        .collect();
    let dec = OpusDecoder::new(&HEADER).unwrap();
    let mut rx = AudioReceiver::new(
        HEADER,
        AudioMode::SingleUnit,
        Some(Box::new(dec)),
        Logger::default(),
    );
    let played = run_audio(&mut rx, 12, &sent);
    assert_eq!(rx.stats().decode_errors, 0);
    let concealed: Vec<u16> = played.frames.iter().filter(|f| f.1).map(|f| f.0).collect();
    assert_eq!(concealed, vec![5]);
    assert!(
        played.frames.iter().all(|f| f.2 == 960),
        "{:?}",
        played.frames
    );
    let hz = left_frequency(&played.pcm[1920 * 2..1920 * 4]);
    assert!((hz - 440.0).abs() < 15.0, "{hz}");
}

#[test]
fn silent_start_and_first_sound_are_logged() {
    let mut enc = OpusEncoder::new(48000, 2, false, None).unwrap();
    let silence = vec![0i16; 960];
    let mut pk: Vec<Vec<u8>> = (0..520)
        .map(|_| enc.encode(&silence, 400).unwrap())
        .collect();
    pk.extend(tone(440.0, 20).iter().map(|f| enc.encode(f, 400).unwrap()));
    let sent: Vec<Vec<u8>> = pk
        .iter()
        .enumerate()
        .map(|(i, p)| audio_datagram(12, i as u16, i as u16 + 1, 1, 0, 0, 1, 5, false, p))
        .collect();
    let (log, lines) = captured_log();
    let dec = OpusDecoder::new(&HEADER).unwrap();
    let mut rx = AudioReceiver::new(HEADER, AudioMode::SingleUnit, Some(Box::new(dec)), log);
    run_audio(&mut rx, 12, &sent);
    let lines = lines.lock().unwrap();
    let level = lines
        .iter()
        .find(|l| l.starts_with("audio: level after 500 frames: peak "))
        .expect("level line");
    assert!(level.contains("(silent)"), "{level}");
    let start = lines
        .iter()
        .find(|l| l.starts_with("audio: sound starts at frame "))
        .expect("sound line");
    let frame: u16 = start["audio: sound starts at frame ".len()..]
        .split(' ')
        .next()
        .unwrap()
        .parse()
        .unwrap();
    assert!((521..=523).contains(&frame), "{start}");
}

#[test]
fn silence_padded_at_a_constant_bitrate_is_told_by_its_zero_bytes_and_a_later_silence_is_logged() {
    let mut enc = OpusEncoder::new(48000, 2, false, Some(64_000)).unwrap();
    let silence = vec![0i16; 960];
    let mut pk: Vec<Vec<u8>> = tone(440.0, 520)
        .iter()
        .map(|f| enc.encode(f, 400).unwrap())
        .collect();
    pk.extend((0..520).map(|_| enc.encode(&silence, 400).unwrap()));
    let sizes: HashSet<usize> = pk.iter().map(Vec::len).collect();
    assert_eq!(sizes.len(), 1, "a constant bitrate: {sizes:?}");
    let sent: Vec<Vec<u8>> = pk
        .iter()
        .enumerate()
        .map(|(i, p)| audio_datagram(12, i as u16, i as u16 + 1, 1, 0, 0, 1, 5, false, p))
        .collect();
    let (log, lines) = captured_log();
    let dec = OpusDecoder::new(&HEADER).unwrap();
    let mut rx = AudioReceiver::new(HEADER, AudioMode::SingleUnit, Some(Box::new(dec)), log);
    run_audio(&mut rx, 12, &sent);
    let lines = lines.lock().unwrap();
    let zeros = |line: &str| -> u64 {
        let at = line.find("% of their bytes zero").expect("zero share");
        line[..at].rsplit(' ').next().unwrap().parse().unwrap()
    };
    let level = lines
        .iter()
        .find(|l| l.starts_with("audio: level after 500 frames: peak "))
        .expect("level line");
    assert!(!level.contains("(silent)") && zeros(level) < 20, "{level}");
    let silent = lines
        .iter()
        .find(|l| l.starts_with("audio: silent since 500 frames"))
        .expect("silence line");
    assert!(zeros(silent) > 50, "{silent}");
}

#[test]
fn concealment_without_decoder_hands_over_empty_packets() {
    let pk = packets(8);
    let all = packed(9, &pk);
    let sent: Vec<Vec<u8>> = all
        .iter()
        .enumerate()
        .filter(|(i, _)| ![3usize, 4, 5].contains(i))
        .map(|(_, d)| d.clone())
        .collect();
    let mut rx = AudioReceiver::new(HEADER, AudioMode::Packed, None, Logger::default());
    let p = run_audio(&mut rx, 9, &sent);
    let got: Vec<(u16, bool)> = p.frames.iter().map(|f| (f.0, f.1)).collect();
    assert_eq!(
        got,
        vec![
            (1, false),
            (2, false),
            (3, false),
            (4, true),
            (5, false),
            (6, false),
            (7, false),
            (8, false)
        ]
    );
    assert!(p.opus[3].is_empty());
}

struct FailingDecoder;

impl AudioDecoder for FailingDecoder {
    fn decode(&mut self, packet: &[u8], out: &mut [i16]) -> Result<usize, String> {
        if packet.is_empty() {
            out[..960].fill(0);
            Ok(480)
        } else {
            Err("bad packet".into())
        }
    }
}

#[test]
fn decoder_errors_are_concealed() {
    let pk = packets(3);
    let mut rx = AudioReceiver::new(
        HEADER,
        AudioMode::Packed,
        Some(Box::new(FailingDecoder)),
        Logger::default(),
    );
    let p = run_audio(&mut rx, 9, &packed(9, &pk));
    assert_eq!(p.frames.len(), 3);
    assert!(p.frames.iter().all(|f| f.1));
    assert_eq!(rx.stats().decode_errors, 3);
}

fn haptics_datagrams(n: usize) -> Vec<(u16, Vec<u8>)> {
    (0..n as u16)
        .map(|f| (f, packed_haptics_datagram(f, f)))
        .collect()
}

fn run_haptics(rx: &mut HapticsReceiver, ds: &[Vec<u8>]) -> Vec<u16> {
    let mut got = Vec::new();
    for d in ds {
        let h = parse_media(d, 12).unwrap();
        assert_eq!(h.kind, MediaKind::Haptics);
        rx.on_packet(&h, &d[h.payload_offset..], &mut |f| {
            assert_eq!((f.sample_rate, f.channels, f.pcm.len()), (3000, 2, 120));
            assert!(f.pcm.iter().all(|&b| b == f.frame_index as u8));
            got.push(f.frame_index);
        });
    }
    got
}

#[test]
fn haptics_console_and_cloud() {
    let all = haptics_datagrams(10);
    let sent: Vec<Vec<u8>> = all
        .iter()
        .filter(|(f, _)| *f != 4)
        .map(|(_, d)| d.clone())
        .collect();
    let mut c = HapticsReceiver::new(HapticsMode::Console);
    assert_eq!(run_haptics(&mut c, &sent), vec![0, 1, 2, 3, 5, 6, 7, 8, 9]);
    let mut c = HapticsReceiver::new(HapticsMode::Cloud);
    assert_eq!(run_haptics(&mut c, &sent), (0..10).collect::<Vec<u16>>());
    let bad = audio_datagram(12, 1, 20, 3, 120, 2, 1, 0, true, &[0; 100]);
    assert!(run_haptics(&mut c, &[bad]).is_empty());
}

#[test]
fn feedback_state_layout() {
    let s = ControllerState {
        gyro: [1.0, -2.0, 31.0],
        accel: [0.5, -1.0, 9.0],
        left_x: 1000,
        left_y: -1000,
        right_x: 32767,
        right_y: -32768,
        ..ControllerState::IDLE
    };
    let p = encode_state(&s, 9);
    assert_eq!(p.len(), 25);
    let le = |v: u16| v.to_le_bytes();
    let mut want = vec![0xa0];
    for v in [33859u16, 30583, 65535] {
        want.extend_from_slice(&le(v));
    }
    for v in [36044u16, 26214, 65535] {
        want.extend_from_slice(&le(v));
    }
    let q: u32 = 6 | (255 << 3) | (255 << 12) | (255 << 21);
    want.extend_from_slice(&q.to_le_bytes());
    want.extend_from_slice(&hex("03e8 fc18 7fff 8000"));
    assert_eq!(p, want);
    let p12 = encode_state(&s, 12);
    assert_eq!(&p12[..25], &want[..]);
    assert_eq!(&p12[25..], &[0, 0, 1]);
    let v = compress_orientation([0.0, -1.0, 0.0, 0.0]);
    assert_eq!(v & 7, 1 | (1 << 1));
    let back = decompress_orientation(v);
    assert!((back[1] + 1.0).abs() < 1e-3);
}

#[test]
fn history_events_layout_ring_and_refresh() {
    let pressed = ControllerState {
        buttons: button::CROSS | button::OPTIONS,
        l2: 0x80,
        touches: [
            Touch {
                id: 5,
                x: 1000,
                y: 500,
            },
            Touch::NONE,
        ],
        ..ControllerState::IDLE
    };
    let ev = diff_events(&ControllerState::IDLE, &pressed);
    let mut h = History::new();
    h.push(&ev);
    let p = h.pop().unwrap();
    assert_eq!(p, hex("80 86 80  80 ac  80 88 ff  d0 05 3e 81 f4"));
    assert_eq!(parse_history(&p).unwrap().len(), 4);
    let released = ControllerState {
        buttons: button::OPTIONS,
        touches: [Touch::NONE; 2],
        ..pressed
    };
    h.push(&diff_events(&pressed, &released));
    let p = h.pop().unwrap();
    assert_eq!(
        p,
        hex("80 88 00  c0 05 3e 81 f4  80 86 80  80 ac  80 88 ff  d0 05 3e 81 f4")
    );
    let a = ControllerState {
        touches: [Touch { id: 1, x: 1, y: 2 }, Touch::NONE],
        ..ControllerState::IDLE
    };
    let b = ControllerState {
        touches: [Touch { id: 2, x: 3, y: 4 }, Touch::NONE],
        ..ControllerState::IDLE
    };
    assert_eq!(
        diff_events(&a, &b),
        vec![
            HistoryEvent::Touch {
                down: false,
                id: 1,
                x: 1,
                y: 2
            },
            HistoryEvent::Touch {
                down: true,
                id: 2,
                x: 3,
                y: 4
            }
        ]
    );
    let mut h = History::new();
    let many: Vec<HistoryEvent> = (0..40)
        .map(|i| HistoryEvent::trigger(0x86, i as u8))
        .collect();
    h.push(&many);
    assert_eq!(h.pop().unwrap().len(), 40 * 3);
    h.push(&[HistoryEvent::trigger(0x87, 1)]);
    assert_eq!(h.pop().unwrap().len(), 33 * 3);
    let mut h = History::new();
    h.refresh(&pressed);
    let ev = parse_history(&h.pop().unwrap()).unwrap();
    assert_eq!(ev.len(), 18);
    assert_eq!(ev[0], HistoryEvent::trigger(0x87, 0));
    assert_eq!(ev[1], HistoryEvent::trigger(0x86, 0x80));
    assert!(ev.contains(&HistoryEvent::Button {
        code: 0x8c,
        value: None,
        pressed: true
    }));
    assert!(ev.contains(&HistoryEvent::Button {
        code: 0x88,
        value: Some(0xff),
        pressed: true
    }));
    assert!(ev.contains(&HistoryEvent::Button {
        code: 0x8e,
        value: None,
        pressed: false
    }));
}

#[test]
fn state_equality_and_motion_changes() {
    let a = ControllerState::IDLE;
    let mut b = a;
    b.gyro[0] = 5e-8;
    assert!(a.same_as(&b));
    b.buttons = button::R1;
    assert!(!a.same_as(&b));
    assert!(a.same_sticks_and_motion(&b));
    b.left_y = 1;
    assert!(!a.same_sticks_and_motion(&b));
}

#[test]
fn console_feedback_parsing() {
    let mut e = EffectsState::new();
    assert_eq!(
        e.on_message(7, &[0x00, 0xff, 0x10]),
        vec![FeedbackEvent::Rumble {
            left: 0xff,
            right: 0x10
        }]
    );
    assert!(e.on_message(7, &[0, 1]).is_empty());
    let mut t = vec![0u8; 25];
    t[1] = 0x21;
    t[2] = 0x26;
    for (i, b) in t.iter_mut().enumerate().skip(5) {
        *b = i as u8;
    }
    let FeedbackEvent::TriggerEffects { left, right } = e.on_message(11, &t)[0] else {
        panic!()
    };
    assert_eq!(left, [0x21, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]);
    assert_eq!(right, [0x26, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24]);
    assert!(e.on_message(11, &t[..24]).is_empty());
    let mut p = vec![0u8; 25];
    p[0..2].copy_from_slice(&7u16.to_be_bytes());
    p[4..8].copy_from_slice(&99u32.to_be_bytes());
    p[8] = 1;
    p[11] = 255;
    p[12] = 1;
    p[20] = 2;
    p[21] = 3;
    let info = parse_pad_info(&p).unwrap();
    assert_eq!((info.sequence, info.timestamp), (Some(7), Some(99)));
    assert_eq!(
        e.on_message(9, &p),
        vec![
            FeedbackEvent::LightBar { r: 0, g: 0, b: 255 },
            FeedbackEvent::PlayerIndex(1),
            FeedbackEvent::EffectIntensity {
                kind: IntensityKind::Haptic,
                value: 2
            },
            FeedbackEvent::EffectIntensity {
                kind: IntensityKind::Trigger,
                value: 3
            },
            FeedbackEvent::MotionReset,
        ]
    );
    assert_eq!(e.on_message(9, &p), vec![FeedbackEvent::MotionReset]);
    let mut q = p[8..].to_vec();
    q[0] = 2;
    q[4] = 0;
    assert_eq!(e.on_message(9, &q), vec![FeedbackEvent::PlayerIndex(2)]);
    assert!(e.on_message(9, &p[..20]).is_empty());
    let mut fresh = EffectsState::new();
    let mut r = vec![0u8; 17];
    r[12] = 1;
    r[13] = 1;
    assert!(fresh.on_message(9, &r).is_empty());
}

#[test]
fn microphone_packing() {
    let mut m = MicrophonePacker::new().unwrap();
    let loud: Vec<Vec<i16>> = tone(440.0, 6)
        .into_iter()
        .map(|f| f.into_iter().step_by(2).collect())
        .collect();
    assert_eq!(m.push(&loud[0]).unwrap(), None);
    assert_eq!(m.push(&loud[1]).unwrap(), None);
    let p = m.push(&loud[2]).unwrap().expect("third frame sends");
    let q = m.push(&loud[3]).unwrap().expect("fourth frame sends");
    assert_eq!(&q[80..120], &p[0..40]);
    assert_eq!(&q[40..80], &p[80..120]);
    assert!(m.push(&[0i16; 100]).is_err());
}
