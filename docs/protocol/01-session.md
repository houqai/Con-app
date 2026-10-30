# 01 — Session start, "RP crypt" and the control channel

This part describes how a client starts and runs a Remote Play session with a PlayStation 4 or
PlayStation 5 on the local network: the HTTP session request, the symmetric cipher that protects
the session's secrets (called "RP crypt" here), the TCP control channel and its messages, the
order of the whole start-up, timers, and the results that are reported to the application.

Out of scope (other parts):

| Topic | Part |
|---|---|
| The datagram (UDP) stream transport, its handshake, the network/MTU test, the stream protobuf messages, the ECDH key exchange that keys the stream | `02-transport.md` |
| Video, audio, haptics, controller feedback | `03-media.md` |
| Discovery, registration with a PIN (source of the RP key and the regist key), launch parameters (the "launch spec" JSON) | `04-registration.md` |
| Sony cloud streaming: the stream from a cloud slot | `02-transport.md` §2.3 |
| Internet / PSN connections (relay transport, hole punching) | not described yet; known differences in §9 |

Conventions: all multi-byte integers are big-endian (network order) unless stated otherwise.
Byte strings are written in hex, two digits per byte. "Base64" always means the standard
alphabet (`A–Z a–z 0–9 + /`) with `=` padding and no line breaks. "mod 256" arithmetic is
ordinary 8-bit wrap-around. **Con** marks behaviour that exists only because of Con's own changes.
**Uncertain** marks what the reference behaviour does not explain.

---

## 1. Overview of a console session

A local console session goes through these steps, in this order:

1. **Session request** — a short HTTP/1.1 exchange over TCP to port 9295. The client proves it
   is registered (regist key) and names a protocol version; the console answers with a 16-byte
   random **server nonce** (or an error reason).
2. **Key derivation** — from the server nonce and the 16-byte **RP key** obtained at
   registration the client derives a 16-byte AES key **K** and a 16-byte **IV seed S** (section 4).
3. **Control channel** — a new TCP connection to port 9295. The client sends an HTTP/1.1 request
   whose headers carry values encrypted with K/S; after a 200 response the same TCP connection
   switches to a binary framed message stream, every payload encrypted with K/S.
4. The console sends a **session id** (or first asks for a **login PIN**, sec. 6.7.3).
5. The client sends a fixed burst of "feature" messages (sec. 6.8).
6. **Network test** over UDP (02) to determine MTU and round-trip time; fallback values are used
   if it fails.
7. The client creates a random 16-byte **handshake key** and an ECDH key pair, then runs the
   **stream connection** over UDP (02). The session id from step 4 and the launch spec encrypted
   with K/S (04, and sec. 4.6 here) are sent in the stream's first big message.
8. While the stream runs, the control channel stays open: heartbeats are answered, keyboard,
   PIN, screen-guard and other messages are exchanged.
9. When the stream ends (local stop, remote disconnect or error), the control TCP connection is
   closed and a single "quit" result is reported to the application.

---

## 2. Console generations, targets and version strings

The client keeps a **target**: the console generation plus the Remote Play protocol version it
speaks. It determines the URL paths, the version header value, the cipher key derivation, the
IV key and which optional control headers are sent.

| Target | Version string | Session request path | Control path | Key derivation (sec. 4.2) | IV HMAC key (sec. 4.3) | `RP-StartBitrate` | `RP-StreamingType` |
|---|---|---|---|---|---|---|---|
| PS4, version 8 | `8.0` | `/sce/rp/session` | `/sce/rp/session/ctrl` | "old PS4" | H-OLD | no | no |
| PS4, version 9 | `9.0` | `/sce/rp/session` | `/sce/rp/session/ctrl` | "old PS4" | H-OLD | no | no |
| PS4, version 10 | `10.0` | `/sie/ps4/rp/sess/init` | `/sie/ps4/rp/sess/ctrl` | "PS4" (tables SA4/SB4) | H-PS4 | yes | no |
| PS5, version 1 | `1.0` | `/sie/ps5/rp/sess/init` | `/sie/ps5/rp/sess/ctrl` | "PS5" (tables SA5/SB5) | H-PS5 | yes | yes |

- A session to a PS4 starts with target PS4/10.0; to a PS5 with PS5/1.0. The console kind (PS4
  or PS5) is known beforehand (discovery/registration, part 04).
- The target can be changed by version negotiation (sec. 3.5). After the session request
  succeeds the target is fixed for the rest of the session.
- An "unknown PS5" target (a PS5 that answered with a version other than `1.0`) is never used to
  run a session — negotiation fails instead. Note that if it were used, the reference would pick
  the PS4 IV key H-PS4 for it, not H-PS5 (the PS5 key is chosen only for exactly PS5/1.0).

---

## 3. Session request

### 3.1 Inputs

| Input | Size | Source |
|---|---|---|
| Console address | IPv4 or IPv6 | user / discovery |
| Regist key | up to 16 bytes, zero-padded to 16 | registration (part 04, response header `PS4-RegistKey` / `PS5-RegistKey`, hex-decoded) |
| RP key | exactly 16 bytes | registration (part 04, response header `RP-Key`, hex-decoded) |

**Uncertain:** in practice the regist key bytes are themselves ASCII characters of a hex number
(commonly 8 bytes followed by zero padding). The reference only treats them as opaque bytes.

### 3.2 Connection

