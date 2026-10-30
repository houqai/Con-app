use super::seq::idx_after;

pub const MAX_FRAME_UNITS: u16 = 512;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum AudioCounting {
    #[default]
    PerPacket,
    PerNewFrame,
}

#[derive(Clone, Debug, Default)]
pub struct AudioLossCounter {
    mode: AudioCounting,
    started: bool,
    start: u16,
    max: u16,
    counted: u32,
    last_counted: Option<u16>,
}

impl AudioLossCounter {
    pub fn new(mode: AudioCounting) -> Self {
        Self {
            mode,
            ..Default::default()
        }
    }

    pub fn count(&mut self, frame: u16) {
        if self.mode == AudioCounting::PerNewFrame {
            if self.last_counted.is_some_and(|l| !idx_after(frame, l)) {
                return;
            }
            self.last_counted = Some(frame);
        }
        if !self.started {
            self.started = true;
            self.start = frame.wrapping_sub(1);
            self.max = self.start;
        }
        self.counted += 1;
        if idx_after(frame, self.max) {
            self.max = frame;
        }
    }

    pub fn take(&mut self) -> (u32, u32) {
        let span = u32::from(self.max.wrapping_sub(self.start));
        let received = self.counted;
        let lost = span.saturating_sub(self.counted);
        self.start = self.max;
        self.counted = 0;
        (received, lost)
    }
}

#[derive(Clone, Debug)]
struct Frame {
    index: u16,
    total: u16,
    fec: u16,
    seen: Vec<bool>,
    received: u32,
}

#[derive(Clone, Debug, Default)]
pub struct VideoLossCounter {
    current: Option<Frame>,
    received: u32,
    lost: u32,
}

impl VideoLossCounter {
    pub fn new() -> Self {
        Self::default()
    }

    fn close(&mut self) {
        if let Some(f) = self.current.take() {
            let source = u32::from(f.total - f.fec);
            let expected = source + u32::from(f.fec.max(1));
            self.received += f.received;
            self.lost += expected.saturating_sub(f.received);
        }
    }

    pub fn count(&mut self, frame: u16, unit: u16, total: u16, fec: u16) {
        if let Some(f) = self.current.as_mut() {
            if f.index == frame {
                if unit < f.total && !f.seen[usize::from(unit)] {
                    f.seen[usize::from(unit)] = true;
                    f.received += 1;
                }
                return;
            }
            if !idx_after(frame, f.index) {
                return;
            }
        }
        self.close();
        if total == 0 || total < fec || total > MAX_FRAME_UNITS {
            return;
        }
        let mut seen = vec![false; usize::from(total)];
        let mut received = 0;
        if unit < total {
            seen[usize::from(unit)] = true;
            received = 1;
        }
        self.current = Some(Frame {
            index: frame,
            total,
            fec,
            seen,
            received,
        });
    }

    pub fn take(&mut self) -> (u32, u32) {
        let r = (self.received, self.lost);
        self.received = 0;
        self.lost = 0;
        r
    }
}

pub fn report_values(received: u32, lost: u32, margin: u32, ceiling: f64) -> (u16, u16) {
    let total = u64::from(received) + u64::from(lost);
    let cap = (total as f64 * ceiling.max(0.0)).floor() as u64;
    let reported_lost = (u64::from(lost) * u64::from(margin)).min(cap);
    let reported_received = total - reported_lost;
    (reported_received as u16, reported_lost as u16)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn audio_first_packet_and_gaps() {
        let mut a = AudioLossCounter::new(AudioCounting::PerPacket);
        a.count(500);
        a.count(501);
        a.count(504);
        assert_eq!(a.take(), (3, 2));
        a.count(505);
        a.count(505);
        a.count(505);
        assert_eq!(a.take(), (3, 0));
        assert_eq!(a.take(), (0, 0));
    }

    #[test]
    fn audio_across_wrap() {
        let mut a = AudioLossCounter::new(AudioCounting::PerPacket);
        a.count(0xfffe);
        a.count(0xffff);
        a.count(2);
        assert_eq!(a.take(), (3, 2));
    }

    #[test]
    fn audio_per_new_frame() {
        let mut a = AudioLossCounter::new(AudioCounting::PerNewFrame);
        for f in [10, 10, 10, 11, 11, 11, 13, 13, 13] {
            a.count(f);
        }
        assert_eq!(a.take(), (3, 1));
        for f in [14, 12, 13, 14, 15] {
            a.count(f);
        }
        assert_eq!(a.take(), (2, 0));
    }

    #[test]
    fn video_frames() {
        let mut v = VideoLossCounter::new();
        for u in [0, 1, 3, 5, 5] {
            v.count(1, u, 6, 2);
        }
        assert_eq!(v.take(), (0, 0));
        v.count(0, 0, 6, 2);
        v.count(2, 0, 3, 0);
        assert_eq!(v.take(), (4, 2));
        v.count(3, 0, 1, 0);
        assert_eq!(v.take(), (1, 3));
    }

    #[test]
    fn report_margin_and_ceiling() {
        assert_eq!(report_values(990, 10, 1, 0.04), (990, 10));
        assert_eq!(report_values(900, 100, 1, 0.04), (960, 40));
        assert_eq!(report_values(990, 10, 3, 0.04), (970, 30));
        assert_eq!(report_values(990, 10, 3, 0.02), (980, 20));
        assert_eq!(report_values(500, 50, 3, 0.0), (550, 0));
        assert_eq!(report_values(0, 0, 3, 0.04), (0, 0));
    }
}
