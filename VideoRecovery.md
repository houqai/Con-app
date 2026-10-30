# Video after frame loss

This document is self-contained: it can be read without the others. It describes why the PS Cloud stream froze after packet loss, how Con handles it and what remains unverified.

After a loss the engine (`Engine/`, Rust) repairs the frames' references to reference pictures and hands over frames with wrong content marked "decode only": Con decodes them on all systems and does not show them, so the picture holds for about 150 ms until the server's recovery frame, without corruption and without waiting for a key frame. `PictureOrderBridge` (shared code) makes the recovery frame decodable, and `PresentationClock` lays the decoded pictures out on an even schedule.

## Symptom

Without the bridge, during a cloud game the picture froze for about 1.2 seconds after every packet loss, and the number of decoder errors in the overlay grew (VideoToolbox, code −12909, `kVTVideoDecoderBadDataErr`). With a datacenter about 100 ms away, the freeze happened on every loss.

## How the Sony stream is built

Profile 1280×720, HEVC, one slice per frame, 60 frames per second. From the sequence parameter set (SPS):

| Field | Value |
| --- | --- |
| `log2_max_pic_order_cnt_lsb` | 4 — the picture number is sent in four bits, a cycle of 16 frames |
| `sps_max_dec_pic_buffering` | 4 |
| `num_short_term_ref_pic_sets` | 0 — the reference picture set is written in every slice header |
| `long_term_ref_pics_present_flag` | 1 |
| `num_long_term_ref_pics_sps` | 0 |

From the PPS: there are no dependent slices, `output_flag_present_flag` = 0, `num_extra_slice_header_bits` = 0. So in the slice header the picture number starts at the fifth bit of the payload.

Slice headers as the server sends them (first bytes of the NAL):

| Frame | Bytes | Number | Short-term entry | Long-term entries |
| --- | --- | --- | --- | --- |
| Regular | `0201d29760e1…` | 5 | previous frame, used | two, not used: (0, cycle 0), (8, cycle +1) |
| Recovery | `0201d01641a6…` | 0 | previous frame, not used | one, used: (0, cycle 1) |

Each long-term entry has `delta_poc_msb_present_flag` = 1 and a cycle count `delta_poc_msb_cycle_lt`. Per the standard, the entries' cycles add up along the list: the second entry "(8, cycle +1)" means "one cycle further than the first".

Server behaviour:

- A regular frame is built on the previous one. The server keeps up to two long-term pictures in reserve and refreshes them every 8–12 frames.
- After the client reports a loss, the server sends recovery frames: each is built only on a long-term picture that the client definitely received.
- After a few frames the server returns to regular frames on its own.
- A key frame (IDR) arrives about 1.2 seconds after the client's request. Sometimes the server sends one without a request.

## Cause

The decoder reconstructs the full picture number from the low bits and from the previous decoded picture. This works as long as fewer than half a cycle, that is fewer than 8 frames, are skipped.

The loss report reaches the server within the ping time, so at about 100 ms 9–12 frames are lost before the recovery frame. The decoder does not notice the wrap through the cycle and gives the frame a number 16 lower than the real one. It counts the entry "long-term picture one cycle back" from this wrong number, does not find the picture and rejects the frame. All following recovery frames reference the same picture and are rejected the same way, until the key frame.

Example from a capture: the last decoded frame is number 37 (low bits 5). Frames 38–47 are lost. The recovery frame is number 48 (low bits 0), referencing picture 32. The decoder thinks this is frame 32 and looks for picture 16.

The loss counter the engine passes to the video handler (`framesLost`) is not enough to compute the real number: the exact gap is the difference of the frame counters the engine passes with every frame.

## The picture number bridge

[Sources/SoleCore/PictureOrderBridge.swift](Sources/SoleCore/PictureOrderBridge.swift) (shared code) is called from `VideoPipeline.submit` before decoding each HEVC frame.

1. The bridge keeps a model: the number of the last decoded picture, its frame counter and the set of pictures the decoder holds as references. The set is updated from the list in each header, as the decoder does.
2. The real number of a new frame is the previous number plus the difference of the frame counters. The low bits must match the header; if they do not, the bridge stops intervening until the next key frame.
3. If the decoder would get the same number on its own, the frame goes through as is. All consecutive frames pass this way.
4. If the numbers differ and the frame references a long-term picture with a cycle given, the bridge makes copies of the frame with intermediate numbers — in steps of 8, until 8 or less remain to the real number. The copies are decoded before the frame, and their pictures are not shown. After them the decoder computes the number correctly.
5. Only header bits change in a copy: the picture number and the cycle count of the first long-term entry. The cycle count becomes shorter, and the freed bits go into the distance of the unused short-term entry. The header length does not change, and everything after it stays in place. Before writing, the bridge checks that the original header reads and writes back bit for bit.
6. If a frame references a picture that the decoder does not have according to the model, it is not decoded at all: otherwise the decoder could build it on another picture with the same low bits. Then, as with any decoder failure, Con requests a key frame.

