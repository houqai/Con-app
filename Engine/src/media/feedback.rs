use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crate::log::Logger;
use crate::transport::Link;

pub mod button {
    pub const CROSS: u32 = 1 << 0;
    pub const CIRCLE: u32 = 1 << 1;
    pub const SQUARE: u32 = 1 << 2;
    pub const TRIANGLE: u32 = 1 << 3;
    pub const LEFT: u32 = 1 << 4;
    pub const RIGHT: u32 = 1 << 5;
    pub const UP: u32 = 1 << 6;
    pub const DOWN: u32 = 1 << 7;
    pub const L1: u32 = 1 << 8;
    pub const R1: u32 = 1 << 9;
    pub const L3: u32 = 1 << 10;
    pub const R3: u32 = 1 << 11;
    pub const OPTIONS: u32 = 1 << 12;
    pub const SHARE: u32 = 1 << 13;
    pub const TOUCHPAD: u32 = 1 << 14;
    pub const PS: u32 = 1 << 15;
}

const BUTTON_CODES: [(u8, bool); 16] = [
    (0x88, true),
    (0x89, true),
    (0x8a, true),
    (0x8b, true),
    (0x82, true),
    (0x83, true),
    (0x80, true),
    (0x81, true),
    (0x84, true),
    (0x85, true),
    (0x8f, false),
    (0x90, false),
    (0x8c, false),
    (0x8d, false),
    (0x91, false),
    (0x8e, false),
];
pub const CODE_L2: u8 = 0x86;
pub const CODE_R2: u8 = 0x87;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Touch {
    pub id: i16,
    pub x: u16,
    pub y: u16,
}

impl Touch {
    pub const NONE: Touch = Touch { id: -1, x: 0, y: 0 };

    pub fn active(&self) -> bool {
        self.id >= 0
    }
}

