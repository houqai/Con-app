# Con's own stream engine: protocol description (clean room)

Con's stream engine is an independent work, written the clean-room way:

1. **Description (this folder).** Writers studied the protocol and described *the protocol and
   the required behaviour*: what
   goes on the wire, byte by byte; the order of the exchanges; keys and cryptography; timers; how
   losses are recovered. Facts and protocol values only.
2. **Implementation.** Implementers wrote the engine from this folder alone, without reading any
   other implementation.
3. **Check.** The engine was checked against the description on tests and live runs.

## Rules for the description

- No source code and no pseudocode that follows another implementation's code; no names of its
  functions, types, variables, files or constants; no copied comments. Prose, tables, byte layouts,
  formulas, state diagrams in words.
- Protocol values (port numbers, magic bytes, message ids, key tables, field numbers) are facts
  needed to talk to the console and are written as values.
- What is uncertain is marked **Uncertain**; what Con adds or changes relative to the reference
  is marked **Con**.

## Parts

| File | What |
|---|---|
| `01-session.md` | Session request over HTTP, its cryptography, the control channel |
| `02-transport.md` | The datagram transport: packets, chunks, acknowledgements, encryption, congestion control, the network test, the stream's protobuf messages |
| `03-media.md` | Video and audio streams, loss recovery (FEC), feedback (controller state), haptics and effects, statistics |
| `04-registration.md` | Finding consoles, registration with a PIN, launch parameters, key exchange |
| `QUESTIONS.md` | Open questions about the description and the interpretation the engine uses for each |
| `IMPLEMENTATION.md` | The engine (`Engine/`, Rust): modules, C interface, threads, capture formats, tests, open work |

The stream from a Sony cloud slot is in `02-transport.md` §2.3. Internet connections to a console (relay transport, hole punching) are not described yet; `01-session.md` §9 lists what is known of their differences.
