# SoleCloud

Swift module for PlayStation cloud sessions: sign-in cookies, session creation, datacenters, allocation and licences. Sources in `Sources/SoleCloud`; it depends only on Foundation and `SoleCore`. Authorship of the original protocol materials is stated in THIRD-PARTY-NOTICES.

## What is implemented

| Component | Capabilities |
| --- | --- |
| SonySSO | Selection of secure Sony cookies, expiry check and conflicting accounts |
| CloudSessionService | Configuration, session creation, code exchange, datacenter request, state reset |
| CloudProtocol | Authorization URL, strict callback/state check, limiting provider errors |
| CloudDatacenter | `POST /datacenters` with requestGameSpecification (GET returns HTTP 405), an array or a wrapper object, selection: manual → lowest ping → Sony's order |
| CloudNetworkProbe (SoleEngine) | Senkusha UDP test for the cloud: the session key in the session key field of the BIG message, without the Remote Play version request, BIG in parts under MTU 576, RTT and MTU; all datacenters in parallel, 15 s timeout |
| selectDatacenter / allocate | `POST /datacenters/select` with a `pingResults` string for each datacenter (the selected one first, only with measured latency) and `POST /allocate` with a network estimate; parsing of `launchSlot` or the queue |
| CloudPingPolicy | With Distant servers on, latency of the selected datacenter above 80 ms is replaced with 75 ms in select and allocate; with it off, a datacenter above 80 ms stops the start with `TooFar`. The other strings and the interface show the measured values |
| CloudDatacenterName | City and country by datacenter code, a site letter when there are several in one city; an unknown code is shown as is |
| CloudEntitlementService | Read-only Sony Commerce OAuth and existing internal_entitlements, exact productId, active licence, preference for license_type=4 |
| CloudAllocation | launchSlot: IP/port, 16-byte handshakeKey (hidden in description), sessionId, launchSpecification, PSN wrapper from privateIp; queue with a limit of min(estimate × 2, 900 s) |

All components are covered by unit tests with simulated HTTP responses and have been tested against Sony's servers.

## Datacenter selection and allocation

Selection uses `POST /datacenters/select` with `pingResults`, `dataCenter` and the `requestGameSpecification` already accepted by the server. Sony accepts a selection without measured latency (200), but then rejects allocate with 403 / 002.2005 "invalid session key". Such a selection is therefore not sent: if no datacenter answered the UDP test, preparation stops with a clear error. Sony's server checks the latency limit (80 ms) against the values passed and rejects a selection above it with 400 / 002.0019. For the selected datacenter, a latency above the 80 ms limit is reported as 75 ms (`CloudPingPolicy`). This works around a service restriction and is not a measurement.

The allocate response: the address and ports are in `launchSlot`, while `handshakeKey`, `sessionId` and `launchSpecification` are next to it, at the top level; `dataMigration: true` means waiting for save data migration and is polled like a queue. Allocate passes the port from the select response (with the fallback port of the selected datacenter), the real preparation timings and the bitrate from the settings. `diagnostics/cloud-response.json` in the cache folder (`~/Library/Caches/Sole` on macOS) stores only allowed field paths, numeric codes and categories; the raw response, tokens and keys are not stored.

ICMP ping is not used in preparation: Sony's datacenters do not answer it, and the stream goes over UDP. `diagnostics/cloud-probe.json` stores the stage and result of the test for each datacenter, `cloud-key-structure.json` the time of each step. The allocated slot is kept only in memory. Without a Takion client the server frees the slot on its own timeout; the release endpoint is not documented.

## Wire details

Control packet: type at offset 0; tag 1; GMAC 5; key position 9; chunk type 13; flags 14; length 15; payload 17. Chunk length includes the four bytes of the chunk header. INIT takes 33 bytes without the PSN wrapper, INIT_ACK — 65, COOKIE — 49, COOKIE_ACK — 17.

Video v12: the packed field at offset 5 contains the unit index in the upper 11 bits, total minus one in the next 11, FEC count in the lower 10. Checking the packet structure does not replace cryptographic authentication.

## Stream from the slot

The stream is driven by the engine (`Engine/`, through `RemotePlaySession(cloud:)` in SoleEngine). A cloud slot differs from a console only a little; the protocol details are in [docs/protocol/02-transport.md](docs/protocol/02-transport.md) (§2.3 "Cloud slot").

