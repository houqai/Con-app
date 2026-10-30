mod common;
use common::console::{b64, NONCE, REGIST, RP_KEY};
use common::{arr, hex, seq};

use base64::Engine as _;
use con_engine::crypto::regist::{pin_keys, unmask_pin_seed};
use con_engine::crypto::rp::{derive_session_keys, RpCipher};
use con_engine::crypto::stream::{
    iv_add, sign_public_key, verify_public_key_signature, DirectionKeys, EcdhKeyPair, PacketTagger,
    StreamKeys,
};
use con_engine::Target;

struct SessionVector {
    target: Target,
    k: &'static str,
    s: &'static str,
    iv0: &'static str,
    iv1: &'static str,
    auth: &'static str,
    auth_b64: &'static str,
    os: &'static str,
    os_b64: &'static str,
    mic5: &'static str,
}

const SESSION_VECTORS: [SessionVector; 3] = [
    SessionVector {
        target: Target::Ps4V8,
        k: "38 87 a8 48 9a a0 b0 c4 52 fb 1f 1e df 2a 53 54",
        s: "74 5f af 46 f2 65 7b ff 77 ca 3b 29 d4 d3 6e 6e",
        iv0: "db 69 1e fa 5f 55 e5 c5 c7 80 d4 fc 7c bc fe 02",
        iv1: "a6 cf 49 ef 2d a1 0c 43 89 07 6b 6b cd 4a a7 70",
        auth: "8e 7b aa 3a ea 35 ae 21 f0 6b f5 93 c5 38 f1 82",
        auth_b64: "jnuqOuo1riHwa/WTxTjxgg==",
        os: "da 29 a8 c5 fe 5e e1 72 f0 29",
        os_b64: "2imoxf5e4XLwKQ==",
        mic5: "14 f6 4d 4b",
    },
    SessionVector {
        target: Target::Ps4V10,
        k: "76 52 38 dc 13 92 3d ec 3b 33 ca 83 eb e3 e6 8c",
        s: "d0 a6 a5 ac 04 4c 4d 53 d5 27 60 a7 64 85 ba 97",
        iv0: "3c ff 1c e1 7b 24 04 b4 15 e3 0b 90 8a 75 0a ee",
        iv1: "5d 6f 45 9c e0 6d 37 ff ef e8 9a 63 d4 a9 90 80",
        auth: "7e c0 bd 28 44 51 7a 23 b6 c1 31 7a 46 39 a6 a1",
        auth_b64: "fsC9KERReiO2wTF6RjmmoQ==",
        os: "64 42 eb 6f e1 a3 ed fa 6c 43",
        os_b64: "ZELrb+Gj7fpsQw==",
        mic5: "45 35 63 d0",
    },
    SessionVector {
        target: Target::Ps5V1,
        k: "e1 6c 0f 8d 28 63 9a 08 98 24 98 c5 1b 81 53 9e",
        s: "2a 1c c5 15 8b ea 26 3f 5b d5 a5 0c 85 cf d9 1c",
        iv0: "98 d7 d8 3a b6 ce a8 90 c5 54 8d 82 25 66 14 01",
        iv1: "ef db 26 d0 bc 8b 55 fc 0c 1b 28 b7 5a 35 66 1b",
        auth: "a7 28 94 59 c5 d1 a2 5e 22 1a 88 3d 0f b6 d5 27",
        auth_b64: "pyiUWcXRol4iGog9D7bVJw==",
        os: "bb de 06 26 0b 44 0b d2 76 00",
        os_b64: "u94GJgtEC9J2AA==",
        mic5: "29 b6 ec 4c",
    },
];

