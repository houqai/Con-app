use crate::ffmpeg::*;
use crate::frc::{Frc, Nv12};
use crate::SDL_Renderer;
use sdl2_sys::{SDL_PixelFormatEnum, SDL_Rect, SDL_Texture, SDL_TextureAccess};
use std::collections::VecDeque;
use std::ptr::null_mut;
use std::sync::atomic::{AtomicI32, Ordering::Relaxed};
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::time::Instant;

struct Video {
    decoder: *mut AVCodecContext,
    packet: *mut AVPacket,
    decoded: *mut AVFrame,
    transfer: *mut AVFrame,
    frc: Option<Frc>,
    frc_failed: bool,
    last_arrival: i64,
    interval_us: i64,
    pending: *mut AVFrame,
    pending_arrival: i64,
    signature: Vec<u8>,
}

unsafe impl Send for Video {}

static VIDEO: Mutex<Video> = Mutex::new(Video {
    decoder: null_mut(),
    packet: null_mut(),
    decoded: null_mut(),
    transfer: null_mut(),
    frc: None,
    frc_failed: false,
    last_arrival: 0,
    interval_us: 16_667,
    pending: null_mut(),
    pending_arrival: 0,
    signature: Vec::new(),
});

struct Screen {
    waiting: VecDeque<(*mut AVFrame, i64)>,
    spare: Vec<*mut AVFrame>,
    texture: *mut SDL_Texture,
    texture_width: i32,
    texture_height: i32,
    texture_format: u32,
    #[cfg_attr(not(windows), allow(dead_code))]
    joined_chroma: Vec<u8>,
}

unsafe impl Send for Screen {}

static SCREEN: Mutex<Screen> = Mutex::new(Screen {
    waiting: VecDeque::new(),
    spare: Vec::new(),
    texture: null_mut(),
    texture_width: 0,
    texture_height: 0,
    texture_format: 0,
    joined_chroma: Vec::new(),
});

impl Screen {
    fn spare(&mut self) -> *mut AVFrame {
        self.spare
            .pop()
            .unwrap_or_else(|| unsafe { av_frame_alloc() })
    }
    fn give_back(&mut self, picture: *mut AVFrame) {
        unsafe { av_frame_unref(picture) };
        self.spare.push(picture);
    }
    fn push(&mut self, picture: *mut AVFrame, time: i64) {
        self.waiting.push_back((picture, time));
        while self.waiting.len() > WAITING_MAX {
            if let Some((old, _)) = self.waiting.pop_front() {
                self.give_back(old);
                SKIPPED_COUNT.fetch_add(1, Relaxed);
            }
        }
    }
}

static DECODED_COUNT: AtomicI32 = AtomicI32::new(0);
static DRAWN_COUNT: AtomicI32 = AtomicI32::new(0);
static PICTURE_WIDTH: AtomicI32 = AtomicI32::new(0);
static PICTURE_HEIGHT: AtomicI32 = AtomicI32::new(0);
static DECODE_US: AtomicI32 = AtomicI32::new(0);
static HARDWARE: AtomicI32 = AtomicI32::new(0);
static BY_REFRESH: AtomicI32 = AtomicI32::new(0);
static UPSCALE_X100: AtomicI32 = AtomicI32::new(0);
static UPSCALED_HEIGHT: AtomicI32 = AtomicI32::new(0);
static UPSCALE_METHOD: AtomicI32 = AtomicI32::new(0);
static GENERATION: AtomicI32 = AtomicI32::new(0);
static GENERATED_COUNT: AtomicI32 = AtomicI32::new(0);
static INTERVAL_US: AtomicI32 = AtomicI32::new(16_667);
static SKIPPED_COUNT: AtomicI32 = AtomicI32::new(0);
const WAITING_MAX: usize = 4;
const REPEAT_HIDDEN_US: i64 = 100_000;
const KEPT_BY_REFRESH: usize = 2;

pub fn pick(times: &[i64], now: i64, by_refresh: bool) -> Option<usize> {
    if times.is_empty() {
        return None;
    }
    if by_refresh {
        return Some(times.len().saturating_sub(KEPT_BY_REFRESH));
    }
    times.iter().rposition(|&time| time <= now)
}