Example of a copy for a frame from a capture: `0201d01641a6…` → `0201d6951076…`: number 13 instead of 0, cycle 0 instead of 1, short-term entry distance 2 instead of 1.

The bridge does not intervene if: the frame has several slices; the NAL type is not TRAIL_R of the base layer; the SPS has reference picture sets, long-term pictures or scaling lists; the frame counter was not passed; after a decoder failure until the next key frame. A gap longer than 72 frames is not covered (more than eight copies).

[Sources/SoleMedia/VideoPipeline.swift](Sources/SoleMedia/VideoPipeline.swift) decodes the copies and the frame synchronously and counts `bridgedLosses`; the overlay shows this number in the "Losses" line. The engine's UDP receive buffer for the cloud is 4 MB: with 102 KB, frames are lost while the decoder is starting.

## Verification

Captures. During a live stream, frames around four losses were saved: the chain from the key frame, the rejected frame and up to 90 following ones. The same bytes were fed to VideoToolbox by a separate program and through `VideoPipeline`:

| Capture | Rejected without bridge | Rejected with bridge |
| --- | --- | --- |
| 1 | 1 | 0 |
| 2 | 10 | 0 |
| 3 | 66 | 0 |
| 4 | 61 | 0 |

The picture of the copy and the picture of the frame itself match exactly. The last frame before the key frame, decoded through the bridge, matches the key frame after it by eye.

Live stream (56 seconds, 3240 frames): one real loss (counter 177 → 189) and three artificial ones. All four were covered, decoder errors 0. The recovery frame arrived 150–185 ms after the loss; the requested key frame came about 1.2 s later, already without the picture stopping. Decoding the copy and the frame together took 5–6 ms against the usual 2.6 ms per frame.

Tests: `Tests/SoleCoreTests/PictureOrderBridgeTests.swift`. The parameter sets and headers are real; the slice data is synthetic: the bridge reads and rewrites only headers.

The captures contain game frames and are not part of the repository.

## Not verified and open questions

- Only the 1280×720 profile. It is unknown how Sony encodes 1080p and above: if a frame is split into slices, the bridge will not intervene and recovery through the key frame will remain.
- The relation "frame counter +1 = picture number +1" is derived from observation. It is checked against the low bits on every frame, but an error of exactly one cycle is not caught by this check; it is caught by the check that the reference picture is present in the decoder.
- The behaviour of VideoToolbox after a rejected frame is unknown: whether its internal last picture number changes. So after any failure the bridge waits for a key frame.
- The bridge relies on the VideoToolbox decoder following the standard at a step of exactly half a cycle. Both branches (with a wrap through the cycle and without) occurred in the captures and passed.
- Console Remote Play has not been tested through this path; whether consoles use long-term pictures is unconfirmed.
- A long session was not tested.

Options considered and postponed:

- Extend the picture number in the SPS to 12 bits and rewrite the header of every frame. The decoder then never errs, but every frame of the stream changes along with the header length, and alignment needs a full parse of the slice header.
- Rewrite only the cycle count in the recovery frame, without touching the number. The frame number in the decoder could then match the number of the reference picture (in capture 2 it would have).
- Feed the decoder artificial empty frames in place of the lost ones. This needs a CABAC encoder.

## Repeats at 30 FPS and the pause at recovery

Re-encoded identical pictures of the stream are decoded to keep the reference frames, but are not sent for display. With a game at 30 FPS and a transport stream at 60 FPS, the display is about 30 real pictures without generation and 30 real + 30 intermediate with it. Display is counted at the layer's input, not as confirmed display refreshes. Repeat detection is a heuristic based on picture change, not the FPS set by the game.

After a long gap the first available picture is shown at once. No intermediate picture is computed across a gap, and repeat detection starts over.

The "Recovery" line in the overlay separately shows the time between the last successful decode and the start of decoding the recovery frame, as well as the time to decode it together with the bridge's copies. The first figure includes the absence of available frames and the receiver's work; it is not pure network delay. On the four captures decoding the recovery frame with copies took 1.9–2.3 ms.

