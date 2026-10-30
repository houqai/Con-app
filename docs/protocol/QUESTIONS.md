# Questions from the implementation

Questions the description in this folder leaves open, with the section each concerns and the
reading the engine (`Engine/`, Rust) uses until it is answered.

## Session, registration and discovery

1. **01 §6.7.1 — clock of the fallback session id.** "The number of whole seconds of a
   monotonic clock": which clock and which origin (system uptime, process start, other)? Does
   the console care about the value at all?
   *Assumption:* seconds since the engine first needed the clock in this process.

2. **01 §6.7.5 — keyboard text length larger than the payload.** For `0x0021` (length at 28)
   and `0x0024` (length at 8), what happens when the declared length T is larger than the bytes
   that follow (or smaller)? *Assumption:* the text is cut to the bytes present; extra bytes
   after T are ignored.

3. **01 §6.4 — largest control message.** The reference fails above 504 payload bytes; a new
   engine "may accept larger messages". Is any message known to be larger (keyboard text)?
   *Assumption:* payloads up to 64 KiB are accepted; a larger length fails the channel.

4. **01 §6.9 / §6.6 — send failures on the control channel.** Only receive errors are said to
   fail the channel. Does a failed send (for example a heartbeat reply) fail it too?
   *Assumption:* no; the error goes back to the caller (application command) or is ignored
   (heartbeat reply, feature burst), and the channel's state is unchanged.

5. **01 §3.2 / §3.5 — addresses tried by the 2nd and 3rd session request.** After version
   negotiation, is the repeated request sent only to the address that answered first, or are all
   resolved addresses tried again? *Assumption:* only the address that answered.

6. **01 §6.3 — strictness of the control response parser.** The session response is strict
   (empty value or a line without a colon = invalid, §3.4). Is the control response parsed the
   same way? *Assumption:* tolerant (bad lines skipped); only the status, `RP-Server-Type` and
   `RP-Prohibit` matter.

7. **01 §6.7.6 — `RP-Prohibit: 1` and the guard flags.** It reports "cannot display = true". Does
   it also arm the guard or mark blacked out (which decides whether a later `0x0001 00` clears
   it)?
   *Assumption:* the flags are not changed.

8. **04 §1.4, 01 §3.5 — console family vs. target family.** Two rules can give a PS5 console a
   PS4 target (the `5.0` → PS4/9.0 negotiation rule "applied even for a PS5", and a PS5 below
   8050000 labelled PS4-8/9/10). In that case, which family decides (a) the `PS4-`/`PS5-` prefix
   of the registration response fields, (b) the registration probe `SRC2`/`SRC3`, (c) the
   PS5-only launch specification members, (d) the stream transport version 9/12?
   *Assumption:* the family of the target everywhere.

9. **04 §1.6 — search destinations.** The engine follows the recommendation and always sends each
   search to the main destination (default `255.255.255.255`) **and** to every extra (directed
   broadcast) address. The extra list is supplied by the application (the engine has no portable
   interface listing without platform code). Please confirm this is the wanted behaviour, and
   whether the 255.255.255.255 send should be kept when directed broadcasts are known (consoles
   then answer twice; answers are merged by `host-id`, so it is harmless).

10. **04 §2.8 — size limits of the registration response.** The reference accepts at most 1500
    bytes of header plus body. *Assumption:* up to 64 KiB is accepted; `Content-Length` 0 or
    above 64 KiB is invalid.

## Transport, network test and stream connection

11. **02 §6.4 vs 03 §4 — microphone unit word.** 02 gives `0x00022821` (unit index 0, "units − 1"
    = 2, descriptor 0x2821); 03 gives `0x02002821` but describes it with the same fields, which
    in the audio layout would be unit index 2 and one unit. *Assumption:* `0x00022821`.

12. **02 §7.3 — key position request of a DATA chunk.** "*s* = length of the message data in
    the chunk": does that include the data-type byte of a first fragment? *Assumption:* no —
    only the data bytes after it (for continuations: all bytes after the 8-byte header). A
    heartbeat (`08 03`) therefore advances the position by 4.

13. **02 §11.4 vs 04 §3.1 — BANG field 6.** 02 says "extended info (event code, §11.2)", wire
    type 2; 04 says "enum". A strict decoder would reject the whole BANG if the console sent the
    other form. *Assumption:* the field is an event-code sub-message, and generally an
    **optional** field that arrives with an unexpected wire type is skipped (required fields
    with the wrong wire type still fail the message).