fn video() -> MutexGuard<'static, Video> {
    VIDEO
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn screen() -> MutexGuard<'static, Screen> {
    SCREEN
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

pub fn signature(luma: &[u8], pitch: usize, width: usize, height: usize) -> Vec<u8> {
    let step = (width / 320).max(1);
    let (columns, rows) = (width / step, height / step);
    let mut samples = Vec::with_capacity(columns * rows);
    for y in 0..rows {
        let line = (y * step + step / 2) * pitch;
        for x in 0..columns {
            samples.push(luma.get(line + x * step + step / 2).copied().unwrap_or(0));
        }
    }
    samples
}

pub fn change(before: &[u8], now: &[u8]) -> f64 {
    if now.is_empty() || before.len() != now.len() {
        return 255.0;
    }
    let sum: u64 = before
        .iter()
        .zip(now)
        .map(|(&a, &b)| u64::from(a.abs_diff(b)))
        .sum();
    sum as f64 / now.len() as f64
}

pub fn paced(interval: i64, gap: i64) -> i64 {
    if (5_000..=50_000).contains(&gap) {
        interval + (gap - interval) / 8
    } else {
        interval
    }
}

fn now_us() -> i64 {
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_micros() as i64
}

pub fn averaged(average: i32, took: i32) -> i32 {
    if average == 0 {
        took
    } else {
        average + (took - average) / 16
    }
}

pub fn placed(
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    picture_width: i32,
    picture_height: i32,
    fill: bool,
) -> SDL_Rect {
    let scale_x = f64::from(width) / f64::from(picture_width);
    let scale_y = f64::from(height) / f64::from(picture_height);
    let scale = if fill {
        scale_x.max(scale_y)
    } else {
        scale_x.min(scale_y)
    };
    let w = f64::from(picture_width) * scale;
    let h = f64::from(picture_height) * scale;
    SDL_Rect {
        x: x + ((f64::from(width) - w) / 2.0) as i32,
        y: y + ((f64::from(height) - h) / 2.0) as i32,
        w: w as i32,
        h: h as i32,
    }
}

#[cfg(windows)]
unsafe fn attach_hardware(context: *mut AVCodecContext) {
    if std::env::var_os("CON_SOFTWARE_DECODE").is_some() {
        return;
    }
    let mut device: *mut AVBufferRef = null_mut();
    unsafe {
        if av_hwdevice_ctx_create(
            &mut device,
            AV_HWDEVICE_TYPE_D3D11VA,
            std::ptr::null(),
            null_mut(),
            0,
        ) != 0
        {
            return;
        }
        (*context).hw_device_ctx = av_buffer_ref(device);
        av_buffer_unref(&mut device);
        (*context).get_format = Some(pick_format);
    }
}

#[cfg(not(windows))]
unsafe fn attach_hardware(_context: *mut AVCodecContext) {}

#[cfg(windows)]
unsafe extern "C" fn pick_format(
    _context: *mut AVCodecContext,
    formats: *const AVPixelFormat,
) -> AVPixelFormat {
    let mut chosen = AV_PIX_FMT_NONE;
    unsafe {
        let mut at = formats;
        while *at != AV_PIX_FMT_NONE {
            if *at == AV_PIX_FMT_D3D11 {
                return AV_PIX_FMT_D3D11;
            }
            chosen = *at;
            at = at.add(1);
        }
    }
    chosen
}

#[no_mangle]
pub extern "C" fn con_video_hardware() -> i32 {
    HARDWARE.load(Relaxed)
}

