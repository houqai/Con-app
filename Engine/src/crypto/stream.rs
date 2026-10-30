use aes::cipher::{BlockEncrypt, KeyInit};
use aes::Aes128;
use aes_gcm::aead::consts::U16;
use aes_gcm::aead::AeadInPlace;
use aes_gcm::AesGcm;
use k256::elliptic_curve::sec1::ToEncodedPoint;
use sha2::{Digest, Sha256};

use super::hmac_sha256;

pub const CLIENT_TO_CONSOLE: u8 = 2;
pub const CONSOLE_TO_CLIENT: u8 = 3;

pub const GMAC_KEY_SPAN: u64 = 45_000;
pub const GMAC_IV_STEP: u128 = 44_910;

type Aes128Gcm16 = AesGcm<Aes128, U16>;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum KeyExchangeError {
    #[error("the peer public key is not a valid curve point")]
    InvalidPeerKey,
}

pub fn iv_add(iv: &[u8; 16], n: u128) -> [u8; 16] {
    u128::from_le_bytes(*iv).wrapping_add(n).to_le_bytes()
}

pub struct EcdhKeyPair {
    secret: k256::SecretKey,
}

impl std::fmt::Debug for EcdhKeyPair {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("EcdhKeyPair { .. }")
    }
}

impl EcdhKeyPair {
    pub fn generate() -> Self {
        Self {
            secret: k256::SecretKey::random(&mut rand::rngs::OsRng),
        }
    }

    pub fn from_private_bytes(bytes: &[u8; 32]) -> Option<Self> {
        k256::SecretKey::from_slice(bytes)
            .ok()
            .map(|secret| Self { secret })
    }

    pub fn public_key(&self) -> [u8; 65] {
        let point = self.secret.public_key().to_encoded_point(false);
        let mut out = [0u8; 65];
        out.copy_from_slice(point.as_bytes());
        out
    }

    pub fn shared_secret(&self, peer_public: &[u8]) -> Result<[u8; 32], KeyExchangeError> {
        let peer = k256::PublicKey::from_sec1_bytes(peer_public)
            .map_err(|_| KeyExchangeError::InvalidPeerKey)?;
        let shared = k256::ecdh::diffie_hellman(self.secret.to_nonzero_scalar(), peer.as_affine());
        let mut out = [0u8; 32];
        out.copy_from_slice(shared.raw_secret_bytes());
        Ok(out)
    }
}

pub fn sign_public_key(handshake_key: &[u8; 16], public_key: &[u8]) -> [u8; 32] {
    hmac_sha256(handshake_key, &[public_key])
}

pub fn verify_public_key_signature(
    handshake_key: &[u8; 16],
    public_key: &[u8],
    signature: &[u8],
) -> bool {
    let expected = sign_public_key(handshake_key, public_key);
    if signature.len() != expected.len() {
        return false;
    }
    expected
        .iter()
        .zip(signature)
        .fold(0u8, |acc, (a, b)| acc | (a ^ b))
        == 0
}

#[derive(Clone)]
pub struct DirectionKeys {
    key: [u8; 16],
    base_iv: [u8; 16],
    cipher: Aes128,
    gmac_base: [u8; 16],
}

impl std::fmt::Debug for DirectionKeys {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("DirectionKeys { .. }")
    }
}

fn fold(d: &[u8]) -> [u8; 16] {
    let mut out = [0u8; 16];
    for i in 0..16 {
        out[i] = d[i] ^ d[16 + i];
    }
    out
}

impl DirectionKeys {
    pub fn derive(shared_secret: &[u8; 32], handshake_key: &[u8; 16], index: u8) -> Self {
        let mac = hmac_sha256(
            shared_secret,
            &[&[0x01, index, 0x00], handshake_key, &[0x01, 0x00]],
        );
        let mut key = [0u8; 16];
        let mut base_iv = [0u8; 16];
        key.copy_from_slice(&mac[..16]);
        base_iv.copy_from_slice(&mac[16..]);
        Self::from_parts(key, base_iv)
    }

