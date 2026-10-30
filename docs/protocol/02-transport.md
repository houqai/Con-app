# 02 — Datagram transport ("Takion") and the stream connection

This part describes the UDP transport that carries a stream between the client and a console
(or a cloud streaming server), the authentication and encryption of its packets, the loss and
congestion reports, the network test that precedes a console stream, and the protobuf
messages exchanged over the transport's reliable message service.

Conventions:

- All multi-byte integers on the wire are **big-endian** unless a line says otherwise.
- Offsets are **from the first byte of the UDP payload** (the Takion packet) unless a table
  says "relative to …". On cloud connections a 4-byte routing prefix is put in front of every
  datagram the client sends (§2.3); offsets never include it.
- "Client" is Con; "server" is the console or cloud server. "Reference" means the observed behaviour
  of an existing implementation; where that behaviour is a choice rather than a
  protocol requirement it says so.
- **Con** marks behaviour Con adds or changes relative to the reference. **Uncertain** marks
  facts that could not be confirmed from the reference.
- Media payload formats (video units, audio units, FEC, haptics PCM) and the contents of
  controller feedback are in `03-media.md`. The session request, the control channel and the
  "RP" cipher used to encrypt the launch specification are in `01-session.md`. The launch
  specification's JSON content is in `04-registration.md`. Cloud slot allocation, the relay
  and hole punching are not documented here.

---

## 1. Overview

The transport is a reduced SCTP (RFC 4960) look-alike over plain UDP:

- One UDP 5-tuple per connection. There is no IP-level multiplexing: each datagram carries
  exactly one Takion packet, and a control packet carries exactly one chunk.
- A 4-way handshake (INIT, INIT-ACK, COOKIE-ECHO, COOKIE-ACK) establishes a pair of
  32-bit verification tags.
- A reliable, ordered message service ("data chunks") with 32-bit transmission sequence
  numbers (TSN), cumulative acknowledgements, retransmission and fragmentation. It carries
  protobuf messages and a few small binary messages.
- Unreliable media packets (video, audio, haptics) with their own 16-bit indices.
- Unreliable client→server packets: controller state, controller event history, microphone
  audio, congestion (loss) reports.
- After a key exchange carried inside the first protobuf messages, every packet is
  authenticated with a 4-byte AES-GCM tag, and media/feedback payloads are encrypted with
  AES-128-CTR, both driven by a per-direction "key position" counter.

Two independent transport connections exist during a console session, one after the other:

| Purpose | Server UDP port | Transport version | Crypto |
|---|---|---|---|
| Network test ("Senkusha", §9) | 9297 | 7 (media header layout) | none |
| Stream connection (§10) | 9296 | 9 (PS4) or 12 (PS5) | yes |

For a cloud slot the network test and the stream go to the port the cloud service assigns
(§2.3).

---

## 2. Socket setup

### 2.1 Console (local network)

- UDP socket of the address family of the selected console address, `connect()`ed to the
  console address and port 9296 (stream) or 9297 (network test). The client's local port is
  ephemeral.
- Receive buffer (SO_RCVBUF) set to 0x19000 (102 400) bytes — the same value the client
  advertises as its receiver window.
- Don't-fragment: set for the network test and, by default, for the stream (IPv4
  DF / path-MTU-discovery "do"). If the network test fails, the stream is opened with
  don't-fragment cleared. On a platform where the option cannot be set the reference just
  continues.
- Datagrams are read into a 1500-byte buffer; anything longer is truncated by the read.
  Windows reports such a read as an error (`WSAEMSGSIZE`, 10040) with the buffer filled; it
  is taken as the truncated datagram, not as a failure of the connection. A receive whose
  wait ran out is sometimes reported by Windows as `ERROR_IO_PENDING` (997) instead of a
  timeout; it is taken as a timeout.

### 2.2 Externally supplied socket (PSN remote play)

When the data path was opened by hole punching (not documented here), the transport is given an
already-connected socket instead of creating one. The network test and the stream then use
that **same** socket one after the other (the network test does not close it). Before the
handshake on such a socket the client drains datagrams already queued: it reads and discards
datagrams until 200 ms pass without one, or at most 1 s in total. The receive buffer is then
set as above.

### 2.3 Cloud slot — **Con**

- Destination: the slot's public address and the UDP port the slot was allocated (not 9296).
- Receive buffer 4 MiB (0x400000). This is local only; the advertised window stays 0x19000.
- Don't-fragment cleared.
- **Datagram prefix.** If the slot has a non-zero "wrapper" byte *P*, every datagram the
  client sends is prefixed by 4 bytes `00 00 00 P` and the Takion packet follows. The prefix
  is added after the packet is complete and is not covered by the authentication tag. Con
  uses *P* = the slot's wrapper type (1 for PS4/PS3 cloud; 0 = no prefix for PS5 cloud), and
  for the cloud network probe *P* = 1 for non-PS5 back ends. Datagrams received from the
  server carry **no** prefix (the reference parses them from byte 0, and live PS4 cloud
  streams with *P* = 1 work).
  **Uncertain:** a comment in the reference calls *P* "the last octet of the slot's private
  address"; the value actually passed is the slot's wrapper type.

---

## 3. Packet types

The low nibble of byte 0 is the packet type. The high nibble is 0 except for media packets,
where bit 4 (0x10) is a flag (§6).

| Type | Name (this document) | Direction | Reliability | Auth tag | Payload encrypted |
|---|---|---|---|---|---|
| 0 | Control (one chunk) | both | chunk-dependent | yes | no |
| 1 | Controller event history | client→server | unreliable | yes | yes |
| 2 | Video | server→client (also used as MTU probe reply) | unreliable | yes | yes |
| 3 | Audio / haptics / microphone | both | unreliable | yes | yes |
| 4 | (handshake) | — | — | — | — |
| 5 | Congestion report | client→server | unreliable | yes | no |
| 6 | Controller state | client→server | unreliable | yes | yes |
| 8 | (client info) | — | — | — | — |

Types 4 and 8 are known names but the reference never sends them and drops them on receipt.
The client acts on received types 0, 2 and 3 only; anything else is dropped.

### 3.1 Position of the authentication tag and key position

Every authenticated packet carries a 4-byte tag ("GMAC") and the low 32 bits of the sender's
key position (§7):

| Type | GMAC offset (4 bytes) | Key position offset (4 bytes, BE) | Key position field zeroed while computing the tag? |
|---|---|---|---|
| 0 Control | 5 | 9 | **yes** |
| 2 Video, 3 Audio | 10 | 14 | no |
| 5 Congestion | 7 | 11 | **yes** |
| 1, 6 Feedback | 8 | 4 | no |

---

## 4. Control packets and chunks

### 4.1 Common layout

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | 0x00 (packet type 0) |
| 1 | 4 | Verification tag: the **receiver's** tag (0 in INIT) |
| 5 | 4 | GMAC (zero while not authenticated) |
| 9 | 4 | Key position, low 32 bits (0 while not authenticated) |
| 13 | 1 | Chunk type |
| 14 | 1 | Chunk flags |
| 15 | 2 | Chunk length = chunk payload length + 4 |
| 17 | n | Chunk payload |

Datagram length is always `13 + chunk length` (i.e. `17 + n`). On receipt the client checks
that the length field matches the datagram length exactly and that the verification tag
equals its own tag; otherwise the packet is dropped.

Chunk types:

