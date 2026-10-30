#!/usr/bin/env python3
import re
import sys

source = open(sys.argv[1]).read()

def table(name):
    found = re.search(r"constexpr float " + name + r"\[kPhaseCount\]\[kFilterSize\] = \{(.*?)\};", source, re.S)
    rows = re.findall(r"\{([^{}]*)\}", found.group(1))
    values = [[float(v.strip().rstrip("f")) for v in row.split(",") if v.strip()] for row in rows]
    assert len(values) == 64 and all(len(row) == 8 for row in values), name
    return values

out = ["//! The filter coefficients of NVIDIA Image Scaling (NIS_Config.h of NVIDIAGameWorks/NVIDIAImageScaling,",
       "//! MIT, Copyright (c) 2022 NVIDIA CORPORATION & AFFILIATES): 64 phases of 8 taps, for the scaler and",
       "//! for its sharpening. Made from that file by Tools/Upscalers/nis_coefficients.py.", "",
       "#![allow(clippy::excessive_precision)]", ""]
for name, values in (("SCALER", table("coef_scale")), ("USM", table("coef_usm"))):
    out.append(f"pub const {name}: [[f32; 8]; 64] = [")
    out.extend("    [" + ", ".join(repr(v) for v in row) + "]," for row in values)
    out += ["];", ""]
open(sys.argv[2], "w").write("\n".join(out))
