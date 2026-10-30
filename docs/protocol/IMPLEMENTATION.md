# The engine: implementation

The engine is the Rust crate `con-engine` in `Engine/`. It is written only from the
description in this folder (clean room: no reference engine code, patches, headers or other
Remote Play clients were read). Questions the description left open are in
[QUESTIONS.md](QUESTIONS.md), together with the reading the engine uses for each.

## Building and testing

```sh
cd Engine
CARGO_TARGET_DIR=../work/engine-rust-target cargo test       # all tests
CARGO_TARGET_DIR=../work/engine-rust-target cargo clippy --all-targets
CARGO_TARGET_DIR=../work/engine-rust-target cargo build --release   # libcon_engine.a + rlib
./build.sh                       # static libraries + header for every platform
```

`build.sh` generates the C header with cbindgen of the version `Cargo.toml` pins for the tests
(`cargo install cbindgen --version 0.29.4 --locked`; without it the script installs that
version into `work/cbindgen-0.29.4`).

Stable Rust, edition 2021, crate types `staticlib` and `rlib`. Dependencies are pure-Rust
RustCrypto crates (`aes`, `cfb-mode`, `aes-gcm`, `hmac`, `sha2`, `k256` with ECDH), `rand`,
`base64`, `thiserror`, `socket2` for the receive buffer size, `libc` on Unix for the
don't-fragment option, and libopus (C, built with CMake by the `opus` crate) behind the
default feature `opus`. No other C code, no OpenSSL. `unsafe` code is confined to the
don't-fragment `setsockopt` in `net.rs` (Linux/Android, macOS/iOS, Windows; elsewhere the
option is skipped as the description allows), the C interface (`ffi/`) and the thread
priority calls in `threads.rs` (pthread QoS, `setpriority`, `SetThreadPriority`).

## Modules

