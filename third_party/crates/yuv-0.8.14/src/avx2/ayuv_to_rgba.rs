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

use crate::avx2::avx2_utils::*;
use crate::yuv_support::{CbCrInverseTransform, YuvPacked444Format, YuvSourceChannels};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn avx2_ayuv_to_rgba<const DESTINATION_CHANNELS: u8, const PACKING: u8>(
    ayuv: &[u8],
    rgba: &mut [u8],
    transform: &CbCrInverseTransform<i16>,
    bias_y: i16,
    bias_uv: i16,
    width: usize,
    use_premultiply: bool,
) {
    unsafe {
        avx2_ayuv_to_rgba_impl::<DESTINATION_CHANNELS, PACKING>(
            ayuv,
            rgba,
            transform,
            bias_y,
            bias_uv,
            width,
            use_premultiply,
        )
    }
}

#[inline(always)]
unsafe fn _mm256_load_deintl_ayuv<const PACKED: u8>(
    src: &[u8],
) -> (__m256i, __m256i, __m256i, __m256i) {
    let packing: YuvPacked444Format = PACKED.into();

    let r0 = _mm256_loadu_si256(src.as_ptr() as *const __m256i);
    let r1 = _mm256_loadu_si256(src.get_unchecked(32..).as_ptr() as *const __m256i);
    let r2 = _mm256_loadu_si256(src.get_unchecked(64..).as_ptr() as *const __m256i);
    let r3 = _mm256_loadu_si256(src.get_unchecked(96..).as_ptr() as *const __m256i);
    let (a0, a1, a2, a3) = _mm256_deinterleave_rgba_epi8(r0, r1, r2, r3);

    match packing {
        YuvPacked444Format::Ayuv => (a0, a1, a2, a3),
        YuvPacked444Format::Vuya => (a3, a2, a1, a0),
    }
}

