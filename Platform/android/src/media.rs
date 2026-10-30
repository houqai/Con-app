use crate::now_us;
use jni::objects::{JClass, JObject};
use jni::JNIEnv;
use ndk_sys::*;
use std::ffi::c_void;
use std::ptr::null_mut;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicI64, AtomicPtr, Ordering::SeqCst};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::JoinHandle;
use std::time::Duration;

struct Drawer {
    running: Arc<AtomicBool>,
    thread: JoinHandle<()>,
}

struct Video {
    window: *mut ANativeWindow,
    decoder: *mut AMediaCodec,
    drawer: Option<Drawer>,
}

unsafe impl Send for Video {}

static VIDEO: Mutex<Video> = Mutex::new(Video {
    window: null_mut(),
    decoder: null_mut(),
    drawer: None,
});
static DECODING: AtomicBool = AtomicBool::new(false);
static SHOWN: AtomicI32 = AtomicI32::new(0);
static WIDTH: AtomicI32 = AtomicI32::new(0);
static HEIGHT: AtomicI32 = AtomicI32::new(0);
static DECODE_US: AtomicI32 = AtomicI32::new(0);

static PACING: AtomicBool = AtomicBool::new(false);
static LAST_REFRESH: AtomicI64 = AtomicI64::new(0);
static REFRESH_PERIOD: AtomicI64 = AtomicI64::new(16_666_667);
static REFRESHING: AtomicBool = AtomicBool::new(false);
static REFRESH_LOOPER: AtomicPtr<ALooper> = AtomicPtr::new(null_mut());

#[no_mangle]
pub extern "C" fn con_video_pacing(by_refresh: i32) {
    PACING.store(by_refresh != 0, SeqCst);
    if by_refresh != 0 {
        start_refreshes();
        wake_refreshes();
    }
}

fn refreshes_wanted() -> bool {
    PACING.load(SeqCst) && DECODING.load(SeqCst)
}

fn wake_refreshes() {
    let looper = REFRESH_LOOPER.load(SeqCst);
    if !looper.is_null() {
        unsafe { ALooper_wake(looper) };
    }
}

type PostFrame =
    unsafe extern "C" fn(*mut AChoreographer, unsafe extern "C" fn(i64, *mut c_void), *mut c_void);
static POST_FRAME: Mutex<Option<PostFrame>> = Mutex::new(None);

fn post_frame() -> Option<PostFrame> {
    let mut found = locked(&POST_FRAME);
    if found.is_none() {
        unsafe {
            let library = libc::dlopen(c"libandroid.so".as_ptr(), libc::RTLD_NOW);
            if !library.is_null() {
                let mut symbol =
                    libc::dlsym(library, c"AChoreographer_postFrameCallback64".as_ptr());
                if symbol.is_null() {
                    symbol = libc::dlsym(library, c"AChoreographer_postFrameCallback".as_ptr());
                }
                if !symbol.is_null() {
                    *found = Some(std::mem::transmute::<*mut c_void, PostFrame>(symbol));
                }
            }
        }
    }
    *found
}

fn start_refreshes() {
    static STARTED: AtomicBool = AtomicBool::new(false);
    if STARTED.swap(true, SeqCst) {
        return;
    }
    let _ = std::thread::Builder::new()
        .name("con-refreshes".into())
        .spawn(|| {
            let Some(post) = post_frame() else { return };
            unsafe {
                let looper = ALooper_prepare(0);
                let choreographer = AChoreographer_getInstance();
                if choreographer.is_null() {
                    return;
                }
                REFRESH_LOOPER.store(looper, SeqCst);
                loop {
                    if refreshes_wanted() && !REFRESHING.swap(true, SeqCst) {
                        post(choreographer, refreshed, choreographer as *mut c_void);
                    }
                    ALooper_pollOnce(-1, null_mut(), null_mut(), null_mut());
                }
            }
        });
}

unsafe extern "C" fn refreshed(time: i64, data: *mut c_void) {
    if !refreshes_wanted() {
        LAST_REFRESH.store(0, SeqCst);
        REFRESHING.store(false, SeqCst);
        return;
    }
    let last = LAST_REFRESH.swap(time, SeqCst);
    let gap = time - last;
    if last > 0 && (4_000_000..50_000_000).contains(&gap) {
        let period = REFRESH_PERIOD.load(SeqCst);
        REFRESH_PERIOD.store(period + (gap - period) / 8, SeqCst);
    }
    if let Some(post) = post_frame() {
        unsafe { post(data as *mut AChoreographer, refreshed, data) };
    }
}