| Module | Description part | Content |
|---|---|---|
| `crypto::rp` | 01 §4 | `RpCipher` (AES-128-CFB-128, IV = HMAC-SHA256 of seed ‖ counter), session key derivation for PS4 8/9, PS4 10 and PS5 (tables of Appendix A), launch specification protection (key stream at counter 0, Base64) |
| `crypto::regist` | 04 §2.5–2.6, 01 App. B | Registration key `B` and masked seed `E` with a PIN (old and new generations); the console-side inverses (used by tests and fake consoles) |
| `crypto::stream` | 02 §7, 04 §4 | secp256k1 ECDH (`EcdhKeyPair`), public key signature and its check, per-direction keys (`StreamKeys`, `DirectionKeys`), the little-endian CTR key stream at any position, GMAC keys with the 45 000-byte refresh, the 4-byte truncated GCM tag with a 16-byte nonce, `PacketTagger` |
| `fec` | 03 §2.5 | GF(2⁸) with 0x11D, Cauchy coding matrix, `encode` (server side) and `recover` (any pattern with at most `m` losses) |
| `discovery` | 04 §1 | Search and wake-up datagrams, wake credential, tolerant response parser, generation rules with Con's replacement of "unknown", `wake()`, and `DiscoveryService` (rounds, drop after K rounds, at most 16 consoles, list callback) |
| `registration` | 04 §2 | `RegistRequest` (filler, hidden seed, encrypted inner header, exact header text), response header/body parsing with error reasons, and `register()` (unicast probe, pause, TCP exchange, decryption) |
| `launch` | 04 §3, 01 §6.3 | Presets, Con's choice by height, server-type adjustments, exact JSON in the fixed order (PS4 and PS5 forms), protection with the session cipher |
| `session::request` | 01 §3 | Request text, response parsing, version negotiation (up to three requests, `5.0` rule), `request_session()` |
| `session::control` | 01 §4.5, §6 | Encrypted control headers, request text, response parsing (`RP-Server-Type`, `RP-Prohibit`), one resend after a response timeout, framing, counters (local/remote, empty payloads skip them), reader thread with heartbeat replies, session id (validation, fallback, feature burst), login PIN loop, screen guard and blackout, on-screen keyboard, all application commands |
| `session::messages` | 01 §5, §6.5–6.8 | Message types, fixed payloads, keyboard payloads, session id validation, fallback id, device id, feature burst, screen guard state machine |
| `session` | 01 §7–8 | `start()` for states 1–7 (request → keys → 10 ms → control → session id) and the quit results (`QuitReason`) |
| `transport::packet` | 02 §3, §4, §6, §8 | Packet and chunk types, tag/key-position layouts, control packets, INIT / INIT-ACK (with the acceptance rule) / COOKIE / DATA-ACK, DATA payloads, media headers for versions 7, 9 and 12 (extended flag, adaptive stream index, haptics marker, minimum sizes, both unit-word layouts), microphone, congestion, controller state/history and network-test probe datagrams |
| `transport::seq` | 02 §5.1 | Serial-number order for 32-bit TSNs and 16-bit indices (half-way = neither) |
| `transport::crypt` | 02 §7.3–7.5 | `Sealer` (key position allocation `s + s mod 16`, payload encryption at key position + 16, tag with or without the key position field zeroed), `Opener` (verification, 64-bit key position extension shared by control and media), GMAC key cache per 45 000-byte span |
| `transport::sendbuf` | 02 §5.2 | 16-entry send buffer, re-send after 200 ms (checked every 100 ms) byte for byte, give-up after 25 retransmissions with all older entries, cumulative acknowledgement, round-trip samples from the first transmission (latest, count, median of five), `RttStats::with_initial` |
| `transport::reorder` | 02 §5.3–5.4 | 16-TSN data window (old, duplicate, too far) and Con's reassembly (one message at a time, per channel, 9/8-byte headers, second start dropped, whole messages delivered while one is pending, 1 MiB limit) |
| `transport::video` | 02 §6.3, 03 §2.4 | 64-index video window: start at packet − unit index, eviction, restart, head-of-line wait (16 ms console, 3 ms cloud) that keeps its start on eviction and restarts on delivery |
| `transport::loss` | 02 §8.1, 03 §7 | Audio sequence counting (first packet starts the range, surplus is not loss, per packet, or once per frame newer than the newest counted for PS5 cloud; empty audio datagrams not counted), per-frame video unit counting, report values with margin and ceiling |
| `transport` (`Transport`, `Link`) | 02 §2, §4–§8 | Socket setup (connected UDP, receive buffer 0x19000 / 4 MiB, don't-fragment, cloud prefix `00 00 00 P` on sent datagrams only, supplied socket drained 200 ms / 1 s), one I/O thread: handshake with 3 × 5 s attempts per step and immediate re-send on invalid replies, console/cloud receive TSN start, reliable send (single or fragmented), acknowledgements after processing, optional re-ack of duplicates, retransmission, key installation from the handler so that the next DATA-ACK is the first authenticated packet, re-verification of held chunks and release of up to 32 held media packets, tag checks, payload decryption, video reordering, congestion reports every 200 ms from the transport start, controller state/history and microphone sends, counters |
| `proto` | 02 §11 | Own protobuf codec (varint incl. negative int32, fixed32/64, length-delimited, packed repeated accepted, unknown fields skipped, required fields enforced) and a `proto_message!` macro; every message and sub-message of the tables (envelope with all 33 types, BIG, BANG, STREAMINFO, SENKUSHA, CONNECTIONQUALITY, LOG, CLIENTMETRIC, DIRECTMESSAGE with deep-link/mic-info, …) |
| `nettest` | 02 §9 | Console network test (protocol request, hello, BANG, echo, 10 pings, inbound and outbound binary MTU search, client-MTU commands, disconnect; fallback values) and Con's cloud probe (no protocol request, credential in the hello, 518/519 fragments, echoed hello, 5 pings with the tag at 22 or 23, 200–1000 ms MTU wait, 2 attempts, early stop, unmeasured = 0, stream defaults 1454/1254); `run_report`, `NetworkTestConfig::measure_mtu`, `TestStage` |
| `stream` | 02 §10, 04 §3.1, §4 | Stream connection: transport up (5 s), BIG with launch spec and ECDH fields fragmented per §5.5 (console and cloud sizes), BANG (5 s; checks, key derivation, signature only logged), early STREAMINFO kept, STREAMINFO (5 s; 14-byte audio header, ≤ 8 profiles, Con cloud prelude messages logged and reported), STREAMINFOACK / CONTROLLERCONNECTION / client STREAMINFO, heartbeat every second, server DISCONNECT (255 bytes kept) and the client's own DISCONNECT on every way out; the media layer runs in the handler on the transport's I/O thread; controller feedback starts after the client's stream info and stops with the stream; `StreamHandle` for IDR requests, corrupt-frame reports, controller state, microphone, statistics |
| `runner` | 01 §7–8, 01 §10 | `Session`: console (states 1–11: session request, control, session id, network test or fallback, handshake key and key pair, launch spec with measured MTU/RTT, stream, control close) or cloud slot (`CloudSlot`: stream only with the slot's values, codec, maximum frame rate, measured round trip); events (control, network test, stream info, connected, connection quality, cloud prelude, quit with reason text and stage), `stop()`, `stats()`, `media_stats()`, captures, missing-reference mode, handles for control and stream |
| `media::bits` | 03 §2.7 | Bit reader/writer, Exp-Golomb codes, emulation-prevention removal with a map back to the NAL bytes, re-escaping (`escape_nal`), insertion for builders |
| `media::h26x` | 03 §2.7 | Annex B NAL scanning, NAL and keyframe types, full parsing of H.264 SPS/PPS and H.265 SPS/PPS as far as slice headers need them, slice header parsing (slice type, picture ids, references), the H.265 reference rewrite; minimal SPS/PPS/slice builders for tests and fakes |
| `media::video` | 03 §2.2–2.9 | `VideoReceiver`: profile switching, frames from units (sizes, `L`, rejections, duplicates, late units), flush on enough units or the last unit, FEC recovery with padding counts, the four flush outcomes, corrupt-frame reports at frame start and on FEC failure, IDR request on FEC failure (option, Con: off) with "waiting for IDR", reference tracking and the missing-reference modes (below), lost-frame counters, samples with ≥ 64 zero bytes of padding |
| `media::audio` | 03 §3 | Audio header, packed datagrams (checks, unit indices, startup rule), PS5 cloud single-unit frames (taken once, newest only; packed datagrams recognised), 8-slot jitter buffer (start at 3, concealment rule), `AudioDecoder` trait (decoder errors are concealed), level diagnostics, console and PS5 cloud haptics receivers (first frame always, codec byte ignored) |
| `media::opus` (feature `opus`) | 03 §3.1, §4 | Opus decoder (mono/stereo, up to 120 ms per packet) and encoder through libopus, `MicrophonePacker` (48 kHz mono, 10 ms, restricted low delay, 40-byte units, 3 per datagram) |
| `media::feedback` | 03 §5 | `ControllerState` (Con's button bits, triggers, sticks, two touches, gyro, accel, orientation), state payload (25/28 bytes, clamped motion values, compressed quaternion), history events (3- and 2-byte buttons, 5-byte touches), event derivation, the 64-event ring cut to 32 after each payload, 64-payload queue, Con's 100 ms button refresh, the sender thread (one history payload per pass, state on stick/motion change and every 200 ms) |
| `media::effects` | 03 §6 | Rumble, pad info (25- and 17-byte forms; events only on change, motion reset every time), trigger effects (two 11-byte blocks) |
| `media::capture` | — | Video and audio capture files (formats below), writer thread, `RecordHeader::decode`, `AudioRecordHeader::decode` |
| `media` (`MediaPipeline`, `MediaSink`) | 03 §7–8 | The layer for one stream: created from the first acceptable stream info (later ones restart audio), video/audio/haptics dispatch, measured bitrate (computed at each connection-quality message), `MediaStats` |
| `threads` | — | `spawn` (every engine thread starts through it, with its role), `set_hook`, `set_current_thread_interactive` |
| `log` | 03 §8 | Optional log callback; lines never contain keys, payloads or launch specifications |
| `ffi` | — | The C interface (below) |
| `net` (private) | — | All socket code: TCP with deadlines and stop polling, UDP with timeouts and port-range binding, host resolution |

## Rust API

- Long waits take a `StopToken` (cloneable flag) and return "stopped" soon after it is set.
  Timeouts and ports are configuration fields with the description's defaults, so tests run
  against loopback fakes.
- Errors are typed per area: `RegistError`, `SessionRequestError`, `ControlError`,
  `FecError`, `LaunchError`, `KeyExchangeError`, `WakeError`; `session::StartError` carries
  the `QuitReason`, the `Stage` and a log text.
- Commands go through `ControlHandle` (cloneable, usable from any thread, e.g. to answer a PIN
  request while `session::start` waits). Each send takes the next counter, encrypts and writes
  under one lock, so counters reach the console in order.
- Threads: `Transport` owns one I/O thread (receive, timers, handler calls); `stream::run`
  blocks the calling thread for the stream's lifetime (the runner's session thread);
  `Session::start` spawns that thread. No async runtime.
- Upper layers implement `TransportHandler` (`on_message`, `on_media`; called on the I/O
  thread, must not wait for acknowledgements) and send through a cloneable `Link`
  (`send_message`, `send_fragmented`, `wait_ack`, `send_raw`, `send_feedback_state/history`,
  `send_microphone`, `install_keys`, `stats`).
- `Session::start(config, events, media)`: `events` receives `SessionEvent`s (control
  events, `StreamEvent`s, quit); `media` is an `Arc<dyn MediaSink>` with four methods, all
  with defaults: `video(&VideoSample) -> bool` (accepted), `audio(&AudioFrame)`,
  `haptics(&HapticsFrame)`, and `raw(&StreamData)` (every packet and feedback message before
  the media layer; `RawSink` wraps a closure). They are called on the transport's I/O thread;
  `StreamHandle::request_idr` may be called from inside `video`. Callbacks are
  `Arc<dyn Fn(..) + Send + Sync>` with plain data, the same shape as the C interface
  (function pointer plus user data).
- Samples and frames are plain structs of slices and numbers: `VideoSample` (kind parameter
  sets / picture, Annex B `data`, `padded` = data + 64 zeros, 16-bit frame index, frames lost
  since the previous sample, `recovered` (reference rewrite), `fec_recovered`, `keyframe`,
  `decode_only`, codec, profile index, width, height); `AudioFrame` (interleaved i16 `pcm`,
  the Opus packet, `decoded`, `concealed`, frame index, channels, rate, samples per channel);
  `HapticsFrame` (LE i16 stereo bytes, frame index, 3000 Hz, 2 channels).
- Controller feedback arrives as `SessionEvent::Stream(StreamEvent::Feedback(FeedbackEvent))`
  (rumble, trigger effects, light bar, player index, effect intensity, motion reset); FEC
  failures as `StreamEvent::FecFailure`.
- Input: `StreamHandle::set_controller_state(ControllerState)` from any thread; the motion
  origin after a motion reset stays with the app (03 §5.2 "Con"); `compress_orientation` and
  the state layout are in the engine.
- Statistics: `StreamHandle::media_stats()` / `Session::media_stats()` (video, audio, haptics,
  feedback counters, measured and running bitrate); `stats()` gives the transport's counters
  with the round trip.
- Feature `opus` (default): libopus 1.5 from the `opus` crate (via `opusic-sys`), built from
  source with **CMake** and linked statically. Without the feature (or with
  `decode_audio = false`) the engine hands Opus packets plus the header values to the app,
  and the microphone sender is absent. Cross builds (Android, Windows) need CMake with the
  target's toolchain; without it they can build `--no-default-features`.
- Secrets (`RpCipher`, `Registration`, stream keys, requests) never print their bytes in
  `Debug`.

## Video path

### Guarantees

No partial frame is delivered after an FEC failure; FEC-recovered units are cut to `L − p`;
frames are delivered once and in frame order (older frames and late units are dropped);
parameter sets go out as their own sample before a profile's first picture, in the order of
the stream info's header; every delivered buffer starts as the console sent it (start codes
included) and has 64 zero bytes after it.

### Profile switches

The open frame of the old profile is finished first (flush, reports), then the new profile's
parameter sets go out; a datagram of an older frame is dropped before the profile check. A
datagram whose index has no profile is dropped. The remembered references are cleared at a
profile switch and when the decoder accepts an IDR/IRAP picture; P pictures before the new
profile's keyframe are not delivered (counted lost; QUESTIONS.md, question 40).

### Parsing

The parameter sets are parsed as the standards define them, as far as slice headers need:
H.265 SPS (profile/tier/level with sub-layers, scaling lists, PCM, all short-term RPS sets
with inter-RPS prediction, CTB size, long-term reference fields `long_term_ref_pics_present_flag`,
`lt_ref_pic_poc_lsb_sps`, `used_by_curr_pic_lt_sps_flag`), H.265 PPS (up to
`lists_modification_present_flag`, tiles, deblocking, scaling lists), H.264 SPS (scaling
matrices, POC types 0/1/2, `frame_mbs_only_flag`), H.264 PPS (slice groups,
`redundant_pic_cnt_present_flag`). Slice headers are read with the fields these enable
(`num_extra_slice_header_bits`, `output_flag_present_flag`, a separate colour plane,
`slice_segment_address` for non-first segments, short-term RPS from the SPS or explicit,
`num_long_term_sps`, `num_long_term_pics`, `lt_idx_sps` / `poc_lsb_lt` +
`used_by_curr_pic_lt_flag`, `delta_poc_msb_cycle_lt` accumulated as in equation 7-52; H.264
POC types 0/1, field coding, `redundant_pic_cnt`). When a parameter set is not readable the
description's assumptions are used.

Every slice of a picture is read. The references are those of its P slices; a picture counts
as intra only when all its slices are I slices (intra refresh pictures begin with an I slice;
QUESTIONS.md, question 43); the RPS is read for I slices too.

### Picture ids and the decoder's buffer

- Remembered pictures carry their full id: H.265 `PicOrderCntVal` derived as the decoder does
  (H.265 8.3.1: MSB from `prevTid0Pic` — the last delivered picture with TemporalId 0 that is
  not RASL/RADL/sub-layer non-reference; 0 at IDR/BLA and a CRA that starts the stream);
  H.264 `frame_num` counted on past `MaxFrameNum`. Only delivered pictures advance it (the
  decoder sees no others). A remembered picture is a reference only when its full id matches
  (QUESTIONS.md, questions 38 and 45). Pictures without a readable id fall back to the
  description's frame-index rule. H.264 non-reference pictures (`nal_ref_idc` 0) are never
  taken for a reference.
- Every used reference is checked: short-term, positive and long-term entries. A used
  long-term picture must be remembered (full POC with the MSB flag, else the newest remembered
  picture with that LSB). P pictures that use only long-term pictures are checked too.
- Entries kept only for later use (`used_by_curr_pic` 0) that are missing are left alone:
  decoders accept such pictures.
- The remembered pictures follow the decoder's buffer: after an accepted H.265 picture,
  remembered pictures its RPS does not list are forgotten (H.265 8.3.2 marks them unused). A
  long-term picture older than 16 frames stays remembered as long as the RPSs list it. A
  rejected picture's RPS is not applied (QUESTIONS.md, question 46).
- Pictures delivered without a check (slice header not readable, B or other slices, H.265 P
  pictures whose RPS was not readable or that use no picture) are counted
  (`VideoStats::frames_unchecked`, `ConStats.video_frames_unchecked`), flagged in the
  capture, and the first one is logged ("video: frame …: references not readable …").

### Repair (H.265 rewrite)

- The rewrite chooses among the RPS's own older pictures (only these are still in the
  decoder's buffer). Further used pictures that are not remembered stop being used (explicit
  RPS); with `lists_modification_present_flag` (where the number of used pictures sizes later
  header fields) a rewrite must keep the count. When no short-term picture of the RPS can
  replace a missing reference, the nearest remembered long-term picture of the RPS whose
  `used_by_curr_pic_lt_flag` is coded in the slice is used instead (its flag set, the missing
  ones cleared) — what the server's own recovery pictures do. Without a replacement, or with an
  RPS from the SPS or predicted, the picture is not delivered (QUESTIONS.md, questions 37
  and 44).
