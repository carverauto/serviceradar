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

use crate::neon::utils::*;
use crate::yuv_support::{CbCrInverseTransform, YuvPacked444Format, YuvSourceChannels};
use std::arch::aarch64::*;

#[cfg(feature = "rdm")]
#[target_feature(enable = "rdm")]
pub(crate) unsafe fn neon_ayuv_to_rgba_rdm<const DESTINATION_CHANNELS: u8, const PACKED: u8>(
    ayuv: &[u8],
    rgba: &mut [u8],
    transform: &CbCrInverseTransform<i16>,
    bias_y: i16,
    bias_uv: i16,
    width: usize,
    use_premultiply: bool,
) {
    neon_ayuv_to_rgba_impl::<DESTINATION_CHANNELS, PACKED, true>(
        ayuv,
        rgba,
        transform,
        bias_y,
        bias_uv,
        width,
        use_premultiply,
    )
}

pub(crate) unsafe fn neon_ayuv_to_rgba<const DESTINATION_CHANNELS: u8, const PACKED: u8>(
    ayuv: &[u8],
    rgba: &mut [u8],
    transform: &CbCrInverseTransform<i16>,
    bias_y: i16,
    bias_uv: i16,
    width: usize,
    use_premultiply: bool,
) {
    neon_ayuv_to_rgba_impl::<DESTINATION_CHANNELS, PACKED, false>(
        ayuv,
        rgba,
        transform,
        bias_y,
        bias_uv,
        width,
        use_premultiply,
    )
}

#[inline(always)]
unsafe fn neon_ayuv_to_rgba_impl<
    const DESTINATION_CHANNELS: u8,
    const PACKED: u8,
    const R: bool,
