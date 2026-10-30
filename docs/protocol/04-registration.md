# 04 — Finding consoles, registration, launch parameters, key exchange

This part describes four things a client must do around a Remote Play stream with a console on
the local network:

1. find consoles on the LAN and wake one from rest mode (section 1);
2. register ("pair") with a console once, using the PIN the console shows (section 2);
3. send the launch parameters of the stream (section 3);
4. agree session keys with the console by elliptic-curve Diffie–Hellman (section 4);

plus the formats of the PSN account identifiers (section 5), test vectors (section 6) and the list
of doubts (section 7).

The session request over HTTP, the control channel and the derivation of the session cipher from
the console's nonce are in `01-session.md`. The datagram transport that carries the launch message
and the key exchange is in `02-transport.md`. Registration through PSN (for consoles outside the
LAN) shares the request format described here; its transport (the PSN relay) is not documented
here.

## 0. Conventions

- Byte values are hexadecimal (`0x41` or plain `41` in dumps). "Big-endian" = most significant
  byte first.
- Arithmetic on bytes is modulo 256 ("+", "−" wrap around); "⊕" is XOR.
- Text messages are ASCII. `\r` = 0x0D, `\n` = 0x0A, `\0` = 0x00.
- **Console generation.** The protocol differs by console family and firmware. This document uses
  four generation labels; the second column is the value the console and client exchange in the
  `RP-Version` header.

| Label | RP-Version string | Console |
|---|---|---|
| PS4-8 | `8.0` | PS4, system software below 7.0 |
| PS4-9 | `9.0` | PS4, system software 7.x |
| PS4-10 | `10.0` | PS4, system software 8.0 and later |
| PS5 | `1.0` | PS5 |

  "Old generation" below means PS4-8 and PS4-9; "new generation" means PS4-10 and PS5.

---

## 1. Discovery on the local network

Discovery is a plain-text, HTTP-like exchange over UDP. The client sends a search datagram; every
console that hears it answers with one datagram describing itself.

### 1.1 Ports

| Purpose | Transport | Console port |
|---|---|---|
| Search / wake, PS4 | UDP | **987** |
| Search / wake, PS5 | UDP | **9302** |
| Registration probe and request (section 2) | UDP, then TCP | **9295** |
| Session request, control (see `01-session.md`) | TCP | **9295** |

Client side: the search socket is a UDP socket bound to any local address, with broadcast sending
enabled. The client first tries to bind local port **9303**, then 9304, … up to **9319**; if none
is free it lets the system pick a port. **Uncertain:** whether consoles require the source port
to be in 9303–9319; the range is what the reference client uses, and replies go back to the
datagram's source address and port.

The same socket is used to send searches and wake-ups and to receive replies. IPv4 and IPv6 both
work the same way (one socket per address family); Con uses IPv4 only.

### 1.2 Search request

One datagram, text, followed by a single `\0` byte (the terminating zero is sent; datagram length =
text length + 1):

```
SRCH * HTTP/1.1\n
device-discovery-protocol-version:<V>\n
```

(Each `\n` above is a single 0x0A; there is no `\r`, no blank line, no space after the colon.)

| Destination port | `<V>` |
|---|---|
| 987 (PS4) | `00020020` |
| 9302 (PS5) | `00030010` |

The client sends both variants in every search round (section 1.6).

### 1.3 Search response

The console answers from its own address with one UDP datagram (up to 511 bytes are read; longer
responses are truncated). It is an HTTP-style status line followed by header lines:

```
HTTP/1.1 <code> <reason>\n
<key>:<value>\n
<key>:<value>\n
...
```

Parsing rules that are known to work:

- The datagram must start with exactly `HTTP/1.1 ` (9 bytes). The status code is the decimal number
  after it; the rest of the status line is ignored. The status line ends at the first `\n`
  (an optional `\r` before it is removed).
- Each following line is `key:value`. One optional space after the colon is skipped. A line may end
  with `\n` or `\r\n`. Empty lines are skipped. The reference parser rejects the whole datagram if
  a line of two or more characters has no colon, or if a value is empty; a tolerant implementation
  may simply skip such lines.
- Reading stops at a `\0` byte or at the end of the datagram.
- Header names are compared case-sensitively, exactly as listed.

**Status code → console state:**

| Code | Meaning | State |
|---|---|---|
| 200 | Console is on and Remote Play can be started | ready |
| 620 | Console is in rest mode (standby); it can be woken (section 1.5) | standby |
| anything else | — | unknown |

**Header fields:**

| Header | Value | Use |
|---|---|---|
| `host-id` | Console identifier (text, typically 12 hex digits). **Required**: responses without it are ignored. | Key of the console list |
| `host-name` | Console name chosen by the user | Display |
| `host-type` | `PS4` or `PS5` (text) | Display only; the family is decided by the protocol version below |
| `system-version` | System software version as a decimal number in text (e.g. `08520011`) | Choose the generation (1.4) |
| `device-discovery-protocol-version` | `00020020` (PS4) or `00030010` (PS5) | Decide PS4 or PS5 |
| `host-request-port` | Decimal (base auto-detected: `0x` prefix = hex, leading `0` = octal) TCP port | Reported; the reference engine does **not** use it — sessions always go to 9295 |
| `running-app-titleid` | Title id of the running application (may be absent) | Display |
| `running-app-name` | Name of the running application (may be absent) | Display |

Other headers may appear and are ignored. The address of the console is the source address of the
response datagram.

Illustrative response (values invented):

```
HTTP/1.1 620 Server Standby\n
host-id:0123456789AB\n
host-type:PS5\n
host-name:Living room\n
host-request-port:997\n
device-discovery-protocol-version:00030010\n
system-version:08520011\n
```

### 1.4 PS4 or PS5, and the generation

- The console is a **PS5** exactly when `device-discovery-protocol-version` equals `00030010`;
  otherwise it is a PS4.
- `system-version` is read as a decimal integer *N* (leading zeros allowed; non-digits stop the
  number). Then, checking in this order:

| Condition | Generation |
|---|---|
| PS5 and *N* ≥ 8050001 | PS5 (RP-Version `1.0`) |
| PS5 and *N* ≥ 8050000 | PS5, version unknown |
| *N* ≥ 8000000 | PS4-10 |
| *N* ≥ 7000000 | PS4-9 |
| *N* > 0 | PS4-8 |
| otherwise | PS4, version unknown |

(These rules are applied as written also to a PS5 below 8050000 — it would be labelled a PS4
generation by the reference; such firmware does not exist in practice.)

**Con:** an "unknown" result is replaced by PS5 (`1.0`) for a PS5 and PS4-10 for a PS4. The
session request can still correct the generation later (the console reports its RP-Version on a
mismatch; see `01-session.md`).

### 1.5 Wake-up

A console in rest mode (status 620) is woken by one UDP datagram sent **unicast** to its address,
port 987 (PS4) or 9302 (PS5), from the discovery socket (or any temporary UDP socket bound the same
way). Text, followed by one `\0` byte:

