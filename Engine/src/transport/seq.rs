pub fn tsn_before(a: u32, b: u32) -> bool {
    a != b && b.wrapping_sub(a) < 0x8000_0000
}

pub fn tsn_after(a: u32, b: u32) -> bool {
    tsn_before(b, a)
}

pub fn tsn_at_or_before(a: u32, b: u32) -> bool {
    a == b || tsn_before(a, b)
}

pub fn idx_before(a: u16, b: u16) -> bool {
    a != b && b.wrapping_sub(a) < 0x8000
}

pub fn idx_after(a: u16, b: u16) -> bool {
    idx_before(b, a)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serial_order() {
        assert!(tsn_before(1, 2));
        assert!(!tsn_before(2, 1));
        assert!(tsn_before(u32::MAX, 0));
        assert!(tsn_after(0, u32::MAX));
        assert!(!tsn_before(5, 5));
        assert!(!tsn_before(0, 0x8000_0000));
        assert!(!tsn_after(0, 0x8000_0000));
        assert!(tsn_before(0, 0x7fff_ffff));
        assert!(tsn_at_or_before(7, 7));
        assert!(idx_before(0xffff, 0));
        assert!(idx_after(3, 0xfffe));
        assert!(!idx_before(0, 0x8000) && !idx_after(0, 0x8000));
    }
}