| Value | Chunk | Payload size |
|---|---|---|
| 0x00 | DATA | ≥ 8 (see §5) |
| 0x01 | INIT | 16 |
| 0x02 | INIT-ACK | 48 |
| 0x03 | DATA-ACK (SACK) | 12 |
| 0x0A | COOKIE-ECHO | 32 |
| 0x0B | COOKIE-ACK | 0 |

### 4.2 Handshake

Constants: advertised receiver window **0x00019000**, outbound streams **100 (0x64)**,
inbound streams **100 (0x64)**.

The client chooses a random non-zero 32-bit **client tag** *Tc*. Its first outgoing TSN equals
*Tc*.

**INIT** (client→server, 33-byte datagram). Header tag 0, GMAC 0, key position 0, flags 0,
length 20. Payload:

| Offset in payload | Size | Field |
|---|---|---|
| 0 | 4 | Initiate tag = *Tc* |
| 4 | 4 | Receiver window = 0x00019000 |
| 8 | 2 | Outbound streams = 100 |
| 10 | 2 | Inbound streams = 100 |
| 12 | 4 | Initial TSN = *Tc* |

**INIT-ACK** (server→client, 65 bytes). Header tag = *Tc*, flags must be 0. Payload: server
tag *Ts* (4), receiver window (4), outbound streams (2), inbound streams (2), initial TSN (4),
cookie (32 bytes, opaque). The client requires: *Ts* ≠ 0; server outbound streams ≥ 1 and
≤ 100; server inbound streams ≥ 100. A datagram shorter than 65 bytes, not type 0, or with a
different chunk type/flags is a failed attempt.

**COOKIE-ECHO** (client→server, 49 bytes). Header tag = *Ts*, GMAC 0, key position 0, flags
0, length 36, payload = the 32 cookie bytes unchanged.

**COOKIE-ACK** (server→client, 17 bytes). Header tag = *Tc*, flags 0, no payload. If the
first datagram received while waiting for it has byte 13 = 0x02 (a repeated INIT-ACK), the
client reads one more datagram and checks that one.

Timing: the client sends INIT and waits up to **5 s** for INIT-ACK; on timeout or an invalid
reply it re-sends INIT, up to **3 attempts** in total. The COOKIE-ECHO/COOKIE-ACK step uses
the same rule (3 attempts × 5 s). Handshake packets are never authenticated and are sent
directly, not through the retransmission buffer. (The stream connection itself only waits
5 s for the transport to come up, §10.3, so on a stream a second attempt is usually moot.)

**Receive sequence start.** After the handshake the client expects the server's first DATA
TSN to be:
- console: *Ts* (the reference ignores the initial TSN field of INIT-ACK);
- cloud: the initial TSN announced in INIT-ACK. **Con**

**Uncertain:** whether a console's announced initial TSN always equals its tag.

After the handshake all control packets the client sends carry *Ts* as verification tag.

### 4.3 DATA chunk

Chunk flags of a DATA chunk: bit 0 (0x01) = **last fragment** of a message ("complete").
Other bits are 0.

Payload layout of the **first (or only) fragment**:

| Offset in payload | Datagram offset | Size | Field |
|---|---|---|---|
| 0 | 17 | 4 | TSN |
| 4 | 21 | 2 | Channel (stream identifier) |
| 6 | 23 | 2 | Reserved, 0 |
| 8 | 25 | 1 | Message data type |
| 9 | 26 | n | Message data |

A **continuation fragment** has the same layout without the data-type byte: TSN (4),
channel (2), reserved (2), data from payload offset 8 (datagram offset 25).

So a single-chunk message costs 26 bytes of Takion overhead, a continuation 25.

Message data types:

| Value | Content |
|---|---|
| 0 | Protobuf envelope message (§11) |
| 7 | Rumble (≥ 3 bytes) — contents in `03-media.md` |
| 9 | Controller pad info (17 or 25 bytes) — `03-media.md` |
| 11 | Adaptive trigger effects (≥ 25 bytes) — `03-media.md` |

Received messages of any other data type are acknowledged and discarded.

Channels used by the client:

| Channel | Messages |
|---|---|
| 1 | Hello (BIG), heartbeat, disconnect, controller connection, client stream info; network-test protocol request, BIG and disconnect |
| 2 | Corrupt-frame report, IDR request |
| 8 | Network-test commands (echo, MTU, client MTU) |
| 9 | Stream-info acknowledgement |

The channel number has no other effect in the reference sender; the receiver uses it only
for fragment reassembly (§5.4).

### 4.4 DATA-ACK chunk

Payload (12 bytes; datagram is 29 bytes):

| Offset in payload | Size | Field |
|---|---|---|
| 0 | 4 | Cumulative TSN acknowledged |
| 4 | 4 | Receiver window (client always sends 0x00019000) |
| 8 | 2 | Number of gap-ack blocks (client sends 0) |
| 10 | 2 | Number of duplicate TSNs (client sends 0) |

Chunk flags 0. On receipt the client accepts only a payload of exactly 12 bytes with a gap
block count of 0 (a non-zero duplicate count is tolerated). Gap blocks are therefore never
interpreted. **Uncertain:** their layout (presumably 4 bytes each, as in SCTP).

---

## 5. Reliable message service

### 5.1 Sequence numbers and wraparound

TSNs are 32-bit, media indices 16-bit. Both compare with serial-number arithmetic
(RFC 1982): for *n*-bit numbers, *a* precedes *b* iff `a ≠ b` and
`(b − a) mod 2^n < 2^(n−1)`. Equal halves (difference exactly 2^(n−1)) are neither less nor
greater. The client increments its TSN by 1 per DATA chunk sent (fragments each take one
TSN); the server does the same.

### 5.2 Sending and retransmission

Each DATA chunk is transmitted immediately and a copy of the exact datagram (including its
tag and key position) is kept in a **send buffer of 16 entries**.

- A background check runs every **100 ms** while the buffer is not empty. Any entry whose
  last transmission is more than **200 ms** old is re-sent byte-for-byte (same TSN, same key
  position, same tag). So the effective retransmission interval is 200–300 ms.
- After **25 retransmissions** of an entry the client gives up on it: the entry and every
  older entry are removed as if acknowledged (no further notification).
- A received DATA-ACK with cumulative TSN *C* removes every entry whose TSN equals *C* or
  precedes it.
- If the buffer is full when a new chunk is sent, the chunk is still transmitted once but
  not stored (it will not be retransmitted) and the send reports an error.
- **Con — urgent messages.** The corrupt-frame report and the IDR request
  are transmitted twice at once (the second datagram byte for byte the first, as a
  retransmission is): lost on the way up, such a message would wait 200–300 ms for its
  retransmission while the picture stays broken. The peer takes the copy as a duplicate.

**Con — round-trip time.** The time of an entry's first transmission is remembered. When a
DATA-ACK removes an entry that was not given up on, the client records
`now − first transmission` as the latest round-trip sample (and counts samples). A re-sent
message is measured from its first transmission, so above ~200 ms the sample includes the
retransmission delay. Because a heartbeat goes out every second (§10.4) and the server
acknowledges immediately, this gives about one sample per second. Con shows the median of the
last five samples.

### 5.3 Receiving and acknowledging

Incoming DATA chunks pass through a **reorder window of 16 TSNs**, starting at the expected
first TSN (§4.2):

- A TSN before the window start, or one already held, is discarded.
- A TSN that would need the window to grow beyond 16 slots is discarded (the newest is
  dropped, not the oldest).
- Otherwise it is stored; then every consecutive held message from the window start is
  delivered in order (reassembly §5.4, dispatch §10).