impl Default for Touch {
    fn default() -> Self {
        Self::NONE
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ControllerState {
    pub buttons: u32,
    pub l2: u8,
    pub r2: u8,
    pub left_x: i16,
    pub left_y: i16,
    pub right_x: i16,
    pub right_y: i16,
    pub touches: [Touch; 2],
    pub gyro: [f32; 3],
    pub accel: [f32; 3],
    pub orientation: [f32; 4],
}

impl Default for ControllerState {
    fn default() -> Self {
        Self::IDLE
    }
}

fn approx_eq(a: &[f32], b: &[f32]) -> bool {
    a.iter().zip(b).all(|(x, y)| (x - y).abs() <= 1e-7)
}

impl ControllerState {
    pub const IDLE: ControllerState = ControllerState {
        buttons: 0,
        l2: 0,
        r2: 0,
        left_x: 0,
        left_y: 0,
        right_x: 0,
        right_y: 0,
        touches: [Touch::NONE; 2],
        gyro: [0.0; 3],
        accel: [0.0, 1.0, 0.0],
        orientation: [0.0, 0.0, 0.0, 1.0],
    };

    pub fn same_as(&self, o: &Self) -> bool {
        self.buttons == o.buttons
            && self.l2 == o.l2
            && self.r2 == o.r2
            && self.touches == o.touches
            && self.same_sticks_and_motion(o)
    }

    pub fn same_sticks_and_motion(&self, o: &Self) -> bool {
        (self.left_x, self.left_y, self.right_x, self.right_y)
            == (o.left_x, o.left_y, o.right_x, o.right_y)
            && approx_eq(&self.gyro, &o.gyro)
            && approx_eq(&self.accel, &o.accel)
            && approx_eq(&self.orientation, &o.orientation)
    }
}

pub fn gyro_value(g: f32) -> u16 {
    let g = f64::from(g).clamp(-30.0, 30.0);
    (65535.0 * (g + 30.0) / 60.0) as u16
}

pub fn accel_value(a: f32) -> u16 {
    let a = f64::from(a).clamp(-5.0, 5.0);
    (65535.0 * (a + 5.0) / 10.0) as u16
}

const HALF_SQRT2: f64 = std::f64::consts::FRAC_1_SQRT_2;

pub fn compress_orientation(q: [f32; 4]) -> u32 {
    let mut largest = 0;
    for i in 1..4 {
        if q[i].abs() > q[largest].abs() {
            largest = i;
        }
    }
    let mut v = u32::from(q[largest] < 0.0);
    v |= (largest as u32) << 1;
    let mut shift = 3;
    for (i, c) in q.iter().enumerate() {
        if i == largest {
            continue;
        }
        let c = f64::from(*c).clamp(-HALF_SQRT2, HALF_SQRT2);
        let field = ((c + HALF_SQRT2) * 511.0 / std::f64::consts::SQRT_2) as u32;
        v |= (field & 0x1ff) << shift;
        shift += 9;
    }
    v
}

pub fn decompress_orientation(v: u32) -> [f32; 4] {
    let largest = ((v >> 1) & 3) as usize;
    let negative = v & 1 != 0;
    let mut q = [0f32; 4];
    let mut shift = 3;
    let mut sum = 0f64;
    for (i, c) in q.iter_mut().enumerate() {
        if i == largest {
            continue;
        }
        let field = f64::from((v >> shift) & 0x1ff);
        let x = field * std::f64::consts::SQRT_2 / 511.0 - HALF_SQRT2;
        sum += x * x;
        *c = x as f32;
        shift += 9;
    }
    let l = (1.0 - sum).max(0.0).sqrt();
    q[largest] = if negative { -l as f32 } else { l as f32 };
    q
}

pub fn encode_state(s: &ControllerState, version: u32) -> Vec<u8> {
    let mut p = Vec::with_capacity(28);
    p.push(0xa0);
    for g in s.gyro {
        p.extend_from_slice(&gyro_value(g).to_le_bytes());
    }
    for a in s.accel {
        p.extend_from_slice(&accel_value(a).to_le_bytes());
    }
    p.extend_from_slice(&compress_orientation(s.orientation).to_le_bytes());
    for v in [s.left_x, s.left_y, s.right_x, s.right_y] {
        p.extend_from_slice(&v.to_be_bytes());
    }
    if version >= 12 {
        p.extend_from_slice(&[0, 0, 1]);
    }
    p
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HistoryEvent {
    Button {
        code: u8,
        value: Option<u8>,
        pressed: bool,
    },
    Touch {
        down: bool,
        id: u8,
        x: u16,
        y: u16,
    },
}

impl HistoryEvent {
    pub fn button(bit: usize, pressed: bool) -> Self {
        let (code, has_value) = BUTTON_CODES[bit];
        HistoryEvent::Button {
            code,
            value: has_value.then_some(if pressed { 0xff } else { 0x00 }),
            pressed,
        }
    }

    pub fn trigger(code: u8, value: u8) -> Self {
        HistoryEvent::Button {
            code,
            value: Some(value),
            pressed: value != 0,
        }
    }

    pub fn encode(&self, out: &mut Vec<u8>) {
        match *self {
            HistoryEvent::Button {
                code,
                value: Some(v),
                ..
            } => out.extend_from_slice(&[0x80, code, v]),
            HistoryEvent::Button {
                code,
                value: None,
                pressed,
            } => out.extend_from_slice(&[0x80, if pressed { code + 0x20 } else { code }]),
            HistoryEvent::Touch { down, id, x, y } => {
                let x = x.min(0xfff);
                let y = y.min(0xfff);
                out.extend_from_slice(&[
                    if down { 0xd0 } else { 0xc0 },
                    id & 0x7f,
                    (x >> 4) as u8,
                    (((x & 0xf) << 4) as u8) | ((y >> 8) & 0xf) as u8,
                    y as u8,
                ]);
            }
        }
    }
}

pub fn parse_history(p: &[u8]) -> Option<Vec<HistoryEvent>> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < p.len() {
        match p[i] {
            0x80 => {
                let code = *p.get(i + 1)?;
                let base = if (0xac..=0xb1).contains(&code) {
                    code - 0x20
                } else {
                    code
                };
                if (0x8c..=0x91).contains(&base) {
                    out.push(HistoryEvent::Button {
                        code: base,
                        value: None,
                        pressed: code != base,
                    });
                    i += 2;
                } else {
                    let v = *p.get(i + 2)?;
                    out.push(HistoryEvent::Button {
                        code,
                        value: Some(v),
                        pressed: v != 0,
                    });
                    i += 3;
                }
            }
            0xd0 | 0xc0 => {
                let b = p.get(i..i + 5)?;
                out.push(HistoryEvent::Touch {
                    down: b[0] == 0xd0,
                    id: b[1],
                    x: (u16::from(b[2]) << 4) | u16::from(b[3] >> 4),
                    y: (u16::from(b[3] & 0xf) << 8) | u16::from(b[4]),
                });
                i += 5;
            }
            _ => return None,
        }
    }
    Some(out)
}

pub fn diff_events(old: &ControllerState, new: &ControllerState) -> Vec<HistoryEvent> {
    let mut ev = Vec::new();
    for slot in 0..2 {
        let (o, n) = (old.touches[slot], new.touches[slot]);
        let id_changed = o.id != n.id;
        if id_changed && o.active() {
            ev.push(HistoryEvent::Touch {
                down: false,
                id: o.id as u8,
                x: o.x,
                y: o.y,
            });
        }
        if n.active() && (id_changed || (n.x, n.y) != (o.x, o.y)) {
            ev.push(HistoryEvent::Touch {
                down: true,
                id: n.id as u8,
                x: n.x,
                y: n.y,
            });
        }
    }
    for bit in 0..16 {
        let mask = 1u32 << bit;
        if (old.buttons ^ new.buttons) & mask != 0 {
            ev.push(HistoryEvent::button(bit, new.buttons & mask != 0));
        }
    }
    if old.l2 != new.l2 {
        ev.push(HistoryEvent::trigger(CODE_L2, new.l2));
    }
    if old.r2 != new.r2 {
        ev.push(HistoryEvent::trigger(CODE_R2, new.r2));
    }
    ev
}

pub const HISTORY_RING: usize = 64;
pub const HISTORY_KEEP: usize = 32;
pub const HISTORY_MAX_PAYLOAD: usize = 0x300;
pub const HISTORY_QUEUE: usize = 64;
pub const STATE_KEEPALIVE: Duration = Duration::from_millis(200);
pub const BUTTON_REFRESH: Duration = Duration::from_millis(100);

#[derive(Clone, Debug, Default)]
pub struct History {
    ring: VecDeque<HistoryEvent>,
    queue: VecDeque<Vec<u8>>,
    pub dropped: u64,
}

impl History {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push(&mut self, events: &[HistoryEvent]) {
        if events.is_empty() {
            return;
        }
        for e in events {
            self.ring.push_front(*e);
            if self.ring.len() > HISTORY_RING {
                self.ring.pop_back();
            }
        }
        let mut p = Vec::with_capacity(self.ring.len() * 5);
        for e in &self.ring {
            let mut b = Vec::with_capacity(5);
            e.encode(&mut b);
            if p.len() + b.len() > HISTORY_MAX_PAYLOAD {
                break;
            }
            p.extend_from_slice(&b);
        }
        if self.queue.len() >= HISTORY_QUEUE {
            self.queue.pop_front();
            self.dropped += 1;
        }
        self.queue.push_back(p);
        self.ring.truncate(HISTORY_KEEP);
    }

    pub fn refresh(&mut self, s: &ControllerState) {
        let mut ev: Vec<HistoryEvent> = (0..16)
            .map(|bit| HistoryEvent::button(bit, s.buttons & (1 << bit) != 0))
            .collect();
        ev.push(HistoryEvent::trigger(CODE_L2, s.l2));
        ev.push(HistoryEvent::trigger(CODE_R2, s.r2));
        self.push(&ev);
    }

    pub fn pop(&mut self) -> Option<Vec<u8>> {
        self.queue.pop_front()
    }

    pub fn queued(&self) -> usize {
        self.queue.len()
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct FeedbackStats {
    pub state_sent: u64,
    pub history_sent: u64,
    pub history_dropped: u64,
    pub refreshes: u64,
}

struct Inner {
    current: ControllerState,
    history: History,
    running: bool,
    stats: FeedbackStats,
}

pub struct FeedbackShared {
    inner: Mutex<Inner>,
    cond: Condvar,
}

impl std::fmt::Debug for FeedbackShared {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("FeedbackShared { .. }")
    }
}

impl Default for FeedbackShared {
    fn default() -> Self {
        Self {
            inner: Mutex::new(Inner {
                current: ControllerState::IDLE,
                history: History::new(),
                running: false,
                stats: FeedbackStats::default(),
            }),
            cond: Condvar::new(),
        }
    }
}

impl FeedbackShared {
    fn lock(&self) -> MutexGuard<'_, Inner> {
        crate::sync::lock(&self.inner)
    }

    pub fn set_state(&self, s: ControllerState) {
        let mut g = self.lock();
        if g.current.same_as(&s) {
            return;
        }
        let ev = diff_events(&g.current, &s);
        g.history.push(&ev);
        g.current = s;
        drop(g);
        self.cond.notify_all();
    }

    pub fn stats(&self) -> FeedbackStats {
        let g = self.lock();
        FeedbackStats {
            history_dropped: g.history.dropped,
            ..g.stats
        }
    }
}

pub struct FeedbackSender {
    shared: Arc<FeedbackShared>,
    thread: Option<JoinHandle<()>>,
}

impl std::fmt::Debug for FeedbackSender {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("FeedbackSender { .. }")
    }
}

impl FeedbackSender {
    pub fn start(shared: Arc<FeedbackShared>, link: Link, version: u32, log: Logger) -> Self {
        shared.lock().running = true;
        let s = shared.clone();
        let thread = crate::threads::spawn(
            crate::threads::ThreadRole::Sender,
            "con-feedback",
            move || run(&s, &link, version, &log),
        )
        .ok();
        Self { shared, thread }
    }
}

impl Drop for FeedbackSender {
    fn drop(&mut self) {
        self.shared.lock().running = false;
        self.shared.cond.notify_all();
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

fn run(shared: &FeedbackShared, link: &Link, version: u32, log: &Logger) {
    let mut last_sent: Option<ControllerState> = None;
    let mut last_state_at: Option<Instant> = None;
    let mut last_refresh = Instant::now();
    loop {
        let (payload, current) = {
            let mut g = shared.lock();
            if !g.running {
                return;
            }
            (g.history.pop(), g.current)
        };
        if let Some(p) = payload {
            match link.send_feedback_history(&p) {
                Ok(()) => shared.lock().stats.history_sent += 1,
                Err(e) => log.debug(|| format!("feedback: history not sent: {e}")),
            }
        }
        let now = Instant::now();
        let due = last_state_at.is_none_or(|t| now.duration_since(t) >= STATE_KEEPALIVE);
        let changed = last_sent.is_none_or(|l| !current.same_sticks_and_motion(&l));
        if due || changed {
            match link.send_feedback_state(&encode_state(&current, version)) {
                Ok(()) => shared.lock().stats.state_sent += 1,
                Err(e) => log.debug(|| format!("feedback: state not sent: {e}")),
            }
            last_sent = Some(current);
            last_state_at = Some(now);
        }
        let mut g = shared.lock();
        if now.duration_since(last_refresh) >= BUTTON_REFRESH {
            last_refresh = now;
            let cur = g.current;
            g.history.refresh(&cur);
            g.stats.refreshes += 1;
        }
        if g.history.queued() > 0 || !g.running {
            continue;
        }
        let keepalive_at = last_state_at.map_or(now, |t| t + STATE_KEEPALIVE);
        let wake = (last_refresh + BUTTON_REFRESH).min(keepalive_at);
        let timeout = wake.saturating_duration_since(Instant::now());
        if timeout.is_zero() {
            continue;
        }
        let (_guard, _) = shared
            .cond
            .wait_timeout_while(g, timeout, |g| {
                g.running && g.history.queued() == 0 && g.current.same_as(&current)
            })
            .unwrap_or_else(|p| p.into_inner());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn idle_state_payload() {
        let p = encode_state(&ControllerState::IDLE, 12);
        assert_eq!(p.len(), 28);
        assert_eq!(p[0], 0xa0);
        assert_eq!(&p[1..7], &[0xff, 0x7f, 0xff, 0x7f, 0xff, 0x7f]);
        assert_eq!(&p[7..13], &[0xff, 0x7f, 0x99, 0x99, 0xff, 0x7f]);
        assert_eq!(&p[25..], &[0, 0, 1]);
        assert_eq!(encode_state(&ControllerState::IDLE, 9).len(), 25);
    }

    #[test]
    fn orientation_round_trip() {
        for q in [
            [0.0f32, 0.0, 0.0, 1.0],
            [0.5, -0.5, 0.5, -0.5],
            [0.1, 0.7, -0.1, 0.7],
            [-0.9, 0.3, 0.2, 0.2],
        ] {
            let n = q.iter().map(|x| x * x).sum::<f32>().sqrt();
            let q = q.map(|x| x / n);
            let v = compress_orientation(q);
            assert_eq!(v >> 30, 0);
            let r = decompress_orientation(v);
            let dot: f32 = q.iter().zip(&r).map(|(a, b)| a * b).sum();
            assert!(dot.abs() > 0.999, "{q:?} -> {r:?}");
        }
    }
}