```
WAKEUP * HTTP/1.1\n
client-type:vr\n
auth-type:R\n
model:w\n
app-type:r\n
user-credential:<C>\n
device-discovery-protocol-version:<V>\n
```

- `<V>` is `00020020` for PS4 and `00030010` for PS5, as in the search.
- `<C>` is the **wake credential**, written as an unsigned decimal number. It is derived from the
  registration key obtained at registration (section 2.8): take the stored registration-key bytes
  up to the first `\0`; these bytes are ASCII hexadecimal digits (at most 8 of them); read them as
  one hexadecimal number; print that number in decimal. Example: stored key text `1a2b3c4d` →
  0x1A2B3C4D → `user-credential:439041101`. If the key text is longer than 8 characters or is not
  valid hexadecimal, the reference client refuses to send.
- The console does not answer the wake-up itself. It starts up; subsequent search rounds then show
  it with status 200. Waking takes several seconds to tens of seconds. **Uncertain:** exact boot
  times; the reference client simply keeps searching.

**Con:** Con's app does not send wake-up datagrams; the engine supports them.

### 1.6 The search service (timing)

The reference engine runs discovery as a background service:

- After an initial delay `D0`, and then every `P` milliseconds, it does one **round**:
  1. increments a round counter;
  2. drops every known console that has not answered for more than `K` rounds (a console last seen
     in round *r* is dropped in the first round *n* with *r* + *K* < *n*) and reports the changed
     list;
  3. sends the PS4 search (version `00020020`) to the main destination address, port 987, and — only
     if the main destination is the limited broadcast address `255.255.255.255` — also to each
     address in an extra list of broadcast addresses (normally the directed broadcast address of
     every local IPv4 network, i.e. interface address OR NOT netmask), port 987;
  4. sends the PS5 search (version `00030010`) to the same destinations, port 9302.
- A receiving thread parses each incoming datagram (1.3). Datagrams without `host-id` are ignored.
  Consoles are keyed by `host-id`: a new id is added (up to a maximum number of consoles `M`; extra
  consoles are ignored); for a known id the state, port and text fields are updated and the round
  counter of its last answer is set to the current round. The list is reported to the application
  whenever something changed (new console, dropped console, state or any field changed).
- There is no per-request timeout: a console disappears only through the round rule above.

| Parameter | Reference | **Con** |
|---|---|---|
| Initial delay `D0` | 500 ms | 500 ms |
| Round period `P` | 500 ms | 500 ms |
| Rounds without answer before drop `K` | 3 | 3 |
| Maximum consoles `M` | 16 | 16 |
| Main destination | `255.255.255.255` | `255.255.255.255` |
| Extra broadcast list | every local network's directed broadcast | every local IPv4 network's directed broadcast (interfaces that are up, not loopback, duplicates removed, at most 32) |

**Con:** Con sends every search to `255.255.255.255` and to each directed broadcast address,
whatever the main destination (QUESTIONS.md, question 9).

---

## 2. Registration with a PIN

Registration is done once per console and PSN account. The user opens *Settings → System → Remote
Play → Link Device* (wording differs by console) and the console shows an 8-digit PIN. The client
sends an encrypted request containing the user's PSN account id; the console answers with the
long-term secrets needed for every later session.

### 2.1 Flow and timeouts

| Step | What | Timeout |
|---|---|---|
| 1 | UDP probe to console port 9295 (2.2) | wait up to **3000 ms** for the reply |
| 2 | Pause | **100 ms** (the console does not accept the request immediately after the probe) |
| 3 | TCP connection to the address and port the probe reply came from (normally console:9295) | **3000 ms** to connect |
| 4 | Send request header (2.3), then request body (2.4) | **3000 ms** for each |
| 5 | Receive response header, up to and including the first `\r\n\r\n` | **3000 ms** |
| 6 | Receive the rest of the body, until `Content-Length` bytes of body are in | **3000 ms** |
| 7 | Decrypt and parse the body (2.8) | — |
| 8 | Close the TCP connection | — |

Any step failing ends the registration as failed; the user can cancel at any time. A random
16-byte value **A** (the IV seed, see 2.5) is generated from a cryptographically secure source
at the start of each attempt.

### 2.2 Step 1: UDP probe

- PS4 (all generations): payload `SRC2` followed by `\0` (5 bytes: `53 52 43 32 00`).
- PS5: payload `SRC3` followed by `\0` (5 bytes: `53 52 43 33 00`).

Sent to the console address, UDP port 9295. The reply is any datagram whose first 4 bytes are
`RES2` (PS4) or `RES3` (PS5); other datagrams received meanwhile are ignored (the reference reads
at most 255 bytes per datagram). The rest of the reply is not interpreted. The source address and
port of that reply are the TCP destination in step 3.

Two ways of sending the probe:

| Mode | How |
|---|---|
| Direct (unicast) — **Con uses this** | UDP socket connected to console:9295; send; receive on it. |
| Broadcast | UDP socket with broadcast enabled, bound to any local address and a system-chosen port; the probe is sent to the given address (expected to be a broadcast address), port 9295. The reply then reveals the console's real address. |

### 2.3 Step 4a: request header (exact bytes)

```
POST <path> HTTP/1.1\r\n
 HTTP/1.1\r\n
HOST: <host>\r\n
User-Agent: remoteplay Windows\r\n
Connection: close\r\n
Content-Length: <n>\r\n
[RP-Version: <rpv>\r\n]
\r\n
```

- The second line, a space followed by `HTTP/1.1`, is really sent by the reference client and the
  consoles accept it. **Uncertain:** whether it is required; reproduce it for safety.
- `HOST` is written in upper case. Its value `<host>` is the fixed text `10.0.2.15` for LAN
  registration (it is not checked). For PSN registration it is the client's local IP address as
  reported by the PSN session (PSN relay; not documented here).
- `<n>` is the body length in decimal.
- The `RP-Version` line is present for PS4-9, PS4-10 and PS5 and absent for PS4-8. `<rpv>` is the
  generation's RP-Version string (table in section 0).

| Generation | `<path>` |
|---|---|
| PS4-8, PS4-9 | `/sce/rp/regist` |
| PS4-10 (and PS4 with unknown version) | `/sie/ps4/rp/sess/rgst` |
| PS5 | `/sie/ps5/rp/sess/rgst` |

The header is sent first, then the body, on the same TCP connection.

### 2.4 Step 4b: request body layout

The body is **0x1E0 (480) bytes of filler** followed by an **encrypted inner header**:

| Offset | Size | Content |
|---|---|---|
| 0x000 | 0x1E0 | Filler. The reference uses `0x41` ('A') for every byte; any bytes may be used, see below. Some positions are overwritten with key material as described next. |
| 0x1E0 | *m* | Inner header, encrypted with the registration cipher (2.5), counter 0 |

Total body length = 0x1E0 + *m*.

**Key material hidden in the filler:**

