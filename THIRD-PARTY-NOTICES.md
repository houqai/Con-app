# Third-party notices

## psn-api (MIT)

Reference: https://github.com/achievements-app/psn-api

PSNAuthorization.swift follows the PSN endpoints, OAuth parameters and token exchange documented by this project.

MIT License

Copyright (c) 2021 Wes Copeland.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

## Con engine (Engine/) and what it is built with

Con's stream engine (Engine/, Rust) is Con's own code, written from the protocol description in docs/protocol.

The engine library that every build of Con links statically contains the following third-party code.

### libopus 1.6.1 (BSD-3-Clause), through opusic-sys 0.7.5 (BSD-3-Clause)

Audio decoding and encoding. https://opus-codec.org, https://github.com/DoumanAsh/opusic-sys (bindings by Douman).

Copyright 2001-2023 Xiph.Org, Skype Limited, Octasic, Jean-Marc Valin, Timothy B. Terriberry, CSIRO, Gregory Maxwell, Mark Borgerding, Erik de Castro Lopo, Mozilla, Amazon

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

- Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
- Neither the name of Internet Society, IETF or IETF Trust, nor the names of specific contributors, may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

The same BSD-3-Clause terms apply to opusic-sys (Copyright Douman).

### subtle 2.6.1 (BSD-3-Clause)

Constant-time comparison. https://github.com/dalek-cryptography/subtle

Copyright (c) 2016-2017 Isis Agora Lovecruft, Henry de Valence. All rights reserved.
Copyright (c) 2016-2024 Isis Agora Lovecruft. All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

### generic-array 0.14.7 (MIT)

https://github.com/fizyk20/generic-array. Copyright (c) 2015 Bartłomiej Kamiński. Under the MIT License below.

### Rust crates under "MIT OR Apache-2.0"

Each of these crates is offered under the MIT License or the Apache License 2.0 (zerocopy also under BSD-2-Clause), at the user's choice; Con uses them under the MIT License below. The Rust standard library (The Rust Project Developers, https://github.com/rust-lang/rust, MIT OR Apache-2.0) is linked into the engine as well.

