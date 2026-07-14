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
#![allow(clippy::incompatible_msrv)]
mod avx2_utils;
mod ayuv_to_rgba;
mod cgco;
#[cfg(feature = "nightly_f16")]
mod f16_converter;
mod gbr_to_rgb;
#[cfg(feature = "rdp")]
mod rdp_to_yuv;
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
mod rgb_to_yuv_p16_420_d16;
mod rgb_to_yuv_p16_d16;
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
mod y_to_rgba;
mod y_to_rgba_alpha;
mod yuv16_to_rgba16_bilinear;
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
mod yuv_p16_to_rgb_d16;
mod yuv_p16_to_rgb_d16_420;
#[cfg(feature = "nightly_f16")]
mod yuv_p16_to_rgb_f16;
mod yuv_to_rgba;
mod yuv_to_rgba420;
mod yuv_to_rgba422;
mod yuv_to_rgba_alpha;
mod yuv_to_rgba_bilinear;
mod yuv_to_yuv2;
#[cfg(feature = "nightly_f16")]
mod yuva_p16_to_rgb_f16;
mod yuy2_to_rgb;
mod yuy2_to_yuv;

pub(crate) use ayuv_to_rgba::avx2_ayuv_to_rgba;
pub(crate) use cgco::avx2_ycgco_full_range_to_rgb;
#[cfg(feature = "ycgco_r_type")]
pub(crate) use cgco::{ycgco_ro_re_u16_to_rgba_avx2, ycgco_ro_re_u16_to_rgba_avx2_full};
#[cfg(feature = "nightly_f16")]
pub(crate) use f16_converter::{SurfaceU16ToFloat16Avx2, SurfaceU8ToFloat16Avx2};
pub(crate) use gbr_to_rgb::{avx_yuv_to_rgba_row_full, avx_yuv_to_rgba_row_limited};
#[cfg(feature = "rdp")]
pub(crate) use rdp_to_yuv::rdp_avx2_rgba_to_yuv;
pub(crate) use rgb_to_nv::avx2_rgba_to_nv;
pub(crate) use rgb_to_nv420::avx2_rgba_to_nv420;
#[cfg(feature = "professional_mode")]
pub(crate) use rgb_to_nv420_prof::avx2_rgba_to_nv420_prof;
#[cfg(feature = "professional_mode")]
pub(crate) use rgb_to_nv_prof::avx2_rgba_to_nv_prof;
pub(crate) use rgb_to_y::avx2_rgb_to_y_row;
#[cfg(feature = "professional_mode")]
pub(crate) use rgb_to_yuv420_prof::avx2_rgba_to_yuv420_prof;
pub(crate) use rgb_to_yuv_p16::avx_rgba_to_yuv_p16;
pub(crate) use rgb_to_yuv_p16_420::avx_rgba_to_yuv_p16_420;
pub(crate) use rgb_to_yuv_p16_420_d16::avx_rgba_to_yuv_p16_420_d16;
pub(crate) use rgb_to_yuv_p16_d16::avx_rgba_to_yuv_p16_d16;
#[cfg(feature = "professional_mode")]
pub(crate) use rgb_to_yuv_prof::avx2_rgba_to_yuv_prof;
#[cfg(feature = "fast_mode")]
pub(crate) use rgba_to_nv_fast::avx2_rgba_to_nv_fast_rgba;
#[cfg(feature = "fast_mode")]
pub(crate) use rgba_to_nv_fast420::avx2_rgba_to_nv_fast_rgba420;
pub(crate) use rgba_to_yuv::avx2_rgba_to_yuv;
pub(crate) use rgba_to_yuv420::avx2_rgba_to_yuv420;
#[cfg(feature = "fast_mode")]
pub(crate) use rgba_to_yuv_fast::avx2_rgba_to_yuv_dot_rgba;
#[cfg(feature = "fast_mode")]
pub(crate) use rgba_to_yuv_fast420::avx2_rgba_to_yuv_dot_rgba420;
pub(crate) use shuffle::{ShuffleConverterAvx2, ShuffleQTableConverterAvx2};
pub(crate) use y_to_rgba::avx2_y_to_rgba_row;
pub(crate) use y_to_rgba_alpha::avx2_y_to_rgba_alpha_row;
pub(crate) use yuv16_to_rgba16_bilinear::{
    avx_planar16_bilinear_1_row_rgba, avx_planar16_bilinear_2_rows_rgba,
};
pub(crate) use yuv_nv_to_rgba::avx2_yuv_nv_to_rgba_row;
pub(crate) use yuv_nv_to_rgba420::avx2_yuv_nv_to_rgba_row420;
#[cfg(feature = "professional_mode")]
pub(crate) use yuv_nv_to_rgba420_prof::avx2_yuv_nv_to_rgba_row420_prof;
pub(crate) use yuv_nv_to_rgba422::avx2_yuv_nv_to_rgba_row422;
#[cfg(feature = "fast_mode")]
pub(crate) use yuv_nv_to_rgba_fast::avx_yuv_nv_to_rgba_fast;
#[cfg(feature = "fast_mode")]
pub(crate) use yuv_nv_to_rgba_fast420::avx_yuv_nv_to_rgba_fast420;
#[cfg(feature = "professional_mode")]
pub(crate) use yuv_nv_to_rgba_prof::avx2_yuv_nv_to_rgba_row_prof;
pub(crate) use yuv_p16_to_rgb16::avx_yuv_p16_to_rgba_row;
pub(crate) use yuv_p16_to_rgb16_420::avx_yuv_p16_to_rgba_row420;
pub(crate) use yuv_p16_to_rgb16_alpha::avx_yuv_p16_to_rgba_alpha_row;
pub(crate) use yuv_p16_to_rgb8::avx_yuv_p16_to_rgba8_row;
pub(crate) use yuv_p16_to_rgb8_alpha::avx_yuv_p16_to_rgba8_alpha_row;
pub(crate) use yuv_p16_to_rgb_d16::avx_yuv_p16_to_rgba_d16_row;
pub(crate) use yuv_p16_to_rgb_d16_420::avx_yuv_p16_to_rgba_d16_row420;
#[cfg(feature = "nightly_f16")]
pub(crate) use yuv_p16_to_rgb_f16::avx_yuv_p16_to_rgba_f16_row;
pub(crate) use yuv_to_rgba::avx2_yuv_to_rgba_row;
pub(crate) use yuv_to_rgba420::avx2_yuv_to_rgba_row420;
pub(crate) use yuv_to_rgba422::avx2_yuv_to_rgba_row422;
pub(crate) use yuv_to_rgba_alpha::avx2_yuv_to_rgba_alpha;
pub(crate) use yuv_to_rgba_bilinear::{
    avx_bilinear_interpolate_1_row_rgba, avx_bilinear_interpolate_2_rows_rgba,
};
pub(crate) use yuv_to_yuv2::yuv_to_yuy2_avx2_row;
#[cfg(feature = "nightly_f16")]
pub(crate) use yuva_p16_to_rgb_f16::avx_yuva_p16_to_rgba_f16_row;
pub(crate) use yuy2_to_rgb::yuy2_to_rgb_avx;
pub(crate) use yuy2_to_yuv::yuy2_to_yuv_avx;