- `h26x::rewrite_references` rewrites every independent slice segment of the picture
  (dependent segments have no RPS of their own); if any segment cannot be read or has another
  RPS shape, the picture is not delivered (question 39).
- Each rewritten NAL is written again from its payload with emulation-prevention bytes
  inserted (`bits::escape_nal`, also the trailing `03` after a final zero byte); clearing a
  used flag could otherwise turn `00 00 04` into a start code. The picture may grow by a byte
  or two.
- H.264 pictures with a missing reference cannot be repaired and are not delivered.

### Missing-reference modes

`MissingReference` in `VideoConfig::missing_reference`, or `MissingReferenceSlot` in
`SessionRunnerConfig` / `StreamConfig` (shared, read at every video packet) and
`Session::set_missing_reference`; C `con_session_set_reference_repair`.

| Mode | C value | Behaviour |
|---|---|---|
| `Hide` (default) | `CON_MISSING_REFERENCE_REPAIR_HIDE` (2) | Repair, and every tainted picture is delivered with `VideoSample::decode_only` (C: `CON_VIDEO_FLAG_DECODE_ONLY` in `ConVideoEvent.flags`): the app decodes it and keeps the last picture shown |
| `Repair` | `CON_MISSING_REFERENCE_REPAIR_SHOW` (1, and any other value) | The 03 §2.7 repair; every picture is shown, no keyframe requests, no numbering check |
| `Withhold` | `CON_MISSING_REFERENCE_WITHHOLD` (0) | Pictures with a missing reference are not delivered until one whose references are all with the decoder |