- If at least one message was delivered, the client sends **one** DATA-ACK whose cumulative
  TSN is the last delivered TSN. The acknowledgement is sent **after** the delivered messages
  were processed (this matters for the key exchange, §10.2).
- Duplicates are not re-acknowledged by the reference; they become covered by the next
  cumulative acknowledgement. (An implementation may re-acknowledge duplicates; the reference
  simply doesn't.)

### 5.4 Fragmentation and reassembly — **Con**

A message longer than a datagram is sent as a first fragment (with the data-type byte)
followed by continuation fragments (without it), on one channel, with consecutive TSNs. All
fragments except the last carry flags 0; the last carries flags 1. A message that fits in one
datagram is a single first fragment with flags 1.

Receiving (Con's reassembly; the reference drops multi-fragment messages):

1. At most one message is being assembled at a time; it remembers its channel and data type.
2. A delivered chunk is a **continuation** iff a message is being assembled and the chunk's
   channel equals that message's channel. Its header is 8 bytes; otherwise it is a first
   fragment with a 9-byte header. A chunk shorter than its header is dropped and any pending
   assembly is abandoned.
3. A first fragment with flags 0 while another message is pending (on another channel) is
   dropped; the pending message is kept.
4. A first fragment with flags 0 starts an assembly. A continuation appends its data. When a
   chunk with flags 1 arrives as a continuation, the assembled message is complete and
   delivered, and the assembly is cleared.
5. A first fragment with flags 1 is a whole message and is delivered directly (even while a
   message on another channel is pending; that one stays pending).
6. An assembly larger than 1 MiB is abandoned.

### 5.5 Fragment sizes used by the client

The only message the client fragments is the hello (BIG, §11.3). With
*M* = min(MTU in, MTU out) from the network test (§9) or the cloud slot:

| | Console | Cloud (**Con**) |
|---|---|---|
| Budget *B* | *M* − 50 | *M* − 28 |
| First fragment data bytes | *B* − 26 | *B* − 30 |
| Continuation data bytes | *B* − 25 | *B* − 29 |

The cloud figures account for the IP+UDP header (28) and the 4-byte datagram prefix. The
client cuts full-size fragments while the remainder does not fit in one more chunk, then sends
the remainder with flags 1. (Con's cloud network probe uses fixed sizes, §9.5.)

---

## 6. Media packets (types 2 and 3)

### 6.1 Server→client header, transport versions 9 and 12

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | Low nibble: 2 = video, 3 = audio. Bit 4: "extended" flag (see below) |
| 1 | 2 | Packet index (16-bit, per media type, +1 per packet) |
| 3 | 2 | Frame index (16-bit) |
| 5 | 4 | Unit word (below) |
| 9 | 1 | Codec |
| 10 | 4 | GMAC |
| 14 | 4 | Key position, low 32 bits |
| 18 | … | Version-dependent tail (below) |

Unit word (32-bit big-endian):

| | Bits 31…21 | Bits 20…10 | Bits 9…0 |
|---|---|---|---|
| Video | unit index in frame (11 bits) | units in frame − 1 (11 bits) | FEC units in frame (10 bits) |

| | Bits 31…24 | Bits 23…16 | Bits 15…0 |
|---|---|---|---|
| Audio | unit index (8 bits) | units in frame − 1 (8 bits) | audio unit descriptor: bits 15…8 unit size in bytes, bits 7…4 redundant (FEC) units, bits 3…0 source units |

Tail, video (both versions):

| Offset | Size | Field |
|---|---|---|
| 18 | 2 | Unknown 16-bit field |
| 20 | 1 | Bits 7…5: adaptive stream index (selects one of the resolutions announced in stream info, §11.4); bits 4…0 unknown |
| 21 | — | Payload starts here (if bit 4 of byte 0 is set: 3 more unknown bytes at 21…23, payload at 24) |

Tail, audio:

| Version | Layout |
|---|---|
| 9 | Byte 18 unknown; payload at 19 (if the extended flag is set: 3 unknown bytes at 19…21, payload at 22) |
| 12 | Byte 18 unknown; then (after the 3 extended bytes if flagged) one **content marker** byte: 0x02 = haptics (DualSense actuator PCM), anything else = game audio; payload follows the marker (normally at offset 20) |

Minimum datagram sizes the client accepts: video 25 bytes; audio 20 (v9) / 21 (v12).

The payload (from its start to the end of the datagram) is encrypted (§7.4) with the
server→client key stream starting at **key position + 16**. Everything before the payload is
in clear. The first payload byte of a video packet is part of the encrypted payload. How
payloads are assembled into frames, FEC and the codec byte values are in `03-media.md`.

**Con:** a cloud server marks video packets with codec value 3 regardless of the codec
requested; Con treats such a packet as carrying the requested codec.

### 6.2 Version 7 layout (network test only)

Same as above up to offset 17, but with no extra byte at 18 for audio: audio payload starts
at 18; video has the 3-byte tail at 18…20 and payload at 21; the extended flag adds 3 bytes.
In version 7 the unit word is read with the **video** bit layout for both media types. The
GMAC field (10…13) and key position (14…17) are zero in the network test.

### 6.3 Ordering on receipt

- **Before keys exist** (handshake done, key exchange not yet finished, §10.2) media packets
  are held, at most 32; extra ones are dropped. When the server→client key becomes
  available the held packets are verified and processed in arrival order.
- **Audio** (including haptics) is delivered in arrival order, without reordering.
- **Video** goes through a reorder window of **64 packet indices**:
  - The window start is set from the first video packet: its packet index minus its unit
    index (i.e. the first packet of its frame).
  - Packets before the window start and duplicates are discarded.
  - A packet beyond the window evicts the oldest slots (discarding what they hold) until it
    fits; if this empties the window, the window restarts at that packet. If the window is
    empty and the comparison is ambiguous (exactly half the number space away), the window
    restarts at the packet.
  - Consecutive packets from the window start are delivered immediately.
  - **Head-of-line wait.** When the window holds packets but the start slot is empty, the
    first held packet waits. When it has waited the wait limit (counted from its own arrival),
    the client skips all empty slots up to it and continues delivering; a further gap is
    skipped at once if the packet behind it has already waited the limit. **Con**: no packet
    is held longer than the limit however many gaps a frame has (a timer restarted at every
    delivery made each gap of a frame cost the whole wait). The socket wait is shortened
    (rounded up to whole ms) so the wait ends on time.
  - Wait limit: **16 ms** for a console; **3 ms** for a cloud server. **Con** (cloud packets
    do not overtake each other; waiting only delays frames FEC could already restore).
- Optional local switches can discard video, or game audio (not haptics), right after
  parsing.

### 6.4 Client→server audio (microphone)

Same header as §6.1 (type 3) with: packet index = the client's 16-bit microphone counter,
frame index = counter + 1, unit word 0x00022821 (unit index 0, units − 1 = 2, descriptor
0x2821 = 40-byte units, 2 redundant, 1 source), codec 5, GMAC at 10, key position at 14, byte 18 = 0,
and for PS5 one more 0 byte at 19. The payload (3 × 40 bytes of Opus) starts at 19 (PS4) or
20 (PS5) and is encrypted with the client→server key stream at key position + 16. The key
position is allocated for payload length + 16 (§7.3). Microphone contents and the enabling
handshake are in `03-media.md`; the client announces its microphone format in its own stream
info message (§11.4).

---

## 7. Keys, encryption and authentication

### 7.1 Key exchange inputs

- **Handshake key** *H*: 16 random bytes generated by the client before the stream
  connection (console), or supplied with the cloud slot (**Con**). For consoles it is also
  carried inside the launch specification (`04-registration.md`).
- **ECDH** on curve **secp256k1**. The client generates a key pair per stream connection and
  sends its public key **uncompressed** (65 bytes, `04 ‖ X ‖ Y`) in BIG, with signature
  `HMAC-SHA256(key = H, message = the 65-byte public key)` (32 bytes). The server returns its
  public key and signature the same way in BANG. The shared secret *Z* is the 32-byte
  big-endian X coordinate of the shared point.
  The reference does **not** verify the server's signature. **Uncertain:** that it is
  computed the same way (likely).

### 7.2 Per-direction key and IV

For each direction an index *i* is used: **2 = client→server**, **3 = server→client**.

```
D = 01 ‖ i ‖ 00 ‖ H (16 bytes) ‖ 01 00            (21 bytes)
S = HMAC-SHA256(key = Z, message = D)              (32 bytes)
K_enc = S[0..15]     IV_base = S[16..31]
```

**Counter arithmetic.** "IV + n" below means: interpret the 16 IV bytes as a
**little-endian** 128-bit integer (byte 0 least significant), add *n*, keep the result modulo
2^128, write back little-endian.

### 7.3 Key position

Each direction has a 64-bit key position counter, starting at 0 when the keys are created.
The sender allocates a range of key positions for each authenticated packet and writes the
low 32 bits of the range start into the packet. The receiver uses the value in the packet; it
does not need to predict it.

Reference allocation rule for a request of *s* bytes: the packet gets the current position
*p*, and the counter advances by `s + (s mod 16)` (sic — not a round-up to 16). The *s*
used:

| Packet | *s* |
|---|---|
| DATA chunk | length of the message data in the chunk (not the whole packet) |
| DATA-ACK | 29 (whole datagram) |
| Congestion report | 15 |
| Controller state / history, microphone | payload length + 16 |

Before the client→server key exists, the key position written is 0 and the counter does not
advance (for example BIG is sent with key position 0 and a zero tag).

**Uncertain:** whether the server requires increasing, non-overlapping positions. Copying the
rule above is safe. Encrypted regions never overlap with this rule because a packet with
payload length *L* allocates at least *L* + 16 and encrypts from *p* + 16.

**Receiver: extending to 64 bits.** The receiver keeps the last accepted 64-bit position
*prev* (initially 0; one state for the whole connection, shared by control and media). For a
received low part *l* with *prev* = (*hi*, *lo*):
- if *l* follows *lo* in 32-bit serial order but *l* < *lo* numerically (wrapped forward):
  *hi* + 1;
- else if *l* precedes *lo* in serial order but *l* > *lo* numerically (wrapped backward) and
  *hi* > 0: *hi* − 1;
- result = (*hi*, *l*).
The state is updated after a packet's tag verifies. (The reference also updates it while
parsing control chunks and media headers, after verification.)

### 7.4 Payload encryption (AES-128-CTR)

Key stream block for 16-aligned position *q*: `AES-128-ECB-Encrypt(K_enc, IV_base + q/16)`.
The key stream byte at position *x* is byte `x mod 16` of the block for `x − (x mod 16)`.
Encryption and decryption XOR the payload with the key stream starting at **key position + 16**
(the 16 bytes at the key position itself are not used for data).

Encrypted: media payloads (both directions), controller state and history payloads. Not
encrypted: control packets (DATA chunk contents are in clear), congestion reports.

### 7.5 Authentication tag (truncated AES-GCM GMAC)

For a packet with key position *p* (full 64-bit value):

1. GMAC key index `n = floor((p − 1) / 45000)` for *p* > 0, and `n = 0` for *p* = 0.
2. GMAC key:
   - `G_0 = fold(SHA-256(K_enc ‖ IV_base))`
   - for *n* > 0: `G_n = fold(SHA-256(G_0 ‖ (IV_base + n × 44910)))`
   - where `fold(d) = d[0..15] XOR d[16..31]`. Note that every `G_n` is derived from `G_0`,
     not from the previous key. Keys "refresh" every 45 000 bytes of key position.
3. Nonce: the 16 bytes `IV_base + floor(p / 16)` — i.e. the same counter value as the CTR
   block containing *p*. The nonce is **16 bytes long**, so GCM derives its initial counter
   block by GHASH (standard GCM rule for nonces that are not 96 bits).
4. Input: the whole Takion packet (without the cloud prefix) as **additional authenticated
   data**, with the GMAC field set to zero and — for control and congestion packets only —
   the 4-byte key position field also set to zero. No plaintext.
5. Tag: the first **4** bytes of the 16-byte GCM tag, written at the GMAC offset (§3.1).

Order of operations when sending an encrypted packet: allocate the key position, encrypt
the payload, write the key position, compute and write the tag.

Receiving: once the server→client key exists, every received packet's tag is verified with
key index 3 material; a mismatch drops the packet. A packet type with no defined tag position
is dropped. When the key becomes available, DATA chunks still waiting in the reorder window
(§5.3) are re-verified and dropped if invalid. Before the key exists no tags are checked.

### 7.6 Test vectors

Inputs: *Z* = bytes 00 01 02 … 1F; *H* = A0 A1 … AF. These values were produced by the
reference and reproduced by an independent implementation of this section.

| | index 2 (client→server) | index 3 (server→client) |
|---|---|---|
| K_enc | 849fa47d53feb0d7dca3974134cebc7b | 518be4810fc14341a3baea427ac087e7 |
| IV_base | 2b86f7636e383c2ebaaf40fb13622195 | 6bafe14f25c37d152560177335707385 |
| G_0 | 3a2897e470211327092b4be9f81d9ec2 | 80a5ce882d445ca19b74e989e951c2d9 |
| G_1 | 89e20495c1b6017b22175afb75ae358c | d91c6d4cd7f467fa9899ce4d4b078065 |
| Key stream at 0 (32 bytes) | de66140841508cc954d360320956ba2a 65139d0d4c9f6728fb8f3fe26077619f | cb8d181a9ef7e8b127248cb83e813585 e056cb1dd9436bf70cce9478bf46e771 |
| Key stream at 0x10000 (16 bytes) | 3981c2e1047908f9fd42fed737cfedef | 82d521485715daf525798fbf432d3bda |

Tag example: control packet (28 bytes) `00 11223344 00000000 00000040 00 01 000f 55667788 0001
0000 00 0803` — tag 0x11223344, key position 0x40, DATA chunk, flags 1, length 15, TSN
0x55667788, channel 1, data type 0, protobuf `08 03` (heartbeat). The tag is computed over
these bytes with the key position field zeroed:

| | index 2 | index 3 |
|---|---|---|
| GMAC at key position 0x40 (key G_0) | 7926cef1 | 16f7d264 |
| GMAC of the same 28 bytes at key position 45001 (key G_1) | 3d05f159 | a2e7ce3e |

---

## 8. Client→server unreliable packets

### 8.1 Congestion report (type 5), 15 bytes

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | 0x05 |
| 1 | 2 | Unknown, always 0 |
| 3 | 2 | Packets received in the interval |
| 5 | 2 | Packets lost in the interval |
| 7 | 4 | GMAC (computed with the key position field zeroed) |
| 11 | 4 | Key position, low 32 bits |

Sent every **200 ms**, starting when the transport is started — the reference does not wait
for the handshake; reports before the key exchange carry a zero tag and key position 0. The
server uses these reports to choose its bitrate and the number of FEC units per frame. The
server's stream info carries a congestion-control interval field, which the reference
ignores.

**Counting** (per interval, reset after each report):

- Video: when a video frame is finished (the first packet of a newer frame arrives), the
  frame contributes *received* = source + FEC units that arrived and *lost* = expected source
  + FEC units − received.
- Audio (game audio only, not haptics): each counted audio frame index *f* updates a 16-bit
  range. On the very first count of the connection the range is initialised to
  `start = max = f − 1` (**Con**: nothing before the first packet counts as lost). Each count
  increments a counter and raises *max* to *f* if *f* follows it (serial order). At report
  time: `span = (max − start) mod 2^16`; `lost = span − counted` if `counted ≤ span`, else 0
  (**Con**: surplus packets from duplicates are not a loss; the reference reports the whole
  range as lost); `received = counted`. Then `start = max`, `counted = 0`.
  - Console audio: one count per audio packet, using the packet's frame index.
  - PS5 cloud audio: one count per **new** frame index only (each frame arrives in three
    packets; counting each copy would report about 100 false losses per second). **Con**
- The report adds video and audio numbers: *R* = received total, *L* = lost total.

**Reported values** (**Con**):
```
T = R + L
reported_lost = min(L × margin, floor(T × ceiling))
reported_received = T − reported_lost
```
both truncated to 16 bits. *margin* = 3 for cloud servers, 1 for consoles (losses come in
bursts while the server sizes FEC for the average). *ceiling* is the loss ceiling given by the
application: Con uses 0.04 for PS5 cloud and consoles, 0.02 for PS4/PS3 cloud.
Observed server behaviour noted by Con: PS5 cloud adjusts FEC smoothly (about 1 FEC unit at
0 % reported loss, 2.5 at 0.9 %, 5.5 at 4.4 %, falling to 640×360 near 20 %); PS4/PS3 cloud
switches from 1–2 to 30–50 FEC units once the reported average exceeds about 1.8 %.

### 8.2 Controller state (type 6) and controller event history (type 1)

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | 0x06 (state) or 0x01 (history) |
| 1 | 2 | 16-bit sequence number (separate counters for state and history, each starting at 0, +1 per packet) |
| 3 | 1 | 0 |
| 4 | 4 | Key position, low 32 bits |
| 8 | 4 | GMAC (key position field **not** zeroed) |
| 12 | n | Encrypted payload |

Key position allocated for *n* + 16; payload encrypted at key position + 16. State payload
size: 0x19 bytes for transport version 9, 0x1C for version 12. Contents, sending rules and
the history format are in `03-media.md`.

---

## 9. Network test ("Senkusha")

Purpose: before a console stream, measure round-trip time and the largest datagram size in
each direction. The results go into the launch specification (MTU, RTT) and the hello
fragment size (§5.5).

### 9.1 Transport

UDP port 9297 (or the externally supplied socket, §2.2), don't-fragment set, no encryption
(tags and key positions are zero everywhere), media headers in the version-7 layout (§6.2).
Same handshake and message service as the stream. The client waits up to **30 s** for the
transport to connect.

Unless noted, protobuf messages are sent as single DATA chunks with flags 1. "Wait for ack"
means wait up to 5 s for a DATA-ACK whose cumulative TSN equals that message's TSN.

### 9.2 Sequence (console)

1. **Protocol request**: envelope type 31 with supported versions = [9] (channel 1). Wait up
   to 5 s for a type-32 reply (content ignored).
2. **Hello**: envelope type 0 with protocol version 9, empty session key, empty launch
   specification, empty encrypted key, no ECDH fields (channel 1). Wait up to 5 s for any
   BANG (type 1) with its payload present (content ignored).
3. **RTT test** (§9.3), 10 pings.
4. MTU timeout `t = clamp(RTT × 5, 5 ms, 500 ms)`.
5. **Inbound MTU** (§9.4) with range 576…1454, 3 attempts per size.
6. **Outbound MTU** (§9.4) with the same range and attempts.
7. **Disconnect** message (type 8, reason "Client Disconnecting", channel 1); close.

If any step fails the stream is still attempted with fallback values: MTU in = MTU out =
1454, RTT = 1 ms, don't-fragment cleared.

### 9.3 RTT test

1. Echo on: senkusha command 0 with echo state true (channel 8). Wait for ack.
2. For each ping *k* (0-based):
   - Datagram of **548 bytes**: version-7 audio header (type 0x03, packet index 0, frame index
     = test index 0, unit word with unit index *k* and "units − 1" = 0x7FF, i.e.
     `(k << 21) | (0x7FF << 10)`, codec 0xFF, GMAC/key position 0), then 4 zero bytes, then a
     random 32-bit **ping tag** (big-endian) at offset 22, then zeros. Sent raw (not
     reliable).
   - Wait up to **1 s** for the pong: an audio packet whose frame index equals the test index,
     whose unit index (read with the version-7 layout) equals *k*, with at least 8 payload
     bytes, carrying the same tag at offset 22. RTT sample = receive time − send time.
     A ping without pong is skipped.
3. Echo off: command 0 with state false. Wait for ack.
4. RTT = mean of the samples; zero samples is a failure.

### 9.4 MTU tests

**Inbound** (largest datagram the server can send to the client). Binary search with
`min = 576`, `max = 1454`, first candidate `cur = max`; request ids start at 1 and increase
by one per attempt:
- Send senkusha command 1 (MTU) with id, requested MTU = *cur*, count = 1 (channel 8, not
  waiting for ack). Wait up to *t* for a **video** packet whose frame index equals the id.
- Success (within the allowed attempts): `min = cur`; otherwise `max = cur`.
  Next `cur = min + (max − min) / 2` (integer); stop when `max − min ≤ 1`. Result = *min*.

**Outbound** (largest datagram the client can send):
1. Send senkusha command 4 (client MTU) with id 1, requested MTU = inbound result, state true,
   downstream MTU = inbound result (channel 8, no ack wait). Wait up to 5 s for the server's
   own command-4 message with id 1; command-1 messages arriving meanwhile are ignored.
2. Binary search as above, starting with `cur` = inbound result. Probe datagram of
   `cur − 28` bytes: version-7 audio header with frame index 0, unit index = attempt number,
   "units − 1" = 0x7FF, codec 0xFF; 4 zero bytes; random tag at offset 22; filler bytes to the
   end (the reference repeats a 6-byte ASCII pattern; content is irrelevant). Pong recognised
   as in §9.3. Result = *min*.
3. Send command 4 with id 2, state false, requested MTU = final *max*, downstream MTU =
   inbound result; wait for ack.

### 9.5 Cloud network probe — **Con**

Before allocating a cloud slot Con probes candidate data centres with its own variant:

- Port: the data centre's probe port from the service; transport version 9 media layout;
  no encryption; don't-fragment cleared; datagram prefix as in §2.3 when non-zero.
- Connect wait 8 s. **No** protocol request (data centres do not answer it).
- Hello: type 0, version 9, **session key = the service credential** (the data centre reads
  it), empty launch specification and encrypted key. Split into fragments of **518** bytes
  (first) and **519** bytes (continuations), flags 1 on the last — sized for a 576-byte
  datagram: 576 − 28 − 30 / 29.
- The data centre echoes the hello instead of answering BANG; the client waits up to 2 s for
  any protobuf data, but proceeds either way.
- RTT test with **5** pings. Pong matching ignores the unit index; the tag is accepted at
  offset 22 or 23 (a version-9 parse of the version-7 ping shifts it by one byte).
- MTU timeout `clamp(RTT × 5, 200 ms, 1000 ms)`; 2 attempts per size; client-MTU reply wait
  1.5 s. If neither the first candidate nor the minimum (576) gets an answer, the MTU test
  stops early. MTU results that could not be measured are reported as 0; the stream then uses
  1454 (in) / 1254 (out). RTT is the required result; default 1 ms.

---

## 10. Stream connection

### 10.1 Parameters

- Port 9296 (console) or the slot port (cloud).
- Transport version: console PS5 → **12**, console PS4 → **9**; cloud PS5 → 12, cloud
  PS4/PS3 → 9 (**Con**). There is no in-band version negotiation on the stream: the version is
  implied by the target and announced in BIG; the server answers "version accepted" in BANG.
- Encryption enabled.

### 10.2 Exchange

```
client                                   server
  | INIT / INIT-ACK / COOKIE / COOKIE-ACK   |   (§4.2)
  | DATA ch1: BIG (may be fragmented) ----> |
  | <---------------------------- DATA-ACK  |
  | <-------------------------- DATA: BANG  |
  |   (client derives keys, enables crypto) |
  | DATA-ACK (already authenticated) -----> |
  | <-------------------- DATA: STREAMINFO  |
  | DATA-ACK -----------------------------> |
  | DATA ch9: STREAMINFOACK --------------> |
  | DATA ch1: CONTROLLERCONNECTION -------> |
  | DATA ch1: client STREAMINFO (mic) ----> |
  | <=========== video / audio media ====== |
  | ===== state, history, congestion =====> |
  | DATA ch1: HEARTBEAT every 1 s --------> |
  | ...                                     |
  | DATA ch1: DISCONNECT -----------------> |
```

1. **Transport up.** Congestion reports already run from the transport start (§8.1). The
   client waits at most **5 s** for the handshake to complete.
2. **BIG.** Sent at once (§11.3), fragmented per §5.5 on channel 1. It is not authenticated
   (no key yet).
3. **Wait for BANG**, at most **5 s**. While waiting:
   - a DISCONNECT ends the connection (§10.5);
   - a STREAMINFO arriving before BANG is kept (only the first one) and processed right after
     BANG;
   - anything else is ignored.
   On BANG the client requires *version accepted* = true, *encrypted key accepted* = true, and
   a non-empty server public key and signature; otherwise the connection fails. It computes *Z*
   (§7.1) and both direction keys (§7.2) and switches authentication on immediately, before the
   DATA-ACK for BANG is sent. So that DATA-ACK is the first authenticated packet the client
   sends (key position 0 from now on, see §7.3). From now on every received packet must carry a
   valid tag; held media packets are released (§6.3).
4. **Wait for STREAMINFO**, at most **5 s**. Other messages are ignored (DISCONNECT ends the
   connection). **Con (cloud):** cloud servers send other protobuf messages in this phase; the
   client logs their type, whether a stream-info payload is present and their size, and keeps
   waiting.
   On STREAMINFO: the audio header must be exactly 14 bytes, otherwise the connection fails.
   Up to 8 resolutions are taken (width, height, codec header bytes); the adaptive stream index
   in video packets selects among them. Then the client sends, in this order:
   STREAMINFOACK (channel 9), CONTROLLERCONNECTION (channel 1), its own STREAMINFO announcing
   the microphone format (channel 1).
5. **Streaming.** Controller state/history start. The client sends a HEARTBEAT every
   **1 s** (channel 1).

### 10.3 Messages received while streaming

| Type | Client action |
|---|---|
| 8 DISCONNECT | End the session (§10.5) |
| 16 CONNECTIONQUALITY | Informational: target bitrate, upstream bitrate, upstream loss, disable-upstream-audio, RTT, loss. The reference only logs them (and uses the event to sample its own measured bitrate) |
| 5 CORRUPTFRAME | Informational, logged |
| 14 STREAMINFOACK | Ignored |
| anything else | Ignored |

Messages of data type 7, 9, 11 are dispatched to the controller-feedback handling
(`03-media.md`).

### 10.4 Messages sent while streaming

| Message | When | Channel |
|---|---|---|
| HEARTBEAT (type 3, no payload) | every 1 s | 1 |
| CORRUPTFRAME (type 5) with start, end frame indices | when the video receiver detects missing frames (a frame newer than "last complete + 1" starts: range last complete + 1 … new frame − 1), or when FEC fails on a frame (range last complete + 1 … current frame); details in `03-media.md` | 2 |
| IDRREQUEST (type 25, no payload) | after an FEC failure, if the application enabled it and no request is outstanding | 2 |

### 10.5 Ending

- Client-initiated: the client sends DISCONNECT with reason "Client Disconnecting" on
  channel 1, then closes the socket without waiting.
- Server-initiated: a received DISCONNECT carries a reason string (the client keeps up to 255
  bytes). The reason "Server shutting down" is reported to the application as a remote
  shutdown; any other reason as a remote disconnect. The client still sends its own
  DISCONNECT on the way out.
- Transport failure (socket error, failed handshake) ends the connection.
- A timeout in any phase above ends the connection with an error.

---

## 11. Protobuf messages

All messages are protobuf **proto2** encodings of one envelope message. Repeated scalar
fields are **not packed** (one tag per element). Encoders following the reference write
fields in increasing field-number order and always write required fields. The reference's
decoder **rejects** a message lacking a required field (marked "R" below), so an encoder must
write them even when empty.

Wire types: 0 = varint (integers, bools, enums), 1 = 64-bit (double), 2 = length-delimited
(strings, bytes, sub-messages), 5 = 32-bit (float).

### 11.1 Envelope

| Field | Wire | R | Meaning |
|---|---|---|---|
| 1 | 0 | R | Message type (enum below) |
| 2…32 | 2 | | Payload sub-message; which field depends on the type (below) |

| Type | Name | Payload field | Used by client |
|---|---|---|---|
| 0 | BIG (client hello) | 2 | sent |
| 1 | BANG (server hello) | 3 | received |
| 2 | INFO | 4 | — |
| 3 | HEARTBEAT | none | sent |
| 4 | PACKETLOSS | 5 | — |
| 5 | CORRUPTFRAME | 6 | sent, received (logged) |
| 6 | CURSOR | 8 | — |
| 7 | TIMER | 9 | — |
| 8 | DISCONNECT | 10 | sent, received |
| 9 | LOG | 11 | — |
| 10 | HEADERREQUEST | 12 | — |
| 11 | DEBUG | 13 | — |
| 12 | SENKUSHA (network-test command) | 14 | sent (network test) |
| 13 | STREAMINFO | 15 | received; also sent (microphone format) |
| 14 | STREAMINFOACK | none | sent |
| 15 | XMBCOMMAND | 16 | — |
| 16 | CONNECTIONQUALITY | 17 | received (logged) |
| 17 | CLIENTMETRIC | 18 | — |
| 18 | PLAYTIMELEFT | 19 | — |
| 19 | SERVERMESSAGE | 20 | — |
| 20 | FPSCHANGE | 21 | — |
| 21 | CONTROLLERCONNECTION | 22 | sent |
| 22 | CLIENTINFO | 23 | — |
| 23 | VIDEOCAPTURE | 24 | — |
| 24 | AUDIOCAPTURE | 25 | — |
| 25 | IDRREQUEST | none | sent |
| 26 | GKTRACE | 26 | — |
| 27 | PERIODICTIMESTAMP | 27 | — |
| 28 | SERVERSETTINGS | 28 | — |
| 29 | DIRECTMESSAGE | 29 | — |
| 30 | MICCONNECTION | 30 | — |
| 31 | TAKIONPROTOCOLREQUEST | 31 | sent (network test) |
| 32 | TAKIONPROTOCOLREQUESTACK | 32 | received (network test) |

(Field number 7 of the envelope is not used.) The type names are the conventional labels for
the enum values; only the numbers go on the wire.

### 11.2 Shared sub-message: event code

| Field | Wire | R | Meaning |
|---|---|---|---|
| 1 | 2 | R | Event code (string) |
| 2 | 2 | | Name (string) |
| 3 | 2 | | Description (string) |

### 11.3 BIG — client hello (payload field 2)

| Field | Wire | R | Meaning | Client value |
|---|---|---|---|---|
| 1 | 0 | R | Client transport version | 9 or 12 (stream); 9 (network test) |
| 2 | 2 | R | Session key (string) | Console: the session id from the session request (`01-session.md`). Cloud: the slot's session id. Network test: empty. Cloud probe: the service credential |
| 3 | 2 | R | Launch specification (string) | See below. Network test: empty |
| 4 | 2 | R | Encrypted key (bytes) | Stream: 4 zero bytes `00 00 00 00`. Network test: empty |
| 5 | 2 | | Client ECDH public key (bytes, 65) | stream only |
| 6 | 2 | | Signature of field 5 (bytes, 32) | stream only |

Launch specification, console: take the launch JSON text (`04-registration.md`) **including
its terminating NUL byte**; encrypt an all-zero buffer of the same length with the session's
RP cipher (`01-session.md`) at counter 0; XOR that result into the JSON bytes; encode with
standard base64 (alphabet `A–Z a–z 0–9 + /`, `=` padding). The JSON carries, among others,
the MTU (= measured inbound MTU) and RTT (= measured RTT in ms) from the network test and the
handshake key. **Con (cloud):** the slot comes with a launch specification already encoded
by the service (several kilobytes); it is sent verbatim.

Encoding example (stream, outline): `08 00 | 12 <len> [ 08 <ver> | 12 <len> <session key> |
1A <len> <launch spec> | 22 04 00 00 00 00 | 2A 41 <65 bytes> | 32 20 <32 bytes> ]`.

### 11.4 BANG — server hello (payload field 3)

| Field | Wire | R | Meaning |
|---|---|---|---|
| 1 | 0 | R | Server version |
| 2 | 0 | R | Token |
| 3 | 0 | R | Encrypted key accepted (bool) — must be true |
| 4 | 0 | R | Version accepted (bool) — must be true |
| 5 | 2 | R | Session key (string) |
| 6 | 2 | | Extended info (event code, §11.2) |
| 7 | 2 | | Server version string |
| 8 | 2 | | Server ECDH public key (bytes, 65) — required by the stream |
| 9 | 2 | | Signature of field 8 (bytes, 32) — required by the stream |

### 11.5 STREAMINFO (payload field 15)

| Field | Wire | R | Meaning |
|---|---|---|---|
| 1 | 2 | | Resolution (repeated sub-message, below), one per adaptive stream, in index order |
| 2 | 2 | R | Audio header (bytes, 14) |
| 3 | 0 | | Start timeout |
| 4 | 0 | | Idle (AFK) timeout |
| 5 | 0 | | Idle (AFK) disconnect timeout |
| 6 | 0 | | Congestion-control interval (ignored by the reference) **Uncertain:** unit |
| 7 | 2 | | Audio channel (repeated sub-message, below; ignored by the reference) |

Resolution sub-message: field 1 width (varint, R), field 2 height (varint, R), field 3 codec
header bytes (bytes, R; e.g. parameter sets for the decoder — see `03-media.md`).

Audio channel sub-message: field 1 channel type (varint, R), field 2 audio header (bytes, R),
field 3 raw PCM (bool).

Audio header, 14 bytes as received from the server: byte 0 channels, byte 1 bits per sample,
bytes 2–5 sample rate (BE), bytes 6–9 frame size in samples (BE), bytes 10–13 unknown (BE).

**Client STREAMINFO** (microphone format): only field 2, with header
`01 10 0000BB80 000001E0 00000000` (1 channel, 16 bits, 48 000 Hz, 480 samples, 0).
Full encoding: `08 0D 7A 10 12 0E 01 10 00 00 BB 80 00 00 01 E0 00 00 00 00`.

STREAMINFOACK has no payload: `08 0E`.

### 11.6 CONTROLLERCONNECTION (payload field 22)

| Field | Wire | R | Meaning | Client value |
|---|---|---|---|---|
| 1 | 0 | | Controller id (signed) | omitted |
| 2 | 0 | | Connected (bool) | true |
| 3 | 0 | | Controller type: 0 not set, 1 DualShock 3, 2 DualShock 4, 3 Vita, 4 XInput, 5 mobile, 6 DualSense, 7 VR2 Sense | 6 when DualSense features are enabled, else 2 |

Encoding (DualSense): `08 15 B2 01 04 10 01 18 06`.

### 11.7 DISCONNECT (payload field 10)

| Field | Wire | R | Meaning |
|---|---|---|---|
| 1 | 2 | R | Reason (string) |
| 2 | 2 | | Extended info (event code) |

Client encoding (26 bytes): `08 08 52 16 0A 14` + ASCII "Client Disconnecting".

### 11.8 CORRUPTFRAME (payload field 6)

| Field | Wire | R | Meaning |
|---|---|---|---|
| 1 | 0 | R | First corrupt/missing video frame index |
| 2 | 0 | R | Last corrupt/missing video frame index |

Encoding: `08 05 32 <len> 08 <start> 10 <end>`. HEARTBEAT = `08 03`; IDRREQUEST = `08 19`.

### 11.9 CONNECTIONQUALITY (payload field 17)

| Field | Wire | Meaning |
|---|---|---|
| 1 | 0 | Target bitrate |
| 2 | 0 | Upstream bitrate |
| 3 | 5 | Upstream loss (float) |
| 4 | 0 | Disable upstream audio (bool) |
| 5 | 1 | RTT (double) |
| 6 | 0 | Loss (unsigned 64-bit) |

All optional. **Uncertain:** units (bitrates probably kbit/s; RTT probably ms).

### 11.10 Network-test messages

TAKIONPROTOCOLREQUEST (payload field 31): field 1, varint, repeated (unpacked) — supported
transport versions. Client sends [9]: `08 1F FA 01 02 08 09`.

TAKIONPROTOCOLREQUESTACK (payload field 32): field 1, varint, optional — chosen version.

SENKUSHA command (payload field 14):

| Field | Wire | R | Meaning |
|---|---|---|---|
| 1 | 0 | R | Command: 0 echo, 1 MTU, 3 bandwidth, 4 client MTU |
| 2 | 2 | | Echo sub-message |
| 3 | 2 | | MTU sub-message |
| 4 | 2 | | Bandwidth sub-message |
| 5 | 2 | | Client MTU sub-message |

Echo: field 1 state (bool, R). Example "echo on": `08 0C 72 06 08 00 12 02 08 01`.

MTU: field 1 id (R), 2 requested MTU (R), 3 MTU sent, 4 count, 5 send delay, 6 delta — all
varint. The client sends id, requested MTU and count = 1.

Client MTU: field 1 id (R), 2 requested MTU (R), 3 state (bool, R), 4 downstream MTU — varint.

Bandwidth (unused by the client): 1 id (R), 2 time (R), 3 bandwidth, 4 fps, 5 MTU, 6 NAL-unit
count, 7 total sent, 8 upstream (bool), 9 loss (double).

### 11.11 Messages the client does not use

Listed for completeness, so a decoder can skip or log them. All fields optional unless "R".

| Payload (field) | Fields |
|---|---|
| INFO (4) | 1 effective bandwidth, 2 bitrate, 3 min bitrate, 4 target bitrate, 5 corrupt-frame frequency, 6 MTU, 7 fps, 8 monitor interval, 9 external overhead, 10 internal overhead, 11 timeout interval, 12 min resume quality, 13 min fps — all varint, all R |
| PACKETLOSS (5) | 1 start (R), 2 end (R), 3 packets received (R) — varint |
| CURSOR (8) | 1 id, 2 width, 3 height, 4 hotspot x, 5 hotspot y (varint, R); 6 pixels (bytes) |
| TIMER (9) | 1 seconds left (R), 2 total seconds (R) |
| LOG (11) | 1 repeated log entry: {1 timestamp int64 (R), 2 level enum 0 critical…5 trace (R), 3 component string (R), 4 message string (R), 5 timestamp double} |
| HEADERREQUEST (12) | 1 header type: 0 audio, 1 video (R) |
| DEBUG (13) | 1 type: 0 overlay, 1 bitrate (R); 2 overlay {1 enable bool, 2 toggle bool, 3 location enum 0–3, 4 level}; 3 bitrate {1 toggle bool, 2 bitrate change float} |
| XMBCOMMAND (16) | 1 command: 0 off, 1 on, 2 toggle (R); 2 player id |
| CLIENTMETRIC (18) | 1 repeated metric: {1 category enum 0–20 (R), 2 start frame int32 (R), 3 end frame int32 (R), 5 count int32 (R), 6 average float (R), 7 std dev float (R), 8 min float (R), 9 max float (R)} |
| PLAYTIMELEFT (19) | 1 time left (varint), 2 reason (string) |
| SERVERMESSAGE (20) | 1 payload (string) |
| FPSCHANGE (21) | 1 fps (R) |
| CLIENTINFO (23) | 1 session key string (R), 2 GCM tag (varint), 3 key position (varint) |
| VIDEOCAPTURE (24) | 1 server side (bool, default false), 2 IDR period (default 0) |
| AUDIOCAPTURE (25) | 1 server side (bool, default false) |
| GKTRACE (26) | 1 sequence number, 2 GCM tag, 3 key position — all R |
| PERIODICTIMESTAMP (27) | 1 timestamp info (bytes, R), 2 version (R) |
| SERVERSETTINGS (28) | 1 IDR period (default 0), 2 send periodic timestamp (bool, default false) |
| DIRECTMESSAGE (29) | 1 type: 0 deep link, 1 mic info (R); 2 destination: 1000 controller service, 1001 client (R); 3 data (bytes) — data is a deep-link or mic-info message (below) |
| MICCONNECTION (30) | 1 controller id int32 (R), 2 connected bool (R), 3 result bool |

Deep-link message (inside DIRECTMESSAGE data): 1 type enum (0 save data, 1 invite, 2 game
alert, 3 system service status, 4 debug menu, 5 raw) R; 2 request id; 3 pad unique id;
4 invitation id string; 5 session id string; 6 item id string; 7 "system UI overlaid" string;
8 result; 9 should show bool; 10 raw data string.

Mic-info message: 1 type enum (0 connect, 1 mute) R; 2 controller id; 3 connected bool;
4 muted bool; 5 result bool.

Client-metric categories 0–20: video frame lifetime, video frame NAL units complete, video FEC
correction, video frame queue, video decoder frame queue, video submit to decoder, video
decode, video decoded picture drop, video YUV copy, video texture copy, video render, graphics
pre-render, graphics present, audio frame lifetime, audio frame NAL units complete, audio FEC
correction, audio frame queue, audio submit to decoder, audio decode, audio buffer copy, audio
render.

---

## 12. Timers and constants

| What | Value |
|---|---|
| Stream port / network-test port | 9296 / 9297 |
| Advertised receiver window; console SO_RCVBUF | 0x19000 |
| Cloud SO_RCVBUF (**Con**) | 0x400000 |
| Streams announced in INIT | 100 out, 100 in |
| Handshake: wait per attempt / attempts | 5 s / 3 (INIT and COOKIE separately) |
| Read buffer per datagram | 1500 bytes |
| Data reorder window | 16 TSNs |
| Send (retransmission) buffer | 16 messages |
| Retransmission check / timeout / max retransmissions | 100 ms / 200 ms / 25 |
| Media packets held before keys exist | 32 |
| Video reorder window | 64 packet indices |
| Video head-of-line wait | 16 ms console, 3 ms cloud (**Con**) |
| Reassembled message limit (**Con**) | 1 MiB |
| Congestion report interval | 200 ms |
| Loss margin (**Con**) | 3 cloud, 1 console |
| Heartbeat interval | 1 s |
| Stream phase timeouts (transport up, BANG, STREAMINFO) | 5 s each |
| GMAC key refresh | every 45 000 key-position bytes; IV step 44 910 |
| GMAC tag length | 4 bytes |
| Network test: connect wait | 30 s (console), 8 s (cloud probe **Con**) |
| Network test: pings / pong wait | 10 / 1 s (cloud probe: 5 / 1 s) |
| Network test: MTU range / attempts | 576…1454 / 3 (cloud probe: 2) |
| Network test: MTU wait | clamp(5 × RTT, 5 ms, 500 ms) (cloud probe: 200…1000 ms) |
| Fallbacks after a failed network test | MTU 1454/1454, RTT 1 ms, DF off |
| Cloud defaults when the slot gives none (**Con**) | MTU in 1454, MTU out 1254, RTT 1 ms |

---

## 13. Summary of Con-specific behaviour

| Area | Behaviour |
|---|---|
| Cloud datagram prefix | `00 00 00 P` in front of every client datagram when *P* ≠ 0; not authenticated; inbound datagrams have none (§2.3) |
| Cloud initial TSN | Taken from INIT-ACK instead of the server tag (§4.2) |
| Cloud transport version | PS5 cloud 12, PS4/PS3 cloud 9 (§10.1) |
| Cloud hello | Pre-encoded launch specification sent verbatim; fragment sizes for prefix (§5.5, §11.3) |
| Cloud receive buffer | 4 MiB (§2.3) |
| Cloud codec value 3 | Treated as the requested codec (§6.1) |
| Cloud stream-info phase | Other protobuf messages before STREAMINFO are logged and skipped (§10.2) |
| Fragment reassembly | Multi-fragment messages are reassembled per channel, one at a time (§5.4) |
| Video reorder wait | 3 ms in the cloud instead of 16 ms (§6.3) |
| Loss counting | First packet starts the range; surplus is not loss; PS5 cloud audio frames counted once (§8.1) |
| Loss report | Margin 3 in the cloud, ceiling from the application (§8.1) |
| RTT | From first transmission of a reliable message to its acknowledgement (§5.2) |
| Cloud network probe | Variant of the network test for data centres (§9.5) |

## 14. Open points

- The meaning of the unknown header fields of media packets (offset 18 of audio, 18–19 and
  the low bits of 20 of video, the 3 extended bytes) and of the first word of the congestion
  report.
- Gap-ack blocks in DATA-ACK are never produced or interpreted by the reference.
- Whether servers check that client key positions increase.
- Packet types 4 and 8 are never seen in practice by the reference.
- The server's BANG signature is not checked by the reference.
