use super::bits::{escape_nal, unescape_nal, BitReader, BitWriter};

const HEADER_BYTES: usize = 512;
const MAX_RPS_PICTURES: u32 = 16;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum CodecFamily {
    H264,
    H265,
}

impl From<crate::Codec> for CodecFamily {
    fn from(c: crate::Codec) -> Self {
        match c {
            crate::Codec::H264 => CodecFamily::H264,
            crate::Codec::H265 | crate::Codec::H265Hdr => CodecFamily::H265,
        }
    }
}

pub fn nal_units(stream: &[u8]) -> Vec<std::ops::Range<usize>> {
    let mut starts = Vec::new();
    let mut i = 0;
    while i + 3 <= stream.len() {
        if stream[i] == 0 && stream[i + 1] == 0 && stream[i + 2] == 1 {
            starts.push(i);
            i += 3;
        } else {
            i += 1;
        }
    }
    let mut out = Vec::with_capacity(starts.len());
    for (n, &s) in starts.iter().enumerate() {
        let begin = s + 3;
        let mut end = starts.get(n + 1).copied().unwrap_or(stream.len());
        while end > begin && stream[end - 1] == 0 {
            end -= 1;
        }
        if end > begin {
            out.push(begin..end);
        }
    }
    out
}

pub fn nal_type(codec: CodecFamily, nal: &[u8]) -> Option<u8> {
    let b = *nal.first()?;
    Some(match codec {
        CodecFamily::H264 => b & 0x1f,
        CodecFamily::H265 => (b >> 1) & 0x3f,
    })
}

fn header_len(codec: CodecFamily) -> usize {
    match codec {
        CodecFamily::H264 => 1,
        CodecFamily::H265 => 2,
    }
}

pub fn is_slice(codec: CodecFamily, t: u8) -> bool {
    match codec {
        CodecFamily::H264 => t == 1 || t == 5,
        CodecFamily::H265 => t <= 21 && !(10..=15).contains(&t),
    }
}

pub fn is_keyframe_type(codec: CodecFamily, t: u8) -> bool {
    match codec {
        CodecFamily::H264 => t == 5,
        CodecFamily::H265 => (16..=21).contains(&t),
    }
}

