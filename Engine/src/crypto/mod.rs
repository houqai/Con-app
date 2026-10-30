pub mod regist;
pub mod rp;
pub mod stream;
pub(crate) mod tables;

use aes::cipher::{AsyncStreamCipher, KeyIvInit};
use hmac::{Hmac, Mac};
use rand::RngCore;
use sha2::Sha256;

type HmacSha256 = Hmac<Sha256>;

pub fn hmac_sha256(key: &[u8], parts: &[&[u8]]) -> [u8; 32] {
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC accepts any key length");
    for p in parts {
        mac.update(p);
    }
    mac.finalize().into_bytes().into()
}

pub fn aes128_cfb_encrypt(key: &[u8; 16], iv: &[u8; 16], data: &mut [u8]) {
    cfb_mode::Encryptor::<aes::Aes128>::new(key.into(), iv.into()).encrypt(data);
}

pub fn aes128_cfb_decrypt(key: &[u8; 16], iv: &[u8; 16], data: &mut [u8]) {
    cfb_mode::Decryptor::<aes::Aes128>::new(key.into(), iv.into()).decrypt(data);
}

pub fn random_bytes<const N: usize>() -> [u8; N] {
    let mut out = [0u8; N];
    rand::rngs::OsRng.fill_bytes(&mut out);
    out
}

pub(crate) fn hex_decode(text: &str) -> Option<Vec<u8>> {
    let t = text.as_bytes();
    if !t.len().is_multiple_of(2) {
        return None;
    }
    t.chunks(2)
        .map(|p| {
            let hi = (p[0] as char).to_digit(16)?;
            let lo = (p[1] as char).to_digit(16)?;
            Some((hi * 16 + lo) as u8)
        })
        .collect()
}

pub(crate) fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_round_trip() {
        assert_eq!(hex_decode("00aBff").unwrap(), vec![0x00, 0xab, 0xff]);
        assert_eq!(hex_encode(&[0x00, 0xab, 0xff]), "00abff");
        assert!(hex_decode("abc").is_none());
        assert!(hex_decode("zz").is_none());
    }

    #[test]
    fn cfb_round_trip_partial_block() {
        let key = [7u8; 16];
        let iv = [9u8; 16];
        let plain: Vec<u8> = (0..37).collect();
        let mut buf = plain.clone();
        aes128_cfb_encrypt(&key, &iv, &mut buf);
        assert_ne!(buf, plain);
        aes128_cfb_decrypt(&key, &iv, &mut buf);
        assert_eq!(buf, plain);
    }
}
