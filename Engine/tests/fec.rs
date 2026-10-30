use con_engine::fec::{coding_matrix, encode, gf_mul, recover, FecError};
use rand::rngs::StdRng;
use rand::seq::SliceRandom;
use rand::{Rng, SeedableRng};

fn random_units(rng: &mut StdRng, k: usize, len: usize) -> Vec<Vec<u8>> {
    (0..k)
        .map(|_| (0..len).map(|_| rng.gen()).collect())
        .collect()
}

fn frame(sources: &[Vec<u8>], parity: &[Vec<u8>]) -> Vec<Option<Vec<u8>>> {
    sources.iter().chain(parity).cloned().map(Some).collect()
}

#[test]
fn parity_equals_matrix_product() {
    let mut rng = StdRng::seed_from_u64(1);
    let sources = random_units(&mut rng, 6, 64);
    let parity = encode(&sources, 3).unwrap();
    let c = coding_matrix(6, 3).unwrap();
    for (i, p) in parity.iter().enumerate() {
        for b in 0..64 {
            let expect = (0..6).fold(0u8, |acc, j| acc ^ gf_mul(c[i][j], sources[j][b]));
            assert_eq!(p[b], expect);
        }
    }
}

#[test]
fn single_parity_is_not_plain_xor() {
    let sources = vec![vec![1u8], vec![1u8]];
    let parity = encode(&sources, 1).unwrap();
    assert_eq!(parity[0], vec![0x01 ^ 0x8e]);
}

#[test]
fn exhaustive_patterns_small_frames() {
    let mut rng = StdRng::seed_from_u64(2);
    for k in 1..=6 {
        for m in 1..=4 {
            let n = k + m;
            let sources = random_units(&mut rng, k, 33);
            let parity = encode(&sources, m).unwrap();
            for mask in 0u32..(1 << n) {
                let lost = mask.count_ones() as usize;
                let mut units = frame(&sources, &parity);
                for (i, u) in units.iter_mut().enumerate() {
                    if mask & (1 << i) != 0 {
                        *u = None;
                    }
                }
                let source_lost = (0..k).filter(|&i| mask & (1 << i) != 0).count();
                let r = recover(&mut units, k);
                if lost <= m {
                    assert_eq!(r, Ok(source_lost), "k={k} m={m} mask={mask:b}");
                    for j in 0..k {
                        assert_eq!(units[j].as_ref().unwrap(), &sources[j]);
                    }
                } else if source_lost > 0 {
                    assert!(
                        matches!(r, Err(FecError::NotEnoughUnits { .. })),
                        "k={k} m={m} mask={mask:b}"
                    );
                }
            }
        }
    }
}

#[test]
fn randomized_patterns_fixed_seed() {
    let mut rng = StdRng::seed_from_u64(0x5eed);
    for _ in 0..300 {
        let k = rng.gen_range(1..=60);
        let m = rng.gen_range(1..=20);
        let len = rng.gen_range(1..=1400);
        let sources = random_units(&mut rng, k, len);
        let parity = encode(&sources, m).unwrap();
        let mut idx: Vec<usize> = (0..k + m).collect();
        idx.shuffle(&mut rng);
        let lose = rng.gen_range(0..=m);
        let mut units = frame(&sources, &parity);
        for &i in &idx[..lose] {
            units[i] = None;
        }
        recover(&mut units, k).unwrap();
        for j in 0..k {
            assert_eq!(units[j].as_ref().unwrap(), &sources[j], "k={k} m={m}");
        }
    }
}

#[test]
fn largest_code_recovers_worst_case() {
    let mut rng = StdRng::seed_from_u64(3);
    let (k, m) = (200, 56);
    let sources = random_units(&mut rng, k, 16);
    let parity = encode(&sources, m).unwrap();
    let mut units = frame(&sources, &parity);
    for u in units.iter_mut().take(m) {
        *u = None;
    }
    assert_eq!(recover(&mut units, k), Ok(m));
    for j in 0..k {
        assert_eq!(units[j].as_ref().unwrap(), &sources[j]);
    }
}

#[test]
fn errors() {
    let sources = vec![vec![0u8; 4], vec![0u8; 5]];
    assert_eq!(encode(&sources, 1), Err(FecError::LengthMismatch));
    let empty: Vec<Vec<u8>> = vec![];
    assert_eq!(encode(&empty, 1), Err(FecError::NoSourceUnits));
    let mut units = vec![Some(vec![0u8; 4]), None, Some(vec![0u8; 3])];
    assert_eq!(recover(&mut units, 2), Err(FecError::LengthMismatch));
    let mut units: Vec<Option<Vec<u8>>> = vec![None, None, Some(vec![1])];
    assert_eq!(
        recover(&mut units, 2),
        Err(FecError::NotEnoughUnits {
            present: 1,
            needed: 2
        })
    );
    let mut units = vec![Some(vec![1u8]), Some(vec![2u8])];
    assert_eq!(recover(&mut units, 2), Ok(0));
}