1. No registration, session request or ctrl connection: the address, port, handshake key, session id and launch specification are taken from the allocate response.
2. Takion version 12 for the PS5 cloud, 9 for the PS4 and PS3 clouds. If the slot has a wrapper type, every outgoing datagram is preceded by four bytes `00 00 00 P`; GMAC is computed without them.
3. The initial sequence number of the server's data is taken from INIT_ACK, not from the tag.
4. BIG carries the slot's launch specification as is; the message chunks are computed with an overhead of 28 + 30/29 bytes.
5. Video arrives with codec 3 and is handled as the requested codec.
6. Sound: one Opus frame per packet; each frame arrives three times with the same bytes, in three neighbouring packet groups. The first packet with a newer frame index is taken, the rest serve as a reserve against loss.
7. The UDP receive buffer is 4 MB: with 102 KB, frames are lost while the decoder is starting.
8. Gamepad feedback (type marker 0x02) is packed like a console's, not like sound: the packet holds a frame with the packet number and copies of the two previous ones. The receiver splits the packet into frames and hands each one over once, in order.

Video: HEVC, one slice per frame, the picture number is four bits (a cycle of 16 frames). A normal frame is built on the previous one and lists up to two long-term pictures that the server keeps in reserve. After a loss report the server sends frames built on one of them and states how many cycles back it lies. The report reaches the server within the ping time, so with a latency of about 100 ms the gap is 9–12 frames; a decoder without these frames does not notice the wrap of the cycle. How Con handles this is in [VideoRecovery.md](VideoRecovery.md) (`PictureOrderBridge`, shared code, SoleCore). After a few frames the server returns to normal frames by itself.

## Licence selection

- The exact productId is looked up first, on all pages of the licence list.
- If there is no exact match, a valid full PS5 licence with the same Sony conceptId in the record or `game_meta` is accepted. PS4, DLC, invalid licences and a match by title only are excluded. If Sony does not return a conceptId, this fallback does not apply. The error message then describes a matching failure and does not claim the game is missing from the library.
- Cross-generation purchases: when a valid licence has a PS5 `product_id` (PPSA) and a PS4 `id` (CUSA), the PS5 product owned by the account is launched. Sending the PS4 id to the PS5 cloud makes Sony reply `noGameForEntitlementId`.
- A PS4-only licence without a PS5 product is not sent to the PS5 cloud.
- Diagnostics of the last selected licence store only the ID, licence attributes and a few `game_meta` fields in `diagnostics/last-license.json`; tokens and the full library are not written there.

## PS4 cloud (PS Plus PC)

A separate backend (`PSPlusPC`) adds Sony's PS4 cloud titles to the catalog after sign-in. Sessions use kratos allocation, Takion 9 and UDP wrapper 1; the resolution is capped at 1080p (H.264). PS4 packed Opus source and redundancy units are handled separately from PS5 cloud audio. The cloud session target stays PS4 for negotiation compatibility, so the Takion version and audio framing follow the PS5 flag of the connection, not the target.

A missing streaming licence is activated only when Sony confirms a single matching SKU with an explicit zero total; paid or indeterminate prices are rejected.

Screenshots come from `product.promomedia.materials.urls` with type 26 and from `mediaList.screenshots` (`SCREENSHOT` / typeId 4), with the same trusted-URL checks and a cap of six images. Library tabs, including recent and favourites, filter by backend.

The public all-ps5-list can mark a game as not streamable although its exact PS5 Store product lists `STREAMING_SUPPORTED` for PS5. Owned, recent and searched PS5 candidates are therefore checked lazily against the exact product on the concept's Store page before they are added. A PS4 licence is never substituted for a PS5 licence.

## PS3 cloud

A separate PS3 catalog source resolves legacy NP/BL/BC product IDs and matching streaming entitlements. Sessions use konan allocation, the PS3 client OAuth scope without duid, PC Takion 9 transport and a 720p cap.

## Linking

In another Swift package add a local dependency on the Con directory and `.product(name: "SoleCloud", package: "Con")` to the target's dependencies. Use `import SoleCloud`.

Check: `swift test --filter SoleCloudTests`. Full project check: `swift test`.