>(
    ayuv: &[u8],
    rgba: &mut [u8],
    transform: &CbCrInverseTransform<i16>,
    bias_y: i16,
    bias_uv: i16,
    width: usize,
    use_premultiply: bool,
) {
    let packed_ayuv: YuvPacked444Format = PACKED.into();
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = destination_channels.get_channels_count();

    let mut cx = 0usize;

    const SCALE: i32 = 2;

    let y_corr = vdupq_n_u8(bias_y as u8);
    let uv_corr = vdupq_n_u8(bias_uv as u8);

    let weights_arr: [i16; 8] = [
        transform.y_coef,
        transform.cr_coef,
        transform.cb_coef,
        transform.g_coeff_1,
        transform.g_coeff_2,
        0,
        0,
        0,
    ];

    let v_weights = vld1q_s16(weights_arr.as_ptr());

    while cx + 16 < width {
        let data_values = vld4q_u8(ayuv.get_unchecked(cx * 4..).as_ptr());

        let u_high_u8: int8x8_t;
        let v_high_u8: int8x8_t;
        let u_low_u8: int8x8_t;
        let v_low_u8: int8x8_t;
        let a_values;
        let y_values;

        match packed_ayuv {
            YuvPacked444Format::Ayuv => {
                let u_values = vsubq_u8(data_values.2, uv_corr);
                let v_values = vsubq_u8(data_values.3, uv_corr);

                u_high_u8 = vreinterpret_s8_u8(vget_high_u8(u_values));
                v_high_u8 = vreinterpret_s8_u8(vget_high_u8(v_values));
                u_low_u8 = vreinterpret_s8_u8(vget_low_u8(u_values));
                v_low_u8 = vreinterpret_s8_u8(vget_low_u8(v_values));

                a_values = data_values.0;
                y_values = data_values.1;
            }
            YuvPacked444Format::Vuya => {
                let u_values = vsubq_u8(data_values.1, uv_corr);
                let v_values = vsubq_u8(data_values.0, uv_corr);

                u_high_u8 = vreinterpret_s8_u8(vget_high_u8(u_values));
                v_high_u8 = vreinterpret_s8_u8(vget_high_u8(v_values));
                u_low_u8 = vreinterpret_s8_u8(vget_low_u8(u_values));
                v_low_u8 = vreinterpret_s8_u8(vget_low_u8(v_values));

                a_values = data_values.3;
                y_values = data_values.2;
            }
        }

        let y_values = vqsubq_u8(y_values, y_corr);

        let yhh = vexpand_high_8_to_10(y_values);
        let u_high = vshll_n_s8::<SCALE>(u_high_u8);
        let v_high = vshll_n_s8::<SCALE>(v_high_u8);
        let y_high = xqdmulhq_laneq_s16::<0, R>(vreinterpretq_s16_u16(yhh), v_weights);

        let ghc0 = xqdmulhq_laneq_s16::<3, R>(v_high, v_weights);
        let rhc0 = xqdmlahq_laneq_s16::<1, R>(y_high, v_high, v_weights);
        let bhc0 = xqdmlahq_laneq_s16::<2, R>(y_high, u_high, v_weights);
        let ghc1 = xqdmlahq_laneq_s16::<4, R>(ghc0, u_high, v_weights);
        let r_high = vqmovun_s16(rhc0);
        let b_high = vqmovun_s16(bhc0);
        let g_high = vqmovun_s16(vsubq_s16(y_high, ghc1));

        let u_low = vshll_n_s8::<SCALE>(u_low_u8);
        let v_low = vshll_n_s8::<SCALE>(v_low_u8);
        let y_v_shl = vexpand8_to_10(vget_low_u8(y_values));
        let y_low = xqdmulhq_laneq_s16::<0, R>(vreinterpretq_s16_u16(y_v_shl), v_weights);

        let glc0 = xqdmulhq_laneq_s16::<3, R>(v_low, v_weights);
        let rlc0 = xqdmlahq_laneq_s16::<1, R>(y_low, v_low, v_weights);
        let blc0 = xqdmlahq_laneq_s16::<2, R>(y_low, u_low, v_weights);
        let glc1 = xqdmlahq_laneq_s16::<4, R>(glc0, u_low, v_weights);
        let r_low = vqmovun_s16(rlc0);
        let b_low = vqmovun_s16(blc0);
        let g_low = vqmovun_s16(vsubq_s16(y_low, glc1));

        let mut r_values = vcombine_u8(r_low, r_high);
        let mut g_values = vcombine_u8(g_low, g_high);
        let mut b_values = vcombine_u8(b_low, b_high);

        let dst_shift = cx * channels;

        if use_premultiply {
            r_values = neon_premultiply_alpha(r_values, a_values);
            g_values = neon_premultiply_alpha(g_values, a_values);
            b_values = neon_premultiply_alpha(b_values, a_values);
        }

        neon_store_rgb8::<DESTINATION_CHANNELS>(
            rgba.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            r_values,
            g_values,
            b_values,
            a_values,
        );

        cx += 16;
    }

    if cx < width {
        let diff = width - cx;

        assert!(diff <= 16);

        let mut dst_buffer: [u8; 16 * 4] = [0; 16 * 4];
        let mut src_buffer: [u8; 16 * 4] = [0; 16 * 4];

        std::ptr::copy_nonoverlapping(
            ayuv.get_unchecked(cx * 4..).as_ptr(),
            src_buffer.as_mut_ptr().cast(),
            diff * 4,
        );

        let data_values = vld4q_u8(src_buffer.as_ptr().cast());

        let u_high_u8: int8x8_t;
        let v_high_u8: int8x8_t;
        let u_low_u8: int8x8_t;
        let v_low_u8: int8x8_t;
        let a_values;
        let y_values;

        match packed_ayuv {
            YuvPacked444Format::Ayuv => {
                let u_values = vsubq_u8(data_values.2, uv_corr);
                let v_values = vsubq_u8(data_values.3, uv_corr);

                u_high_u8 = vreinterpret_s8_u8(vget_high_u8(u_values));
                v_high_u8 = vreinterpret_s8_u8(vget_high_u8(v_values));
                u_low_u8 = vreinterpret_s8_u8(vget_low_u8(u_values));
                v_low_u8 = vreinterpret_s8_u8(vget_low_u8(v_values));

                a_values = data_values.0;
                y_values = data_values.1;
            }
            YuvPacked444Format::Vuya => {
                let u_values = vsubq_u8(data_values.1, uv_corr);
                let v_values = vsubq_u8(data_values.0, uv_corr);

                u_high_u8 = vreinterpret_s8_u8(vget_high_u8(u_values));
                v_high_u8 = vreinterpret_s8_u8(vget_high_u8(v_values));
                u_low_u8 = vreinterpret_s8_u8(vget_low_u8(u_values));
                v_low_u8 = vreinterpret_s8_u8(vget_low_u8(v_values));

                a_values = data_values.3;
                y_values = data_values.2;
            }
        }

        let y_values = vqsubq_u8(y_values, y_corr);

        let yhh = vexpand_high_8_to_10(y_values);
        let u_high = vshll_n_s8::<SCALE>(u_high_u8);
        let v_high = vshll_n_s8::<SCALE>(v_high_u8);
        let y_high = xqdmulhq_laneq_s16::<0, R>(vreinterpretq_s16_u16(yhh), v_weights);

        let ghc0 = xqdmulhq_laneq_s16::<3, R>(v_high, v_weights);
        let rhc0 = xqdmlahq_laneq_s16::<1, R>(y_high, v_high, v_weights);
        let bhc0 = xqdmlahq_laneq_s16::<2, R>(y_high, u_high, v_weights);
        let ghc1 = xqdmlahq_laneq_s16::<4, R>(ghc0, u_high, v_weights);
        let r_high = vqmovun_s16(rhc0);
        let b_high = vqmovun_s16(bhc0);
        let g_high = vqmovun_s16(vsubq_s16(y_high, ghc1));

        let u_low = vshll_n_s8::<SCALE>(u_low_u8);
        let v_low = vshll_n_s8::<SCALE>(v_low_u8);
        let y_v_shl = vexpand8_to_10(vget_low_u8(y_values));
        let y_low = xqdmulhq_laneq_s16::<0, R>(vreinterpretq_s16_u16(y_v_shl), v_weights);

        let glc0 = xqdmulhq_laneq_s16::<3, R>(v_low, v_weights);
        let rlc0 = xqdmlahq_laneq_s16::<1, R>(y_low, v_low, v_weights);
        let blc0 = xqdmlahq_laneq_s16::<2, R>(y_low, u_low, v_weights);
        let glc1 = xqdmlahq_laneq_s16::<4, R>(glc0, u_low, v_weights);
        let r_low = vqmovun_s16(rlc0);
        let b_low = vqmovun_s16(blc0);
        let g_low = vqmovun_s16(vsubq_s16(y_low, glc1));

        let mut r_values = vcombine_u8(r_low, r_high);
        let mut g_values = vcombine_u8(g_low, g_high);
        let mut b_values = vcombine_u8(b_low, b_high);

        if use_premultiply {
            r_values = neon_premultiply_alpha(r_values, a_values);
            g_values = neon_premultiply_alpha(g_values, a_values);
            b_values = neon_premultiply_alpha(b_values, a_values);
        }

        neon_store_rgb8::<DESTINATION_CHANNELS>(
            dst_buffer.as_mut_ptr().cast(),
            r_values,
            g_values,
            b_values,
            a_values,
        );

        let dst_shift = cx * channels;
        std::ptr::copy_nonoverlapping(
            dst_buffer.as_mut_ptr().cast(),
            rgba.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            diff * channels,
        );
    }
}
