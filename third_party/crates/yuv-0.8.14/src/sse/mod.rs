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
mod gbr_to_rgb;
mod rgb_to_nv;
mod rgb_to_nv420;
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
#[cfg(feature = "fast_mode")]
mod rgba_to_nv_fast;
#[cfg(feature = "fast_mode")]
mod rgba_to_nv_fast420;
mod rgba_to_yuv;
mod rgba_to_yuv420;
#[cfg(feature = "fast_mode")]
mod rgba_to_yuv_fast;
#[cfg(feature = "fast_mode")]
mod rgba_to_yuv_fast420;
mod shuffle;
pub(crate) mod utils;
mod y_to_rgba;
mod y_to_rgba_alpha;
mod yuv16_to_rgba16_bilinear;
mod yuv_nv_p16_to_rgb;
mod yuv_nv_to_rgba;
mod yuv_nv_to_rgba420;
#[cfg(feature = "professional_mode")]
mod yuv_nv_to_rgba420_prof;
mod yuv_nv_to_rgba422;
#[cfg(feature = "fast_mode")]
mod yuv_nv_to_rgba_fast;
#[cfg(feature = "fast_mode")]
mod yuv_nv_to_rgba_fast420;
#[cfg(feature = "professional_mode")]
mod yuv_nv_to_rgba_prof;
mod yuv_p16_to_rgb16;
mod yuv_p16_to_rgb16_420;
mod yuv_p16_to_rgb16_alpha;
mod yuv_p16_to_rgb8;
mod yuv_p16_to_rgb8_alpha;
mod yuv_to_rgba;
mod yuv_to_rgba420;
mod yuv_to_rgba422;
mod yuv_to_rgba_alpha;
mod yuv_to_rgba_bilinear;
mod yuv_to_yuy2;
mod yuy2_to_rgb;
mod yuy2_to_yuv;

pub(crate) use gbr_to_rgb::{sse_yuv_to_rgba_row_full, sse_yuv_to_rgba_row_limited};
pub(crate) use rgb_to_nv::sse_rgba_to_nv_row;
pub(crate) use rgb_to_nv420::sse_rgba_to_nv_row420;
#[cfg(feature = "professional_mode")]
pub(crate) use rgb_to_nv420_prof::sse_rgba_to_nv420_prof;
#[cfg(feature = "professional_mode")]
pub(crate) use rgb_to_nv_prof::sse_rgba_to_nv_prof;
pub(crate) use rgb_to_y::sse_rgb_to_y;
#[cfg(feature = "professional_mode")]
pub(crate) use rgb_to_yuv420_prof::sse_rgba_to_yuv420_prof;
pub(crate) use rgb_to_yuv_p16::sse_rgba_to_yuv_p16;
pub(crate) use rgb_to_yuv_p16_420::sse_rgba_to_yuv_p16_420;
#[cfg(feature = "professional_mode")]
pub(crate) use rgb_to_yuv_prof::sse_rgba_to_yuv_prof;
#[cfg(feature = "fast_mode")]
pub(crate) use rgba_to_nv_fast::sse_rgba_to_nv_fast_rgba;
#[cfg(feature = "fast_mode")]
pub(crate) use rgba_to_nv_fast420::sse_rgba_to_nv_fast_rgba420;
pub(crate) use rgba_to_yuv::sse_rgba_to_yuv_row;
pub(crate) use rgba_to_yuv420::sse_rgba_to_yuv_row420;
#[cfg(feature = "fast_mode")]
pub(crate) use rgba_to_yuv_fast::sse_rgba_to_yuv_dot_rgba;
#[cfg(feature = "fast_mode")]
pub(crate) use rgba_to_yuv_fast420::sse_rgba_to_yuv_dot_rgba420;
pub(crate) use shuffle::{ShuffleConverterSse, ShuffleQTableConverterSse};
pub(crate) use utils::*;
pub(crate) use y_to_rgba::sse_y_to_rgba_row;
pub(crate) use y_to_rgba_alpha::sse_y_to_rgba_alpha_row;
pub(crate) use yuv16_to_rgba16_bilinear::{
    sse_planar16_bilinear_1_row_rgba, sse_planar16_bilinear_2_rows_rgba,
};
pub(crate) use yuv_nv_p16_to_rgb::sse_yuv_nv_p16_to_rgba_row;
pub(crate) use yuv_nv_to_rgba::sse_yuv_nv_to_rgba;
pub(crate) use yuv_nv_to_rgba420::sse_yuv_nv_to_rgba420;
#[cfg(feature = "professional_mode")]
pub(crate) use yuv_nv_to_rgba420_prof::sse_yuv_nv_to_rgba_row420_prof;
pub(crate) use yuv_nv_to_rgba422::sse_yuv_nv_to_rgba422;
#[cfg(feature = "fast_mode")]
pub(crate) use yuv_nv_to_rgba_fast::sse_yuv_nv_to_rgba_fast;
#[cfg(feature = "fast_mode")]
pub(crate) use yuv_nv_to_rgba_fast420::sse_yuv_nv_to_rgba_fast420;
#[cfg(feature = "professional_mode")]
pub(crate) use yuv_nv_to_rgba_prof::sse_yuv_nv_to_rgba_row_prof;
pub(crate) use yuv_p16_to_rgb16::sse_yuv_p16_to_rgba_row;
pub(crate) use yuv_p16_to_rgb16_420::sse_yuv_p16_to_rgba_row420;
pub(crate) use yuv_p16_to_rgb16_alpha::sse_yuv_p16_to_rgba_alpha_row;
pub(crate) use yuv_p16_to_rgb8::sse_yuv_p16_to_rgba8_row;
pub(crate) use yuv_p16_to_rgb8_alpha::sse_yuv_p16_to_rgba8_alpha_row;
pub(crate) use yuv_to_rgba::sse_yuv_to_rgba_row;
pub(crate) use yuv_to_rgba420::sse_yuv_to_rgba_row420;
pub(crate) use yuv_to_rgba422::sse_yuv_to_rgba_row422;
pub(crate) use yuv_to_rgba_alpha::sse_yuv_to_rgba_alpha_row;
pub(crate) use yuv_to_rgba_bilinear::{
    sse_bilinear_interpolate_1_row_rgba, sse_bilinear_interpolate_2_rows_rgba,
};
pub(crate) use yuv_to_yuy2::yuv_to_yuy2_sse;
pub(crate) use yuy2_to_rgb::yuy2_to_rgb_sse;
pub(crate) use yuy2_to_yuv::yuy2_to_yuv_sse;