**Hide.**

- *Taint tracking.* Every remembered picture carries "tainted" (its content is wrong). A
  delivered picture is tainted when it was rewritten, or when a reference it uses (H.265:
  used short-term, positive and long-term entries, found by full POC; H.264: the `frame_num`
  it references) is tainted, belongs to another numbering of the decoder (below) or is not
  found. It is clean when all its used references are genuine (untainted pictures really
  delivered); IDR/IRAP pictures and pictures of I slices only are clean. Pictures whose
  references cannot be read are tainted while any remembered reference picture is
  (question 53). Pictures the decoder drops from its reference set (RPS pruning, the
  16-picture limit, a keyframe) stop tainting with them.
- Hidden pictures count as delivered (`frames_delivered`, not lost) and in `frames_hidden`;
  `hide_runs` counts the freezes (a picture hidden, or not delivered for a missing reference,
  after one shown). Pictures that cannot be repaired (all H.264 pictures) are not delivered;
  they freeze the picture too. Log lines: "video: frame … decoded hidden (its content is
  wrong); the picture shown is kept until one whose references are all genuine", "video:
  display resumes at frame … (all references genuine \| keyframe) after … pictures hidden and
  … not delivered from frame …".
- *Keyframe as the fallback.* When no picture has been shown for `HIDE_KEYFRAME_AFTER_MS` =
  500 ms after the first picture not shown (30 frames at 60 fps, 15 at 30; FEC failures count
  as time), one keyframe request goes out, repeated after 2 s if the run still lasts. The
  server's recovery picture comes about 150 ms after a corrupt-frame report, so 500 ms leaves
  it room to end the run first.
- *The decoder's numbering.* When more frames than half the POC LSB range (H.264:
  `MaxFrameNum`) pass without a delivered picture, the decoder numbers the next picture
  differently from the encoder and its references find other pictures. Such a picture starts
  a new numbering; references across numberings count as tainted, so it and the pictures
  built on it are hidden (or not delivered), and a keyframe is requested at once (same 2 s
  limit).

**Withhold.**

- A picture whose used references (short-term, long-term, positive; H.264: the `frame_num` it
  references) are not all pictures the decoder accepted is not delivered, nor is any later one
  that uses a withheld picture; delivery resumes with the first picture whose used references
  are all there or a keyframe. Withheld pictures are counted lost (`frames_lost` of the next
  sample, `VideoStats::frames_lost`), in `frames_reference_missing`, `frames_withheld` and
  `withhold_periods`; the capture records them as "not delivered, reference missing". Log
  lines: "video: frame … uses a picture the decoder does not have; pictures are withheld …",
  "video: delivery resumes at frame … after … pictures withheld …".
- If no clean picture comes within `WITHHOLD_KEYFRAME_AFTER_MS` = 300 ms after the first
  withheld frame (counted in frame indices at the stream's frame rate, `MediaConfig::max_fps`:
  18 frames at 60 fps, 9 at 30; frames lost by FEC count as time), one IDR request goes out
  (`VideoStats::idr_requests`, log "video: keyframe requested …"). It is repeated only after
  `WITHHOLD_KEYFRAME_INTERVAL_MS` = 2 s if the run still lasts; none while the FEC-failure
  option already waits for an IDR it requested.
- After more than `MaxPicOrderCntLsb / 2` frames without a delivered picture, or when the id
  unwrapped over every received picture differs from the one unwrapped over the delivered
  ones, the picture is withheld and a keyframe requested at once (same rate limit). H.264:
  the same with a gap of `MaxFrameNum` frames.

**All modes.** An FEC failure counts the frames since the last complete one (03 §2.6); frames
already counted because they were withheld or dropped for a missing reference are not counted
again (question 51). `ConStats.video_frames_reference_missing` includes withheld pictures,
`video_idr_requests` the requests of hidden and withheld runs, and `ConVideoEvent.frames_lost`
withheld pictures.

### PS5 cloud H.265 streams

What a recorded PS5 cloud stream (1080p60) shows, and what `tests/media.rs` replays as slice
headers (the header bits up to the long-term pictures, then synthetic slice data):

- SPS: `log2_max_pic_order_cnt_lsb` **4** (the POC LSB wraps every 16 pictures),
  `sps_max_dec_pic_buffering` 4, no short-term RPS sets, `long_term_ref_pics_present_flag` 1
  with no long-term candidates in the SPS, temporal MVP and SAO off. PPS: no extra slice header
  bits, no output flag, no dependent slices, no list modification, no tiles.
- Every picture is TRAIL_R (P slices, TemporalId 0) with an explicit RPS of one negative
  picture (POC − 1) and 0–2 long-term pictures (named with `delta_poc_msb_present_flag`);
  keyframes are IDR_N_LP. Pictures have one slice or 3–12 slices.
- The server answers a corrupt-frame report with a recovery picture, about 9 frames (150 ms)
  later, that uses only a long-term picture (the short-term entry kept for later use,
  `used_by_curr_pic` 0). Decoders accept it even when the POC − 1 picture it keeps was
  rejected or never delivered.
- With a 4-bit LSB, matching by POC LSB alone finds the picture 16 frames earlier for a lost
  one; the decoder then rejects every picture until the recovery picture. Matching by full POC
  avoids this.
- **Hide:** after a loss the next picture is rewritten to the long-term picture, it and the
  pictures built on it are decoded hidden, and the recovery picture is shown: the screen holds
  for about 9 frames, without a keyframe. A burst of 9 or more lost frames breaks the
  decoder's numbering; the pictures are hidden until a keyframe, requested at once.
- **Repair:** the same pictures are shown and smear for about 150 ms.
- **Withhold:** the recovery picture comes 9–11 frames after the loss, more than the 8 a
  decoder can bridge after withheld pictures, so it would be misnumbered and its long-term
  reference would resolve to another picture. Every loss therefore ends in a keyframe: the
  picture freezes from the loss until the keyframe arrives (an estimated 250–350 ms).
