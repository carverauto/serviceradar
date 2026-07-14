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

use crate::internals::ProcessedOffset;
use crate::neon::utils::*;
use crate::yuv_support::{
    CbCrInverseTransform, YuvChromaRange, YuvChromaSubsampling, YuvSourceChannels,
};
use std::arch::aarch64::*;

#[cfg(feature = "rdm")]
#[target_feature(enable = "rdm")]
pub(crate) unsafe fn neon_yuv_to_rgba_alpha_rdm<
    const DESTINATION_CHANNELS: u8,
    const SAMPLING: u8,
>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane: &[u8],
    u_plane: &[u8],
    v_plane: &[u8],
    a_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
    use_premultiply: bool,
) -> ProcessedOffset {
    neon_yuv_to_rgba_alpha_impl::<DESTINATION_CHANNELS, SAMPLING, true>(
        range,
        transform,
        y_plane,
        u_plane,
        v_plane,
        a_plane,
        rgba,
        start_cx,
        start_ux,
        width,
        use_premultiply,
    )
}

pub(crate) unsafe fn neon_yuv_to_rgba_alpha<const DESTINATION_CHANNELS: u8, const SAMPLING: u8>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane: &[u8],
    u_plane: &[u8],
    v_plane: &[u8],
    a_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
    use_premultiply: bool,
) -> ProcessedOffset {
    neon_yuv_to_rgba_alpha_impl::<DESTINATION_CHANNELS, SAMPLING, false>(
        range,
        transform,
        y_plane,
        u_plane,
        v_plane,
        a_plane,
        rgba,
        start_cx,
        start_ux,
        width,
        use_premultiply,
    )
}

#[inline(always)]
unsafe fn neon_yuv_to_rgba_alpha_impl<
    const DESTINATION_CHANNELS: u8,
    const SAMPLING: u8,
    const R: bool,