#[test]
fn session_cipher_vectors() {
    for v in &SESSION_VECTORS {
        let (k, s) = derive_session_keys(v.target, &NONCE, &RP_KEY);
        assert_eq!(k.to_vec(), hex(v.k), "{} K", v.target);
        assert_eq!(s.to_vec(), hex(v.s), "{} S", v.target);
        let c = RpCipher::for_session(v.target, &NONCE, &RP_KEY);
        assert_eq!(c.iv(0).to_vec(), hex(v.iv0), "{} IV0", v.target);
        assert_eq!(c.iv(1).to_vec(), hex(v.iv1), "{} IV1", v.target);
        let auth = c.encrypted(0, &REGIST);
        assert_eq!(auth, hex(v.auth));
        assert_eq!(b64(&auth), v.auth_b64);
        let os = c.encrypted(2, b"Win10.0.0\0");
        assert_eq!(os, hex(v.os));
        assert_eq!(b64(&os), v.os_b64);
        assert_eq!(c.encrypted(5, &[0x00, 0x01, 0x01, 0x59]), hex(v.mic5));
        assert_eq!(c.decrypted(5, &hex(v.mic5)), vec![0x00, 0x01, 0x01, 0x59]);
    }
}

#[test]
fn launch_keystream_differs_from_cfb_after_first_block() {
    let c = RpCipher::for_session(Target::Ps5V1, &NONCE, &RP_KEY);
    assert_eq!(
        c.keystream(0, 40),
        hex("c6 19 f6 6b a6 e2 c6 6a 22 1a 88 3d 0f b6 d5 27 10 4f 0f 51 1d 48 16 78 44 38 4c 16 f7 f3 2b ae
             fa d6 46 c1 be 11 80 3e")
    );
    let plain: Vec<u8> = (0u8..40).collect();
    assert_eq!(
        c.encrypted(0, &plain),
        hex("c6 18 f4 68 a2 e7 c0 6d 2a 13 82 36 03 bb db 28 a7 4f ad 1d 8a 25 fa d4 94 2e d8 39 ba 79 60 84
             68 63 c1 88 a4 75 90 fc")
    );
}

#[test]
fn launch_keystream_vectors() {
    let key = seq::<16>(0x10);
    let seed = seq::<16>(0x20);
    let ps5 = RpCipher::new(key, seed, Target::Ps5V1.iv_hmac_key());
    assert_eq!(
        ps5.keystream(0, 48),
        hex("ba 3c dd 46 36 94 c2 33 34 cb 42 50 1a 1a 05 9a 0d 35 b1 c6 c2 a3 fa 01 d6 d2 b2 11 0e 79 f9 4a
             f0 26 44 8c 54 b1 94 d7 8b af 9f b8 7c 3c e2 43")
    );
    let ps4 = RpCipher::new(key, seed, Target::Ps4V10.iv_hmac_key());
    assert_eq!(
        ps4.keystream(0, 48),
        hex("ef 9c 77 1b 71 4f 9f ee bb ac a7 a8 28 be 5f 69 95 f7 cf 6f 16 96 f6 99 9a 36 70 b8 92 e2 2b 16
             7d e2 2e 32 35 26 a4 98 88 29 2b eb de 3c 01 f7")
    );
}

#[test]
fn launch_spec_protection_is_xor_with_keystream() {
    let c = RpCipher::for_session(Target::Ps4V10, &NONCE, &RP_KEY);
    let json = "{\"a\":1,\"bb\":\"some longer text to cover several blocks\"}";
    let encoded = c.encode_launch_spec(json);
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .unwrap();
    assert_eq!(bytes.len(), json.len() + 1);
    let ks = c.keystream(0, bytes.len());
    let plain: Vec<u8> = bytes.iter().zip(&ks).map(|(a, b)| a ^ b).collect();
    assert_eq!(&plain[..json.len()], json.as_bytes());
    assert_eq!(plain[json.len()], 0);
}

#[test]
fn registration_key_check_values() {
    let pin = 12_345_678;
    let s: [u8; 16] = arr("0f 1e 2d 3c 4b 5a 69 78 87 96 a5 b4 c3 d2 e1 f0");
    let ps4 = pin_keys(Target::Ps4V10, pin, &s, 5, 0x11);
    assert_eq!(
        ps4.key.to_vec(),
        hex("7d 68 9c 0e e5 bb 41 0b 7e 16 7d 24 00 fa ff c3")
    );
    assert_eq!(
        ps4.masked_seed.to_vec(),
        hex("40 a8 f2 ef a1 13 0d 51 6c b7 60 be 27 b5 3c 32")
    );
    let ps5 = pin_keys(Target::Ps5V1, pin, &s, 5, 0x11);
    assert_eq!(
        ps5.key.to_vec(),
        hex("67 db d4 2a 8f f3 f3 80 26 73 f9 76 f9 22 43 4b")
    );
    assert_eq!(
        ps5.masked_seed.to_vec(),
        hex("c2 29 f8 7b 0a 1b 14 45 e7 76 c2 e2 3a df dc 2a")
    );
    assert_eq!(unmask_pin_seed(Target::Ps4V10, &ps4.masked_seed, 0x11), s);
    assert_eq!(unmask_pin_seed(Target::Ps5V1, &ps5.masked_seed, 0x11), s);
}

#[test]
fn registration_vectors() {
    let a = seq::<16>(0);
    let pin = 12_345_678;
    let old = pin_keys(Target::Ps4V9, pin, &a, 1, 8);
    assert_eq!(
        old.key.to_vec(),
        hex("3f a0 a5 f8 dc bb 3e cc 50 ba ed ef 97 34 c7 c9")
    );
    assert_eq!(
        old.masked_seed.to_vec(),
        hex("36 3b 4b ed 0a 6a df 52 2b d9 ca af 47 e5 17 d3")
    );
    assert_eq!(unmask_pin_seed(Target::Ps4V9, &old.masked_seed, 8), a);

    let p4 = pin_keys(Target::Ps4V10, pin, &a, 1, 8);
    assert_eq!(
        p4.key.to_vec(),
        hex("ce bc b6 40 08 07 76 04 7b 85 e8 5b f3 50 f5 2d")
    );
    assert_eq!(
        p4.masked_seed.to_vec(),
        hex("88 14 27 27 c2 e3 73 71 df 5e d5 a5 9c f7 7e 8f")
    );

    let p5 = pin_keys(Target::Ps5V1, pin, &a, 1, 8);
    assert_eq!(
        p5.key.to_vec(),
        hex("d8 60 e1 46 bd b0 bd 94 b4 60 07 0b b1 f3 86 6d")
    );
    assert_eq!(
        p5.masked_seed.to_vec(),
        hex("7b 0a 38 8c fa d1 da 43 45 26 0d 8a ec 78 65 6c")
    );

    let iv = |t: Target, key: [u8; 16]| RpCipher::new(key, a, t.iv_hmac_key()).iv(0);
    assert_eq!(
        iv(Target::Ps4V9, old.key).to_vec(),
        hex("4a 01 3f 3a 4e c9 2d d8 df 9d 7a 17 72 42 90 07")
    );
    assert_eq!(
        iv(Target::Ps4V10, p4.key).to_vec(),
        hex("87 5c c8 f1 9c d5 f0 37 17 ad 6a 2e 2d 02 cd fe")
    );
    assert_eq!(
        iv(Target::Ps5V1, p5.key).to_vec(),
        hex("8a d8 7b 1f 1a 32 e4 5d 44 ff 2e af 1e 6e 3c cb")
    );
}

#[test]
fn stream_key_derivation_vectors() {
    let z = seq::<32>(0);
    let h = seq::<16>(0xa0);
    let k = StreamKeys::derive(&z, &h);
    assert_eq!(
        k.local.key().to_vec(),
        hex("84 9f a4 7d 53 fe b0 d7 dc a3 97 41 34 ce bc 7b")
    );
    assert_eq!(
        k.local.base_iv().to_vec(),
        hex("2b 86 f7 63 6e 38 3c 2e ba af 40 fb 13 62 21 95")
    );
    assert_eq!(
        k.remote.key().to_vec(),
        hex("51 8b e4 81 0f c1 43 41 a3 ba ea 42 7a c0 87 e7")
    );
    assert_eq!(
        k.remote.base_iv().to_vec(),
        hex("6b af e1 4f 25 c3 7d 15 25 60 17 73 35 70 73 85")
    );
}

#[test]
fn public_key_signature_vector() {
    let h = seq::<16>(0xa0);
    let mut pk = vec![0x04];
    pk.extend(0u8..0x40);
    let sig = sign_public_key(&h, &pk);
    assert_eq!(
        sig.to_vec(),
        hex("5c2b92902c04dadb12d0ac7f1032025d990ccd1d219b77beb1616ccde7a29bd4")
    );
    assert!(verify_public_key_signature(&h, &pk, &sig));
    let mut bad = sig;
    bad[0] ^= 1;
    assert!(!verify_public_key_signature(&h, &pk, &bad));
    assert!(!verify_public_key_signature(&h, &pk, &sig[..31]));
}

#[test]
fn transport_gmac_and_keystream_vectors() {
    let z = seq::<32>(0);
    let h = seq::<16>(0xa0);
    let k = StreamKeys::derive(&z, &h);
    let dirs: [(&DirectionKeys, [&str; 6]); 2] = [
        (
            &k.local,
            [
                "3a2897e470211327092b4be9f81d9ec2",
                "89e20495c1b6017b22175afb75ae358c",
                "de66140841508cc954d360320956ba2a 65139d0d4c9f6728fb8f3fe26077619f",
                "3981c2e1047908f9fd42fed737cfedef",
                "7926cef1",
                "3d05f159",
            ],
        ),
        (
            &k.remote,
            [
                "80a5ce882d445ca19b74e989e951c2d9",
                "d91c6d4cd7f467fa9899ce4d4b078065",
                "cb8d181a9ef7e8b127248cb83e813585 e056cb1dd9436bf70cce9478bf46e771",
                "82d521485715daf525798fbf432d3bda",
                "16f7d264",
                "a2e7ce3e",
            ],
        ),
    ];
    let packet = hex("00 11223344 00000000 00000000 00 01 000f 55667788 0001 0000 00 0803");
    assert_eq!(packet.len(), 28);
    for (d, v) in dirs {
        assert_eq!(d.gmac_key(0).to_vec(), hex(v[0]));
        assert_eq!(d.gmac_key(1).to_vec(), hex(v[1]));
        assert_eq!(d.keystream(0, 32), hex(v[2]));
        assert_eq!(d.keystream(0x10000, 16), hex(v[3]));
        let mut tagger = PacketTagger::new(d.clone());
        assert_eq!(tagger.tag(0x40, &packet).to_vec(), hex(v[4]));
        assert_eq!(tagger.tag(45001, &packet).to_vec(), hex(v[5]));
    }
}

#[test]
fn keystream_is_position_consistent() {
    let k = DirectionKeys::from_parts(seq(1), seq(2));
    let whole = k.keystream(5, 100);
    assert_eq!(k.keystream(37, 20), whole[32..52].to_vec());
    let mut data = vec![0xaau8; 50];
    k.apply_keystream(13, &mut data);
    k.apply_keystream(13, &mut data);
    assert_eq!(data, vec![0xaau8; 50]);
    assert_eq!(DirectionKeys::gmac_key_index(0), 0);
    assert_eq!(DirectionKeys::gmac_key_index(45000), 0);
    assert_eq!(DirectionKeys::gmac_key_index(45001), 1);
}

#[test]
fn iv_addition_is_little_endian_with_wrap() {
    let mut iv = [0u8; 16];
    iv[0] = 0xff;
    let r = iv_add(&iv, 1);
    assert_eq!(r[0], 0);
    assert_eq!(r[1], 1);
    assert_eq!(iv_add(&[0xff; 16], 1), [0u8; 16]);
}

#[test]
fn ecdh_both_sides_agree() {
    let client = EcdhKeyPair::generate();
    let console = EcdhKeyPair::generate();
    let cp = client.public_key();
    assert_eq!(cp[0], 0x04);
    let z1 = client.shared_secret(&console.public_key()).unwrap();
    let z2 = console.shared_secret(&cp).unwrap();
    assert_eq!(z1, z2);
    let hk = seq::<16>(0xa0);
    let a = StreamKeys::from_exchange(&client, &console.public_key(), &hk).unwrap();
    let b = StreamKeys::derive(&z2, &hk);
    assert_eq!(a.local.key(), b.local.key());
    assert_eq!(a.remote.base_iv(), b.remote.base_iv());
    assert!(client.shared_secret(&[0x04; 65]).is_err());
    assert!(client.shared_secret(&[]).is_err());
}

#[test]
fn ecdh_known_scalar_gives_generator() {
    let mut one = [0u8; 32];
    one[31] = 1;
    let kp = EcdhKeyPair::from_private_bytes(&one).unwrap();
    let pk = kp.public_key();
    assert_eq!(
        pk[1..33].to_vec(),
        hex("79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")
    );
}
