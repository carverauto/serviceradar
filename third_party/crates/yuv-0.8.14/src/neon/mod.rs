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
#![deny(unreachable_code, unreachable_pub)]
mod ar30_utils;
mod ayuv_to_rgba;
mod cgco;
#[cfg(feature = "nightly_f16")]
mod f16_converter;
#[cfg(feature = "nightly_f16")]
mod f16_utils;
mod gbr_to_rgb;
#[cfg(feature = "professional_mode")]
mod rgb_to_nv420_prof;
#[cfg(feature = "professional_mode")]
mod rgb_to_nv_prof;
mod rgb_to_y;
#[cfg(feature = "professional_mode")]
mod rgb_to_yuv420_prof;
mod rgb_to_yuv_p16;
mod rgb_to_yuv_p16_420;
#[cfg(feature = "professional_mode")]
mod rgb_to_yuv_prof;
mod rgba_to_nv;
mod rgba_to_nv420;
#[cfg(all(feature = "nightly_i8mm", feature = "fast_mode"))]
mod rgba_to_nv_dot;
#[cfg(all(feature = "nightly_i8mm", feature = "fast_mode"))]
mod rgba_to_nv_dot420;
mod rgba_to_yuv;
mod rgba_to_yuv420;
#[cfg(all(feature = "nightly_i8mm", feature = "fast_mode"))]
mod rgba_to_yuv_dot;
#[cfg(all(feature = "nightly_i8mm", feature = "fast_mode"))]
mod rgba_to_yuv_dot420;
#[cfg(feature = "fast_mode")]
mod rgbx_to_nv_fast;
#[cfg(feature = "fast_mode")]
mod rgbx_to_nv_fast420;
#[cfg(feature = "fast_mode")]
mod rgbx_to_yuv_fast;
#[cfg(feature = "fast_mode")]
mod rgbx_to_yuv_fast420;
mod shuffle;
mod utils;
mod y_p16_to_rgba16;
mod y_to_rgb;
mod y_to_rgb_alpha;
mod yuv_nv_p10_to_ar30;
mod yuv_nv_p10_to_rgba;
#[cfg(feature = "professional_mode")]
mod yuv_nv_p10_to_rgba_prof;
mod yuv_nv_p16_to_rgb;
mod yuv_nv_to_rgba;
mod yuv_nv_to_rgba420;
#[cfg(feature = "professional_mode")]
mod yuv_nv_to_rgba420_prof;
#[cfg(feature = "professional_mode")]
mod yuv_nv_to_rgba_prof;
#[cfg(feature = "fast_mode")]
mod yuv_nv_to_rgbx_fast;
#[cfg(feature = "fast_mode")]
mod yuv_nv_to_rgbx_fast420;
mod yuv_p16_to_rgba16;
mod yuv_p16_to_rgba16_420;
mod yuv_p16_to_rgba16_alpha;
mod yuv_p16_to_rgba16_bilinear;
mod yuv_p16_to_rgba8;
mod yuv_p16_to_rgba_alpha;
#[cfg(feature = "nightly_f16")]
mod yuv_p16_to_rgba_f16;
mod yuv_to_rgba;
mod yuv_to_rgba420;
mod yuv_to_rgba_alpha;
mod yuv_to_rgba_bilinear;
mod yuv_to_yuy2;
#[cfg(feature = "nightly_f16")]
mod yuva_p16_to_rgba_f16;
mod yuy2_to_rgb;
mod yuy2_to_yuv;