| Generation | Positions overwritten |
|---|---|
| Old (PS4-8, PS4-9) | 0x11C … 0x12B (16 bytes) = the hidden seed value **E** (2.6.1) |
| New (PS4-10, PS5) | 0x0C7 … 0x0CE (8 bytes) = **E**[8 … 15]; 0x191 … 0x198 (8 bytes) = **E**[0 … 7] |

For the new generation two table column numbers are read **from the filler itself, before
anything is written into it**:

- column *c0* = body[0x18D] AND 0x1F (0 … 31) — selects the key column of table T0;
- column *c1* = body[0x000] >> 3 (0 … 31) — selects the column of table T1.

Neither byte 0x000 nor byte 0x18D is overwritten later, so the console recovers *c0* and *c1* from
the same bytes. With the filler `0x41` everywhere, *c0* = 1 and *c1* = 8. If random filler is used,
*c0* and *c1* must be computed from the actual random bytes.

**Inner header (plaintext)**, one of:

| Case | Text (each line ends with `\r\n`) |
|---|---|
| New generation (always account id) | `Client-Type: dabfa2ec873de5839bee8d3f4c0239c4282c07c25c6077a2931afcf0adc0d34f` then `Np-AccountId: <B>` |
| Old generation with account id (needed from PS4 system software 7.0 on) | `Client-Type: Windows` then `Np-AccountId: <B>` |
| Old generation with online id (PS4 below 7.0 only; optional alternative) | `Client-Type: Windows` then `Np-Online-Id: <online id>` |

- `<B>` = standard Base64 (alphabet `A–Z a–z 0–9 + /`, with `=` padding) of the 8-byte PSN account id
  (section 5), always 12 characters.
- No blank line and no terminating `\0` follow; *m* is exactly the length of these two lines
  (107 bytes for the new generation with account id, 50 bytes for the old generation with account
  id).
- For the new generation an online id, if given, is ignored; the account id is required.

### 2.5 The registration cipher

The registration uses a symmetric cipher defined by two 16-byte values, **B** (the AES key)
and **A** (the IV seed), and a 16-byte **HMAC key H** chosen by generation. The same
construction (with B and A derived differently) is used for the session; see `01-session.md`.

**IV for a message counter *n*** (64-bit):

  IV = first 16 bytes of HMAC-SHA256(key = H, message = A ‖ *n* as 8 bytes big-endian)

**Encryption / decryption:** AES-128 in **CFB-128** mode (full-block feedback, no padding, output
length = input length), key = B, IV as above. Each message starts from a fresh IV computed from its
counter. In registration the counter is **0** for the request's inner header and **0** again for the
response body (same key and IV; CFB makes this decrypt correctly because the console encrypts its
response the same way).

**HMAC key H by generation:**

| Generation | H |
|---|---|
| PS5 (`1.0`) | `46 46 87 b3 49 ca 8c e8 59 c5 27 0f 5d 7a 69 d6` |
| PS4-8, PS4-9 | `ac 07 88 83 c8 3a 1f e8 11 46 3a f3 9e e3 e3 77` |
| PS4-10, and any unknown version (also a PS5 of unknown version) | `20 d6 6f 59 04 ea 7c 14 e5 57 ff c5 2e 48 8a c8` |

### 2.6 Deriving B and E

Notation: *P* = the PIN as an integer (the 8 decimal digits read as one number, e.g. `12345678` →
0x00BC614E); *P*[0..3] = its 4 bytes big-endian. **A** = the random 16 bytes of this attempt.
Index *i* runs 0 … 15.

#### 2.6.1 Old generation (PS4-8, PS4-9)

- B = R ⊕ (*P*[0], *P*[1], *P*[2], *P*[3], 0, 0, …, 0), where
  R = `3f 1c c4 b6 dc bb 3e cc 50 ba ed ef 97 34 c7 c9`
  (only the first four bytes of R are changed by the PIN).
- E[*i*] = (A[*i*] − *i* − 0x29) ⊕ X[*i*], where
  X = `e1 ec 9c 3a dd bd 08 85 fc 0e 1d 78 90 32 c0 04`.
- H = the old-generation HMAC key.
- E is written at body offsets 0x11C … 0x12B.

#### 2.6.2 New generation (PS4-10, PS5) with PIN

Tables T0 and T1 (2.7) are 16 rows × 32 columns of bytes, one pair for PS4-10 and one pair for PS5.
Row *i*, column *c* is written T[*i*][*c*].

- B[*i*] = T0[*i*][*c0*] for *i* = 0 … 15, then the last four bytes are mixed with the PIN:
  B[12] ⊕= *P*[0], B[13] ⊕= *P*[1], B[14] ⊕= *P*[2], B[15] ⊕= *P*[3].
- E[*i*] = (A[*i*] ⊕ T1[*i*][*c1*]) + *k* + *i*, where *k* = **0x29** for PS4-10 and
  **0xD3** (= −0x2D) for PS5.
- E[8 … 15] → body 0x0C7 … 0x0CE, E[0 … 7] → body 0x191 … 0x198.

The console inverts this: A[*i*] = (E[*i*] − *k* − *i*) ⊕ T1[*i*][*c1*].

#### 2.6.3 New generation through PSN (no PIN)

Used when registering over the PSN relay (not documented here); only for PS4-10 and PS5. Three 16-byte
values come from the PSN session setup: **D1** and **D2** (random values the client generated and
sent in the session creation) and **CD1** (the console's "customData1", received from PSN, Base64
decoded twice, first 16 bytes).

- F = AES-128-CFB-128 encryption of CD1 with key D1 and IV = first 16 bytes of
  HMAC-SHA256(H, D2 ‖ 00 00 00 00 00 00 00 00), H chosen by the generation as in 2.5.
- B[*i*] = T0[*i*][*c0*] ⊕ F[*i*]. The PIN is not used.
- E[*i*] = (A[*i*] − *i* + *w*) ⊕ T1[*i*][*c1*], where *w* = **0x2B** for PS5 and **0xD7**
  (= −0x29) for PS4-10. (Note the different formula from 2.6.2.)
- E is placed in the body as in 2.6.2.

The request header and body are concatenated and sent as one message over the PSN control channel
instead of TCP; the response header and body come back the same way. Everything else (body layout,
cipher, response) is as for the LAN.

### 2.7 Key tables

Each table is 512 bytes, shown as 16 rows (r00 … r15) of 32 columns (00 … 1f). T[*i*][*c*] is the
byte in row *i*, column *c* (equivalently, byte number *i* × 32 + *c* of the 512-byte table).

**T0 for PS4-10** (key table, column *c0*):

