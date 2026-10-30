use crate::con_check_unit;
use ndk_sys::*;
use std::ffi::{c_void, CStr};
use std::ptr::null_mut;
use std::sync::atomic::{AtomicI32, AtomicPtr, Ordering::SeqCst};

static READER: AtomicPtr<AImageReader> = AtomicPtr::new(null_mut());
static PICTURES: AtomicI32 = AtomicI32::new(0);

const COLOR_FORMAT_YUV420_FLEXIBLE: i32 = 0x7F420888;
const FRAME_US: u64 = 33_333;
const ENCODE_TIMEOUT_MS: i64 = 15_000;

#[no_mangle]
pub extern "C" fn con_check_begin() -> i32 {
    unsafe {
        let binder = libc::dlopen(c"libbinder_ndk.so".as_ptr(), libc::RTLD_NOW);
        let start = if binder.is_null() {
            null_mut()
        } else {
            libc::dlsym(binder, c"ABinderProcess_startThreadPool".as_ptr())
        };
        if start.is_null() {
            return 0;
        }
        let start: extern "C" fn() = std::mem::transmute(start);
        start();
    }
    1
}

unsafe extern "C" fn on_image_available(_context: *mut c_void, reader: *mut AImageReader) {
    let mut image: *mut AImage = null_mut();
    unsafe {
        if AImageReader_acquireNextImage(reader, &mut image) == media_status_t::AMEDIA_OK
            && !image.is_null()
        {
            PICTURES.fetch_add(1, SeqCst);
            AImage_delete(image);
        }
    }
}

#[no_mangle]
pub extern "C" fn con_check_window_open(width: i32, height: i32) -> *mut c_void {
    con_check_window_close();
    let mut reader: *mut AImageReader = null_mut();
    let mut window: *mut ANativeWindow = null_mut();
    unsafe {
        if AImageReader_new(
            width,
            height,
            AIMAGE_FORMATS::AIMAGE_FORMAT_YUV_420_888.0 as i32,
            4,
            &mut reader,
        ) != media_status_t::AMEDIA_OK
        {
            return null_mut();
        }
        READER.store(reader, SeqCst);
        let mut listener = AImageReader_ImageListener {
            context: null_mut(),
            onImageAvailable: Some(on_image_available),
        };
        AImageReader_setImageListener(reader, &mut listener);
        PICTURES.store(0, SeqCst);
        if AImageReader_getWindow(reader, &mut window) == media_status_t::AMEDIA_OK {
            window as *mut c_void
        } else {
            null_mut()
        }
    }
}

#[no_mangle]
pub extern "C" fn con_check_window_pictures() -> i32 {
    PICTURES.load(SeqCst)
}

#[no_mangle]
pub extern "C" fn con_check_window_close() {
    let reader = READER.swap(null_mut(), SeqCst);
    if !reader.is_null() {
        unsafe { AImageReader_delete(reader) };
    }
}

fn now_ms() -> i64 {
    let mut time = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut time) };
    time.tv_sec * 1000 + time.tv_nsec / 1_000_000
}

#[no_mangle]
pub unsafe extern "C" fn con_check_encode(
    hevc: i32,
    width: i32,
    height: i32,
    frames: i32,
    unit: con_check_unit,
    context: *mut c_void,
) -> i32 {
    let (mime, name): (&CStr, &CStr) = if hevc != 0 {
        (c"video/hevc", c"c2.android.hevc.encoder")
    } else {
        (c"video/avc", c"c2.android.avc.encoder")
    };
    unsafe {
        let mut codec = AMediaCodec_createCodecByName(name.as_ptr());
        if codec.is_null() {
            codec = AMediaCodec_createEncoderByType(mime.as_ptr());
        }
        if codec.is_null() {
            return -1;
        }
        let format = AMediaFormat_new();
        AMediaFormat_setString(format, AMEDIAFORMAT_KEY_MIME, mime.as_ptr());
        AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_WIDTH, width);
        AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_HEIGHT, height);
        AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_BIT_RATE, 2_000_000);
        AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_FRAME_RATE, 30);
        AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_I_FRAME_INTERVAL, 1);
        AMediaFormat_setInt32(
            format,
            AMEDIAFORMAT_KEY_COLOR_FORMAT,
            COLOR_FORMAT_YUV420_FLEXIBLE,
        );
        let mut result = -2;
        if AMediaCodec_configure(
            codec,
            format,
            null_mut(),
            null_mut(),
            AMEDIACODEC_CONFIGURE_FLAG_ENCODE as u32,
        ) == media_status_t::AMEDIA_OK
        {
            result = -3;
            if AMediaCodec_start(codec) == media_status_t::AMEDIA_OK {
                result = 0;
                let mut sent = 0i32;
                let mut input_done = false;
                let mut ended = false;
                let until = now_ms() + ENCODE_TIMEOUT_MS;
                while !ended && now_ms() < until {
                    let input = if input_done {
                        -1
                    } else {
                        AMediaCodec_dequeueInputBuffer(codec, 5000)
                    };
                    if input >= 0 {
                        let mut room = 0usize;
                        let picture = AMediaCodec_getInputBuffer(codec, input as usize, &mut room);
                        let luma_size = width as usize * height as usize;
                        let frame_size = luma_size * 3 / 2;
                        if sent < frames && !picture.is_null() && room >= frame_size {
                            let pixels = std::slice::from_raw_parts_mut(picture, frame_size);
                            for (at, pixel) in pixels[..luma_size].iter_mut().enumerate() {
                                *pixel =
                                    (at % width as usize + at / width as usize + sent as usize * 8)
                                        as u8;
                            }
                            pixels[luma_size..].fill(128);
                            AMediaCodec_queueInputBuffer(
                                codec,
                                input as usize,
                                0,
                                frame_size,
                                sent as u64 * FRAME_US,
                                0,
                            );
                            sent += 1;
                        } else {
                            if sent < frames {
                                eprintln!(
                                    "      encoder input buffer holds {room} bytes, a frame needs {frame_size} ({})",
                                    if picture.is_null() { "no buffer" } else { "buffer present" }
                                );
                            }
                            AMediaCodec_queueInputBuffer(
                                codec,
                                input as usize,
                                0,
                                0,
                                sent as u64 * FRAME_US,
                                AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM,
                            );
                            input_done = true;
                        }
                    }
                    let mut info = AMediaCodecBufferInfo {
                        offset: 0,
                        size: 0,
                        presentationTimeUs: 0,
                        flags: 0,
                    };
                    let out = AMediaCodec_dequeueOutputBuffer(codec, &mut info, 5000);
                    if out >= 0 {
                        let mut size = 0usize;
                        let bytes = AMediaCodec_getOutputBuffer(codec, out as usize, &mut size);
                        if !bytes.is_null() && info.size > 0 {
                            if let Some(unit) = unit {
                                unit(
                                    bytes.add(info.offset as usize),
                                    info.size,
                                    (info.flags & AMEDIACODEC_BUFFER_FLAG_CODEC_CONFIG != 0) as i32,
                                    context,
                                );
                            }
                            result += 1;
                        }
                        ended = info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM != 0;
                        AMediaCodec_releaseOutputBuffer(codec, out as usize, false);
                    }
                }
                if !ended {
                    eprintln!(
                        "      encoder accepted {sent} frames and produced {result} units in 15 s without end of stream"
                    );
                }
                AMediaCodec_stop(codec);
            }
        }
        AMediaFormat_delete(format);
        AMediaCodec_delete(codec);
        result
    }
}
