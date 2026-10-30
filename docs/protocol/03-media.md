# 03 — Media and input: video, audio, FEC, controller feedback, effects, statistics

This part describes what is carried *inside* the datagram transport once a stream is running:
the audio/video datagrams the console (or cloud server) sends, how a client turns them into
decodable pictures and sound, how lost units are recovered, what the client sends back as
controller input, which effect messages come from the console, and which loss statistics the
client reports. It also lists what the engine must hand to Con's app.

Transport framing (packet base types, chunks, acknowledgements, key positions, the stream
cipher and its MAC, the cloud datagram prefix, the stream's protobuf message envelope and
channels) is in `02-transport.md`. The session request, launch parameters (resolution, bitrate,
codec request) and the control connection messages (microphone on/off etc.) are in
`01-session.md`. This file refers to those and does not repeat them.

## 0. Conventions

- Offsets are in bytes from the first byte of the datagram as the transport sees it, i.e.
  **after** any cloud datagram prefix has been removed (`02-transport.md` §2.3). Offset 0 is the
  type byte whose low nibble is the packet base type.
- "BE16/BE32" = big-endian (network order) unsigned integer; "LE16" = little-endian.
- Bit numbering: bit 0 is the least significant bit.
- "Serial comparison" of 16-bit counters means RFC 1982 arithmetic: `a` is *newer* than `b` iff
  `a ≠ b` and `(a − b) mod 65536 < 32768`. All frame, packet and sequence indices in this file
  are 16-bit and wrap.
- **Con** marks behaviour Con adds or changes relative to the reference, or that Con's app
  relies on.
- **Uncertain** marks a value or interpretation not fully established.

Packet base types used here (low nibble of byte 0):

| Value | Direction | Meaning |
|---|---|---|
| 1 | client → console | controller feedback **history** (button / trigger / touch events) |
| 2 | console → client | video unit |
| 3 | console → client; also client → console | audio or haptics unit; client→console = microphone |
| 5 | client → console | congestion (loss) report |
| 6 | client → console | controller feedback **state** (sticks, motion) |

Data messages with a non-protobuf "data type" byte (see `02-transport.md`, data chunk payload)
used here: **7** = rumble, **9** = pad info (light bar, player index, intensities, motion reset),
**11** = adaptive trigger effects. Data type **0** = protobuf.

---

## 1. The audio/video datagram

### 1.1 Protocol versions

The AV header has three variants, chosen by the transport protocol version negotiated for the
stream:

| Version | Used for |
|---|---|
| 7 | only the pre-stream network test (see `02-transport.md`); never carries media here |
| 9 | PS4 console; PS4 cloud (**Con**: PS4/PS3 cloud slots speak version 9) |
| 12 | PS5 console; PS5 cloud |

**Con:** for a cloud slot the version follows the slot's console kind (PS5 → 12, otherwise 9),
not the target negotiated with the server.

### 1.2 Header layout (versions 9 and 12)

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | bits 0–3: base type (2 = video, 3 = audio); bit 4: **extension flag** (3 extra header bytes, see below); bits 5–7: 0 seen |
| 1 | 2 | BE16 **packet index** — per media type, +1 for every datagram of that type |
| 3 | 2 | BE16 **frame index** — video: picture counter; audio: index of the first new audio frame in this datagram |
| 5 | 4 | BE32 **unit word** (bit fields differ for video and audio, §1.3) |
| 9 | 1 | **codec** byte (§1.5) |
| 10 | 4 | GMAC of the datagram (see `02-transport.md`) |
| 14 | 4 | BE32 low 32 bits of the **key position** of the payload |
| 18 | … | type-specific part (below) |

Video, from offset 18:

| Offset | Size | Field |
|---|---|---|
| 18 | 2 | BE16, meaning unknown (values such as 0x0398, 0x005e, 0x0000 seen); ignore |
| 20 | 1 | bits 5–7: **adaptive stream index** (0–7, selects the video profile, §2.1); bits 0–4 unknown (0 seen) |
| 21 | 3 | only if the extension flag is set: unknown, skipped (values like `00 00 32`, `00 20 31`, `00 40 33` seen) |
| 21 or 24 | rest | **payload** (encrypted) |

Audio, from offset 18:

| Offset | Size | Field |
|---|---|---|
| 18 | 1 | unknown; ignore |
| 19 | 3 | only if the extension flag is set: unknown, skipped |
| next | 1 | **version 12 only:** stream marker. `0x02` = this datagram belongs to the **haptics** stream; any other value = game audio |
| next | rest | **payload** (encrypted) |

**Con (diagnostics):** each stream marker value is written to the log the first time it is
seen ("audio: stream marker 0xNN seen"), to learn whether the cloud sends more streams than
game audio and haptics (for example, the DualSense's speaker).

So the payload starts at: video 21 (24 with extension); audio v9 19 (22); audio v12 20 (23).

Minimum datagram sizes accepted: video 25 bytes; audio v9 20 bytes; audio v12 21 bytes.
Shorter datagrams are dropped.

Version 7 layout (for completeness): identical bytes 0–17; video then has the same 3 bytes at
18–20 and payload at 21; audio has **no** byte at 18 and its payload starts at 18; the extension
flag adds 3 bytes in both cases. The key position field is not expanded through the key-state
tracker in version 7 (taken as is).

### 1.3 Unit word (offset 5, BE32)

Video:

| Bits | Field |
|---|---|
| 31–21 (11 bits) | **unit index** within the frame, 0-based |
| 20–10 (11 bits) | **total units in frame minus 1** (source + FEC) |
| 9–0 (10 bits) | **number of FEC units** in the frame |

Audio (and haptics, and the microphone stream):

| Bits | Field |
|---|---|
| 31–24 (8 bits) | unit index (unused by the receiver) |
| 23–16 (8 bits) | **total units in this datagram minus 1** |
| 15–8 (8 bits) | **unit size** in bytes (every unit in the datagram has this size) |
| 7–4 (4 bits) | **redundancy unit count** r ("FEC" count; these are copies of earlier frames, not parity) |
| 3–0 (4 bits) | **new (source) unit count** s |

### 1.4 Decryption and authentication of the payload

The datagram's MAC is verified as described in `02-transport.md` (MAC field zeroed during the
computation, key position field left in place). The 32-bit key position is expanded to the
64-bit stream position with the receive-side key-state tracker (`02-transport.md`). The payload
(from the payload offset in §1.2 to the end of the datagram) is decrypted with the console's
(remote) stream cipher at keystream position **key position + 16**. Header bytes are never
encrypted. AV datagrams that arrive before the remote cipher exists are held and processed once
it exists (`02-transport.md`).