```
      00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d 1e 1f
r00:  be ce 5d f0 c1 7d b5 d0 cb 30 13 5d aa 56 23 fb c4 bc f1 8f 38 57 fb d4 d4 3f 26 38 b5 ce ed 6a
r01:  21 bc 38 d0 1e 68 cc 7b 45 d1 be 42 1a 08 aa 16 fd b0 c0 f4 da 35 e9 12 fd 21 07 48 34 c1 fc 9f
r02:  8c b6 cb 5d b2 9c 84 e0 1a fa a0 c7 eb 3a 93 b3 b3 f1 15 af 13 bd 21 ab ea 5b 80 50 6b 31 1d 7c
r03:  1d 40 ba 3c 56 0e e7 94 3a 5b a1 40 80 74 0a ad 28 cf 47 df 42 a6 69 e9 5e bb c0 c0 0e b2 c5 8a
r04:  ee 08 03 d2 84 e5 91 00 1d 46 06 55 09 9d 39 9f d8 e7 fd ad 9e 93 97 c5 ea e7 a3 10 a7 f2 a2 93
r05:  7f 07 04 b4 ee bb bf 88 23 9c 6e a7 62 b1 4b 67 1e b8 3b 1f 64 93 5a 99 ec da fd 0c 6a b7 fe e4
r06:  12 76 32 65 b8 41 23 d1 17 09 9c 24 2d 5c 9d 12 79 de a1 ce 69 ac a4 bc 39 2f 57 38 84 61 2d 2a
r07:  e8 04 f8 d5 9d 0b ff 7e 56 0c ec 87 0a 1e ab df 93 81 13 ee cf 32 02 5a bf b0 17 b7 ba b5 7f f0
r08:  01 7b e1 cb 39 7e 60 6d a4 75 6e 29 92 45 a6 4f 74 00 86 78 73 be fd 3e e0 d1 0c 6c 0b 49 09 83
r09:  6c 85 8a 1d cb 16 ce 81 7c 49 c9 2c 63 61 de e2 3f 98 b2 73 f0 9a ec 7b 7c f1 c9 e1 7f a5 19 8b
r10:  4b e8 38 a4 34 7d f4 28 fe 0d 4d 11 57 0c 95 f1 af d7 34 80 f4 eb 9b 50 e6 6a 5d ea ce 0c 85 4e
r11:  c5 5b 93 44 c4 24 98 80 fc f7 72 9c 31 0b ee 89 67 b3 a2 69 4f b3 79 5a 14 02 70 ed 50 13 75 00
r12:  6a f3 c6 05 1a 00 33 34 f5 ac 9e 04 db c2 00 b0 1b c4 f3 97 9d 7f be b8 23 8d 99 e7 cb 74 37 4c
r13:  57 ec d2 69 49 46 75 74 af 51 40 a4 11 7b b3 2f 51 da e2 ef 33 73 12 18 25 39 03 09 ca 49 dc 8e
r14:  f1 94 d7 80 17 9e 87 46 c1 04 78 d1 e5 3d 25 88 ec 72 3a 28 41 68 14 6e 10 e4 c9 57 75 90 fe 22
r15:  1a 63 8e f4 b8 8d 1a 36 fd b6 cb 72 c2 97 52 9f 91 72 1b 75 57 90 3b fd 5a 93 8c db fc a3 03 df
```

**T0 for PS5:**

```
      00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d 1e 1f
r00:  24 d8 c2 69 4c 67 78 71 ee 31 bd 2b 83 b2 1d 61 c9 a7 8e ed 9a d3 6a 6b 5c c8 35 79 a7 24 e2 17
r01:  06 60 2e df f4 db 27 10 55 d9 ea 16 4e 90 0c bf 40 6f 54 a5 31 70 2d 5d 1e 27 df 37 40 ba 9d 5d
r02:  ff e1 05 70 80 d4 b7 c2 96 7f 2f 42 eb 5a 08 de c1 b5 52 15 f6 b5 f2 d9 69 a5 c7 c4 7f 46 64 a4
r03:  fd 46 98 a7 e1 2a 8e 6f af 65 42 28 b9 c2 6f 3e e3 e4 4e e4 5b 9d 60 10 b8 5a b0 7d 04 0c 4c 24
r04:  78 bd b8 ba db 8f e3 a0 75 6d 28 c2 33 5b 32 83 dd 51 b0 a5 8d 09 66 e4 5c b8 70 0b e6 82 14 b6
r05:  d2 b0 c2 e0 55 f3 84 ad 9d 3a f8 77 f5 9d 9a a9 7d f1 45 1b 9b 55 25 d8 c1 ff 03 a5 48 0b 1b 19
r06:  0c bd e0 cd 48 f3 2c 99 19 d6 b8 bb d6 35 43 6f 71 e3 ef 3e 97 b8 e9 40 a8 47 e0 e0 01 16 9d a7
r07:  e5 94 4b 1d d2 80 a2 7f f2 98 10 38 0d b8 56 c3 7a 4b 4c 85 ec 2f 23 89 af d5 ba 9a ad b0 61 9c
r08:  51 b4 6d 02 49 26 a4 34 84 20 35 30 23 0a 47 14 32 1a 96 0e e8 0f 96 96 d4 ba 68 3a 67 15 74 e0
r09:  d6 60 4c 68 50 73 14 2f 11 59 ac c8 32 d1 db 4c 8a 94 75 33 61 d1 d4 fd aa 6a 61 68 d8 ae 31 4f
r10:  b8 07 7b 27 0f f9 0b b0 c2 64 b3 72 ea 8b 87 40 09 b4 82 b4 ad 76 f9 36 05 60 89 c8 20 eb a5 f1
r11:  51 0b 27 a7 f0 76 84 96 eb b1 2e c2 85 28 bc 48 34 d4 01 8d 5b 25 54 e0 c4 4f a0 fa 99 8d 6d 7a
r12:  64 b1 a9 5d a4 f9 f5 22 eb 9a f4 a8 7a 78 4b 7f e2 8b 04 50 43 7d 26 2d 19 98 38 6a 4f 2d 30 15
r13:  2e 4f cd b9 ce 9e 8d 12 c9 fe 33 8b 84 ce 5b 40 e3 7f 72 6d 6c 8a 6a 9e 54 f1 e3 64 5d 6e 7f ac
r14:  1a e7 f7 fa 00 22 ed 2b 23 fa 58 c5 eb 44 92 5d cc aa 82 9f 23 fb a6 c9 65 2a e0 79 12 65 2c 34
r15:  c5 23 16 c9 cc 05 30 f3 96 0b 90 67 1a a7 69 4c 3e 43 24 9d 4e 68 bd 8b 75 6e 9d 07 6f 1a 6a ba
```

**T1 for PS4-10** (seed table, column *c1*):

