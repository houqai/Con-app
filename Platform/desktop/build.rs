use std::env;
use std::path::PathBuf;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    let os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let out = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR is not set"));
    let mut includes: Vec<PathBuf> = Vec::new();
    match os.as_str() {
        "linux" => {
            for library in ["libavcodec", "libavutil", "libswscale"] {
                let found = pkg_config::Config::new()
                    .probe(library)
                    .unwrap_or_else(|error| {
                        panic!("{library} (FFmpeg development files) not found: {error}")
                    });
                includes.extend(found.include_paths);
            }
            pkg_config::Config::new()
                .probe("libsecret-1")
                .unwrap_or_else(|error| panic!("libsecret-1 development files not found: {error}"));
        }
        "windows" => {
            for library in ["avcodec", "avutil", "swscale"] {
                println!("cargo:rustc-link-lib=dylib={library}");
            }
        }
        _ => {
            std::fs::write(out.join("ffmpeg.rs"), "").expect("failed to write ffmpeg.rs");
            return;
        }
    }
    let mut builder = bindgen::Builder::default()
        .header_contents(
            "con_ffmpeg.h",
            "#include <libavcodec/avcodec.h>\n#include <libavutil/hwcontext.h>\n#include <libswscale/swscale.h>\n",
        )
        .allowlist_function(
            "avcodec_(find_decoder|alloc_context3|open2|free_context|send_packet|receive_frame)\
             |av_packet_(alloc|free|unref)|av_new_packet|av_frame_(alloc|free|unref|move_ref|get_buffer)\
             |sws_(getContext|scale|freeContext)\
             |av_hwdevice_ctx_create|av_hwframe_transfer_data|av_buffer_(ref|unref)",
        )
        .allowlist_type("AVCodecID|AVPixelFormat|SwsFlags|AVHWDeviceType")
        .allowlist_var("AV_CODEC_FLAG_LOW_DELAY|FF_THREAD_SLICE|AV_FRAME_FLAG_CORRUPT|SWS_AREA")
        .default_enum_style(bindgen::EnumVariation::Consts)
        .prepend_enum_name(false)
        .layout_tests(false)
        .derive_debug(false)
        .derive_default(false)
        .generate_comments(false)
        .parse_callbacks(Box::new(bindgen::CargoCallbacks::new()));
    for include in &includes {
        builder = builder.clang_arg(format!("-I{}", include.display()));
    }
    builder
        .generate()
        .expect("failed to generate FFmpeg bindings")
        .write_to_file(out.join("ffmpeg.rs"))
        .expect("failed to write ffmpeg.rs");
}