- Resuming with the recovery picture in Withhold mode would need a generated "copy the
  previous picture" P picture for every withheld one (keeps the decoder's numbering and shows
  a frozen picture); that needs a CABAC slice writer and is not implemented.

## Audio path

- The decode buffer holds the longest Opus frame (120 ms, ≤ 5760 samples per channel), not
  only the header's frame size, so packets longer than the header's frame size decode; all
  decoded samples are delivered; concealment produces the length of the last decoded packet
  (question 47). Decoder errors are logged with the packet size (the first 10, then at powers
  of two).
- A PS5 cloud datagram whose unit word describes its payload exactly as two or more units
  (`s + r` = total, payload = unit size × total) is taken as packed and its units decoded
  separately (log "audio: cloud datagrams are packed …"; question 48). Decoding a packed
  payload as one Opus packet plays garbled sound at about the normal level.
- The header's last field (unknown, typically 1) is logged ("audio header: …"). The
  description has no mute or "audio not started" signal for game audio (the client's mute
  message, `0x0036`, and "disable upstream audio" concern the microphone).
- After 500 frames the receiver logs "audio: level after 500 frames: peak …, Opus packets …
  bytes on average, … % of their bytes zero, first byte 0x…, last frame … samples (header frame
  size …)", with "(silent)" when the peak is ≤ 64; after a silent start, "audio: sound starts
  at frame …"; and after 500 silent frames following sound, "audio: silent since 500 frames …"
  with the same figures.
- Servers encode at a constant bitrate, so silent packets are as long as sounding ones and
  packet size tells nothing. Silence padded at a constant bitrate is mostly zero bytes, sound
  almost none: a high zero share in a silent stream means the server sent silence;
  normal-content packets decoding to silence, or decoder errors, point to the client (question
  49).

## Capture files

Both captures are written by a thread of their own (role `CON_THREAD_CAPTURE`) with a queue of
512 records; the I/O thread never waits for the disk (records that do not fit are skipped,
their sequence numbers missing). An existing file of another kind is refused and left alone.
`NULL` / `None` stops and finishes the file; it is also finished at the end of the session.
Each start writes a kind-3 record first, so several sessions can share a file. The files
contain decrypted media, no keys; they are for analysis and should be deleted after.

### Video capture

`Session::set_video_capture(path)` / `con_session_set_video_capture(session, path)` (or
`ConSessionOptions.video_capture_path` at the start) appends every video sample handed to the
application and every frame that was not delivered.

File layout (all numbers little-endian):

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | `CONVCAP1` |
| 8 | 2 | format version (1) |
| 10 | 2 | record header size (32) |
| 12 | 4 | 0 |

Then records, each a 32-byte header and `length` data bytes:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `length`: data bytes after the header (Annex B as delivered, without the 64 padding bytes) |
| 4 | 2 | frame index (parameter sets: the frame that switched the profile) |
| 6 | 1 | kind: 0 parameter sets, 1 picture, 2 frame not delivered (no data), 3 capture started (no data) |
| 7 | 1 | flags: 0x01 keyframe (IDR/IRAP), 0x02 reference rewritten (H.265 repair), 0x04 FEC restored units, 0x08 the app's decoder accepted it, 0x10 parameter sets repeated by the capture (it started while a profile was active), 0x20 references not checked, 0x40 delivered "decode only" |
| 8 | 4 | frames lost since the previous sample (03 §2.9) |
| 12 | 1 | profile index (255 unknown) |
| 13 | 1 | codec: 0 H.264, 1 H.265, 2 H.265 HDR |
| 14 | 1 | kind 2: reason — 1 FEC failed, 2 reference missing (or not repairable), 3 waiting for IDR, 4 invalid frame sizes |
| 15 | 1 | 0 |
| 16 | 2 | profile width (0 for kind 2/3) |
| 18 | 2 | profile height |
| 20 | 4 | record sequence number since the capture started |
| 24 | 8 | microseconds since the capture started |

`media::capture::RecordHeader::decode` reads a header.

### Audio capture

`Session::set_audio_capture(path)` / `con_session_set_audio_capture(session, path)` records the
audio header the receiver works with, every game audio **and haptics** datagram as received
(media header in clear, payload decrypted) and every audio frame handed to the application
with the peak and RMS of its PCM and its Opus packet. A capture started during a stream begins
with the current header (flag "repeated"); start it right after `con_session_start_*` to have
the header in the file. About 60–80 KB/s.

File layout (little-endian):

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | `CONACAP1` |
| 8 | 2 | format version (1) |
| 10 | 2 | record header size (40) |
| 12 | 4 | 0 |

Records, each a 40-byte header and `length` data bytes:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `length` of the data |
| 4 | 2 | frame index (datagram: of the datagram; frame: of the audio frame) |
| 6 | 1 | kind: 0 audio header (data: the 14 bytes), 1 datagram (data: the whole datagram), 2 frame delivered (data: the Opus packet; none when concealed), 3 capture started (no data) |
| 7 | 1 | flags: 0x01 decoded (header: the engine decodes; frame: PCM delivered), 0x02 concealed, 0x04 decoder error (concealed instead), 0x08 haptics datagram, 0x10 header repeated by the capture, 0x20 media header with the extension flag |
| 8 | 2 | datagram: packet index |
| 10 | 1 | datagram: codec byte |
| 11 | 1 | datagram: payload offset (bytes of media header before the payload) |
| 12 | 4 | datagram: unit word as received |
| 16 | 2 | frame: peak (largest absolute sample, 0–32767) |
| 18 | 2 | frame: RMS |
| 20 | 2 | frame: samples per channel |
| 22 | 2 | frame: Opus packet bytes (0 when concealed) |
| 24 | 1 | header and frame: channels |
| 25 | 1 | header: layout the receiver expects (0 packed, 1 single unit) |
| 26 | 2 | 0 |
| 28 | 4 | record sequence number since the capture started |
| 32 | 8 | microseconds since the capture started |

`media::capture::AudioRecordHeader::decode` reads a header. Reading a silent stream: frames
with peak ≤ 64 and a high zero-byte share in their Opus packets mean the server sent silence;
normal packets decoding to silence or flag 0x04 mean a decoding problem in the client;
datagrams per frame and the unit words show the layout the server used.

## C interface

The interface is `src/ffi/` (opaque handles, `#[repr(C)]` structures, constants as integers,
every exported function under `catch_unwind`); the header is generated from it (below).

- **Version:** `con_engine_version()` ("0.1.0"), `con_engine_abi_version()` (=
  `CON_ENGINE_ABI_VERSION`, currently 2; changes with any structure or signature),
  `con_quit_reason_name()`, `con_stage_name()`.
- **Results:** `int32_t`, `CON_OK` or a negative `CON_ERR_*` (invalid argument, not ready,
  I/O, unsupported, bad credential, send failed, panic). Bad input never aborts.
- **Enumerations** cross as `uint32_t`/`int32_t` constants (console family, target, codec,
  console state, log level, quit reason, stage, registration status, event type, buttons,
  thread role, probe status and stage, missing-reference mode); an unknown value from C is
  rejected, never transmuted into a Rust enum.
