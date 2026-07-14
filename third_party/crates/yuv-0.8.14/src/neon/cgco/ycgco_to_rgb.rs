/*
 * Copyright (c) Radzivon Bartoshyk, 2/2025. All rights reserved.
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
use crate::neon::utils::neon_store_rgb8;
use crate::yuv_support::{YuvChromaRange, YuvSourceChannels};
use crate::YuvChromaSubsampling;
use std::arch::aarch64::*;

pub(crate) unsafe fn neon_ycgco_full_range_to_rgb<
    const DESTINATION_CHANNELS: u8,
    const SAMPLING: u8,
>(
    y_plane: &[u8],
    u_plane: &[u8],
    v_plane: &[u8],
    rgba: &mut [u8],
    width: usize,
    chroma_range: YuvChromaRange,
) -> ProcessedOffset {
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = destination_channels.get_channels_count();

    let mut cx = 0;
    let mut uv_x = 0;

    let y_ptr = y_plane.as_ptr();
    let u_ptr = u_plane.as_ptr();
    let v_ptr = v_plane.as_ptr();
    let rgba_ptr = rgba.as_mut_ptr();

    let bias_y = vdupq_n_u8(chroma_range.bias_y as u8);
    let bias_uv = vdupq_n_u8(chroma_range.bias_uv as u8);

    while cx + 16 <= width {
        let mut y_values = vld1q_u8(y_ptr.add(cx));

        let u_high_u8: uint8x8_t;
        let v_high_u8: uint8x8_t;
        let u_low_u8: uint8x8_t;
        let v_low_u8: uint8x8_t;

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let mut u_values = vld1_u8(u_ptr.add(uv_x));
                let mut v_values = vld1_u8(v_ptr.add(uv_x));

                u_values = vsub_u8(u_values, vget_low_u8(bias_uv));
                v_values = vsub_u8(v_values, vget_low_u8(bias_uv));

                u_high_u8 = vzip2_u8(u_values, u_values);
                v_high_u8 = vzip2_u8(v_values, v_values);
                u_low_u8 = vzip1_u8(u_values, u_values);
                v_low_u8 = vzip1_u8(v_values, v_values);
            }
            YuvChromaSubsampling::Yuv444 => {
                let mut u_values = vld1q_u8(u_ptr.add(uv_x));
                let mut v_values = vld1q_u8(v_ptr.add(uv_x));

                u_values = vsubq_u8(u_values, bias_uv);
                v_values = vsubq_u8(v_values, bias_uv);

                u_high_u8 = vget_high_u8(u_values);
                v_high_u8 = vget_high_u8(v_values);
                u_low_u8 = vget_low_u8(u_values);
                v_low_u8 = vget_low_u8(v_values);
            }
        }

        y_values = vqsubq_u8(y_values, bias_y);

        let y_high = vreinterpretq_s16_u16(vmovl_high_u8(y_values));
        let y_low = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(y_values)));

        let u_high = vmovl_s8(vreinterpret_s8_u8(u_high_u8));
        let v_high = vmovl_s8(vreinterpret_s8_u8(v_high_u8));
        let u_low = vmovl_s8(vreinterpret_s8_u8(u_low_u8));
        let v_low = vmovl_s8(vreinterpret_s8_u8(v_low_u8));

        let t_high = vsubq_s16(y_high, u_high);
        let t_low = vsubq_s16(y_low, u_low);

        let r_h = vaddq_s16(t_high, v_high);
        let r_l = vaddq_s16(t_low, v_low);
        let b_h = vsubq_s16(t_high, v_high);
        let b_l = vsubq_s16(t_low, v_low);
        let g_h = vaddq_s16(y_high, u_high);
        let g_l = vaddq_s16(y_low, u_low);

        let r_values = vcombine_u8(vqmovun_s16(r_l), vqmovun_s16(r_h));
        let g_values = vcombine_u8(vqmovun_s16(g_l), vqmovun_s16(g_h));
        let b_values = vcombine_u8(vqmovun_s16(b_l), vqmovun_s16(b_h));

        let dst_shift = cx * channels;

        neon_store_rgb8::<DESTINATION_CHANNELS>(
            rgba_ptr.add(dst_shift),
            r_values,
            g_values,
            b_values,
            vdupq_n_u8(255),
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
            u_plane.get_unchecked(uv_x..).as_ptr(),
            u_buffer.as_mut_ptr().cast(),
            ux_diff,
        );

        std::ptr::copy_nonoverlapping(
            v_plane.get_unchecked(uv_x..).as_ptr(),
            v_buffer.as_mut_ptr().cast(),
            ux_diff,
        );

        let mut y_values = vld1q_u8(y_buffer.as_ptr().cast());

        let u_high_u8: uint8x8_t;
        let v_high_u8: uint8x8_t;
        let u_low_u8: uint8x8_t;
        let v_low_u8: uint8x8_t;

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let mut u_values = vld1_u8(u_buffer.as_ptr().cast());
                let mut v_values = vld1_u8(v_buffer.as_ptr().cast());

                u_values = vsub_u8(u_values, vget_low_u8(bias_uv));
                v_values = vsub_u8(v_values, vget_low_u8(bias_uv));

                u_high_u8 = vzip2_u8(u_values, u_values);
                v_high_u8 = vzip2_u8(v_values, v_values);
                u_low_u8 = vzip1_u8(u_values, u_values);
                v_low_u8 = vzip1_u8(v_values, v_values);
            }
            YuvChromaSubsampling::Yuv444 => {
                let mut u_values = vld1q_u8(u_buffer.as_ptr().cast());
                let mut v_values = vld1q_u8(v_buffer.as_ptr().cast());

                u_values = vsubq_u8(u_values, bias_uv);
                v_values = vsubq_u8(v_values, bias_uv);

                u_high_u8 = vget_high_u8(u_values);
                v_high_u8 = vget_high_u8(v_values);
                u_low_u8 = vget_low_u8(u_values);
                v_low_u8 = vget_low_u8(v_values);
            }
        }

        y_values = vqsubq_u8(y_values, bias_y);

        let y_high = vreinterpretq_s16_u16(vmovl_high_u8(y_values));
        let y_low = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(y_values)));

        let u_high = vmovl_s8(vreinterpret_s8_u8(u_high_u8));
        let v_high = vmovl_s8(vreinterpret_s8_u8(v_high_u8));
        let u_low = vmovl_s8(vreinterpret_s8_u8(u_low_u8));
        let v_low = vmovl_s8(vreinterpret_s8_u8(v_low_u8));

        let t_high = vsubq_s16(y_high, u_high);
        let t_low = vsubq_s16(y_low, u_low);

        let r_h = vaddq_s16(t_high, v_high);
        let r_l = vaddq_s16(t_low, v_low);
        let b_h = vsubq_s16(t_high, v_high);
        let b_l = vsubq_s16(t_low, v_low);
        let g_h = vaddq_s16(y_high, u_high);
        let g_l = vaddq_s16(y_low, u_low);

        let r_values = vcombine_u8(vqmovun_s16(r_l), vqmovun_s16(r_h));
        let g_values = vcombine_u8(vqmovun_s16(g_l), vqmovun_s16(g_h));
        let b_values = vcombine_u8(vqmovun_s16(b_l), vqmovun_s16(b_h));

        neon_store_rgb8::<DESTINATION_CHANNELS>(
            dst_buffer.as_mut_ptr().cast(),
            r_values,
            g_values,
            b_values,
            vdupq_n_u8(255),
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

/// Special path for Planar YUV 4:2:0 for aarch64 with RDM available
pub(crate) unsafe fn neon_ycgco420_to_rgba_row<const DESTINATION_CHANNELS: u8>(
    y_plane0: &[u8],
    y_plane1: &[u8],
    u_plane: &[u8],
    v_plane: &[u8],
    rgba0: &mut [u8],
    rgba1: &mut [u8],
    width: u32,
    chroma_range: YuvChromaRange,
) -> ProcessedOffset {
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = destination_channels.get_channels_count();

    let mut cx = 0usize;
    let mut uv_x = 0usize;

    let u_ptr = u_plane.as_ptr();
    let v_ptr = v_plane.as_ptr();

    let bias_y = vdupq_n_u8(chroma_range.bias_y as u8);
    let bias_uv = vdupq_n_u8(chroma_range.bias_uv as u8);

    while cx + 16 <= width as usize {
        let vl0 = vld1q_u8(y_plane0.get_unchecked(cx..).as_ptr());
        let vl1 = vld1q_u8(y_plane1.get_unchecked(cx..).as_ptr());

        let mut u_values = vld1_u8(u_ptr.add(uv_x));
        let mut v_values = vld1_u8(v_ptr.add(uv_x));

        u_values = vsub_u8(u_values, vget_low_u8(bias_uv));
        v_values = vsub_u8(v_values, vget_low_u8(bias_uv));

        let y_values0 = vqsubq_u8(vl0, bias_y);
        let y_values1 = vqsubq_u8(vl1, bias_y);

        let u_high_u8 = vzip2_u8(u_values, u_values);
        let v_high_u8 = vzip2_u8(v_values, v_values);
        let u_low_u8 = vzip1_u8(u_values, u_values);
        let v_low_u8 = vzip1_u8(v_values, v_values);

        let u_high = vmovl_s8(vreinterpret_s8_u8(u_high_u8));
        let v_high = vmovl_s8(vreinterpret_s8_u8(v_high_u8));
        let u_low = vmovl_s8(vreinterpret_s8_u8(u_low_u8));
        let v_low = vmovl_s8(vreinterpret_s8_u8(v_low_u8));

        let y_high0 = vreinterpretq_s16_u16(vmovl_high_u8(y_values0));
        let y_low0 = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(y_values0)));

        let y_high1 = vreinterpretq_s16_u16(vmovl_high_u8(y_values1));
        let y_low1 = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(y_values1)));

        let t_high0 = vsubq_s16(y_high0, u_high);
        let t_low0 = vsubq_s16(y_low0, u_low);

        let t_high1 = vsubq_s16(y_high1, u_high);
        let t_low1 = vsubq_s16(y_low1, u_low);

        let r_h0 = vaddq_s16(t_high0, v_high);
        let r_l0 = vaddq_s16(t_low0, v_low);
        let b_h0 = vsubq_s16(t_high0, v_high);
        let b_l0 = vsubq_s16(t_low0, v_low);
        let g_h0 = vaddq_s16(y_high0, u_high);
        let g_l0 = vaddq_s16(y_low0, u_low);

        let r_h1 = vaddq_s16(t_high1, v_high);
        let r_l1 = vaddq_s16(t_low1, v_low);
        let b_h1 = vsubq_s16(t_high1, v_high);
        let b_l1 = vsubq_s16(t_low1, v_low);
        let g_h1 = vaddq_s16(y_high1, u_high);
        let g_l1 = vaddq_s16(y_low1, u_low);

        let r_values0 = vcombine_u8(vqmovun_s16(r_l0), vqmovun_s16(r_h0));
        let g_values0 = vcombine_u8(vqmovun_s16(g_l0), vqmovun_s16(g_h0));
        let b_values0 = vcombine_u8(vqmovun_s16(b_l0), vqmovun_s16(b_h0));

        let r_values1 = vcombine_u8(vqmovun_s16(r_l1), vqmovun_s16(r_h1));
        let g_values1 = vcombine_u8(vqmovun_s16(g_l1), vqmovun_s16(g_h1));
        let b_values1 = vcombine_u8(vqmovun_s16(b_l1), vqmovun_s16(b_h1));

        let dst_shift = cx * channels;

        neon_store_rgb8::<DESTINATION_CHANNELS>(
            rgba0.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            r_values0,
            g_values0,
            b_values0,
            vdupq_n_u8(255),
        );
        neon_store_rgb8::<DESTINATION_CHANNELS>(
            rgba1.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            r_values1,
            g_values1,
            b_values1,
            vdupq_n_u8(255),
        );

        cx += 16;
        uv_x += 8;
    }

    if cx < width as usize {
        let diff = width as usize - cx;

        assert!(diff <= 16);

        let mut dst_buffer0: [u8; 16 * 4] = [0; 16 * 4];
        let mut dst_buffer1: [u8; 16 * 4] = [0; 16 * 4];
        let mut y_buffer0: [u8; 16] = [0; 16];
        let mut y_buffer1: [u8; 16] = [0; 16];
        let mut u_buffer: [u8; 16] = [0; 16];
        let mut v_buffer: [u8; 16] = [0; 16];

        std::ptr::copy_nonoverlapping(
            y_plane0.get_unchecked(cx..).as_ptr(),
            y_buffer0.as_mut_ptr().cast(),
            diff,
        );

        std::ptr::copy_nonoverlapping(
            y_plane1.get_unchecked(cx..).as_ptr(),
            y_buffer1.as_mut_ptr().cast(),
            diff,
        );

        let half_div = diff.div_ceil(2);

        std::ptr::copy_nonoverlapping(
            u_plane.get_unchecked(uv_x..).as_ptr(),
            u_buffer.as_mut_ptr().cast(),
            half_div,
        );

        std::ptr::copy_nonoverlapping(
            v_plane.get_unchecked(uv_x..).as_ptr(),
            v_buffer.as_mut_ptr().cast(),
            half_div,
        );

        let vl0 = vld1q_u8(y_buffer0.as_ptr().cast());
        let vl1 = vld1q_u8(y_buffer1.as_ptr().cast());

        let mut u_values = vld1_u8(u_buffer.as_ptr().cast());
        let mut v_values = vld1_u8(v_buffer.as_ptr().cast());

        u_values = vsub_u8(u_values, vget_low_u8(bias_uv));
        v_values = vsub_u8(v_values, vget_low_u8(bias_uv));

        let y_values0 = vqsubq_u8(vl0, bias_y);
        let y_values1 = vqsubq_u8(vl1, bias_y);

        let u_high_u8 = vzip2_u8(u_values, u_values);
        let v_high_u8 = vzip2_u8(v_values, v_values);
        let u_low_u8 = vzip1_u8(u_values, u_values);
        let v_low_u8 = vzip1_u8(v_values, v_values);

        let u_high = vmovl_s8(vreinterpret_s8_u8(u_high_u8));
        let v_high = vmovl_s8(vreinterpret_s8_u8(v_high_u8));
        let u_low = vmovl_s8(vreinterpret_s8_u8(u_low_u8));
        let v_low = vmovl_s8(vreinterpret_s8_u8(v_low_u8));

        let y_high0 = vreinterpretq_s16_u16(vmovl_high_u8(y_values0));
        let y_low0 = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(y_values0)));

        let y_high1 = vreinterpretq_s16_u16(vmovl_high_u8(y_values1));
        let y_low1 = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(y_values1)));

        let t_high0 = vsubq_s16(y_high0, u_high);
        let t_low0 = vsubq_s16(y_low0, u_low);

        let t_high1 = vsubq_s16(y_high1, u_high);
        let t_low1 = vsubq_s16(y_low1, u_low);

        let r_h0 = vaddq_s16(t_high0, v_high);
        let r_l0 = vaddq_s16(t_low0, v_low);
        let b_h0 = vsubq_s16(t_high0, v_high);
        let b_l0 = vsubq_s16(t_low0, v_low);
        let g_h0 = vaddq_s16(y_high0, u_high);
        let g_l0 = vaddq_s16(y_low0, u_low);

        let r_h1 = vaddq_s16(t_high1, v_high);
        let r_l1 = vaddq_s16(t_low1, v_low);
        let b_h1 = vsubq_s16(t_high1, v_high);
        let b_l1 = vsubq_s16(t_low1, v_low);
        let g_h1 = vaddq_s16(y_high1, u_high);
        let g_l1 = vaddq_s16(y_low1, u_low);

        let r_values0 = vcombine_u8(vqmovun_s16(r_l0), vqmovun_s16(r_h0));
        let g_values0 = vcombine_u8(vqmovun_s16(g_l0), vqmovun_s16(g_h0));
        let b_values0 = vcombine_u8(vqmovun_s16(b_l0), vqmovun_s16(b_h0));

        let r_values1 = vcombine_u8(vqmovun_s16(r_l1), vqmovun_s16(r_h1));
        let g_values1 = vcombine_u8(vqmovun_s16(g_l1), vqmovun_s16(g_h1));
        let b_values1 = vcombine_u8(vqmovun_s16(b_l1), vqmovun_s16(b_h1));

        neon_store_rgb8::<DESTINATION_CHANNELS>(
            dst_buffer0.as_mut_ptr().cast(),
            r_values0,
            g_values0,
            b_values0,
            vdupq_n_u8(255),
        );
        neon_store_rgb8::<DESTINATION_CHANNELS>(
            dst_buffer1.as_mut_ptr().cast(),
            r_values1,
            g_values1,
            b_values1,
            vdupq_n_u8(255),
        );

        let dst_shift = cx * channels;
        std::ptr::copy_nonoverlapping(
            dst_buffer0.as_mut_ptr().cast(),
            rgba0.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            diff * channels,
        );

        std::ptr::copy_nonoverlapping(
            dst_buffer1.as_mut_ptr().cast(),
            rgba1.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            diff * channels,
        );

        cx += diff;
        uv_x += half_div;
    }

    ProcessedOffset { cx, ux: uv_x }
}