| Crate | Copyright holders | Source |
|---|---|---|
| aead 0.5.2 | RustCrypto Developers; MobileCoin, LLC | https://github.com/RustCrypto/traits |
| aes 0.8.4 | Artyom Pavlov; RustCrypto Developers | https://github.com/RustCrypto/block-ciphers |
| aes-gcm 0.10.3 | RustCrypto Developers | https://github.com/RustCrypto/AEADs |
| base16ct 0.2.0 | Steve Thomas; RustCrypto Developers | https://github.com/RustCrypto/formats |
| base64 0.22.1 | Alice Maz; Marshall Pierce | https://github.com/marshallpierce/rust-base64 |
| block-buffer 0.10.4 | RustCrypto Developers | https://github.com/RustCrypto/utils |
| cfb-mode 0.8.2 | Artyom Pavlov; RustCrypto Developers | https://github.com/RustCrypto/block-modes |
| cfg-if 1.0.5 | Alex Crichton | https://github.com/rust-lang/cfg-if |
| cipher 0.4.4 | RustCrypto Developers | https://github.com/RustCrypto/traits |
| const-oid 0.9.6 | RustCrypto Developers | https://github.com/RustCrypto/formats |
| cpufeatures 0.2.17 | RustCrypto Developers | https://github.com/RustCrypto/utils |
| crypto-bigint 0.5.5 | RustCrypto Developers | https://github.com/RustCrypto/crypto-bigint |
| crypto-common 0.1.7 | RustCrypto Developers | https://github.com/RustCrypto/traits |
| ctr 0.9.2 | Artyom Pavlov; RustCrypto Developers | https://github.com/RustCrypto/block-modes |
| der 0.7.10 | RustCrypto Developers | https://github.com/RustCrypto/formats |
| digest 0.10.7 | Artyom Pavlov; RustCrypto Developers | https://github.com/RustCrypto/traits |
| elliptic-curve 0.13.8 | RustCrypto Developers | https://github.com/RustCrypto/traits |
| ff 0.13.1 | Sean Bowe, Jack Grigg | https://github.com/zkcrypto/ff |
| getrandom 0.2.17 | The rust-random Project Developers; The Rust Project Developers | https://github.com/rust-random/getrandom |
| ghash 0.5.1 | RustCrypto Developers | https://github.com/RustCrypto/universal-hashes |
| group 0.13.0 | Sean Bowe, Jack Grigg | https://github.com/zkcrypto/group |
| hkdf 0.12.4 | Vlad Filippov; RustCrypto Developers | https://github.com/RustCrypto/KDFs |
| hmac 0.12.1 | Artyom Pavlov; RustCrypto Developers | https://github.com/RustCrypto/MACs |
| inout 0.1.4 | Artyom Pavlov; RustCrypto Developers | https://github.com/RustCrypto/utils |
| k256 0.13.4 | RustCrypto Developers | https://github.com/RustCrypto/elliptic-curves |
| libc 0.2.190 | The Rust Project Developers | https://github.com/rust-lang/libc |
| opaque-debug 0.3.1 | RustCrypto Developers | https://github.com/RustCrypto/utils |
| opus 0.4.0 | Tad Hardesty | https://github.com/SpaceManiac/opus-rs |
| polyval 0.6.2 | RustCrypto Developers | https://github.com/RustCrypto/universal-hashes |
| ppv-lite86 0.2.21 | The CryptoCorrosion Contributors | https://github.com/cryptocorrosion/cryptocorrosion |
| rand 0.8.8 | Developers of the Rand project; The Rust Project Developers | https://github.com/rust-random/rand |
| rand_chacha 0.3.1 | Developers of the Rand project; The Rust Project Developers; The CryptoCorrosion Contributors | https://github.com/rust-random/rand |
| rand_core 0.6.4 | Developers of the Rand project; The Rust Project Developers | https://github.com/rust-random/rand |
| sec1 0.7.3 | RustCrypto Developers | https://github.com/RustCrypto/formats |
| sha2 0.10.9 | RustCrypto Developers; Graydon Hoare; Mozilla Foundation | https://github.com/RustCrypto/hashes |
| socket2 0.6.5 | Alex Crichton, Thomas de Zeeuw | https://github.com/rust-lang/socket2 |
| thiserror 2.0.21 | David Tolnay | https://github.com/dtolnay/thiserror |
| typenum 1.20.1 | Paho Lurie-Gregg | https://github.com/paholg/typenum |
| universal-hash 0.5.1 | RustCrypto Developers | https://github.com/RustCrypto/traits |
| windows-link 0.2.1 | Microsoft Corporation (Windows only) | https://github.com/microsoft/windows-rs |
| windows-sys 0.61.2 | Microsoft Corporation (Windows only) | https://github.com/microsoft/windows-rs |
| zerocopy 0.8.62 | The Fuchsia Authors | https://github.com/google/zerocopy |
| zeroize 1.9.1 | RustCrypto Developers | https://github.com/RustCrypto/utils |

### The MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Build tools that do not end up in the engine (cc, cmake, find-msvc-tools, shlex, proc-macro2, quote, syn, unicode-ident, version_check, thiserror-impl) are not listed.

## Con on Linux and Windows: the desktop library and the sign-in window (Platform/desktop, Platform/login)