- **Defaults:** `con_discovery_config_default`, `con_registration_request_default`,
  `con_console_config_default`, `con_cloud_config_default`, `con_session_options_default`,
  `con_cloud_probe_config_default`, `con_controller_state_idle` (the rest state).
- **Discovery:** `con_discovery_start(config, callback, user, &handle)` (the callback gets the
  whole console list after every change: appeared, changed, dropped), `con_discovery_wake`
  (from the search socket), `con_discovery_stop`; `con_wake` for a single wake-up from a
  temporary socket. The application supplies directed broadcast addresses
  (`extra_destinations`).
- **Registration:** `con_registration_start(request, callback, user, &handle)` runs on its own
  thread and calls the callback exactly once with a `ConRegistrationResult` (status, error
  text, HTTP status and `RP-Application-Reason` of a rejection, keys, MAC, nickname, AP
  fields, key type, support command); `con_registration_cancel`, `con_registration_free`. The
  account id is the 8 wire bytes as given (the byte-order question of 04 §5 stays with the
  caller).
- **Sessions:** `con_session_start_console(ConConsoleConfig, ConSessionOptions, callback,
  user, &handle)` (host, family, keys, codec, requested height and frame rate → Con's preset,
  bitrate override, downgrade, video off, keyboard, network test on/off, ports) and
  `con_session_start_cloud(ConCloudConfig, …)` (address and port, prefix, PS5, session id,
  handshake key, launch specification, MTUs, codec, frame rate, `rtt_us`). Options:
  DualSense, loss ceiling, discard switches, IDR on FEC failure, audio decoding, log level,
  statistics interval, video capture path. `con_session_stop` (returns at once),
  `con_session_is_finished`, `con_session_free`.
- **Commands:** control channel — `submit_pin`, `keyboard_set_text/accept/cancel`, `sleep`,
  `go_home`, `microphone_connect`, `set_microphone_muted` (`CON_ERR_NOT_READY` without a
  control channel, e.g. cloud); stream — `set_controller_state` (`ConControllerState`, the
  engine derives the events), `send_microphone_pcm` (48 kHz mono, multiples of 480 samples),
  `request_keyframe`, `report_corrupt_frames`, `stats` (`ConStats`: transport, video, audio,
  haptics, feedback counters, measured bitrate); `set_video_capture`, `set_audio_capture`;
  `set_reference_repair(session, mode)` (takes effect with the next video packet; allowed at
  any time while the handle lives, before the stream and inside callbacks);
  `video_hidden(session, &frames, &runs)` and `video_withheld(session, &frames, &periods)`
  (either pointer may be NULL; `CON_ERR_NOT_READY` without a stream).
- **Events:** one callback per session with a tagged `ConEvent` (`type` + union `data`):
  log line with level; PIN requested; keyboard opened / text changed / closed; cannot display;
  network test result; stream info (profiles with their parameter sets, audio header and its
  values, timeouts); connected; connection quality; server corrupt frames; cloud prelude;
  video access unit (Annex B, followed by 64 zero bytes, frame index, frames lost, keyframe,
  recovered, FEC, profile and size, `flags`; the callback writes `accepted = 0` when its
  decoder rejected a picture); audio frame (decoded PCM or the Opus packet, concealment flag);
  haptics PCM; rumble; trigger effects; light bar; player index; effect intensity; motion
  reset; FEC failure; statistics (every `stats_interval_ms`); quit with reason, "is error",
  the console's text and `stage`. The quit event is always the last; no log line follows it.
- **Screen guard:** the client sends nothing back about it (the fixed burst closer `0x0910` of
  the feature burst, 01 §6.8, is sent by the engine); the console's "cannot display" state
  reaches the application as `CON_EVENT_CANNOT_DISPLAY`.
- **Cloud probe** (02 §9.5, question 31): `con_cloud_probe_run` (blocking),
  `con_cloud_probe_start` / `_cancel` / `_free` (own thread, callback once). Config: address
  and port, credential, prefix, every timing of the probe (0 = default), MTU on/off.
  `ConCloudProbeResult`: round trip and samples, MTU in/out (0 = not measured), `CON_PROBE_*`
  status (OK, cancelled, host not found, no connection, no RTT, network, internal),
  `CON_PROBE_STAGE_*` reached (connect, hello, RTT, MTU in, MTU out, done), hello echoed,
  error text. Several probes may run at once.
- **Slot round trip** (question 32): `ConCloudConfig.rtt_us` is logged and reported as the
  stream's round trip (`rtt_latest_us`, `rtt_median_us`, with `rtt_samples` 0) until the
  first own measurement (Rust: `CloudSlot::rtt_us`, `TransportConfig::initial_rtt_us`).
- **Thread callback** (question 33): `con_set_thread_callback(callback, user)` is a
  process-wide callback every engine thread calls on itself before its work, with its role
  (`CON_THREAD_*`: I/O, sender, session, control, statistics, discovery, registration, probe,
  capture, helper) and name; `con_thread_set_interactive()` gives the calling thread the
  platform's interactive priority (Apple QoS user-interactive, Linux/Android nice −8, Windows
  `THREAD_PRIORITY_HIGHEST`).
- **Quit stage** (question 35): `ConQuitEvent.stage`, `CON_STAGE_*` — session request,
  control, network test, transport, key exchange (hello sent, waiting for BANG), stream info,
  streaming.
- **Decode-only pictures:** `ConVideoEvent.flags` is a `uint8_t` after `accepted`, in what was
  padding (`sizeof(ConVideoEvent)` is 56 on 64-bit targets). Bit `CON_VIDEO_FLAG_DECODE_ONLY`
  (0x01): decode the picture, do not display it (keep the last picture shown). Other bits 0.
  Con's app drops such images before the display queue on macOS, releases the output buffer
  unrendered on Android, and calls `con_video_submit(…, show = 0)` on Linux and Windows.

`ConSessionOptions` and `ConStats` have no size or reserved field, so they cannot grow without
a new ABI version; later additions are functions (captures, hidden and withheld counters).

### Threads, ownership, lifetimes

- Callbacks run on engine threads: discovery thread; registration thread; probe thread;
  session thread, control reader thread, transport I/O thread (all media and stream events)
  and the statistics thread. One session's callbacks can run
  concurrently; they must be quick (a synchronous decode per frame is fine) and must not
  unwind into the engine.
- Every pointer in an event or result (strings, sample data, profile array, statistics) and
  the event itself are valid only until the callback returns. Strings in are copied during
  the call. The user pointer is handed back unchanged and must outlive the handle.
- Events can arrive before `*_start` returns; applications find their state through the user
  pointer.
- Each handle is released exactly once (`con_discovery_stop`, `con_registration_free`,
  `con_cloud_probe_free`, `con_session_free`). Outside callbacks the release waits for every
  engine thread of the handle, so no callback of it runs afterwards. Inside any callback the
  release returns at once and the waiting happens on a short-lived helper thread (a
  thread-local marks callback threads), so releasing a session from its own quit callback
  cannot deadlock.