#[no_mangle]
pub extern "C" fn con_video_open(hevc: i32) -> i32 {
    con_video_close();
    let mut video = video();
    unsafe {
        let codec = avcodec_find_decoder(if hevc != 0 {
            AV_CODEC_ID_HEVC
        } else {
            AV_CODEC_ID_H264
        });
        let mut context = if codec.is_null() {
            null_mut()
        } else {
            avcodec_alloc_context3(codec)
        };
        if context.is_null() {
            return 1;
        }
        (*context).flags |= AV_CODEC_FLAG_LOW_DELAY as i32;
        (*context).thread_count = 0;
        (*context).thread_type = FF_THREAD_SLICE as i32;
        attach_hardware(context);
        if avcodec_open2(context, codec, null_mut()) != 0 {
            avcodec_free_context(&mut context);
            return 1;
        }
        video.decoder = context;
        video.packet = av_packet_alloc();
        video.decoded = av_frame_alloc();
        video.transfer = av_frame_alloc();
    }
    DECODED_COUNT.store(0, Relaxed);
    SKIPPED_COUNT.store(0, Relaxed);
    GENERATED_COUNT.store(0, Relaxed);
    DRAWN_COUNT.store(0, Relaxed);
    DECODE_US.store(0, Relaxed);
    HARDWARE.store(0, Relaxed);
    0
}

#[no_mangle]
pub extern "C" fn con_video_present(new: i32, due_in_us: i64) {
    let mut video = video();
    let picture = std::mem::replace(&mut video.pending, null_mut());
    if picture.is_null() {
        return;
    }
    if new == 0 {
        let following = now_us() - video.last_arrival < REPEAT_HIDDEN_US;
        if video.frc.is_some() && GENERATION.load(Relaxed) != 0 && following {
            screen().give_back(picture);
        } else {
            screen().push(picture, now_us() + due_in_us.max(0));
        }
        return;
    }
    let arrival = video.pending_arrival;
    if video.last_arrival > 0 {
        video.interval_us = paced(video.interval_us, arrival - video.last_arrival);
        INTERVAL_US.store(video.interval_us as i32, Relaxed);
    }
    video.last_arrival = arrival;
    let time = now_us() + due_in_us.max(0);
    let generated = unsafe { generate(&mut video, picture, arrival) };
    let later = if generated.is_empty() {
        0
    } else {
        video.interval_us / 2
    };
    let mut screen = screen();
    for frame in generated {
        screen.push(frame, time);
    }
    screen.push(picture, time + later);
}

#[no_mangle]
pub extern "C" fn con_video_generation(on: i32) {
    GENERATION.store(i32::from(on != 0), Relaxed);
}

#[no_mangle]
pub extern "C" fn con_video_generation_available() -> i32 {
    i32::from(Frc::available())
}

#[no_mangle]
pub extern "C" fn con_video_generation_check() -> i32 {
    crate::frc::check()
}

#[no_mangle]
pub extern "C" fn con_video_upscale(factor_x100: i32) {
    UPSCALE_X100.store(factor_x100.max(0), Relaxed);
}

#[no_mangle]
pub extern "C" fn con_video_upscale_method(method: i32) {
    UPSCALE_METHOD.store(method, Relaxed);
}

#[no_mangle]
pub unsafe extern "C" fn con_video_upscale_methods(renderer: *mut SDL_Renderer) -> i32 {
    #[cfg(windows)]
    {
        unsafe { crate::upscale::methods(renderer as *mut sdl2_sys::SDL_Renderer) }
    }
    #[cfg(not(windows))]
    {
        let _ = renderer;
        0
    }
}

#[cfg(windows)]
fn report(result: Result<String, String>) -> i32 {
    match result {
        Ok(line) => {
            eprintln!("upscale: {line}");
            0
        }
        Err(line) => {
            eprintln!("upscale: failed: {line}");
            1
        }
    }
}

#[no_mangle]
pub extern "C" fn con_video_upscale_check() -> i32 {
    #[cfg(windows)]
    {
        report(crate::upscale::check())
    }
    #[cfg(not(windows))]
    {
        eprintln!("upscale: only on Windows");
        1
    }
}

#[no_mangle]
pub unsafe extern "C" fn con_video_upscale_check_on(renderer: *mut SDL_Renderer) -> i32 {
    #[cfg(windows)]
    {
        report(unsafe { crate::upscale::check_on(renderer as *mut sdl2_sys::SDL_Renderer) })
    }
    #[cfg(not(windows))]
    {
        let _ = renderer;
        1
    }
}

#[no_mangle]
pub extern "C" fn con_video_upscaled_height() -> i32 {
    UPSCALED_HEIGHT.load(Relaxed)
}