```
      00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d 1e 1f
r00:  c8 48 c2 b4 08 eb 88 f7 5f 4a 09 2d 59 1f 09 cd 1c 18 f4 7a 28 4a 96 6d b3 59 71 53 75 7e 82 50
r01:  57 e4 59 b3 f4 49 69 40 eb 17 c9 9f 17 97 71 ae c9 60 7f f8 2e 08 94 e8 43 ea da 6b e5 19 59 33
r02:  1f 89 ae 47 57 7b 1c 66 fe ff 95 bf 55 6b d5 93 27 ea a6 24 67 39 9f d3 0c aa 26 42 e7 66 4d d8
r03:  18 75 fe 44 03 46 ee 3e f8 3c b7 85 97 03 07 06 92 ff 59 17 27 0b 21 f7 05 7f 69 90 0e 38 91 c6
r04:  67 23 48 ba 08 8e 57 dd 91 d0 40 47 1c 5b bf c8 06 3f 96 a0 dc 00 e5 9a f5 3b 90 80 66 bb 0f 93
r05:  30 07 2b 56 45 a0 9a b1 b0 72 0c e4 dd 70 dd 7c 5a bf d4 e8 0d ca 37 e5 0e fd 12 ee 79 9a 5e a7
r06:  1e 31 af 1f 46 52 ca f3 42 00 3d f2 89 7c 1c 77 60 b7 4a 80 76 47 4b 3f b6 91 2f 9c c2 f1 ad 44
r07:  29 cb 32 8c 0a 8d 05 75 46 a1 f8 da 1a a7 20 de 32 59 fe 70 b5 87 f3 92 fd b4 df f4 a6 e3 7d 98
r08:  3b e1 ba 18 db 61 d1 c2 a6 ee 08 25 fa 86 8a 7b fe bc 02 bd 22 5f 25 30 51 5d 28 36 5a 29 8e 52
r09:  eb 49 14 28 7f 0a c4 69 25 85 6b ec 33 33 57 ab 50 13 cf e7 73 78 23 06 4d 1f bb 38 11 b1 6e 6c
r10:  6f cd 4b 0e 42 85 80 bb a8 39 68 c9 5b bb 46 58 86 88 57 88 5e ea 7c 37 df fd 02 39 45 89 2e f2
r11:  e4 f0 08 c0 b6 eb 9c 6e 7a 81 a3 26 46 fe e1 70 3c 3e 11 7a 32 ce 45 02 7d 32 cd 08 07 06 a3 a8
r12:  f7 34 fe ee 06 b0 14 d6 6b 2d 2e 01 af 77 11 ec 1f 31 38 17 9c d0 e0 c5 4d a4 d6 ad b9 e6 e1 e3
r13:  e2 9e 44 91 9a 5e 26 ca cc da 4d d7 78 6a 75 a6 19 ad cc 62 c7 b6 0d 14 b1 be eb cb 10 cf a9 ee
r14:  e2 42 08 35 8a 5c bc f1 49 fe 64 78 03 49 0c 85 f0 e4 77 26 d2 5e f5 c1 3b 3d 2d cc cf 2a ac ed
r15:  88 52 74 6d bf b2 b9 f7 58 51 1c 50 f6 3d f2 c4 47 0a 21 30 47 81 2d e4 75 0d 8f 2d 22 b0 63 27
```

**T1 for PS5:**

```
      00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d 1e 1f
r00:  79 4d 78 30 fe 10 52 4c a8 90 5b 9a 7e 5f d3 e1 13 e0 f1 0f a3 e7 bb 45 7f dc 8e d5 f1 04 5c 78
r01:  51 ef f8 65 59 03 39 84 37 ae 59 df 23 b6 60 34 e6 4b e2 f5 4c 13 c6 da f9 fd b3 65 84 d6 45 ec
r02:  2c 00 f2 ed dc cb 93 6e 61 46 e5 d6 01 94 ee 78 85 0e 68 5e b5 5b cd d3 63 41 fc 81 43 1c 6f 7c
r03:  ba e8 bd 86 31 d5 70 7f b5 4a 90 3e 84 e1 71 e0 02 99 f4 71 e7 02 ed 36 af de 56 c2 90 e0 ae c2
r04:  f9 af 53 c6 d8 62 16 32 27 fb 6e 9b 48 c6 ea ff 6f 78 02 22 98 2c 1f bf b0 8e a9 39 bc df 17 de
r05:  d7 0e e1 7a 01 0e c3 87 fc aa e4 6b 0f 5b 0a f1 18 19 8a e5 2c 36 9b 40 30 99 24 94 48 d7 47 b2
r06:  af 6b 8c 40 9e 4d 6d 34 07 c1 26 2f bb 14 f7 bc 36 52 bd 84 fe 4a 9a f4 8a db 34 89 aa f1 0d 94
r07:  0b 92 f4 1c e4 6c 79 2d 6e c0 19 0a d5 55 94 14 05 13 c2 62 23 b3 d4 26 c4 44 56 7a cd 1c ea d4
r08:  74 b9 36 40 9f 08 fb 49 62 05 92 98 ad 1d 9f 8a 76 8b d4 0f 21 40 76 b6 16 91 45 93 66 cc 12 ea
r09:  4d f4 09 e2 ac 33 d0 6f 43 51 07 3e d7 95 2c 1e 1f 0c 24 b3 0e 3a ef 95 f5 eb 77 dd 20 f2 35 98
r10:  f2 ae a9 66 e6 13 ef 5d 3a 2d 66 ed e2 1e e9 32 4a 40 bf 37 c6 70 29 d9 8c a1 61 4a 29 3d c7 55
r11:  9c 94 9e c9 11 45 10 28 a7 27 d1 d3 d0 84 79 c7 a9 b0 f6 af 45 8c 3c d4 df 3b f7 0d a2 4f 13 97
r12:  78 27 f0 48 c0 a5 ab 83 01 05 d0 12 d7 1e 12 3a 4e 98 77 ae ba b1 4e b5 3b 59 ca 6d a5 11 80 91
r13:  9c 07 69 59 5a 53 70 7c 95 97 11 6d 66 8d a3 bd bb 2d b0 bf 9b 10 cb c7 0f 5b 7e 67 e2 b0 4b ba
r14:  10 12 b9 bc 97 fd 48 e4 8a c1 0f a1 30 9d 56 20 24 1a 7d 5b a0 b4 be 9d 38 4f b4 56 a8 4d 13 7c
r15:  44 e8 84 97 eb 78 2c 52 85 e4 a2 f6 f3 d9 71 9e ee b8 11 47 fb a9 1b c7 40 c6 e1 19 6d 50 a1 2a
```

### 2.8 Response

**HTTP layer.** The response is read up to and including the first `\r\n\r\n`; that part is the
header. The status line must start with `HTTP/1.1 `; the code follows. Header lines are
`Name: value` (parsed as in 1.3; `\r\n` line ends). The reference allows at most 1500 bytes for
header plus body together.

- Code **200**: success. `Content-Length` (decimal) must be present and non-zero; exactly that many
  body bytes follow the header (some may already have arrived with the header).
- Any other code: registration failed. The header `RP-Application-Reason` carries a reason as a
  hexadecimal number (with or without `0x`); see 2.9.

**Body.** Decrypt the whole body with the registration cipher (same B, A, H as the request,
counter 0). The plaintext is a list of `Name: value` lines separated by `\r\n` (the same line
syntax as HTTP headers; no status line). Fields:

