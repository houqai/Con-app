#![allow(clippy::missing_safety_doc)]

#[cfg(target_os = "android")]
pub mod bridge;
#[cfg(target_os = "android")]
pub mod media;

#[cfg(target_os = "android")]
fn now_us() -> i64 {
    let mut time = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut time) };
    time.tv_sec * 1_000_000 + time.tv_nsec / 1000
}
