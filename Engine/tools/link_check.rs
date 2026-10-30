#![allow(dead_code)]

mod abi {
    include!("../src/ffi/abi.rs");
    pub enum ConDiscovery {}
    pub enum ConRegistration {}
    pub enum ConSession {}
    pub enum ConCloudProbe {}
}

#[path = "../tests/capi/mod.rs"]
mod capi;

#[cfg(own_opus)]
use std::ffi::{c_char, c_int, CStr};

#[cfg(own_opus)]
#[no_mangle]
pub extern "C" fn opus_get_version_string() -> *const c_char {
    c"own".as_ptr()
}

#[cfg(own_opus)]
#[no_mangle]
pub extern "C" fn opus_decoder_get_size(channels: c_int) -> c_int {
    channels * 1000
}

#[cfg(not(own_opus))]
fn own_opus() -> bool {
    false
}

#[cfg(own_opus)]
fn own_opus() -> bool {
    let version = unsafe { CStr::from_ptr(opus_get_version_string()) };
    version.to_bytes() == b"own" && opus_decoder_get_size(2) == 2000
}

fn main() {
    let functions = capi::all_functions();
    let missing: Vec<_> = functions.iter().filter(|(_, a)| *a == 0).collect();
    println!("{} functions linked", functions.len());
    let mut ok = missing.is_empty();
    for what in std::env::args().skip(1) {
        match what.as_str() {
            "selftest" => {
                let checks = capi::selftest();
                for l in &checks.lines {
                    println!("{l}");
                }
                for f in &checks.failures {
                    println!("{f}");
                }
                ok &= checks.failures.is_empty();
            }
            "opus" => {
                let own = own_opus();
                println!(
                    "program's own opus_* symbols take precedence: {}",
                    if own { "yes" } else { "no" }
                );
                ok &= own;
            }
            other => {
                eprintln!("usage: link_check [selftest] [opus] (not {other:?})");
                ok = false;
            }
        }
    }
    std::process::exit(if ok { 0 } else { 1 });
}
