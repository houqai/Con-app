#![allow(clippy::missing_safety_doc)]

#[cfg(any(target_os = "linux", windows))]
mod ffmpeg;
#[cfg(any(target_os = "linux", windows))]
pub mod frc;
#[cfg(any(target_os = "linux", windows))]
pub mod image;
#[cfg(windows)]
pub mod nis_coefficients;
#[cfg(any(target_os = "linux", windows))]
pub mod secret;
#[cfg(windows)]
pub mod upscale;
#[cfg(any(target_os = "linux", windows))]
pub mod video;
#[cfg(any(target_os = "linux", windows))]
pub mod window;

#[allow(non_camel_case_types)]
pub struct SDL_Renderer {
    _private: [u8; 0],
}

#[cfg(any(target_os = "linux", windows))]
fn c_copy(bytes: &[u8]) -> *mut u8 {
    unsafe {
        let block = libc::malloc(bytes.len().max(1)) as *mut u8;
        if !block.is_null() {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), block, bytes.len());
        }
        block
    }
}