- The host name is resolved (IPv4 unless the user's string contains `:`, then IPv6). Every
  resolved address is tried in order: a TCP connection to **port 9295** with a **5 s** connect
  timeout. The first address that connects is used; it is remembered as **the console address**
  for the control channel and the stream.
- The numeric form of that address (no brackets, even for IPv6) is used in the `Host` header.
- If no address connects, the session ends (sec. 8). If the last failure was "connection
  refused", the reason is "session request: connection refused", otherwise "session request:
  unknown error".
- A new TCP connection is opened for every attempt (sec. 3.5); it is closed after the response.

### 3.3 Request

The request is sent at once (whole buffer; send timeout **5 s**). It is exactly these lines, each
ending in CR LF, followed by an empty line (CR LF) and no body:

```
GET <session request path> HTTP/1.1
Host: <numeric console address>:9295
User-Agent: remoteplay Windows
Connection: close
Content-Length: 0
RP-Registkey: <regist key as hex>
Rp-Version: <version string>
```

- Header order and spelling are as shown; note `Rp-Version` (lower-case `p`) in this request
  while the control request uses `RP-Version`. **Uncertain** whether the console cares; keep it.
- `RP-Registkey`: the regist key bytes **up to (not including) the first zero byte** (at most
  16), each byte as two **lower-case** hex digits. (With the usual ASCII-hex content every nibble
  is 0–9, so case never shows.)
- The total request is well under 512 bytes.

Example for a PS5 with regist key bytes `61 31 62 32 63 33 64 34` ("a1b2c3d4") at 192.168.1.20:

```
GET /sie/ps5/rp/sess/init HTTP/1.1\r\n
Host: 192.168.1.20:9295\r\n
User-Agent: remoteplay Windows\r\n
Connection: close\r\n
Content-Length: 0\r\n
RP-Registkey: 6131623263336434\r\n
Rp-Version: 1.0\r\n
\r\n
```

### 3.4 Response

- Read from the socket until the four bytes CR LF CR LF have been seen (total wait **5 s**). Only
  the header part is used; any body is ignored. The reference keeps at most 512 bytes.
- The status line must begin with exactly `HTTP/1.1 ` followed by a decimal status code.
- Header lines are `Name: Value` (one optional space after the colon); lines end with CR LF
  (a bare LF is also accepted). An empty value or a line without a colon makes the response
  invalid.
- Headers used:

| Header | Matching | Meaning |
|---|---|---|
| `RP-Nonce` | exact case | Base64 of the 16-byte server nonce N |
| `RP-Version` | case-insensitive | the console's own version string (sent with errors) |
| `RP-Application-Reason` | exact case | error reason, a hexadecimal number (an optional `0x` prefix is accepted) |

- **Success** = status 200 **and** `RP-Nonce` present **and** it Base64-decodes to exactly 16
  bytes. Anything else is a failure. A 200 without a valid nonce is "session request: unknown
  error".

Application reasons (`RP-Application-Reason`):

| Value | Meaning | Result |
|---|---|---|
| `80108b02` | invalid PSN id | session request: unknown error |
| `80108b09` | registration failed (probably wrong PIN / stale registration) | session request: unknown error |
| `80108b10` | Remote Play is already in use on the console | "Remote Play already in use" |
| `80108b11` | RP version mismatch | version negotiation (sec. 3.5), else "version mismatch" |
| `80108b15` | Remote Play on the console crashed | "Remote Play crashed" |
| `80108bff` | unknown | version negotiation if `RP-Version` differs (sec. 3.5), else unknown error |
| anything else / absent | — | session request: unknown error |

### 3.5 Version negotiation

Up to three session requests are made:

1. With the initial target (PS4 → `10.0`, PS5 → `1.0`).
2. If the response is a failure **and** the reason is `80108b11` or `80108bff` **and** the
   response has an `RP-Version` header **and** its value differs from the version string just
   sent, the console's version is mapped to a target:
   - for a PS5: `1.0` → PS5/1.0; anything else → unknown;
   - for a PS4: `8.0`, `9.0`, `10.0` → the matching PS4 target; anything else → unknown;
   - special case: if the mapping gave "unknown" and the value is exactly `5.0`, use PS4/9.0
     (some consoles report `5.0`; 9.0 works for them). The reference applies this even for a PS5.
   - If still unknown: the session ends with "version mismatch".
   - Otherwise the target is switched and the request is repeated on a new TCP connection.
3. The same rule once more (a third request with the newly reported version).
4. The third request may not negotiate any further: a version mismatch there ends the session
   with "version mismatch" (reason `80108b11`) or "unknown error" (other reasons).

A failure that is not a negotiable mismatch ends the session immediately with the result from the
table in sec. 3.4.

---

## 4. RP crypt

RP crypt is the symmetric cipher shared by the session request result, the control channel, the
launch spec, and (with different keys) registration. It has three parts: a 16-byte AES key K, a
16-byte IV seed S, and a per-message 64-bit counter.

### 4.1 Session keys

After a successful session request: N = the 16-byte server nonce, R = the 16-byte RP key.
K and S are computed byte by byte, `i` = 0…15, all arithmetic mod 256, `^` = XOR.

### 4.2 Derivation per target

**Old PS4 (versions 8.0 and 9.0).** Two constant 16-byte strings:

```
P1 = 01 49 87 9b 65 39 8b 39 4b 3a 8d 48 c3 0a ef 51
P2 = e1 ec 9c 3a dd bd 08 85 fc 0e 1d 78 90 32 c0 04
```

- S[i] = (N[i] − i − 0x27) ^ P1[i]
- K[i] = (R[i] − i + 0x34) ^ P2[i] ^ N[i]

**PS4 version 10.0.** Two tables of 32 rows × 16 bytes (Appendix A). Let
A = row (N[0] >> 3) of table SA4 and B = row (N[7] >> 3) of table SB4.

- S[i] = (N[i] + 0x36 + i) ^ A[i]
- K[i] = ((B[i] ^ R[i]) + 0x21 + i) ^ N[i]

**PS5 version 1.0.** A = row (N[0] >> 3) of table SA5, B = row (N[7] >> 3) of table SB5.

- S[i] = (N[i] − 0x2d − i) ^ A[i]
- K[i] = (R[i] + 0x18 + i) ^ N[i] ^ B[i]

(Precedence: the parenthesised sum/difference is taken mod 256 first, then XORed.)

### 4.3 IV for a counter value

For a 64-bit counter value c:

  IV(c) = first 16 bytes of HMAC-SHA256( key = H, message = S ‖ c as 8 bytes big-endian )

The message is 24 bytes. H is a 16-byte constant chosen by target:

| Name | Used for | H |
|---|---|---|
| H-PS5 | exactly PS5/1.0 | `46 46 87 b3 49 ca 8c e8 59 c5 27 0f 5d 7a 69 d6` |
| H-OLD | PS4/8.0 and PS4/9.0 | `ac 07 88 83 c8 3a 1f e8 11 46 3a f3 9e e3 e3 77` |
| H-PS4 | every other target (PS4/10.0; also registration of a PS4) | `20 d6 6f 59 04 ea 7c 14 e5 57 ff c5 2e 48 8a c8` |

### 4.4 Cipher

- Algorithm: **AES-128 in CFB mode with 128-bit feedback** (CFB-128), key K, IV = IV(c), no
  padding; the ciphertext has exactly the length of the plaintext (the last partial block uses
  only the needed keystream bytes).
- Every protected item (one header value, one control message payload) is encrypted **on its
  own**: a fresh CFB stream that starts at IV(c) for that item's counter value c. Nothing is
  chained between items.
- Decryption is the CFB inverse with the same K and IV(c).
- There is no authentication tag. A wrong key just yields garbage plaintext.

### 4.5 Counters

Two independent counters, both starting at 0 for each new control connection:

- **Local counter** (client → console): incremented by one for every item the client encrypts,
  in the order the items are encrypted.
- **Remote counter** (console → client): incremented by one for every item the client decrypts.

Usage in a local (LAN) session:

| Item | Direction | Counter |
|---|---|---|
| `RP-Auth` header value | client → console | local 0 |
| `RP-Did` header value | client → console | local 1 |
| `RP-OSType` header value | client → console | local 2 |
| `RP-StartBitrate` header value (PS4 10.0 and PS5 only) | client → console | local 3 |
| `RP-StreamingType` header value (PS5 only) | client → console | local 4 |
| each later control message **with a non-empty payload** | client → console | next local value (3 for PS4 8/9, 4 for PS4 10, 5 for PS5, then +1 each) |
| `RP-Server-Type` response header value, if present and exactly 16 bytes | console → client | remote 0 |
| each received control message **with a non-empty payload** | console → client | next remote value |
| the launch spec (sec. 4.6) | client → console | fixed value **0**, outside both counters |

- Control messages with an empty payload (e.g. heartbeat reply, sleep) are sent without
  encryption and **do not** advance the local counter; received empty messages do not advance
  the remote counter.
- If `RP-Server-Type` is absent or does not decode to exactly 16 bytes, the reference does not
  consume remote counter 0 for it, so the first received control payload is decrypted with
  counter 0. **Uncertain** whether a console ever omits the header; with every known console it
  is present.
- Because the client encrypts and sends from more than one place, an implementation must make
  "take the next local counter, encrypt, write to the socket" one atomic step, so that the
  console receives the payloads in counter order.

### 4.6 Launch spec protection (for part 04)

The launch spec JSON (part 04) is protected with K/S but **not** with plain CFB encryption:

1. Take the JSON text **including its terminating zero byte** (length L).
2. Produce L keystream bytes by CFB-128-encrypting L zero bytes with key K and IV(0) (counter
   value 0). Since the plaintext is zero, this equals the OFB keystream: block 0 = AES_K(IV(0)),
   block j = AES_K(block j−1).
3. XOR the keystream into the JSON bytes; Base64 the L result bytes.

Note this differs from CFB-encrypting the JSON directly (CFB would feed the ciphertext back).
The value 0 is reused although the `RP-Auth` header was also encrypted with counter 0.

### 4.7 Test vectors

Computed independently from the description above (not taken from any test suite).
Inputs: N = `9c 3e 51 07 c2 88 1d f4 6b 20 e7 93 4a 0d b6 75`,
R = `11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff 00`,
regist key field = `61 31 62 32 63 33 64 34 00 00 00 00 00 00 00 00`.

**PS4 8.0 / 9.0**

```
K               38 87 a8 48 9a a0 b0 c4 52 fb 1f 1e df 2a 53 54
S               74 5f af 46 f2 65 7b ff 77 ca 3b 29 d4 d3 6e 6e
IV(0)           db 69 1e fa 5f 55 e5 c5 c7 80 d4 fc 7c bc fe 02
IV(1)           a6 cf 49 ef 2d a1 0c 43 89 07 6b 6b cd 4a a7 70
RP-Auth (c=0)   8e 7b aa 3a ea 35 ae 21 f0 6b f5 93 c5 38 f1 82  -> "jnuqOuo1riHwa/WTxTjxgg=="
OSType  (c=2)   da 29 a8 c5 fe 5e e1 72 f0 29                    -> "2imoxf5e4XLwKQ=="
00 01 01 59 (c=5)  14 f6 4d 4b
```

**PS4 10.0**

```
K               76 52 38 dc 13 92 3d ec 3b 33 ca 83 eb e3 e6 8c
S               d0 a6 a5 ac 04 4c 4d 53 d5 27 60 a7 64 85 ba 97
IV(0)           3c ff 1c e1 7b 24 04 b4 15 e3 0b 90 8a 75 0a ee
IV(1)           5d 6f 45 9c e0 6d 37 ff ef e8 9a 63 d4 a9 90 80
RP-Auth (c=0)   7e c0 bd 28 44 51 7a 23 b6 c1 31 7a 46 39 a6 a1  -> "fsC9KERReiO2wTF6RjmmoQ=="
OSType  (c=2)   64 42 eb 6f e1 a3 ed fa 6c 43                    -> "ZELrb+Gj7fpsQw=="
00 01 01 59 (c=5)  45 35 63 d0
```

**PS5 1.0**

```
K               e1 6c 0f 8d 28 63 9a 08 98 24 98 c5 1b 81 53 9e
S               2a 1c c5 15 8b ea 26 3f 5b d5 a5 0c 85 cf d9 1c
IV(0)           98 d7 d8 3a b6 ce a8 90 c5 54 8d 82 25 66 14 01
IV(1)           ef db 26 d0 bc 8b 55 fc 0c 1b 28 b7 5a 35 66 1b
RP-Auth (c=0)   a7 28 94 59 c5 d1 a2 5e 22 1a 88 3d 0f b6 d5 27  -> "pyiUWcXRol4iGog9D7bVJw=="
OSType  (c=2)   bb de 06 26 0b 44 0b d2 76 00                    -> "u94GJgtEC9J2AA=="
00 01 01 59 (c=5)  29 b6 ec 4c
```

CFB vs. launch-spec keystream, PS5 1.0, counter 0, 40 bytes:

```
keystream (40 zero bytes "encrypted"):
  c6 19 f6 6b a6 e2 c6 6a 22 1a 88 3d 0f b6 d5 27 10 4f 0f 51 1d 48 16 78 44 38 4c 16 f7 f3 2b ae
  fa d6 46 c1 be 11 80 3e
CFB-128 encryption of bytes 00 01 02 ... 27:
  c6 18 f4 68 a2 e7 c0 6d 2a 13 82 36 03 bb db 28 a7 4f ad 1d 8a 25 fa d4 94 2e d8 39 ba 79 60 84
  68 63 c1 88 a4 75 90 fc
```

(The first 16 bytes agree, later blocks differ — that is the CFB/OFB difference of sec. 4.6.)

---

## 5. Device id

The client presents a 32-byte **device id** in the control request (`RP-Did`). A new one is made
for every session:

| Offset | Size | Value |
|---|---|---|
| 0 | 10 | `00 18 00 00 00 07 00 40 00 80` |
| 10 | 16 | cryptographically random bytes |
| 26 | 6 | `00 00 00 00 00 00` |

---

## 6. Control channel

### 6.1 Connection

- After the session request succeeds the client derives K/S (sec. 4), waits about **10 ms**
  (the PS4 does not always accept the next connection immediately), then opens a **new TCP
  connection to port 9295** of the console address chosen in sec. 3.2 (connect timeout **5 s**).
- Local and remote counters are reset to 0.

### 6.2 Control request

All encrypted header values are produced with RP crypt and the counter shown in sec. 4.5, then
Base64-encoded:

| Header | Plaintext before encryption |
|---|---|
| `RP-Auth` | the 16-byte regist key field (all 16 bytes, including the zero padding) |
| `RP-Did` | the 32-byte device id (sec. 5) |
| `RP-OSType` | the 9 characters `Win10.0.0` followed by one zero byte (10 bytes) |
| `RP-StartBitrate` | 4 zero bytes (PS4 10.0 and PS5 only) |
| `RP-StreamingType` | 4 bytes, **little-endian** 32-bit codec choice: 1 = H.264, 2 = H.265, 3 = H.265 HDR (PS5 only) |

The request (each line ends in CR LF, then an empty line):

```
GET <control path> HTTP/1.1
Host: <numeric console address>:9295
User-Agent: remoteplay Windows
Connection: keep-alive
Content-Length: 0
RP-Auth: <base64>
RP-Version: <version string>
RP-Did: <base64>
RP-ControllerType: 3
RP-ClientType: 11
RP-OSType: <base64>
RP-ConPath: 1
RP-StartBitrate: <base64>        (only PS4 10.0 and PS5)
RP-StreamingType: <base64>       (only PS5)
```

- The order of headers is as above. The fixed values `RP-ControllerType: 3`, `RP-ClientType: 11`
  and `RP-ConPath: 1` are sent unchanged. **Uncertain:** their meaning (by their names: controller
  type, client type and connection path).
- The whole request is below 512 bytes and is written with a single send.
- The encrypted values are computed once. If a resend is needed (below) the identical bytes are
  sent again; the counters are not rewound and not advanced again.

### 6.3 Control response

- Read until CR LF CR LF, at most **5 s**.
- If that times out the first time, the client closes the TCP connection, opens a new one
  (same address and port, 5 s connect timeout) and sends the identical request once more. A second
  timeout, or any other receive failure, makes the control channel fail.
- Status must be 200, otherwise the control channel fails.
- Headers used:

| Header | Content | Use |
|---|---|---|
| `RP-Server-Type` | Base64 of 16 bytes, encrypted with RP crypt, remote counter 0 | byte 0 of the plaintext: 0 = PS4, 1 = PS4 Pro, 2 = PS5. The other 15 bytes are not used. |
| `RP-Prohibit` | decimal integer | `1` = the console currently shows something that may not be streamed (the application is told "cannot display", see sec. 6.7.6) |

- A correct `RP-Server-Type` value is 24 Base64 characters ending in `==`. If it is malformed
  or decodes to more than 16 bytes, the control channel fails. If it decodes to fewer than 16
  bytes it is ignored (and the remote counter is not advanced).
- Server type adjustments (made before the stream is negotiated):
  - type 0 (plain PS4), the user asked for 1080p and allowed automatic downgrade → use the 720p
    preset instead (1280×720, 10 000 kbit/s), keeping 60 fps if 60 was asked, otherwise 30 fps;
  - type 0 or 1 (any PS4) and a codec other than H.264 was asked → use H.264.
- Any bytes received after the CR LF CR LF belong to the framed message stream (sec. 6.4) and
  must be kept as its start.

### 6.4 Message framing

After the HTTP response the TCP stream carries messages in both directions, each:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | payload length L (big-endian, unsigned) |
| 4 | 2 | message type (big-endian) |
| 6 | 2 | zero |
| 8 | L | payload, encrypted with RP crypt if L > 0 |

- The 8-byte header is never encrypted.
- The client encrypts each non-empty payload with the next local counter (sec. 4.5) and sends
  header and payload (each send with a 5 s timeout).
- Received messages are processed in arrival order; a non-empty payload is decrypted with the next
  remote counter before it is interpreted. The value at offset 6 is not checked.
- The reference holds at most 512 bytes of unprocessed input, so a single received message larger
  than 504 bytes of payload makes it fail the control channel. An implementation may accept larger
  messages; none of the known messages is that large except possibly keyboard text.
- Unknown message types are ignored (after decrypting, so the counter still advances).

### 6.5 Message catalog

C→S = client to console, S→C = console to client. Payloads are shown in plaintext.

| Type | Dir | Name (descriptive) | Payload |
|---|---|---|---|
| `0x0001` | S→C | screen guard | ≥ 1 byte, see 6.7.6 |
| `0x0004` | S→C | login PIN request | empty |
| `0x0005` | S→C | login result | 1 byte: 0 = success, 1 = PIN incorrect |
| `0x000d` | C→S | keyboard enable | 16 bytes `00 00 00 01 00 00 05 ae 00 00 00 00 00 00 00 00` |
| `0x0011` | C→S | DualSense controller info | 16 bytes `a0 ab 51 bd d1 7e 00 00 ff ff ff ff ff 00 00 00` |
| `0x0013` | C→S | enable DualSense features | 3 bytes `00 40 00` |
| `0x0014` | C→S | go to home screen | 16 bytes `00 ff` followed by 14 zero bytes |
| `0x0016` | S→C | screen blackout | ≥ 2 bytes, see 6.7.6 |
| `0x0020` | C→S | keyboard enable toggle | 1 byte `01` |
| `0x0021` | S→C | on-screen keyboard opened | ≥ 32 bytes, see 6.7.5 |
| `0x0022` | S→C | on-screen keyboard closed by console | ignored |
| `0x0023` | C→S | keyboard text change | 36-byte header + text, see 6.7.5 |
| `0x0024` | S→C | keyboard text changed | ≥ 40-byte header + text, see 6.7.5 |
| `0x0025` | C→S | keyboard close | 4 bytes: `00 00 00 00` accept, `00 00 00 01` cancel |
| `0x0030` | C→S | microphone connect | 2 bytes `00 00` |
| `0x0033` | S→C | session id | see 6.7.1 |
| `0x0034` | S→C | relay hand-over confirmed | empty (relay connections only, sec. 9) |
| `0x0036` | C→S | microphone mute state | 4 bytes `00 01 xx 59`, see 6.7.8 |
| `0x0050` | C→S | put console to sleep (rest mode) | empty |
| `0x00fe` | S→C | heartbeat request | empty |
| `0x01fe` | C→S | heartbeat reply | empty |
| `0x0910` | C→S | burst closer (meaning unknown) | 4 bytes `00 00 00 00` |
| `0x8004` | C→S | login PIN | the PIN as entered (UTF-8 digits, e.g. `31 32 33 34`), no terminator |

### 6.6 Keepalive

- The console sends heartbeat requests (`0x00fe`, empty) periodically; the client answers each
  immediately with `0x01fe` (empty, unencrypted, no counter). A non-empty request payload is
  tolerated (decrypted, ignored) and still answered.
- The client never initiates heartbeats on the control channel and has no timeout of its own for
  missing heartbeats. **Uncertain:** the console's heartbeat period and how long it waits for a
  reply before ending the session.

### 6.7 Message details

#### 6.7.1 Session id (`0x0033`, S→C)

| Offset | Size | Content |
|---|---|---|
| 0 | 1 | a marker/length byte; observed value `0x4a`. Not checked except that a different value is logged. |
| 1 | n | the session id: ASCII letters and digits only |

Validation (after decryption):
- total payload < 2 bytes → invalid;
- n must be at least 24 and at most 126 (**Con**: the reference allows at most 78; Con accepts up
  to 126 for cloud ids);
- any character outside `A–Z a–z 0–9` → invalid.

If valid, the id (without the first byte) is stored as the session's id and is later sent in the
stream's first big message (part 02). If invalid, a **fallback id** is created instead (below).
In both cases the client immediately sends the feature burst (sec. 6.8). A second session id
message does not change the id, but the reference sends the feature burst again for it.

**Fallback id:** the number of whole seconds of a monotonic clock written in decimal (at most 15
digits), immediately followed by the Base64 encoding (64 characters) of 48 fresh random bytes.
The same fallback is used if no session id arrives at all within 10 s (sec. 7.2). **Uncertain**
whether consoles accept a fallback id; the reference continues with it.

#### 6.7.2 Heartbeat — see 6.6.

#### 6.7.3 Login PIN

Some consoles (with a "login passcode" set for the user) require a PIN before they send the
session id.

- `0x0004` (login PIN request) — the client reports a "PIN requested" event to the application,
  with a flag "previous PIN was wrong" = false the first time and true on every later request in
  the same session. It then waits (without time limit) for the application to supply the PIN or to
  stop.
- If a PIN request arrives **after** a session id was already received, the client fails the
  control channel ("control: unknown error").
- The application's PIN is sent as `0x8004` with the PIN's bytes as payload (encrypted, next local
  counter).
- `0x0005` (login result) — byte 0 = 0: success (the session id normally follows); byte 0 = 1:
  incorrect — if a PIN had been requested, the client treats it exactly like a new PIN request
  (event with "previous PIN was wrong" = true). Other values are only logged. A payload longer than
  1 byte is accepted (first byte used); an empty one is ignored.

#### 6.7.4 Sleep, home, microphone (C→S commands from the application)

- **Sleep** — `0x0050`, empty payload. The console goes into rest mode; the stream is normally
  closed by the console afterwards.
- **Go home** — `0x0014`, 16 bytes `00 ff 00 … 00`.
- **Microphone connect** — `0x0030`, `00 00`.
- **Microphone mute state** — `0x0036`, 4 bytes `00 01 xx 59` with xx = `01` when the
  microphone is to be live and `00` when muted (the reference's application flag "muted" maps to
  `00`). **Uncertain:** the meaning of bytes 0, 1 and 3 (`0x59`).

#### 6.7.5 On-screen keyboard

Only active if the user enabled keyboard support (the feature burst then sends `0x000d` and
`0x0020`).

**Keyboard opened (`0x0021`, S→C):**

| Offset | Size | Content |
|---|---|---|
| 0 | 28 | unknown, ignored |
| 28 | 4 | text length T (big-endian) |
| 32 | T | current text, UTF-8, no terminator |

Total length is expected to be 32 + T; shorter than 32 is ignored. The application gets a
"keyboard opened" event with the text (empty text when T = 0).

**Keyboard text changed (`0x0024`, S→C):**

| Offset | Size | Content |
|---|---|---|
| 0 | 4 | counter (echo of the client's, sec. below) |
| 4 | 4 | unknown |
| 8 | 4 | text length T (big-endian) |
| 12 | 4 | unknown |
| 16 | 16 | unknown |
| 32 | 4 | unknown |
| 36 | 4 | second length field (not used) |
| 40 | T | text, UTF-8 |

Shorter than 40 bytes is ignored. The application gets a "keyboard text changed" event.

**Keyboard closed by console (`0x0022`, S→C):** payload ignored; the application gets a "keyboard
closed remotely" event.

**Keyboard text change (`0x0023`, C→S):** sent when the user edits the text:

| Offset | Size | Content |
|---|---|---|
| 0 | 4 | counter, big-endian; 1 for the first text change of the session, +1 each time |
| 4 | 4 | text length T (big-endian) |
| 8 | 8 | zero |
| 16 | 16 | zero |
| 32 | 4 | text length T again (big-endian) |
| 36 | T | the complete new text, UTF-8, no terminator |

**Keyboard close (`0x0025`, C→S):** `00 00 00 00` = accept the text, `00 00 00 01` = cancel.

#### 6.7.6 Screen guard and blackout ("cannot display")

The console reports when the picture contains content that may not be streamed. The client keeps
two flags, "guard armed" and "blacked out", both false at start, and tells the application
"cannot display = true/false":

- `0x0001`, byte 0 = `01` → arm the guard.
- `0x0001`, byte 0 = `00` and not blacked out → disarm the guard and tell the application
  "cannot display = false".
- `0x0016`, when the guard is armed, not blacked out and the first two bytes are **not** `01 ff`
  → tell the application "cannot display = true" and mark blacked out.
- `0x0016`, when blacked out and the first two bytes are `01 ff` → clear "blacked out" (no
  notification).
- `RP-Prohibit: 1` in the control response → "cannot display = true".

The reference reads byte 0 (and byte 1) without checking the length; an implementation should
ignore payloads that are too short. **Uncertain:** the full meaning of these messages; the
behaviour above is what is known to work.

#### 6.7.7 DualSense info and the burst closer

See the feature burst, sec. 6.8. **Uncertain:** the meaning of the `0x0011` bytes; they are sent
unchanged.

#### 6.7.8 Microphone — see 6.7.4.

### 6.8 Feature burst after the session id

Immediately after a session id message (valid or not), or after a fallback id was made because no
session id came, the client sends, in this order, each with the next local counter:

1. If DualSense features are enabled: `0x0013` `00 40 00`, then `0x0011` (16 bytes, table 6.5).
2. If keyboard support is enabled: `0x000d` (16 bytes, table 6.5), then `0x0020` `01`.
3. `0x0036` `00 01 01 59` (microphone live) — **twice**.
4. `0x0910` `00 00 00 00`.

### 6.9 End of the control channel

- There is no goodbye message on the control channel. The client ends it by closing the TCP
  connection, after the stream connection has ended (the stream's own disconnect message is part
  02).
- If the console closes the TCP connection (orderly close, zero-length read), the reference
  silently stops reading the control channel **without** ending the session; the session ends
  when the stream ends. A receive error, a frame larger than the buffer limit (sec. 6.4) or a PIN
  request after the session id makes the control channel fail. Before the stream is started
  this ends the session with "control: unknown error" (checked while waiting in states 4–5 and
  right after the network test). Once the stream runs, a control failure neither ends the stream
  nor appears in the quit result (the stream's own result replaces it).

---

## 7. Session lifecycle

### 7.1 States

| # | State | Leaves to | On failure |
|---|---|---|---|
| 1 | Requesting session (sec. 3) | 2 | quit with the session request result |
| 2 | Keys derived, short pause (~10 ms) | 3 | — |
| 3 | Control connecting and request/response (sec. 6.1–6.3) | 4 | quit "control: connect failed" |
| 4 | Waiting for session id or PIN request (≤ 10 s) | 5, 6 or 7 | control failed → quit with the control reason |
| 5 | PIN loop: event to the application, wait for PIN (no limit), send PIN, then back to waiting (≤ 10 s) | 5, 6 or 7 | control failed → quit |
| 6 | Session id present | 8 | — |
| 7 | No session id after the wait: make a fallback id, send feature burst | 8 | quit "control: unknown error" if the fallback cannot be made |
| 8 | Network test over UDP (part 02). On failure: MTU in = MTU out = 1454, RTT = 1 ms, "don't fragment" off | 9 | user stop → quit "stopped"; control failed meanwhile → quit with the control reason |
| 9 | Handshake key (16 random bytes) and ECDH key pair made | 10 | quit (unknown) |
| 10 | Stream connection running (part 02); control channel serving in parallel | 11 | see 8.1 |
| 11 | Close control TCP, report quit | — | — |

- A user stop is checked at every step; it aborts any wait or connection attempt immediately and
  produces the result "stopped".
- During state 10 the control channel continues to process heartbeats, keyboard, screen-guard,
  login messages and application commands.
- If the stream ends with a remote disconnect, the console's reason text (from the stream's
  disconnect message, part 02) is passed to the application along with the result.

### 7.2 Timers

| What | Value |
|---|---|
| Session request: TCP connect, per address | 5 s |
| Session request: send | 5 s |
| Session request: response header | 5 s |
| Pause between session request and control connection | 10 ms |
| Control: TCP connect | 5 s |
| Control: response header | 5 s, one resend on a new TCP connection after the first timeout |
| Control: sending one frame (header, then payload) | 5 s each |
| Wait for session id or PIN request | 10 s |
| Wait for the user's PIN | unlimited |
| Wait for session id or another PIN request after sending a PIN | 10 s |
| Network-test fallback values | MTU in 1454, MTU out 1454, RTT 1000 µs |

---

## 8. Results reported to the application

### 8.1 Quit results

Exactly one quit result is reported per session, with an optional text from the console.

| Result (meaning) | When | Is an error |
|---|---|---|
| stopped | the application stopped the session; or the stream ended normally | no |
| session request: unknown error | no address connected (last failure not "refused"); sending/receiving/parsing failed; 200 without valid nonce; reasons `80108b02`, `80108b09`, unknown reasons; internal failure | yes |
| session request: connection refused | the last address tried refused the TCP connection | yes |
| session request: Remote Play already in use | reason `80108b10` | yes |
| session request: Remote Play crashed | reason `80108b15` | yes |
| session request: version mismatch | reason `80108b11` that negotiation could not resolve; or an unknown console version | yes |
| control: unknown error | the control channel failed after it was set up (receive error, oversize frame, PIN request after session id); or no session id and no fallback | yes |
| control: connect failed | any failure while connecting the control channel or in its request/response (including a non-200 status) | yes |
| control: connection refused | (exists, but the reference always overrides it with "control: connect failed") | yes |
| stream: unknown error | the stream connection failed for another reason | yes |
| stream: remote disconnected | the console ended the stream; its reason text is attached | yes |
| stream: remote shut down | the console ended the stream with reason text exactly `Server shutting down` | **no** |
| PSN registration failed | relay connections only (sec. 9) | yes |

### 8.2 Events from this part

| Event | Data |
|---|---|
| PIN requested | "previous PIN was wrong" flag |
| keyboard opened | current text (may be empty) |
| keyboard text changed | text |
| keyboard closed remotely | — |
| cannot display | true / false (sec. 6.7.6) |
| quit | result and optional reason text |

The "connected" event (stream running) and media events belong to parts 02/03.

### 8.3 Commands from the application handled by this part

| Command | Effect |
|---|---|
| submit PIN | `0x8004` (sec. 6.7.3) |
| sleep | `0x0050` |
| go home | `0x0014` |
| microphone connect | `0x0030` |
| microphone mute / unmute | `0x0036` |
| keyboard set text / accept / cancel | `0x0023` / `0x0025` |
| stop | aborts the current step; ends the stream; closes control; quit "stopped" |

Commands are only meaningful while the control channel is open. They must be serialized with
the client's own sends (sec. 4.5).

---

## 9. Differences on a relay (internet / PSN) connection

The relay transport and hole punching are described in part 05. For this part the differences are:

- Before the session request the client performs registration over the relay (≤ 10 s); the RP key
  and regist key come from that registration. Failure or cancel → "PSN registration failed".
- The session request and the control request are the same HTTP texts, carried inside relay
  messages instead of TCP; `Host` uses the console address and the control port obtained by hole
  punching instead of 9295.
- Control frames (sec. 6.4) are carried inside relay data messages; the receiving side accepts a
  relay message as control data only if the 32-bit length at the start of the carried bytes equals
  the number of carried bytes minus 8.
- Counter quirks seen only on the relay:
  - for a PS5, the local counter is advanced by one extra step after the control request headers
    are encrypted and before any control message (so the first control payload uses 6, not 5);
  - the login PIN reply (`0x8004`) is encrypted with the value **one below** the next local
    counter, while the counter still advances by one.
  **Uncertain:** whether these are protocol requirements or compensations in the reference; they
  are what is known to work.
- After the network test the client sends a "relay hand-over request": a frame with
  length field `00 00 00 10`, type `00 0d`, zero field `00 00` and 16 **unencrypted random**
  bytes. The console answers with control message `0x0034` (empty); the client waits ≤ 5 s for it
  and fails otherwise. After that the stream runs over the hole-punched data socket.

---

## 10. Con-specific behaviour

- **Con — cloud slots skip this whole part.** When Con connects to a Sony cloud streaming slot
  (part 05) there is no session request and no control channel. The slot supplies the session id
  (up to 127 characters), the 16-byte handshake key, the launch spec (already encoded by the
  service and sent unchanged), the UDP port, MTU in/out and RTT (defaults when missing: 1454, 1254,
  1000 µs; "don't fragment" off). The stream is negotiated as for a PS4 10.0 target (only the
  transport version differs, part 02/05). The session goes straight to "ECDH key pair, run stream";
  RP crypt is not used. Quit results are only the stream ones and "stopped"; an ECDH set-up failure
  gives "stream: unknown error". No PIN, keyboard, heartbeat or screen-guard messages exist.
- **Con — longer session ids.** The session id buffer is 128 bytes, which raises the
  accepted console session id length to 126 characters (sec. 6.7.1).
- **Con — reliable data message reassembly.** This is part of the UDP transport's reliable data
  channel, not of the TCP control channel; part 02 is authoritative. In short: a reliable data message may arrive in
  several fragments; bit 0 of the message's flags byte marks the last fragment; the first fragment
  has a 9-byte header (data type at offset 8), continuations an 8-byte header without the type
  byte; fragments are joined per channel up to 1 MiB; a fragment on another channel while one
  message is pending is delivered alone if it is complete, and dropped if it starts a second
  fragmented message.
- **Con — round-trip measurement.** Also transport-level (part 02/03): the time from the
  first sending of a reliable data message to its acknowledgement is measured (not for messages
  given up after all resends) and exposed to the application as "latest RTT" and "number of
  samples". No effect on the wire.

---

## 11. Open questions

- Meaning of `RP-ControllerType`, `RP-ClientType`, `RP-ConPath`, the device id's fixed bytes, the
  `0x0011` payload and the microphone bytes; all are sent as observed.
- Whether the first byte of the session id message is a length; it is observed as `0x4a`.
- The console's heartbeat period and timeout.
- Whether consoles accept the fallback session id.
- The exact semantics of the screen guard and blackout messages.
- Whether the relay counter quirks (sec. 9) are required by the console.

---

## Appendix A — Session key tables

Each table has 32 rows of 16 bytes. Row r is used when the selecting nonce byte (N[0] for SA
tables, N[7] for SB tables) has r = byte >> 3, i.e. byte values 8r … 8r+7 (shown in brackets).
Byte columns are i = 0 … 15 from left to right.

#### Table SA4 — PS4 10.0, seed S (row chosen by N[0])

```
 0 (00-07): df 40 82 a6 2e d8 6b 2b f5 6c 5f f5 fb 21 69 b4
 1 (08-0f): 0d c0 ac 7e 04 b5 f0 75 de 5e ba fa a6 25 56 de
 2 (10-17): 75 58 21 fe 58 8f d0 75 f6 20 aa 54 3a 45 54 f3
 3 (18-1f): 62 1c 56 f1 86 88 db ce 10 bf 3d de e6 f5 02 51
 4 (20-27): 1a 62 eb 47 92 0c a7 e0 6c 33 f5 84 ec 69 31 db
 5 (28-2f): ed 98 d8 4f 23 3f 77 29 ac a5 bc d0 8f 2b 89 b9
 6 (30-37): 65 ee be d9 16 ea a9 66 07 97 71 43 dd 64 e3 00
 7 (38-3f): aa 10 b6 ce 73 e3 e3 8c f8 5d 0e 95 3e 1a 4f be
 8 (40-47): 77 6b 50 47 7c fc a4 d4 2c 4d 53 c1 26 26 92 38
 9 (48-4f): 69 6c 1e 85 48 ea 33 5b b1 28 09 e3 24 47 7a 12
10 (50-57): c3 4d e8 83 78 f1 8c 6a b3 87 7f 67 df 47 c4 2f
11 (58-5f): 1d ee a1 fd ed 82 19 1e 90 87 ab db 80 b7 b2 ab
12 (60-67): f4 b5 ae fc 53 0c ec 36 f0 b4 30 ea 9b de 60 31
13 (68-6f): 81 f5 12 72 02 35 87 65 01 ea 4f f7 95 ba b1 09
14 (70-77): a2 ef 3a a3 0c 99 4e 6e d4 64 bb d2 a0 38 39 e8
15 (78-7f): 36 bf 20 21 1b 34 5c bd 2c 64 c5 6f 7f b9 91 65
16 (80-87): f3 d2 c5 5d 1d 89 78 09 bb 6a 3a 0a 9c 01 4c d9
17 (88-8f): 19 7f c2 38 94 8a e4 2d 7f ff f7 45 57 21 98 aa
18 (90-97): 78 cf 63 53 57 08 11 55 65 1b 55 5e 8d ce 68 2d
19 (98-9f): 02 d3 2c ec f8 8f 14 62 7c 78 47 73 e8 d5 40 2d
20 (a0-a7): 40 9f 56 54 de 96 65 61 76 06 b6 db 16 c8 1c 0b
21 (a8-af): 76 77 fd 84 7b b4 3c 87 01 09 89 4c 0f 8e 44 c0
22 (b0-b7): 0b 0c 1f 20 aa 75 52 b5 bc a2 55 d6 06 3f f1 6a
23 (b8-bf): 2b b2 e4 70 da eb 49 e4 1b 1f df 45 ee 5a 69 68
24 (c0-c7): 3f 99 26 cb 6b ac ae 2b bc 75 f2 8d 64 ff d2 2b
25 (c8-cf): b4 27 78 2b cd 16 10 81 b1 59 fe e4 1b 62 d1 cf
26 (d0-d7): 31 43 8f 85 7d 59 a8 d2 26 4c a0 fb f8 db 6a 12
27 (d8-df): 93 e2 bc e7 26 df 77 88 e0 90 c0 2d 20 c9 8c fa
28 (e0-e7): ef 0f c6 3b 5b 4c f1 1b 35 92 b9 74 9e 0f 16 2a
29 (e8-ef): b3 7e d9 11 1a a3 41 c4 65 19 1d db 92 f4 3e f4
30 (f0-f7): e0 cd a6 ee 23 ef 64 87 65 5f fb 5f 6c 29 4a f9
31 (f8-ff): 80 a2 e0 69 bc 29 e3 48 08 a6 dc bc 68 d7 d7 84
```

#### Table SB4 — PS4 10.0, key K (row chosen by N[7])

```
 0 (00-07): 76 65 9d e4 f7 6c 45 1f 73 42 47 c3 92 32 f4 38
 1 (08-0f): 9b ee b5 ad a3 56 85 c3 bd 9b ef ac 55 98 1f af
 2 (10-17): 15 16 fb c3 09 d3 ad a4 ea a3 4a be f2 88 9a 34
 3 (18-1f): ba bd ac 73 7a e8 bc ad ba 5e a6 f0 b8 5a 51 2a
 4 (20-27): c1 88 7d ae f4 b8 89 b5 ce dd 27 be 6f 6c 81 8f
 5 (28-2f): 21 9f 9c 5d 98 72 a3 2e 74 49 70 af 85 7b 14 66
 6 (30-37): bf e8 25 af c2 df f3 a1 76 f4 2b 8c 6f 01 ce 96
 7 (38-3f): ba 43 f7 02 7a 0e 77 15 45 03 aa 84 88 56 b1 ee
 8 (40-47): 55 0f 6e c6 cd 6b c4 f0 a1 05 6b 3f c4 c9 47 95
 9 (48-4f): e9 de 2e 30 3c d6 46 ca 50 25 f7 a2 66 ec a5 6e
10 (50-57): 41 8c b0 51 74 32 ea 96 ce 70 1c 5c 26 34 66 3a
11 (58-5f): 11 1e d0 d8 99 37 ae 35 fa e4 0b 4c 52 0c 12 3a
12 (60-67): 1a b0 07 27 82 c5 13 86 3d b5 22 fb 7d 2a 4d 45
13 (68-6f): f5 b3 24 4a 2d 69 46 51 65 9a 37 11 7d de 9c 7c
14 (70-77): 1e f8 70 88 7d f9 2c f4 80 5c 6f 55 73 f2 a0 90
15 (78-7f): 52 7e 2c 50 36 d0 3b f7 1f d8 4a 06 11 f3 21 1f
16 (80-87): 3a f7 df 1c a8 85 d5 f8 54 63 75 36 ea 30 5a 13
17 (88-8f): 2a 8e e9 da ad b2 52 94 74 69 70 19 c4 c8 36 f3
18 (90-97): bd 0f 6f b9 c7 42 79 fd ac 8f 1c cc 01 9f 45 3a
19 (98-9f): 71 2e f1 d7 33 a2 ae 2d 89 6a cb 63 ed 8d 83 10
20 (a0-a7): f5 87 f7 18 d6 7a 60 5c 2b 4a 19 0a ea 3f d1 5b
21 (a8-af): d5 6d ad 65 bd 52 d2 10 71 ca 4b e5 72 cd ae a7
22 (b0-b7): 40 24 19 4c 51 19 52 cc c2 70 63 c6 34 1c 97 14
23 (b8-bf): 74 ad 1e 30 89 9f 84 58 ff d5 84 41 a6 68 16 c8
24 (c0-c7): 24 c8 8a c5 36 42 e3 d4 f7 af 74 ac 89 ee 47 2e
25 (c8-cf): 1d 1d 7d 89 9c 21 d0 aa a9 01 ee b2 70 c7 c3 11
26 (d0-d7): 30 ef 8c f6 23 bf fb d0 bb 51 a9 f6 1d a7 d2 c7
27 (d8-df): f9 c0 15 08 c7 10 67 d1 42 13 27 22 c3 e3 94 66
28 (e0-e7): d4 13 19 2a f2 9d 4e cc 2a b3 df 95 c5 b6 91 34
29 (e8-ef): dc 15 d4 80 5b d8 ec 2e 49 d7 d8 45 0e 7d ba 09
30 (f0-f7): d8 68 75 f3 f9 92 8e 78 be 43 b9 28 a9 2e de c9
31 (f8-ff): 79 7d 6d 5b 23 7e 5e 5d 53 cf 01 ea 86 5f 8a 4b
```

#### Table SA5 — PS5 1.0, seed S (row chosen by N[0])

```
 0 (00-07): 7f ae 83 20 47 39 b6 5b 23 9b 5c a5 37 c4 df 59
 1 (08-0f): 2a b3 fd b2 32 86 3c e7 1a 96 14 9d b1 d9 90 72
 2 (10-17): 88 ac e4 14 77 23 04 9e 30 ec 3f 27 e7 c2 b1 76
 3 (18-1f): a1 ee 5d ea c0 b9 68 ee a2 61 b9 b4 69 12 09 90
 4 (20-27): ff 23 bb 18 93 56 ff 48 d8 d3 71 a1 c3 61 30 83
 5 (28-2f): 54 05 6b 8d 42 56 04 01 d8 0b e7 83 0a 66 b2 94
 6 (30-37): 52 17 28 5c e5 10 c7 77 03 ba 51 89 73 6a 28 68
 7 (38-3f): b1 67 78 79 4c 6e b1 97 b3 b7 7f 54 a7 02 55 35
 8 (40-47): e7 56 6b c3 3c ee 89 31 d5 f1 23 5c ec 45 3c 55
 9 (48-4f): 33 17 20 a0 76 17 23 3f 76 ac b4 cc 07 5a 62 22
10 (50-57): 58 96 15 c9 f8 19 7b a0 07 b3 01 c8 fc e0 b6 f4
11 (58-5f): 30 b6 68 87 50 06 98 54 51 2b 2e 57 15 01 1f 85
12 (60-67): ba fa 39 ec cf e8 12 88 30 83 a6 2a d2 08 d5 ae
13 (68-6f): fb 2f 13 83 ce 0a 24 cb 42 7a a6 26 6d 52 d6 9b
14 (70-77): ab ca 48 53 9e 31 05 5d 50 78 e5 0d 2d 87 7c 83
15 (78-7f): 3f bc 19 ae 90 1b ce 02 1d 75 d3 d1 6f d1 c2 f0
16 (80-87): 48 f0 b3 37 05 4d be 69 27 da 04 c2 33 a3 45 b1
17 (88-8f): 71 71 e0 f3 cc 8b a6 18 88 6d 1e 2f 3c 6b 69 89
18 (90-97): e6 c5 f9 00 ca 32 9f 20 87 d7 ea 15 18 bb e0 24
19 (98-9f): 45 0c e7 c2 1a bc cc ff 6d 3f 15 57 94 1c a2 25
20 (a0-a7): 61 a2 b1 ef 31 a8 a9 02 1a a2 89 f8 ec ee 97 f6
21 (a8-af): 9d 95 f3 c7 5d cb 12 08 2c 49 e1 d5 93 67 52 a3
22 (b0-b7): 9e e5 44 62 ee eb be a4 9a 95 3d b3 69 3f da 9a
23 (b8-bf): f3 e2 0b 72 55 13 8b 97 12 58 f4 4a 52 36 c6 42
24 (c0-c7): 6c 78 c9 8b 44 bc 85 80 93 ba 6c e3 d2 39 95 c6
25 (c8-cf): 58 14 c5 a2 d9 ef 2d 9d 97 f7 ec 55 f7 2e 4c 0f
26 (d0-d7): e8 b8 34 86 45 fc f4 61 93 4a 7f 2c 3f eb d1 ce
27 (d8-df): c3 d2 1c c1 0e 4a 44 f7 74 ce 00 69 43 99 bd b7
28 (e0-e7): 7d 2b 99 ce 22 3b 2d c9 6f 4d 38 87 45 20 c5 67
29 (e8-ef): 11 13 e6 e7 86 68 92 93 0a 71 a5 5b 95 01 ae 09
30 (f0-f7): 17 d5 d7 2f 9e 56 86 d1 98 9c 24 a2 82 84 ad ee
31 (f8-ff): 07 fa cf ea 1b e7 6d c1 f3 8a 0b 21 4e 66 47 a4
```

#### Table SB5 — PS5 1.0, key K (row chosen by N[7])

```
 0 (00-07): e1 34 17 1d f5 17 da e1 1b e6 0c 73 35 d4 6b 42
 1 (08-0f): f4 b6 93 72 ae 46 40 5d 26 30 98 f8 c7 be b7 2c
 2 (10-17): cf 79 70 90 c5 7a f3 b1 3d 59 08 59 e1 41 ae 65
 3 (18-1f): 1d 37 b5 a7 8b 19 8a 50 50 2d a9 89 4e 6e 7d bf
 4 (20-27): 29 89 b6 11 32 db 0d 75 58 e2 9a 1a 1b 08 66 2a
 5 (28-2f): 30 9b 97 be 9f 0c 1e 4e ff 3a e2 06 15 ba 57 9d
 6 (30-37): 49 42 db 52 4b bb d9 63 8f 6d 9d 3b d7 e3 49 bc
 7 (38-3f): dc 76 ac 59 e6 e3 56 81 1d 29 f9 65 48 c3 70 50
 8 (40-47): d4 88 bf 3a 7e 00 22 b2 8a 80 fe f9 75 1a d1 cc
 9 (48-4f): 19 07 60 62 dc 4b 99 64 95 ea f6 cc fc 97 e5 7f
10 (50-57): eb fc da f3 42 3a 43 b0 d2 24 fe 04 d1 31 47 77
11 (58-5f): 55 bc 0a 75 90 82 a2 18 2f 12 26 31 92 eb 47 38
12 (60-67): 6e 45 e0 99 83 80 74 02 e3 04 e6 7a 64 c9 08 8a
13 (68-6f): f0 99 34 26 a2 a5 c8 15 e9 91 6f d7 c1 c7 e6 c5
14 (70-77): 5d 2c 6b 55 bb 5b 44 d1 f8 36 9b 81 19 3a 47 18
15 (78-7f): d7 ae f2 b8 b1 c1 b7 d6 e8 9f 6a 68 31 7d be f3
16 (80-87): 9f f2 e2 37 41 09 86 52 3f ac a4 98 4e 42 6c 81
17 (88-8f): 64 31 6b fd f8 01 75 14 ac b5 18 2f ef d5 42 4d
18 (90-97): 2d 39 2c 11 24 22 0f ac 65 bf d6 da ef 82 00 fb
19 (98-9f): 62 2c 8d d8 b6 77 6e 1a 2a a5 34 da ad 75 64 88
20 (a0-a7): 6c b0 18 ce c8 ed 82 5d 4d 18 43 89 57 06 fd c2
21 (a8-af): 5c 82 23 2b 43 7f 55 ec f8 fb 23 ed 49 92 1d cf
22 (b0-b7): 3b 6a ad 42 07 1a 76 5e da 5a 23 44 1d 2d c9 ec
23 (b8-bf): 61 f2 9b 4f b4 12 33 4d 6a 86 e2 f0 d9 4d 45 7a
24 (c0-c7): 09 8a 95 ed d9 86 2a f2 c6 fd 72 2f 3d 18 9f 7f
25 (c8-cf): ab 50 48 85 71 0d 68 55 91 96 a2 87 51 da f8 4c
26 (d0-d7): b0 45 bd 9f 98 8d 5a 50 47 65 68 6f c3 08 78 4c
27 (d8-df): 90 c2 56 a9 62 03 d1 bd 77 54 70 6a 96 ce bd e0
28 (e0-e7): 57 cb f4 4d 2c 8f b8 2c ae 4e 31 4d ee b9 50 31
29 (e8-ef): 75 30 ff b1 fc ef 2e 05 08 28 3d 44 8a 4a 03 e3
30 (f0-f7): 54 69 13 d5 9b 68 12 5b 4a cf a2 b9 50 9f c0 cc
31 (f8-ff): 1b cd 10 d7 92 29 65 1e 02 8d 08 4e 68 d3 70 f7
```

---

## Appendix B — RP crypt during registration (reference for part 04)

Registration (part 04) uses the same cipher as sec. 4.3–4.4 (AES-128-CFB-128, IV = first 16
bytes of HMAC-SHA256 over seed ‖ 64-bit big-endian counter), but its key K and seed S are made
differently. Where the values k0, k1, the PIN and the seed are taken from or put into the
registration request is described in part 04.

- **Seed S:** 16 random bytes chosen by the client for each registration.
- **IV key:** H-OLD for PS4 8.0/9.0, H-PS4 for PS4 10.0, H-PS5 for PS5 (sec. 4.3).
- **PIN:** the 8-digit registration PIN as a 32-bit unsigned number, used as 4 big-endian bytes
  p0 p1 p2 p3.

**Old PS4 (8.0 / 9.0):**
- K = `3f 1c c4 b6 dc bb 3e cc 50 ba ed ef 97 34 c7 c9` with K[0] ^= p0, K[1] ^= p1,
  K[2] ^= p2, K[3] ^= p3.
- The 16-byte value sent in the request in place of S ("seed mask" M):
  M[i] = (S[i] − i − 0x29) ^ P2[i] (P2 from sec. 4.2).

**PS4 10.0 and PS5, PIN registration:** k0 and k1 are 0…31.
- K[i] = R0[i][k0] for i = 0…15 (table R0-PS4 or R0-PS5), then K[12] ^= p0, K[13] ^= p1,
  K[14] ^= p2, K[15] ^= p3.
- M[i] = ((S[i] ^ R1[i][k1]) + c + i) mod 256 with c = 0x29 for PS4 and c = 0xd3 (i.e. −0x2d)
  for PS5 (tables R1-PS4 / R1-PS5).

**PS4 10.0 and PS5, registration over the relay (PSN, part 05):** no PIN; the hole-punching
exchange supplies three 16-byte values D1, D2 and C.
- E = CFB-128 encryption of C with key D1, IV computed from seed D2 with counter 0 (IV key by
  target as above).
- K[i] = R0[i][k0] ^ E[i].
- M[i] = ((S[i] − i + c) mod 256) ^ R1[i][k1] with c = 0xd7 (i.e. −0x29) for PS4 and 0x2b for PS5.
- The inverse (recovering S from M, used when the console's value has to be read back):
  S[i] = ((M[i] ^ R1[i][k1]) + i − c) mod 256.

Check values (PIN registration), PIN = 12345678 (bytes `00 bc 61 4e`), k0 = 5, k1 = 0x11,
S = `0f 1e 2d 3c 4b 5a 69 78 87 96 a5 b4 c3 d2 e1 f0`:

```
PS4 10.0  K = 7d 68 9c 0e e5 bb 41 0b 7e 16 7d 24 00 fa ff c3
          M = 40 a8 f2 ef a1 13 0d 51 6c b7 60 be 27 b5 3c 32
PS5       K = 67 db d4 2a 8f f3 f3 80 26 73 f9 76 f9 22 43 4b
          M = c2 29 f8 7b 0a 1b 14 45 e7 76 c2 e2 3a df dc 2a
```

Table layout: each R table has 16 lines (i = 0…15) of 32 bytes (column k = 0…31, left to right);
the byte used is line i, column k.

#### Table R0-PS4 — registration key K, PS4 10.0

```
i= 0: be ce 5d f0 c1 7d b5 d0 cb 30 13 5d aa 56 23 fb c4 bc f1 8f 38 57 fb d4 d4 3f 26 38 b5 ce ed 6a
i= 1: 21 bc 38 d0 1e 68 cc 7b 45 d1 be 42 1a 08 aa 16 fd b0 c0 f4 da 35 e9 12 fd 21 07 48 34 c1 fc 9f
i= 2: 8c b6 cb 5d b2 9c 84 e0 1a fa a0 c7 eb 3a 93 b3 b3 f1 15 af 13 bd 21 ab ea 5b 80 50 6b 31 1d 7c
i= 3: 1d 40 ba 3c 56 0e e7 94 3a 5b a1 40 80 74 0a ad 28 cf 47 df 42 a6 69 e9 5e bb c0 c0 0e b2 c5 8a
i= 4: ee 08 03 d2 84 e5 91 00 1d 46 06 55 09 9d 39 9f d8 e7 fd ad 9e 93 97 c5 ea e7 a3 10 a7 f2 a2 93
i= 5: 7f 07 04 b4 ee bb bf 88 23 9c 6e a7 62 b1 4b 67 1e b8 3b 1f 64 93 5a 99 ec da fd 0c 6a b7 fe e4
i= 6: 12 76 32 65 b8 41 23 d1 17 09 9c 24 2d 5c 9d 12 79 de a1 ce 69 ac a4 bc 39 2f 57 38 84 61 2d 2a
i= 7: e8 04 f8 d5 9d 0b ff 7e 56 0c ec 87 0a 1e ab df 93 81 13 ee cf 32 02 5a bf b0 17 b7 ba b5 7f f0
i= 8: 01 7b e1 cb 39 7e 60 6d a4 75 6e 29 92 45 a6 4f 74 00 86 78 73 be fd 3e e0 d1 0c 6c 0b 49 09 83
i= 9: 6c 85 8a 1d cb 16 ce 81 7c 49 c9 2c 63 61 de e2 3f 98 b2 73 f0 9a ec 7b 7c f1 c9 e1 7f a5 19 8b
i=10: 4b e8 38 a4 34 7d f4 28 fe 0d 4d 11 57 0c 95 f1 af d7 34 80 f4 eb 9b 50 e6 6a 5d ea ce 0c 85 4e
i=11: c5 5b 93 44 c4 24 98 80 fc f7 72 9c 31 0b ee 89 67 b3 a2 69 4f b3 79 5a 14 02 70 ed 50 13 75 00
i=12: 6a f3 c6 05 1a 00 33 34 f5 ac 9e 04 db c2 00 b0 1b c4 f3 97 9d 7f be b8 23 8d 99 e7 cb 74 37 4c
i=13: 57 ec d2 69 49 46 75 74 af 51 40 a4 11 7b b3 2f 51 da e2 ef 33 73 12 18 25 39 03 09 ca 49 dc 8e
i=14: f1 94 d7 80 17 9e 87 46 c1 04 78 d1 e5 3d 25 88 ec 72 3a 28 41 68 14 6e 10 e4 c9 57 75 90 fe 22
i=15: 1a 63 8e f4 b8 8d 1a 36 fd b6 cb 72 c2 97 52 9f 91 72 1b 75 57 90 3b fd 5a 93 8c db fc a3 03 df
```

#### Table R0-PS5 — registration key K, PS5

```
i= 0: 24 d8 c2 69 4c 67 78 71 ee 31 bd 2b 83 b2 1d 61 c9 a7 8e ed 9a d3 6a 6b 5c c8 35 79 a7 24 e2 17
i= 1: 06 60 2e df f4 db 27 10 55 d9 ea 16 4e 90 0c bf 40 6f 54 a5 31 70 2d 5d 1e 27 df 37 40 ba 9d 5d
i= 2: ff e1 05 70 80 d4 b7 c2 96 7f 2f 42 eb 5a 08 de c1 b5 52 15 f6 b5 f2 d9 69 a5 c7 c4 7f 46 64 a4
i= 3: fd 46 98 a7 e1 2a 8e 6f af 65 42 28 b9 c2 6f 3e e3 e4 4e e4 5b 9d 60 10 b8 5a b0 7d 04 0c 4c 24
i= 4: 78 bd b8 ba db 8f e3 a0 75 6d 28 c2 33 5b 32 83 dd 51 b0 a5 8d 09 66 e4 5c b8 70 0b e6 82 14 b6
i= 5: d2 b0 c2 e0 55 f3 84 ad 9d 3a f8 77 f5 9d 9a a9 7d f1 45 1b 9b 55 25 d8 c1 ff 03 a5 48 0b 1b 19
i= 6: 0c bd e0 cd 48 f3 2c 99 19 d6 b8 bb d6 35 43 6f 71 e3 ef 3e 97 b8 e9 40 a8 47 e0 e0 01 16 9d a7
i= 7: e5 94 4b 1d d2 80 a2 7f f2 98 10 38 0d b8 56 c3 7a 4b 4c 85 ec 2f 23 89 af d5 ba 9a ad b0 61 9c
i= 8: 51 b4 6d 02 49 26 a4 34 84 20 35 30 23 0a 47 14 32 1a 96 0e e8 0f 96 96 d4 ba 68 3a 67 15 74 e0
i= 9: d6 60 4c 68 50 73 14 2f 11 59 ac c8 32 d1 db 4c 8a 94 75 33 61 d1 d4 fd aa 6a 61 68 d8 ae 31 4f
i=10: b8 07 7b 27 0f f9 0b b0 c2 64 b3 72 ea 8b 87 40 09 b4 82 b4 ad 76 f9 36 05 60 89 c8 20 eb a5 f1
i=11: 51 0b 27 a7 f0 76 84 96 eb b1 2e c2 85 28 bc 48 34 d4 01 8d 5b 25 54 e0 c4 4f a0 fa 99 8d 6d 7a
i=12: 64 b1 a9 5d a4 f9 f5 22 eb 9a f4 a8 7a 78 4b 7f e2 8b 04 50 43 7d 26 2d 19 98 38 6a 4f 2d 30 15
i=13: 2e 4f cd b9 ce 9e 8d 12 c9 fe 33 8b 84 ce 5b 40 e3 7f 72 6d 6c 8a 6a 9e 54 f1 e3 64 5d 6e 7f ac
i=14: 1a e7 f7 fa 00 22 ed 2b 23 fa 58 c5 eb 44 92 5d cc aa 82 9f 23 fb a6 c9 65 2a e0 79 12 65 2c 34
i=15: c5 23 16 c9 cc 05 30 f3 96 0b 90 67 1a a7 69 4c 3e 43 24 9d 4e 68 bd 8b 75 6e 9d 07 6f 1a 6a ba
```

#### Table R1-PS4 — registration seed mask, PS4 10.0

```
i= 0: c8 48 c2 b4 08 eb 88 f7 5f 4a 09 2d 59 1f 09 cd 1c 18 f4 7a 28 4a 96 6d b3 59 71 53 75 7e 82 50
i= 1: 57 e4 59 b3 f4 49 69 40 eb 17 c9 9f 17 97 71 ae c9 60 7f f8 2e 08 94 e8 43 ea da 6b e5 19 59 33
i= 2: 1f 89 ae 47 57 7b 1c 66 fe ff 95 bf 55 6b d5 93 27 ea a6 24 67 39 9f d3 0c aa 26 42 e7 66 4d d8
i= 3: 18 75 fe 44 03 46 ee 3e f8 3c b7 85 97 03 07 06 92 ff 59 17 27 0b 21 f7 05 7f 69 90 0e 38 91 c6
i= 4: 67 23 48 ba 08 8e 57 dd 91 d0 40 47 1c 5b bf c8 06 3f 96 a0 dc 00 e5 9a f5 3b 90 80 66 bb 0f 93
i= 5: 30 07 2b 56 45 a0 9a b1 b0 72 0c e4 dd 70 dd 7c 5a bf d4 e8 0d ca 37 e5 0e fd 12 ee 79 9a 5e a7
i= 6: 1e 31 af 1f 46 52 ca f3 42 00 3d f2 89 7c 1c 77 60 b7 4a 80 76 47 4b 3f b6 91 2f 9c c2 f1 ad 44
i= 7: 29 cb 32 8c 0a 8d 05 75 46 a1 f8 da 1a a7 20 de 32 59 fe 70 b5 87 f3 92 fd b4 df f4 a6 e3 7d 98
i= 8: 3b e1 ba 18 db 61 d1 c2 a6 ee 08 25 fa 86 8a 7b fe bc 02 bd 22 5f 25 30 51 5d 28 36 5a 29 8e 52
i= 9: eb 49 14 28 7f 0a c4 69 25 85 6b ec 33 33 57 ab 50 13 cf e7 73 78 23 06 4d 1f bb 38 11 b1 6e 6c
i=10: 6f cd 4b 0e 42 85 80 bb a8 39 68 c9 5b bb 46 58 86 88 57 88 5e ea 7c 37 df fd 02 39 45 89 2e f2
i=11: e4 f0 08 c0 b6 eb 9c 6e 7a 81 a3 26 46 fe e1 70 3c 3e 11 7a 32 ce 45 02 7d 32 cd 08 07 06 a3 a8
i=12: f7 34 fe ee 06 b0 14 d6 6b 2d 2e 01 af 77 11 ec 1f 31 38 17 9c d0 e0 c5 4d a4 d6 ad b9 e6 e1 e3
i=13: e2 9e 44 91 9a 5e 26 ca cc da 4d d7 78 6a 75 a6 19 ad cc 62 c7 b6 0d 14 b1 be eb cb 10 cf a9 ee
i=14: e2 42 08 35 8a 5c bc f1 49 fe 64 78 03 49 0c 85 f0 e4 77 26 d2 5e f5 c1 3b 3d 2d cc cf 2a ac ed
i=15: 88 52 74 6d bf b2 b9 f7 58 51 1c 50 f6 3d f2 c4 47 0a 21 30 47 81 2d e4 75 0d 8f 2d 22 b0 63 27
```

#### Table R1-PS5 — registration seed mask, PS5

```
i= 0: 79 4d 78 30 fe 10 52 4c a8 90 5b 9a 7e 5f d3 e1 13 e0 f1 0f a3 e7 bb 45 7f dc 8e d5 f1 04 5c 78
i= 1: 51 ef f8 65 59 03 39 84 37 ae 59 df 23 b6 60 34 e6 4b e2 f5 4c 13 c6 da f9 fd b3 65 84 d6 45 ec
i= 2: 2c 00 f2 ed dc cb 93 6e 61 46 e5 d6 01 94 ee 78 85 0e 68 5e b5 5b cd d3 63 41 fc 81 43 1c 6f 7c
i= 3: ba e8 bd 86 31 d5 70 7f b5 4a 90 3e 84 e1 71 e0 02 99 f4 71 e7 02 ed 36 af de 56 c2 90 e0 ae c2
i= 4: f9 af 53 c6 d8 62 16 32 27 fb 6e 9b 48 c6 ea ff 6f 78 02 22 98 2c 1f bf b0 8e a9 39 bc df 17 de
i= 5: d7 0e e1 7a 01 0e c3 87 fc aa e4 6b 0f 5b 0a f1 18 19 8a e5 2c 36 9b 40 30 99 24 94 48 d7 47 b2
i= 6: af 6b 8c 40 9e 4d 6d 34 07 c1 26 2f bb 14 f7 bc 36 52 bd 84 fe 4a 9a f4 8a db 34 89 aa f1 0d 94
i= 7: 0b 92 f4 1c e4 6c 79 2d 6e c0 19 0a d5 55 94 14 05 13 c2 62 23 b3 d4 26 c4 44 56 7a cd 1c ea d4
i= 8: 74 b9 36 40 9f 08 fb 49 62 05 92 98 ad 1d 9f 8a 76 8b d4 0f 21 40 76 b6 16 91 45 93 66 cc 12 ea
i= 9: 4d f4 09 e2 ac 33 d0 6f 43 51 07 3e d7 95 2c 1e 1f 0c 24 b3 0e 3a ef 95 f5 eb 77 dd 20 f2 35 98
i=10: f2 ae a9 66 e6 13 ef 5d 3a 2d 66 ed e2 1e e9 32 4a 40 bf 37 c6 70 29 d9 8c a1 61 4a 29 3d c7 55
i=11: 9c 94 9e c9 11 45 10 28 a7 27 d1 d3 d0 84 79 c7 a9 b0 f6 af 45 8c 3c d4 df 3b f7 0d a2 4f 13 97
i=12: 78 27 f0 48 c0 a5 ab 83 01 05 d0 12 d7 1e 12 3a 4e 98 77 ae ba b1 4e b5 3b 59 ca 6d a5 11 80 91
i=13: 9c 07 69 59 5a 53 70 7c 95 97 11 6d 66 8d a3 bd bb 2d b0 bf 9b 10 cb c7 0f 5b 7e 67 e2 b0 4b ba
i=14: 10 12 b9 bc 97 fd 48 e4 8a c1 0f a1 30 9d 56 20 24 1a 7d 5b a0 b4 be 9d 38 4f b4 56 a8 4d 13 7c
i=15: 44 e8 84 97 eb 78 2c 52 85 e4 a2 f6 f3 d9 71 9e ee b8 11 47 fb a9 1b c7 40 c6 e1 19 6d 50 a1 2a
```