fn ceil_log2(x: u32) -> u32 {
    if x <= 1 {
        0
    } else {
        32 - (x - 1).leading_zeros()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct H264Sps {
    pub id: u32,
    pub log2_max_frame_num: u32,
    pub poc_type: u32,
    pub log2_max_poc_lsb: u32,
    pub delta_pic_order_always_zero: bool,
    pub frame_mbs_only: bool,
    pub separate_colour_plane: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct H264Pps {
    pub id: u32,
    pub sps_id: u32,
    pub bottom_field_pic_order_in_frame_present: bool,
    pub redundant_pic_cnt_present: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ShortTermRps {
    pub negatives: Vec<(i32, bool)>,
    pub positives: Vec<(i32, bool)>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct H265Sps {
    pub id: u32,
    pub log2_max_poc_lsb: u32,
    pub separate_colour_plane: bool,
    pub address_bits: Option<u32>,
    pub rps_sets: Option<Vec<ShortTermRps>>,
    pub long_term: Option<LongTermSps>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LongTermSps {
    pub present: bool,
    pub pictures: Vec<(u32, bool)>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LongTermRef {
    pub poc_lsb: u32,
    pub msb_cycle: Option<u32>,
    pub used: bool,
    pub used_flag_position: Option<usize>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct H265Pps {
    pub id: u32,
    pub sps_id: u32,
    pub dependent_slice_segments_enabled: bool,
    pub output_flag_present: bool,
    pub num_extra_slice_header_bits: u32,
    pub lists_modification_present: Option<bool>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ParameterSets {
    pub h264_sps: Vec<H264Sps>,
    pub h264_pps: Vec<H264Pps>,
    pub h265_sps: Vec<H265Sps>,
    pub h265_pps: Vec<H265Pps>,
}

fn put<T>(list: &mut Vec<T>, v: T, id: impl Fn(&T) -> u32) {
    let key = id(&v);
    list.retain(|x| id(x) != key);
    list.push(v);
}

impl ParameterSets {
    pub fn parse(codec: CodecFamily, header: &[u8]) -> Self {
        let mut ps = Self::default();
        for r in nal_units(header) {
            let nal = &header[r];
            match (codec, nal_type(codec, nal)) {
                (CodecFamily::H264, Some(7)) => {
                    if let Some(s) = parse_h264_sps(nal) {
                        put(&mut ps.h264_sps, s, |s| s.id);
                    }
                }
                (CodecFamily::H264, Some(8)) => {
                    if let Some(p) = parse_h264_pps(nal) {
                        put(&mut ps.h264_pps, p, |p| p.id);
                    }
                }
                (CodecFamily::H265, Some(33)) => {
                    if let Some(s) = parse_h265_sps(nal) {
                        put(&mut ps.h265_sps, s, |s| s.id);
                    }
                }
                (CodecFamily::H265, Some(34)) => {
                    if let Some(p) = parse_h265_pps(nal) {
                        put(&mut ps.h265_pps, p, |p| p.id);
                    }
                }
                _ => {}
            }
        }
        ps
    }

    pub fn readable(&self) -> bool {
        !self.h264_sps.is_empty() || !self.h265_sps.is_empty()
    }

    fn h264_context(&self, pps_id: u32) -> Option<(&H264Sps, H264Pps)> {
        let pps = self
            .h264_pps
            .iter()
            .find(|p| p.id == pps_id)
            .copied()
            .unwrap_or(H264Pps {
                id: pps_id,
                sps_id: self.h264_sps.first()?.id,
                bottom_field_pic_order_in_frame_present: false,
                redundant_pic_cnt_present: false,
            });
        let sps = self
            .h264_sps
            .iter()
            .find(|s| s.id == pps.sps_id)
            .or(self.h264_sps.first())?;
        Some((sps, pps))
    }

    fn h265_context(&self, pps_id: u32) -> (Option<&H265Sps>, H265Pps) {
        let pps = self
            .h265_pps
            .iter()
            .find(|p| p.id == pps_id)
            .copied()
            .unwrap_or(H265Pps {
                id: pps_id,
                sps_id: self.h265_sps.first().map_or(0, |s| s.id),
                dependent_slice_segments_enabled: false,
                output_flag_present: false,
                num_extra_slice_header_bits: 0,
                lists_modification_present: None,
            });
        let sps = self
            .h265_sps
            .iter()
            .find(|s| s.id == pps.sps_id)
            .or(self.h265_sps.first());
        (sps, pps)
    }
}

fn skip_h264_scaling_list(r: &mut BitReader<'_>, size: usize) -> Option<()> {
    let (mut last, mut next) = (8i32, 8i32);
    for _ in 0..size {
        if next != 0 {
            let delta = r.se()?;
            next = last.wrapping_add(delta).rem_euclid(256);
        }
        if next != 0 {
            last = next;
        }
    }
    Some(())
}

fn parse_h264_sps(nal: &[u8]) -> Option<H264Sps> {
    let rbsp = unescape_nal(nal);
    let mut r = BitReader::new(&rbsp);
    r.skip(8)?;
    let profile_idc = r.bits(8)?;
    r.skip(16)?;
    let id = r.ue()?;
    let mut separate_colour_plane = false;
    if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(&profile_idc) {
        let chroma_format_idc = r.ue()?;
        if chroma_format_idc == 3 {
            separate_colour_plane = r.bit()?;
        }
        r.ue()?;
        r.ue()?;
        r.skip(1)?;
        if r.bit()? {
            let lists = if chroma_format_idc == 3 { 12 } else { 8 };
            for i in 0..lists {
                if r.bit()? {
                    skip_h264_scaling_list(&mut r, if i < 6 { 16 } else { 64 })?;
                }
            }
        }
    }
    let v = r.ue()?;
    if v > 12 {
        return None;
    }
    let mut sps = H264Sps {
        id,
        log2_max_frame_num: v + 4,
        poc_type: 2,
        log2_max_poc_lsb: 4,
        delta_pic_order_always_zero: true,
        frame_mbs_only: true,
        separate_colour_plane,
    };
    if let Some((poc_type, lsb, always_zero, frame_mbs_only)) = parse_h264_poc_fields(&mut r) {
        sps.poc_type = poc_type;
        sps.log2_max_poc_lsb = lsb;
        sps.delta_pic_order_always_zero = always_zero;
        sps.frame_mbs_only = frame_mbs_only;
    }
    Some(sps)
}

fn parse_h264_poc_fields(r: &mut BitReader<'_>) -> Option<(u32, u32, bool, bool)> {
    let poc_type = r.ue()?;
    let mut lsb = 4;
    let mut always_zero = false;
    match poc_type {
        0 => {
            let v = r.ue()?;
            if v > 12 {
                return None;
            }
            lsb = v + 4;
        }
        1 => {
            always_zero = r.bit()?;
            r.se()?;
            r.se()?;
            let n = r.ue()?;
            if n > 255 {
                return None;
            }
            for _ in 0..n {
                r.se()?;
            }
        }
        2 => {}
        _ => return None,
    }
    r.ue()?;
    r.skip(1)?;
    r.ue()?;
    r.ue()?;
    let frame_mbs_only = r.bit()?;
    Some((poc_type, lsb, always_zero, frame_mbs_only))
}

fn parse_h264_pps(nal: &[u8]) -> Option<H264Pps> {
    let rbsp = unescape_nal(nal);
    let mut r = BitReader::new(&rbsp);
    r.skip(8)?;
    let id = r.ue()?;
    let sps_id = r.ue()?;
    r.skip(1)?;
    let bottom = r.bit()?;
    let groups = r.ue()?;
    if groups > 7 {
        return None;
    }
    if groups > 0 {
        match r.ue()? {
            0 => {
                for _ in 0..=groups {
                    r.ue()?;
                }
            }
            2 => {
                for _ in 0..groups {
                    r.ue()?;
                    r.ue()?;
                }
            }
            3..=5 => {
                r.skip(1)?;
                r.ue()?;
            }
            6 => {
                let units = r.ue()?.checked_add(1)?;
                if units > 1 << 20 {
                    return None;
                }
                r.skip(units as usize * ceil_log2(groups + 1) as usize)?;
            }
            _ => {}
        }
    }
    r.ue()?;
    r.ue()?;
    r.skip(3)?;
    r.se()?;
    r.se()?;
    r.se()?;
    r.skip(2)?;
    let redundant = r.bit()?;
    Some(H264Pps {
        id,
        sps_id,
        bottom_field_pic_order_in_frame_present: bottom,
        redundant_pic_cnt_present: redundant,
    })
}

fn skip_profile_tier_level(r: &mut BitReader<'_>, max_sub_layers_minus1: u32) -> Option<()> {
    r.skip(88 + 8)?;
    let n = max_sub_layers_minus1 as usize;
    let mut present = [(false, false); 8];
    for p in present.iter_mut().take(n) {
        *p = (r.bit()?, r.bit()?);
    }
    if n > 0 {
        r.skip(2 * (8 - n))?;
    }
    for &(profile, level) in present.iter().take(n) {
        if profile {
            r.skip(88)?;
        }
        if level {
            r.skip(8)?;
        }
    }
    Some(())
}

fn skip_h265_scaling_list(r: &mut BitReader<'_>) -> Option<()> {
    for size_id in 0..4u32 {
        let step = if size_id == 3 { 3 } else { 1 };
        let mut matrix = 0;
        while matrix < 6 {
            if !r.bit()? {
                r.ue()?;
            } else {
                let coefs = 64.min(1u32 << (4 + (size_id << 1)));
                if size_id > 1 {
                    r.se()?;
                }
                for _ in 0..coefs {
                    r.se()?;
                }
            }
            matrix += step;
        }
    }
    Some(())
}

fn parse_st_rps(
    r: &mut BitReader<'_>,
    idx: usize,
    num_sets: usize,
    sets: &[ShortTermRps],
) -> Option<(ShortTermRps, Option<Vec<usize>>)> {
    let inter = idx != 0 && r.bit()?;
    if inter {
        let delta_idx = if idx == num_sets {
            r.ue()? as usize + 1
        } else {
            1
        };
        let reference = sets.get(idx.checked_sub(delta_idx)?)?;
        let sign = r.bit()?;
        let abs = r.ue()?;
        if abs >= 1 << 15 {
            return None;
        }
        let delta_rps = if sign {
            -(abs as i32 + 1)
        } else {
            abs as i32 + 1
        };
        let nn = reference.negatives.len();
        let np = reference.positives.len();
        let total = nn + np;
        let mut used = vec![false; total + 1];
        let mut use_delta = vec![true; total + 1];
        for j in 0..=total {
            used[j] = r.bit()?;
            if !used[j] {
                use_delta[j] = r.bit()?;
            }
        }
        let mut negatives = Vec::new();
        for j in (0..np).rev() {
            let d = reference.positives[j].0 + delta_rps;
            if d < 0 && use_delta[nn + j] {
                negatives.push((d, used[nn + j]));
            }
        }
        if delta_rps < 0 && use_delta[total] {
            negatives.push((delta_rps, used[total]));
        }
        for j in 0..nn {
            let d = reference.negatives[j].0 + delta_rps;
            if d < 0 && use_delta[j] {
                negatives.push((d, used[j]));
            }
        }
        let mut positives = Vec::new();
        for j in (0..nn).rev() {
            let d = reference.negatives[j].0 + delta_rps;
            if d > 0 && use_delta[j] {
                positives.push((d, used[j]));
            }
        }
        if delta_rps > 0 && use_delta[total] {
            positives.push((delta_rps, used[total]));
        }
        for j in 0..np {
            let d = reference.positives[j].0 + delta_rps;
            if d > 0 && use_delta[nn + j] {
                positives.push((d, used[nn + j]));
            }
        }
        let max = MAX_RPS_PICTURES as usize;
        if negatives.len() > max || positives.len() > max {
            return None;
        }
        return Some((
            ShortTermRps {
                negatives,
                positives,
            },
            None,
        ));
    }
    let nn = r.ue()?;
    let np = r.ue()?;
    if nn > MAX_RPS_PICTURES || np > MAX_RPS_PICTURES {
        return None;
    }
    let mut rps = ShortTermRps::default();
    let mut flags = Vec::with_capacity(nn as usize);
    let mut poc = 0i32;
    for _ in 0..nn {
        let d = r.ue()?;
        if d >= 1 << 15 {
            return None;
        }
        poc -= d as i32 + 1;
        flags.push(r.position());
        rps.negatives.push((poc, r.bit()?));
    }
    poc = 0;
    for _ in 0..np {
        let d = r.ue()?;
        if d >= 1 << 15 {
            return None;
        }
        poc += d as i32 + 1;
        rps.positives.push((poc, r.bit()?));
    }
    Some((rps, Some(flags)))
}

fn parse_h265_sps(nal: &[u8]) -> Option<H265Sps> {
    let rbsp = unescape_nal(nal);
    let mut r = BitReader::new(&rbsp);
    r.skip(16)?;
    r.skip(4)?;
    let max_sub_layers_minus1 = r.bits(3)?;
    if max_sub_layers_minus1 > 6 {
        return None;
    }
    r.skip(1)?;
    skip_profile_tier_level(&mut r, max_sub_layers_minus1)?;
    let id = r.ue()?;
    let chroma_format_idc = r.ue()?;
    let separate_colour_plane = chroma_format_idc == 3 && r.bit()?;
    let width = r.ue()?;
    let height = r.ue()?;
    if r.bit()? {
        for _ in 0..4 {
            r.ue()?;
        }
    }
    r.ue()?;
    r.ue()?;
    let v = r.ue()?;
    if v > 12 {
        return None;
    }
    let log2_max_poc_lsb = v + 4;
    let mut sps = H265Sps {
        id,
        log2_max_poc_lsb,
        separate_colour_plane,
        address_bits: None,
        rps_sets: None,
        long_term: None,
    };
    if let Some((bits, sets)) = parse_h265_sps_rps(&mut r, max_sub_layers_minus1, width, height) {
        sps.address_bits = Some(bits);
        sps.rps_sets = Some(sets);
        sps.long_term = parse_long_term_sps(&mut r, log2_max_poc_lsb);
    }
    Some(sps)
}

fn parse_h265_sps_rps(
    r: &mut BitReader<'_>,
    max_sub_layers_minus1: u32,
    width: u32,
    height: u32,
) -> Option<(u32, Vec<ShortTermRps>)> {
    let ordering_all = r.bit()?;
    let first = if ordering_all {
        0
    } else {
        max_sub_layers_minus1
    };
    for _ in first..=max_sub_layers_minus1 {
        r.ue()?;
        r.ue()?;
        r.ue()?;
    }
    let min_cb = r.ue()?.checked_add(3)?;
    let ctb = min_cb.checked_add(r.ue()?)?;
    if !(3..=7).contains(&ctb) {
        return None;
    }
    r.ue()?;
    r.ue()?;
    r.ue()?;
    r.ue()?;
    if r.bit()? && r.bit()? {
        skip_h265_scaling_list(r)?;
    }
    r.skip(2)?;
    if r.bit()? {
        r.skip(8)?;
        r.ue()?;
        r.ue()?;
        r.skip(1)?;
    }
    let n = r.ue()? as usize;
    if n > 64 {
        return None;
    }
    let mut sets: Vec<ShortTermRps> = Vec::with_capacity(n);
    for i in 0..n {
        let (s, _) = parse_st_rps(r, i, n, &sets)?;
        sets.push(s);
    }
    let size = 1u32 << ctb;
    let ctbs = width.div_ceil(size).checked_mul(height.div_ceil(size))?;
    Some((ceil_log2(ctbs), sets))
}

fn parse_long_term_sps(r: &mut BitReader<'_>, log2_max_poc_lsb: u32) -> Option<LongTermSps> {
    let present = r.bit()?;
    let mut pictures = Vec::new();
    if present {
        let n = r.ue()?;
        if n > 32 {
            return None;
        }
        for _ in 0..n {
            pictures.push((r.bits(log2_max_poc_lsb)?, r.bit()?));
        }
    }
    Some(LongTermSps { present, pictures })
}

fn parse_h265_pps(nal: &[u8]) -> Option<H265Pps> {
    let rbsp = unescape_nal(nal);
    let mut r = BitReader::new(&rbsp);
    r.skip(16)?;
    let id = r.ue()?;
    let sps_id = r.ue()?;
    let dependent = r.bit()?;
    let output = r.bit()?;
    let extra = r.bits(3)?;
    let lists = parse_h265_pps_lists_modification(&mut r);
    Some(H265Pps {
        id,
        sps_id,
        dependent_slice_segments_enabled: dependent,
        output_flag_present: output,
        num_extra_slice_header_bits: extra,
        lists_modification_present: lists,
    })
}

fn parse_h265_pps_lists_modification(r: &mut BitReader<'_>) -> Option<bool> {
    r.skip(2)?;
    r.ue()?;
    r.ue()?;
    r.se()?;
    r.skip(2)?;
    if r.bit()? {
        r.ue()?;
    }
    r.se()?;
    r.se()?;
    r.skip(4)?;
    let tiles = r.bit()?;
    r.skip(1)?;
    if tiles {
        let columns = r.ue()?;
        let rows = r.ue()?;
        if columns > 64 || rows > 64 {
            return None;
        }
        if !r.bit()? {
            for _ in 0..columns + rows {
                r.ue()?;
            }
        }
        r.skip(1)?;
    }
    r.skip(1)?;
    if r.bit()? {
        r.skip(1)?;
        if !r.bit()? {
            r.se()?;
            r.se()?;
        }
    }
    if r.bit()? {
        skip_h265_scaling_list(r)?;
    }
    r.bit()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SliceKind {
    I,
    P,
    Other,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SliceInfo {
    pub nal_type: u8,
    pub kind: SliceKind,
    pub dependent: bool,
    pub is_reference: bool,
    pub temporal_id: u8,
    pub pic_id: Option<u32>,
    pub pic_id_modulus: u32,
    pub reference: Option<u32>,
    pub rps_known: bool,
    pub negatives: Vec<(i32, bool)>,
    pub positives: Vec<(i32, bool)>,
    pub used_flag_positions: Vec<usize>,
    pub long_terms: Option<Vec<LongTermRef>>,
    pub lists_modification_present: Option<bool>,
}

impl SliceInfo {
    fn new(nal_type: u8) -> Self {
        Self {
            nal_type,
            kind: SliceKind::Other,
            dependent: false,
            is_reference: true,
            temporal_id: 0,
            pic_id: None,
            pic_id_modulus: 0,
            reference: None,
            rps_known: false,
            negatives: Vec::new(),
            positives: Vec::new(),
            used_flag_positions: Vec::new(),
            long_terms: None,
            lists_modification_present: None,
        }
    }

    pub fn uses_references(&self) -> bool {
        self.negatives.iter().any(|n| n.1)
            || self.positives.iter().any(|p| p.1)
            || self.long_terms.iter().flatten().any(|l| l.used)
    }
}

pub fn first_slice(codec: CodecFamily, picture: &[u8]) -> Option<std::ops::Range<usize>> {
    nal_units(picture)
        .into_iter()
        .find(|r| nal_type(codec, &picture[r.clone()]).is_some_and(|t| is_slice(codec, t)))
}

pub fn parse_slice(codec: CodecFamily, ps: &ParameterSets, nal: &[u8]) -> Option<SliceInfo> {
    let t = nal_type(codec, nal)?;
    let rbsp = unescape_nal(&nal[..nal.len().min(HEADER_BYTES)]);
    let mut r = BitReader::new(&rbsp);
    r.skip(8 * header_len(codec))?;
    match codec {
        CodecFamily::H264 => parse_h264_slice(t, (nal[0] >> 5) & 3, ps, &mut r),
        CodecFamily::H265 => {
            let mut info = parse_h265_slice(t, ps, &mut r)?;
            info.temporal_id = (nal.get(1)? & 7).saturating_sub(1);
            Some(info)
        }
    }
}

fn parse_h264_slice(
    t: u8,
    nal_ref_idc: u8,
    ps: &ParameterSets,
    r: &mut BitReader<'_>,
) -> Option<SliceInfo> {
    if t != 1 && t != 5 {
        return None;
    }
    r.ue()?;
    let mut info = SliceInfo::new(t);
    info.is_reference = nal_ref_idc != 0;
    info.kind = match r.ue()? {
        0 | 5 => SliceKind::P,
        2 | 7 => SliceKind::I,
        _ => SliceKind::Other,
    };
    let pps_id = r.ue()?;
    let Some((sps, pps)) = ps.h264_context(pps_id) else {
        return Some(info);
    };
    if sps.separate_colour_plane {
        r.skip(2)?;
    }
    info.pic_id = Some(r.bits(sps.log2_max_frame_num)?);
    info.pic_id_modulus = 1 << sps.log2_max_frame_num;
    if t != 1 || info.kind != SliceKind::P {
        return Some(info);
    }
    let mut field = false;
    if !sps.frame_mbs_only && r.bit()? {
        field = true;
        r.skip(1)?;
    }
    if sps.poc_type == 0 {
        r.skip(sps.log2_max_poc_lsb as usize)?;
        if pps.bottom_field_pic_order_in_frame_present && !field {
            r.se()?;
        }
    }
    if sps.poc_type == 1 && !sps.delta_pic_order_always_zero {
        r.se()?;
        if pps.bottom_field_pic_order_in_frame_present && !field {
            r.se()?;
        }
    }
    if pps.redundant_pic_cnt_present {
        r.ue()?;
    }
    if r.bit()? {
        r.ue()?;
    }
    let mut distance = 0u32;
    if r.bit()? {
        let mut found = false;
        for _ in 0..33 {
            let idc = r.ue()?;
            if idc == 3 {
                break;
            }
            let v = r.ue()?;
            if idc == 0 && !found {
                distance = v;
                found = true;
            }
        }
    }
    if field {
        return Some(info);
    }
    info.reference = Some(distance);
    Some(info)
}

fn parse_h265_slice(t: u8, ps: &ParameterSets, r: &mut BitReader<'_>) -> Option<SliceInfo> {
    if !is_slice(CodecFamily::H265, t) {
        return None;
    }
    let first = r.bit()?;
    if (16..=23).contains(&t) {
        r.skip(1)?;
    }
    let (sps, pps) = ps.h265_context(r.ue()?);
    let mut info = SliceInfo::new(t);
    info.lists_modification_present = pps.lists_modification_present;
    if !first {
        if pps.dependent_slice_segments_enabled {
            info.dependent = r.bit()?;
        }
        r.skip(sps?.address_bits? as usize)?;
        if info.dependent {
            return Some(info);
        }
    }
    r.skip(pps.num_extra_slice_header_bits as usize)?;
    info.kind = match r.ue()? {
        1 => SliceKind::P,
        2 => SliceKind::I,
        _ => SliceKind::Other,
    };
    if pps.output_flag_present {
        r.skip(1)?;
    }
    let Some(sps) = sps else {
        return Some(info);
    };
    if sps.separate_colour_plane {
        r.skip(2)?;
    }
    info.pic_id_modulus = 1 << sps.log2_max_poc_lsb;
    if t == 19 || t == 20 {
        info.pic_id = Some(0);
        return Some(info);
    }
    info.pic_id = Some(r.bits(sps.log2_max_poc_lsb)?);
    let sets: &[ShortTermRps] = sps.rps_sets.as_deref().unwrap_or(&[]);
    let n = sets.len();
    if !r.bit()? {
        let (rps, flags) = parse_st_rps(r, n, n, sets)?;
        info.negatives = rps.negatives;
        info.positives = rps.positives;
        info.used_flag_positions = flags.unwrap_or_default();
    } else {
        if sps.rps_sets.is_none() {
            return Some(info);
        }
        let idx = if n > 1 {
            r.bits(ceil_log2(n as u32))? as usize
        } else {
            0
        };
        let set = sets.get(idx)?;
        info.negatives = set.negatives.clone();
        info.positives = set.positives.clone();
    }
    info.rps_known = true;
    info.reference = info
        .negatives
        .iter()
        .position(|&(_, used)| used)
        .map(|i| i as u32);
    info.long_terms = sps
        .long_term
        .as_ref()
        .and_then(|lt| parse_long_terms(r, lt, sps.log2_max_poc_lsb));
    Some(info)
}

fn parse_long_terms(
    r: &mut BitReader<'_>,
    lt: &LongTermSps,
    log2_max_poc_lsb: u32,
) -> Option<Vec<LongTermRef>> {
    if !lt.present {
        return Some(Vec::new());
    }
    let candidates = lt.pictures.len() as u32;
    let from_sps = if candidates > 0 { r.ue()? } else { 0 };
    if from_sps > candidates {
        return None;
    }
    let coded = r.ue()?;
    let total = from_sps.checked_add(coded).filter(|&t| t <= 32)?;
    let mut out = Vec::with_capacity(total as usize);
    let mut cycle = 0u32;
    for i in 0..total {
        let (poc_lsb, used, used_flag_position) = if i < from_sps {
            let idx = if candidates > 1 {
                r.bits(ceil_log2(candidates))? as usize
            } else {
                0
            };
            let &(lsb, used) = lt.pictures.get(idx)?;
            (lsb, used, None)
        } else {
            let lsb = r.bits(log2_max_poc_lsb)?;
            let at = r.position();
            (lsb, r.bit()?, Some(at))
        };
        let msb_present = r.bit()?;
        let delta = if msb_present { r.ue()? } else { 0 };
        cycle = if i == 0 || i == from_sps {
            delta
        } else {
            delta.checked_add(cycle)?
        };
        out.push(LongTermRef {
            poc_lsb,
            msb_cycle: msb_present.then_some(cycle),
            used,
            used_flag_position,
        });
    }
    Some(out)
}

pub fn rewrite_references(
    ps: &ParameterSets,
    picture: &[u8],
    used: &[bool],
    used_lt: Option<&[bool]>,
) -> Option<Vec<u8>> {
    let codec = CodecFamily::H265;
    let mut out = Vec::with_capacity(picture.len() + 16);
    let mut copied = 0;
    let mut rewritten = 0;
    for range in nal_units(picture) {
        let nal = &picture[range.clone()];
        if !nal_type(codec, nal).is_some_and(|t| is_slice(codec, t)) {
            continue;
        }
        let info = parse_slice(codec, ps, nal)?;
        if info.dependent {
            continue;
        }
        if !info.rps_known || info.negatives.len() != used.len() {
            return None;
        }
        let mut writes: Vec<(usize, bool)> = Vec::new();
        for (i, (&(_, old), &new)) in info.negatives.iter().zip(used).enumerate() {
            match info.used_flag_positions.get(i) {
                Some(&bit) => writes.push((bit, new)),
                None if old != new => return None,
                None => {}
            }
        }
        if let Some(want) = used_lt {
            let lts = info.long_terms.as_ref()?;
            if lts.len() != want.len() {
                return None;
            }
            for (l, &new) in lts.iter().zip(want) {
                match l.used_flag_position {
                    Some(bit) => writes.push((bit, new)),
                    None if l.used != new => return None,
                    None => {}
                }
            }
        }
        let mut rbsp = unescape_nal(nal);
        for (bit, u) in writes {
            let mask = 0x80u8 >> (bit % 8);
            let byte = rbsp.get_mut(bit / 8)?;
            if u {
                *byte |= mask;
            } else {
                *byte &= !mask;
            }
        }
        out.extend_from_slice(&picture[copied..range.start]);
        out.extend_from_slice(&escape_nal(&rbsp));
        copied = range.end;
        rewritten += 1;
    }
    if rewritten == 0 {
        return None;
    }
    out.extend_from_slice(&picture[copied..]);
    Some(out)
}

pub fn build_h264_sps(log2_max_frame_num: u32) -> Vec<u8> {
    let mut w = BitWriter::new();
    w.bits(8, 66).bits(8, 0).bits(8, 40).ue(0);
    w.ue(log2_max_frame_num - 4);
    w.ue(2);
    w.ue(1)
        .bit(false)
        .ue(79)
        .ue(44)
        .bit(true)
        .bit(true)
        .bit(false)
        .bit(false);
    w.trailing();
    w.annex_b_nal(&[0x67])
}

pub fn build_h264_pps() -> Vec<u8> {
    let mut w = BitWriter::new();
    w.ue(0)
        .ue(0)
        .bit(false)
        .bit(false)
        .ue(0)
        .ue(0)
        .ue(0)
        .bit(false)
        .bits(2, 0);
    w.se(0)
        .se(0)
        .se(0)
        .bit(true)
        .bit(false)
        .bit(false)
        .trailing();
    w.annex_b_nal(&[0x68])
}

pub fn build_h264_slice(
    idr: bool,
    frame_num: u32,
    log2_max_frame_num: u32,
    distance: u32,
    body: &[u8],
) -> Vec<u8> {
    build_h264_slice_with(idr, true, frame_num, log2_max_frame_num, distance, body)
}

pub fn build_h264_slice_with(
    idr: bool,
    reference: bool,
    frame_num: u32,
    log2_max_frame_num: u32,
    distance: u32,
    body: &[u8],
) -> Vec<u8> {
    let mut w = BitWriter::new();
    w.ue(0);
    w.ue(if idr { 7 } else { 5 });
    w.ue(0);
    w.bits(log2_max_frame_num, u64::from(frame_num));
    if idr {
        w.ue(0);
    } else {
        w.bit(false);
        if distance == 0 {
            w.bit(false);
        } else {
            w.bit(true).ue(0).ue(distance).ue(3);
        }
    }
    w.bits(8, 0xa5);
    let header = match (idr, reference) {
        (true, _) => 0x65,
        (false, true) => 0x41,
        (false, false) => 0x01,
    };
    let mut nal = w.annex_b_nal(&[header]);
    nal.extend_from_slice(body);
    nal
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct H265Build {
    pub log2_max_poc_lsb: u32,
    pub width: u32,
    pub height: u32,
    pub num_extra_slice_header_bits: u32,
    pub output_flag_present: bool,
    pub dependent_slice_segments: bool,
    pub lists_modification_present: bool,
}

impl H265Build {
    pub fn new(log2_max_poc_lsb: u32) -> Self {
        Self {
            log2_max_poc_lsb,
            width: 1280,
            height: 720,
            num_extra_slice_header_bits: 0,
            output_flag_present: false,
            dependent_slice_segments: false,
            lists_modification_present: false,
        }
    }

    pub fn address_bits(&self) -> u32 {
        ceil_log2(self.width.div_ceil(64) * self.height.div_ceil(64))
    }
}

pub fn build_h265_parameter_sets(log2_max_poc_lsb: u32) -> Vec<u8> {
    build_h265_parameter_sets_with(&H265Build::new(log2_max_poc_lsb))
}

pub fn build_h265_parameter_sets_with(b: &H265Build) -> Vec<u8> {
    let mut out = Vec::new();
    let mut vps = BitWriter::new();
    vps.bits(4, 0)
        .bits(2, 3)
        .bits(6, 0)
        .bits(3, 0)
        .bit(true)
        .bits(16, 0xffff);
    vps.bits(32, 0x0160_0000).bits(32, 0).bits(32, 0).trailing();
    out.extend(vps.annex_b_nal(&[0x40, 0x01]));
    let mut sps = BitWriter::new();
    sps.bits(4, 0).bits(3, 0).bit(true);
    sps.bits(2, 0)
        .bit(false)
        .bits(5, 1)
        .bits(32, 0x6000_0000)
        .bits(4, 0b1001);
    sps.bits(43, 0).bit(false).bits(8, 120);
    sps.ue(0)
        .ue(1)
        .ue(b.width)
        .ue(b.height)
        .bit(false)
        .ue(0)
        .ue(0);
    sps.ue(b.log2_max_poc_lsb - 4);
    sps.bit(true).ue(1).ue(0).ue(0);
    sps.ue(0).ue(3).ue(0).ue(3).ue(0).ue(0);
    sps.bit(false).bit(false).bit(false).bit(false);
    sps.ue(0);
    sps.bit(false).bit(false).bit(false);
    sps.bit(false).bit(false).trailing();
    out.extend(sps.annex_b_nal(&[0x42, 0x01]));
    let mut pps = BitWriter::new();
    pps.ue(0)
        .ue(0)
        .bit(b.dependent_slice_segments)
        .bit(b.output_flag_present)
        .bits(3, u64::from(b.num_extra_slice_header_bits))
        .bit(false)
        .bit(false);
    pps.ue(0).ue(0).se(0).bit(false).bit(false).bit(false);
    pps.se(0).se(0).bit(false).bit(false).bit(false).bit(false);
    pps.bit(false).bit(false);
    pps.bit(false).bit(false).bit(false);
    pps.bit(b.lists_modification_present);
    pps.ue(0).bit(false).bit(false).trailing();
    out.extend(pps.annex_b_nal(&[0x44, 0x01]));
    out
}

#[derive(Clone, Copy, Debug)]
pub struct H265SliceSpec<'a> {
    pub idr: bool,
    pub intra: bool,
    pub poc_lsb: u32,
    pub address: u32,
    pub negatives: &'a [(u32, bool)],
    pub body: &'a [u8],
}

pub fn build_h265_slice_with(b: &H265Build, s: &H265SliceSpec<'_>) -> Vec<u8> {
    let mut w = BitWriter::new();
    let first = s.address == 0;
    w.bit(first);
    if s.idr {
        w.bit(false);
    }
    w.ue(0);
    if !first {
        if b.dependent_slice_segments {
            w.bit(false);
        }
        w.bits(b.address_bits(), u64::from(s.address));
    }
    w.bits(b.num_extra_slice_header_bits, 0);
    w.ue(if s.idr || s.intra { 2 } else { 1 });
    if b.output_flag_present {
        w.bit(true);
    }
    if !s.idr {
        w.bits(b.log2_max_poc_lsb, u64::from(s.poc_lsb));
        w.bit(false);
        w.ue(s.negatives.len() as u32).ue(0);
        for &(delta, used) in s.negatives {
            w.ue(delta).bit(used);
        }
    }
    w.bits(8, 0x5a);
    let header: [u8; 2] = if s.idr { [0x28, 0x01] } else { [0x02, 0x01] };
    let mut nal = w.annex_b_nal(&header);
    nal.extend_from_slice(s.body);
    nal
}

pub fn build_h265_slice(
    idr: bool,
    poc_lsb: u32,
    log2_max_poc_lsb: u32,
    negatives: &[bool],
    body: &[u8],
) -> Vec<u8> {
    let negatives: Vec<(u32, bool)> = negatives.iter().map(|&u| (0, u)).collect();
    build_h265_slice_with(
        &H265Build::new(log2_max_poc_lsb),
        &H265SliceSpec {
            idr,
            intra: false,
            poc_lsb,
            address: 0,
            negatives: &negatives,
            body,
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media::bits::raw_offset;

    fn slice(codec: CodecFamily, p: &ParameterSets, nal: &[u8]) -> SliceInfo {
        let r = first_slice(codec, nal).unwrap();
        parse_slice(codec, p, &nal[r]).unwrap()
    }

    #[test]
    fn h264_parameter_set_and_slices() {
        let header = [build_h264_sps(8), build_h264_pps()].concat();
        let p = ParameterSets::parse(CodecFamily::H264, &header);
        assert_eq!(p.h264_sps[0].log2_max_frame_num, 8);
        assert_eq!(p.h264_sps[0].poc_type, 2);
        assert!(p.h264_sps[0].frame_mbs_only);
        assert_eq!(p.h264_pps.len(), 1);
        let idr = build_h264_slice(true, 0, 8, 0, &[1, 2, 3]);
        let s = slice(CodecFamily::H264, &p, &idr);
        assert_eq!((s.nal_type, s.kind, s.reference), (5, SliceKind::I, None));
        assert_eq!(s.pic_id, Some(0));
        for d in [0, 1, 4] {
            let n = build_h264_slice(false, 9, 8, d, &[9; 20]);
            let s = slice(CodecFamily::H264, &p, &n);
            assert_eq!(
                (s.kind, s.reference, s.pic_id),
                (SliceKind::P, Some(d), Some(9))
            );
            assert_eq!(s.pic_id_modulus, 256);
        }
    }

    #[test]
    fn h264_poc_type_0_and_redundant_count() {
        let mut w = BitWriter::new();
        w.bits(8, 100).bits(8, 0).bits(8, 40).ue(0);
        w.ue(1).ue(0).ue(0).bit(false).bit(false);
        w.ue(4);
        w.ue(0).ue(2);
        w.ue(1)
            .bit(false)
            .ue(79)
            .ue(44)
            .bit(true)
            .bit(true)
            .bit(false)
            .bit(false);
        w.trailing();
        let sps = w.annex_b_nal(&[0x67]);
        let mut w = BitWriter::new();
        w.ue(0)
            .ue(0)
            .bit(false)
            .bit(true)
            .ue(0)
            .ue(0)
            .ue(0)
            .bit(false)
            .bits(2, 0);
        w.se(0)
            .se(0)
            .se(0)
            .bit(true)
            .bit(false)
            .bit(true)
            .trailing();
        let pps = w.annex_b_nal(&[0x68]);
        let p = ParameterSets::parse(CodecFamily::H264, &[sps, pps].concat());
        assert_eq!(p.h264_sps[0].poc_type, 0);
        assert_eq!(p.h264_sps[0].log2_max_poc_lsb, 6);
        assert!(p.h264_pps[0].redundant_pic_cnt_present);
        assert!(p.h264_pps[0].bottom_field_pic_order_in_frame_present);
        let mut w = BitWriter::new();
        w.ue(0).ue(5).ue(0).bits(8, 7);
        w.bits(6, 0b10_1010).se(-3);
        w.ue(0);
        w.bit(false);
        w.bit(true).ue(0).ue(2).ue(3);
        w.bits(8, 0xa5);
        let nal = w.annex_b_nal(&[0x41]);
        let s = slice(CodecFamily::H264, &p, &nal);
        assert_eq!(
            (s.kind, s.reference, s.pic_id),
            (SliceKind::P, Some(2), Some(7))
        );
    }

    #[test]
    fn h265_parameter_sets_slices_and_rewrite() {
        let header = build_h265_parameter_sets(8);
        let p = ParameterSets::parse(CodecFamily::H265, &header);
        let sps = &p.h265_sps[0];
        assert_eq!(sps.log2_max_poc_lsb, 8);
        assert_eq!(sps.address_bits, Some(8));
        assert_eq!(sps.rps_sets, Some(Vec::new()));
        assert_eq!(p.h265_pps[0].lists_modification_present, Some(false));
        let idr = build_h265_slice(true, 0, 8, &[], &[0; 8]);
        let s = slice(CodecFamily::H265, &p, &idr);
        assert_eq!((s.nal_type, s.kind, s.pic_id), (20, SliceKind::I, Some(0)));
        let pic = build_h265_slice(false, 7, 8, &[false, true, true, false], &[0x11; 8]);
        let s = slice(CodecFamily::H265, &p, &pic);
        assert_eq!(
            (s.kind, s.reference, s.pic_id),
            (SliceKind::P, Some(1), Some(7))
        );
        assert_eq!(
            s.negatives,
            vec![(-1, false), (-2, true), (-3, true), (-4, false)]
        );
        assert_eq!(s.used_flag_positions.len(), 4);
        let out = rewrite_references(&p, &pic, &[false, false, false, true], None).unwrap();
        assert_eq!(out.len(), pic.len());
        let s2 = slice(CodecFamily::H265, &p, &out);
        assert_eq!(s2.reference, Some(3));
        assert!(rewrite_references(&p, &pic, &[true], None).is_none());
    }

    #[test]
    fn h265_optional_slice_header_fields() {
        let b = H265Build {
            num_extra_slice_header_bits: 2,
            output_flag_present: true,
            dependent_slice_segments: true,
            lists_modification_present: true,
            ..H265Build::new(6)
        };
        let p = ParameterSets::parse(CodecFamily::H265, &build_h265_parameter_sets_with(&b));
        let pps = p.h265_pps[0];
        assert_eq!(pps.num_extra_slice_header_bits, 2);
        assert!(pps.output_flag_present && pps.dependent_slice_segments_enabled);
        assert_eq!(pps.lists_modification_present, Some(true));
        let negatives = [(0, false), (1, true)];
        let spec = H265SliceSpec {
            idr: false,
            intra: false,
            poc_lsb: 33,
            address: 0,
            negatives: &negatives,
            body: &[1, 2, 3],
        };
        let s = slice(CodecFamily::H265, &p, &build_h265_slice_with(&b, &spec));
        assert_eq!(
            (s.kind, s.pic_id, s.reference),
            (SliceKind::P, Some(33), Some(1))
        );
        assert_eq!(s.negatives, vec![(-1, false), (-3, true)]);
        let nal = build_h265_slice_with(
            &b,
            &H265SliceSpec {
                address: 40,
                ..spec
            },
        );
        let r = first_slice(CodecFamily::H265, &nal).unwrap();
        let s = parse_slice(CodecFamily::H265, &p, &nal[r]).unwrap();
        assert!(!s.dependent);
        assert_eq!(s.negatives, vec![(-1, false), (-3, true)]);
    }

    #[test]
    fn h265_rps_from_the_sps_and_predicted() {
        let mut w = BitWriter::new();
        w.bits(4, 0).bits(3, 0).bit(true);
        w.bits(48, 0).bits(48, 0);
        w.ue(0).ue(1).ue(640).ue(384).bit(false).ue(0).ue(0).ue(4);
        w.bit(true).ue(1).ue(0).ue(0);
        w.ue(0).ue(3).ue(0).ue(3).ue(0).ue(0);
        w.bit(false).bit(false).bit(false).bit(false);
        w.ue(2);
        w.ue(2).ue(0).ue(0).bit(true).ue(1).bit(false);
        w.bit(true).bit(true).ue(0);
        w.bit(true).bit(false).bit(true).bit(true);
        w.bit(false)
            .bit(false)
            .bit(false)
            .bit(false)
            .bit(false)
            .trailing();
        let sps = w.annex_b_nal(&[0x42, 0x01]);
        let p = ParameterSets::parse(CodecFamily::H265, &sps);
        let sets = p.h265_sps[0].rps_sets.clone().unwrap();
        assert_eq!(sets[0].negatives, vec![(-1, true), (-3, false)]);
        assert_eq!(sets[1].negatives, vec![(-1, true), (-2, true), (-4, false)]);
        let mut w = BitWriter::new();
        w.bit(true)
            .ue(0)
            .ue(1)
            .bits(8, 9)
            .bit(true)
            .bits(1, 1)
            .bits(8, 0x5a);
        let nal = w.annex_b_nal(&[0x02, 0x01]);
        let s = slice(CodecFamily::H265, &p, &nal);
        assert_eq!(s.negatives, sets[1].negatives);
        assert_eq!(s.reference, Some(0));
        assert!(
            s.used_flag_positions.is_empty(),
            "an SPS set cannot be rewritten"
        );
        let mut w = BitWriter::new();
        w.bit(true).ue(0).ue(1).bits(8, 9).bit(false);
        w.bit(true).ue(0).bit(false).ue(0);
        w.bit(true)
            .bit(true)
            .bit(false)
            .bit(true)
            .bit(false)
            .bit(true);
        w.bits(8, 0x5a);
        let nal = w.annex_b_nal(&[0x02, 0x01]);
        let s = slice(CodecFamily::H265, &p, &nal);
        assert_eq!(s.negatives, vec![(-1, true), (-3, false)]);
        assert!(s.used_flag_positions.is_empty());
    }

    #[test]
    fn h265_rewrite_inserts_emulation_prevention() {
        let has_emulation =
            |nal: &[u8]| nal.windows(3).any(|w| w[0] == 0 && w[1] == 0 && w[2] <= 2);
        let negatives = [(4095, true), (4095, true), (4095, false)];
        let body: Vec<u8> = (0..64).map(|i| 0x40 + i as u8).collect();
        let mut naive_broken = 0;
        for extra in 0..8 {
            let b = H265Build {
                num_extra_slice_header_bits: extra,
                ..H265Build::new(16)
            };
            let p = ParameterSets::parse(CodecFamily::H265, &build_h265_parameter_sets_with(&b));
            let pic = build_h265_slice_with(
                &b,
                &H265SliceSpec {
                    idr: false,
                    intra: false,
                    poc_lsb: 50_000,
                    address: 0,
                    negatives: &negatives,
                    body: &body,
                },
            );
            let r = first_slice(CodecFamily::H265, &pic).unwrap();
            assert!(!has_emulation(&pic[r.clone()]));
            let s = parse_slice(CodecFamily::H265, &p, &pic[r.clone()]).unwrap();
            let bit = s.used_flag_positions[0];
            let byte = raw_offset(&pic[r.clone()], bit / 8).unwrap();
            let mut flipped = pic[r.clone()].to_vec();
            flipped[byte] &= !(0x80u8 >> (bit % 8));
            let broken = has_emulation(&flipped);
            naive_broken += usize::from(broken);
            let out = rewrite_references(&p, &pic, &[false, true, false], None).unwrap();
            assert_eq!(out.len() > pic.len(), broken);
            let r2 = first_slice(CodecFamily::H265, &out).unwrap();
            assert!(!has_emulation(&out[r2.clone()]));
            let s2 = parse_slice(CodecFamily::H265, &p, &out[r2.clone()]).unwrap();
            assert_eq!(s2.reference, Some(1));
            assert_eq!(
                s2.negatives.iter().map(|n| n.1).collect::<Vec<_>>(),
                vec![false, true, false]
            );
            let a = unescape_nal(&pic[r]);
            let c = unescape_nal(&out[r2]);
            assert_eq!(a.len(), c.len());
            assert_eq!(a[a.len() - 64..], c[c.len() - 64..]);
        }
        assert!(
            naive_broken > 0,
            "no alignment produced a start-code pattern"
        );
    }

    #[test]
    fn h265_rewrite_changes_every_slice_segment() {
        let b = H265Build::new(8);
        let p = ParameterSets::parse(CodecFamily::H265, &build_h265_parameter_sets_with(&b));
        let negatives = [(0, true), (0, true)];
        let mut pic = Vec::new();
        for (i, address) in [0u32, 60, 160].iter().enumerate() {
            pic.extend(build_h265_slice_with(
                &b,
                &H265SliceSpec {
                    idr: false,
                    intra: false,
                    poc_lsb: 20,
                    address: *address,
                    negatives: &negatives,
                    body: &[0x30 + i as u8; 40],
                },
            ));
        }
        let out = rewrite_references(&p, &pic, &[false, true], None).unwrap();
        let units = nal_units(&out);
        assert_eq!(units.len(), 3);
        for r in units {
            let s = parse_slice(CodecFamily::H265, &p, &out[r]).unwrap();
            assert_eq!(s.negatives, vec![(-1, false), (-2, true)]);
        }
    }

    #[test]
    fn header_values_near_the_limits_do_not_overflow() {
        let mut w = BitWriter::new();
        w.se(i32::MAX).se(-7).bit(true).trailing();
        let mut r = BitReader::new(w.bytes());
        assert_eq!(skip_h264_scaling_list(&mut r, 16), Some(()));
        assert_eq!(r.bit(), Some(true));
        let lt = LongTermSps {
            present: true,
            pictures: vec![(1, true), (2, false)],
        };
        let mut w = BitWriter::new();
        w.ue(2).ue(u32::MAX - 1).bits(16, 0xffff).trailing();
        assert_eq!(
            parse_long_terms(&mut BitReader::new(w.bytes()), &lt, 8),
            None
        );
        let mut w = BitWriter::new();
        w.ue(1).ue(1).bits(1, 1).bit(false);
        w.bits(8, 0x2a).bit(true).bit(false).trailing();
        let refs = parse_long_terms(&mut BitReader::new(w.bytes()), &lt, 8).unwrap();
        assert_eq!(
            refs.iter().map(|l| (l.poc_lsb, l.used)).collect::<Vec<_>>(),
            vec![(2, false), (0x2a, true)]
        );
    }

    #[test]
    fn nal_scanning() {
        let s = [
            0, 0, 0, 1, 0x67, 1, 0, 0, 1, 0x68, 2, 0, 0, 0, 1, 0x65, 3, 0,
        ];
        let r = nal_units(&s);
        assert_eq!(r, vec![4..6, 9..11, 15..17]);
        assert!(is_keyframe_type(CodecFamily::H264, 5));
        assert!(is_keyframe_type(CodecFamily::H265, 19));
        assert!(!is_keyframe_type(CodecFamily::H265, 1));
        assert_eq!(
            (ceil_log2(1), ceil_log2(2), ceil_log2(240), ceil_log2(256)),
            (0, 1, 8, 8)
        );
    }
}
