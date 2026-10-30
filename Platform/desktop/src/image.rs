use crate::ffmpeg::*;
use std::ptr::{null, null_mut};

pub fn kind(bytes: &[u8]) -> Option<AVCodecID> {
    let length = bytes.len();
    if length > 3 && bytes.starts_with(&[0xFF, 0xD8]) {
        Some(AV_CODEC_ID_MJPEG)
    } else if length > 8 && bytes.starts_with(b"\x89PNG") {
        Some(AV_CODEC_ID_PNG)
    } else if length > 12 && bytes.starts_with(b"RIFF") && &bytes[8..12] == b"WEBP" {
        Some(AV_CODEC_ID_WEBP)
    } else {
        None
    }
}

pub fn fitted(width: i32, height: i32, max_side: i32) -> (i32, i32) {
    let (mut w, mut h) = (width, height);
    let longest = w.max(h);
    if max_side > 0 && longest > max_side {
        w = (i64::from(w) * i64::from(max_side) / i64::from(longest)) as i32;
        h = (i64::from(h) * i64::from(max_side) / i64::from(longest)) as i32;
    }
    (w.max(1), h.max(1))
}

pub fn premultiply(pixels: &mut [u8]) {
    for pixel in pixels.as_chunks_mut::<4>().0 {
        let alpha = u32::from(pixel[3]);
        if alpha != 255 {
            for channel in &mut pixel[..3] {
                *channel = (u32::from(*channel) * alpha / 255) as u8;
            }
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn con_image_decode(
    bytes: *const u8,
    length: i32,
    max_side: i32,
    width: *mut i32,
    height: *mut i32,
    stride: *mut i32,
) -> *mut u8 {
    if width.is_null() || height.is_null() || stride.is_null() {
        return null_mut();
    }
    unsafe {
        *width = 0;
        *height = 0;
        *stride = 0;
    }
    if bytes.is_null() || length <= 0 {
        return null_mut();
    }
    let picture = unsafe { std::slice::from_raw_parts(bytes, length as usize) };
    let Some(kind) = kind(picture) else {
        return null_mut();
    };
    unsafe {
        let codec = avcodec_find_decoder(kind);
        if codec.is_null() {
            return null_mut();
        }
        let mut context = avcodec_alloc_context3(codec);
        let mut packet = av_packet_alloc();
        let mut frame = av_frame_alloc();
        let mut result = null_mut();
        if !context.is_null()
            && !packet.is_null()
            && !frame.is_null()
            && avcodec_open2(context, codec, null_mut()) >= 0
        {
            (*packet).data = bytes as *mut u8;
            (*packet).size = length;
            if avcodec_send_packet(context, packet) >= 0 {
                avcodec_send_packet(context, null());
                if avcodec_receive_frame(context, frame) >= 0
                    && (*frame).width > 0
                    && (*frame).height > 0
                {
                    let (w, h) = fitted((*frame).width, (*frame).height, max_side);
                    result = scaled(frame, w, h);
                    if !result.is_null() {
                        *width = w;
                        *height = h;
                        *stride = w * 4;
                    }
                }
            }
        }
        av_frame_free(&mut frame);
        av_packet_free(&mut packet);
        avcodec_free_context(&mut context);
        result
    }
}

unsafe fn scaled(frame: *const AVFrame, w: i32, h: i32) -> *mut u8 {
    unsafe {
        let scale = sws_getContext(
            (*frame).width,
            (*frame).height,
            (*frame).format as AVPixelFormat,
            w,
            h,
            AV_PIX_FMT_BGRA,
            SWS_AREA as _,
            null_mut(),
            null_mut(),
            null(),
        );
        if scale.is_null() {
            return null_mut();
        }
        let row_bytes = w * 4;
        let size = row_bytes as usize * h as usize;
        let result = libc::malloc(size) as *mut u8;
        if !result.is_null() {
            let planes: [*mut u8; 4] = [result, null_mut(), null_mut(), null_mut()];
            let pitches: [i32; 4] = [row_bytes, 0, 0, 0];
            sws_scale(
                scale,
                (*frame).data.as_ptr() as *const *const u8,
                (*frame).linesize.as_ptr(),
                0,
                (*frame).height,
                planes.as_ptr(),
                pitches.as_ptr(),
            );
            premultiply(std::slice::from_raw_parts_mut(result, size));
        }
        sws_freeContext(scale);
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kinds_are_told_by_their_first_bytes() {
        assert_eq!(kind(&[0xFF, 0xD8, 0xFF, 0xE0]), Some(AV_CODEC_ID_MJPEG));
        assert_eq!(kind(b"\x89PNG\r\n\x1a\n\0"), Some(AV_CODEC_ID_PNG));
        assert_eq!(kind(b"RIFF\0\0\0\0WEBPVP8 "), Some(AV_CODEC_ID_WEBP));
        assert_eq!(kind(b"GIF89a\0\0\0\0\0\0\0"), None);
        assert_eq!(kind(&[0xFF, 0xD8, 0xFF]), None);
    }

    #[test]
    fn the_longer_side_is_made_no_larger() {
        assert_eq!(fitted(1920, 1080, 256), (256, 144));
        assert_eq!(fitted(1080, 1920, 256), (144, 256));
        assert_eq!(fitted(100, 50, 256), (100, 50));
        assert_eq!(fitted(100, 50, 0), (100, 50));
        assert_eq!(fitted(4000, 1, 100), (100, 1));
    }

    #[test]
    fn colour_is_multiplied_by_its_alpha() {
        let mut pixels = [200, 100, 50, 255, 200, 100, 50, 128, 255, 255, 255, 0];
        premultiply(&mut pixels);
        assert_eq!(pixels, [200, 100, 50, 255, 100, 50, 25, 128, 0, 0, 0, 0]);
    }
}