pub(crate) use ayuv_to_rgba::neon_ayuv_to_rgba;
#[cfg(feature = "rdm")]
pub(crate) use ayuv_to_rgba::neon_ayuv_to_rgba_rdm;
pub(crate) use cgco::{neon_ycgco420_to_rgba_row, neon_ycgco_full_range_to_rgb};
#[cfg(feature = "ycgco_r_type")]
pub(crate) use cgco::{ycgco_ro_re_u16_to_rgba_neon, ycgco_ro_re_u16_to_rgba_neon_full};
#[cfg(feature = "nightly_f16")]
pub(crate) use f16_converter::{
    SurfaceF16ToUnsigned16Neon, SurfaceF16ToUnsigned16NeonFallback, SurfaceF16ToUnsigned8Neon,
    SurfaceF16ToUnsigned8NeonFallback, SurfaceU16ToFloat16Neon, SurfaceU16ToFloat16NeonFallback,
    SurfaceU8ToFloat16Neon, SurfaceU8ToFloat16NeonFallback,
};
#[cfg(feature = "rdm")]
pub(crate) use gbr_to_rgb::yuv_to_rgba_row_limited_rdm;
pub(crate) use gbr_to_rgb::{yuv_to_rgba_row_full, yuv_to_rgba_row_limited};
#[cfg(feature = "professional_mode")]
pub(crate) use rgb_to_nv420_prof::neon_rgba_to_nv_prof420;
#[cfg(feature = "professional_mode")]
pub(crate) use rgb_to_nv_prof::neon_rgba_to_nv_prof;
#[cfg(feature = "rdm")]
pub(crate) use rgb_to_y::neon_rgb_to_y_rdm;
pub(crate) use rgb_to_y::neon_rgb_to_y_row;
#[cfg(feature = "professional_mode")]
pub(crate) use rgb_to_yuv420_prof::neon_rgba_to_yuv_prof420;
pub(crate) use rgb_to_yuv_p16::neon_rgba_to_yuv_p16;
#[cfg(feature = "rdm")]
pub(crate) use rgb_to_yuv_p16::neon_rgba_to_yuv_p16_rdm;
pub(crate) use rgb_to_yuv_p16_420::neon_rgba_to_yuv_p16_420;
#[cfg(feature = "rdm")]
pub(crate) use rgb_to_yuv_p16_420::neon_rgba_to_yuv_p16_rdm_420;
#[cfg(feature = "professional_mode")]
pub(crate) use rgb_to_yuv_prof::neon_rgba_to_yuv_prof;
pub(crate) use rgba_to_nv::neon_rgbx_to_nv_row;
#[cfg(feature = "rdm")]
pub(crate) use rgba_to_nv::neon_rgbx_to_nv_row_rdm;
pub(crate) use rgba_to_nv420::neon_rgbx_to_nv_row420;
#[cfg(feature = "rdm")]
pub(crate) use rgba_to_nv420::neon_rgbx_to_nv_row_rdm420;
#[cfg(all(feature = "nightly_i8mm", feature = "fast_mode"))]
pub(crate) use rgba_to_nv_dot::neon_rgba_to_nv_dot_rgba;
#[cfg(all(feature = "nightly_i8mm", feature = "fast_mode"))]
pub(crate) use rgba_to_nv_dot420::neon_rgba_to_nv_dot_rgba420;
pub(crate) use rgba_to_yuv::neon_rgba_to_yuv;
#[cfg(feature = "rdm")]
pub(crate) use rgba_to_yuv::neon_rgba_to_yuv_rdm;
pub(crate) use rgba_to_yuv420::neon_rgba_to_yuv420;
#[cfg(feature = "rdm")]
pub(crate) use rgba_to_yuv420::neon_rgba_to_yuv_rdm420;
#[cfg(all(feature = "nightly_i8mm", feature = "fast_mode"))]
pub(crate) use rgba_to_yuv_dot::neon_rgba_to_yuv_dot_rgba;
#[cfg(all(feature = "nightly_i8mm", feature = "fast_mode"))]
pub(crate) use rgba_to_yuv_dot420::neon_rgba_to_yuv_dot_rgba420;
#[cfg(feature = "fast_mode")]
pub(crate) use rgbx_to_nv_fast::neon_rgbx_to_nv_fast;
#[cfg(feature = "fast_mode")]
pub(crate) use rgbx_to_nv_fast420::neon_rgbx_to_nv_fast420;
#[cfg(feature = "fast_mode")]
pub(crate) use rgbx_to_yuv_fast::neon_rgbx_to_yuv_fast;
#[cfg(feature = "fast_mode")]
pub(crate) use rgbx_to_yuv_fast420::neon_rgbx_to_yuv_fast420;
pub(crate) use shuffle::ShuffleConverterNeon;
pub(crate) use y_p16_to_rgba16::neon_y_p16_to_rgba16_row;
pub(crate) use y_to_rgb::neon_y_to_rgb_row;
#[cfg(feature = "rdm")]
pub(crate) use y_to_rgb::neon_y_to_rgb_row_rdm;
pub(crate) use y_to_rgb_alpha::neon_y_to_rgb_alpha_row;
#[cfg(feature = "rdm")]
pub(crate) use y_to_rgb_alpha::neon_y_to_rgb_row_alpha_rdm;
pub(crate) use yuv_nv_p10_to_ar30::neon_yuv_nv12_p10_to_ar30_row;
pub(crate) use yuv_nv_p10_to_rgba::neon_yuv_nv12_p10_to_rgba_row;
#[cfg(feature = "professional_mode")]
pub(crate) use yuv_nv_p10_to_rgba_prof::neon_yuv_nv12_p10_to_rgba_row_prof;
pub(crate) use yuv_nv_p16_to_rgb::neon_yuv_nv_p16_to_rgba_row;
#[cfg(feature = "rdm")]
pub(crate) use yuv_nv_p16_to_rgb::neon_yuv_nv_p16_to_rgba_row_rdm;
pub(crate) use yuv_nv_to_rgba::neon_yuv_nv_to_rgba_row;
#[cfg(feature = "rdm")]
pub(crate) use yuv_nv_to_rgba::neon_yuv_nv_to_rgba_row_rdm;
pub(crate) use yuv_nv_to_rgba420::neon_yuv_nv_to_rgba_row420;
#[cfg(feature = "rdm")]
pub(crate) use yuv_nv_to_rgba420::neon_yuv_nv_to_rgba_row_rdm420;
#[cfg(feature = "professional_mode")]
pub(crate) use yuv_nv_to_rgba420_prof::neon_yuv_nv_to_rgba_row420_prof;
#[cfg(feature = "professional_mode")]
pub(crate) use yuv_nv_to_rgba_prof::neon_yuv_nv_to_rgba_row_prof;
#[cfg(feature = "fast_mode")]
pub(crate) use yuv_nv_to_rgbx_fast::neon_yuv_nv_to_rgba_fast_row;
#[cfg(feature = "fast_mode")]
pub(crate) use yuv_nv_to_rgbx_fast420::neon_yuv_nv_to_rgba_fast_row420;
pub(crate) use yuv_p16_to_rgba16::neon_yuv_p16_to_rgba16_row;
#[cfg(feature = "rdm")]
pub(crate) use yuv_p16_to_rgba16::neon_yuv_p16_to_rgba16_row_rdm;
pub(crate) use yuv_p16_to_rgba16_420::neon_yuv_p16_to_rgba16_row420;
#[cfg(feature = "rdm")]
pub(crate) use yuv_p16_to_rgba16_420::neon_yuv_p16_to_rgba16_row420_rdm;
pub(crate) use yuv_p16_to_rgba16_alpha::neon_yuv_p16_to_rgba16_alpha_row;
#[cfg(feature = "rdm")]
pub(crate) use yuv_p16_to_rgba16_alpha::neon_yuv_p16_to_rgba16_alpha_row_rdm;
pub(crate) use yuv_p16_to_rgba16_bilinear::{
    neon_planar16_bilinear_1_row_rgba16, neon_planar16_bilinear_2_rows_rgba,
};
pub(crate) use yuv_p16_to_rgba8::neon_yuv_p16_to_rgba_row;
pub(crate) use yuv_p16_to_rgba_alpha::neon_yuv_p16_to_rgba_alpha_row;
#[cfg(feature = "nightly_f16")]
pub(crate) use yuv_p16_to_rgba_f16::neon_yuv_p16_to_rgba_f16_row;
pub(crate) use yuv_to_rgba::neon_yuv_to_rgba_row;
#[cfg(feature = "rdm")]
pub(crate) use yuv_to_rgba::neon_yuv_to_rgba_row_rdm;
pub(crate) use yuv_to_rgba420::neon_yuv_to_rgba_row420;
#[cfg(feature = "rdm")]
pub(crate) use yuv_to_rgba420::neon_yuv_to_rgba_row_rdm420;
pub(crate) use yuv_to_rgba_alpha::neon_yuv_to_rgba_alpha;
#[cfg(feature = "rdm")]
pub(crate) use yuv_to_rgba_alpha::neon_yuv_to_rgba_alpha_rdm;
pub(crate) use yuv_to_rgba_bilinear::{
    neon_bilinear_interpolate_1_row_rgba, neon_bilinear_interpolate_2_rows_rgba,
};
pub(crate) use yuv_to_yuy2::yuv_to_yuy2_neon_impl;
#[cfg(feature = "nightly_f16")]
pub(crate) use yuva_p16_to_rgba_f16::neon_yuva_p16_to_rgba_f16_row;
pub(crate) use yuy2_to_rgb::yuy2_to_rgb_neon;
pub(crate) use yuy2_to_yuv::yuy2_to_yuv_neon_impl;