#[no_mangle]
pub extern "C" fn con_video_pacing(by_refresh: i32) {
    BY_REFRESH.store(i32::from(by_refresh != 0), Relaxed);
}

unsafe fn generate(video: &mut Video, picture: *mut AVFrame, time: i64) -> Vec<*mut AVFrame> {
    let mut made = Vec::new();
    if GENERATION.load(Relaxed) == 0 || video.frc_failed {
        video.frc = None;
        return made;
    }
    unsafe {
        let (width, height) = ((*picture).width, (*picture).height);
        if (*picture).format != AV_PIX_FMT_NV12 || width <= 0 || height <= 0 {
            return made;
        }
        if video.frc.as_ref().map(|frc| frc.size()) != Some((width, height)) {
            video.frc = Frc::new(width, height);
            if video.frc.is_none() {
                video.frc_failed = true;
                return made;
            }
        }
        let (luma_pitch, chroma_pitch) = (
            (*picture).linesize[0] as usize,
            (*picture).linesize[1] as usize,
        );
        let rows = height as usize;
        let input = Nv12 {
            width,
            height,
            luma: std::slice::from_raw_parts((*picture).data[0], luma_pitch * rows),
            luma_pitch,
            chroma: std::slice::from_raw_parts((*picture).data[1], chroma_pitch * (rows / 2)),
            chroma_pitch,
        };
        let Some(frc) = video.frc.as_mut() else {
            return made;
        };
        let worked = frc.between(&input, time, video.interval_us, &mut |between: &Nv12| {
            let frame = screen().spare();
            if frame.is_null() {
                return;
            }
            (*frame).format = AV_PIX_FMT_NV12;
            (*frame).width = between.width;
            (*frame).height = between.height;
            if av_frame_get_buffer(frame, 0) != 0 {
                screen().give_back(frame);
                return;
            }
            let width = between.width as usize;
            for row in 0..rows {
                std::ptr::copy_nonoverlapping(
                    between.luma.as_ptr().add(row * between.luma_pitch),
                    (*frame).data[0].add(row * (*frame).linesize[0] as usize),
                    width,
                );
            }
            for row in 0..rows / 2 {
                std::ptr::copy_nonoverlapping(
                    between.chroma.as_ptr().add(row * between.chroma_pitch),
                    (*frame).data[1].add(row * (*frame).linesize[1] as usize),
                    width,
                );
            }
            GENERATED_COUNT.fetch_add(1, Relaxed);
            made.push(frame);
        });
        if !worked {
            video.frc = None;
            video.frc_failed = true;
        }
    }
    made
}

#[no_mangle]
pub unsafe extern "C" fn con_video_submit(
    unit: *const u8,
    length: i32,
    show: i32,
    change_out: *mut f64,
) -> i32 {
    unsafe { *change_out = -1.0 };
    let mut video = video();
    if video.decoder.is_null() {
        return -1;
    }
    let mut taken = 0;
    let started = now_us();
    unsafe {
        if length >= 0
            && !video.packet.is_null()
            && !video.decoded.is_null()
            && !video.transfer.is_null()
            && av_new_packet(video.packet, length) == 0
        {
            if length > 0 {
                std::ptr::copy_nonoverlapping(unit, (*video.packet).data, length as usize);
            }
            if avcodec_send_packet(video.decoder, video.packet) == 0 {
                taken = 1;
                while avcodec_receive_frame(video.decoder, video.decoded) == 0 {
                    let decoded = video.decoded;
                    if (*decoded).decode_error_flags != 0
                        || ((*decoded).flags & AV_FRAME_FLAG_CORRUPT as i32) != 0
                    {
                        taken = 0;
                        av_frame_unref(decoded);
                        continue;
                    }
                    DECODED_COUNT.fetch_add(1, Relaxed);
                    PICTURE_WIDTH.store((*decoded).width, Relaxed);
                    PICTURE_HEIGHT.store((*decoded).height, Relaxed);
                    let card = hardware_format((*decoded).format);
                    HARDWARE.store(i32::from(card), Relaxed);
                    if show == 0 {
                        av_frame_unref(decoded);
                        continue;
                    }
                    let picture = if card {
                        av_frame_unref(video.transfer);
                        let copied = av_hwframe_transfer_data(video.transfer, decoded, 0) == 0;
                        av_frame_unref(decoded);
                        if !copied {
                            taken = 0;
                            continue;
                        }
                        video.transfer
                    } else {
                        decoded
                    };
                    let (width, height) = ((*picture).width as usize, (*picture).height as usize);
                    let pitch = (*picture).linesize[0] as usize;
                    let now = signature(
                        std::slice::from_raw_parts((*picture).data[0], pitch * height),
                        pitch,
                        width,
                        height,
                    );
                    *change_out = change(&video.signature, &now);
                    video.signature = now;
                    let slot = screen().spare();
                    if slot.is_null() {
                        av_frame_unref(picture);
                        continue;
                    }
                    av_frame_move_ref(slot, picture);
                    if !video.pending.is_null() {
                        screen().give_back(video.pending);
                    }
                    video.pending = slot;
                    video.pending_arrival = started;
                }
            }
            av_packet_unref(video.packet);
        }
    }
    let took = (now_us() - started) as i32;
    DECODE_US.store(averaged(DECODE_US.load(Relaxed), took), Relaxed);
    taken
}

