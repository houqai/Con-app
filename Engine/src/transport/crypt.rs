use super::packet::{tag_layout, TagLayout};
use crate::crypto::stream::{DirectionKeys, PacketTagger};

pub fn key_pos_advance(s: u64) -> u64 {
    s + (s % 16)
}

#[derive(Debug)]
pub struct Sealer {
    tagger: PacketTagger,
    position: u64,
}

impl Sealer {
    pub fn new(keys: DirectionKeys) -> Self {
        Self::starting_at(keys, 0)
    }

    pub fn starting_at(keys: DirectionKeys, position: u64) -> Self {
        Self {
            tagger: PacketTagger::new(keys),
            position,
        }
    }

    pub fn position(&self) -> u64 {
        self.position
    }

    pub fn allocate(&mut self, s: u64) -> u64 {
        let p = self.position;
        self.position = self.position.wrapping_add(key_pos_advance(s));
        p
    }

    pub fn encrypt_payload(&self, packet: &mut [u8], payload_offset: usize, key_position: u64) {
        self.tagger
            .keys()
            .apply_keystream(key_position.wrapping_add(16), &mut packet[payload_offset..]);
    }

    pub fn seal(&mut self, packet: &mut [u8], key_position: u64) {
        let Some(layout) = tag_layout(packet[0] & 0x0f) else {
            return;
        };
        let tag = compute_tag(&mut self.tagger, packet, layout, key_position);
        packet[layout.key_pos..layout.key_pos + 4]
            .copy_from_slice(&(key_position as u32).to_be_bytes());
        packet[layout.gmac..layout.gmac + 4].copy_from_slice(&tag);
    }
}

pub fn compute_tag(
    tagger: &mut PacketTagger,
    packet: &[u8],
    layout: TagLayout,
    key_position: u64,
) -> [u8; 4] {
    let mut copy = packet.to_vec();
    copy[layout.gmac..layout.gmac + 4].fill(0);
    if layout.zero_key_pos {
        copy[layout.key_pos..layout.key_pos + 4].fill(0);
    } else {
        copy[layout.key_pos..layout.key_pos + 4]
            .copy_from_slice(&(key_position as u32).to_be_bytes());
    }
    tagger.tag(key_position, &copy)
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct KeyPosTracker {
    prev: u64,
}

impl KeyPosTracker {
    pub fn extend(&self, low: u32) -> u64 {
        let mut hi = (self.prev >> 32) as u32;
        let lo = self.prev as u32;
        let follows = low != lo && low.wrapping_sub(lo) < 0x8000_0000;
        let precedes = low != lo && lo.wrapping_sub(low) < 0x8000_0000;
        if follows && low < lo {
            hi = hi.wrapping_add(1);
        } else if precedes && low > lo && hi > 0 {
            hi -= 1;
        }
        (u64::from(hi) << 32) | u64::from(low)
    }

    pub fn accept(&mut self, full: u64) {
        self.prev = full;
    }
}

#[derive(Debug)]
pub struct Opener {
    tagger: PacketTagger,
    tracker: KeyPosTracker,
}

impl Opener {
    pub fn new(keys: DirectionKeys) -> Self {
        Self {
            tagger: PacketTagger::new(keys),
            tracker: KeyPosTracker::default(),
        }
    }

    pub fn verify(&mut self, packet: &[u8]) -> Option<u64> {
        let layout = tag_layout(*packet.first()? & 0x0f)?;
        if packet.len() < layout.min_len() {
            return None;
        }
        let low = u32::from_be_bytes(
            packet[layout.key_pos..layout.key_pos + 4]
                .try_into()
                .expect("4 bytes"),
        );
        let full = self.tracker.extend(low);
        let tag = compute_tag(&mut self.tagger, packet, layout, full);
        if !constant_time_eq(&tag, &packet[layout.gmac..layout.gmac + 4]) {
            return None;
        }
        self.tracker.accept(full);
        Some(full)
    }

    pub fn decrypt_payload(&self, packet: &mut [u8], payload_offset: usize, key_position: u64) {
        self.tagger
            .keys()
            .apply_keystream(key_position.wrapping_add(16), &mut packet[payload_offset..]);
    }
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allocation_rule() {
        assert_eq!(key_pos_advance(0), 0);
        assert_eq!(key_pos_advance(2), 4);
        assert_eq!(key_pos_advance(15), 30);
        assert_eq!(key_pos_advance(16), 16);
        assert_eq!(key_pos_advance(29), 42);
        let mut s = Sealer::new(DirectionKeys::from_parts([1; 16], [2; 16]));
        assert_eq!(s.allocate(29), 0);
        assert_eq!(s.allocate(15), 42);
        assert_eq!(s.position(), 72);
    }

    #[test]
    fn tracker_extends_across_wrap() {
        let mut t = KeyPosTracker::default();
        assert_eq!(t.extend(0x40), 0x40);
        t.accept(0xffff_ff00);
        assert_eq!(t.extend(0x10), 0x1_0000_0010);
        t.accept(0x1_0000_0010);
        assert_eq!(t.extend(0xffff_fff0), 0xffff_fff0);
        assert_eq!(t.extend(0x20), 0x1_0000_0020);
        assert_eq!(t.extend(0x08), 0x1_0000_0008);
        let t0 = KeyPosTracker::default();
        assert_eq!(t0.extend(0xffff_fff0), 0xffff_fff0);
    }
}