14. **02 §11.5 vs 03 §4 — client microphone audio header.** 02: `01 10 0000BB80 000001E0
    00000000` with the full encoding; 03: last word `00000001`. *Assumption:* 02's bytes.

15. **02 §8.1 vs 03 §7.1 — expected video units of a frame.** 02: "expected source + FEC
    units"; 03: `k + max(m, 1)`, which reports one lost unit for every frame without FEC units.
    *Assumption:* 03's `k + max(m, 1)`. Please confirm (it changes what consoles see when they
    send frames with 0 FEC units).

16. **02 §8.1 — PS5 cloud audio "one count per new frame index".** *Assumption:* a packet is
    counted when its frame index differs from the last counted one (the three packets of a
    frame arrive together).
    *Answer:* 03 §3.3 — a frame is counted once, when it is taken, i.e. when its
    index is newer than the newest taken so far; late copies of older frames are not counted.
    Empty audio datagrams are not counted in either mode.

17. **02 §9.5 — cloud probe "if neither the first candidate nor the minimum (576) gets an
    answer, the MTU test stops early".** *Assumption:* when the first candidate fails, the
    probe tries 576 next (same attempts); if 576 fails too the direction is reported as 0
    (unmeasured); otherwise the binary search continues with 576 confirmed.

18. **02 §9.4 — outbound MTU search.** "Binary search as above, starting with `cur` = inbound
    result": is the range still 576…1454 (so the search may go above the inbound result), and
    what is the "attempt number" in the probe's unit index? *Assumption:* range 576…1454, first
    candidate the inbound result; the unit index counts every outbound probe sent (0, 1, 2 …).
    The final command 4 carries the search's final `max` (1454 if the first candidate passed).

19. **02 §4.2 — INIT-ACK with another header tag than the client tag; other datagrams during
    the handshake.** *Assumption:* both are "invalid replies" (a failed attempt, INIT or
    COOKIE-ECHO re-sent at once); only a repeated INIT-ACK while waiting for COOKIE-ACK is
    skipped.

20. **02 §9.1 — "wait for a DATA-ACK whose cumulative TSN equals that message's TSN".**
    *Assumption:* a cumulative TSN after it also counts (it acknowledges the message too).

21. **02 §9.5 — cloud probe steps not mentioned.** Does the probe also turn echo on/off with
    acknowledgement waits, run the outbound test only when the inbound one measured something,
    and end with a DISCONNECT? *Assumption:* yes to all three, as in the console test.

22. **02 §5.3 — re-acknowledging duplicates.** The reference does not; the engine sends a
    DATA-ACK for the last delivered TSN when a TSN before the window arrives (allowed by the
    description; it stops server retransmissions after a lost acknowledgement). Please say if
    a console is known to dislike extra acknowledgements.

## Media: video, audio, haptics, controller feedback

23. **03 §3.2 / §3.4 — order in which the units of a packed audio datagram reach the jitter
    buffer.** In unit order (new frame first, then the copies of F−r … F−1) the jitter rules
    conceal a frame as soon as one newer frame is buffered with fewer than 3 buffered, so the
    copy that arrives a moment later is already "older than the next frame" and discarded:
    the redundancy never fills a gap, contrary to "a lost datagram's frames are filled in from
    the copies". *Assumption:* the engine offers the units oldest first (copies F−r … F−1, then
    the new frames), as Con's PS5 cloud haptics handling does (03 §3.5). Please confirm what the reference
    does and whether consoles rely on it.

24. **03 §5.3 — a new finger in the same touch slot.** "If the touch id changed and the old
    touch was active → a lift event; *otherwise* if a touch is active and (new id, or moved) →
    down/move". Read literally, an update that replaces finger A by finger B in one step sends
    only A's lift, and B's down only when B later moves. *Assumption:* both events go out in
    the same update (lift of A, then down of B).

25. **03 §2.7 — H.265 rewrite to a distance the slice cannot express.** When the first
    remembered frame is at a distance r′ ≥ num_negative_pics of the slice's explicit RPS,
    there is no flag to set. *Assumption:* no rewrite; the picture is not delivered and counts
    as one lost frame (as for H.264).
    *Resolved:* the search runs over the slice's own RPS pictures (older than the first used
    one), matched by POC (question 38): a picture the RPS does not list is not in the
    decoder's buffer, so it cannot stand in anyway. Without one, the picture is not delivered.