- Panics never cross the boundary: each exported function's body runs under
  `catch_unwind` (`CON_ERR_PANIC`); callbacks into C are only made from engine threads.
- Secrets (registration, RP and handshake keys) are plain bytes in and out; nothing secret
  appears in log events.

### The generated header

| Part | Content |
|---|---|
| `src/ffi/abi.rs` | Every constant, `#[repr(C)]` structure, the event union and the callback types of the interface. Uses only `std`, so a program can include it as its copy of the header's definitions. |
| `src/ffi/mod.rs` | The exported functions, the opaque handles and everything behind them; `pub use abi::*`. |
| `cbindgen.toml` | cbindgen settings: C, `#pragma once`, `<stddef.h>`/`<stdint.h>`, `usize` → `size_t`, `typedef struct X {…} X` style; no comments in the header (no documentation, no preamble, no `extern "C"` block). |
| `build.sh` | Runs `cbindgen --config cbindgen.toml src/ffi/mod.rs` once per run (only the C interface becomes the header, not the crate) and writes **`work/engine-rust/include/con_engine.h`** (the fixed path for the app) and a copy beside every library, **`work/engine-rust/<target>/include/con_engine.h`**. |

Rules kept by the Rust side: constants of `uint32_t` values are written with the suffix `u32`,
which cbindgen turns into C's `u` (`#define CON_CONSOLE_PS5 1u`; Swift imports them as
`UInt32`); the thread roles and buttons are literal values checked against `ThreadRole` and
`media::feedback::button` at compile time; the quit reasons are constants (`CON_QUIT_*`, used
by `quit_reason_code`); `ConEvent.type_` is `type` in C (`cbindgen:field-names`). Negative
constants (`CON_ERR_*`, `CON_LOG_NONE`) are written without parentheses (`-3`), so an
expression like `x-CON_ERR_IO` does not compile. `ConEvent.data` is `union ConEventData`, with
`typedef union ConEventData {…} ConEventData` (Swift: `ConEventData`).

### libopus symbols

