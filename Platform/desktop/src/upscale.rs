use crate::frc::Nv12;
use std::ffi::c_void;
use windows::core::{s, Interface, PCSTR};
use windows::Win32::Foundation::RECT;
use windows::Win32::Graphics::Direct3D::Fxc::D3DCompile;
use windows::Win32::Graphics::Direct3D::{
    ID3DBlob, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST, D3D_DRIVER_TYPE_UNKNOWN,
    D3D_PRIMITIVE_TOPOLOGY,
};
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::*;
use windows::Win32::Graphics::Dxgi::{CreateDXGIFactory1, IDXGIAdapter1, IDXGIFactory1};

pub const FSR: i32 = 0;
pub const NIS: i32 = 1;
pub const ANIME4K: i32 = 2;
pub const PLAIN: i32 = 3;
const ALL: i32 = 1 << FSR | 1 << NIS | 1 << ANIME4K;

const RCAS_STOPS: f32 = 0.2;
const NIS_SHARPNESS: f32 = 0.5;

pub fn enlarged(width: i32, height: i32, factor: f64) -> Option<(i32, i32)> {
    if width <= 0 || height <= 0 {
        return None;
    }
    let most = (7680.0 * 4320.0 / (f64::from(width) * f64::from(height))).sqrt();
    let scale = factor.min(most);
    if scale < 1.1 {
        return None;
    }
    let even = |value: f64| ((value / 2.0).round() as i32 * 2).max(2);
    Some((
        even(f64::from(width) * scale),
        even(f64::from(height) * scale),
    ))
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Step {
    Anime4K((i32, i32)),
    Nis((i32, i32), (i32, i32), f32),
    Easu((i32, i32), (i32, i32)),
    Rcas((i32, i32)),
}

impl Step {
    fn out(self) -> (i32, i32) {
        match self {
            Step::Anime4K(at) => (at.0 * 2, at.1 * 2),
            Step::Nis(_, to, _) | Step::Easu(_, to) => to,
            Step::Rcas(at) => at,
        }
    }
}

pub fn steps(method: i32, source: (i32, i32), size: (i32, i32)) -> Vec<Step> {
    let mut steps = Vec::new();
    let mut at = source;
    match method {
        PLAIN => {}
        ANIME4K => {
            while at.0 * 2 <= size.0 && at.1 * 2 <= size.1 {
                steps.push(Step::Anime4K(at));
                at = (at.0 * 2, at.1 * 2);
            }
            if at != size || steps.is_empty() {
                steps.push(Step::Easu(at, size));
            }
        }
        NIS => loop {
            let next = (size.0.min(at.0 * 2), size.1.min(at.1 * 2));
            steps.push(Step::Nis(
                at,
                next,
                if next == size { NIS_SHARPNESS } else { 0.0 },
            ));
            at = next;
            if at == size || steps.len() > 4 {
                break;
            }
        },
        _ => {
            if size != source {
                steps.push(Step::Easu(source, size));
            }
            steps.push(Step::Rcas(size));
        }
    }
    steps
}

const BETWEEN: [&str; 5] = ["step0", "step1", "step2", "step3", "step4"];
const NETWORK_A: [&str; 5] = ["a0", "a1", "a2", "a3", "a4"];
const NETWORK_B: [&str; 5] = ["b0", "b1", "b2", "b3", "b4"];

const SHADER: &str = r#"
Texture2D<float> luma : register(t0);
Texture2D<float2> chroma : register(t1);
Texture2D<float4> source : register(t2);
RWTexture2D<float4> target : register(u0);
SamplerState near : register(s0);
SamplerState smooth : register(s1);
cbuffer Constants : register(b0) { float4 con0; float4 con1; float4 con2; float4 con3; };

float3 rgb(float y, float2 c) {
    y = (y * 255.0 - 16.0) / 219.0;
    c = (c * 255.0 - 128.0) / 224.0;
    float3 v = saturate(float3(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y, y + 1.8556 * c.x));
    float3 light = pow(v, 2.4);
    return light <= 0.0031308 ? light * 12.92 : 1.055 * pow(light, 1.0 / 2.4) - 0.055;
}

[numthreads(8, 8, 1)] void colour(uint3 id : SV_DispatchThreadID) {
    uint w, h; target.GetDimensions(w, h);
    if (id.x >= w || id.y >= h) return;
    float2 place = (float2(id.xy) + 0.5) / float2(w, h);
    target[id.xy] = float4(rgb(luma[id.xy], chroma.SampleLevel(smooth, place, 0)), 1.0);
}

// ---- AMD FidelityFX Super Resolution 1 (ffx_fsr1.h, MIT, Copyright (c) 2021 Advanced Micro
// Devices, Inc.), ported: EASU and RCAS of 32-bit floats, their approximations kept.

float rcpLow(float a) { return asfloat(0x7ef07ebbu - asuint(a)); }
float rcpMedium(float a) { float b = asfloat(0x7ef19fffu - asuint(a)); return b * (-b * a + 2.0); }
float rsqLow(float a) { return asfloat(0x5f347d74u - (asuint(a) >> 1)); }

void easuTap(inout float3 aC, inout float aW, float2 off, float2 dir, float2 len, float lob, float clp, float3 c) {
    float2 v = float2(off.x * dir.x + off.y * dir.y, off.x * -dir.y + off.y * dir.x) * len;
    float d2 = min(v.x * v.x + v.y * v.y, clp);
    float wB = 2.0 / 5.0 * d2 - 1.0, wA = lob * d2 - 1.0;
    wB *= wB; wA *= wA;
    wB = 25.0 / 16.0 * wB - (25.0 / 16.0 - 1.0);
    float w = wB * wA;
    aC += c * w; aW += w;
}

void easuSet(inout float2 dir, inout float len, float2 pp, int corner, float lA, float lB, float lC, float lD, float lE) {
    float w = corner == 0 ? (1.0 - pp.x) * (1.0 - pp.y) : corner == 1 ? pp.x * (1.0 - pp.y) : corner == 2 ? (1.0 - pp.x) * pp.y : pp.x * pp.y;
    float dc = lD - lC, cb = lC - lB;
    float lenX = rcpLow(max(abs(dc), abs(cb)));
    float dirX = lD - lB;
    dir.x += dirX * w;
    lenX = saturate(abs(dirX) * lenX); lenX *= lenX;
    len += lenX * w;
    float ec = lE - lC, ca = lC - lA;
    float lenY = rcpLow(max(abs(ec), abs(ca)));
    float dirY = lE - lA;
    dir.y += dirY * w;
    lenY = saturate(abs(dirY) * lenY); lenY *= lenY;
    len += lenY * w;
}

[numthreads(8, 8, 1)] void easu(uint3 id : SV_DispatchThreadID) {
    uint w, h; target.GetDimensions(w, h);
    if (id.x >= w || id.y >= h) return;
    float2 pp = float2(id.xy) * con0.xy + con0.zw;
    float2 fp = floor(pp);
    pp -= fp;
    float2 p0 = fp * con1.xy + con1.zw;
    float2 p1 = p0 + con2.xy, p2 = p0 + con2.zw, p3 = p0 + con3.xy;
    float4 bczzR = source.GatherRed(near, p0), bczzG = source.GatherGreen(near, p0), bczzB = source.GatherBlue(near, p0);
    float4 ijfeR = source.GatherRed(near, p1), ijfeG = source.GatherGreen(near, p1), ijfeB = source.GatherBlue(near, p1);
    float4 klhgR = source.GatherRed(near, p2), klhgG = source.GatherGreen(near, p2), klhgB = source.GatherBlue(near, p2);
    float4 zzonR = source.GatherRed(near, p3), zzonG = source.GatherGreen(near, p3), zzonB = source.GatherBlue(near, p3);
    float4 bczzL = bczzB * 0.5 + (bczzR * 0.5 + bczzG), ijfeL = ijfeB * 0.5 + (ijfeR * 0.5 + ijfeG);
    float4 klhgL = klhgB * 0.5 + (klhgR * 0.5 + klhgG), zzonL = zzonB * 0.5 + (zzonR * 0.5 + zzonG);
    float bL = bczzL.x, cL = bczzL.y, iL = ijfeL.x, jL = ijfeL.y, fL = ijfeL.z, eL = ijfeL.w;
    float kL = klhgL.x, lL = klhgL.y, hL = klhgL.z, gL = klhgL.w, oL = zzonL.z, nL = zzonL.w;
    float2 dir = float2(0.0, 0.0); float len = 0.0;
    easuSet(dir, len, pp, 0, bL, eL, fL, gL, jL);
    easuSet(dir, len, pp, 1, cL, fL, gL, hL, kL);
    easuSet(dir, len, pp, 2, fL, iL, jL, kL, nL);
    easuSet(dir, len, pp, 3, gL, jL, kL, lL, oL);
    float2 dir2 = dir * dir;
    float dirR = dir2.x + dir2.y;
    bool zro = dirR < 1.0 / 32768.0;
    dirR = rsqLow(dirR);
    dirR = zro ? 1.0 : dirR;
    dir.x = zro ? 1.0 : dir.x;
    dir *= dirR;
    len = len * 0.5; len *= len;
    float stretch = (dir.x * dir.x + dir.y * dir.y) * rcpLow(max(abs(dir.x), abs(dir.y)));
    float2 len2 = float2(1.0 + (stretch - 1.0) * len, 1.0 - 0.5 * len);
    float lob = 0.5 + ((1.0 / 4.0 - 0.04) - 0.5) * len;
    float clp = rcpLow(lob);
    float3 f = float3(ijfeR.z, ijfeG.z, ijfeB.z), g = float3(klhgR.w, klhgG.w, klhgB.w), j = float3(ijfeR.y, ijfeG.y, ijfeB.y), k = float3(klhgR.x, klhgG.x, klhgB.x);
    float3 min4 = min(min(min(f, g), j), k), max4 = max(max(max(f, g), j), k);
    float3 aC = float3(0.0, 0.0, 0.0); float aW = 0.0;
    easuTap(aC, aW, float2( 0.0, -1.0) - pp, dir, len2, lob, clp, float3(bczzR.x, bczzG.x, bczzB.x));
    easuTap(aC, aW, float2( 1.0, -1.0) - pp, dir, len2, lob, clp, float3(bczzR.y, bczzG.y, bczzB.y));
    easuTap(aC, aW, float2(-1.0,  1.0) - pp, dir, len2, lob, clp, float3(ijfeR.x, ijfeG.x, ijfeB.x));
    easuTap(aC, aW, float2( 0.0,  1.0) - pp, dir, len2, lob, clp, j);
    easuTap(aC, aW, float2( 0.0,  0.0) - pp, dir, len2, lob, clp, f);
    easuTap(aC, aW, float2(-1.0,  0.0) - pp, dir, len2, lob, clp, float3(ijfeR.w, ijfeG.w, ijfeB.w));
    easuTap(aC, aW, float2( 1.0,  1.0) - pp, dir, len2, lob, clp, k);
    easuTap(aC, aW, float2( 2.0,  1.0) - pp, dir, len2, lob, clp, float3(klhgR.y, klhgG.y, klhgB.y));
    easuTap(aC, aW, float2( 2.0,  0.0) - pp, dir, len2, lob, clp, float3(klhgR.z, klhgG.z, klhgB.z));
    easuTap(aC, aW, float2( 1.0,  0.0) - pp, dir, len2, lob, clp, g);
    easuTap(aC, aW, float2( 1.0,  2.0) - pp, dir, len2, lob, clp, float3(zzonR.z, zzonG.z, zzonB.z));
    easuTap(aC, aW, float2( 0.0,  2.0) - pp, dir, len2, lob, clp, float3(zzonR.w, zzonG.w, zzonB.w));
    target[id.xy] = float4(min(max4, max(min4, aC / aW)), 1.0);
}

[numthreads(8, 8, 1)] void rcas(uint3 id : SV_DispatchThreadID) {
    uint w, h; target.GetDimensions(w, h);
    if (id.x >= w || id.y >= h) return;
    int2 sp = int2(id.xy), last = int2(w, h) - 1;
    float3 b = source[clamp(sp + int2(0, -1), int2(0, 0), last)].rgb;
    float3 d = source[clamp(sp + int2(-1, 0), int2(0, 0), last)].rgb;
    float3 e = source[sp].rgb;
    float3 f = source[clamp(sp + int2(1, 0), int2(0, 0), last)].rgb;
    float3 hh = source[clamp(sp + int2(0, 1), int2(0, 0), last)].rgb;
    float bL = b.b * 0.5 + (b.r * 0.5 + b.g), dL = d.b * 0.5 + (d.r * 0.5 + d.g), eL = e.b * 0.5 + (e.r * 0.5 + e.g);
    float fL = f.b * 0.5 + (f.r * 0.5 + f.g), hL = hh.b * 0.5 + (hh.r * 0.5 + hh.g);
    float nz = 0.25 * bL + 0.25 * dL + 0.25 * fL + 0.25 * hL - eL;
    nz = saturate(abs(nz) * rcpMedium(max(max(max(bL, dL), max(eL, fL)), hL) - min(min(min(bL, dL), min(eL, fL)), hL)));
    nz = -0.5 * nz + 1.0;
    float3 mn4 = min(min(min(b, d), f), hh), mx4 = max(max(max(b, d), f), hh);
    float3 hitMin = min(mn4, e) / (4.0 * mx4);
    float3 hitMax = (1.0 - max(mx4, e)) / (4.0 * mn4 - 4.0);
    float3 lobes = max(-hitMin, hitMax);
    float lobe = max(-(0.25 - 1.0 / 16.0), min(max(max(lobes.r, lobes.g), lobes.b), 0.0)) * con0.x;
    lobe *= nz;
    float rcpL = rcpMedium(4.0 * lobe + 1.0);
    target[id.xy] = float4((lobe * (b + d + hh + f) + e) * rcpL, 1.0);
}

struct Out { float4 position : SV_Position; float2 place : TEXCOORD0; };

Out vs(uint id : SV_VertexID) {
    Out o;
    float2 place = float2((id << 1) & 2, id & 2);
    o.place = place;
    o.position = float4(place * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    return o;
}

float4 show(Out i) : SV_Target {
    if (con0.z > 0.5) {
        float2 o = con0.xy * 0.25;
        float3 m = source.Sample(smooth, i.place + float2(-o.x, -o.y)).rgb + source.Sample(smooth, i.place + float2(o.x, -o.y)).rgb
                 + source.Sample(smooth, i.place + float2(-o.x, o.y)).rgb + source.Sample(smooth, i.place + float2(o.x, o.y)).rgb;
        return float4(m * 0.25, 1.0);
    }
    return float4(source.Sample(smooth, i.place).rgb, 1.0);
}
"#;

const ANIME4K_SHADER: &str = include_str!("../shaders/anime4k.hlsl");

const NIS_PREFIX: &str = r#"
#define NIS_HLSL 1
#define NIS_SCALER 1
#define NIS_CLAMP_OUTPUT 1
#define NIS_BLOCK_WIDTH 32
#define NIS_BLOCK_HEIGHT 24
#define NIS_THREAD_GROUP_SIZE 256
cbuffer cb : register(b0) {
    float kDetectRatio; float kDetectThres; float kMinContrastRatio; float kRatioNorm;
    float kContrastBoost; float kEps; float kSharpStartY; float kSharpScaleY;
    float kSharpStrengthMin; float kSharpStrengthScale; float kSharpLimitMin; float kSharpLimitScale;
    float kScaleX; float kScaleY; float kDstNormX; float kDstNormY;
    float kSrcNormX; float kSrcNormY;
    uint kInputViewportOriginX; uint kInputViewportOriginY; uint kInputViewportWidth; uint kInputViewportHeight;
    uint kOutputViewportOriginX; uint kOutputViewportOriginY; uint kOutputViewportWidth; uint kOutputViewportHeight;
    float reserved0; float reserved1;
};
SamplerState samplerLinearClamp : register(s0);
Texture2D in_texture : register(t0);
RWTexture2D<float4> out_texture : register(u0);
Texture2D coef_scaler : register(t1);
Texture2D coef_usm : register(t2);
"#;
const NIS_SCALER: &str = include_str!("../shaders/NIS_Scaler.hlsli");
const NIS_MAIN: &str = r#"
[numthreads(NIS_THREAD_GROUP_SIZE, 1, 1)]
void nis(uint3 blockIdx : SV_GroupID, uint3 threadIdx : SV_GroupThreadID) { NVScaler(blockIdx.xy, threadIdx.x); }
"#;
const NIS_BLOCK: (u32, u32) = (32, 24);

#[repr(C)]
#[derive(Clone, Copy, Default, Debug, PartialEq)]
pub struct NisConstants {
    detect_ratio: f32,
    detect_thres: f32,
    min_contrast_ratio: f32,
    ratio_norm: f32,
    contrast_boost: f32,
    eps: f32,
    sharp_start_y: f32,
    sharp_scale_y: f32,
    sharp_strength_min: f32,
    sharp_strength_scale: f32,
    sharp_limit_min: f32,
    sharp_limit_scale: f32,
    scale_x: f32,
    scale_y: f32,
    dst_norm_x: f32,
    dst_norm_y: f32,
    src_norm_x: f32,
    src_norm_y: f32,
    input_origin: [u32; 2],
    input_size: [u32; 2],
    output_origin: [u32; 2],
    output_size: [u32; 2],
    reserved: [f32; 2],
}

pub fn nis_constants(
    sharpness: f32,
    input: (i32, i32),
    output: (i32, i32),
) -> Option<NisConstants> {
    if input.0 <= 0 || input.1 <= 0 || output.0 <= 0 || output.1 <= 0 {
        return None;
    }
    let (scale_x, scale_y) = (
        input.0 as f32 / output.0 as f32,
        input.1 as f32 / output.1 as f32,
    );
    if !(0.5..=1.0).contains(&scale_x) || !(0.5..=1.0).contains(&scale_y) {
        return None;
    }
    let slider = sharpness.clamp(0.0, 1.0) - 0.5;
    let (max_scale, min_scale, limit_scale) = if slider >= 0.0 {
        (1.25, 1.25, 1.25)
    } else {
        (1.75, 1.0, 1.0)
    };
    let (min_contrast, max_contrast) = (2.0f32, 10.0f32);
    let (sharp_start, sharp_end) = (0.45f32, 0.9f32);
    let strength_min = (0.4 + slider * min_scale * 1.2f32).max(0.0);
    let strength_max = 1.6 + slider * max_scale * 1.8f32;
    let limit_min = (0.14 + slider * limit_scale * 0.32f32).max(0.1);
    let limit_max = 0.5 + slider * limit_scale * 0.6f32;
    Some(NisConstants {
        detect_ratio: 2.0 * 1127.0 / 1024.0,
        detect_thres: 64.0 / 1024.0,
        min_contrast_ratio: min_contrast,
        ratio_norm: 1.0 / (max_contrast - min_contrast),
        contrast_boost: 1.0,
        eps: 1.0 / 255.0,
        sharp_start_y: sharp_start,
        sharp_scale_y: 1.0 / (sharp_end - sharp_start),
        sharp_strength_min: strength_min,
        sharp_strength_scale: strength_max - strength_min,
        sharp_limit_min: limit_min,
        sharp_limit_scale: limit_max - limit_min,
        scale_x,
        scale_y,
        dst_norm_x: 1.0 / output.0 as f32,
        dst_norm_y: 1.0 / output.1 as f32,
        src_norm_x: 1.0 / input.0 as f32,
        src_norm_y: 1.0 / input.1 as f32,
        input_origin: [0, 0],
        input_size: [input.0 as u32, input.1 as u32],
        output_origin: [0, 0],
        output_size: [output.0 as u32, output.1 as u32],
        reserved: [0.0; 2],
    })
}

pub fn easu_constants(input: (i32, i32), output: (i32, i32)) -> [f32; 16] {
    let (iw, ih, ow, oh) = (
        input.0 as f32,
        input.1 as f32,
        output.0 as f32,
        output.1 as f32,
    );
    [
        iw / ow,
        ih / oh,
        0.5 * iw / ow - 0.5,
        0.5 * ih / oh - 0.5,
        1.0 / iw,
        1.0 / ih,
        1.0 / iw,
        -1.0 / ih,
        -1.0 / iw,
        2.0 / ih,
        1.0 / iw,
        2.0 / ih,
        0.0,
        4.0 / ih,
        0.0,
        0.0,
    ]
}

fn compile(source: &str, entry: PCSTR, target: PCSTR) -> windows::core::Result<ID3DBlob> {
    let mut code = None;
    let mut errors: Option<ID3DBlob> = None;
    let result = unsafe {
        D3DCompile(
            source.as_ptr() as *const c_void,
            source.len(),
            s!("con-upscale"),
            None,
            None,
            entry,
            target,
            0,
            0,
            &mut code,
            Some(&mut errors),
        )
    };
    if let Err(error) = result {
        let said = errors
            .map(|e| String::from_utf8_lossy(bytes(&e)).into_owned())
            .unwrap_or_default();
        return Err(windows::core::Error::new(error.code(), said));
    }
    code.ok_or_else(windows::core::Error::from_thread)
}

fn bytes(blob: &ID3DBlob) -> &[u8] {
    unsafe {
        std::slice::from_raw_parts(blob.GetBufferPointer() as *const u8, blob.GetBufferSize())
    }
}

fn floats(values: &[f32]) -> Vec<u8> {
    values.iter().flat_map(|v| v.to_ne_bytes()).collect()
}

#[derive(Clone)]
struct Surface {
    read: ID3D11ShaderResourceView,
    write: Option<ID3D11UnorderedAccessView>,
    size: (i32, i32),
}

pub struct Upscaler {
    device: ID3D11Device,
    colour: ID3D11ComputeShader,
    easu: ID3D11ComputeShader,
    rcas: ID3D11ComputeShader,
    anime4k: Vec<ID3D11ComputeShader>,
    anime4k_space: ID3D11ComputeShader,
    nis: ID3D11ComputeShader,
    vertex: ID3D11VertexShader,
    show: ID3D11PixelShader,
    near: ID3D11SamplerState,
    smooth: ID3D11SamplerState,
    constants: ID3D11Buffer,
    nis_constants: ID3D11Buffer,
    nis_scaler: ID3D11ShaderResourceView,
    nis_usm: ID3D11ShaderResourceView,
    luma: Option<(ID3D11Texture2D, ID3D11ShaderResourceView)>,
    chroma: Option<(ID3D11Texture2D, ID3D11ShaderResourceView)>,
    source: (i32, i32),
    surfaces: std::collections::HashMap<&'static str, Surface>,
    uploaded_since_draw: bool,
    drawn_for: (i32, (i32, i32)),
}

impl Upscaler {
    pub fn new(device: ID3D11Device) -> windows::core::Result<Upscaler> {
        let nis_source = format!("{NIS_PREFIX}{NIS_SCALER}{NIS_MAIN}");
        unsafe {
            let compute =
                |source: &str, entry: PCSTR| -> windows::core::Result<ID3D11ComputeShader> {
                    let code = compile(source, entry, s!("cs_5_0"))?;
                    let mut made = None;
                    device.CreateComputeShader(bytes(&code), None, Some(&mut made))?;
                    made.ok_or_else(windows::core::Error::from_thread)
                };
            let colour = compute(SHADER, s!("colour"))?;
            let easu = compute(SHADER, s!("easu"))?;
            let rcas = compute(SHADER, s!("rcas"))?;
            let anime4k = vec![
                compute(ANIME4K_SHADER, s!("anime4k_0"))?,
                compute(ANIME4K_SHADER, s!("anime4k_1"))?,
                compute(ANIME4K_SHADER, s!("anime4k_2"))?,
            ];
            let anime4k_space = compute(ANIME4K_SHADER, s!("anime4k_space"))?;
            let nis = compute(&nis_source, s!("nis"))?;
            let vs = compile(SHADER, s!("vs"), s!("vs_5_0"))?;
            let ps = compile(SHADER, s!("show"), s!("ps_5_0"))?;
            let mut vertex = None;
            device.CreateVertexShader(bytes(&vs), None, Some(&mut vertex))?;
            let mut show = None;
            device.CreatePixelShader(bytes(&ps), None, Some(&mut show))?;
            let sampler = |filter: D3D11_FILTER| -> windows::core::Result<ID3D11SamplerState> {
                let description = D3D11_SAMPLER_DESC {
                    Filter: filter,
                    AddressU: D3D11_TEXTURE_ADDRESS_CLAMP,
                    AddressV: D3D11_TEXTURE_ADDRESS_CLAMP,
                    AddressW: D3D11_TEXTURE_ADDRESS_CLAMP,
                    ComparisonFunc: D3D11_COMPARISON_NEVER,
                    MaxLOD: f32::MAX,
                    ..Default::default()
                };
                let mut made = None;
                device.CreateSamplerState(&description, Some(&mut made))?;
                made.ok_or_else(windows::core::Error::from_thread)
            };
            let near = sampler(D3D11_FILTER_MIN_MAG_MIP_POINT)?;
            let smooth = sampler(D3D11_FILTER_MIN_MAG_MIP_LINEAR)?;
            let buffer = |size: usize| -> windows::core::Result<ID3D11Buffer> {
                let description = D3D11_BUFFER_DESC {
                    ByteWidth: size.div_ceil(16) as u32 * 16,
                    Usage: D3D11_USAGE_DYNAMIC,
                    BindFlags: D3D11_BIND_CONSTANT_BUFFER.0 as u32,
                    CPUAccessFlags: D3D11_CPU_ACCESS_WRITE.0 as u32,
                    ..Default::default()
                };
                let mut made = None;
                device.CreateBuffer(&description, None, Some(&mut made))?;
                made.ok_or_else(windows::core::Error::from_thread)
            };
            let constants = buffer(64)?;
            let nis_constants = buffer(std::mem::size_of::<NisConstants>())?;
            let table =
                |values: &[[f32; 8]; 64]| -> windows::core::Result<ID3D11ShaderResourceView> {
                    let description = D3D11_TEXTURE2D_DESC {
                        Width: 2,
                        Height: 64,
                        MipLevels: 1,
                        ArraySize: 1,
                        Format: DXGI_FORMAT_R32G32B32A32_FLOAT,
                        SampleDesc: DXGI_SAMPLE_DESC {
                            Count: 1,
                            Quality: 0,
                        },
                        Usage: D3D11_USAGE_IMMUTABLE,
                        BindFlags: D3D11_BIND_SHADER_RESOURCE.0 as u32,
                        CPUAccessFlags: 0,
                        MiscFlags: 0,
                    };
                    let data = D3D11_SUBRESOURCE_DATA {
                        pSysMem: values.as_ptr() as *const c_void,
                        SysMemPitch: 32,
                        SysMemSlicePitch: 0,
                    };
                    let mut texture = None;
                    device.CreateTexture2D(&description, Some(&data), Some(&mut texture))?;
                    let texture = texture.ok_or_else(windows::core::Error::from_thread)?;
                    let mut view = None;
                    device.CreateShaderResourceView(&texture, None, Some(&mut view))?;
                    view.ok_or_else(windows::core::Error::from_thread)
                };
            let nis_scaler = table(&crate::nis_coefficients::SCALER)?;
            let nis_usm = table(&crate::nis_coefficients::USM)?;
            let missing = windows::core::Error::from_thread;
            Ok(Upscaler {
                colour,
                easu,
                rcas,
                anime4k,
                anime4k_space,
                nis,
                vertex: vertex.ok_or_else(missing)?,
                show: show.ok_or_else(missing)?,
                near,
                smooth,
                constants,
                nis_constants,
                nis_scaler,
                nis_usm,
                luma: None,
                chroma: None,
                source: (0, 0),
                surfaces: Default::default(),
                uploaded_since_draw: false,
                drawn_for: (-1, (0, 0)),
                device,
            })
        }
    }

    fn texture(
        &self,
        width: i32,
        height: i32,
        format: DXGI_FORMAT,
        bind: u32,
        dynamic: bool,
    ) -> windows::core::Result<ID3D11Texture2D> {
        let description = D3D11_TEXTURE2D_DESC {
            Width: width as u32,
            Height: height as u32,
            MipLevels: 1,
            ArraySize: 1,
            Format: format,
            SampleDesc: DXGI_SAMPLE_DESC {
                Count: 1,
                Quality: 0,
            },
            Usage: if dynamic {
                D3D11_USAGE_DYNAMIC
            } else {
                D3D11_USAGE_DEFAULT
            },
            BindFlags: bind,
            CPUAccessFlags: if dynamic {
                D3D11_CPU_ACCESS_WRITE.0 as u32
            } else {
                0
            },
            MiscFlags: 0,
        };
        let mut made = None;
        unsafe {
            self.device
                .CreateTexture2D(&description, None, Some(&mut made))?
        };
        made.ok_or_else(windows::core::Error::from_thread)
    }

    fn view(&self, texture: &ID3D11Texture2D) -> windows::core::Result<ID3D11ShaderResourceView> {
        let mut made = None;
        unsafe {
            self.device
                .CreateShaderResourceView(texture, None, Some(&mut made))?
        };
        made.ok_or_else(windows::core::Error::from_thread)
    }

    fn surface(
        &mut self,
        name: &'static str,
        size: (i32, i32),
        format: DXGI_FORMAT,
    ) -> windows::core::Result<Surface> {
        if let Some(surface) = self.surfaces.get(name).filter(|s| s.size == size) {
            return Ok(surface.clone());
        }
        let texture = self.texture(
            size.0,
            size.1,
            format,
            (D3D11_BIND_SHADER_RESOURCE.0 | D3D11_BIND_UNORDERED_ACCESS.0) as u32,
            false,
        )?;
        let read = self.view(&texture)?;
        let mut write = None;
        unsafe {
            self.device
                .CreateUnorderedAccessView(&texture, None, Some(&mut write))?
        };
        let surface = Surface { read, write, size };
        self.surfaces.insert(name, surface.clone());
        Ok(surface)
    }

    pub fn upload(
        &mut self,
        context: &ID3D11DeviceContext,
        picture: &Nv12,
    ) -> windows::core::Result<()> {
        if self.source != (picture.width, picture.height) || self.luma.is_none() {
            let bind = D3D11_BIND_SHADER_RESOURCE.0 as u32;
            let luma = self.texture(
                picture.width,
                picture.height,
                DXGI_FORMAT_R8_UNORM,
                bind,
                true,
            )?;
            let chroma = self.texture(
                picture.width / 2,
                picture.height / 2,
                DXGI_FORMAT_R8G8_UNORM,
                bind,
                true,
            )?;
            self.luma = Some((luma.clone(), self.view(&luma)?));
            self.chroma = Some((chroma.clone(), self.view(&chroma)?));
            self.source = (picture.width, picture.height);
        }
        let rows = picture.height as usize;
        let width = picture.width as usize;
        let planes = [
            (
                self.luma.as_ref().map(|t| t.0.clone()),
                picture.luma,
                picture.luma_pitch,
                rows,
            ),
            (
                self.chroma.as_ref().map(|t| t.0.clone()),
                picture.chroma,
                picture.chroma_pitch,
                rows / 2,
            ),
        ];
        for (texture, from, pitch, count) in planes {
            let Some(texture) = texture else { continue };
            let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
            unsafe {
                context.Map(&texture, 0, D3D11_MAP_WRITE_DISCARD, 0, Some(&mut mapped))?;
                let to = mapped.pData as *mut u8;
                for row in 0..count {
                    std::ptr::copy_nonoverlapping(
                        from.as_ptr().add(row * pitch),
                        to.add(row * mapped.RowPitch as usize),
                        width.min(pitch),
                    );
                }
                context.Unmap(&texture, 0);
            }
        }
        self.uploaded_since_draw = true;
        Ok(())
    }

    fn forget(&mut self) {
        self.luma = None;
        self.chroma = None;
        self.source = (0, 0);
        self.surfaces.clear();
        self.uploaded_since_draw = false;
        self.drawn_for = (-1, (0, 0));
    }

    pub fn has_picture(&self) -> bool {
        self.luma.is_some()
    }

    fn set_constants(
        &self,
        context: &ID3D11DeviceContext,
        buffer: &ID3D11Buffer,
        data: &[u8],
    ) -> windows::core::Result<()> {
        let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
        unsafe {
            context.Map(buffer, 0, D3D11_MAP_WRITE_DISCARD, 0, Some(&mut mapped))?;
            std::ptr::copy_nonoverlapping(data.as_ptr(), mapped.pData as *mut u8, data.len());
            context.Unmap(buffer, 0);
        }
        Ok(())
    }

    fn dispatch(
        &self,
        context: &ID3D11DeviceContext,
        shader: &ID3D11ComputeShader,
        reads: &[Option<ID3D11ShaderResourceView>],
        write: &Surface,
        groups: (u32, u32),
    ) {
        let none: Vec<Option<ID3D11ShaderResourceView>> = vec![None; reads.len()];
        let no_write: Option<ID3D11UnorderedAccessView> = None;
        unsafe {
            context.CSSetShader(shader, None);
            context.CSSetShaderResources(0, Some(reads));
            context.CSSetUnorderedAccessViews(0, 1, Some(&write.write), None);
            context.Dispatch(groups.0, groups.1, 1);
            context.CSSetUnorderedAccessViews(0, 1, Some(&no_write), None);
            context.CSSetShaderResources(0, Some(&none));
        }
    }

    pub fn draw(
        &mut self,
        context: &ID3D11DeviceContext,
        factor: f64,
        method: i32,
        place: (i32, i32, i32, i32),
    ) -> windows::core::Result<(i32, i32)> {
        let (Some(luma), Some(chroma)) = (self.luma.clone(), self.chroma.clone()) else {
            return Ok((0, 0));
        };
        let source = self.source;
        let size = if method == PLAIN {
            source
        } else {
            enlarged(source.0, source.1, factor).unwrap_or(source)
        };
        let saved = Saved::take(context);
        if saved.targets[0].is_none() {
            return Err(windows::core::Error::from_thread());
        }
        let groups = |s: (i32, i32)| ((s.0 as u32).div_ceil(8), (s.1 as u32).div_ceil(8));
        let picture = self.surface("picture", size, DXGI_FORMAT_R8G8B8A8_UNORM)?;
        if self.uploaded_since_draw || self.drawn_for != (method, size) {
            let plan = steps(method, source, size);
            let rgb = if plan.is_empty() {
                picture.clone()
            } else {
                self.surface("rgb", source, DXGI_FORMAT_R8G8B8A8_UNORM)?
            };
            let samplers = [Some(self.near.clone()), Some(self.smooth.clone())];
            unsafe { context.CSSetSamplers(0, Some(&samplers)) };
            self.dispatch(
                context,
                &self.colour,
                &[Some(luma.1.clone()), Some(chroma.1.clone())],
                &rgb,
                groups(source),
            );
            let mut input = rgb;
            for (index, &step) in plan.iter().enumerate() {
                let out = if index + 1 == plan.len() {
                    picture.clone()
                } else {
                    self.surface(BETWEEN[index], step.out(), DXGI_FORMAT_R8G8B8A8_UNORM)?
                };
                match step {
                    Step::Anime4K(at) => {
                        let a =
                            self.surface(NETWORK_A[index], at, DXGI_FORMAT_R16G16B16A16_FLOAT)?;
                        let b =
                            self.surface(NETWORK_B[index], at, DXGI_FORMAT_R16G16B16A16_FLOAT)?;
                        let mut detail = input.clone();
                        for (pass, shader) in self.anime4k.iter().enumerate() {
                            let into = if pass % 2 == 0 { &a } else { &b };
                            self.dispatch(
                                context,
                                shader,
                                &[Some(detail.read.clone())],
                                into,
                                groups(at),
                            );
                            detail = into.clone();
                        }
                        self.dispatch(
                            context,
                            &self.anime4k_space,
                            &[Some(detail.read.clone()), Some(input.read.clone())],
                            &out,
                            groups(step.out()),
                        );
                    }
                    Step::Nis(from, to, sharpness) => {
                        let constants = nis_constants(sharpness, from, to).unwrap_or_default();
                        let data = unsafe {
                            std::slice::from_raw_parts(
                                &constants as *const NisConstants as *const u8,
                                std::mem::size_of::<NisConstants>(),
                            )
                        };
                        self.set_constants(context, &self.nis_constants, data)?;
                        unsafe {
                            context
                                .CSSetConstantBuffers(0, Some(&[Some(self.nis_constants.clone())]));
                            context.CSSetSamplers(0, Some(&[Some(self.smooth.clone())]));
                        }
                        let blocks = (
                            (to.0 as u32).div_ceil(NIS_BLOCK.0),
                            (to.1 as u32).div_ceil(NIS_BLOCK.1),
                        );
                        let reads = [
                            Some(input.read.clone()),
                            Some(self.nis_scaler.clone()),
                            Some(self.nis_usm.clone()),
                        ];
                        self.dispatch(context, &self.nis, &reads, &out, blocks);
                        unsafe { context.CSSetSamplers(0, Some(&samplers)) };
                    }
                    Step::Easu(from, to) => {
                        self.set_constants(
                            context,
                            &self.constants,
                            &floats(&easu_constants(from, to)),
                        )?;
                        unsafe {
                            context.CSSetConstantBuffers(0, Some(&[Some(self.constants.clone())]))
                        };
                        self.dispatch(
                            context,
                            &self.easu,
                            &[None, None, Some(input.read.clone())],
                            &out,
                            groups(to),
                        );
                    }
                    Step::Rcas(at) => {
                        self.set_constants(
                            context,
                            &self.constants,
                            &floats(&[2f32.powf(-RCAS_STOPS), 0.0, 0.0, 0.0]),
                        )?;
                        unsafe {
                            context.CSSetConstantBuffers(0, Some(&[Some(self.constants.clone())]))
                        };
                        self.dispatch(
                            context,
                            &self.rcas,
                            &[None, None, Some(input.read.clone())],
                            &out,
                            groups(at),
                        );
                    }
                }
                input = out;
            }
            unsafe {
                context.CSSetShader(None, None);
                context.CSSetConstantBuffers(0, Some(&[None]));
            }
            self.uploaded_since_draw = false;
            self.drawn_for = (method, size);
        }
        let larger = size.1 > place.3;
        let show_constants = [
            1.0 / place.2.max(1) as f32,
            1.0 / place.3.max(1) as f32,
            if larger { 1.0 } else { 0.0 },
            0.0,
        ];
        self.set_constants(context, &self.constants, &floats(&show_constants))?;
        unsafe {
            context.IASetInputLayout(None);
            context.IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            context.VSSetShader(&self.vertex, None);
            context.RSSetState(None);
            context.OMSetBlendState(None, None, 0xffff_ffff);
            context.OMSetRenderTargets(Some(&[saved.targets[0].clone()]), None);
            context.RSSetViewports(Some(&[D3D11_VIEWPORT {
                TopLeftX: place.0 as f32,
                TopLeftY: place.1 as f32,
                Width: place.2 as f32,
                Height: place.3 as f32,
                MinDepth: 0.0,
                MaxDepth: 1.0,
            }]));
            context.PSSetShader(&self.show, None);
            context.PSSetSamplers(
                0,
                Some(&[Some(self.near.clone()), Some(self.smooth.clone())]),
            );
            context.PSSetConstantBuffers(0, Some(&[Some(self.constants.clone())]));
            context.PSSetShaderResources(0, Some(&[None, None, Some(picture.read.clone())]));
            context.Draw(3, 0);
            context.PSSetShaderResources(0, Some(&[None, None, None]));
        }
        saved.restore(context);
        Ok(size)
    }
}

struct Saved {
    targets: [Option<ID3D11RenderTargetView>; 1],
    depth: Option<ID3D11DepthStencilView>,
    viewports: [D3D11_VIEWPORT; 16],
    viewport_count: u32,
    scissors: [RECT; 16],
    scissor_count: u32,
    rasterizer: Option<ID3D11RasterizerState>,
    blend: Option<ID3D11BlendState>,
    blend_factor: [f32; 4],
    sample_mask: u32,
    resources: [Option<ID3D11ShaderResourceView>; 3],
    samplers: [Option<ID3D11SamplerState>; 2],
    pixel: Option<ID3D11PixelShader>,
    vertex: Option<ID3D11VertexShader>,
    pixel_constants: [Option<ID3D11Buffer>; 1],
    topology: D3D_PRIMITIVE_TOPOLOGY,
    layout: Option<ID3D11InputLayout>,
}

impl Saved {
    fn take(context: &ID3D11DeviceContext) -> Saved {
        let mut saved = Saved {
            targets: [None],
            depth: None,
            viewports: [D3D11_VIEWPORT::default(); 16],
            viewport_count: 16,
            scissors: [RECT::default(); 16],
            scissor_count: 16,
            rasterizer: None,
            blend: None,
            blend_factor: [0.0; 4],
            sample_mask: 0,
            resources: [None, None, None],
            samplers: [None, None],
            pixel: None,
            vertex: None,
            pixel_constants: [None],
            topology: D3D_PRIMITIVE_TOPOLOGY(0),
            layout: None,
        };
        unsafe {
            context.OMGetRenderTargets(Some(&mut saved.targets), Some(&mut saved.depth));
            context.RSGetViewports(
                &mut saved.viewport_count,
                Some(saved.viewports.as_mut_ptr()),
            );
            context.RSGetScissorRects(&mut saved.scissor_count, Some(saved.scissors.as_mut_ptr()));
            saved.rasterizer = context.RSGetState().ok();
            context.OMGetBlendState(
                Some(&mut saved.blend),
                Some(&mut saved.blend_factor),
                Some(&mut saved.sample_mask),
            );
            context.PSGetShaderResources(0, Some(&mut saved.resources));
            context.PSGetSamplers(0, Some(&mut saved.samplers));
            context.PSGetShader(&mut saved.pixel, None, None);
            context.VSGetShader(&mut saved.vertex, None, None);
            context.PSGetConstantBuffers(0, Some(&mut saved.pixel_constants));
            saved.topology = context.IAGetPrimitiveTopology();
            saved.layout = context.IAGetInputLayout().ok();
        }
        saved
    }

    fn restore(&self, context: &ID3D11DeviceContext) {
        unsafe {
            context.OMSetRenderTargets(Some(&self.targets), self.depth.as_ref());
            context.RSSetViewports(Some(&self.viewports[..self.viewport_count as usize]));
            context.RSSetScissorRects(Some(&self.scissors[..self.scissor_count as usize]));
            context.RSSetState(self.rasterizer.as_ref());
            context.OMSetBlendState(
                self.blend.as_ref(),
                Some(&self.blend_factor),
                self.sample_mask,
            );
            context.PSSetShaderResources(0, Some(&self.resources));
            context.PSSetSamplers(0, Some(&self.samplers));
            context.PSSetShader(self.pixel.as_ref(), None);
            context.VSSetShader(self.vertex.as_ref(), None);
            context.PSSetConstantBuffers(0, Some(&self.pixel_constants));
            context.IASetPrimitiveTopology(self.topology);
            context.IASetInputLayout(self.layout.as_ref());
        }
    }
}

static UPSCALER: std::sync::Mutex<Option<(ID3D11Device, Option<Upscaler>)>> =
    std::sync::Mutex::new(None);

extern "C" {
    fn SDL_RenderGetD3D11Device(renderer: *mut sdl2_sys::SDL_Renderer) -> *mut c_void;
}

unsafe fn device_of(renderer: *mut sdl2_sys::SDL_Renderer) -> Option<ID3D11Device> {
    unsafe {
        let raw = SDL_RenderGetD3D11Device(renderer);
        (!raw.is_null()).then(|| ID3D11Device::from_raw(raw))
    }
}

fn upscaler() -> std::sync::MutexGuard<'static, Option<(ID3D11Device, Option<Upscaler>)>> {
    UPSCALER
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn made_on(
    kept: &mut Option<(ID3D11Device, Option<Upscaler>)>,
    device: ID3D11Device,
) -> Option<&mut Upscaler> {
    if kept.as_ref().map(|(on, _)| on.as_raw()) != Some(device.as_raw()) {
        *kept = Some((device.clone(), Upscaler::new(device).ok()));
    }
    kept.as_mut()?.1.as_mut()
}

pub unsafe fn available(renderer: *mut sdl2_sys::SDL_Renderer) -> bool {
    let Some(device) = (unsafe { device_of(renderer) }) else {
        return false;
    };
    let mut guard = upscaler();
    made_on(&mut guard, device).is_some()
}

pub unsafe fn methods(renderer: *mut sdl2_sys::SDL_Renderer) -> i32 {
    if unsafe { available(renderer) } {
        ALL
    } else {
        0
    }
}

pub unsafe fn draw(
    renderer: *mut sdl2_sys::SDL_Renderer,
    picture: Option<&Nv12>,
    factor: f64,
    method: i32,
    place: (i32, i32, i32, i32),
) -> Option<(i32, i32)> {
    unsafe {
        let (mut r, mut g, mut b, mut a) = (0u8, 0u8, 0u8, 0u8);
        let mut blend = sdl2_sys::SDL_BlendMode::SDL_BLENDMODE_NONE;
        sdl2_sys::SDL_GetRenderDrawColor(renderer, &mut r, &mut g, &mut b, &mut a);
        sdl2_sys::SDL_GetRenderDrawBlendMode(renderer, &mut blend);
        sdl2_sys::SDL_SetRenderDrawBlendMode(
            renderer,
            sdl2_sys::SDL_BlendMode::SDL_BLENDMODE_BLEND,
        );
        sdl2_sys::SDL_SetRenderDrawColor(renderer, 0, 0, 0, 0);
        sdl2_sys::SDL_RenderDrawPoint(renderer, 0, 0);
        sdl2_sys::SDL_SetRenderDrawColor(renderer, r, g, b, a);
        sdl2_sys::SDL_SetRenderDrawBlendMode(renderer, blend);
        sdl2_sys::SDL_RenderFlush(renderer);
        let device = device_of(renderer)?;
        let context = device.GetImmediateContext().ok()?;
        let mut guard = upscaler();
        let upscaler = made_on(&mut guard, device)?;
        if let Some(picture) = picture {
            upscaler.upload(&context, picture).ok()?;
        }
        if !upscaler.has_picture() {
            return None;
        }
        upscaler.draw(&context, factor, method, place).ok()
    }
}

pub fn source() -> Option<(i32, i32)> {
    let guard = upscaler();
    guard
        .as_ref()
        .and_then(|(_, u)| u.as_ref())
        .filter(|u| u.has_picture())
        .map(|u| u.source)
}

pub fn forget() {
    let mut guard = upscaler();
    if let Some((_, Some(upscaler))) = guard.as_mut() {
        upscaler.forget();
    }
}

fn check_planes() -> (Vec<u8>, Vec<u8>) {
    let (w, h) = (640usize, 360usize);
    let luma = vec![126u8; w * h];
    let mut chroma = vec![128u8; w * h / 2];
    for y in 0..h / 2 {
        for x in w / 2 * 3 / 8..w / 2 * 5 / 8 {
            chroma[y * w + 2 * x] = 102;
            chroma[y * w + 2 * x + 1] = 240;
        }
    }
    (luma, chroma)
}

fn colours_match(grey: (i32, i32, i32), bar: (i32, i32, i32), slack: i32) -> bool {
    let light = ((126.0 - 16.0) / 219.0f64).powf(2.4);
    let expected = ((1.055 * light.powf(1.0 / 2.4) - 0.055) * 255.0).round() as i32;
    (grey.0 - expected).abs() <= slack
        && (grey.1 - grey.0).abs() <= 3
        && (grey.2 - grey.0).abs() <= 3
        && bar.2 > bar.1 + 60
        && bar.2 > bar.0 + 20
}

pub unsafe fn check_on(renderer: *mut sdl2_sys::SDL_Renderer) -> Result<String, String> {
    let (luma, chroma) = check_planes();
    let picture = Nv12 {
        width: 640,
        height: 360,
        luma: &luma,
        luma_pitch: 640,
        chroma: &chroma,
        chroma_pitch: 640,
    };
    let mut lines = Vec::new();
    let mut right = true;
    unsafe {
        let (mut w, mut h) = (0, 0);
        sdl2_sys::SDL_GetRendererOutputSize(renderer, &mut w, &mut h);
        if w <= 0 || h <= 0 {
            return Err("no size".into());
        }
        for (method, label) in [(FSR, "FSR 1"), (NIS, "NIS"), (ANIME4K, "Anime4K")] {
            sdl2_sys::SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
            sdl2_sys::SDL_RenderClear(renderer);
            let Some(size) = draw(renderer, Some(&picture), 2.0, method, (0, 0, w, h)) else {
                right = false;
                lines.push(format!("{label}: not drawn"));
                continue;
            };
            let mut pixels = vec![0u8; (w * h * 4) as usize];
            if sdl2_sys::SDL_RenderReadPixels(
                renderer,
                std::ptr::null(),
                sdl2_sys::SDL_PixelFormatEnum::SDL_PIXELFORMAT_ARGB8888 as u32,
                pixels.as_mut_ptr() as *mut c_void,
                w * 4,
            ) != 0
            {
                right = false;
                lines.push(format!("{label}: not read"));
                continue;
            }
            let pixel = |x: i32, y: i32| {
                let at = ((y * w + x) * 4) as usize;
                (
                    i32::from(pixels[at]),
                    i32::from(pixels[at + 1]),
                    i32::from(pixels[at + 2]),
                )
            };
            let (grey, bar) = (pixel(w / 8, h / 2), pixel(w / 2, h / 2));
            let good = colours_match(grey, bar, if method == ANIME4K { 8 } else { 3 });
            right &= good;
            let verdict = if good { "" } else { ": wrong" };
            lines.push(format!(
                "{label}{verdict}: enlarged to {}x{}, grey {:?}, bar {:?} (blue, green, red)",
                size.0, size.1, grey, bar
            ));
        }
        let text = format!("SDL renderer {w}x{h}:\n    {}", lines.join("\n    "));
        if right {
            Ok(text)
        } else {
            Err(text)
        }
    }
}

pub fn check() -> Result<String, String> {
    let mut lines = Vec::new();
    let mut right = true;
    unsafe {
        let factory: IDXGIFactory1 = CreateDXGIFactory1().map_err(|e| format!("no DXGI: {e}"))?;
        let mut index = 0;
        while let Ok(adapter) = factory.EnumAdapters1(index) {
            index += 1;
            let Ok(description) = adapter.GetDesc1() else {
                continue;
            };
            if description.VendorId == 0x1414 {
                continue;
            }
            let name = String::from_utf16_lossy(&description.Description)
                .trim_end_matches('\0')
                .to_string();
            let mut times = Vec::new();
            match check_device(&adapter, PLAIN, 1.0) {
                Ok(line) => lines.push(format!("{name}, not enlarged: {line}")),
                Err(line) => {
                    right = false;
                    lines.push(format!("{name}, not enlarged: wrong: {line}"))
                }
            }
            for (method, label) in [(FSR, "FSR 1"), (NIS, "NIS"), (ANIME4K, "Anime4K")] {
                let mut each = Vec::new();
                for factor in [2.0, 3.0, 4.0] {
                    match check_time(&adapter, method, factor) {
                        Ok(ms) => each.push(format!("{ms:.1}")),
                        Err(error) => each.push(error),
                    }
                }
                times.push(format!("{label} {}", each.join("/")));
                for factor in [2.0, 3.0, 4.0] {
                    match check_device(&adapter, method, factor) {
                        Ok(line) => lines.push(format!("{name}, {label} ×{factor}: {line}")),
                        Err(line) => {
                            right = false;
                            lines.push(format!("{name}, {label} ×{factor}: wrong: {line}"))
                        }
                    }
                }
            }
            lines.push(format!(
                "{name}: GPU time for 1080p ×2/×3/×4, ms: {}",
                times.join(", ")
            ));
        }
    }
    let text = lines.join("\n  ");
    if right && !lines.is_empty() {
        Ok(text)
    } else {
        Err(text)
    }
}

unsafe fn check_device(
    adapter: &IDXGIAdapter1,
    method: i32,
    factor: f64,
) -> Result<String, String> {
    let (luma, chroma) = check_planes();
    let picture = Nv12 {
        width: 640,
        height: 360,
        luma: &luma,
        luma_pitch: 640,
        chroma: &chroma,
        chroma_pitch: 640,
    };
    let (size, pixels) = unsafe { render(adapter, method, factor, &picture, (1280, 720)) }?;
    let pixel = |x: usize, y: usize| {
        let at = (y * 1280 + x) * 4;
        (
            i32::from(pixels[at + 2]),
            i32::from(pixels[at + 1]),
            i32::from(pixels[at]),
        )
    };
    let (grey, bar) = (pixel(160, 360), pixel(640, 360));
    let line = format!(
        "enlarged to {}x{}, grey {:?}, bar {:?} (blue, green, red)",
        size.0, size.1, grey, bar
    );
    let expected = if method == PLAIN {
        Some((640, 360))
    } else {
        enlarged(640, 360, factor)
    };
    if Some(size) == expected && colours_match(grey, bar, if method == ANIME4K { 8 } else { 3 }) {
        Ok(line)
    } else {
        Err(line)
    }
}

unsafe fn test_device(
    adapter: &IDXGIAdapter1,
    size: (i32, i32),
) -> Result<(ID3D11Device, ID3D11DeviceContext, Upscaler, ID3D11Texture2D), String> {
    unsafe {
        let mut device = None;
        let mut context = None;
        D3D11CreateDevice(
            adapter,
            D3D_DRIVER_TYPE_UNKNOWN,
            Default::default(),
            D3D11_CREATE_DEVICE_FLAG(0),
            None,
            D3D11_SDK_VERSION,
            Some(&mut device),
            None,
            Some(&mut context),
        )
        .map_err(|e| format!("no device: {e}"))?;
        let (device, context) = (device.ok_or("no device")?, context.ok_or("no context")?);
        let upscaler = Upscaler::new(device.clone()).map_err(|e| format!("shaders: {e}"))?;
        let screen = upscaler
            .texture(
                size.0,
                size.1,
                DXGI_FORMAT_R8G8B8A8_UNORM,
                D3D11_BIND_RENDER_TARGET.0 as u32,
                false,
            )
            .map_err(|e| format!("target: {e}"))?;
        let mut target = None;
        device
            .CreateRenderTargetView(&screen, None, Some(&mut target))
            .map_err(|e| format!("target view: {e}"))?;
        context.OMSetRenderTargets(Some(&[target]), None);
        Ok((device, context, upscaler, screen))
    }
}

unsafe fn check_time(adapter: &IDXGIAdapter1, method: i32, factor: f64) -> Result<f64, String> {
    let (luma, chroma) = (vec![126u8; 1920 * 1080], vec![128u8; 1920 * 540]);
    let picture = Nv12 {
        width: 1920,
        height: 1080,
        luma: &luma,
        luma_pitch: 1920,
        chroma: &chroma,
        chroma_pitch: 1920,
    };
    unsafe {
        let (device, context, mut upscaler, _screen) = test_device(adapter, (1920, 1080))?;
        let query = |kind: D3D11_QUERY| -> Result<ID3D11Query, String> {
            let mut made = None;
            device
                .CreateQuery(
                    &D3D11_QUERY_DESC {
                        Query: kind,
                        MiscFlags: 0,
                    },
                    Some(&mut made),
                )
                .map_err(|e| format!("query: {e}"))?;
            made.ok_or_else(|| "query".to_string())
        };
        let wait = |query: &ID3D11Query, data: *mut c_void, size: usize| {
            while (Interface::vtable(&context).GetData)(
                Interface::as_raw(&context),
                Interface::as_raw(query),
                data,
                size as u32,
                0,
            )
            .0 != 0
            {
                std::thread::yield_now();
            }
        };
        let mut least = f64::MAX;
        for _ in 0..6 {
            upscaler
                .upload(&context, &picture)
                .map_err(|e| format!("upload: {e}"))?;
            let (disjoint, start, end) = (
                query(D3D11_QUERY_TIMESTAMP_DISJOINT)?,
                query(D3D11_QUERY_TIMESTAMP)?,
                query(D3D11_QUERY_TIMESTAMP)?,
            );
            context.Begin(&disjoint);
            context.End(&start);
            upscaler
                .draw(&context, factor, method, (0, 0, 1920, 1080))
                .map_err(|e| format!("draw: {e}"))?;
            context.End(&end);
            context.End(&disjoint);
            let mut clock = D3D11_QUERY_DATA_TIMESTAMP_DISJOINT::default();
            let (mut from, mut to) = (0u64, 0u64);
            wait(
                &disjoint,
                &mut clock as *mut _ as *mut c_void,
                std::mem::size_of_val(&clock),
            );
            wait(&start, &mut from as *mut u64 as *mut c_void, 8);
            wait(&end, &mut to as *mut u64 as *mut c_void, 8);
            if !clock.Disjoint.as_bool() && clock.Frequency > 0 && to > from {
                least = least.min((to - from) as f64 / clock.Frequency as f64 * 1000.0);
            }
        }
        if least == f64::MAX {
            Err("not measured".into())
        } else {
            Ok(least)
        }
    }
}

unsafe fn render(
    adapter: &IDXGIAdapter1,
    method: i32,
    factor: f64,
    picture: &Nv12,
    out: (i32, i32),
) -> Result<((i32, i32), Vec<u8>), String> {
    unsafe {
        let (device, context, mut upscaler, screen) = test_device(adapter, out)?;
        upscaler
            .upload(&context, picture)
            .map_err(|e| format!("upload: {e}"))?;
        let size = upscaler
            .draw(&context, factor, method, (0, 0, out.0, out.1))
            .map_err(|e| format!("draw: {e}"))?;
        let description = D3D11_TEXTURE2D_DESC {
            Width: out.0 as u32,
            Height: out.1 as u32,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_R8G8B8A8_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC {
                Count: 1,
                Quality: 0,
            },
            Usage: D3D11_USAGE_STAGING,
            BindFlags: 0,
            CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
            MiscFlags: 0,
        };
        let mut staging = None;
        device
            .CreateTexture2D(&description, None, Some(&mut staging))
            .map_err(|e| format!("staging: {e}"))?;
        let staging = staging.ok_or("staging")?;
        context.CopyResource(&staging, &screen);
        let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
        context
            .Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped))
            .map_err(|e| format!("read: {e}"))?;
        let row = out.0 as usize * 4;
        let mut pixels = Vec::with_capacity(row * out.1 as usize);
        for y in 0..out.1 as usize {
            pixels.extend_from_slice(std::slice::from_raw_parts(
                (mapped.pData as *const u8).add(y * mapped.RowPitch as usize),
                row,
            ));
        }
        context.Unmap(&staging, 0);
        Ok((size, pixels))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_picture_is_enlarged_by_the_factor_up_to_8k() {
        assert_eq!(enlarged(1920, 1080, 2.0), Some((3840, 2160)));
        assert_eq!(enlarged(1920, 1080, 3.0), Some((5760, 3240)));
        assert_eq!(enlarged(1920, 1080, 4.0), Some((7680, 4320)));
        assert_eq!(enlarged(2560, 1440, 4.0), Some((7680, 4320)));
        assert_eq!(enlarged(7680, 4320, 2.0), None);
        assert_eq!(enlarged(0, 0, 2.0), None);
    }

    #[test]
    fn each_way_goes_in_its_passes() {
        let (hd, k4, k6, k8) = ((1920, 1080), (3840, 2160), (5760, 3240), (7680, 4320));
        assert_eq!(steps(FSR, hd, k8), vec![Step::Easu(hd, k8), Step::Rcas(k8)]);
        assert_eq!(steps(FSR, hd, hd), vec![Step::Rcas(hd)]);
        assert_eq!(steps(PLAIN, hd, hd), vec![]);
        assert_eq!(steps(ANIME4K, hd, k4), vec![Step::Anime4K(hd)]);
        assert_eq!(
            steps(ANIME4K, hd, k6),
            vec![Step::Anime4K(hd), Step::Easu(k4, k6)]
        );
        assert_eq!(
            steps(ANIME4K, hd, k8),
            vec![Step::Anime4K(hd), Step::Anime4K(k4)]
        );
        assert_eq!(steps(NIS, hd, k4), vec![Step::Nis(hd, k4, NIS_SHARPNESS)]);
        assert_eq!(
            steps(NIS, hd, k6),
            vec![Step::Nis(hd, k4, 0.0), Step::Nis(k4, k6, NIS_SHARPNESS)]
        );
        assert_eq!(
            steps(NIS, hd, k8),
            vec![Step::Nis(hd, k4, 0.0), Step::Nis(k4, k8, NIS_SHARPNESS)]
        );
        for (method, size) in [(NIS, k6), (NIS, k8), (ANIME4K, k6)] {
            assert_eq!(steps(method, hd, size).last().map(|s| s.out()), Some(size));
        }
        for step in steps(NIS, (1280, 720), k8) {
            if let Step::Nis(from, to, sharpness) = step {
                assert!(
                    nis_constants(sharpness, from, to).is_some(),
                    "{from:?} → {to:?}"
                );
            }
        }
    }

    #[test]
    fn nis_enlarges_up_to_twice_and_never_makes_smaller() {
        let c = nis_constants(0.5, (1920, 1080), (2880, 1620)).unwrap();
        assert!((c.scale_x - 1920.0 / 2880.0).abs() < 1e-6);
        assert!(
            (c.sharp_strength_min - 0.4).abs() < 1e-6
                && (c.sharp_strength_scale - 1.2).abs() < 1e-6
        );
        assert!(nis_constants(0.5, (1280, 720), (3840, 2160)).is_none());
        assert!(nis_constants(0.5, (1920, 1080), (1280, 720)).is_none());
        assert_eq!(std::mem::size_of::<NisConstants>(), 28 * 4);
    }

    #[test]
    fn easu_s_constants_are_amd_s() {
        let c = easu_constants((1920, 1080), (3840, 2160));
        assert_eq!(&c[..4], &[0.5, 0.5, -0.25, -0.25]);
        assert_eq!(c[13], 4.0 / 1080.0);
    }
}