26. **03 §4 — microphone unit order and silence.** The engine fills the three units as the
    layout of §3.2 says ([F][F−2][F−1]), not as the reference ([newest][previous][newest]);
    both are said to be accepted. Which should be used? Also: with the libopus the engine
    builds (1.5 line), restricted-low-delay at the 40-byte limit encodes digital silence to
    40 bytes as well, so the "silent frames are skipped" effect does not happen; silence is
    sent. Is that acceptable, or should the engine skip silent input itself?

27. **03 §2.6 — the "FEC failure" app event without the IDR option.** The reference emits it
    only when "request IDR on FEC failure" is on. *Choice:* the engine emits
    `StreamEvent::FecFailure` for every FEC failure (with `idr_requested` false when no request
    was sent); the app may ignore it. Say if this must follow the reference.

28. **03 §2.6 / §2.9 — frames that never arrived.** Lost-frame counters grow only on FEC
    failure (by the range since last-complete) and on a missing reference. A frame of which no
    datagram arrived, followed by a complete IDR, is reported in a corrupt-frame report but not
    counted in "frames lost since the previous delivery". *Assumption:* that is intended
    (followed as written). Con's app should not read the count as "frames missing".

29. **03 §2.7 — H.264 reference list modification.** "For idc 0 the value
    abs_diff_pic_num_minus1 is the reference distance r": if several idc-0 entries are present,
    which one? *Assumption:* the first (it sets reference index 0). An idc-1 entry before it
    is skipped as described.

30. **03 §5.3 — history payload queue full (64).** Which payload is dropped? *Assumption:* the
    oldest queued one (every newer payload repeats its events).

## C interface

Raised by Con's app (`Sources/SoleEngine/RustEngine.swift`); all are resolved.

31. **Cloud network test before the allocation.** Con measures every data centre before it
    asks for a slot: round trip and MTU in and out through the cloud probe (02 §9.5), with the
    probe's credential and the datagram prefix, plus how far a failed test got.
    *Resolved:* `con_cloud_probe_run` (blocking) and `con_cloud_probe_start` / `_cancel` /
    `_free` (own thread, callback once) with `ConCloudProbeConfig` (address, port, credential,
    prefix, every probe timing, MTU on/off) and `ConCloudProbeResult` (`rtt_us`, samples,
    `mtu_in`, `mtu_out` with 0 = not measured, `CON_PROBE_*` status, `CON_PROBE_STAGE_*`
    reached, hello echoed, error text). Several may run at once.

32. **Round trip of a cloud slot known before the stream.** Con has measured the slot's data
    centre (question 31). Does the engine need a starting round trip before its own
    measurements, and which value does it take?
    *Resolved:* `ConCloudConfig.rtt_us`. The description has the RTT among the slot's inputs
    (01 §10, default 1 ms) but nothing on the wire depends on it: retransmission is a fixed
    200 ms, congestion reports do not carry it, and the cloud launch specification is the
    service's text. The engine logs it and reports it as the stream's round trip until its
    first own measurement (`rtt_samples` stays 0 until then). See question 42.

33. **Priority of the engine's threads.** On macOS Con gives the threads that receive and send
    the stream the interactive class of service.
    *Resolved:* `con_set_thread_callback(callback, user)`: every engine thread calls it on itself
    before its work with its role (`CON_THREAD_IO` — receives the stream and calls the media
    callbacks — `SENDER`, `SESSION`, `CONTROL`, `STATISTICS`, `DISCOVERY`, `REGISTRATION`,
    `PROBE`, `CAPTURE`, `HELPER`) and name; `con_thread_set_interactive()` applies the
    platform's interactive priority to the calling thread (Apple: QoS class user interactive
    through `pthread_set_qos_class_self_np`; Linux/Android nice −8; Windows
    `THREAD_PRIORITY_HIGHEST`).

34. **libopus symbols in the static library.** A program that links `libcon_engine.a` and
    another libopus gets one copy for both, chosen by the linker.
    *Resolved:* `Engine/build.sh` renames all ~440 global libopus symbols to `con_*`
    (definitions and references, `llvm-objcopy --redefine-syms`), checks that no old name is
    defined or used, and links a program with its own `opus_*` functions beside the library.
    Libraries built by plain `cargo build` keep the names.

35. **Stages of a failed connection.** The quit reason names the step that failed; for a stream
    that ends during the transport handshake, is there a stable way to tell the steps apart?
    *Resolved:* `ConQuitEvent.stage` (`CON_STAGE_SESSION_REQUEST`, `CONTROL`, `NETWORK_TEST`,
    `TRANSPORT`, `KEY_EXCHANGE` = hello sent, waiting for BANG, `STREAM_INFO`, `STREAMING`) and
    `con_stage_name`.