fn hardware_format(format: i32) -> bool {
    #[cfg(windows)]
    {
        format == AV_PIX_FMT_D3D11 as i32
    }
    #[cfg(not(windows))]
    {
        let _ = format;
        false
    }
}

#[no_mangle]
pub unsafe extern "C" fn con_video_draw(
    renderer: *mut SDL_Renderer,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    fill: i32,
) -> i32 {
    let renderer = renderer as *mut sdl2_sys::SDL_Renderer;
    let mut screen = screen();
    unsafe {
        let times: Vec<i64> = screen.waiting.iter().map(|&(_, time)| time).collect();
        let chosen = pick(&times, now_us(), BY_REFRESH.load(Relaxed) != 0);
        let mut picture = null_mut();
        if let Some(index) = chosen {
            for _ in 0..index {
                if let Some((old, _)) = screen.waiting.pop_front() {
                    screen.give_back(old);
                    SKIPPED_COUNT.fetch_add(1, Relaxed);
                }
            }
            picture = screen
                .waiting
                .pop_front()
                .map_or(null_mut(), |(picture, _)| picture);
        }
        #[cfg(windows)]
        {
            let factor = UPSCALE_X100.load(Relaxed);
            let (factor, method) = if factor > 0 {
                (f64::from(factor) / 100.0, UPSCALE_METHOD.load(Relaxed))
            } else {
                (1.0, crate::upscale::PLAIN)
            };
            let format = if picture.is_null() {
                AV_PIX_FMT_NV12
            } else {
                (*picture).format
            };
            let usable = picture.is_null()
                || ((format == AV_PIX_FMT_NV12 || format == AV_PIX_FMT_YUV420P)
                    && (*picture).width > 0);
            if usable {
                let mut joined = std::mem::take(&mut screen.joined_chroma);
                let input = (!picture.is_null()).then(|| {
                    let (w, h) = ((*picture).width, (*picture).height);
                    let (lp, cp) = (
                        (*picture).linesize[0] as usize,
                        (*picture).linesize[1] as usize,
                    );
                    let luma = std::slice::from_raw_parts((*picture).data[0], lp * h as usize);
                    if format == AV_PIX_FMT_NV12 {
                        return Nv12 {
                            width: w,
                            height: h,
                            luma,
                            luma_pitch: lp,
                            chroma: std::slice::from_raw_parts(
                                (*picture).data[1],
                                cp * (h as usize / 2),
                            ),
                            chroma_pitch: cp,
                        };
                    }
                    let (cw, ch, vp) = (
                        w as usize / 2,
                        h as usize / 2,
                        (*picture).linesize[2] as usize,
                    );
                    let (u, v) = (
                        std::slice::from_raw_parts((*picture).data[1], cp * ch),
                        std::slice::from_raw_parts((*picture).data[2], vp * ch),
                    );
                    joined.clear();
                    joined.reserve(cw * 2 * ch);
                    for row in 0..ch {
                        for x in 0..cw {
                            joined.push(u[row * cp + x]);
                            joined.push(v[row * vp + x]);
                        }
                    }
                    Nv12 {
                        width: w,
                        height: h,
                        luma,
                        luma_pitch: lp,
                        chroma: &joined[..],
                        chroma_pitch: cw * 2,
                    }
                });
                let size = input
                    .as_ref()
                    .map(|p| (p.width, p.height))
                    .or_else(crate::upscale::source);
                let drawn = size.and_then(|(pw, ph)| {
                    let place = placed(x, y, width, height, pw, ph, fill != 0);
                    crate::upscale::draw(
                        renderer,
                        input.as_ref(),
                        factor,
                        method,
                        (place.x, place.y, place.w, place.h),
                    )
                    .map(|(_, enlarged)| (enlarged, ph))
                });
                drop(input);
                screen.joined_chroma = joined;
                if let Some((enlarged, ph)) = drawn {
                    UPSCALED_HEIGHT.store(if enlarged != ph { enlarged } else { 0 }, Relaxed);
                    if !picture.is_null() {
                        DRAWN_COUNT.fetch_add(1, Relaxed);
                        screen.give_back(picture);
                    }
                    return 1;
                }
            }
            UPSCALED_HEIGHT.store(0, Relaxed);
        }
        if !picture.is_null() && (*picture).width > 0 {
            let nv12 = (*picture).format == AV_PIX_FMT_NV12;
            let format = if nv12 {
                SDL_PixelFormatEnum::SDL_PIXELFORMAT_NV12
            } else {
                SDL_PixelFormatEnum::SDL_PIXELFORMAT_IYUV
            } as u32;
            if screen.texture.is_null()
                || screen.texture_width != (*picture).width
                || screen.texture_height != (*picture).height
                || screen.texture_format != format
            {
                if !screen.texture.is_null() {
                    sdl2_sys::SDL_DestroyTexture(screen.texture);
                }
                screen.texture = sdl2_sys::SDL_CreateTexture(
                    renderer,
                    format,
                    SDL_TextureAccess::SDL_TEXTUREACCESS_STREAMING as i32,
                    (*picture).width,
                    (*picture).height,
                );
                screen.texture_width = (*picture).width;
                screen.texture_height = (*picture).height;
                screen.texture_format = format;
            }
            if !screen.texture.is_null() {
                let (data, lines) = (&(*picture).data, &(*picture).linesize);
                if nv12 {
                    sdl2_sys::SDL_UpdateNVTexture(
                        screen.texture,
                        std::ptr::null(),
                        data[0],
                        lines[0],
                        data[1],
                        lines[1],
                    );
                } else {
                    sdl2_sys::SDL_UpdateYUVTexture(
                        screen.texture,
                        std::ptr::null(),
                        data[0],
                        lines[0],
                        data[1],
                        lines[1],
                        data[2],
                        lines[2],
                    );
                }
                DRAWN_COUNT.fetch_add(1, Relaxed);
            }
        }
        if !picture.is_null() {
            screen.give_back(picture);
        }
    }
    let (drawn, picture_width, picture_height) =
        (screen.texture, screen.texture_width, screen.texture_height);
    drop(screen);
    if drawn.is_null() || picture_width <= 0 || picture_height <= 0 {
        return 0;
    }
    let place = placed(
        x,
        y,
        width,
        height,
        picture_width,
        picture_height,
        fill != 0,
    );
    unsafe { sdl2_sys::SDL_RenderCopy(renderer, drawn, std::ptr::null(), &place) };
    1
}