fn paced_refresh(now_ns: i64, previous: &mut i64) -> Option<i64> {
    let last = LAST_REFRESH.load(SeqCst);
    let period = REFRESH_PERIOD.load(SeqCst).max(4_000_000);
    if last == 0 {
        return Some(now_ns);
    }
    let ahead = now_ns + 2_000_000 - last;
    let steps = if ahead <= 0 {
        0
    } else {
        (ahead + period - 1) / period
    };
    let mut refresh = last + steps * period;
    if refresh < *previous + period - period / 4 {
        refresh = *previous + period;
    }
    if refresh - now_ns > 2 * period + period / 2 {
        return None;
    }
    *previous = refresh;
    Some(refresh)
}

fn locked<T>(mutex: &'static Mutex<T>) -> MutexGuard<'static, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

const PLANNED: usize = 64;

#[derive(Clone, Copy)]
struct Planned {
    given: i64,
    delay: i64,
}

struct Plan {
    slots: [Planned; PLANNED],
    next: usize,
    last_given: i64,
}

static PLAN: Mutex<Plan> = Mutex::new(Plan {
    slots: [Planned { given: 0, delay: 0 }; PLANNED],
    next: 0,
    last_given: 0,
});

struct Codec(*mut AMediaCodec);
unsafe impl Send for Codec {}
impl Codec {
    fn get(&self) -> *mut AMediaCodec {
        self.0
    }
}

#[no_mangle]
pub unsafe extern "C" fn con_video_window(native: *mut c_void) {
    let next = native as *mut ANativeWindow;
    if !next.is_null() {
        unsafe { ANativeWindow_acquire(next) };
    }
    let (codec, drawer, old) = {
        let mut video = locked(&VIDEO);
        DECODING.store(false, SeqCst);
        (
            std::mem::replace(&mut video.decoder, null_mut()),
            video.drawer.take(),
            std::mem::replace(&mut video.window, next),
        )
    };
    finish(codec, drawer);
    if !old.is_null() {
        unsafe { ANativeWindow_release(old) };
    }
}

#[no_mangle]
pub unsafe extern "system" fn Java_app_con_check_Shared_surface(
    env: JNIEnv,
    _type: JClass,
    surface: JObject,
) {
    let next = if surface.is_null() {
        null_mut()
    } else {
        unsafe { ANativeWindow_fromSurface(env.get_raw(), surface.as_raw()) }
    };
    unsafe { con_video_window(next as *mut c_void) };
    if !next.is_null() {
        unsafe { ANativeWindow_release(next) };
    }
}

fn draw(codec: *mut AMediaCodec, running: &AtomicBool) {
    let mut average = 0f64;
    let mut previous_refresh = 0i64;
    while running.load(SeqCst) {
        let mut info = AMediaCodecBufferInfo {
            offset: 0,
            size: 0,
            presentationTimeUs: 0,
            flags: 0,
        };
        let index = unsafe { AMediaCodec_dequeueOutputBuffer(codec, &mut info, 10000) };
        if index >= 0 {
            let now = now_us();
            let given = info.presentationTimeUs;
            let mut delay = 0;
            {
                let mut plan = locked(&PLAN);
                if let Some(slot) = plan.slots.iter_mut().find(|slot| slot.given == given) {
                    delay = slot.delay;
                    slot.given = -1;
                }
            }
            let show = info.size > 0 && delay >= 0;
            if info.size > 0 && given > 0 && now >= given {
                let took = (now - given) as f64;
                average = if average == 0.0 {
                    took
                } else {
                    average + (took - average) / 16.0
                };
                DECODE_US.store(average as i32, SeqCst);
            }
            unsafe {
                if show && PACING.load(SeqCst) {
                    match paced_refresh(now * 1000, &mut previous_refresh) {
                        Some(refresh) => {
                            AMediaCodec_releaseOutputBufferAtTime(
                                codec,
                                index as usize,
                                refresh - 1_000_000,
                            );
                        }
                        None => {
                            AMediaCodec_releaseOutputBuffer(codec, index as usize, false);
                            continue;
                        }
                    }
                } else if show && delay > 0 && given + delay > now + 2000 {
                    AMediaCodec_releaseOutputBufferAtTime(
                        codec,
                        index as usize,
                        (given + delay) * 1000,
                    );
                } else {
                    AMediaCodec_releaseOutputBuffer(codec, index as usize, show);
                }
            }
            if show {
                SHOWN.fetch_add(1, SeqCst);
            }
        } else if index == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED as isize {
            unsafe {
                let format = AMediaCodec_getOutputFormat(codec);
                if !format.is_null() {
                    let mut value = 0i32;
                    if AMediaFormat_getInt32(format, AMEDIAFORMAT_KEY_WIDTH, &mut value) {
                        WIDTH.store(value, SeqCst);
                    }
                    if AMediaFormat_getInt32(format, AMEDIAFORMAT_KEY_HEIGHT, &mut value) {
                        HEIGHT.store(value, SeqCst);
                    }
                    AMediaFormat_delete(format);
                }
            }
        } else if index < AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED as isize {
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}

#[no_mangle]
pub extern "C" fn con_video_open(hevc: i32) -> i32 {
    con_video_close();
    let mut video = locked(&VIDEO);
    let mut result = 1;
    if !video.window.is_null() {
        let kind = if hevc != 0 {
            c"video/hevc"
        } else {
            c"video/avc"
        };
        unsafe {
            let codec = AMediaCodec_createDecoderByType(kind.as_ptr());
            let format = AMediaFormat_new();
            AMediaFormat_setString(format, AMEDIAFORMAT_KEY_MIME, kind.as_ptr());
            AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_WIDTH, 1920);
            AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_HEIGHT, 1080);
            AMediaFormat_setInt32(format, c"max-width".as_ptr(), 3840);
            AMediaFormat_setInt32(format, c"max-height".as_ptr(), 2160);
            AMediaFormat_setInt32(format, c"low-latency".as_ptr(), 1);
            AMediaFormat_setInt32(format, c"priority".as_ptr(), 0);
            AMediaFormat_setInt32(format, c"operating-rate".as_ptr(), 120);
            if !codec.is_null()
                && AMediaCodec_configure(codec, format, video.window, null_mut(), 0)
                    == media_status_t::AMEDIA_OK
                && AMediaCodec_start(codec) == media_status_t::AMEDIA_OK
            {
                video.decoder = codec;
                DECODING.store(true, SeqCst);
                SHOWN.store(0, SeqCst);
                WIDTH.store(0, SeqCst);
                HEIGHT.store(0, SeqCst);
                DECODE_US.store(0, SeqCst);
                let running = Arc::new(AtomicBool::new(true));
                let flag = Arc::clone(&running);
                let handed = Codec(codec);
                video.drawer = std::thread::Builder::new()
                    .spawn(move || draw(handed.get(), &flag))
                    .ok()
                    .map(|thread| Drawer { running, thread });
                result = 0;
            } else if !codec.is_null() {
                AMediaCodec_delete(codec);
            }
            AMediaFormat_delete(format);
        }
    }
    if result == 0 {
        wake_refreshes();
    }
    result
}

#[no_mangle]
pub unsafe extern "C" fn con_video_submit(
    unit: *const u8,
    length: i32,
    parameters: i32,
    delay_us: i64,
) -> i32 {
    let video = locked(&VIDEO);
    let decoder = video.decoder;
    let mut taken = if decoder.is_null() { -1 } else { 0 };
    if !decoder.is_null() && length > 0 {
        unsafe {
            let index = AMediaCodec_dequeueInputBuffer(decoder, 8000);
            if index >= 0 {
                let mut room = 0usize;
                let buffer = AMediaCodec_getInputBuffer(decoder, index as usize, &mut room);
                if !buffer.is_null() && room >= length as usize {
                    std::ptr::copy_nonoverlapping(unit, buffer, length as usize);
                    let given = {
                        let mut plan = locked(&PLAN);
                        let mut given = now_us();
                        if given <= plan.last_given {
                            given = plan.last_given + 1;
                        }
                        plan.last_given = given;
                        let slot = plan.next % PLANNED;
                        plan.slots[slot] = Planned {
                            given,
                            delay: delay_us,
                        };
                        plan.next = plan.next.wrapping_add(1);
                        given
                    };
                    let flags = if parameters != 0 {
                        AMEDIACODEC_BUFFER_FLAG_CODEC_CONFIG
                    } else {
                        0
                    };
                    taken = (AMediaCodec_queueInputBuffer(
                        decoder,
                        index as usize,
                        0,
                        length as usize,
                        given as u64,
                        flags,
                    ) == media_status_t::AMEDIA_OK) as i32;
                } else {
                    AMediaCodec_queueInputBuffer(decoder, index as usize, 0, 0, 0, 0);
                }
            }
        }
    }
    taken
}

#[no_mangle]
pub unsafe extern "C" fn con_video_counts(
    pictures: *mut i32,
    picture_width: *mut i32,
    picture_height: *mut i32,
) {
    unsafe {
        *pictures = SHOWN.load(SeqCst);
        *picture_width = WIDTH.load(SeqCst);
        *picture_height = HEIGHT.load(SeqCst);
    }
}

#[no_mangle]
pub extern "C" fn con_video_decode_us() -> i32 {
    DECODE_US.load(SeqCst)
}

#[no_mangle]
pub extern "C" fn con_video_ready() -> i32 {
    (!locked(&VIDEO).window.is_null()) as i32
}

#[no_mangle]
pub extern "C" fn con_video_close() {
    let (codec, drawer) = {
        let mut video = locked(&VIDEO);
        DECODING.store(false, SeqCst);
        let codec = std::mem::replace(&mut video.decoder, null_mut());
        (codec, video.drawer.take())
    };
    finish(codec, drawer);
}

fn finish(codec: *mut AMediaCodec, drawer: Option<Drawer>) {
    if let Some(drawer) = drawer {
        drawer.running.store(false, SeqCst);
        let _ = drawer.thread.join();
    }
    if !codec.is_null() {
        unsafe {
            AMediaCodec_stop(codec);
            AMediaCodec_delete(codec);
        }
    }
}

struct Sound {
    output: *mut AAudioStream,
    channels: i32,
    rate: i32,
    failed: i64,
}

unsafe impl Send for Sound {}

static SOUND: Mutex<Sound> = Mutex::new(Sound {
    output: null_mut(),
    channels: 0,
    rate: 0,
    failed: 0,
});
static WRITTEN: AtomicI32 = AtomicI32::new(0);
static REFUSED: AtomicI32 = AtomicI32::new(0);

#[no_mangle]
pub extern "C" fn con_audio_open(channels: i32, rate: i32) -> i32 {
    let mut sound = locked(&SOUND);
    unsafe {
        if !sound.output.is_null() && (sound.channels != channels || sound.rate != rate) {
            AAudioStream_requestStop(sound.output);
            AAudioStream_close(sound.output);
            sound.output = null_mut();
        }
        let mut result = 0;
        if sound.output.is_null() && sound.failed != 0 && now_us() - sound.failed < 1_000_000 {
            result = 1;
        } else if sound.output.is_null() {
            let mut builder: *mut AAudioStreamBuilder = null_mut();
            result = 1;
            if AAudio_createStreamBuilder(&mut builder) == AAUDIO_OK {
                AAudioStreamBuilder_setDirection(
                    builder,
                    AAUDIO_DIRECTION_OUTPUT as aaudio_direction_t,
                );
                AAudioStreamBuilder_setFormat(builder, AAUDIO_FORMAT_PCM_I16 as aaudio_format_t);
                AAudioStreamBuilder_setChannelCount(builder, channels);
                AAudioStreamBuilder_setSampleRate(builder, rate);
                AAudioStreamBuilder_setPerformanceMode(
                    builder,
                    AAUDIO_PERFORMANCE_MODE_NONE as aaudio_performance_mode_t,
                );
                AAudioStreamBuilder_setUsage(builder, AAUDIO_USAGE_GAME as aaudio_usage_t);
                let mut output: *mut AAudioStream = null_mut();
                if AAudioStreamBuilder_openStream(builder, &mut output) == AAUDIO_OK {
                    let wanted = rate / 7;
                    let most = AAudioStream_getBufferCapacityInFrames(output);
                    AAudioStream_setBufferSizeInFrames(output, wanted.min(most));
                    sound.channels = channels;
                    sound.rate = rate;
                    if AAudioStream_requestStart(output) == AAUDIO_OK {
                        result = 0;
                    } else {
                        AAudioStream_close(output);
                        output = null_mut();
                    }
                }
                sound.output = output;
                AAudioStreamBuilder_delete(builder);
            }
            sound.failed = if result != 0 { now_us() } else { 0 };
        }
        result
    }
}

#[no_mangle]
pub unsafe extern "C" fn con_audio_write(samples: *const i16, frames: i32) {
    let mut sound = locked(&SOUND);
    if !sound.output.is_null() && frames > 0 {
        unsafe {
            let taken = AAudioStream_write(sound.output, samples as *const c_void, frames, 0);
            if taken > 0 {
                WRITTEN.fetch_add(taken, SeqCst);
            }
            if taken < frames {
                REFUSED.fetch_add(1, SeqCst);
            }
            if taken == AAUDIO_ERROR_DISCONNECTED {
                AAudioStream_close(sound.output);
                sound.output = null_mut();
            }
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn con_audio_counts(frames_written: *mut i32, writes_refused: *mut i32) {
    unsafe {
        *frames_written = WRITTEN.load(SeqCst);
        *writes_refused = REFUSED.load(SeqCst);
    }
}

#[no_mangle]
pub extern "C" fn con_audio_underruns() -> i32 {
    let sound = locked(&SOUND);
    if sound.output.is_null() {
        0
    } else {
        unsafe { AAudioStream_getXRunCount(sound.output) }
    }
}

#[no_mangle]
pub extern "C" fn con_audio_close() {
    let mut sound = locked(&SOUND);
    if !sound.output.is_null() {
        unsafe {
            AAudioStream_requestStop(sound.output);
            AAudioStream_close(sound.output);
        }
        sound.output = null_mut();
    }
    WRITTEN.store(0, SeqCst);
    REFUSED.store(0, SeqCst);
}
