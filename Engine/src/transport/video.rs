use std::collections::VecDeque;
use std::time::{Duration, Instant};

pub const VIDEO_WINDOW: usize = 64;
pub const CONSOLE_VIDEO_WAIT: Duration = Duration::from_millis(16);
pub const CLOUD_VIDEO_WAIT: Duration = Duration::from_millis(3);

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct VideoReorderStats {
    pub discarded: u64,
    pub evicted: u64,
    pub skipped: u64,
    pub restarts: u64,
}

#[derive(Debug)]
pub struct VideoReorder<T> {
    start: Option<u16>,
    slots: VecDeque<Option<(T, Instant)>>,
    held: usize,
    wait: Duration,
    stats: VideoReorderStats,
}

impl<T> VideoReorder<T> {
    pub fn new(wait: Duration) -> Self {
        Self {
            start: None,
            slots: VecDeque::new(),
            held: 0,
            wait,
            stats: VideoReorderStats::default(),
        }
    }

    pub fn stats(&self) -> VideoReorderStats {
        self.stats
    }

    #[cfg(test)]
    pub fn start(&self) -> Option<u16> {
        self.start
    }

    pub fn deadline(&self) -> Option<Instant> {
        self.slots
            .iter()
            .flatten()
            .next()
            .map(|(_, arrived)| *arrived + self.wait)
    }

    fn advance(&mut self) {
        self.start = self.start.map(|s| s.wrapping_add(1));
    }

    fn restart(&mut self, at: u16) {
        self.stats.evicted += self.held as u64;
        self.slots.clear();
        self.held = 0;
        self.start = Some(at);
        self.stats.restarts += 1;
    }

    fn deliver(&mut self, out: &mut Vec<T>) {
        while let Some((item, _)) = self.slots.front_mut().and_then(Option::take) {
            self.slots.pop_front();
            self.held -= 1;
            self.advance();
            out.push(item);
        }
    }

    pub fn push(
        &mut self,
        packet_index: u16,
        unit_index: u16,
        item: T,
        now: Instant,
        out: &mut Vec<T>,
    ) {
        let start = *self
            .start
            .get_or_insert(packet_index.wrapping_sub(unit_index));
        let mut d = packet_index.wrapping_sub(start);
        if d == 0x8000 && self.held == 0 {
            self.restart(packet_index);
            d = 0;
        } else if d >= 0x8000 {
            self.stats.discarded += 1;
            return;
        }
        if usize::from(d) >= VIDEO_WINDOW {
            if self.held == 0 {
                self.restart(packet_index);
                d = 0;
            } else {
                while usize::from(d) >= VIDEO_WINDOW {
                    if let Some(Some(_)) = self.slots.pop_front() {
                        self.held -= 1;
                        self.stats.evicted += 1;
                    }
                    self.advance();
                    d -= 1;
                    if self.held == 0 {
                        self.restart(packet_index);
                        d = 0;
                        break;
                    }
                }
            }
        }
        let d = usize::from(d);
        while self.slots.len() <= d {
            self.slots.push_back(None);
        }
        if self.slots[d].is_some() {
            self.stats.discarded += 1;
            return;
        }
        self.slots[d] = Some((item, now));
        self.held += 1;
        self.deliver(out);
    }