>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane: &[u8],
    u_plane: &[u8],
    v_plane: &[u8],
    a_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
    use_premultiply: bool,
) -> ProcessedOffset {
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    assert!(
        destination_channels == YuvSourceChannels::Rgba
            || destination_channels == YuvSourceChannels::Bgra,
        "Cannot call YUV to Rgb with alpha without real alpha"
    );
    let channels = destination_channels.get_channels_count();

    let mut cx = start_cx;
    let mut uv_x = start_ux;
    let y_ptr = y_plane.as_ptr();
    let u_ptr = u_plane.as_ptr();
    let v_ptr = v_plane.as_ptr();
    let a_ptr = a_plane.as_ptr();
    let rgba_ptr = rgba.as_mut_ptr();

    const SCALE: i32 = 2;

    let y_corr = vdupq_n_u8(range.bias_y as u8);
    let uv_corr = vdupq_n_u8(range.bias_uv as u8);

    let weights_arr: [i16; 8] = [
        transform.y_coef as i16,
        transform.cr_coef as i16,
        transform.cb_coef as i16,
        transform.g_coeff_1 as i16,
        transform.g_coeff_2 as i16,
        0,
        0,
        0,
    ];

    let v_weights = vld1q_s16(weights_arr.as_ptr());

    while cx + 32 <= width {
        let mut y_set = xvld1q_u8_x2(y_ptr.add(cx));

        let u_high_u8: int8x16_t;
        let v_high_u8: int8x16_t;
        let u_low_u8: int8x16_t;
        let v_low_u8: int8x16_t;

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let mut u_values = vld1q_u8(u_ptr.add(uv_x));
                let mut v_values = vld1q_u8(v_ptr.add(uv_x));

                u_values = vsubq_u8(u_values, uv_corr);
                v_values = vsubq_u8(v_values, uv_corr);

                u_high_u8 = vreinterpretq_s8_u8(vzip2q_u8(u_values, u_values));
                v_high_u8 = vreinterpretq_s8_u8(vzip2q_u8(v_values, v_values));
                u_low_u8 = vreinterpretq_s8_u8(vzip1q_u8(u_values, u_values));
                v_low_u8 = vreinterpretq_s8_u8(vzip1q_u8(v_values, v_values));
            }
            YuvChromaSubsampling::Yuv444 => {
                let mut u_values = xvld1q_u8_x2(u_ptr.add(uv_x));
                let mut v_values = xvld1q_u8_x2(v_ptr.add(uv_x));

                u_values.0 = vsubq_u8(u_values.0, uv_corr);
                v_values.0 = vsubq_u8(v_values.0, uv_corr);
                u_values.1 = vsubq_u8(u_values.1, uv_corr);
                v_values.1 = vsubq_u8(v_values.1, uv_corr);

                u_high_u8 = vreinterpretq_s8_u8(u_values.1);
                v_high_u8 = vreinterpretq_s8_u8(v_values.1);
                u_low_u8 = vreinterpretq_s8_u8(u_values.0);
                v_low_u8 = vreinterpretq_s8_u8(v_values.0);
            }
        }

        y_set.0 = vqsubq_u8(y_set.0, y_corr);
        y_set.1 = vqsubq_u8(y_set.1, y_corr);

        let yh0 = vreinterpretq_s16_u16(vexpand8_to_10(vget_low_u8(y_set.1)));
        let u_high0 = vshll_n_s8::<SCALE>(vget_low_s8(u_high_u8));
        let v_high0 = vshll_n_s8::<SCALE>(vget_low_s8(v_high_u8));
        let y_high0 = xqdmulhq_laneq_s16::<0, R>(yh0, v_weights);

        let yh1 = vreinterpretq_s16_u16(vexpand_high_8_to_10(y_set.1));
        let u_high1 = vshll_high_n_s8::<SCALE>(u_high_u8);
        let v_high1 = vshll_high_n_s8::<SCALE>(v_high_u8);
        let y_high1 = xqdmulhq_laneq_s16::<0, R>(yh1, v_weights);

        let ghc1 = xqdmulhq_laneq_s16::<3, R>(v_high1, v_weights);
        let rhc1 = xqdmlahq_laneq_s16::<1, R>(y_high1, v_high1, v_weights);
        let bhc1 = xqdmlahq_laneq_s16::<2, R>(y_high1, u_high1, v_weights);
        let ghc2 = xqdmlahq_laneq_s16::<4, R>(ghc1, u_high1, v_weights);
        let r_high1 = vqmovun_s16(rhc1);
        let b_high1 = vqmovun_s16(bhc1);
        let g_high1 = vqmovun_s16(vsubq_s16(y_high1, ghc2));

        let ghc0 = xqdmulhq_laneq_s16::<3, R>(v_high0, v_weights);
        let rhc0 = xqdmlahq_laneq_s16::<1, R>(y_high0, v_high0, v_weights);
        let bhc0 = xqdmlahq_laneq_s16::<2, R>(y_high0, u_high0, v_weights);
        let ghc01 = xqdmlahq_laneq_s16::<4, R>(ghc0, u_high0, v_weights);
        let r_high0 = vqmovun_s16(rhc0);
        let b_high0 = vqmovun_s16(bhc0);
        let g_high0 = vqmovun_s16(vsubq_s16(y_high0, ghc01));

        let yll0 = vexpand8_to_10(vget_low_u8(y_set.0));
        let u_low0 = vshll_n_s8::<SCALE>(vget_low_s8(u_low_u8));
        let v_low0 = vshll_n_s8::<SCALE>(vget_low_s8(v_low_u8));
        let y_low0 = xqdmulhq_laneq_s16::<0, R>(vreinterpretq_s16_u16(yll0), v_weights);

        let yll1 = vexpand_high_8_to_10(y_set.0);
        let u_low1 = vshll_high_n_s8::<SCALE>(u_low_u8);
        let v_low1 = vshll_high_n_s8::<SCALE>(v_low_u8);
        let y_low1 = xqdmulhq_laneq_s16::<0, R>(vreinterpretq_s16_u16(yll1), v_weights);

        let glc0 = xqdmulhq_laneq_s16::<3, R>(v_low0, v_weights);
        let rlc0 = xqdmlahq_laneq_s16::<1, R>(y_low0, v_low0, v_weights);
        let blc0 = xqdmlahq_laneq_s16::<2, R>(y_low0, u_low0, v_weights);
        let glc01 = xqdmlahq_laneq_s16::<4, R>(glc0, u_low0, v_weights);
        let r_low0 = vqmovun_s16(rlc0);
        let b_low0 = vqmovun_s16(blc0);
        let g_low0 = vqmovun_s16(vsubq_s16(y_low0, glc01));

        let glc1 = xqdmulhq_laneq_s16::<3, R>(v_low1, v_weights);
        let rlc11 = xqdmlahq_laneq_s16::<1, R>(y_low1, v_low1, v_weights);
        let blc11 = xqdmlahq_laneq_s16::<2, R>(y_low1, u_low1, v_weights);
        let glc11 = xqdmlahq_laneq_s16::<4, R>(glc1, u_low1, v_weights);
        let r_low1 = vqmovun_s16(rlc11);
        let b_low1 = vqmovun_s16(blc11);
        let g_low1 = vqmovun_s16(vsubq_s16(y_low1, glc11));

        let mut r_high = vcombine_u8(r_high0, r_high1);
        let mut g_high = vcombine_u8(g_high0, g_high1);
        let mut b_high = vcombine_u8(b_high0, b_high1);

        let mut r_low = vcombine_u8(r_low0, r_low1);
        let mut g_low = vcombine_u8(g_low0, g_low1);
        let mut b_low = vcombine_u8(b_low0, b_low1);

        let a_values = xvld1q_u8_x2(a_ptr.add(cx));

        if use_premultiply {
            r_high = neon_premultiply_alpha(r_high, a_values.0);
            g_high = neon_premultiply_alpha(g_high, a_values.0);
            b_high = neon_premultiply_alpha(b_high, a_values.0);

            r_low = neon_premultiply_alpha(r_low, a_values.1);
            g_low = neon_premultiply_alpha(g_low, a_values.1);
            b_low = neon_premultiply_alpha(b_low, a_values.1);
        }

        let dst_shift = cx * channels;

        neon_store_rgb8::<DESTINATION_CHANNELS>(
            rgba_ptr.add(dst_shift),
            r_low,
            g_low,
            b_low,
            a_values.0,
        );

        neon_store_rgb8::<DESTINATION_CHANNELS>(
            rgba_ptr.add(dst_shift + channels * 16),
            r_high,
            g_high,
            b_high,
            a_values.1,
        );

        cx += 32;

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                uv_x += 16;
            }
            YuvChromaSubsampling::Yuv444 => {
                uv_x += 32;
            }
        }
    }

    while cx + 16 <= width {
        let ylv = vld1q_u8(y_ptr.add(cx));
        let a_values = vld1q_u8(a_ptr.add(cx));

        let u_high_u8: int8x8_t;
        let v_high_u8: int8x8_t;
        let u_low_u8: int8x8_t;
        let v_low_u8: int8x8_t;

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let mut u_values = vld1_u8(u_ptr.add(uv_x));
                let mut v_values = vld1_u8(v_ptr.add(uv_x));

                u_values = vsub_u8(u_values, vget_low_u8(uv_corr));
                v_values = vsub_u8(v_values, vget_low_u8(uv_corr));

                u_high_u8 = vreinterpret_s8_u8(vzip2_u8(u_values, u_values));
                v_high_u8 = vreinterpret_s8_u8(vzip2_u8(v_values, v_values));
                u_low_u8 = vreinterpret_s8_u8(vzip1_u8(u_values, u_values));
                v_low_u8 = vreinterpret_s8_u8(vzip1_u8(v_values, v_values));
            }
            YuvChromaSubsampling::Yuv444 => {
                let mut u_values = vld1q_u8(u_ptr.add(uv_x));
                let mut v_values = vld1q_u8(v_ptr.add(uv_x));

                u_values = vsubq_u8(u_values, uv_corr);
                v_values = vsubq_u8(v_values, uv_corr);

                u_high_u8 = vreinterpret_s8_u8(vget_high_u8(u_values));
                v_high_u8 = vreinterpret_s8_u8(vget_high_u8(v_values));
                u_low_u8 = vreinterpret_s8_u8(vget_low_u8(u_values));
                v_low_u8 = vreinterpret_s8_u8(vget_low_u8(v_values));
            }
        }

        let y_values = vqsubq_u8(ylv, y_corr);

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
            rgba_ptr.add(dst_shift),
            r_values,
            g_values,
            b_values,
            a_values,
        );

        cx += 16;

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                uv_x += 8;
            }
            YuvChromaSubsampling::Yuv444 => {
                uv_x += 16;
            }
        }
    }

    if cx < width {
        let diff = width - cx;

        assert!(diff <= 16);

        let mut dst_buffer: [u8; 16 * 4] = [0; 16 * 4];
        let mut y_buffer: [u8; 16] = [0; 16];
        let mut u_buffer: [u8; 16] = [0; 16];
        let mut v_buffer: [u8; 16] = [0; 16];
        let mut a_buffer: [u8; 16] = [0; 16];

        std::ptr::copy_nonoverlapping(
            y_plane.get_unchecked(cx..).as_ptr(),
            y_buffer.as_mut_ptr().cast(),
            diff,
        );

        let ux_diff = match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => diff.div_ceil(2),
            YuvChromaSubsampling::Yuv444 => diff,
        };

        std::ptr::copy_nonoverlapping(
            a_plane.get_unchecked(cx..).as_ptr(),
            a_buffer.as_mut_ptr().cast(),
            diff,
        );

        std::ptr::copy_nonoverlapping(
            u_plane.get_unchecked(uv_x..).as_ptr(),
            u_buffer.as_mut_ptr().cast(),
            ux_diff,
        );

        std::ptr::copy_nonoverlapping(
            v_plane.get_unchecked(uv_x..).as_ptr(),
            v_buffer.as_mut_ptr().cast(),
            ux_diff,
        );

        let ylv = vld1q_u8(y_buffer.as_ptr().cast());
        let a_values = vld1q_u8(a_buffer.as_ptr().cast());

        let u_high_u8: int8x8_t;
        let v_high_u8: int8x8_t;
        let u_low_u8: int8x8_t;
        let v_low_u8: int8x8_t;

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let mut u_values = vld1_u8(u_buffer.as_ptr().cast());
                let mut v_values = vld1_u8(v_buffer.as_ptr().cast());

                u_values = vsub_u8(u_values, vget_low_u8(uv_corr));
                v_values = vsub_u8(v_values, vget_low_u8(uv_corr));

                u_high_u8 = vreinterpret_s8_u8(vzip2_u8(u_values, u_values));
                v_high_u8 = vreinterpret_s8_u8(vzip2_u8(v_values, v_values));
                u_low_u8 = vreinterpret_s8_u8(vzip1_u8(u_values, u_values));
                v_low_u8 = vreinterpret_s8_u8(vzip1_u8(v_values, v_values));
            }
            YuvChromaSubsampling::Yuv444 => {
                let mut u_values = vld1q_u8(u_buffer.as_ptr().cast());
                let mut v_values = vld1q_u8(v_buffer.as_ptr().cast());

                u_values = vsubq_u8(u_values, uv_corr);
                v_values = vsubq_u8(v_values, uv_corr);

                u_high_u8 = vreinterpret_s8_u8(vget_high_u8(u_values));
                v_high_u8 = vreinterpret_s8_u8(vget_high_u8(v_values));
                u_low_u8 = vreinterpret_s8_u8(vget_low_u8(u_values));
                v_low_u8 = vreinterpret_s8_u8(vget_low_u8(v_values));
            }
        }

        let y_values = vqsubq_u8(ylv, y_corr);

        let yhh = vexpand_high_8_to_10(y_values);
        let u_high = vshll_n_s8::<SCALE>(u_high_u8);
        let v_high = vshll_n_s8::<SCALE>(v_high_u8);
        let y_high = xqdmulhq_laneq_s16::<0, R>(vreinterpretq_s16_u16(yhh), v_weights);

        let ghc0 = xqdmulhq_laneq_s16::<3, R>(v_high, v_weights);
        let rhc0 = xqdmlahq_laneq_s16::<1, R>(y_high, v_high, v_weights);
        let bhc0 = xqdmlahq_laneq_s16::<2, R>(y_high, u_high, v_weights);
        let ghc01 = xqdmlahq_laneq_s16::<4, R>(ghc0, u_high, v_weights);
        let r_high = vqmovun_s16(rhc0);
        let b_high = vqmovun_s16(bhc0);
        let g_high = vqmovun_s16(vsubq_s16(y_high, ghc01));

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

        cx += diff;
        uv_x += ux_diff;
    }

    ProcessedOffset { cx, ux: uv_x }
}