Con's own Rust code for the app on Linux and Windows (keyring access, FFmpeg frame conversion, SDL texture upload) and for its sign-in window con-login is linked with these crates, besides the Rust standard library and those of the engine above (libc, windows-link, windows-sys). The MIT License text is the one above; crates offered under "MIT OR Apache-2.0" (memchr: "Unlicense OR MIT") are used under it. The libraries they bind to — GTK 4, WebKitGTK 6, GLib, libsoup, Cairo, Pango and libsecret on Linux, SDL 2 and FFmpeg on both — are the system's (Linux), except in the Flatpak, which carries its own FFmpeg (LGPL 2.1 or later; its licence in /app/share/licenses/ffmpeg), or ship beside the program with their own licences (Windows, the folder licenses/, the GTK stack's in licenses/gtk).

| Crate | Licence | Copyright holders | Source |
|---|---|---|---|
| sdl2-sys 0.38.0 | MIT AND Zlib | Tony Aldridge; Cobrand; the rust-sdl2 contributors | https://github.com/rust-sdl2/rust-sdl2 |
| gtk4, gdk4, gsk4 (and -sys) 0.11.5; glib, gio, glib-sys, gio-sys, gobject-sys, cairo-rs, cairo-sys-rs, pango, pango-sys, graphene-rs, graphene-sys, gdk-pixbuf, gdk-pixbuf-sys 0.22 (Linux only) | MIT | The gtk-rs Project Developers | https://github.com/gtk-rs/gtk4-rs, https://github.com/gtk-rs/gtk-rs-core |
| webkit6 0.6.1, webkit6-sys 0.6.0, javascriptcore6 (and -sys) 0.6.0 (Linux only) | MIT | Bilal Elmoussaoui | https://gitlab.gnome.org/World/Rust/webkit6-rs |
| soup3, soup3-sys 0.9.0 (Linux only) | MIT | The Gtk-rs Project Developers | https://gitlab.gnome.org/World/Rust/soup3-rs |
| field-offset 0.3.6, memoffset 0.9.1, slab 0.4.12, smallvec 1.16.3, bitflags 2.13.2, hashbrown 0.17.1, indexmap 2.14.2, equivalent 1.0.3, memchr 2.8.3, pin-project-lite 0.2.17, futures-channel, futures-core, futures-executor, futures-io, futures-task, futures-util 0.3.34 (Linux only) | MIT, or MIT OR Apache-2.0 | Diggory Blake; Gilad Naaman; Carl Lerche; The Servo Project Developers; The Rust Project Developers; Andrew Gallant; the indexmap, pin-project-lite and futures-rs contributors | crates.io |
| webview2-com 0.39.1, webview2-com-sys 0.39.1 (Windows only) | MIT | Bill Avery and the webview2-rs contributors | https://github.com/wravery/webview2-rs |
| windows, windows-core 0.62.2; windows-collections, windows-future, windows-numerics, windows-result, windows-strings, windows-threading (Windows only) | MIT OR Apache-2.0 | Microsoft Corporation | https://github.com/microsoft/windows-rs |

The upscaler on Windows uses Direct3D 11 through the windows crate 0.62 (Microsoft, MIT OR Apache-2.0, listed above) and compiles its shaders with the system's d3dcompiler_47.dll. Its algorithms are listed below ("Upscaler": FSR 1, NIS, Anime4K).

"Frame generation" on Windows talks to AMD's AMF runtime (amfrt64.dll, part of AMD's graphics driver, not shipped with Con). The definitions of AMF's C interface in Platform/desktop/src/frc.rs — the order of its tables of functions, its constants and identifiers — follow the headers of the AMF SDK (https://github.com/GPUOpen-LibrariesAndSDKs/AMF, amf/public/include), under the MIT License (the text above): Copyright (c) 2016 Advanced Micro Devices, Inc. All rights reserved.

con-login.exe holds Microsoft's WebView2 loader (WebView2LoaderStatic.lib, as webview2-com-sys carries it), under the licence of Microsoft's WebView2 SDK: licenses/WebView2.txt and licenses/WebView2-NOTICE.txt in the Windows folder.

Build tools that do not end up in a program (bindgen, pkg-config, the crates' procedural macros and what they use) are not listed.

## "Upscaler": FSR 1, NIS, Anime4K (macOS, Windows)

Each under the MIT License (the text above), with its copyright:

- **AMD FidelityFX Super Resolution 1** (EASU and RCAS), ported from ffx_fsr1.h of https://github.com/GPUOpen-Effects/FidelityFX-FSR into Sources/SoleMedia/Upscaler.swift (Metal) and Platform/desktop/src/upscale.rs (HLSL): Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved.
- **NVIDIA Image Scaling** (Windows): its shader NIS_Scaler.h unmodified (Platform/desktop/shaders/NIS_Scaler.hlsli), its filter coefficients from NIS_Config.h (Platform/desktop/src/nis_coefficients.rs), of https://github.com/NVIDIAGameWorks/NVIDIAImageScaling: Copyright (c) 2022 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
- **Anime4K** v4.0, the network Anime4K_3DGraphics_Upscale_x2_US, its weights turned into Sources/SoleMedia/Anime4KShader.swift (Metal) and Platform/desktop/shaders/anime4k.hlsl by Tools/Upscalers/anime4k.py, of https://github.com/bloc97/Anime4K: Copyright (c) 2019-2021 bloc97. All rights reserved.

## Con on Android: native layer (Platform/android, Platform/android-check)

Con's own Rust code for the app on Android (the JNI bridge to its Java side, the system's video decoder and sound output) is linked with these crates, besides the Rust standard library and those of the engine above (libc, cfg-if). The MIT License text is the one above; crates offered under "MIT OR Apache-2.0" (memchr: "Unlicense OR MIT") are used under it. The libraries they bind to (libandroid, libmediandk, libaaudio) are Android's own.