    pub fn poll(&mut self, now: Instant, out: &mut Vec<T>) {
        while let Some(deadline) = self.deadline() {
            if now < deadline {
                return;
            }
            while matches!(self.slots.front(), Some(None)) {
                self.slots.pop_front();
                self.advance();
                self.stats.skipped += 1;
            }
            self.deliver(out);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }

    #[test]
    fn in_order_and_gap_wait() {
        let t0 = Instant::now();
        let mut w = VideoReorder::new(CONSOLE_VIDEO_WAIT);
        let mut out = Vec::new();
        w.push(12, 2, 12, t0, &mut out);
        assert!(out.is_empty());
        assert_eq!(w.start(), Some(10));
        assert_eq!(w.deadline(), Some(t0 + ms(16)));
        w.push(10, 0, 10, t0 + ms(1), &mut out);
        assert_eq!(out, vec![10]);
        assert_eq!(w.deadline(), Some(t0 + ms(16)));
        w.poll(t0 + ms(15), &mut out);
        assert_eq!(out, vec![10]);
        w.poll(t0 + ms(16), &mut out);
        assert_eq!(out, vec![10, 12]);
        assert_eq!(w.deadline(), None);
        w.push(11, 1, 11, t0 + ms(18), &mut out);
        assert_eq!(w.stats().discarded, 1);
        assert_eq!(w.stats().skipped, 1);
    }

    #[test]
    fn duplicates_and_eviction() {
        let t0 = Instant::now();
        let mut w = VideoReorder::new(CLOUD_VIDEO_WAIT);
        let mut out = Vec::new();
        w.push(0, 0, 0u16, t0, &mut out);
        w.push(0, 0, 0u16, t0, &mut out);
        assert_eq!(w.stats().discarded, 1);
        w.push(2, 0, 2, t0, &mut out);
        w.push(70, 0, 70, t0 + ms(1), &mut out);
        assert_eq!(out, vec![0, 70]);
        assert_eq!(w.stats().evicted, 1);
        assert_eq!(w.stats().restarts, 1);
        assert_eq!(w.start(), Some(71));
    }

    #[test]
    fn a_packet_waits_no_longer_than_the_wait_however_many_gaps() {
        let t0 = Instant::now();
        let mut w = VideoReorder::new(CONSOLE_VIDEO_WAIT);
        let mut out = Vec::new();
        w.push(0, 0, 0u16, t0, &mut out);
        w.push(5, 0, 5, t0, &mut out);
        w.push(40, 0, 40, t0, &mut out);
        assert_eq!(w.deadline(), Some(t0 + ms(16)));
        w.push(68, 0, 68, t0 + ms(5), &mut out);
        assert_eq!(out, vec![0, 5]);
        assert_eq!(w.deadline(), Some(t0 + ms(16)));
        w.push(107, 0, 107, t0 + ms(6), &mut out);
        assert_eq!(w.stats().evicted, 1);
        assert_eq!(w.deadline(), Some(t0 + ms(21)));
        w.poll(t0 + ms(21), &mut out);
        assert_eq!(out, vec![0, 5, 68]);
        assert_eq!(w.deadline(), Some(t0 + ms(22)));
        w.poll(t0 + ms(22), &mut out);
        assert_eq!(out, vec![0, 5, 68, 107]);
    }

    #[test]
    fn several_gaps_that_have_waited_go_at_once() {
        let t0 = Instant::now();
        let mut w = VideoReorder::new(CLOUD_VIDEO_WAIT);
        let mut out = Vec::new();
        w.push(0, 0, 0u16, t0, &mut out);
        w.push(2, 2, 2, t0, &mut out);
        w.push(4, 4, 4, t0, &mut out);
        w.poll(t0 + ms(3), &mut out);
        assert_eq!(out, vec![0, 2, 4]);
        assert_eq!(w.stats().skipped, 2);
        assert_eq!(w.deadline(), None);
    }

    #[test]
    fn wraps_and_ambiguous_restart() {
        let t0 = Instant::now();
        let mut w = VideoReorder::new(CONSOLE_VIDEO_WAIT);
        let mut out = Vec::new();
        w.push(0xfffe, 0, 1u32, t0, &mut out);
        w.push(0xffff, 1, 2, t0, &mut out);
        w.push(0, 2, 3, t0, &mut out);
        assert_eq!(out, vec![1, 2, 3]);
        w.push(0x8001, 0, 4, t0, &mut out);
        assert_eq!(out, vec![1, 2, 3, 4]);
        assert_eq!(w.start(), Some(0x8002));
    }
}
