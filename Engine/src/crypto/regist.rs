use super::rp::{RpCipher, OLD_P2};
use super::tables::{R0_PS4, R0_PS5, R1_PS4, R1_PS5};
use crate::Target;

const OLD_KEY: [u8; 16] = [
    0x3f, 0x1c, 0xc4, 0xb6, 0xdc, 0xbb, 0x3e, 0xcc, 0x50, 0xba, 0xed, 0xef, 0x97, 0x34, 0xc7, 0xc9,
];

#[derive(Clone, PartialEq, Eq)]
pub struct RegistKeys {
    pub key: [u8; 16],
    pub masked_seed: [u8; 16],
}

impl std::fmt::Debug for RegistKeys {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("RegistKeys { .. }")
    }
}

fn tables(target: Target) -> (&'static [[u8; 32]; 16], &'static [[u8; 32]; 16]) {
    match target {
        Target::Ps5V1 => (&R0_PS5, &R1_PS5),
        _ => (&R0_PS4, &R1_PS4),
    }
}

fn seed_offset(target: Target) -> u8 {
    if target == Target::Ps5V1 {
        0xd3
    } else {
        0x29
    }
}

pub fn pin_keys(target: Target, pin: u32, seed: &[u8; 16], c0: u8, c1: u8) -> RegistKeys {
    let p = pin.to_be_bytes();
    let mut key = [0u8; 16];
    let mut masked = [0u8; 16];
    if target.is_old_generation() {
        key = OLD_KEY;
        for i in 0..4 {
            key[i] ^= p[i];
        }
        for i in 0..16 {
            masked[i] = seed[i].wrapping_sub(i as u8).wrapping_sub(0x29) ^ OLD_P2[i];
        }
    } else {
        let (t0, t1) = tables(target);
        let (c0, c1) = ((c0 & 0x1f) as usize, (c1 & 0x1f) as usize);
        let k = seed_offset(target);
        for i in 0..16 {
            key[i] = t0[i][c0];
            masked[i] = (seed[i] ^ t1[i][c1]).wrapping_add(k).wrapping_add(i as u8);
        }
        for i in 0..4 {
            key[12 + i] ^= p[i];
        }
    }
    RegistKeys {
        key,
        masked_seed: masked,
    }
}

pub fn unmask_pin_seed(target: Target, masked: &[u8; 16], c1: u8) -> [u8; 16] {
    let mut seed = [0u8; 16];
    if target.is_old_generation() {
        for i in 0..16 {
            seed[i] = (masked[i] ^ OLD_P2[i])
                .wrapping_add(i as u8)
                .wrapping_add(0x29);
        }
    } else {
        let (_, t1) = tables(target);
        let c1 = (c1 & 0x1f) as usize;
        let k = seed_offset(target);
        for i in 0..16 {
            seed[i] = masked[i].wrapping_sub(k).wrapping_sub(i as u8) ^ t1[i][c1];
        }
    }
    seed
}

pub fn cipher(target: Target, keys: &RegistKeys, seed: &[u8; 16]) -> RpCipher {
    RpCipher::new(keys.key, *seed, target.iv_hmac_key())
}
