#![allow(dead_code)]

pub fn hex(text: &str) -> Vec<u8> {
    let t: String = text.chars().filter(|c| c.is_ascii_hexdigit()).collect();
    assert!(t.len().is_multiple_of(2), "odd hex length");
    (0..t.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&t[i..i + 2], 16).unwrap())
        .collect()
}

pub fn arr<const N: usize>(text: &str) -> [u8; N] {
    hex(text).try_into().expect("wrong length")
}

pub fn seq<const N: usize>(start: u8) -> [u8; N] {
    let mut a = [0u8; N];
    for (i, b) in a.iter_mut().enumerate() {
        *b = start.wrapping_add(i as u8);
    }
    a
}

pub mod console;
pub mod media;
pub mod senkusha;
pub mod takion;
