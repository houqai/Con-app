use super::audio::{AudioDecoder, AudioHeader};

pub struct OpusDecoder {
    inner: ::opus::Decoder,
}

impl std::fmt::Debug for OpusDecoder {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("OpusDecoder")
    }
}

fn channels(n: u8) -> Option<::opus::Channels> {
    match n {
        1 => Some(::opus::Channels::Mono),
        2 => Some(::opus::Channels::Stereo),
        _ => None,
    }
}

impl OpusDecoder {
    pub fn new(header: &AudioHeader) -> Result<Self, String> {
        let ch = channels(header.channels)
            .ok_or_else(|| format!("{} channels not supported", header.channels))?;
        let inner = ::opus::Decoder::new(header.rate, ch).map_err(|e| e.to_string())?;
        Ok(Self { inner })
    }
}

impl AudioDecoder for OpusDecoder {
    fn decode(&mut self, packet: &[u8], out: &mut [i16]) -> Result<usize, String> {
        self.inner
            .decode(packet, out, false)
            .map_err(|e| e.to_string())
    }
}

pub struct OpusEncoder {
    inner: ::opus::Encoder,
}

impl std::fmt::Debug for OpusEncoder {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("OpusEncoder")
    }
}

impl OpusEncoder {
    pub fn new(
        rate: u32,
        channel_count: u8,
        low_delay: bool,
        cbr_bitrate: Option<i32>,
    ) -> Result<Self, String> {
        let ch = channels(channel_count)
            .ok_or_else(|| format!("{channel_count} channels not supported"))?;
        let app = if low_delay {
            ::opus::Application::LowDelay
        } else {
            ::opus::Application::Audio
        };
        let mut inner = ::opus::Encoder::new(rate, ch, app).map_err(|e| e.to_string())?;
        if let Some(b) = cbr_bitrate {
            inner
                .set_bitrate(::opus::Bitrate::Bits(b))
                .map_err(|e| e.to_string())?;
            inner.set_vbr(false).map_err(|e| e.to_string())?;
        }
        Ok(Self { inner })
    }

    pub fn encode(&mut self, pcm: &[i16], max: usize) -> Result<Vec<u8>, String> {
        self.inner.encode_vec(pcm, max).map_err(|e| e.to_string())
    }
}

pub const MIC_UNIT: usize = 40;
pub const MIC_FRAME: usize = 480;

pub struct MicrophonePacker {
    encoder: OpusEncoder,
    previous: Vec<[u8; MIC_UNIT]>,
}

impl std::fmt::Debug for MicrophonePacker {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("MicrophonePacker")
    }
}

impl MicrophonePacker {
    pub fn new() -> Result<Self, String> {
        Ok(Self {
            encoder: OpusEncoder::new(48_000, 1, true, None)?,
            previous: Vec::new(),
        })
    }

    pub fn push(&mut self, pcm: &[i16]) -> Result<Option<[u8; 3 * MIC_UNIT]>, String> {
        if pcm.len() != MIC_FRAME {
            return Err(format!("{} samples, {MIC_FRAME} expected", pcm.len()));
        }
        let packet = self.encoder.encode(pcm, MIC_UNIT)?;
        let Ok(unit) = <[u8; MIC_UNIT]>::try_from(packet.as_slice()) else {
            return Ok(None);
        };
        self.previous.push(unit);
        if self.previous.len() > 3 {
            self.previous.remove(0);
        }
        if self.previous.len() < 3 {
            return Ok(None);
        }
        let mut out = [0u8; 3 * MIC_UNIT];
        out[..MIC_UNIT].copy_from_slice(&self.previous[2]);
        out[MIC_UNIT..2 * MIC_UNIT].copy_from_slice(&self.previous[0]);
        out[2 * MIC_UNIT..].copy_from_slice(&self.previous[1]);
        Ok(Some(out))
    }
}