#[target_feature(enable = "avx2")]
unsafe fn avx2_ayuv_to_rgba_impl<const DESTINATION_CHANNELS: u8, const PACKED: u8>(
    ayuv: &[u8],
    rgba: &mut [u8],
    transform: &CbCrInverseTransform<i16>,
    bias_y: i16,
    bias_uv: i16,
    width: usize,
    use_premultiply: bool,
) {
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = destination_channels.get_channels_count();

    let mut cx = 0usize;
    let rgba_ptr = rgba.as_mut_ptr();

    let y_corr = _mm256_set1_epi8(bias_y as i8);
    let uv_corr = _mm256_set1_epi16(((bias_uv) << 2) | ((bias_uv) >> 6));
    let v_luma_coeff = _mm256_set1_epi16(transform.y_coef);
    let v_cr_coeff = _mm256_set1_epi16(transform.cr_coef);
    let v_cb_coeff = _mm256_set1_epi16(transform.cb_coef);
    let v_g_coeff_1 = _mm256_set1_epi16(transform.g_coeff_1);
    let v_g_coeff_2 = _mm256_set1_epi16(transform.g_coeff_2);

    while cx + 32 <= width {
        let (a, mut y_vals, u, v) = _mm256_load_deintl_ayuv::<PACKED>(ayuv.get_unchecked(cx * 4..));

        y_vals = _mm256_subs_epu8(y_vals, y_corr);

        let u_high_u16 = _mm256_srli_epi16::<6>(_mm256_unpackhi_epi8(u, u));
        let v_high_u16 = _mm256_srli_epi16::<6>(_mm256_unpackhi_epi8(v, v));
        let u_low_u16 = _mm256_srli_epi16::<6>(_mm256_unpacklo_epi8(u, u));
        let v_low_u16 = _mm256_srli_epi16::<6>(_mm256_unpacklo_epi8(v, v));

        let y0_10 = _mm256_expand8_unordered_to_10(y_vals);

        let u_high = _mm256_sub_epi16(u_high_u16, uv_corr);
        let v_high = _mm256_sub_epi16(v_high_u16, uv_corr);
        let y_high = _mm256_mulhrs_epi16(y0_10.1, v_luma_coeff);

        let rhc = _mm256_mulhrs_epi16(v_high, v_cr_coeff);
        let bhc = _mm256_mulhrs_epi16(u_high, v_cb_coeff);
        let ghc0 = _mm256_mulhrs_epi16(v_high, v_g_coeff_1);
        let ghc1 = _mm256_mulhrs_epi16(u_high, v_g_coeff_2);

        let r_high = _mm256_add_epi16(y_high, rhc);
        let b_high = _mm256_add_epi16(y_high, bhc);
        let g_high = _mm256_sub_epi16(y_high, _mm256_add_epi16(ghc0, ghc1));

        let u_low = _mm256_sub_epi16(u_low_u16, uv_corr);
        let v_low = _mm256_sub_epi16(v_low_u16, uv_corr);
        let y_low = _mm256_mulhrs_epi16(y0_10.0, v_luma_coeff);

        let rlc = _mm256_mulhrs_epi16(v_low, v_cr_coeff);
        let blc = _mm256_mulhrs_epi16(u_low, v_cb_coeff);
        let glc0 = _mm256_mulhrs_epi16(v_low, v_g_coeff_1);
        let glc1 = _mm256_mulhrs_epi16(u_low, v_g_coeff_2);

        let r_low = _mm256_add_epi16(y_low, rlc);
        let b_low = _mm256_add_epi16(y_low, blc);
        let g_low = _mm256_sub_epi16(y_low, _mm256_add_epi16(glc0, glc1));

        let mut r_values = _mm256_packus_epi16(r_low, r_high);
        let mut g_values = _mm256_packus_epi16(g_low, g_high);
        let mut b_values = _mm256_packus_epi16(b_low, b_high);

        if use_premultiply {
            let a_high = _mm256_unpackhi_epi8(a, _mm256_setzero_si256());
            let a_low = _mm256_unpacklo_epi8(a, _mm256_setzero_si256());

            let r_low = _mm256_unpacklo_epi8(r_values, _mm256_setzero_si256());
            let r_high = _mm256_unpackhi_epi8(r_values, _mm256_setzero_si256());
            let g_low = _mm256_unpacklo_epi8(g_values, _mm256_setzero_si256());
            let g_high = _mm256_unpackhi_epi8(g_values, _mm256_setzero_si256());
            let b_low = _mm256_unpacklo_epi8(b_values, _mm256_setzero_si256());
            let b_high = _mm256_unpackhi_epi8(b_values, _mm256_setzero_si256());

            let (r_l, r_h) = avx2_div_by255_x2(
                _mm256_mullo_epi16(r_low, a_low),
                _mm256_mullo_epi16(r_high, a_high),
            );
            let (g_l, g_h) = avx2_div_by255_x2(
                _mm256_mullo_epi16(g_low, a_low),
                _mm256_mullo_epi16(g_high, a_high),
            );
            let (b_l, b_h) = avx2_div_by255_x2(
                _mm256_mullo_epi16(b_low, a_low),
                _mm256_mullo_epi16(b_high, a_high),
            );

            r_values = _mm256_packus_epi16(r_l, r_h);
            g_values = _mm256_packus_epi16(g_l, g_h);
            b_values = _mm256_packus_epi16(b_l, b_h);
        }

        let dst_shift = cx * channels;

        _mm256_store_interleave_rgb_for_yuv::<DESTINATION_CHANNELS>(
            rgba_ptr.add(dst_shift),
            r_values,
            g_values,
            b_values,
            a,
        );

        cx += 32;
    }

    if cx < width {
        let diff = width - cx;

        assert!(diff <= 32);

        let mut dst_buffer: [u8; 32 * 4] = [0; 32 * 4];
        let mut src_buffer: [u8; 32 * 4] = [0; 32 * 4];

        std::ptr::copy_nonoverlapping(
            ayuv.get_unchecked(cx * 4..).as_ptr(),
            src_buffer.as_mut_ptr().cast(),
            diff * 4,
        );

        let (a, mut y_vals, u, v) = _mm256_load_deintl_ayuv::<PACKED>(src_buffer.as_slice());

        y_vals = _mm256_subs_epu8(y_vals, y_corr);

        let u_high_u16 = _mm256_srli_epi16::<6>(_mm256_unpackhi_epi8(u, u));
        let v_high_u16 = _mm256_srli_epi16::<6>(_mm256_unpackhi_epi8(v, v));
        let u_low_u16 = _mm256_srli_epi16::<6>(_mm256_unpacklo_epi8(u, u));
        let v_low_u16 = _mm256_srli_epi16::<6>(_mm256_unpacklo_epi8(v, v));

        let y0_10 = _mm256_expand8_unordered_to_10(y_vals);

        let u_high = _mm256_sub_epi16(u_high_u16, uv_corr);
        let v_high = _mm256_sub_epi16(v_high_u16, uv_corr);
        let y_high = _mm256_mulhrs_epi16(y0_10.1, v_luma_coeff);

        let rhc = _mm256_mulhrs_epi16(v_high, v_cr_coeff);
        let bhc = _mm256_mulhrs_epi16(u_high, v_cb_coeff);
        let ghc0 = _mm256_mulhrs_epi16(v_high, v_g_coeff_1);
        let ghc1 = _mm256_mulhrs_epi16(u_high, v_g_coeff_2);

        let r_high = _mm256_add_epi16(y_high, rhc);
        let b_high = _mm256_add_epi16(y_high, bhc);
        let g_high = _mm256_sub_epi16(y_high, _mm256_add_epi16(ghc0, ghc1));

        let u_low = _mm256_sub_epi16(u_low_u16, uv_corr);
        let v_low = _mm256_sub_epi16(v_low_u16, uv_corr);
        let y_low = _mm256_mulhrs_epi16(y0_10.0, v_luma_coeff);

        let rlc = _mm256_mulhrs_epi16(v_low, v_cr_coeff);
        let blc = _mm256_mulhrs_epi16(u_low, v_cb_coeff);
        let glc0 = _mm256_mulhrs_epi16(v_low, v_g_coeff_1);
        let glc1 = _mm256_mulhrs_epi16(u_low, v_g_coeff_2);

        let r_low = _mm256_add_epi16(y_low, rlc);
        let b_low = _mm256_add_epi16(y_low, blc);
        let g_low = _mm256_sub_epi16(y_low, _mm256_add_epi16(glc0, glc1));

        let (r_values, g_values, b_values);

        if use_premultiply {
            let a_high = _mm256_unpackhi_epi8(a, _mm256_setzero_si256());
            let a_low = _mm256_unpacklo_epi8(a, _mm256_setzero_si256());

            let (r_l, r_h) = avx2_div_by255_x2(
                _mm256_mullo_epi16(r_low, a_low),
                _mm256_mullo_epi16(r_high, a_high),
            );
            let (g_l, g_h) = avx2_div_by255_x2(
                _mm256_mullo_epi16(g_low, a_low),
                _mm256_mullo_epi16(g_high, a_high),
            );
            let (b_l, b_h) = avx2_div_by255_x2(
                _mm256_mullo_epi16(b_low, a_low),
                _mm256_mullo_epi16(b_high, a_high),
            );

            r_values = _mm256_packus_epi16(r_l, r_h);
            g_values = _mm256_packus_epi16(g_l, g_h);
            b_values = _mm256_packus_epi16(b_l, b_h);
        } else {
            r_values = _mm256_packus_epi16(r_low, r_high);
            g_values = _mm256_packus_epi16(g_low, g_high);
            b_values = _mm256_packus_epi16(b_low, b_high);
        }

        _mm256_store_interleave_rgb_for_yuv::<DESTINATION_CHANNELS>(
            dst_buffer.as_mut_ptr().cast(),
            r_values,
            g_values,
            b_values,
            a,
        );

        let dst_shift = cx * channels;
        std::ptr::copy_nonoverlapping(
            dst_buffer.as_mut_ptr().cast(),
            rgba.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            diff * channels,
        );
    }
}