#[cfg(feature = "professional_mode")]
use crate::yuv_support::{CbCrForwardTransform, YuvSourceChannels};

#[cfg(feature = "professional_mode")]
impl CbCrForwardTransform<i32> {
    #[inline]
    fn avx_pack_rgba(r: i16, g: i16, b: i16, cn: YuvSourceChannels) -> i64 {
        let r = r.to_ne_bytes();
        let g = g.to_ne_bytes();
        let b = b.to_ne_bytes();
        match cn {
            YuvSourceChannels::Rgb | YuvSourceChannels::Rgba => {
                i64::from_ne_bytes([r[0], r[1], g[0], g[1], b[0], b[1], 0, 0])
            }
            YuvSourceChannels::Bgra | YuvSourceChannels::Bgr => {
                i64::from_ne_bytes([b[0], b[1], g[0], g[1], r[0], r[1], 0, 0])
            }
        }
    }

    #[inline]
    pub(crate) fn avx_make_transform_y(&self, cn: YuvSourceChannels) -> i64 {
        Self::avx_pack_rgba(self.yr as i16, self.yg as i16, self.yb as i16, cn)
    }

    #[inline]
    pub(crate) fn avx_make_transform_cb(&self, cn: YuvSourceChannels) -> i64 {
        Self::avx_pack_rgba(self.cb_r as i16, self.cb_g as i16, self.cb_b as i16, cn)
    }

    #[inline]
    fn avx_make_transform_cr(&self, cn: YuvSourceChannels) -> i64 {
        Self::avx_pack_rgba(self.cr_r as i16, self.cr_g as i16, self.cr_b as i16, cn)
    }
}