### 1.5 Codec byte

| Value | Meaning |
|---|---|
| 3 | video (seen on PS4 console H.264 streams and on cloud streams) |
| 5 | Opus audio |

The video receiver does not decide the codec from this byte; the codec is the one requested at
session setup (H.264, H.265, or H.265 HDR). **Con:** on a cloud stream, a video codec byte of 3
is overwritten with the requested codec before further processing. **Uncertain:** the codec
byte values a PS5 console uses for H.265.

Audio datagrams with a codec byte other than 5 are dropped — **except haptics datagrams**,
which are accepted whatever the codec byte (**Con**).

### 1.6 Worked example (real PS4 H.264 capture)

First two datagrams of a stream, header bytes:

```
02 0000 0001 00000401 03 094223ba 00000080 0398 00 | payload 105 bytes
02 0001 0001 00200401 03 5a8b07c4 00000100 0000 00 | payload 108 bytes
```

Frame 1: unit word 0x00000401 → unit 0, total 2, FEC 1 (one source unit + one FEC unit).
Second datagram: unit 1 (the FEC unit), key position 0x100. Decrypted, the first payload begins
`00 03 00 00 00 01 65 88 …`: a 2-byte padding count of 3 (§2.3), then an Annex B start code and an
IDR slice NAL. Unit size L = 105 + 3 = 108, which is exactly the FEC unit's length.

A later datagram with the extension flag: `12 0002 0002 00004401 03 …` → frame 2, unit 0, total
18, FEC 1, payload at offset 24.

---

## 2. Video

### 2.1 Stream info: profiles and their headers

After key exchange the console sends a protobuf message of type 13 (stream info) on the data
channel (see `02-transport.md` for the envelope). Relevant fields of its stream-info payload
(envelope field 15):

| Field | Type | Meaning |
|---|---|---|
| 1 | repeated message | **resolution** entries, in profile order: field 1 width (uint32), field 2 height (uint32), field 3 **video header** (bytes) |
| 2 | bytes | **audio header**, 14 bytes (§3.1) |
| 3–6 | uint32 | start timeout, AFK timeout, AFK-disconnect timeout, congestion-control interval (not used by the client) |
| 7 | repeated message | audio channel entries (type, header, raw-PCM flag) — not used |

Each resolution entry is a **video profile**; its index in the list (0-based) is the value the
adaptive stream index field (§1.2) refers to. The client keeps at most 8 profiles. The video
header is the codec's parameter sets in Annex B form (H.264: SPS and PPS; H.265: VPS, SPS, PPS),
each preceded by a 4-byte start code.

Profiles are accepted once per session; a second stream info is ignored for video. If the
stream info has a wrong audio header length (≠ 14) the stream setup fails.

After a valid stream info the client sends, in this order on the data channel: a stream-info
acknowledgement (type 14, no payload, channel 9), a controller-connection message (type 21,
§5.5), and its own stream info announcing the microphone format (type 13 with only field 2,
§4). Then controller feedback starts (§5) and the app is told the stream is connected.

### 2.2 Profile switching

The current profile is "none" at start. For every video datagram, if no profile is current or
the datagram's adaptive stream index differs from the current one:

1. If the index is ≥ the number of profiles, the datagram is dropped.
2. Otherwise that profile becomes current, and its **video header is delivered to the app as a
   sample of its own** (no frame counted, frames-lost 0) before any frame data of that profile.
3. The header's SPS is parsed (§2.7) to learn the field widths needed for slice parsing.

The console switches profiles on its own (adaptive resolution); there is no client request
for it.

### 2.3 Frames and units

A video **frame** (one picture) is sent as `N` units: `k` **source units** with unit indices
0…k−1 and `m` **FEC units** with indices k…k+m−1, where `N` = total from the unit word and `m` =
FEC count. One unit per datagram.

Every **source unit's** payload begins with a **BE16 padding count** `p`. The unit's nominal
size is `L = (payload length) + p`; `L` is the same for every unit of the frame. The bytes after
the 2-byte count are a piece of the frame's Annex B byte stream. Units are not cut evenly: a unit
usually holds one or more whole slice NALs (each with its 4-byte start code), or the
continuation of a long slice, so source units have varying lengths and each carries its own `p`.
For FEC computation every source unit is treated as **L bytes: its payload (including the 2-byte
count) followed by `p` zero bytes**.

Every **FEC unit's** payload is exactly `L` bytes of parity (§2.5) and has no padding count.

`L` is learned from the first datagram of the frame that arrives: for a source unit `L` = payload
length + its padding count; for an FEC unit `L` = payload length. A frame is rejected if `L` = 0,
if `N` < `m`, or if `N` > 512 (receiver limit).

The **picture** is the concatenation, in unit-index order, of every source unit's payload with
its first 2 bytes removed (the padding is not part of the payload as sent; after FEC recovery the
recovered unit is cut to `L − p` bytes before removing the 2 bytes).

### 2.4 Receiving a frame

Packet order. Video datagrams are first put in a reorder buffer keyed by packet index (64
entries). It starts at the first received datagram's packet index minus its unit index (the
start of its frame). In-order datagrams are passed on immediately. If the next expected packet
index is missing while later ones are buffered, the receiver waits for it at most **16 ms**
(console) or **3 ms** (cloud, **Con** — on the way from a data centre packets practically never
overtake each other, and waiting only delays the units that would repair the loss); then it
skips directly to the oldest buffered datagram. A further gap that appears while the timer is
running inside the same run of missing packets keeps the original deadline; a new, unrelated
gap starts a new one. A datagram older than the buffer start or a duplicate is dropped; when a
datagram would not fit, the oldest entries are dropped to make room. Audio datagrams are not
reordered.