## Video references

37. **03 §2.7 — further references of a P picture.** Only the reference at the first used
    flag is checked; a P slice may use several pictures. *Choice:* every used negative
    picture must be remembered; missing ones after the first stop being used (H.265, explicit
    RPS); if that is impossible (RPS from the SPS or predicted, or
    `lists_modification_present_flag` with a changed number of used pictures) the picture is
    not delivered. Please say whether the reference does this.

38. **03 §2.7 — which picture an RPS entry is.** The description maps negative picture *i* to
    frame `this − i − 1` ("POC step of one per frame"), which also assumes every
    `delta_poc_s0_minus1` is 0. *Choice:* pictures are identified by their full POC (H.265,
    question 45) and `frame_num` (H.264 reference pictures): entry *i* is the picture with POC
    `this + DeltaPocS0[i]`; the frame-index rule is kept for pictures whose id is unknown.
    Identical when the deltas are 1. Are console streams known to use other deltas or POC
    steps? The POC LSB alone is not enough: the PS5 cloud LSB has 4 bits and repeats within
    the 16 remembered pictures. PS5 cloud streams have deltas of 1 and a POC step of 1 per
    frame.

39. **03 §2.7 — rewrite of a picture with several slices; emulation prevention.** The
    description rewrites "the slice header"; H.265 requires the same RPS in every slice segment
    of a picture, and a flipped bit can create a start-code pattern. *Choice:* every
    independent slice segment is rewritten and each changed NAL is re-escaped (it may grow).
    Does the reference rewrite only the first slice, and do console/cloud streams have more
    than one slice per picture?
    *Answer (PS5 cloud):* both occur: one slice per picture, and 3–12 slices per picture (all
    with the same RPS), within one stream.

40. **03 §2.2 / §2.7 — remembered references after new parameter sets or an IDR.**
    *Choice:* they are forgotten at a profile switch and when the decoder accepts an
    IDR/IRAP picture, so P pictures of a new profile before its keyframe are not delivered
    (counted lost). Please confirm.

41. **03 §2.7 — the actual header settings of the streams.** The parser now reads
    `num_extra_slice_header_bits`, `output_flag_present_flag`, short-term RPS sets in the SPS,
    `lists_modification_present_flag`, dependent slice segments, and for H.264 POC types 0/1
    and field coding, where the description assumed them absent. Which of these do PS4/PS5
    console and cloud streams use?
    *Answer (PS5 cloud H.265):* none of them — no extra slice header bits, no
    output flag, no RPS sets in the SPS (every RPS explicit, one negative picture), no list
    modification, no dependent slices. But **long-term reference pictures** are present
    (question 44), with `log2_max_pic_order_cnt_lsb` 4. PS4 cloud and PS4/PS5 console
    streams have not been examined.

42. **01 §10 / 02 §9.5 — the slot's RTT.** Listed as a slot input with a default of 1 ms;
    is it used anywhere besides the service's launch specification (which already carries
    it)? *Choice:* shown as the round trip until the stream's own first measurement.

43. **03 §2.7 — pictures of several slice types.** The description reads only the first
    slice ("I slices … are delivered unchanged"; "an I slice ends the wait"). With intra
    refresh a P picture can begin with an I slice. *Choice:* all slices are read; the
    references are checked when any slice is a P slice, and only a picture of I slices only
    (or an IRAP picture) ends a wait for an IDR.

## Long-term pictures and audio

44. **03 §2.7 — long-term reference pictures.** PS5 cloud H.265 streams set
    `long_term_ref_pics_present_flag` and list one or two long-term pictures in nearly every
    slice; after a corrupt-frame report the server sends pictures that use only a long-term
    picture. The description does not mention long-term pictures. *Choice:* they are read
    and checked like short-term ones, and when no short-term picture of the RPS can replace
    a missing reference, the nearest remembered long-term picture (with its used flag coded
    in the slice) stands in. Does the reference do this, and do PS5 consoles use long-term
    pictures too?

45. **03 §2.7 / question 38 — picture ids.** *Answer:* the PS5 cloud stream has
    `log2_max_pic_order_cnt_lsb` 4, so the POC LSB repeats every 16 pictures — as many as
    the client remembers. Matching by LSB takes a picture 16 frames back for a lost one;
    pictures are matched by the full POC derived as in H.265 8.3.1
    (and H.264 `frame_num` counted past its wrap). The description's frame-index rule
    ("POC step of one per frame") gives the same picture here (deltas are 1, POC steps by
    1), but only while no picture is lost or rejected.

