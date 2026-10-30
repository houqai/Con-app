use base64::Engine as _;

use super::tables::{SA4, SA5, SB4, SB5};
use super::{aes128_cfb_decrypt, aes128_cfb_encrypt, hmac_sha256};
use crate::Target;

const OLD_P1: [u8; 16] = [
    0x01, 0x49, 0x87, 0x9b, 0x65, 0x39, 0x8b, 0x39, 0x4b, 0x3a, 0x8d, 0x48, 0xc3, 0x0a, 0xef, 0x51,
];
pub(crate) const OLD_P2: [u8; 16] = [
    0xe1, 0xec, 0x9c, 0x3a, 0xdd, 0xbd, 0x08, 0x85, 0xfc, 0x0e, 0x1d, 0x78, 0x90, 0x32, 0xc0, 0x04,
];

#[derive(Clone, PartialEq, Eq)]
pub struct RpCipher {
    key: [u8; 16],
    seed: [u8; 16],
    hmac_key: [u8; 16],
}

impl std::fmt::Debug for RpCipher {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("RpCipher { .. }")
    }
}

impl RpCipher {
    pub fn new(key: [u8; 16], seed: [u8; 16], hmac_key: [u8; 16]) -> Self {
        Self {
            key,
            seed,
            hmac_key,
        }
    }

    pub fn for_session(target: Target, nonce: &[u8; 16], rp_key: &[u8; 16]) -> Self {
        let (key, seed) = derive_session_keys(target, nonce, rp_key);
        Self::new(key, seed, target.iv_hmac_key())
    }

    pub fn iv(&self, counter: u64) -> [u8; 16] {
        let mac = hmac_sha256(&self.hmac_key, &[&self.seed, &counter.to_be_bytes()]);
        let mut iv = [0u8; 16];
        iv.copy_from_slice(&mac[..16]);
        iv
    }

    pub fn encrypt(&self, counter: u64, data: &mut [u8]) {
        aes128_cfb_encrypt(&self.key, &self.iv(counter), data);
    }

    pub fn decrypt(&self, counter: u64, data: &mut [u8]) {
        aes128_cfb_decrypt(&self.key, &self.iv(counter), data);
    }

    pub fn encrypted(&self, counter: u64, data: &[u8]) -> Vec<u8> {
        let mut out = data.to_vec();
        self.encrypt(counter, &mut out);
        out
    }

    pub fn decrypted(&self, counter: u64, data: &[u8]) -> Vec<u8> {
        let mut out = data.to_vec();
        self.decrypt(counter, &mut out);
        out
    }

    pub fn keystream(&self, counter: u64, len: usize) -> Vec<u8> {
        let mut out = vec![0u8; len];
        self.encrypt(counter, &mut out);
        out
    }

    pub fn encode_launch_spec(&self, json: &str) -> String {
        let mut bytes = json.as_bytes().to_vec();
        bytes.push(0);
        let ks = self.keystream(0, bytes.len());
        for (b, k) in bytes.iter_mut().zip(ks) {
            *b ^= k;
        }
        base64::engine::general_purpose::STANDARD.encode(bytes)
    }
}

pub fn derive_session_keys(
    target: Target,
    nonce: &[u8; 16],
    rp_key: &[u8; 16],
) -> ([u8; 16], [u8; 16]) {
    let mut key = [0u8; 16];
    let mut seed = [0u8; 16];
    match target {
        Target::Ps4V8 | Target::Ps4V9 => {
            for i in 0..16 {
                let iu = i as u8;
                seed[i] = nonce[i].wrapping_sub(iu).wrapping_sub(0x27) ^ OLD_P1[i];
                key[i] = rp_key[i].wrapping_sub(iu).wrapping_add(0x34) ^ OLD_P2[i] ^ nonce[i];
            }
        }
        Target::Ps4V10 => {
            let a = &SA4[(nonce[0] >> 3) as usize];
            let b = &SB4[(nonce[7] >> 3) as usize];
            for i in 0..16 {
                let iu = i as u8;
                seed[i] = nonce[i].wrapping_add(0x36).wrapping_add(iu) ^ a[i];
                key[i] = (b[i] ^ rp_key[i]).wrapping_add(0x21).wrapping_add(iu) ^ nonce[i];
            }
        }
        Target::Ps5V1 => {
            let a = &SA5[(nonce[0] >> 3) as usize];
            let b = &SB5[(nonce[7] >> 3) as usize];
            for i in 0..16 {
                let iu = i as u8;
                seed[i] = nonce[i].wrapping_sub(0x2d).wrapping_sub(iu) ^ a[i];
                key[i] = rp_key[i].wrapping_add(0x18).wrapping_add(iu) ^ nonce[i] ^ b[i];
            }
        }
    }
    (key, seed)
}
