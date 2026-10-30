use crate::transport::packet::data_type;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum IntensityKind {
    Haptic = 0,
    Trigger = 1,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum FeedbackEvent {
    Rumble { left: u8, right: u8 },
    TriggerEffects { left: [u8; 11], right: [u8; 11] },
    LightBar { r: u8, g: u8, b: u8 },
    PlayerIndex(u8),
    EffectIntensity { kind: IntensityKind, value: u8 },
    MotionReset,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct PadInfo {
    pub sequence: Option<u16>,
    pub timestamp: Option<u32>,
    pub player_index: u8,
    pub light: [u8; 3],
    pub motion_reset: bool,
    pub haptic_intensity: u8,
    pub trigger_intensity: u8,
}

pub fn parse_pad_info(d: &[u8]) -> Option<PadInfo> {
    let (b, sequence, timestamp) = match d.len() {
        25 => (
            &d[8..],
            Some(u16::from_be_bytes([d[0], d[1]])),
            Some(u32::from_be_bytes([d[4], d[5], d[6], d[7]])),
        ),
        17 => (d, None, None),
        _ => return None,
    };
    Some(PadInfo {
        sequence,
        timestamp,
        player_index: b[0],
        light: [b[1], b[2], b[3]],
        motion_reset: b[4] != 0,
        haptic_intensity: b[12],
        trigger_intensity: b[13],
    })
}

pub fn parse_rumble(d: &[u8]) -> Option<FeedbackEvent> {
    (d.len() >= 3).then(|| FeedbackEvent::Rumble {
        left: d[1],
        right: d[2],
    })
}

pub fn parse_trigger_effects(d: &[u8]) -> Option<FeedbackEvent> {
    if d.len() < 25 {
        return None;
    }
    let mut left = [0u8; 11];
    let mut right = [0u8; 11];
    left[0] = d[1];
    left[1..].copy_from_slice(&d[5..15]);
    right[0] = d[2];
    right[1..].copy_from_slice(&d[15..25]);
    Some(FeedbackEvent::TriggerEffects { left, right })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EffectsState {
    player_index: u8,
    light: [u8; 3],
    haptic_intensity: u8,
    trigger_intensity: u8,
}

impl Default for EffectsState {
    fn default() -> Self {
        Self {
            player_index: 0,
            light: [0; 3],
            haptic_intensity: 1,
            trigger_intensity: 1,
        }
    }
}

impl EffectsState {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn on_message(&mut self, ty: u8, d: &[u8]) -> Vec<FeedbackEvent> {
        match ty {
            data_type::RUMBLE => parse_rumble(d).into_iter().collect(),
            data_type::TRIGGER_EFFECTS => parse_trigger_effects(d).into_iter().collect(),
            data_type::PAD_INFO => {
                let Some(p) = parse_pad_info(d) else {
                    return Vec::new();
                };
                let mut ev = Vec::new();
                if p.light != self.light {
                    self.light = p.light;
                    ev.push(FeedbackEvent::LightBar {
                        r: p.light[0],
                        g: p.light[1],
                        b: p.light[2],
                    });
                }
                if p.player_index != self.player_index {
                    self.player_index = p.player_index;
                    ev.push(FeedbackEvent::PlayerIndex(p.player_index));
                }
                if p.haptic_intensity != self.haptic_intensity {
                    self.haptic_intensity = p.haptic_intensity;
                    ev.push(FeedbackEvent::EffectIntensity {
                        kind: IntensityKind::Haptic,
                        value: p.haptic_intensity,
                    });
                }
                if p.trigger_intensity != self.trigger_intensity {
                    self.trigger_intensity = p.trigger_intensity;
                    ev.push(FeedbackEvent::EffectIntensity {
                        kind: IntensityKind::Trigger,
                        value: p.trigger_intensity,
                    });
                }
                if p.motion_reset {
                    ev.push(FeedbackEvent::MotionReset);
                }
                ev
            }
            _ => Vec::new(),
        }
    }
}