The "Stream" overlay counts received access units; "To display" counts frames sent to the layer, not actual screen refreshes. Gaps are counted by the difference of frame numbers, not by `framesLost`. These are gaps before the handler, including dependent frames dropped by the engine, not a measurement of UDP packet loss. Late frames are counted separately.

## Presentation schedule

Frames arrive unevenly. Over 12 minutes of a cloud stream (ping about 105 ms) the stream ran at 59.94 fps (16.6833 ms per frame) on a screen refreshing 59.98 times per second (16.6715 ms), so the stream's phase relative to the screen goes full circle in about 22 seconds. The spacing between neighbouring frames was 9 to 24 ms (5th and 95th percentiles); a large frame with a new picture arrives 6–8 ms later than a small repeat. Decoding took 3.2–3.8 ms and did not grow over 12 minutes, and process memory did not grow.

**What is on the screen.** A test window with an AVSampleBufferDisplayLayer configured as in Con showed numbered pictures with recorded arrival times; ScreenCaptureKit read which number was on the screen, and CVDisplayLink gave the times of screen refreshes. A rhythm glitch is the moment when the mapping "screen refresh ↔ picture number" shifts. The capture ran at about 29.5 times per second, so roughly every second glitch is seen; the numbers below are the ones seen.

| Feed and timestamp | Glitches per second | Arrival to screen, median |
|---|---|---|
| Exactly 60 fps, timestamp = arrival time | 3.6 | 23 ms |
| Exactly 60 fps, timestamp 8, 12, 16 ms ahead | 2.5–3.5 | 22–23 ms |
| Exactly 60 fps, timestamp 20 ms ahead | 0.5 | 24 ms |
| Exactly 60 fps, timestamp 24 ms ahead | 0.04 | 30 ms |
| Stream recording, timestamp = arrival time (two 25 s segments) | 5.7 and 4.8 | 23 ms |
| Stream recording, `PresentationClock` (same segments) | 0.23 and 0.28–0.68 | 31–32 ms |

The layer shows a picture exactly at its time only if it receives it about 20 ms before that time. A picture stamped "now" is already late, and the layer outputs it at whatever screen refresh it can make: two pictures in one refresh, none in the next. This happens even with a perfectly even feed; uneven arrival adds more. A timestamp 8–16 ms ahead improves neither evenness nor delay.

**How the schedule works.** `PresentationClock` lays pictures out on an even grid that runs 21 ms ahead of arrival, and makes the grid follow the stream: a picture that arrived with less than 21 ms of margin shifts the grid later by 0.4 ms, one that arrived with margin shifts it earlier by 0.008 ms; this way about one picture in fifty is left without the full margin. The grid step is the stream's own interval, measured from arrivals over half a minute (16.6844 ms in the recording); with the nominal interval the model gives twice as many glitches. A burst of frames after a network delay is shown immediately and does not shift the grid; if the stream itself starts running later (a pause on the server without skipped numbers), the grid moves after it on the second such picture; a picture never waits longer than 37 ms after arrival. Repeats (a game at 30 fps) do not pull the grid earlier; they only keep it from drifting away from arrival while nothing changes on the screen. The layer gets timestamps relative to the host clock without DisplayImmediately; frames late by more than one interval are skipped. Generation uses the same schedule; a repeated picture gets the same extra delay as the original.

**The cost.** The layer's own output already takes about 22 ms, so the 21 ms lead adds 8 ms from arrival to screen (23 → 31 ms), not 21–26. The "Smooth presentation" setting in the stream settings chooses the lead (from "Disabled", which stamps the arrival time, up to 21 ms, or by screen refreshes); it also applies to a stream in progress.

**Does delay accumulate.** After each loss or decoder failure the arrival time shifts relative to the frame numbers by a whole number of frames and stays that way: +3 and +2 frames in the recording, +117, +140, +158 ms in a test with artificial failures. The time from a button press to a picture change (pause menu: Options opens, ○ closes) does not change: 396 ms before the shifts, 382 and 379 ms at +140 ms, 383 and 378 ms at +158 ms (series of 6–7 presses). So this is frame counting on the server, not accumulated delay; the ping after a loss returns to its earlier value.

**Not verified.** A session longer than 12 minutes and heating. A real game on the screen frame by frame: a 30 Hz screen capture cannot distinguish its frames; the schedule was checked in a live stream by timestamps (by the screen model 0.5 glitches per second against 3.1 with arrival-time timestamps on the same arrivals) and in the test window by the screen. Screens with another refresh rate (120 Hz): the 21 ms lead was tuned on a 60 Hz screen. Frame generation with the schedule was not measured on the screen: its delay is added to the lead.