#[no_mangle]
pub unsafe extern "C" fn con_video_counts(
    decoded: *mut i32,
    drawn: *mut i32,
    skipped: *mut i32,
    generated: *mut i32,
    width: *mut i32,
    height: *mut i32,
    decode_us: *mut i32,
    interval_us: *mut i32,
) {
    unsafe {
        *decoded = DECODED_COUNT.load(Relaxed);
        *drawn = DRAWN_COUNT.load(Relaxed);
        *skipped = SKIPPED_COUNT.load(Relaxed);
        *generated = GENERATED_COUNT.load(Relaxed);
        *width = PICTURE_WIDTH.load(Relaxed);
        *height = PICTURE_HEIGHT.load(Relaxed);
        *decode_us = DECODE_US.load(Relaxed);
        *interval_us = INTERVAL_US.load(Relaxed);
    }
}

#[no_mangle]
pub extern "C" fn con_video_close() {
    let mut video = video();
    unsafe {
        if !video.decoder.is_null() {
            avcodec_free_context(&mut video.decoder);
        }
        if !video.packet.is_null() {
            av_packet_free(&mut video.packet);
        }
        if !video.decoded.is_null() {
            av_frame_free(&mut video.decoded);
        }
        if !video.transfer.is_null() {
            av_frame_free(&mut video.transfer);
        }
    }
    video.frc = None;
    video.frc_failed = false;
    video.last_arrival = 0;
    video.signature.clear();
    let pending = std::mem::replace(&mut video.pending, null_mut());
    drop(video);
    if !pending.is_null() {
        screen().give_back(pending);
    }
    let mut screen = screen();
    unsafe {
        while let Some((picture, _)) = screen.waiting.pop_front() {
            screen.give_back(picture);
        }
        for mut picture in std::mem::take(&mut screen.spare) {
            av_frame_free(&mut picture);
        }
    }
}