    pub fn from_parts(key: [u8; 16], base_iv: [u8; 16]) -> Self {
        let mut h = Sha256::new();
        h.update(key);
        h.update(base_iv);
        let gmac_base = fold(&h.finalize());
        Self {
            key,
            base_iv,
            cipher: Aes128::new(&key.into()),
            gmac_base,
        }
    }

    pub fn key(&self) -> &[u8; 16] {
        &self.key
    }

    pub fn base_iv(&self) -> &[u8; 16] {
        &self.base_iv
    }

    pub fn keystream_block(&self, block: u64) -> [u8; 16] {
        let mut b = iv_add(&self.base_iv, block as u128).into();
        self.cipher.encrypt_block(&mut b);
        b.into()
    }

    pub fn apply_keystream(&self, position: u64, data: &mut [u8]) {
        let mut pos = position;
        let mut done = 0;
        while done < data.len() {
            let block = self.keystream_block(pos / 16);
            let offset = (pos % 16) as usize;
            let n = (16 - offset).min(data.len() - done);
            for i in 0..n {
                data[done + i] ^= block[offset + i];
            }
            done += n;
            pos += n as u64;
        }
    }

    pub fn keystream(&self, position: u64, len: usize) -> Vec<u8> {
        let mut out = vec![0u8; len];
        self.apply_keystream(position, &mut out);
        out
    }

    pub fn gmac_key(&self, n: u64) -> [u8; 16] {
        if n == 0 {
            return self.gmac_base;
        }
        let iv = iv_add(&self.base_iv, (n as u128).wrapping_mul(GMAC_IV_STEP));
        let mut h = Sha256::new();
        h.update(self.gmac_base);
        h.update(iv);
        fold(&h.finalize())
    }

    pub fn gmac_key_index(key_position: u64) -> u64 {
        if key_position == 0 {
            0
        } else {
            (key_position - 1) / GMAC_KEY_SPAN
        }
    }
}

#[derive(Clone, Debug)]
pub struct StreamKeys {
    pub local: DirectionKeys,
    pub remote: DirectionKeys,
}

impl StreamKeys {
    pub fn derive(shared_secret: &[u8; 32], handshake_key: &[u8; 16]) -> Self {
        Self {
            local: DirectionKeys::derive(shared_secret, handshake_key, CLIENT_TO_CONSOLE),
            remote: DirectionKeys::derive(shared_secret, handshake_key, CONSOLE_TO_CLIENT),
        }
    }

    pub fn from_exchange(
        own: &EcdhKeyPair,
        console_public: &[u8],
        handshake_key: &[u8; 16],
    ) -> Result<Self, KeyExchangeError> {
        let z = own.shared_secret(console_public)?;
        Ok(Self::derive(&z, handshake_key))
    }
}

pub struct PacketTagger {
    keys: DirectionKeys,
    cached: Option<(u64, Aes128Gcm16)>,
}

impl std::fmt::Debug for PacketTagger {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("PacketTagger { .. }")
    }
}

impl PacketTagger {
    pub fn new(keys: DirectionKeys) -> Self {
        Self { keys, cached: None }
    }

    pub fn keys(&self) -> &DirectionKeys {
        &self.keys
    }

    pub fn tag(&mut self, key_position: u64, packet: &[u8]) -> [u8; 4] {
        let index = DirectionKeys::gmac_key_index(key_position);
        let aead = match &mut self.cached {
            Some((i, aead)) if *i == index => aead,
            slot => {
                let gkey = self.keys.gmac_key(index);
                &mut slot.insert((index, Aes128Gcm16::new(&gkey.into()))).1
            }
        };
        let nonce = iv_add(&self.keys.base_iv, (key_position / 16) as u128);
        let tag = aead
            .encrypt_in_place_detached(&nonce.into(), packet, &mut [])
            .expect("GCM over additional data only cannot fail");
        let mut out = [0u8; 4];
        out.copy_from_slice(&tag[..4]);
        out
    }
}