Frame state. The receiver keeps: the index of the frame currently being assembled ("current",
none at start), whether the current frame was already handed on ("flushed"), and the index of
the **last complete frame** (starts at 0).

For each video datagram (after decryption):

1. If a current frame exists and the datagram's frame index is serially **older** than it, drop
   the datagram.
2. If no current frame exists, or the frame index is **newer** than the current one:
   - push the current frame's unit statistics (§6.1);
   - if the current frame was not yet flushed, flush it now (§2.6);
   - if the new frame index is newer than last-complete + 1, send a **corrupt-frame report**
     for the range [last-complete + 1, new index − 1] (§2.8);
   - start a new frame with this index (sizes from this datagram, all slots empty).
3. Store the unit in its slot. Rejected: unit index ≥ total; empty payload; payload longer than
   `L`; a second copy of the same unit (duplicate). Source units and FEC units received are
   counted separately. Units that arrive after the frame was flushed are still counted (for
   statistics) but not used.
4. If the frame is not yet flushed and either **(source received + FEC received) ≥ k** (enough
   for recovery) or this datagram is the frame's **last unit** (unit index = N − 1), flush now.

So a frame is normally flushed as soon as its last source unit arrives (or as soon as enough
units for FEC recovery are present), without waiting for the remaining FEC units.

### 2.5 Forward error correction (exact code)

The FEC is a systematic **Cauchy Reed–Solomon erasure code over GF(2⁸)**, applied byte-wise
across units.

**Field.** GF(2⁸) with elements = bytes, addition = XOR, multiplication = polynomial
multiplication modulo the primitive polynomial **p(x) = x⁸ + x⁴ + x³ + x² + 1** (0x11D).
`1/a` is the multiplicative inverse (a ≠ 0).

**Coding matrix.** For a frame with `k` source units and `m` FEC units, the m × k matrix `C` is

  C[i][j] = 1 / ( i ⊕ (m + j) ),  i = 0…m−1, j = 0…k−1,

where `i` and `m + j` are taken as integers 0…255 and ⊕ is bitwise XOR (the denominators are never
0 because `i < m ≤ m + j`). This is the "original" Cauchy matrix with X = {0,…,m−1} and
Y = {m,…,m+k−1}. Requires k + m ≤ 256; larger frames cannot be recovered.

Examples (hex): m = 1, k = 6: row 0 = `01 8e f4 47 a7 7a` (note: m = 1 is *not* plain XOR
parity). m = 2, k = 4: row 0 = `8e f4 47 a7`, row 1 = `f4 8e a7 47`.

**Encoding** (what the server does). With D_j the j-th source unit as L bytes (§2.3, zero-padded),
FEC unit i is, for every byte position b = 0…L−1:

  P_i[b] = Σ_{j=0}^{k−1} C[i][j] · D_j[b]   (sum = XOR, product in GF(2⁸))

Units on the wire: index j < k carries D_j; index k + i carries P_i.

