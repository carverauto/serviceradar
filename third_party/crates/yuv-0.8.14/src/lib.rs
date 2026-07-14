/*
 * Copyright (c) Radzivon Bartoshyk, 10/2024. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 *
 * 1.  Redistributions of source code must retain the above copyright notice, this
 * list of conditions and the following disclaimer.
 *
 * 2.  Redistributions in binary form must reproduce the above copyright notice,
 * this list of conditions and the following disclaimer in the documentation
 * and/or other materials provided with the distribution.
 *
 * 3.  Neither the name of the copyright holder nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
#![allow(
    clippy::too_many_arguments,
    clippy::type_complexity,
    clippy::missing_transmute_annotations,
    unused_features
)]
#![allow(clippy::manual_clamp)]
#![cfg_attr(
    all(
        feature = "nightly_avx512",
        any(target_arch = "x86", target_arch = "x86_64")
    ),
    feature(cfg_version)
)]
#![allow(stable_features)]
#![cfg_attr(
    all(
        feature = "nightly_avx512",
        any(target_arch = "x86", target_arch = "x86_64")
    ),
    feature(avx512_target_feature)
)]
#![cfg_attr(
    all(
        feature = "nightly_avx512",
        any(target_arch = "x86", target_arch = "x86_64")
    ),
    feature(x86_amx_intrinsics)
)]
#![cfg_attr(
    all(
        feature = "nightly_avx512",
        any(target_arch = "x86", target_arch = "x86_64")
    ),
    feature(stdarch_x86_avx512)
)]
#![cfg_attr(feature = "nightly_f16", feature(f16))]
#![cfg_attr(
    all(
        feature = "nightly_i8mm",
        all(target_arch = "aarch64", target_feature = "neon")
    ),
    feature(stdarch_neon_i8mm)
)]
#![cfg_attr(docsrs, feature(doc_cfg))]

mod ar30_rgb;
#[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "avx"))]
mod avx2;
#[cfg(all(
    any(target_arch = "x86", target_arch = "x86_64"),
    feature = "nightly_avx512"
))]
mod avx512bw;
mod ayuv_to_rgb;
mod built_coefficients;
#[cfg(feature = "nightly_f16")]
#[cfg_attr(docsrs, doc(cfg(feature = "nightly_f16")))]
mod f16_ar30;
#[cfg(feature = "nightly_f16")]
#[cfg_attr(docsrs, doc(cfg(feature = "nightly_f16")))]
mod f16_converter;
mod from_identity;
mod from_identity_alpha;
#[cfg(feature = "nightly_f16")]
#[cfg_attr(docsrs, doc(cfg(feature = "nightly_f16")))]
mod from_identity_alpha_f16;
#[cfg(feature = "nightly_f16")]
#[cfg_attr(docsrs, doc(cfg(feature = "nightly_f16")))]
mod from_identity_f16;
#[cfg(feature = "geometry")]
#[cfg_attr(docsrs, doc(cfg(feature = "geometry")))]
mod geometry;
mod images;
mod internals;
#[cfg(feature = "geometry")]
#[cfg_attr(docsrs, doc(cfg(feature = "geometry")))]
mod mirroring;
#[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
mod neon;
mod numerics;
#[cfg(feature = "rdp")]
#[cfg_attr(docsrs, doc(cfg(feature = "rdp")))]
mod rdp;
mod rgb16_to_yuv_p16;
mod rgb_ar30;
mod rgb_to_nv_p16;
mod rgb_to_y;
mod rgb_to_ycgco;
#[cfg(feature = "ycgco_r_type")]
#[cfg_attr(docsrs, doc(cfg(feature = "ycgco_r_type")))]
mod rgb_to_ycgco_r;
mod rgba_to_nv;
mod rgba_to_yuv;
mod sharpyuv;
mod shuffle;
#[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "sse"))]
mod sse;
mod to_identity;
#[cfg(all(target_arch = "wasm32", target_feature = "simd128"))]
mod wasm32;
mod y_p16_to_rgb16;
mod y_p16_with_alpha_to_rgb16;
mod y_to_rgb;
mod y_with_alpha_to_rgb;
#[cfg(feature = "ycgco_r_type")]
#[cfg_attr(docsrs, doc(cfg(feature = "ycgco_r_type")))]
mod ycgco_re_to_rgb;
#[cfg(feature = "ycgco_r_type")]
#[cfg_attr(docsrs, doc(cfg(feature = "ycgco_r_type")))]
mod ycgco_re_to_rgb_alpha;
mod ycgco_to_rgb;
mod ycgco_to_rgb_alpha;
mod ycgcor_support;
mod yuv_error;
mod yuv_nv_p10_to_ar30;
mod yuv_nv_p10_to_rgb;
mod yuv_nv_p16_to_rgb16;
mod yuv_nv_to_rgba;
mod yuv_p10_rgba;
mod yuv_p16_ar30;
mod yuv_p16_rgba16_alpha;
mod yuv_p16_rgba_alpha;
#[cfg(feature = "nightly_f16")]
#[cfg_attr(docsrs, doc(cfg(feature = "nightly_f16")))]
mod yuv_p16_rgba_f16;
mod yuv_p16_rgba_p16;
mod yuv_p16_to_rgba16_bilinear;
mod yuv_support;
mod yuv_to_rgba;
mod yuv_to_rgba_alpha;
mod yuv_to_rgba_bilinear;
mod yuv_to_yuy2;
mod yuv_to_yuy2_p16;
#[cfg(feature = "nightly_f16")]
#[cfg_attr(docsrs, doc(cfg(feature = "nightly_f16")))]
mod yuva_p16_rgba_f16;
mod yuy2_to_rgb;
mod yuy2_to_rgb_p16;
mod yuy2_to_yuv;
mod yuy2_to_yuv_p16;

pub use yuv_support::{
    Rgb30ByteOrder, YuvBytesPacking, YuvChromaSubsampling, YuvConversionMode, YuvEndianness,
    YuvRange, YuvStandardMatrix,
};

pub use yuv_nv_p10_to_rgb::{
    p010_to_bgr, p010_to_bgra, p010_to_rgb, p010_to_rgba, p210_to_bgr, p210_to_bgra, p210_to_rgb,
    p210_to_rgba, p410_to_bgr, p410_to_bgra, p410_to_rgb, p410_to_rgba,
};

pub use yuv_nv_p16_to_rgb16::{
    p010_to_rgb10, p010_to_rgba10, p012_to_rgb12, p012_to_rgba12, p210_to_rgb10, p210_to_rgba10,
    p212_to_rgb12, p212_to_rgba12, p410_to_rgb10, p410_to_rgba10, p412_to_rgb12, p412_to_rgba12,
};

pub use yuv_nv_to_rgba::yuv_nv12_to_bgr;
pub use yuv_nv_to_rgba::yuv_nv12_to_bgra;
pub use yuv_nv_to_rgba::yuv_nv12_to_rgb;
pub use yuv_nv_to_rgba::yuv_nv12_to_rgba;
pub use yuv_nv_to_rgba::yuv_nv21_to_bgr;
pub use yuv_nv_to_rgba::yuv_nv21_to_bgra;
pub use yuv_nv_to_rgba::yuv_nv21_to_rgb;
pub use yuv_nv_to_rgba::yuv_nv21_to_rgba;
pub use yuv_nv_to_rgba::yuv_nv24_to_bgr;
pub use yuv_nv_to_rgba::yuv_nv24_to_bgra;
pub use yuv_nv_to_rgba::yuv_nv24_to_rgb;
pub use yuv_nv_to_rgba::yuv_nv24_to_rgba;
pub use yuv_nv_to_rgba::yuv_nv42_to_bgr;
pub use yuv_nv_to_rgba::yuv_nv42_to_bgra;
pub use yuv_nv_to_rgba::yuv_nv42_to_rgb;
pub use yuv_nv_to_rgba::yuv_nv42_to_rgba;

pub use rgba_to_nv::bgr_to_yuv_nv12;
pub use rgba_to_nv::bgr_to_yuv_nv16;
pub use rgba_to_nv::bgr_to_yuv_nv21;
pub use rgba_to_nv::bgr_to_yuv_nv24;
pub use rgba_to_nv::bgr_to_yuv_nv42;
pub use rgba_to_nv::bgr_to_yuv_nv61;
pub use rgba_to_nv::bgra_to_yuv_nv12;
pub use rgba_to_nv::bgra_to_yuv_nv16;
pub use rgba_to_nv::bgra_to_yuv_nv21;
pub use rgba_to_nv::bgra_to_yuv_nv24;
pub use rgba_to_nv::bgra_to_yuv_nv42;
pub use rgba_to_nv::bgra_to_yuv_nv61;
pub use rgba_to_nv::rgb_to_yuv_nv12;
pub use rgba_to_nv::rgb_to_yuv_nv16;
pub use rgba_to_nv::rgb_to_yuv_nv21;
pub use rgba_to_nv::rgb_to_yuv_nv24;
pub use rgba_to_nv::rgb_to_yuv_nv42;
pub use rgba_to_nv::rgb_to_yuv_nv61;
pub use rgba_to_nv::rgba_to_yuv_nv12;
pub use rgba_to_nv::rgba_to_yuv_nv16;
pub use rgba_to_nv::rgba_to_yuv_nv21;
pub use rgba_to_nv::rgba_to_yuv_nv24;
pub use rgba_to_nv::rgba_to_yuv_nv42;
pub use rgba_to_nv::rgba_to_yuv_nv61;

pub use yuv_to_rgba::yuv420_to_bgr;
pub use yuv_to_rgba::yuv420_to_bgra;
pub use yuv_to_rgba::yuv420_to_rgb;
pub use yuv_to_rgba::yuv420_to_rgba;
pub use yuv_to_rgba::yuv422_to_bgr;
pub use yuv_to_rgba::yuv422_to_bgra;
pub use yuv_to_rgba::yuv422_to_rgb;
pub use yuv_to_rgba::yuv422_to_rgba;
pub use yuv_to_rgba::yuv444_to_bgr;
pub use yuv_to_rgba::yuv444_to_bgra;
pub use yuv_to_rgba::yuv444_to_rgb;
pub use yuv_to_rgba::yuv444_to_rgba;

pub use rgba_to_yuv::bgr_to_yuv420;
pub use rgba_to_yuv::bgr_to_yuv422;
pub use rgba_to_yuv::bgr_to_yuv444;
pub use rgba_to_yuv::bgra_to_yuv420;
pub use rgba_to_yuv::bgra_to_yuv422;
pub use rgba_to_yuv::bgra_to_yuv444;
pub use rgba_to_yuv::rgb_to_yuv420;
pub use rgba_to_yuv::rgb_to_yuv422;
pub use rgba_to_yuv::rgb_to_yuv444;
pub use rgba_to_yuv::rgba_to_yuv420;
pub use rgba_to_yuv::rgba_to_yuv422;
pub use rgba_to_yuv::rgba_to_yuv444;

pub use rgb16_to_yuv_p16::{
    rgb10_to_i010, rgb10_to_i210, rgb10_to_i410, rgb12_to_i012, rgb12_to_i212, rgb12_to_i412,
    rgb14_to_i014, rgb14_to_i214, rgb14_to_i414, rgb16_to_i016, rgb16_to_i216, rgb16_to_i416,
    rgba10_to_i010, rgba10_to_i210, rgba10_to_i410, rgba12_to_i012, rgba12_to_i212, rgba12_to_i412,
    rgba14_to_i014, rgba14_to_i214, rgba14_to_i414, rgba16_to_i016, rgba16_to_i216, rgba16_to_i416,
};
#[cfg(feature = "big_endian")]
#[cfg_attr(docsrs, doc(cfg(feature = "big_endian")))]
pub use rgb16_to_yuv_p16::{
    rgb10_to_i010_be, rgb10_to_i210_be, rgb10_to_i410_be, rgb12_to_i012_be, rgb12_to_i212_be,
    rgb12_to_i412_be, rgb14_to_i014_be, rgb14_to_i214_be, rgb14_to_i414_be, rgb16_to_i016_be,
    rgb16_to_i216_be, rgb16_to_i416_be, rgba10_to_i010_be, rgba10_to_i210_be, rgba10_to_i410_be,
    rgba12_to_i012_be, rgba12_to_i212_be, rgba12_to_i412_be, rgba14_to_i014_be, rgba14_to_i214_be,
    rgba14_to_i414_be, rgba16_to_i016_be, rgba16_to_i216_be, rgba16_to_i416_be,
};

pub use yuv_to_rgba_alpha::yuv420_alpha_to_bgra;
pub use yuv_to_rgba_alpha::yuv420_alpha_to_rgba;
pub use yuv_to_rgba_alpha::yuv422_alpha_to_bgra;
pub use yuv_to_rgba_alpha::yuv422_alpha_to_rgba;
pub use yuv_to_rgba_alpha::yuv444_alpha_to_bgra;
pub use yuv_to_rgba_alpha::yuv444_alpha_to_rgba;

pub use rgb_to_y::bgr_to_yuv400;
pub use rgb_to_y::bgra_to_yuv400;
pub use rgb_to_y::rgb_to_yuv400;
pub use rgb_to_y::rgba_to_yuv400;
pub use y_to_rgb::yuv400_to_bgr;
pub use y_to_rgb::yuv400_to_bgra;
pub use y_to_rgb::yuv400_to_rgb;
pub use y_to_rgb::yuv400_to_rgba;

#[cfg(feature = "big_endian")]
#[cfg_attr(docsrs, doc(cfg(feature = "big_endian")))]
pub use yuv_p10_rgba::{
    i010_be_to_bgr, i010_be_to_bgra, i010_be_to_rgb, i010_be_to_rgba, i012_be_to_bgr,
    i012_be_to_bgra, i012_be_to_rgb, i012_be_to_rgba, i210_be_to_bgr, i210_be_to_bgra,
    i210_be_to_rgb, i210_be_to_rgba, i212_be_to_bgr, i212_be_to_bgra, i212_be_to_rgb,
    i212_be_to_rgba, i410_be_to_rgba, i412_be_to_rgba,
};
pub use yuv_p10_rgba::{
    i010_to_bgr, i010_to_bgra, i010_to_rgb, i010_to_rgba, i012_to_bgr, i012_to_bgra, i012_to_rgb,
    i012_to_rgba, i210_to_bgr, i210_to_bgra, i210_to_rgb, i210_to_rgba, i212_to_bgr, i212_to_bgra,
    i212_to_rgb, i212_to_rgba, i410_to_rgba, i412_to_rgb, i412_to_rgba,
};

pub use rgb_to_ycgco::{
    bgr_to_ycgco420, bgr_to_ycgco422, bgr_to_ycgco444, bgra_to_ycgco420, bgra_to_ycgco422,
    bgra_to_ycgco444, rgb10_to_icgc010, rgb10_to_icgc210, rgb10_to_icgc410, rgb_to_ycgco420,
    rgb_to_ycgco422, rgb_to_ycgco444, rgba10_to_icgc010, rgba10_to_icgc210, rgba10_to_icgc410,
    rgba12_to_icgc012, rgba12_to_icgc212, rgba12_to_icgc412, rgba_to_ycgco420, rgba_to_ycgco422,
    rgba_to_ycgco444,
};

pub use ycgco_to_rgb::{
    ycgco420_to_bgr, ycgco420_to_bgra, ycgco420_to_rgb, ycgco420_to_rgba, ycgco422_to_bgr,
    ycgco422_to_bgra, ycgco422_to_rgb, ycgco422_to_rgba, ycgco444_to_bgr, ycgco444_to_bgra,
    ycgco444_to_rgb, ycgco444_to_rgba,
};

pub use ycgco_to_rgb::{
    icgc010_to_rgb10, icgc010_to_rgba10, icgc012_to_rgb12, icgc012_to_rgba12, icgc210_to_rgb10,
    icgc210_to_rgba10, icgc212_to_rgb12, icgc212_to_rgba12, icgc410_to_rgb10, icgc410_to_rgba10,
    icgc412_to_rgb12, icgc412_to_rgba12,
};

pub use yuv_nv_to_rgba::yuv_nv16_to_bgr;
pub use yuv_nv_to_rgba::yuv_nv16_to_bgra;
pub use yuv_nv_to_rgba::yuv_nv16_to_rgb;
pub use yuv_nv_to_rgba::yuv_nv16_to_rgba;
pub use yuv_nv_to_rgba::yuv_nv61_to_bgr;
pub use yuv_nv_to_rgba::yuv_nv61_to_bgra;
pub use yuv_nv_to_rgba::yuv_nv61_to_rgb;
pub use yuv_nv_to_rgba::yuv_nv61_to_rgba;

pub use ycgco_to_rgb_alpha::{
    ycgco420_alpha_to_bgra, ycgco420_alpha_to_rgba, ycgco422_alpha_to_bgra, ycgco422_alpha_to_rgba,
    ycgco444_alpha_to_bgra, ycgco444_alpha_to_rgba,
};

pub use ycgco_to_rgb_alpha::{
    icgc010_alpha_to_rgba10, icgc012_alpha_to_rgba12, icgc210_alpha_to_rgba10,
    icgc212_alpha_to_rgba12, icgc410_alpha_to_rgba10, icgc412_alpha_to_rgba12,
};

pub use yuv_to_yuy2::yuv420_to_uyvy422;
pub use yuv_to_yuy2::yuv420_to_vyuy422;
pub use yuv_to_yuy2::yuv420_to_yuyv422;
pub use yuv_to_yuy2::yuv420_to_yvyu422;
pub use yuv_to_yuy2::yuv422_to_uyvy422;
pub use yuv_to_yuy2::yuv422_to_vyuy422;
pub use yuv_to_yuy2::yuv422_to_yuyv422;
pub use yuv_to_yuy2::yuv422_to_yvyu422;
pub use yuv_to_yuy2::yuv444_to_uyvy422;
pub use yuv_to_yuy2::yuv444_to_vyuy422;
pub use yuv_to_yuy2::yuv444_to_yuyv422;
pub use yuv_to_yuy2::yuv444_to_yvyu422;

pub use yuy2_to_yuv::uyvy422_to_yuv420;
pub use yuy2_to_yuv::uyvy422_to_yuv422;
pub use yuy2_to_yuv::uyvy422_to_yuv444;
pub use yuy2_to_yuv::vyuy422_to_yuv420;
pub use yuy2_to_yuv::vyuy422_to_yuv422;
pub use yuy2_to_yuv::vyuy422_to_yuv444;
pub use yuy2_to_yuv::yuyv422_to_yuv420;
pub use yuy2_to_yuv::yuyv422_to_yuv422;
pub use yuy2_to_yuv::yuyv422_to_yuv444;
pub use yuy2_to_yuv::yvyu422_to_yuv420;
pub use yuy2_to_yuv::yvyu422_to_yuv422;
pub use yuy2_to_yuv::yvyu422_to_yuv444;

pub use to_identity::{
    bgr_to_gbr, bgra_to_gbr, rgb10_to_gb10, rgb12_to_gb12, rgb14_to_gb14, rgb16_to_gb16,
    rgb_to_gbr, rgba10_to_gb10, rgba12_to_gb12, rgba14_to_gb14, rgba16_to_gb16, rgba_to_gbr,
};

pub use rgb_to_nv_p16::{
    rgb10_to_p010, rgb10_to_p210, rgb10_to_p410, rgb12_to_p012, rgb12_to_p212, rgb12_to_p412,
    rgb16_to_p016, rgb16_to_p216, rgba10_to_p010, rgba10_to_p210, rgba10_to_p410, rgba12_to_p012,
    rgba12_to_p212, rgba12_to_p412, rgba16_to_p016, rgba16_to_p216,
};

pub use yuy2_to_rgb::uyvy422_to_bgr;
pub use yuy2_to_rgb::uyvy422_to_bgra;
pub use yuy2_to_rgb::uyvy422_to_rgb;
pub use yuy2_to_rgb::uyvy422_to_rgba;
pub use yuy2_to_rgb::vyuy422_to_bgr;
pub use yuy2_to_rgb::vyuy422_to_bgra;
pub use yuy2_to_rgb::vyuy422_to_rgb;
pub use yuy2_to_rgb::vyuy422_to_rgba;
pub use yuy2_to_rgb::yuyv422_to_bgr;
pub use yuy2_to_rgb::yuyv422_to_bgra;
pub use yuy2_to_rgb::yuyv422_to_rgb;
pub use yuy2_to_rgb::yuyv422_to_rgba;
pub use yuy2_to_rgb::yvyu422_to_bgr;
pub use yuy2_to_rgb::yvyu422_to_bgra;
pub use yuy2_to_rgb::yvyu422_to_rgb;
pub use yuy2_to_rgb::yvyu422_to_rgba;

pub use yuy2_to_yuv_p16::uyvy422_to_yuv420_p16;
pub use yuy2_to_yuv_p16::uyvy422_to_yuv422_p16;
pub use yuy2_to_yuv_p16::uyvy422_to_yuv444_p16;
pub use yuy2_to_yuv_p16::vyuy422_to_yuv420_p16;
pub use yuy2_to_yuv_p16::vyuy422_to_yuv422_p16;
pub use yuy2_to_yuv_p16::vyuy422_to_yuv444_p16;
pub use yuy2_to_yuv_p16::yuyv422_to_yuv420_p16;
pub use yuy2_to_yuv_p16::yuyv422_to_yuv422_p16;
pub use yuy2_to_yuv_p16::yuyv422_to_yuv444_p16;
pub use yuy2_to_yuv_p16::yvyu422_to_yuv420_p16;
pub use yuy2_to_yuv_p16::yvyu422_to_yuv422_p16;
pub use yuy2_to_yuv_p16::yvyu422_to_yuv444_p16;

pub use yuv_to_yuy2_p16::yuv420_to_uyvy422_p16;
pub use yuv_to_yuy2_p16::yuv420_to_vyuy422_p16;
pub use yuv_to_yuy2_p16::yuv420_to_yuyv422_p16;
pub use yuv_to_yuy2_p16::yuv420_to_yvyu422_p16;
pub use yuv_to_yuy2_p16::yuv422_to_uyvy422_p16;
pub use yuv_to_yuy2_p16::yuv422_to_vyuy422_p16;
pub use yuv_to_yuy2_p16::yuv422_to_yuyv422_p16;
pub use yuv_to_yuy2_p16::yuv422_to_yvyu422_p16;
pub use yuv_to_yuy2_p16::yuv444_to_uyvy422_p16;
pub use yuv_to_yuy2_p16::yuv444_to_vyuy422_p16;
pub use yuv_to_yuy2_p16::yuv444_to_yuyv422_p16;
pub use yuv_to_yuy2_p16::yuv444_to_yvyu422_p16;

pub use yuy2_to_rgb_p16::uyvy422_to_rgb_p16;
pub use yuy2_to_rgb_p16::uyvy422_to_rgba_p16;
pub use yuy2_to_rgb_p16::vyuy422_to_rgb_p16;
pub use yuy2_to_rgb_p16::vyuy422_to_rgba_p16;
pub use yuy2_to_rgb_p16::yuyv422_to_rgb_p16;
pub use yuy2_to_rgb_p16::yuyv422_to_rgba_p16;
pub use yuy2_to_rgb_p16::yvyu422_to_rgb_p16;
pub use yuy2_to_rgb_p16::yvyu422_to_rgba_p16;

pub use sharpyuv::bgr_to_sharp_yuv420;
pub use sharpyuv::bgr_to_sharp_yuv422;
pub use sharpyuv::bgra_to_sharp_yuv420;
pub use sharpyuv::bgra_to_sharp_yuv422;
pub use sharpyuv::rgb_to_sharp_yuv420;
pub use sharpyuv::rgb_to_sharp_yuv422;
pub use sharpyuv::rgba_to_sharp_yuv420;
pub use sharpyuv::rgba_to_sharp_yuv422;
pub use sharpyuv::SharpYuvGammaTransfer;

pub use from_identity::{
    gb10_to_rgb10, gb10_to_rgba10, gb12_to_rgb12, gb12_to_rgba12, gb14_to_rgb14, gb14_to_rgba14,
    gb16_to_rgb16, gb16_to_rgba16, gbr_to_bgr, gbr_to_bgra, gbr_to_rgb, gbr_to_rgba,
};

#[cfg(feature = "nightly_f16")]
pub use from_identity_f16::{
    gb10_to_rgb_f16, gb10_to_rgba_f16, gb12_to_rgb_f16, gb12_to_rgba_f16, gb14_to_rgb_f16,
    gb14_to_rgba_f16, gb16_to_rgb_f16, gb16_to_rgba_f16,
};

#[cfg(feature = "nightly_f16")]
pub use from_identity_alpha_f16::{
    gb10_alpha_to_rgba_f16, gb12_alpha_to_rgba_f16, gb14_alpha_to_rgba_f16, gb16_alpha_to_rgba_f16,
};

pub use from_identity_alpha::{
    gb10_alpha_to_rgba10, gb12_alpha_to_rgba12, gb14_alpha_to_rgba14, gb16_alpha_to_rgba16,
    gbr_with_alpha_to_bgra, gbr_with_alpha_to_rgba,
};

pub use images::{
    BufferStoreMut, YuvBiPlanarImage, YuvBiPlanarImageMut, YuvGrayAlphaImage, YuvGrayImage,
    YuvGrayImageMut, YuvPackedImage, YuvPackedImageMut, YuvPlanarImage, YuvPlanarImageMut,
    YuvPlanarImageWithAlpha,
};
pub use y_p16_to_rgb16::{
    y010_to_rgb10, y010_to_rgba10, y012_to_rgb12, y012_to_rgba12, y014_to_rgb14, y014_to_rgba14,
    y016_to_rgb16, y016_to_rgba16,
};
pub use y_p16_with_alpha_to_rgb16::{
    y010_alpha_to_rgba10, y012_alpha_to_rgba12, y014_alpha_to_rgba14, y016_alpha_to_rgba16,
};
pub use y_with_alpha_to_rgb::{yuv400_alpha_to_bgra, yuv400_alpha_to_rgba};
pub use yuv_error::YuvError;

pub use yuv_p16_rgba_alpha::{
    i010_alpha_to_rgba, i012_alpha_to_rgba, i210_alpha_to_rgba, i212_alpha_to_rgba,
    i410_alpha_to_rgba, i412_alpha_to_rgba,
};
#[cfg(feature = "big_endian")]
#[cfg_attr(docsrs, doc(cfg(feature = "big_endian")))]
pub use yuv_p16_rgba_alpha::{
    i010_be_alpha_to_rgba, i012_be_alpha_to_rgba, i210_alpha_be_to_rgba, i212_be_alpha_to_rgba,
    i410_be_alpha_to_rgba, i412_be_alpha_to_rgba,
};

pub use yuv_p16_rgba16_alpha::{
    i010_alpha_to_rgba10, i012_alpha_to_rgba12, i014_alpha_to_rgba14, i210_alpha_to_rgba10,
    i212_alpha_to_rgba12, i214_alpha_to_rgba14, i410_alpha_to_rgba10, i412_alpha_to_rgba12,
    i414_alpha_to_rgba14,
};
#[cfg(feature = "big_endian")]
#[cfg_attr(docsrs, doc(cfg(feature = "big_endian")))]
pub use yuv_p16_rgba16_alpha::{
    i010_be_alpha_to_rgba10, i012_be_alpha_to_rgba12, i014_be_alpha_to_rgba14,
    i210_alpha_be_to_rgba10, i212_be_alpha_to_rgba12, i214_be_alpha_to_rgba14,
    i410_be_alpha_to_rgba10, i412_be_alpha_to_rgba12, i414_be_alpha_to_rgba14,
};
#[cfg(feature = "big_endian")]
#[cfg_attr(docsrs, doc(cfg(feature = "big_endian")))]
pub use yuv_p16_rgba_p16::{
    i010_be_to_rgb10, i010_be_to_rgba10, i012_be_to_rgb12, i012_be_to_rgba12, i014_be_to_rgb14,
    i014_be_to_rgba14, i016_be_to_rgb16, i016_be_to_rgba16, i210_be_to_rgb10, i210_be_to_rgba10,
    i212_be_to_rgb12, i212_be_to_rgba12, i214_be_to_rgb14, i214_be_to_rgba14, i216_be_to_rgb16,
    i216_be_to_rgba16, i410_be_to_rgb10, i410_be_to_rgba10, i412_be_to_rgb12, i412_be_to_rgba12,
    i414_be_to_rgb14, i414_be_to_rgba14, i416_be_to_rgb16, i416_be_to_rgba16,
};
pub use yuv_p16_rgba_p16::{
    i010_to_rgb10, i010_to_rgba10, i012_to_rgb12, i012_to_rgba12, i014_to_rgb14, i014_to_rgba14,
    i016_to_rgb16, i016_to_rgba16, i210_to_rgb10, i210_to_rgba10, i212_to_rgb12, i212_to_rgba12,
    i214_to_rgb14, i214_to_rgba14, i216_to_rgb16, i216_to_rgba16, i410_to_rgb10, i410_to_rgba10,
    i412_to_rgb12, i412_to_rgba12, i414_to_rgb14, i414_to_rgba14, i416_to_rgb16, i416_to_rgba16,
};

#[cfg(feature = "nightly_f16")]
pub use yuva_p16_rgba_f16::{
    i010_alpha_to_rgba_f16, i012_alpha_to_rgba_f16, i014_alpha_to_rgba_f16, i210_alpha_to_rgba_f16,
    i212_alpha_to_rgba_f16, i214_alpha_to_rgba_f16, i410_alpha_to_rgba_f16, i412_alpha_to_rgba_f16,
    i414_alpha_to_rgba_f16,
};

pub use ar30_rgb::{
    ab30_to_rgb8, ar30_to_rgb8, ar30_to_rgba8, ba30_to_rgb8, ra30_to_rgb8, ra30_to_rgba8,
};

#[cfg(feature = "nightly_f16")]
pub use f16_converter::{
    convert_plane16_to_f16, convert_plane_f16_to_planar, convert_plane_f16_to_planar16,
    convert_plane_to_f16, convert_rgb16_to_f16, convert_rgb_f16_to_rgb, convert_rgb_f16_to_rgb16,
    convert_rgb_to_f16, convert_rgba16_to_f16, convert_rgba_f16_to_rgba,
    convert_rgba_f16_to_rgba16, convert_rgba_to_f16,
};

#[cfg(feature = "geometry")]
pub use geometry::{
    rotate_cbcr, rotate_cbcr16, rotate_plane, rotate_plane16, rotate_rgb, rotate_rgb16,
    rotate_rgba, rotate_rgba16, RotationMode,
};
#[cfg(feature = "geometry")]
pub use mirroring::{
    mirror_cbcr, mirror_cbcr16, mirror_plane, mirror_plane16, mirror_rgb, mirror_rgb16,
    mirror_rgba, mirror_rgba16, MirrorMode,
};

pub use rgb_ar30::{
    rgb10_to_ar30, rgb10_to_ra30, rgb12_to_ar30, rgb12_to_ra30, rgb8_to_ar30, rgb8_to_ra30,
    rgba10_to_ar30, rgba10_to_ra30, rgba12_to_ar30, rgba12_to_ra30, rgba8_to_ar30, rgba8_to_ra30,
};

pub use shuffle::{
    bgr_to_bgra, bgr_to_rgb, bgr_to_rgba, bgra_to_bgr, bgra_to_rgb, bgra_to_rgba, rgb_to_bgr,
    rgb_to_bgra, rgb_to_rgba, rgba_to_bgr, rgba_to_bgra, rgba_to_rgb,
};

pub use yuv_nv_p10_to_ar30::{
    p010_to_ar30, p010_to_ra30, p012_to_ar30, p012_to_ra30, p210_to_ar30, p210_to_ra30,
    p212_to_ar30, p212_to_ra30,
};

pub use yuv_p16_ar30::{
    i010_to_ar30, i010_to_ra30, i012_to_ar30, i012_to_ra30, i014_to_ar30, i014_to_ra30,
    i210_to_ar30, i210_to_ra30, i212_to_ar30, i212_to_ra30, i214_to_ar30, i214_to_ra30,
    i410_to_ar30, i410_to_ra30, i412_to_ar30, i412_to_ra30, i414_to_ar30, i414_to_ra30,
};

#[cfg(feature = "rdp")]
#[cfg_attr(docsrs, doc(cfg(feature = "rdp")))]
pub use rdp::{
    rdp_abgr_to_yuv444, rdp_argb_to_yuv444, rdp_bgr_to_yuv444, rdp_bgra_to_yuv444,
    rdp_rgb_to_yuv444, rdp_rgba_to_yuv444, rdp_yuv444_to_abgr, rdp_yuv444_to_argb,
    rdp_yuv444_to_bgr, rdp_yuv444_to_bgra, rdp_yuv444_to_rgb, rdp_yuv444_to_rgba,
};
#[cfg(feature = "nightly_f16")]
pub use yuv_p16_rgba_f16::{
    i010_to_rgb_f16, i010_to_rgba_f16, i012_to_rgb_f16, i012_to_rgba_f16, i014_to_rgb_f16,
    i014_to_rgba_f16, i210_to_rgb_f16, i210_to_rgba_f16, i212_to_rgb_f16, i212_to_rgba_f16,
    i214_to_rgb_f16, i214_to_rgba_f16, i410_to_rgb_f16, i410_to_rgba_f16, i412_to_rgb_f16,
    i412_to_rgba_f16, i414_to_rgb_f16, i414_to_rgba_f16,
};

pub use ayuv_to_rgb::{ayuv_to_rgb, ayuv_to_rgba, vyua_to_rgb, vyua_to_rgba};

#[cfg(feature = "nightly_f16")]
#[cfg_attr(docsrs, doc(cfg(feature = "nightly_f16")))]
pub use f16_ar30::{rgb_f16_to_ar30, rgb_f16_to_ra30, rgba_f16_to_ar30, rgba_f16_to_ra30};

#[cfg(feature = "ycgco_r_type")]
#[cfg_attr(docsrs, doc(cfg(feature = "ycgco_r_type")))]
pub use ycgco_re_to_rgb::{
    icgc_re010_to_bgr, icgc_re010_to_bgra, icgc_re010_to_rgb, icgc_re010_to_rgba,
    icgc_re012_to_rgb10, icgc_re012_to_rgba10, icgc_re210_to_bgr, icgc_re210_to_bgra,
    icgc_re210_to_rgb, icgc_re210_to_rgba, icgc_re212_to_rgb10, icgc_re212_to_rgba10,
    icgc_re410_to_bgr, icgc_re410_to_bgra, icgc_re410_to_rgb, icgc_re410_to_rgba,
    icgc_re412_to_rgb10, icgc_re412_to_rgba10, icgc_ro010_to_bgr, icgc_ro010_to_bgra,
    icgc_ro010_to_rgb, icgc_ro010_to_rgba, icgc_ro012_to_rgb10, icgc_ro012_to_rgba10,
    icgc_ro210_to_bgr, icgc_ro210_to_bgra, icgc_ro210_to_rgb, icgc_ro210_to_rgba,
    icgc_ro212_to_rgb10, icgc_ro212_to_rgba10, icgc_ro410_to_bgr, icgc_ro410_to_bgra,
    icgc_ro410_to_rgb, icgc_ro410_to_rgba, icgc_ro412_to_rgb10, icgc_ro412_to_rgba10,
};

#[cfg(feature = "ycgco_r_type")]
#[cfg_attr(docsrs, doc(cfg(feature = "ycgco_r_type")))]
pub use ycgco_re_to_rgb_alpha::{
    icgc_re_alpha010_to_bgra, icgc_re_alpha010_to_rgba, icgc_re_alpha012_to_rgba10,
    icgc_re_alpha210_to_bgra, icgc_re_alpha210_to_rgba, icgc_re_alpha212_to_rgba10,
    icgc_re_alpha410_to_bgra, icgc_re_alpha410_to_rgba, icgc_re_alpha412_to_rgba10,
    icgc_ro_alpha010_to_bgra, icgc_ro_alpha010_to_rgba, icgc_ro_alpha012_to_rgba10,
    icgc_ro_alpha210_to_bgra, icgc_ro_alpha210_to_rgba, icgc_ro_alpha212_to_rgba10,
    icgc_ro_alpha410_to_bgra, icgc_ro_alpha410_to_rgba, icgc_ro_alpha412_to_rgba10,
};

#[cfg(feature = "ycgco_r_type")]
#[cfg_attr(docsrs, doc(cfg(feature = "ycgco_r_type")))]
pub use rgb_to_ycgco_r::{
    rgb10_to_icgc_re012, rgb10_to_icgc_re212, rgb10_to_icgc_re412, rgb10_to_icgc_ro012,
    rgb10_to_icgc_ro212, rgb10_to_icgc_ro412, rgb_to_icgc_re010, rgb_to_icgc_re210,
    rgb_to_icgc_re410, rgb_to_icgc_ro010, rgb_to_icgc_ro210, rgb_to_icgc_ro410,
    rgba10_to_icgc_re012, rgba10_to_icgc_re212, rgba10_to_icgc_re412, rgba10_to_icgc_ro012,
    rgba10_to_icgc_ro212, rgba10_to_icgc_ro412, rgba_to_icgc_re010, rgba_to_icgc_re210,
    rgba_to_icgc_re410, rgba_to_icgc_ro010, rgba_to_icgc_ro210, rgba_to_icgc_ro410,
};

pub use yuv_to_rgba_bilinear::{
    yuv420_to_bgr_bilinear, yuv420_to_bgra_bilinear, yuv420_to_rgb_bilinear,
    yuv420_to_rgba_bilinear, yuv422_to_bgr_bilinear, yuv422_to_bgra_bilinear,
    yuv422_to_rgb_bilinear, yuv422_to_rgba_bilinear,
};

pub use yuv_p16_to_rgba16_bilinear::{
    i010_to_rgb10_bilinear, i010_to_rgba10_bilinear, i012_to_rgb12_bilinear,
    i012_to_rgba12_bilinear, i014_to_rgb14_bilinear, i014_to_rgba14_bilinear,
    i016_to_rgb16_bilinear, i016_to_rgba16_bilinear, i210_to_rgb10_bilinear,
    i210_to_rgba10_bilinear, i212_to_rgb12_bilinear, i212_to_rgba12_bilinear,
    i214_to_rgb14_bilinear, i214_to_rgba14_bilinear, i216_to_rgb16_bilinear,
    i216_to_rgba16_bilinear, i414_to_rgb14_bilinear, i414_to_rgba14_bilinear,
};