46. **03 §2.7 — what the decoder still holds.** *Choice:* after an accepted H.265 picture,
    remembered pictures its RPS does not list are forgotten (they are unused for reference
    from then on, H.265 8.3.2), so a long-term picture stays as long as RPSs list it, even
    beyond 16 frames. A rejected picture's RPS is not applied (the decoder may have stopped
    before it). Pictures listed only "for later use" may be missing: VideoToolbox accepts
    such pictures. Please confirm the reference's rule (it remembers 16
    accepted frames only).

47. **03 §3.1 — Opus packets longer than the header's frame size.** "Decodes at most frame
    size samples per channel": a longer packet then fails and is concealed, which is silence
    for every packet. *Choice:* the engine decodes up to 120 ms per packet and delivers all
    samples; concealment has the length of the last decoded packet. Is the header's frame
    size known to differ from the packets on some servers?

48. **03 §3.3 — PS5 cloud layout.** A PS5 cloud stream was seen with about one audio
    datagram per played frame, not three. *Choice:* in single-unit mode a datagram whose
    unit word describes its payload exactly as two or more units is unpacked like 03 §3.2.
    Is the PS5 cloud layout known to change between servers or sessions?

49. **Silent PS5 cloud game audio.** Packets arrive and are played, the decoded PCM stays
    below ±64 for the whole stream; other streams have sound, and the earlier engine
    sometimes had none as well. Is there a known server condition in which the stream carries
    silence (game audio routed elsewhere — e.g. to the controller or a headset after the
    controller-connection message —, the unknown last field of the audio header, the audio
    channel entries of the stream info, field 7), or anything the client must send for game
    audio to start?

## Withholding pictures

50. **03 §2.7 — repair or withhold.** The description repairs a picture whose reference is
    missing (H.265 rewrite) and delivers it; on Android the repaired pictures and those built
    on them show smeared content until the server's recovery picture. *Choice:* withholding
    is a mode (`MissingReference::Withhold`): such pictures are withheld until one whose used
    references are all with the decoder (or a keyframe), with a keyframe request after
    300 ms. The default repairs and hides (question 52).
    How does the reference client present the frames between a loss and the server's
    recovery picture, and does it ever request keyframes on its own after a loss?

51. **H.265 picture numbering after withheld pictures.** A decoder derives a picture's POC
    MSB from the last picture it got (H.265 8.3.1). PS5 cloud streams have
    `log2_max_pic_order_cnt_lsb` 4, and the server's recovery picture comes 9–11 frames after
    a loss — more than the 8 a decoder can bridge — so after withheld pictures it would
    misnumber the recovery picture and resolve its long-term reference to another picture
    (for example the IDR instead of the intended long-term picture). *Choice:* such pictures
    are not shown (withheld, or hidden in the default mode) and a keyframe is requested at
    once; in withhold mode every PS5 cloud loss then ends in a keyframe. Is anything known about how the server picks the POC LSB length, or whether it
    can be made longer (stream info, launch specification)? Do PS5 consoles (not cloud) use
    the same length? Also: *choice* — an FEC failure no longer counts again the frames
    already counted as withheld (03 §2.6 counts from the last complete frame).

## Hiding repaired pictures

52. **03 §2.7 — showing repaired pictures.** The description repairs and delivers; it does not
    say whether the reference client displays the repaired picture and those built on it.
    *Choice:* they are decoded but not displayed (flag "decode only"); the screen keeps the
    last good picture until the first picture whose used references are all genuine (the
    server's recovery picture) or a keyframe; a keyframe is requested when nothing has been
    shown for 500 ms, at once when the decoder's picture numbering broke (a burst longer
    than half the POC LSB range). Does the reference client hide such pictures, freeze
    otherwise, or show them? Does the server's recovery picture always use only pictures
    from before the reported range (recorded PS5 cloud losses show it)?

53. **Pictures whose references cannot be read.** *Choice:* such a picture (or one with B or
    other slices) is treated as tainted, and hidden, while any picture the decoder still
    holds is tainted; otherwise it is treated as clean. Only H.265 P pictures with a readable
    RPS and H.264 P pictures with a known reference are checked one by one; H.264 checks only
    the first reference (question 37). Is anything known about streams with B pictures or several active
    references (PS4/PS5 consoles at other settings)?