`Engine/build.sh` renames every global symbol of libopus's objects in the built library with
the prefix `con_` (`opus_decode` → `con_opus_decode`, `silk_*`, `celt_*`, `ec_*` … — about 440
names), definitions and references, with `llvm-objcopy --redefine-syms` (Homebrew llvm, the
swift.org toolchain or the NDK; on Windows member by member, because import-library entries
cannot be rewritten, then replaced in place), and re-indexes the archive. It then checks that
no object defines or uses an old name. The count differs per target because the libopus build
includes CPU-specific code on x86_64. Objects that also carry LLVM bitcode keep the old names
inside the bitcode, which no normal link reads. `cargo build` alone (the engine's tests)
leaves the names unchanged; `CON_ENGINE_PREFIX_OPUS=0` skips the step (question 34).

## Platform builds

`Engine/build.sh [target …]` (default: every target the host can build) writes
`work/engine-rust/<target>/libcon_engine.a` (`con_engine.lib` for Windows), the header and
`native-libs.txt` (what the final link needs, from `rustc --print native-static-libs`), then
builds the link check `tools/link_check.rs` against the library (`CON_ENGINE_CHECK=0` skips
it). Release profile (LTO, one codegen unit); missing Rust targets are added with rustup.
libopus's build script does not notice changed C settings, so the script rebuilds it whenever
they change.

| Target | How | Link with |
|---|---|---|
| `aarch64-apple-darwin` | `MACOSX_DEPLOYMENT_TARGET=14.0` (the prebuilt Rust `compiler_builtins` carry 11.0) | `-liconv -lSystem -lc -lm` |
| `aarch64-linux-android`, `x86_64-linux-android` | NDK r30 (`ANDROID_NDK_HOME`, default `work/swift-toolchain/android-ndk-r30`), API 28: `CC/AR/linker` of the NDK, libopus through the NDK's CMake toolchain file with `ANDROID_PLATFORM=android-28` | `-ldl -llog -lunwind -lm -lc` |
| `x86_64-pc-windows-msvc` | clang and llvm-ar of the swift.org toolchain (GNU-style driver, `--target=x86_64-pc-windows-msvc -fms-runtime-lib=dll` = /MD), Windows SDK and CRT headers from `work/windows/xwin` with `-idirafter` (clang's own intrinsic headers must come first, otherwise SSE intrinsics become unresolved calls), Ninja, `RC` = llvm-rc of Homebrew llvm (CMake's Windows platform wants a resource compiler); libopus objects carry `/DEFAULTLIB:msvcrt` | `bcrypt advapi32 kernel32 ntdll userenv ws2_32 dbghelp` + msvcrt (/MD) |
| `aarch64-unknown-linux-gnu`, `x86_64-unknown-linux-gnu` | on Linux: the system compiler for the native architecture (another architecture needs `CC_<target>`/`AR_<target>` of a cross compiler); on macOS: swift.org clang with `--target` and the C headers of the Swift static Linux SDK (musl) for libopus | `-lgcc_s -lutil -lrt -lpthread -lm -ldl -lc` |

On the Linux targets built on macOS only libopus is C; it calls only standard C functions
(`malloc`, `memcpy`, `fprintf`, `stderr`, `abort`, maths, and on aarch64 the CPU check's
`fopen`/`fgets`/`strstr`, plus `__stack_chk_fail`/`__stack_chk_guard`), which glibc provides
with the same ABI, so the musl headers do not matter for the result. To build on Linux
instead: rustup with the target, CMake, a C compiler, then `Engine/build.sh
$(uname -m)-unknown-linux-gnu`.

The link check (it includes `src/ffi/abi.rs` and `tests/capi`, links only the static library)
takes the address of every function, so every symbol must resolve, runs the self test where
the host can, and with renamed libopus symbols defines `opus_get_version_string` and
`opus_decoder_get_size` itself, checking that a program may link its own libopus.

| Target | Link check |
|---|---|
| `aarch64-apple-darwin` | linked and run (self test, own `opus_*` functions) |
| Android | linked with the NDK clang; not run by `build.sh` |
| `x86_64-pc-windows-msvc` | linked with lld-link against the xwin libraries; run under Wine by hand (`CON_ENGINE_KEEP_WINDOWS_CHECK=<file>` keeps `link_check.exe`) |
| Linux | linked and run on a Linux host of the same architecture; not linked when built on macOS (no glibc there) |

## Tests

- **Vectors:** every test vector of the description — session K/S/IV/RP-Auth/OSType/`00 01 01
  59` for PS4 8.0, PS4 10.0 and PS5 (01 §4.7); the CFB-vs-key-stream example; registration
  check values of 01 App. B and all vectors of 04 §6; launch key streams; stream key
  derivation; public-key signature; transport vectors of 02 §7.6 (G₀, G₁, key stream at 0 and
  0x10000, GMAC tags at key positions 0x40 and 45001, both directions, through the packet
  API); the exact 910-byte PS5 and 839-byte PS4 launch JSON; the FEC matrix examples; every
  protobuf encoding of 02 §11; the worked media example of 03 §1.6; handshake packet sizes,
  congestion, microphone and controller packet layouts.
- **FEC:** parity against the matrix definition; every erasure pattern for k ≤ 6, m ≤ 4;
  random frames with a fixed seed (k ≤ 60, m ≤ 20, L ≤ 1400); the largest code (k = 200,
  m = 56) with the worst case.
- **Round trips and rules:** CFB, launch protection, keyboard/frame/session-id formats,
  screen guard, ECDH, PIN seed masking; every one of the 33 message types; protobuf error
  cases; key position allocation and 64-bit extension across the 32-bit wrap; serial order;
  data window, reassembly rules and the 1 MiB limit; video window; send buffer; loss counters
  and report values.
- **Loopback fakes** (`tests/common`: console, Takion server, network-test server, media
  sources; no network beyond 127.0.0.1) and a lossy proxy (drop, duplicate, delay/reorder per
  direction): discovery, registration (fake PS5 and PS4 9.0 decrypt the request like a
  console), session request and negotiation, the control channel (full PS5 conversation, old
  PS4 forms, fallbacks, resend, failures), the transport (handshake retries, reliable
  delivery through loss, TSN wraparound, fragmentation, retransmission timing, key exchange
  and refresh past 45 000 bytes, video reordering, congestion reports, a supplied socket),
  the network test and cloud probe, whole console and cloud sessions through
  `runner::Session` with every quit reason and stage.
- **Media** (`tests/media.rs`, `tests/media_session.rs`): media headers of every version;
  frames, FEC recovery and failure, profile switching, slice parsing for both codecs, the
  H.265 rewrite over several slices with emulation prevention at all 8 bit alignments,
  references by full POC and long-term pictures, the PS5 cloud slice headers replayed into
  a strict decoder model (`StrictH265Decoder`, which numbers pictures like a real decoder and
  records wrongly resolved references) in all three missing-reference modes
  (`ps5_cloud_loss_is_hidden_until_the_recovery_picture`,
  `ps5_cloud_loss_uses_a_long_term_picture`, `ps5_cloud_loss_is_withheld_until_a_keyframe`,
  `ps5_cloud_recovery_picture_after_a_gap_is_misnumbered`) and the keyframe timing of hidden
  and withheld runs; packed and single-unit Opus audio of a 440 Hz tone with losses, long
  packets, packed cloud datagrams, level diagnostics; haptics; controller state and history
  bytes; feedback events; microphone packing; captures; an encrypted PS5 console stream and a
  PS5 cloud slot end to end.
- **C interface** (`tests/c_api.rs`, declarations in `tests/capi/mod.rs`): every function
  declared as `extern "C"` as the header declares it and checked against the library
  function's type; discovery, registration, console and cloud sessions, captures, every
  missing-reference mode, counters, thread roles, the cloud probe and the self test driven
  through raw pointers, C strings, `extern "C"` callbacks and a user pointer; bad input (NULL
  pointers and handles, non-UTF-8 strings, values out of range) answers
  `CON_ERR_INVALID_ARGUMENT`, never `CON_ERR_PANIC` or an abort.
  `abi_2_layouts_are_unchanged` freezes size, alignment and every offset of ABI 2;
  `header_is_generated_from_the_rust_definitions` generates the header with the cbindgen
  library, checks every `#define` against the Rust value (and the `u` suffix of unsigned
  ones), that it declares exactly the functions of `tests/capi`, and that it equals every
  header `build.sh` wrote in `work/engine-rust` (fails with "run Engine/build.sh" when
  `src/ffi` changed since); `header_compiles_with_the_rust_layouts` compiles it as C11 and
  C++17 (`-Wall -Wextra -Werror -pedantic`) with `_Static_assert`s from the Rust layouts
  (needs `cc`). Unit test `ffi::tests::a_panic_never_crosses_the_boundary`.
- `cargo clippy --all-targets` is clean with and without `opus`, and for the library on
  `x86_64-pc-windows-msvc` and `aarch64-unknown-linux-gnu`; `tools/link_check.rs` builds with
  `-D warnings`.

## Choices and assumptions

- Open points are listed in [QUESTIONS.md](QUESTIONS.md).
- **Account id byte order** (04 §5): the engine takes the 8 wire bytes as given;
  `account_id_le` (the established clients' order) and `account_id_be` (what Con passes) are
  helpers. The choice stays with the caller.
- **Discovery destinations:** the application supplies the directed broadcast addresses
  (`DiscoveryConfig::extra_destinations`); the service always sends to them and to the main
  destination (question 9). The default bind is IPv4 any, ports 9303–9319 first.
- **Strictness:** the session response is parsed strictly as described; discovery,
  registration and control responses tolerantly (bad lines skipped), as the description
  permits.
- **Console signature** in the key exchange can be checked with
  `verify_public_key_signature`, but nothing rejects on a mismatch (04 §4.2). The server's
  BANG signature is checked and only logged on a mismatch.
- **Stop during a TCP connect** takes effect after the connect attempt (at most its timeout).
- **Transport:** duplicates before the data window are re-acknowledged (question 22);
  acknowledgement waits accept later cumulative TSNs; the console network test reports 576
  for a direction where even the smallest candidate failed (as "Result = min" implies); send
  errors on the UDP socket are logged, only receive errors fail the transport; there is no
  silence timeout while streaming (the description names none).
- **Feedback packets before the keys exist** go out with key position 0, no tag and no
  encryption (the description only defines the rule for key positions); the stream only sends
  them after stream info, when the keys exist.
- **Media:** the video receiver uses the requested codec, never the packet's codec byte (so
  the cloud codec-3 override is implicit); a profile switch takes effect at the first datagram
  with the new index, as described; a source unit shorter than its 2-byte padding count is
  rejected; an FEC unit shorter than `L` is zero-padded for recovery; a decoder error plays
  the frame as concealment; haptics frames are delivered whatever their length (Con's app
  checks 1–4096 bytes, multiple of 4); audio headers outside 1–8 channels, 8–192 kHz or
  1–5760 samples, or with more than two channels, are handed over as Opus packets; the engine
  logs "audio header: …", "audio: opus decoder …", "audio: datagram size …", "audio: cloud
  datagrams are packed …" and the level lines for Con's diagnostics.

## Open work

- Internet connections to a console (not described in this folder yet): relay transport, hole punching,
  PSN registration transport (its key derivation exists), the relay counter quirks and the
  relay hand-over to the stream (01 §9).
- Console streams (not cloud) and LAN registration have not been checked against hardware:
  the console streams' slice headers, codec byte, haptics rate and pad-info fields, the
  microphone format, and the don't-fragment option on each platform.
- H.264 repair, B pictures and pictures with several active references (question 53).
- The link check runs on macOS and Linux hosts only; Android and Windows libraries are
  linked but not run by `build.sh`.
- The questions still open in [QUESTIONS.md](QUESTIONS.md).
