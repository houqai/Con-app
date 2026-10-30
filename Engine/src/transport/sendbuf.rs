use std::collections::VecDeque;
use std::time::{Duration, Instant};

use super::seq::tsn_at_or_before;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RetransmitConfig {
    pub capacity: usize,
    pub check_interval: Duration,
    pub timeout: Duration,
    pub max_retransmissions: u32,
}

impl Default for RetransmitConfig {
    fn default() -> Self {
        Self {
            capacity: 16,
            check_interval: Duration::from_millis(100),
            timeout: Duration::from_millis(200),
            max_retransmissions: 25,
        }
    }
}

#[derive(Clone, Debug)]
struct Entry {
    tsn: u32,
    datagram: Vec<u8>,
    first_sent: Instant,
    last_sent: Instant,
    retransmissions: u32,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CheckResult {
    pub resend: Vec<Vec<u8>>,
    pub given_up: usize,
}

#[derive(Debug)]
pub struct SendBuffer {
    config: RetransmitConfig,
    entries: VecDeque<Entry>,
}

impl SendBuffer {
    pub fn new(config: RetransmitConfig) -> Self {
        Self {
            config,
            entries: VecDeque::new(),
        }
    }

    #[cfg(test)]
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    #[cfg(test)]
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    #[cfg(test)]
    pub fn tsns(&self) -> Vec<u32> {
        self.entries.iter().map(|e| e.tsn).collect()
    }

    pub fn push(&mut self, tsn: u32, datagram: Vec<u8>, now: Instant) -> bool {
        if self.entries.len() >= self.config.capacity {
            return false;
        }
        self.entries.push_back(Entry {
            tsn,
            datagram,
            first_sent: now,
            last_sent: now,
            retransmissions: 0,
        });
        true
    }

    pub fn check(&mut self, now: Instant) -> CheckResult {
        let timeout = self.config.timeout;
        let due = |e: &Entry| now.saturating_duration_since(e.last_sent) > timeout;
        let give_up_through = self
            .entries
            .iter()
            .rposition(|e| due(e) && e.retransmissions >= self.config.max_retransmissions);
        let mut result = CheckResult::default();
        if let Some(i) = give_up_through {
            self.entries.drain(..=i);
            result.given_up = i + 1;
        }
        for e in self.entries.iter_mut() {
            if due(e) {
                e.last_sent = now;
                e.retransmissions += 1;
                result.resend.push(e.datagram.clone());
            }
        }
        result
    }

    pub fn acknowledge(&mut self, cumulative: u32, now: Instant) -> Vec<Duration> {
        let mut samples = Vec::new();
        self.entries.retain(|e| {
            if tsn_at_or_before(e.tsn, cumulative) {
                samples.push(now.saturating_duration_since(e.first_sent));
                false
            } else {
                true
            }
        });
        samples
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RttStats {
    latest_us: u64,
    samples: u64,
    recent: VecDeque<u64>,
    initial_us: u64,
}

impl RttStats {
    pub fn with_initial(initial_us: u64) -> Self {
        Self {
            initial_us,
            ..Self::default()
        }
    }

    pub fn record(&mut self, sample: Duration) {
        let us = u64::try_from(sample.as_micros()).unwrap_or(u64::MAX);
        self.latest_us = us;
        self.samples += 1;
        if self.recent.len() == 5 {
            self.recent.pop_front();
        }
        self.recent.push_back(us);
    }

    pub fn latest_us(&self) -> u64 {
        if self.samples == 0 {
            self.initial_us
        } else {
            self.latest_us
        }
    }

    pub fn samples(&self) -> u64 {
        self.samples
    }

    pub fn median_us(&self) -> u64 {
        let mut v: Vec<u64> = self.recent.iter().copied().collect();
        if v.is_empty() {
            return self.initial_us;
        }
        v.sort_unstable();
        v[(v.len() - 1) / 2]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }

    #[test]
    fn resend_timing_and_ack() {
        let t0 = Instant::now();
        let mut b = SendBuffer::new(RetransmitConfig::default());
        assert!(b.push(10, vec![1], t0));
        assert!(b.push(11, vec![2], t0 + ms(50)));
        assert!(b.check(t0 + ms(200)).resend.is_empty());
        let r = b.check(t0 + ms(201));
        assert_eq!(r.resend, vec![vec![1]]);
        let r = b.check(t0 + ms(300));
        assert_eq!(r.resend, vec![vec![2]]);
        let samples = b.acknowledge(10, t0 + ms(320));
        assert_eq!(samples, vec![ms(320)]);
        assert_eq!(b.tsns(), vec![11]);
        b.acknowledge(12, t0 + ms(330));
        assert!(b.is_empty());
    }

    #[test]
    fn gives_up_after_the_limit_with_older_entries() {
        let t0 = Instant::now();
        let cfg = RetransmitConfig {
            max_retransmissions: 2,
            ..Default::default()
        };
        let mut b = SendBuffer::new(cfg);
        b.push(1, vec![1], t0);
        b.push(2, vec![2], t0 + ms(10));
        b.push(3, vec![3], t0 + ms(400));
        let mut t = t0;
        let mut total = 0;
        for _ in 0..3 {
            t += ms(250);
            let r = b.check(t);
            total += r.resend.len();
        }
        assert_eq!(b.tsns(), vec![3]);
        assert_eq!(total, 5);
    }

    #[test]
    fn full_buffer_refuses() {
        let t0 = Instant::now();
        let mut b = SendBuffer::new(RetransmitConfig::default());
        for i in 0..16 {
            assert!(b.push(i, vec![], t0));
        }
        assert!(!b.push(16, vec![], t0));
        assert_eq!(b.len(), 16);
    }

    #[test]
    fn ack_across_wrap() {
        let t0 = Instant::now();
        let mut b = SendBuffer::new(RetransmitConfig::default());
        b.push(u32::MAX - 1, vec![], t0);
        b.push(u32::MAX, vec![], t0);
        b.push(0, vec![], t0);
        b.push(1, vec![], t0);
        assert_eq!(b.acknowledge(0, t0).len(), 3);
        assert_eq!(b.tsns(), vec![1]);
    }

    #[test]
    fn rtt_median() {
        let mut r = RttStats::default();
        assert_eq!(r.median_us(), 0);
        for v in [30, 10, 20, 50, 40, 5] {
            r.record(ms(v));
        }
        assert_eq!(r.samples(), 6);
        assert_eq!(r.latest_us(), 5_000);
        assert_eq!(r.median_us(), 20_000);
        let mut r = RttStats::with_initial(42_000);
        assert_eq!(
            (r.latest_us(), r.median_us(), r.samples()),
            (42_000, 42_000, 0)
        );
        r.record(ms(7));
        assert_eq!(
            (r.latest_us(), r.median_us(), r.samples()),
            (7_000, 7_000, 1)
        );
    }
}
