#![allow(clippy::missing_safety_doc)]

#[cfg(target_os = "android")]
mod check;
#[cfg(target_os = "android")]
pub use check::*;

#[allow(non_camel_case_types)]
pub type con_check_unit = Option<
    unsafe extern "C" fn(
        unit: *const u8,
        length: i32,
        parameters: i32,
        context: *mut std::ffi::c_void,
    ),
>;
