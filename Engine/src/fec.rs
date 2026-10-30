#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum FecError {
    #[error("a frame needs at least one source unit")]
    NoSourceUnits,
    #[error("{0} units exceed the code's limit of 256")]
    TooManyUnits(usize),
    #[error("units have different lengths")]
    LengthMismatch,
    #[error("{present} units present, {needed} needed")]
    NotEnoughUnits { present: usize, needed: usize },
}

const POLY: u16 = 0x11d;

const fn build_tables() -> ([u8; 512], [u8; 256]) {
    let mut exp = [0u8; 512];
    let mut log = [0u8; 256];
    let mut x: u16 = 1;
    let mut i = 0;
    while i < 255 {
        exp[i] = x as u8;
        log[x as usize] = i as u8;
        x <<= 1;
        if x & 0x100 != 0 {
            x ^= POLY;
        }
        i += 1;
    }
    let mut j = 255;
    while j < 512 {
        exp[j] = exp[j - 255];
        j += 1;
    }
    (exp, log)
}

const TABLES: ([u8; 512], [u8; 256]) = build_tables();
static EXP: [u8; 512] = TABLES.0;
static LOG: [u8; 256] = TABLES.1;

#[inline]
pub fn gf_mul(a: u8, b: u8) -> u8 {
    if a == 0 || b == 0 {
        0
    } else {
        EXP[LOG[a as usize] as usize + LOG[b as usize] as usize]
    }
}

#[inline]
pub fn gf_inv(a: u8) -> u8 {
    assert!(a != 0, "zero has no inverse");
    EXP[255 - LOG[a as usize] as usize]
}

fn mul_add(dst: &mut [u8], src: &[u8], c: u8) {
    match c {
        0 => {}
        1 => dst.iter_mut().zip(src).for_each(|(d, s)| *d ^= s),
        _ => {
            let lc = LOG[c as usize] as usize;
            for (d, &s) in dst.iter_mut().zip(src) {
                if s != 0 {
                    *d ^= EXP[lc + LOG[s as usize] as usize];
                }
            }
        }
    }
}

pub fn cauchy_coefficient(i: usize, j: usize, m: usize) -> u8 {
    gf_inv((i as u8) ^ ((m + j) as u8))
}

pub fn coding_matrix(k: usize, m: usize) -> Result<Vec<Vec<u8>>, FecError> {
    check_sizes(k, m)?;
    Ok((0..m)
        .map(|i| (0..k).map(|j| cauchy_coefficient(i, j, m)).collect())
        .collect())
}

fn check_sizes(k: usize, m: usize) -> Result<(), FecError> {
    if k == 0 {
        return Err(FecError::NoSourceUnits);
    }
    if k + m > 256 {
        return Err(FecError::TooManyUnits(k + m));
    }
    Ok(())
}

pub fn encode<S: AsRef<[u8]>>(sources: &[S], m: usize) -> Result<Vec<Vec<u8>>, FecError> {
    let k = sources.len();
    check_sizes(k, m)?;
    let len = sources[0].as_ref().len();
    if sources.iter().any(|s| s.as_ref().len() != len) {
        return Err(FecError::LengthMismatch);
    }
    let mut parity = vec![vec![0u8; len]; m];
    for (i, p) in parity.iter_mut().enumerate() {
        for (j, s) in sources.iter().enumerate() {
            mul_add(p, s.as_ref(), cauchy_coefficient(i, j, m));
        }
    }
    Ok(parity)
}

fn invert(mut a: Vec<Vec<u8>>) -> Option<Vec<Vec<u8>>> {
    let n = a.len();
    let mut inv: Vec<Vec<u8>> = (0..n)
        .map(|r| (0..n).map(|c| u8::from(r == c)).collect())
        .collect();
    for col in 0..n {
        let pivot = (col..n).find(|&r| a[r][col] != 0)?;
        a.swap(col, pivot);
        inv.swap(col, pivot);
        let f = gf_inv(a[col][col]);
        for c in 0..n {
            a[col][c] = gf_mul(a[col][c], f);
            inv[col][c] = gf_mul(inv[col][c], f);
        }
        for r in 0..n {
            if r != col && a[r][col] != 0 {
                let g = a[r][col];
                for c in 0..n {
                    let (av, iv) = (a[col][c], inv[col][c]);
                    a[r][c] ^= gf_mul(g, av);
                    inv[r][c] ^= gf_mul(g, iv);
                }
            }
        }
    }
    Some(inv)
}

pub fn recover(units: &mut [Option<Vec<u8>>], k: usize) -> Result<usize, FecError> {
    if units.len() < k {
        return Err(FecError::NotEnoughUnits {
            present: units.iter().filter(|u| u.is_some()).count(),
            needed: k,
        });
    }
    let m = units.len() - k;
    check_sizes(k, m)?;
    let missing: Vec<usize> = (0..k).filter(|&j| units[j].is_none()).collect();
    if missing.is_empty() {
        return Ok(0);
    }
    let present: Vec<usize> = (0..units.len()).filter(|&i| units[i].is_some()).collect();
    if present.len() < k {
        return Err(FecError::NotEnoughUnits {
            present: present.len(),
            needed: k,
        });
    }
    let len = units[present[0]]
        .as_ref()
        .expect("present units are Some")
        .len();
    if present
        .iter()
        .any(|&i| units[i].as_ref().map(Vec::len) != Some(len))
    {
        return Err(FecError::LengthMismatch);
    }
    let chosen: Vec<usize> = present.iter().copied().take(k).collect();
    let rows: Vec<Vec<u8>> = chosen
        .iter()
        .map(|&u| {
            if u < k {
                (0..k).map(|c| u8::from(c == u)).collect()
            } else {
                (0..k).map(|j| cauchy_coefficient(u - k, j, m)).collect()
            }
        })
        .collect();
    let inv = invert(rows).expect("every square submatrix of a Cauchy generator is invertible");
    let mut restored = Vec::with_capacity(missing.len());
    for &j in &missing {
        let mut out = vec![0u8; len];
        for (r, &u) in chosen.iter().enumerate() {
            let src = units[u].as_ref().expect("chosen units are present");
            mul_add(&mut out, src, inv[j][r]);
        }
        restored.push((j, out));
    }
    let n = restored.len();
    for (j, out) in restored {
        units[j] = Some(out);
    }
    Ok(n)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn field_basics() {
        for a in 1..=255u8 {
            assert_eq!(gf_mul(a, gf_inv(a)), 1);
        }
        assert_eq!(gf_mul(0x80, 2), 0x1d);
        assert_eq!(gf_mul(0, 7), 0);
    }

    #[test]
    fn matrix_examples_from_description() {
        assert_eq!(
            coding_matrix(6, 1).unwrap(),
            vec![vec![0x01, 0x8e, 0xf4, 0x47, 0xa7, 0x7a]]
        );
        assert_eq!(
            coding_matrix(4, 2).unwrap(),
            vec![vec![0x8e, 0xf4, 0x47, 0xa7], vec![0xf4, 0x8e, 0xa7, 0x47]]
        );
    }

    #[test]
    fn limits() {
        assert_eq!(coding_matrix(0, 1), Err(FecError::NoSourceUnits));
        assert_eq!(coding_matrix(200, 57), Err(FecError::TooManyUnits(257)));
        assert!(coding_matrix(200, 56).is_ok());
    }
}