| Crate | Licence | Copyright holders | Source |
|---|---|---|---|
| jni 0.21.1 | MIT OR Apache-2.0 | Josh Chase and the jni-rs contributors | https://github.com/jni-rs/jni-rs |
| jni-sys 0.3.1, 0.4.1 | MIT OR Apache-2.0 | Steven Fackler; Robert Bragg | https://github.com/jni-rs/jni-sys |
| ndk-sys 0.6.0 | MIT OR Apache-2.0 | The Rust Windowing contributors | https://github.com/rust-mobile/ndk |
| cesu8 1.1.0 | MIT OR Apache-2.0 | Eric Kidd | https://github.com/emk/cesu8-rs |
| combine 4.6.9 | MIT | Markus Westerlind | https://github.com/Marwes/combine |
| bytes 1.12.1 | MIT | Carl Lerche; Sean McArthur | https://github.com/tokio-rs/bytes |
| memchr 2.8.3 | Unlicense OR MIT | Andrew Gallant | https://github.com/BurntSushi/memchr |
| log 0.4.34 | MIT OR Apache-2.0 | The Rust Project Developers | https://github.com/rust-lang/log |
| thiserror 1.0.69 | MIT OR Apache-2.0 | David Tolnay | https://github.com/dtolnay/thiserror |

Build tools that do not end up in the app (walkdir, same-file, jni-sys-macros, thiserror-impl and what procedural macros use) are not listed.

## Libraries that ship beside Con (Windows and Android)

These are not part of Con's own code: they are carried with it as separate libraries, each under its own licence. The texts are in the folder `licenses` of the Windows download and in `assets/licenses` of the Android app. On macOS Con ships no third-party libraries: the engine (with libopus, above) is linked into the program, and everything else is macOS itself.

| What | Where | Licence |
|---|---|---|
| Swift runtime and standard library; Swift Foundation (FoundationEssentials, FoundationInternationalization, FoundationNetworking, FoundationXML); libdispatch and BlocksRuntime — the Swift project (swiftlang) | Windows, Android | Apache License 2.0 with the Runtime Library Exception (`Swift.txt`, `Swift-Foundation.txt`) |
| ICU, as `_FoundationICU` — Unicode, Inc. and others | Windows, Android | Unicode License V3 (`ICU.txt`) |
| SDL 2.32.10 | Windows | zlib (`SDL2.txt`) |
| FFmpeg 8.1.3, LGPL build: avcodec, avutil, swresample, swscale | Windows | LGPL 2.1 or later (`FFmpeg.txt`); source: https://github.com/BtbN/FFmpeg-Builds/releases/tag/autobuild-2026-10-07-13-07 |
| Cairo, Pango, GLib (with GObject, GIO, GModule), HarfBuzz, FreeType, Fontconfig, FriBidi, pixman, libpng, Expat, PCRE2, libffi, zlib, libintl (gettext), win-iconv — gvsbuild 2026.8.0 | Windows | each its own (LGPL 2.1 or later, MPL 1.1, MIT, the FreeType License, the libpng licence, BSD, zlib), texts in `gtk/`; source: https://github.com/wingtk/gvsbuild/releases/tag/2026.8.0 |
| Microsoft Edge WebView2 loader, in con-login.exe | Windows | `WebView2.txt`, `WebView2-NOTICE.txt` |
| Microsoft Visual C++ runtime | Windows | Microsoft Visual C++ Redistributable terms |
| LLVM libc++ (`libc++_shared.so`) | Android | Apache License 2.0 with LLVM Exceptions |
| Inter 4.1 font — The Inter Project Authors | Windows | SIL Open Font License 1.1 (`Inter.txt`) |