#[no_mangle]
pub extern "C" fn con_video_forget() {
    let mut screen = screen();
    if !screen.texture.is_null() {
        unsafe { sdl2_sys::SDL_DestroyTexture(screen.texture) };
    }
    screen.texture = null_mut();
    screen.texture_width = 0;
    screen.texture_height = 0;
    #[cfg(windows)]
    crate::upscale::forget();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_picture_keeps_its_shape() {
        let fitted = placed(0, 0, 960, 1080, 1920, 1080, false);
        assert_eq!((fitted.x, fitted.y, fitted.w, fitted.h), (0, 270, 960, 540));
        let filled = placed(10, 20, 960, 1080, 1920, 1080, true);
        assert_eq!(
            (filled.x, filled.y, filled.w, filled.h),
            (-470, 20, 1920, 1080)
        );
    }

    #[test]
    fn the_screen_takes_the_newest_picture_whose_time_has_come() {
        assert_eq!(pick(&[], 100, false), None);
        assert_eq!(pick(&[10, 20, 30], 100, false), Some(2));
        assert_eq!(pick(&[10, 20, 130], 100, false), Some(1));
        assert_eq!(pick(&[110, 120], 100, false), None);
    }

    #[test]
    fn by_the_refreshes_one_picture_goes_to_each() {
        assert_eq!(pick(&[500], 100, true), Some(0));
        assert_eq!(pick(&[10, 20], 100, true), Some(0));
        assert_eq!(pick(&[10, 20, 30, 40], 100, true), Some(2));
    }

    #[test]
    fn a_picture_is_compared_by_its_brightness_on_a_grid() {
        let flat = vec![100u8; 640 * 360];
        let mut moved = flat.clone();
        moved.iter_mut().step_by(2).for_each(|v| *v = 110);
        let a = signature(&flat, 640, 640, 360);
        assert_eq!(a.len(), 320 * 180);
        assert_eq!(change(&a, &a), 0.0);
        assert_eq!(change(&a, &signature(&moved, 640, 640, 360)), 0.0);
        assert_eq!(change(&[], &a), 255.0);
        assert_eq!(
            change(&a, &signature(&vec![90u8; 640 * 360], 640, 640, 360)),
            10.0
        );
    }

    #[test]
    fn the_time_between_pictures_follows_the_gaps_but_not_a_pause() {
        assert_eq!(paced(16_000, 24_000), 17_000);
        assert_eq!(paced(16_000, 400_000), 16_000);
        assert_eq!(paced(16_000, 1_000), 16_000);
    }

    #[test]
    fn the_decode_time_is_a_running_average() {
        assert_eq!(averaged(0, 5000), 5000);
        assert_eq!(averaged(5000, 6600), 5100);
        assert_eq!(averaged(5000, 4990), 5000);
    }
}