| Name | Value | Stored as |
|---|---|---|
| `PS4-RegistKey` / `PS5-RegistKey` (PS4 or PS5 prefix by console family) | Hex string, at most 32 hex digits | **Registration key**: the hex-decoded bytes, zero-padded to 16 bytes. **Required.** In practice the decoded bytes are themselves ASCII hex digits (8 characters, e.g. hex `3161326233633464` → text `1a2b3c4d`), followed by zeros. |
| `RP-Key` | Exactly 32 hex digits | **RP key** (16 bytes), the long-term secret input of the session cipher. **Required.** |
| `PS4-Mac` / `PS5-Mac` | Exactly 12 hex digits | **Console MAC address** (6 bytes). **Required.** |
| `PS4-Nickname` / `PS5-Nickname` | Text, < 32 bytes | Console name |
| `RP-KeyType` | Integer (decimal; `0x` prefix allowed) | Key type; stored, not used further. **Uncertain:** meaning. |
| `AP-Ssid` | Text, < 48 bytes | Console's Wi-Fi access point name (for direct Wi-Fi play); not used by Con |
| `AP-Bssid` | Text, < 32 bytes | idem |
| `AP-Key` | Text, < 80 bytes | idem |
| `AP-Name` | Text, < 32 bytes | idem |
| `RP-SupportCmd` | Integer | Logged only. **Uncertain:** meaning (a bit set of supported commands). |

Hex digits may be upper or lower case. Unknown names are ignored. Text values longer than the
limits shown are ignored (the field stays empty). A field with a malformed value counts as missing;
if registration key, RP key or MAC is missing the registration fails.

Note: the reference parser rejects the whole body if any line has an empty value or if a non-empty
line lacks a colon; a new implementation may be more tolerant.

**What the client keeps** (per console and account): registration key (16 bytes), RP key
(16 bytes), console MAC (6 bytes), console family and generation, console name. The registration
key and RP key are secrets. Later use:

- Session request: the registration key text (bytes up to the first `\0`) hex-encoded in the
  request (`01-session.md`); the RP key is the long-term secret input of the session cipher.
- Wake-up: the wake credential (1.5) is computed from the registration key.

### 2.9 Error reasons

`RP-Application-Reason` values (hexadecimal) known from the registration and session request:

| Value | Meaning |
|---|---|
| `80108b09` | Registration failed — almost always a wrong or expired PIN |
| `80108b02` | Invalid PSN id (account id / online id not accepted) |
| `80108b10` | Remote Play is already in use |
| `80108b15` | Remote Play on the console has crashed |
| `80108b11` | RP-Version mismatch (wrong generation) |
| `80108bff` | Unknown error |

Other failures: no `RES2`/`RES3` within 3 s (console off, not on this network, or the Link Device
screen not open); TCP connect refused or timed out; any timeout in 2.1; missing required fields.

### 2.10 Con