**Decoding.** Let G be the (k + m) × k generator matrix whose first k rows are the identity and
whose last m rows are C. Every k × k submatrix of G is invertible (Cauchy property). If at least k
of the N units of a frame are present, choose k present units (the reference picks the present
source units, then present FEC units in increasing index, but any choice gives the same
result), form the k × k matrix G_R of their rows, and compute the source units as
D = G_R⁻¹ · Y_R byte-position by byte-position (Y_R = the chosen units' L-byte contents,
missing source units' bytes unknown). If more than m units are missing, recovery fails.

This description was checked against the reference test vectors: for all 68 parity units
present in the 64 recorded frames (L = 1328…1400, k = 3…8, m = 1…4), the formula above reproduces
the parity bytes exactly.

**After recovery** each source unit's first 2 bytes give its padding count `p`; its length is set
to `L − p` (if `p ≥ L` the unit is left as it was and an error is logged). Then the picture is
assembled as in §2.3.

FEC is only attempted when fewer than k source units were received at flush time. A frame whose
FEC count field is 0 is treated as having 1 FEC unit for counting purposes (see §6.1).

### 2.6 Flush outcomes

At flush the frame ends in one of four states:

| Outcome | Condition |
|---|---|
| complete | all k source units present |
| recovered by FEC | some source units missing, recovery succeeded |
| FEC failed | some source units missing, more than m units missing (or recovery impossible) |
| failed | the frame had no valid setup (e.g. sizes were rejected) |

*Failed* — nothing is delivered; logged.

*FEC failed* — nothing is delivered. The client:

1. sends a corrupt-frame report for [last-complete + 1, this frame];
2. only if the session option "request IDR on FEC failure" is on (**Con keeps it off**; Con's app
   asks for a keyframe itself, §2.9): if not already waiting for an IDR, sends an IDR request
   (§2.8) and enters "waiting for IDR"; emits an app event "FEC failure" carrying the frame index
   and whether a request was sent;
3. adds (this frame − (last-complete + 1) + 1) to the lost-frame counters;
4. marks the frame flushed. Last-complete does **not** advance, so the next frame's start sends
   another corrupt-frame report covering the range again.

*Complete* or *recovered* — the picture goes through the reference check (§2.7) and, if it passes,
is delivered to the app (§2.9).

### 2.7 Reference tracking and reference repair

The client remembers the frame indices of the last **16 frames the app's decoder accepted**
(most recent first). Before delivering a picture it parses the header of the **first slice NAL**
of the picture (Annex B, after its start code; emulation-prevention bytes removed while
reading):

- **If waiting for an IDR:** an I slice ends the wait and the frame is delivered; any other
  frame is skipped (not delivered, marked flushed, last-complete unchanged).
- **P slice whose reference is known:** the referenced frame is `this frame − r − 1`, where r is
  the reference distance read from the slice (below). If that frame is not among the remembered
  16:
  - try older distances r' = r+1 … 15 in order; the first r' whose frame `this − r' − 1` *is*
    remembered is chosen. For **H.265 only**, the slice header is rewritten in place so that the
    picture references that frame instead ("recovered"; the app is told). For H.264 no rewrite is
    possible; the search just stops at the first remembered frame.
  - if no rewrite happened, the frame is **not delivered**, counts as one lost frame, and
    last-complete does not advance (so the next frame start reports the gap).
- I slices, unparsable slices, and slices with no known reference are delivered unchanged.

Parsing details (standard syntax element names from ITU-T H.264 / H.265):

H.264 parameter set (from the profile header, NAL type 7): profile_idc, constraint flags (6),
reserved (2), level_idc, seq_parameter_set_id; for profile_idc ∈ {100, 110, 122, 244, 44, 83, 86,
118, 128, 138, 139, 134, 135}: chroma_format_idc (if 3: separate_colour_plane_flag),
bit_depth_luma_minus8, bit_depth_chroma_minus8, qpprime flag, seq_scaling_matrix_present_flag (if
1: give up); then **log2_max_frame_num_minus4** (must be ≤ 12).

H.264 slice (NAL type 1 or 5): first_mb_in_slice; slice_type (0 or 5 → P; 2 or 7 → I; else
unknown). For NAL type 1: reference distance defaults to 0 (previous frame); pic_parameter_set_id;
frame_num (log2_max_frame_num bits); num_ref_idx_active_override_flag (if set:
num_ref_idx_l0_active_minus1); ref_pic_list_modification_flag_l0; if set, up to three
(modification_of_pic_nums_idc, value) pairs are read until idc = 3: for idc 0 the value
abs_diff_pic_num_minus1 is the reference distance r; idc 1 or 2 values are skipped. The parse
assumes frame-only coding, picture order count type 2, and no other optional fields before these
(true for the console's streams). **Uncertain:** the reference reads one extra bit after a set
num_ref_idx_active_override_flag; the console's streams are believed never to set it.

H.265 parameter set (NAL type 33; a VPS, type 32, before it is skipped): sps_video_parameter_set_id
(4), sps_max_sub_layers_minus1 (3), temporal_id_nesting (1), then a one-layer profile_tier_level
(2+1+5+32+4+43+1+8 bits), sps_seq_parameter_set_id, chroma_format_idc (if 3: separate colour plane
flag), pic width, pic height, conformance_window_flag (+4 offsets), bit depths (2 × ue), then
**log2_max_pic_order_cnt_lsb_minus4** (must be ≤ 12). Assumes sps_max_sub_layers_minus1 = 0.

H.265 slice (NAL type 1 = TRAIL_R, or 20 = IDR_N_LP): first_slice_segment_in_pic_flag; for IDR
no_output_of_prior_pics_flag; slice_pic_parameter_set_id; (slice_segment_address if not first —
does not happen for the first slice); slice_type (1 → P, 2 → I). For NAL type 1:
slice_pic_order_cnt_lsb; short_term_ref_pic_set_sps_flag; if 0, an explicit short-term RPS:
num_negative_pics (≤ 16), num_positive_pics, then for each negative picture i:
delta_poc_s0_minus1[i], used_by_curr_pic_s0_flag[i]. The **reference distance r is the first i
whose used flag is 1** (none → "unknown"). Assumes no extra slice header bits and no inter-RPS
prediction (the console's SPS has no short-term RPS sets) and a POC step of one per frame.

H.265 **reference rewrite** to distance r': walk the same explicit RPS; for every negative picture
i < r' clear its used_by_curr_pic_s0_flag bit to 0, and set the flag of i = r' to 1, overwriting
the bits in place in the NAL bytes; flags after r' are left alone. The slice length does not
change. **Uncertain:** flipping a bit could in principle create or destroy an emulation-prevention
pattern; this is not handled.

### 2.8 Messages the client sends about video

Both are protobuf messages on the data channel (envelope and channels: `02-transport.md`):

| Message | Envelope type | Payload | Channel | When |
|---|---|---|---|---|
| corrupt-frame report | 5 | envelope field 6: { field 1 start (uint32), field 2 end (uint32) } — inclusive range of frame indices | 2 | missing/corrupt frames detected (§2.4, §2.6) |
| IDR (keyframe) request | 25 | none | 2 | FEC failure with the option on, or **on the app's request** (Con's app) |

The server answers a corrupt-frame report by sending later frames that reference only frames it
believes the client has (or an IDR). The console may also send a corrupt-frame message (type 5)
itself; the client only logs it.

Other video-related messages from the console: type 16 "connection quality" (envelope field 17:
target bitrate, upstream bitrate, upstream loss, disable-upstream-audio, RTT, loss) — logged; on
its arrival the client recomputes its measured video bitrate (§6.4). Type 3 heartbeat: the client
sends one every **1 s** (channel 1).

### 2.9 What is delivered to the app

Per picture: the Annex B bytes (start codes included; the buffer has ≥ 64 zero bytes of padding
after the end), the number of frames lost since the previous delivery (reset to 0 after each
delivery), and whether the picture was "recovered" by a reference rewrite. **Con:** the app also
needs the picture's 16-bit **frame index**; the profile header is delivered as its own sample
(Con's app tags it as "parameter sets", frame −1 before the first frame).

The app returns whether its decoder **accepted** the picture. Only accepted pictures are added to
the remembered references and advance last-complete; a rejected picture therefore triggers a
corrupt-frame report at the next frame start. **Con:** Con's app decodes synchronously and returns
the real decoder result; when the decoder fails it requests a keyframe (no more than once every
2 s).

Counters kept: lost frames since last delivery, total lost frames.

---

## 3. Audio

### 3.1 Audio header (14 bytes, in stream info field 2)

| Offset | Size | Field | Typical |
|---|---|---|---|
| 0 | 1 | channels | 2 |
| 1 | 1 | bits per sample | 16 |
| 2 | 4 | BE32 sample rate (Hz) | 48000 |
| 6 | 4 | BE32 **frame size** — samples per channel in one Opus frame | 480 (10 ms) |
| 10 | 4 | BE32 unknown | 1 |

**Uncertain:** the typical values are from the client's own microphone header and Con's logs,
not a full survey of consoles. The Opus decoder is created with this rate and channel count and
decodes at most "frame size" samples per channel per frame; output is interleaved signed 16-bit
PCM. When a stream info arrives the audio receiver is reset (buffers emptied, playback restarts).

### 3.2 Packed audio datagrams (console PS4/PS5; PS4 cloud)

A datagram carries `s` **new** frames and `r` **redundant** copies of earlier frames, each exactly
"unit size" bytes (§1.3), payload = `(s + r) × unit size`:

| Unit position u | Frame index |
|---|---|
| 0 … s−1 | F + u (new frames) |
| s … s+r−1 | F − r + (u − s) (copies of the r frames before F) |

with F = the datagram's frame index. Each unit is one Opus packet. Checks (datagram dropped if
any fails): payload not empty; `s + r` = total units (from the unit word); payload length =
unit size × total.

Startup rule: until a datagram with frame index > 32768 has been seen, redundant units whose
frame index would be < 1 are skipped (nothing exists before the first frame; streams start at
frame index 1).

Every unit is offered to the jitter buffer (§3.4) with its frame index; duplicates and frames
already played are discarded there, so a lost datagram's frames are filled in from the copies
in the following datagrams.

For statistics each packed datagram counts once, with its frame index F (§6.1).

Example (from Con's test for PS4 cloud): unit word low half `0x5021` → unit size 0x50 = 80 bytes,
r = 2, s = 1; payload 240 bytes = [frame n][frame n−2][frame n−1].

**Con:** PS4 cloud streams use this packed format too. Decoding the whole 240-byte payload as
one Opus packet "succeeds" but plays garbage.

### 3.3 Single-unit audio (PS5 cloud) — **Con**

A PS5 cloud server sends **one Opus frame per datagram** (the whole payload is the frame; the
s/r/size fields are not used). Datagrams come in groups of "total units" datagrams whose frame
indices overlap with the next group, so every frame is sent three times, byte-identical. The
client takes a frame from the first datagram that brings a frame index **newer** than the newest
taken so far and drops all others (including late copies of older frames). Empty payloads are
ignored. **Con (loss counting):** each frame is counted **once**, when taken, with its frame index
(§6.1); counting all three copies made the statistics report every frame as lost.

**Uncertain:** the exact group structure; it is described from observation.

### 3.4 Jitter buffer and loss concealment (game audio only)

Eight slots, each holding (frame index, Opus bytes). Rules:

- A frame older than the next frame to play, or one already buffered, is discarded.
- If all slots are full: if the new frame is older than the newest buffered, the newest is evicted
  to make room; otherwise the new frame is discarded.
- Playback starts once **3** frames are buffered; the first frame played is the oldest buffered.
- After every arrival the buffer plays as many frames as it can, in order:
  - if the next frame is buffered, it is decoded and played;
  - else, if a newer frame is buffered and either fewer than 3 frames are buffered, or the newest
    buffered frame is at least 3 ahead of the next one, the missing frame is **concealed**: an
    empty frame is given to the decoder (Opus packet-loss concealment produces "frame size"
    samples), and the next index advances;
  - otherwise it waits.

### 3.5 Haptics stream (version 12; DualSense)

Datagrams of base type 3 whose stream marker byte (§1.2) is `0x02` belong to the haptics stream,
handled by a separate receiver with its own state; they are never counted in the statistics.
They are processed even when game audio is disabled.

**Payload content:** raw PCM, not Opus: interleaved **2-channel signed 16-bit little-endian**
samples (left actuator, right actuator). **Con** plays them as 3000 Hz samples (it up-samples ×16
to 48 kHz for the DualSense's USB audio channels 3 and 4). Typical unit: 120 bytes = 30 sample
pairs = 10 ms. **Uncertain:** the sample rate is not signalled anywhere; 3000 Hz is the value Con
uses.

**Console haptics** use the packed layout of §3.2 (new units, then redundant copies). Each unit is
handed to the app if it is the first haptics frame of the stream or its frame index is newer than
the last one handed over; otherwise dropped. No jitter buffer. Note: because new units come first
in the datagram, redundant copies (older) are always dropped on this path.

**PS5 cloud haptics (Con):** also packed (new units first, then copies of the r frames before), but
the client hands over the **copies first, oldest first, then the new units**, each once by frame
index, so the copies fill in for lost datagrams. Checks: unit size ≠ 0, s ≠ 0, payload =
unit size × (s + r). Startup rule as in §3.2.

**Con:** the first haptics frame is always delivered (in the reference a stream whose first
haptics index is not "newer than 0" loses its haptics), and haptics datagrams bypass the
codec-5 check.

App side (**Con**): the app accepts frames of 1–4096 bytes whose length is a multiple of 4.

---

## 4. Microphone (client → console)

Con's app does not send microphone audio; the engine implements the format below, which is the
format the reference implements.

1. The client announces its format with a protobuf type 13 (stream info) whose only content is
   field 2 = 14-byte audio header `01 10 0000BB80 000001E0 00000001` (1 channel, 16 bits, 48000 Hz,
   480 samples, unknown = 1). **Uncertain:** `02-transport.md` §11.5 gives the last word as
   `00000000`; the engine sends 02's bytes (QUESTIONS.md, question 14). This is sent automatically after the console's stream info (§2.1).
2. The microphone is connected and (un)muted with control-connection messages (`01-session.md`).
3. Audio: 48 kHz mono, 10 ms frames (480 samples), Opus in restricted-low-delay mode with a
   **40-byte** output limit; only frames that encode to exactly 40 bytes are sent (silent frames
   encode to ~3 bytes and are skipped).

Datagram (client → console, base type 3):

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | 0x03 |
| 1 | 2 | BE16 packet index: own counter, starts at 0, +1 per datagram |
| 3 | 2 | BE16 frame index = packet index + 1 |
| 5 | 4 | BE32 unit word = `0x02002821`: unit index 0, total 3, unit size 40, r = 2, s = 1. **Uncertain:** `02-transport.md` §6.4 gives `0x00022821`, which the engine sends (QUESTIONS.md, question 11) |
| 9 | 1 | codec 5 |
| 10 | 4 | GMAC |
| 14 | 4 | BE32 key position |
| 18 | 1 | 0 |
| 19 | 1 | **PS5 only:** 0 |
| 19 / 20 | 120 | payload: 3 units × 40 bytes, encrypted |

Encryption: advance the local key position by (payload length + 16), encrypt the payload with the
local stream cipher at key position + 16, write the key position, compute the GMAC over the whole
datagram with the MAC field zero (`02-transport.md`).

Unit content: by the layout of §3.2 the units should be [frame F][frame F−2][frame F−1]. The
reference fills them as [newest][previous][newest] and starts sending only from the third encoded
frame; consoles accept that. **Uncertain:** whether consoles use the redundant units at all.

---

## 5. Controller input (client → console)

Input goes as two kinds of datagrams: **feedback state** (continuous values: sticks, motion) and
**feedback history** (discrete events: buttons, analog triggers, touchpad), both unreliable,
encrypted, with their own 16-bit sequence counters.

### 5.1 Common header (12 bytes)

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | base type: 6 = state, 1 = history |
| 1 | 2 | BE16 sequence number (separate counters for state and for history; start 0, +1 per datagram) |
| 3 | 1 | 0 |
| 4 | 4 | BE32 key position |
| 8 | 4 | GMAC |
| 12 | … | payload (encrypted) |

Sending: advance the local key position by (payload length + 16); encrypt the payload at key
position + 16; write the key position; GMAC over the whole datagram with the MAC field zero, keyed
at the key position. Access to the local cipher is serialized with all other client sends.

### 5.2 Feedback state payload

Version 9: 25 bytes; version 12: 28 bytes.

| Offset | Size | Field | Encoding |
|---|---|---|---|
| 0 | 1 | constant 0xA0 | |
| 1 | 2 | gyro X | LE16, see below |
| 3 | 2 | gyro Y | LE16 |
| 5 | 2 | gyro Z | LE16 |
| 7 | 2 | accel X | LE16 |
| 9 | 2 | accel Y | LE16 |
| 11 | 2 | accel Z | LE16 |
| 13 | 4 | orientation | LE32, compressed quaternion |
| 17 | 2 | left stick X | **BE16**, signed |
| 19 | 2 | left stick Y | BE16, signed |
| 21 | 2 | right stick X | BE16, signed |
| 23 | 2 | right stick Y | BE16, signed |
| 25 | 3 | **v12 only:** `00 00 01` | |

Gyro: angular rate in **rad/s**, range −30…+30: value = trunc(65535 × (g + 30) / 60).
Accel: acceleration in units of **g** (gravity included), range −5…+5:
value = trunc(65535 × (a + 5) / 10). The reference does not clamp; an implementation should clamp to
the range. At rest, flat: accel = (0, 1, 0) (the idle state uses exactly this), gyro = 0.

Sticks: signed 16-bit, −32768…32767, 0 = centre; **X positive = right, Y positive = down**
(Con's app passes up as negative). Each stick axis is a two's complement BE16.

Orientation: a unit quaternion (x, y, z, w) compressed to 32 bits:

- Let L be the index (0 = x, 1 = y, 2 = z, 3 = w) of the component with the largest absolute value
  (first one on ties).
- Bit 0 = 1 if that component is negative, else 0. Bits 1–2 = L.
- The other three components, in x, y, z, w order skipping L, are stored at bits 3–11, 12–20,
  21–29 (9 bits each): clamp v to [−1/√2, +1/√2], then store trunc((v + 1/√2) × 511 / √2).
- Bits 30–31 = 0.

The receiver reconstructs the largest as √(1 − Σ others²) with the sign from bit 0.
Idle orientation is (0, 0, 0, 1). **Con:** Con sends the controller's attitude **relative to the
attitude at the last motion reset** (§6.2): q_sent = q_start⁻¹ ⊗ q_now.

### 5.3 Feedback history payload: events

The payload is a list of variable-length events, **newest first**, concatenated (max 0x300 bytes).

Button event, 3 bytes, for buttons with a value: `80 <code> <value>`, value 0x00 = released,
0xFF = pressed, L2/R2 0…255 analog.

| Code | Button |
|---|---|
| 0x80 | D-pad up |
| 0x81 | D-pad down |
| 0x82 | D-pad left |
| 0x83 | D-pad right |
| 0x84 | L1 |
| 0x85 | R1 |
| 0x86 | L2 (analog value) |
| 0x87 | R2 (analog value) |
| 0x88 | Cross |
| 0x89 | Circle |
| 0x8A | Square |
| 0x8B | Triangle |

Button event, 2 bytes, for buttons without a value: `80 <code>` where the code carries the state
(pressed = released + 0x20):

| Released | Pressed | Button |
|---|---|---|
| 0x8C | 0xAC | Options |
| 0x8D | 0xAD | Share / Create |
| 0x8E | 0xAE | PS |
| 0x8F | 0xAF | L3 |
| 0x90 | 0xB0 | R3 |
| 0x91 | 0xB1 | Touchpad click |

Touch event, 5 bytes:

| Byte | Content |
|---|---|
| 0 | 0xD0 = finger down / moved; 0xC0 = finger lifted |
| 1 | touch id, 0…127 (bit 7 = 0) |
| 2 | x bits 11–4 |
| 3 | bits 7–4: x bits 3–0; bits 3–0: y bits 11–8 |
| 4 | y bits 7–0 |

Coordinates: x 0…1919, y 0…942 (DualShock 4 touchpad grid). **Con / Uncertain:** Con maps the
touchpad to y 0…1079; whether consoles clamp or scale y above 942 is not established. Touch ids
are allotted by the client from a counter that wraps at 128; at most two touches at once.

Events are derived from the difference between the previous and the new controller state:

- For each of the two touch slots: if the touch id changed and the old touch was active →
  a lift event with the old id and old position; otherwise if a touch is active and (new id, or
  moved) → a down/move event with the new position.
- For each of the 16 digital buttons whose state changed → its button event.
- L2 changed → L2 event with the new value; R2 changed → R2 event.

Events are pushed in that order into a ring of the most recent events (64 entries, **Con**;
reference 16), newest first. When new events were pushed, the ring's current contents (all of them) are
formatted into one history payload and queued (queue of 64 payloads); after formatting, the ring
is cut to its **32** newest events (**Con**; reference 4), so each payload repeats up to 32 earlier
events. This repetition is the loss protection: the console applies events by value, so repeats
are harmless.

### 5.4 Sending schedule

A sender thread runs from the moment the console's stream info has been processed until the
stream ends. State: the last state sent in a feedback-state datagram, the time of the last
feedback-state datagram, the time of the last button refresh.

- The app sets a new controller state at any time. If it equals the current one (all fields; float
  fields within 1e−7), nothing happens. Otherwise history events are derived and queued
  immediately (§5.3) and the thread is woken.
- The thread sends **one** queued history payload per pass; while payloads are queued it does not
  wait.
- A feedback-state datagram is sent when the state changed in sticks or motion (gyro, accel,
  orientation — buttons alone do not cause one), and in any case when **200 ms** have passed since
  the last one (keep-alive).
- **Con (input refresh):** at least every **100 ms** the thread wakes up (wait timeout 100 ms, or
  less if the 200 ms keep-alive is due sooner); whenever ≥ 100 ms have passed since the last
  refresh it pushes a fresh event for **every** digital button (all 16) and for L2 and R2, each with
  its **current** value, and queues a history payload. Reason: UDP may lose the final "released"
  event and no later input would resend it — a key stuck pressed.

The reference never enforces a minimum interval between two state datagrams (8 ms was
intended).

### 5.5 Controller connection message

Sent once after the stream info (§2.1): protobuf type 21 with envelope field 22 = { field 2
connected = true, field 3 controller type = 6 (DualSense) if DualSense features are enabled for
the session, else 2 (DualShock 4) }; controller id not set. Channel 1. **Con** enables DualSense for
console sessions and for PS5 cloud slots, not for PS4/PS3 cloud slots.

Other controller types in the enumeration: 0 not set, 1 DualShock 3, 3 Vita, 4 XInput, 5 mobile,
7 VR2 Sense.

---

## 6. Feedback from the console

### 6.1 Rumble — data type 7

Payload ≥ 3 bytes: byte 0 unknown; byte 1 = left / low-frequency (heavy) motor 0…255; byte 2 =
right / high-frequency (light) motor 0…255. Each message is a new absolute setting. Delivered to
the app as (left, right). **Con:** the app halves the values for the DualSense's motor fields and
drops rumble when the user turned vibration off.

### 6.2 Pad info — data type 9

Two sizes. The 25-byte form is an 8-byte prefix followed by the 17-byte form.

25-byte form:

| Offset | Size | Field |
|---|---|---|
| 0 | 2 | BE16 sequence number of the client feedback datagram this answers (**Uncertain** which counter) |
| 2 | 2 | unknown |
| 4 | 4 | BE32 timestamp, believed seconds since stream start (**Uncertain**; the reference reads it wrongly) |
| 8 | 1 | player index |
| 9 | 3 | light bar red, green, blue |
| 12 | 1 | motion reset request (non-zero = reset) |
| 13 | 7 | unknown |
| 20 | 1 | haptic (vibration) intensity |
| 21 | 1 | adaptive trigger intensity |
| 22 | 3 | unknown |

17-byte form: same fields shifted by −8 (player index at 0, RGB at 1–3, motion reset at 4,
intensities at 12 and 13). Any other size is ignored.

Intensity values (the player's console setting): **0 = off, 1 = strong, 2 = medium, 3 = weak**.

The client keeps the last values (initially: player index 0, light 0/0/0, both intensities 1) and
emits an app event only when a value **changes**: light colour, player index, haptic intensity,
trigger intensity. A motion reset request emits a "motion reset" event **every time** the flag is
set. **Con:** on motion reset the app records the current attitude as the new origin (§5.2).

App mapping (**Con**, for reference): DualSense player LEDs 1→0x04, 2→0x0A, 3→0x15, 4→0x1B, 5→0x1F,
0 → all off; a black light bar is replaced by Con's own colour (cloud servers send black).

### 6.3 Adaptive trigger effects — data type 11

Payload ≥ 25 bytes:

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | unknown |
| 1 | 1 | left (L2) effect mode |
| 2 | 1 | right (R2) effect mode |
| 3 | 2 | unknown |
| 5 | 10 | left effect parameters |
| 15 | 10 | right effect parameters |

Mode + 10 parameters are in the DualSense's native trigger-effect encoding (the 11-byte block of a
DualSense output report, e.g. mode 0x05 = off). Delivered to the app as two 11-byte blocks
[mode, params…]; **Con** writes them unchanged into the DualSense output report (right trigger
block, then left).

### 6.4 Haptics

See §3.5 (PCM over the audio stream, not a data message).

---

## 7. Statistics and loss reports

### 7.1 What is counted

Two kinds of counts are accumulated between reports:

**Unit counts (video).** When a video frame is closed (at the arrival of the first datagram of the
next frame), the frame contributes received = source units + FEC units received (including those
received after flushing) and expected = k + max(m, 1); lost = expected − received. A frame of
which no datagram arrived contributes nothing.

**Sequence counts (audio).** Each counted audio datagram (console/PS4-cloud: each packed datagram;
PS5 cloud: each frame when taken, §3.3) records its frame index: the count of received items goes
up by one and the newest index seen is updated (serial comparison). At a reading, the span is
(newest − newest-at-last-reading) mod 65536; lost = span − received if received ≤ span, else
**0** (more items than numbers means duplicates or late arrivals, not loss). **Con:** the span
is taken modulo 2¹⁶ (across wrap), surplus is reported as 0 (the reference reports it as a loss
of the whole range), and at the very first counted item the "newest-at-last-reading" is set to
that index − 1, so nothing counts as lost before the stream's first packet (the reference starts
at 0 and reports the whole initial gap as lost).

Haptics are not counted.

### 7.2 Congestion report (base type 5), every 200 ms

Every **200 ms** the client reads and resets both counts and sends:

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | 0x05 |
| 1 | 2 | BE16 0 |
| 3 | 2 | BE16 **received** |
| 5 | 2 | BE16 **lost** |
| 7 | 4 | GMAC |
| 11 | 4 | BE32 key position |

Total 15 bytes. Key position advanced by 15; the GMAC is computed with both the MAC field and the
key-position field zeroed, then the key position is written (`02-transport.md`).

Values: total = received + lost (unit counts + sequence counts);
reported-lost = min(lost × **margin**, floor(total × **limit**)); reported-received = total −
reported-lost; both truncated to 16 bits.

- **margin** = 1 for consoles, **3 for cloud** (**Con**: a cloud server sizes each
  frame's FEC for the average loss rate as if losses were independent; losses come in runs, so the
  loss is reported three times over).
- **limit** = the session's maximum reported loss share. **Con:** 0.04 for consoles and PS5 cloud,
  **0.02 for PS4/PS3 cloud** slots (those servers react as a switch: below an average of ~1.8 %
  they send one or two FEC units per frame, above it about fifty, which swamps the picture). With 0
  every report says "nothing lost". Con's observed PS5 cloud reaction: 1 FEC unit at 0 % reported
  loss, ~2.5 at 0.9 %, ~4.6 at 3.4 %, ~5.5 at 4.4 %; around 20 % the stream drops to 640×360.

### 7.3 Round trip (**Con**)

The transport measures, for each reliable data message, the time from its first sending to its
acknowledgement (messages that exhausted all resends are not measured), and keeps the latest value
in microseconds and a count of measurements (`02-transport.md`). The app reads both at any time
(heartbeats once a second keep it fresh).

### 7.4 Measured bitrate

The client counts bytes of assembled pictures and pictures; bitrate = bytes × 8 × max-fps /
pictures (max-fps from the requested profile), reset whenever a connection-quality message
arrives. Informational only.

---

## 8. What the engine must give Con's app

From Con's Swift engine wrapper (`Sources/SoleEngine`) and its users.

Inputs from the app:

| Input | Notes |
|---|---|
| connection parameters | console (host, registration secrets, PSN account id) or cloud slot (host, port, datagram prefix byte, launch specification, session id, 16-byte handshake key, MTU in/out, RTT); PS4/PS5 kind; video profile (height 360/540/720/1080, 30/60 fps; codec H.264 for console and PS4 cloud, H.265 for PS5 cloud); max reported loss (§7.2); DualSense on/off |
| controller state | 16 button bits, L2/R2 0–255, four stick axes (signed 16-bit, Y down), up to two touches (id or none, x, y), gyro (rad/s), accel (g), orientation quaternion. Button bit order used by Con's app: 0 Cross, 1 Circle, 2 Square, 3 Triangle, 4 Left, 5 Right, 6 Up, 7 Down, 8 L1, 9 R1, 10 L3, 11 R3, 12 Options, 13 Share, 14 Touchpad, 15 PS |
| keyframe request | send an IDR request now; may be called from inside the video callback |
| login PIN | console login confirmation (`01-session.md`) |
| start / stop | stop sends the disconnect message and ends all threads |

Outputs to the app:

| Output | Content |
|---|---|
| video sample | Annex B buffer (profile headers as separate samples), 16-bit frame index, frames lost since last sample, recovered flag; returns accepted / not accepted (§2.9) |
| audio | decoded PCM: interleaved int16, channel count (1–8), sample rate (8000–192000), ≤ 5760 frames per call. The engine decodes Opus with libopus, or with decoding off hands over the Opus packets with the header values. Concealed frames arrive as PLC output |
| event: connected | stream info processed, input running |
| event: rumble | left, right |
| event: trigger effects | left 11 bytes, right 11 bytes (mode + 10 parameters) |
| event: light bar | R, G, B |
| event: player index | 0…n |
| event: haptics | PCM bytes (§3.5), on any thread; the app re-dispatches |
| event: effect intensity | which (haptic or trigger), value 0–3 |
| event: motion reset | — |
| event: login PIN required | whether the previous PIN was wrong |
| event: quit | reason text and whether it is an error (normal stop and "remote shut down" are not errors) |
| round trip | latest RTT in µs and number of measurements (§7.3) |
| log lines | free text. **Con:** the app picks out media diagnostics by the beginning of certain log lines (audio header lines, Opus decoder messages, audio datagram size errors, "cloud audio" line); the engine keeps these lines under the prefixes `audio header:` and `audio: `. Logs must never contain keys, payloads or launch specifications |

Events are emitted from engine threads; the app moves them to its main thread.

---

## 9. Constants

| Constant | Value |
|---|---|
| video reorder buffer | 64 datagrams |
| reorder wait for a missing video datagram | 16 ms console, 3 ms cloud (**Con**) |
| max units per video frame accepted | 512 (FEC needs k + m ≤ 256) |
| video profiles max | 8 |
| remembered reference frames | 16 |
| profile header padding | ≥ 64 zero bytes after delivered buffers |
| FEC field | GF(2⁸), polynomial 0x11D |
| audio header size | 14 bytes |
| audio jitter buffer | 8 slots, playback after 3 |
| audio startup threshold | frame index > 32768 ends the startup rule |
| microphone | 48 kHz mono, 480-sample frames, 40-byte Opus units, 3 units/datagram |
| feedback state payload | 25 bytes (v9), 28 bytes (v12), first byte 0xA0 |
| feedback state keep-alive | 200 ms |
| button refresh (**Con**) | 100 ms |
| history ring / repeat count | 64 / 32 (**Con**; reference 16 / 4) |
| history payload max | 0x300 bytes; queue 64 payloads |
| gyro range / accel range | ±30 rad/s / ±5 g |
| touch range | x 0–1919, y 0–942 |
| congestion report interval | 200 ms |
| cloud loss margin (**Con**) | ×3 |
| reported loss limit (**Con**) | 0.04; 0.02 for PS4/PS3 cloud |
| heartbeat | every 1 s |
| stream setup step timeout | 5 s |

---

## 10. Open points

- Meaning of video header bytes 18–19, the low 5 bits of byte 20, the 3 extension bytes, and audio
  byte 18.
- Video codec byte values on PS5 consoles (3 seen on PS4 and cloud).
- Whether the haptics sample rate is always 3000 Hz.
- The exact group pattern of PS5 cloud audio (§3.3).
- Which client counter the pad-info sequence number refers to, and the timestamp unit.
- Touchpad y range above 942 (Con sends up to 1079).
- Whether consoles use the microphone's redundant units, and the "correct" content order.
- H.265 reference rewrite and emulation-prevention bytes (§2.7).