- Con registers **directly** (unicast probe), with the **account id** only (never an online id),
  using the generation from discovery (1.4, with Con's replacement of "unknown").
- The PIN is entered as 8 digits and passed as an integer.
- Con stores registration key, RP key, MAC, generation and a "console PIN" field that it never
  fills (0); that field is local only and never sent.
- Con does not use PSN registration (2.6.3).
- See also the byte-order doubt in section 5.

---

## 3. Launch specification

### 3.1 Where it goes

After the session request, the control connection and the network test (`01-session.md`,
`02-transport.md`), the client opens the stream transport and sends its first data message, the
**client launch message** (protobuf message type value 0 in the stream's message envelope; see
`02-transport.md`). Its payload fields are:

| Field | Wire type | Content |
|---|---|---|
| 1 | varint | Client transport version: **9** for PS4 consoles, **12** for PS5 |
| 2 | string | Session id (text received in the session request answer, `01-session.md`) |
| 3 | string | **Launch specification**, Base64 text (3.4) |
| 4 | bytes | "Encrypted key": always the 4 bytes `00 00 00 00` |
| 5 | bytes | Client ECDH public key (section 4) |
| 6 | bytes | Signature of the client public key (section 4) |

The console answers with the **console answer message** (type value 1), whose payload fields are:

| Field | Wire type | Content |
|---|---|---|
| 1 | varint | Console transport version |
| 2 | varint | Token |
| 3 | bool | Encrypted key accepted — must be true |
| 4 | bool | Version accepted — must be true |
| 5 | string | Session id |
| 6 | sub-message | Extended error information (event code, `02-transport.md` §11.2), optional |
| 7 | string | Console version text (optional) |
| 8 | bytes | Console ECDH public key — required |
| 9 | bytes | Signature of the console public key — required |

If either acceptance flag is false or field 8 or 9 is empty, the stream setup fails. While waiting
for the answer, a disconnect message ends the setup, and a stream-information message that arrives
early is kept and processed after the answer (`02-transport.md`).

How the launch message is split into chunks of the transport is in `02-transport.md`.

### 3.2 The JSON document

The launch specification is a compact JSON object (no whitespace, except one space noted below),
written with the fields in exactly this order. The values in *italics* are variables; everything
else is constant text that the reference sends (most of it is placeholder data the console
ignores; reproduce it verbatim).

| # | Key path | Value |
|---|---|---|
| 1 | `sessionId` | `"sessionId4321"` |
| 2 | `streamResolutions` | array with one object: `resolution` {`width`: *W*, `height`: *Hgt*}, `maxFps`: *F*, `score`: `10` |
| 3 | `network` | object: `bwKbpsSent`: *R*, `bwLoss`: `0.001000`, `mtu`: *MTU*, `rtt`: *RTT*, `ports`: `[53,2053]` |
| 4 | `slotId` | `1` |
| 5 | `appSpecification` | object: `minFps`: `30`, `minBandwidth`: `0`, `extTitleId`: `"ps3"`, `version`: `1`, `timeLimit`: `1`, `startTimeout`: `100`, `afkTimeout`: `100`, `afkTimeoutDisconnect`: `100` |
| 6 | `konan` | object: `ps3AccessToken`: `"accessToken"`, `ps3RefreshToken`: `"refreshToken"` |
| 7 | `requestGameSpecification` | object: `model`: `"bravia_tv"`, `platform`: `"android"`, `audioChannels`: `"5.1"`, `language`: `"sp"`, `acceptButton`: `"X"`, `connectedControllers`: `["xinput","ds3","ds4"]`, `yuvCoefficient`: `"bt601"`, `videoEncoderProfile`: `"hw4.1"`, `audioEncoderProfile`: `"audio1"`, and **for PS5 only** a last member `"adaptiveStreamMode": "resize"` (note the single space after the colon) |
| 8 | `userProfile` | object: `onlineId`: `"psnId"`, `npId`: `"npId"`, `region`: `"US"`, `languagesUsed`: `["en","jp"]` |
| 9 | `videoCodec` | **PS5 only**: `"avc"` (H.264) or `"hevc"` (H.265, with or without HDR) |
| 10 | `dynamicRange` | **PS5 only**: `"SDR"`, or `"HDR"` when H.265 HDR is chosen |
| 11 | `handshakeKey` | Base64 (standard, padded) of the 16-byte handshake key (section 4.1), 24 characters |

Numbers are plain unsigned decimals. Exact rendering for PS5, 1920×1080, 60 fps, 15000 kbit/s,
MTU 1454, RTT 1, H.264, handshake key `a0 a1 … af`:

```
{"sessionId":"sessionId4321","streamResolutions":[{"resolution":{"width":1920,"height":1080},"maxFps":60,"score":10}],"network":{"bwKbpsSent":15000,"bwLoss":0.001000,"mtu":1454,"rtt":1,"ports":[53,2053]},"slotId":1,"appSpecification":{"minFps":30,"minBandwidth":0,"extTitleId":"ps3","version":1,"timeLimit":1,"startTimeout":100,"afkTimeout":100,"afkTimeoutDisconnect":100},"konan":{"ps3AccessToken":"accessToken","ps3RefreshToken":"refreshToken"},"requestGameSpecification":{"model":"bravia_tv","platform":"android","audioChannels":"5.1","language":"sp","acceptButton":"X","connectedControllers":["xinput","ds3","ds4"],"yuvCoefficient":"bt601","videoEncoderProfile":"hw4.1","audioEncoderProfile":"audio1","adaptiveStreamMode": "resize"},"userProfile":{"onlineId":"psnId","npId":"npId","region":"US","languagesUsed":["en","jp"]},"videoCodec":"avc","dynamicRange":"SDR","handshakeKey":"oKGio6SlpqeoqaqrrK2urw=="}
```

(910 bytes.) The same for a PS4 omits `,"adaptiveStreamMode": "resize"`, `"videoCodec":"avc",` and
`"dynamicRange":"SDR",` (839 bytes). The reference limits the JSON to 1023 bytes.

**Uncertain:** whether PS4 with system software 12 and later also accepts the PS5-only members; the
reference does not send them to any PS4.

### 3.3 Values

| Variable | Meaning | Values |
|---|---|---|
| *W* × *Hgt*, *R* | Resolution and video bitrate in kbit/s | Presets: 640×360 @ 2000; 960×540 @ 6000; 1280×720 @ 10000; 1920×1080 @ 15000 |
| *F* | Maximum frame rate | 30 or 60 |
| *MTU* | Inbound MTU in bytes as measured by the network test (`02-transport.md`); 1454 if the test failed | integer |
| *RTT* | Round-trip time from the network test in **whole milliseconds** (microseconds ÷ 1000, rounded down); 1 if the test failed | integer |
| codec | H.264, H.265, or H.265 with HDR | see `videoCodec` / `dynamicRange` |

Adjustments made before the launch message is built, after the control connection reports the
console type (`RP-Server-Type`: 0 = PS4, 1 = PS4 Pro, 2 = PS5; `01-session.md`):

- console type 0 (base PS4) and the chosen height is 1080 → the 1280×720 preset (10000 kbit/s) with
  the same frame rate is used instead (when automatic downgrade is enabled);
- console type 0 or 1 (any PS4) → the codec is forced to H.264.

If the application disables video, the 640×360 preset with frame rate 0 is used.

**Con:** for console sessions Con picks the preset by the requested height (≥ 1080 → 1080p,
≥ 720 → 720p, ≥ 540 → 540p, otherwise 360p) and 60 fps when ≥ 60 is requested, else 30. The
presets always choose **H.264**, so Con's PS5 launch specification carries `"videoCodec":"avc"` and
`"dynamicRange":"SDR"`. Automatic downgrade is enabled.

### 3.4 Encryption and encoding

1. Take the JSON text and append one `\0` byte. Let *L* be this length (JSON length + 1).
2. Produce *L* bytes of keystream by encrypting *L* zero bytes with the **session cipher** (the
   cipher of 2.5 with the session's B and A derived from the console nonce and the RP key, see
   `01-session.md`; H chosen by the session's generation) at message counter **0**. Because the
   input is all zeros, this keystream equals AES-128-OFB output: K₁ = AES(B, IV), K₂ = AES(B, K₁), …,
   truncated to *L*.
3. XOR the JSON-plus-zero bytes with the keystream.
4. Encode the result with standard Base64 (with padding). This text is field 3 of the launch
   message.

**Con — cloud.** For PlayStation cloud streaming the launch specification is not built: the cloud
service supplies a ready Base64 string (several kilobytes long), and it is sent in field 3 as is.
The handshake key, session id, MTU and RTT also come from the cloud service, there
is no session request or network test, and the client transport version is 12 if the cloud slot is
a PS5 and 9 otherwise.

---

## 4. Key exchange

### 4.1 Handshake key

Before the stream transport is opened, the client generates a random 16-byte **handshake key**
from a cryptographically secure source (for cloud streams it is supplied by the service instead).
It is sent to the console inside the encrypted launch specification (field `handshakeKey`) and is
used to sign the public keys and to derive the stream keys.

### 4.2 ECDH

- Curve: **secp256k1** (the "Koblitz" curve, as used by Bitcoin; *not* P-256).
- The client generates a fresh key pair for every stream session.
- Public keys are exchanged in **uncompressed SEC1** form: `04` ‖ X (32 bytes, big-endian) ‖ Y
  (32 bytes, big-endian) = 65 bytes.
- Client signature (field 6 of the launch message): **HMAC-SHA256(key = handshake key, message =
  the 65-byte client public key)**, 32 bytes.
- The console sends its public key (answer field 8) and its signature (answer field 9), presumably
  computed the same way. The reference engine does **not** verify the console's signature; it only
  requires it to be present. An implementation may verify it (HMAC with the handshake key over the
  console's public key bytes). **Uncertain:** that the console's signature is exactly that HMAC;
  verify against a live console before rejecting sessions on a mismatch.

### 4.3 Shared secret

The shared secret is the **X coordinate** of the ECDH product point (client private key ×
console public key), 32 bytes big-endian, with no hashing or KDF applied (the plain ECDH output of
common libraries).

### 4.4 Stream keys

Two key sets are derived, one per direction, distinguished by an index:

- index **2**: client → console (what the client encrypts and authenticates with);
- index **3**: console → client (what the client decrypts and verifies with).

For each index *x*:

  M = HMAC-SHA256(key = shared secret (32 bytes), message = `01` ‖ *x* ‖ `00` ‖ handshake key (16 bytes) ‖ `01` ‖ `00`)

(the message is 21 bytes). Then the **base key** = M[0 … 15] and the **base IV** = M[16 … 31].
How these two values drive the stream encryption and the per-packet authentication tags is in
`02-transport.md`.

The keys are installed as soon as the console answer has been processed; all later stream
messages are protected with them.

---

## 5. PSN account identifiers

| Identifier | Form | Use here |
|---|---|---|
| Account id | Unsigned 64-bit integer. Sony's account services give it as a decimal string (`user_id` in the token information; also present in the access token's claims). | Registration (`Np-AccountId`), always for PS4 ≥ 7.0 and PS5 |
| Online id | The user's visible PSN name (text, 3–16 characters) | Registration of PS4 below 7.0 only (`Np-Online-Id`) |

**On-wire form of the account id:** 8 bytes, Base64-encoded (12 characters with one `=`). In the
reference tooling the 8 bytes are the decimal
number written **little-endian** (least significant byte first). Example: account id
`1234567890123456789` = 0x112210F47DE98115 → bytes `15 81 e9 7d f4 10 22 11` → `FYHpffQQIhE=`.

**Con — discrepancy to check.** Con converts the decimal account id into its 8 bytes
**big-endian** (most significant byte first) before passing it to the engine. This differs from
the reference tooling. **Uncertain:** which order the console expects; the little-endian form is
the one used by the established clients. If live registration fails with reason `80108b02`
(invalid PSN id), the byte order is the first suspect.

---

## 6. Test vectors

All vectors were produced with the reference engine and reproduced by an independent
implementation written from sections 2–4. Common inputs: IV seed A = `00 01 02 … 0f`,
PIN 12345678, account id bytes `01 02 03 04 05 06 07 08` (Base64 `AQIDBAUGBwg=`), filler `0x41`
everywhere (so *c0* = 1, *c1* = 8).

**PS4-9 (old generation)**

```
B   = 3f a0 a5 f8 dc bb 3e cc 50 ba ed ef 97 34 c7 c9
IV  = 4a 01 3f 3a 4e c9 2d d8 df 9d 7a 17 72 42 90 07
E at 0x11C..0x12B = 36 3b 4b ed 0a 6a df 52 2b d9 ca af 47 e5 17 d3
inner plaintext = "Client-Type: Windows\r\nNp-AccountId: AQIDBAUGBwg=\r\n"  (50 bytes)
inner encrypted =
  4f 4f ee 5a 69 27 ef 76 3f c4 3c 16 68 83 cd 97 56 0a 88 06 d4 d2 00 76 4d 71 51 9f b2 ce dc 8c
  bc 77 81 07 b1 86 6a 87 87 c0 81 e3 58 a0 a2 5c 7e 85
body length = 530, header: POST /sce/rp/regist ..., RP-Version: 9.0
```

**PS4-10**

```
B   = ce bc b6 40 08 07 76 04 7b 85 e8 5b f3 50 f5 2d
IV  = 87 5c c8 f1 9c d5 f0 37 17 ad 6a 2e 2d 02 cd fe
E   = 88 14 27 27 c2 e3 73 71 df 5e d5 a5 9c f7 7e 8f
      (body 0x0C7..0x0CE = df 5e d5 a5 9c f7 7e 8f, body 0x191..0x198 = 88 14 27 27 c2 e3 73 71)
inner plaintext = "Client-Type: dabfa2ec…0d34f\r\nNp-AccountId: AQIDBAUGBwg=\r\n"  (107 bytes)
inner encrypted =
  d3 e9 9d e4 9e 5c 46 1f 99 89 86 ff c8 e7 34 0c 77 2c 4d c9 9d 2c 84 51 7a 9b c8 51 70 88 99 79
  c3 43 fc 2e 9a e2 58 69 52 12 b5 0b c3 72 5a 00 b5 fe 40 8b e1 9a d3 94 51 60 7a 27 4a 88 16 73
  bd e6 7b 2c 6c 9a 50 ca 65 ca 64 75 d5 48 53 23 9d 91 01 38 f8 e0 a5 3c 39 bd 00 9a 83 32 a2 45
  2e a5 09 00 49 cf d3 50 90 c4 fb
body length = 587
```

**PS5**

```
B   = d8 60 e1 46 bd b0 bd 94 b4 60 07 0b b1 f3 86 6d
IV  = 8a d8 7b 1f 1a 32 e4 5d 44 ff 2e af 1e 6e 3c cb
E   = 7b 0a 38 8c fa d1 da 43 45 26 0d 8a ec 78 65 6c
      (body 0x0C7..0x0CE = 45 26 0d 8a ec 78 65 6c, body 0x191..0x198 = 7b 0a 38 8c fa d1 da 43)
inner encrypted =
  27 b3 66 fd b2 31 f7 ad 85 ea 2f 89 67 e9 c2 6b fb f7 3b b4 01 c2 50 59 1b b4 98 8c ba 55 1a 56
  fa 66 5f 6c df 8b 9f 21 87 d5 77 52 9e a6 8a c7 28 50 a8 29 02 04 1a e6 92 ce 2f 8d ff a7 19 d9
  63 4f f2 68 f4 e3 d1 98 02 f7 8b e8 65 6a e0 ab 0b 07 3c df 89 a1 96 b5 b4 3b d8 c4 9d a9 4f be
  5f 8c 69 80 17 02 d8 2a cc a4 60
body length = 587
```

**Launch-specification keystream** (cipher of 2.5 with B = `10 11 … 1f`, A = `20 21 … 2f`,
counter 0, first 48 bytes):

```
PS5 HMAC key:    ba 3c dd 46 36 94 c2 33 34 cb 42 50 1a 1a 05 9a 0d 35 b1 c6 c2 a3 fa 01 d6 d2 b2 11 0e 79 f9 4a
                 f0 26 44 8c 54 b1 94 d7 8b af 9f b8 7c 3c e2 43
PS4-10 HMAC key: ef 9c 77 1b 71 4f 9f ee bb ac a7 a8 28 be 5f 69 95 f7 cf 6f 16 96 f6 99 9a 36 70 b8 92 e2 2b 16
                 7d e2 2e 32 35 26 a4 98 88 29 2b eb de 3c 01 f7
```

**Stream key derivation** (shared secret = `00 01 02 … 1f`, handshake key = `a0 a1 … af`):

```
index 2: base key = 84 9f a4 7d 53 fe b0 d7 dc a3 97 41 34 ce bc 7b
         base IV  = 2b 86 f7 63 6e 38 3c 2e ba af 40 fb 13 62 21 95
index 3: base key = 51 8b e4 81 0f c1 43 41 a3 ba ea 42 7a c0 87 e7
         base IV  = 6b af e1 4f 25 c3 7d 15 25 60 17 73 35 70 73 85
```

**Public-key signature** (handshake key `a0 … af`, "public key" bytes `04 00 01 02 … 3f` — not a
real curve point, HMAC only): `5c2b92902c04dadb12d0ac7f1032025d990ccd1d219b77beb1616ccde7a29bd4`.

---

## 7. Doubts and open points

- **LAN registration** (2) has not been confirmed against a console.
- **Account id byte order** (5): Con uses big-endian, the reference tooling little-endian.
- **Client discovery port range** 9303–9319: whether the console cares.
- **Stray ` HTTP/1.1` line** in the registration request header (2.3): whether required.
- **Console signature** in the key exchange (4.2): exact construction not confirmed, never checked
  by the reference.
- **`RP-KeyType`, `RP-SupportCmd`** meanings (2.8).
- **PS5-only launch members for recent PS4 firmware** (3.2).
- **PS5 with system-version below 8050000** (1.4): handled as written, not seen in practice.
- **Wake-up timing** (1.5): no reply; boot time not specified.
