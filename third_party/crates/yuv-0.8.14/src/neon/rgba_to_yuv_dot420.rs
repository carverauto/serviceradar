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
use crate::yuv_support::{CbCrForwardTransform, YuvChromaRange, YuvSourceChannels};
use std::arch::aarch64::*;

#[target_feature(enable = "i8mm")]
pub(crate) unsafe fn neon_rgba_to_yuv_dot_rgba420<const ORIGIN_CHANNELS: u8>(
    transform: &CbCrForwardTransform<i32>,
    range: &YuvChromaRange,
    y_plane0: &mut [u8],
    y_plane1: &mut [u8],
    u_plane: &mut [u8],
    v_plane: &mut [u8],
    rgba0: &[u8],
    rgba1: &[u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    let source_channels: YuvSourceChannels = ORIGIN_CHANNELS.into();
    assert!(
        source_channels == YuvSourceChannels::Rgba || source_channels == YuvSourceChannels::Bgra
    );
    let channels = source_channels.get_channels_count();

    let u_ptr = u_plane;
    let v_ptr = v_plane;

    const A_E: i32 = 7;
    let y_bias = vdupq_n_s32(range.bias_y as i32 * (1 << A_E) + (1 << (A_E - 1)) - 1);
    let uv_bias = vdupq_n_s32(range.bias_uv as i32 * (1 << A_E) + (1 << (A_E - 1)) - 1);

    let weights_yr: i32 = i32::from_ne_bytes([
        transform.yr as u8,
        transform.yg as u8,
        transform.yb as u8,
        0,
    ]);
    let weights_yr_bgra: i32 = i32::from_ne_bytes([
        transform.yb as u8,
        transform.yg as u8,
        transform.yr as u8,
        0,
    ]);

    let weights_cb_rgba: i32 = i32::from_ne_bytes([
        transform.cb_r as u8,
        transform.cb_g as u8,
        transform.cb_b as u8,
        0,
    ]);

    let weights_cb_bgra: i32 = i32::from_ne_bytes([
        transform.cb_b as u8,
        transform.cb_g as u8,
        transform.cb_r as u8,
        0,
    ]);

    let weights_cr_rgba: i32 = i32::from_ne_bytes([
        transform.cr_r as u8,
        transform.cr_g as u8,
        transform.cr_b as u8,
        0,
    ]);
    let weights_cr_bgra: i32 = i32::from_ne_bytes([
        transform.cr_b as u8,
        transform.cr_g as u8,
        transform.cr_r as u8,
        0,
    ]);

    let y_weights =
        vreinterpretq_s8_s32(vdupq_n_s32(if source_channels == YuvSourceChannels::Rgba {
            weights_yr
        } else {
            weights_yr_bgra
        }));
    let cb_weights =
        vreinterpretq_s8_s32(vdupq_n_s32(if source_channels == YuvSourceChannels::Rgba {
            weights_cb_rgba
        } else {
            weights_cb_bgra
        }));
    let cr_weights =
        vreinterpretq_s8_s32(vdupq_n_s32(if source_channels == YuvSourceChannels::Rgba {
            weights_cr_rgba
        } else {
            weights_cr_bgra
        }));

    let mut cx = start_cx;
    let mut ux = start_ux;

    while cx + 16 <= width {
        let src0 = rgba0.get_unchecked(cx * channels..).as_ptr();
        let src1 = rgba1.get_unchecked(cx * channels..).as_ptr();

        let v0 = vld1q_u8(src0);
        let v1 = vld1q_u8(src0.add(16));
        let v2 = vld1q_u8(src0.add(32));
        let v3 = vld1q_u8(src0.add(48));

        let v4 = vld1q_u8(src1);
        let v5 = vld1q_u8(src1.add(16));
        let v6 = vld1q_u8(src1.add(32));
        let v7 = vld1q_u8(src1.add(48));

        let y0 = vusdotq_s32(y_bias, v0, y_weights);
        let y1 = vusdotq_s32(y_bias, v1, y_weights);
        let y2 = vusdotq_s32(y_bias, v2, y_weights);
        let y3 = vusdotq_s32(y_bias, v3, y_weights);

        let y4 = vusdotq_s32(y_bias, v4, y_weights);
        let y5 = vusdotq_s32(y_bias, v5, y_weights);
        let y6 = vusdotq_s32(y_bias, v6, y_weights);
        let y7 = vusdotq_s32(y_bias, v7, y_weights);

        let yn_0 = vqshrun_n_s32::<A_E>(y0);
        let yn_1 = vqshrun_n_s32::<A_E>(y1);
        let yn_2 = vqshrun_n_s32::<A_E>(y2);
        let yn_3 = vqshrun_n_s32::<A_E>(y3);

        let yn_4 = vqshrun_n_s32::<A_E>(y4);
        let yn_5 = vqshrun_n_s32::<A_E>(y5);
        let yn_6 = vqshrun_n_s32::<A_E>(y6);
        let yn_7 = vqshrun_n_s32::<A_E>(y7);

        let j0 = vqmovn_u16(vcombine_u16(yn_0, yn_1));
        let j1 = vqmovn_u16(vcombine_u16(yn_2, yn_3));
        let j2 = vqmovn_u16(vcombine_u16(yn_4, yn_5));
        let j3 = vqmovn_u16(vcombine_u16(yn_6, yn_7));

        let y_vl0 = vcombine_u8(j0, j1);
        let y_vl1 = vcombine_u8(j2, j3);

        vst1q_u8(y_plane0.get_unchecked_mut(cx..).as_mut_ptr(), y_vl0);
        vst1q_u8(y_plane1.get_unchecked_mut(cx..).as_mut_ptr(), y_vl1);

        let v0 = vhaddq_u8(v0, v4);
        let v1 = vhaddq_u8(v1, v5);
        let v2 = vhaddq_u8(v2, v6);
        let v3 = vhaddq_u8(v3, v7);

        let uzp0 = vuzpq_u32(vreinterpretq_u32_u8(v0), vreinterpretq_u32_u8(v1));
        let uzp1 = vuzpq_u32(vreinterpretq_u32_u8(v2), vreinterpretq_u32_u8(v3));

        let v0_s = vreinterpretq_u8_u32(uzp0.0);
        let v1_s = vreinterpretq_u8_u32(uzp0.1);
        let v2_s = vreinterpretq_u8_u32(uzp1.0);
        let v3_s = vreinterpretq_u8_u32(uzp1.1);

        let v0_f = vhaddq_u8(v0_s, v1_s);
        let v1_f = vhaddq_u8(v2_s, v3_s);

        let cb0 = vusdotq_s32(uv_bias, v0_f, cb_weights);
        let cb1 = vusdotq_s32(uv_bias, v1_f, cb_weights);

        let cr0 = vusdotq_s32(uv_bias, v0_f, cr_weights);
        let cr1 = vusdotq_s32(uv_bias, v1_f, cr_weights);

        let cb_0 = vqshrun_n_s32::<A_E>(cb0);
        let cb_1 = vqshrun_n_s32::<A_E>(cb1);

        let cr_0 = vqshrun_n_s32::<A_E>(cr0);
        let cr_1 = vqshrun_n_s32::<A_E>(cr1);

        let cb_vl = vqmovn_u16(vcombine_u16(cb_0, cb_1));

        let cr_vl = vqmovn_u16(vcombine_u16(cr_0, cr_1));

        vst1_u8(u_ptr.get_unchecked_mut(ux..).as_mut_ptr(), cb_vl);
        vst1_u8(v_ptr.get_unchecked_mut(ux..).as_mut_ptr(), cr_vl);

        ux += 8;
        cx += 16;
    }

    if cx < width {
        let diff = width - cx;
        assert!(diff <= 16);

        let mut src_buffer0: [u8; 16 * 4] = [0; 16 * 4];
        let mut src_buffer1: [u8; 16 * 4] = [0; 16 * 4];
        let mut y_buffer0: [u8; 16] = [0; 16];
        let mut y_buffer1: [u8; 16] = [0; 16];
        let mut u_buffer: [u8; 16] = [0; 16];
        let mut v_buffer: [u8; 16] = [0; 16];

        std::ptr::copy_nonoverlapping(
            rgba0.get_unchecked(cx * channels..).as_ptr(),
            src_buffer0.as_mut_ptr().cast(),
            diff * channels,
        );
        std::ptr::copy_nonoverlapping(
            rgba1.get_unchecked(cx * channels..).as_ptr(),
            src_buffer1.as_mut_ptr().cast(),
            diff * channels,
        );

        // Replicate last item to one more position for subsampling
        if diff % 2 != 0 {
            let lst = (width - 1) * channels;
            let last_items0 = rgba0.get_unchecked(lst..(lst + channels));
            let last_items1 = rgba1.get_unchecked(lst..(lst + channels));
            let dvb = diff * channels;
            let dst0 = src_buffer0.get_unchecked_mut(dvb..(dvb + channels));
            let dst1 = src_buffer1.get_unchecked_mut(dvb..(dvb + channels));
            for (dst, src) in dst0.iter_mut().zip(last_items0) {
                *dst = *src;
            }
            for (dst, src) in dst1.iter_mut().zip(last_items1) {
                *dst = *src;
            }
        }

        let v0 = vld1q_u8(src_buffer0.as_ptr().cast());
        let v1 = vld1q_u8(src_buffer0.as_ptr().add(16).cast());
        let v2 = vld1q_u8(src_buffer0.as_ptr().add(32).cast());
        let v3 = vld1q_u8(src_buffer0.as_ptr().add(48).cast());

        let v4 = vld1q_u8(src_buffer1.as_ptr().cast());
        let v5 = vld1q_u8(src_buffer1.as_ptr().add(16).cast());
        let v6 = vld1q_u8(src_buffer1.as_ptr().add(32).cast());
        let v7 = vld1q_u8(src_buffer1.as_ptr().add(48).cast());

        let y0 = vusdotq_s32(y_bias, v0, y_weights);
        let y1 = vusdotq_s32(y_bias, v1, y_weights);
        let y2 = vusdotq_s32(y_bias, v2, y_weights);
        let y3 = vusdotq_s32(y_bias, v3, y_weights);

        let y4 = vusdotq_s32(y_bias, v4, y_weights);
        let y5 = vusdotq_s32(y_bias, v5, y_weights);
        let y6 = vusdotq_s32(y_bias, v6, y_weights);
        let y7 = vusdotq_s32(y_bias, v7, y_weights);

        let yn_0 = vqshrun_n_s32::<A_E>(y0);
        let yn_1 = vqshrun_n_s32::<A_E>(y1);
        let yn_2 = vqshrun_n_s32::<A_E>(y2);
        let yn_3 = vqshrun_n_s32::<A_E>(y3);

        let yn_4 = vqshrun_n_s32::<A_E>(y4);
        let yn_5 = vqshrun_n_s32::<A_E>(y5);
        let yn_6 = vqshrun_n_s32::<A_E>(y6);
        let yn_7 = vqshrun_n_s32::<A_E>(y7);

        let j0 = vqmovn_u16(vcombine_u16(yn_0, yn_1));
        let j1 = vqmovn_u16(vcombine_u16(yn_2, yn_3));
        let j2 = vqmovn_u16(vcombine_u16(yn_4, yn_5));
        let j3 = vqmovn_u16(vcombine_u16(yn_6, yn_7));

        let y_vl0 = vcombine_u8(j0, j1);
        let y_vl1 = vcombine_u8(j2, j3);

        vst1q_u8(y_buffer0.as_mut_ptr().cast(), y_vl0);
        vst1q_u8(y_buffer1.as_mut_ptr().cast(), y_vl1);

        let v0 = vhaddq_u8(v0, v4);
        let v1 = vhaddq_u8(v1, v5);
        let v2 = vhaddq_u8(v2, v6);
        let v3 = vhaddq_u8(v3, v7);

        let uzp0 = vuzpq_u32(vreinterpretq_u32_u8(v0), vreinterpretq_u32_u8(v1));
        let uzp1 = vuzpq_u32(vreinterpretq_u32_u8(v2), vreinterpretq_u32_u8(v3));

        let v0_s = vreinterpretq_u8_u32(uzp0.0);
        let v1_s = vreinterpretq_u8_u32(uzp0.1);
        let v2_s = vreinterpretq_u8_u32(uzp1.0);
        let v3_s = vreinterpretq_u8_u32(uzp1.1);

        let v0_f = vhaddq_u8(v0_s, v1_s);
        let v1_f = vhaddq_u8(v2_s, v3_s);

        let cb0 = vusdotq_s32(uv_bias, v0_f, cb_weights);
        let cb1 = vusdotq_s32(uv_bias, v1_f, cb_weights);

        let cr0 = vusdotq_s32(uv_bias, v0_f, cr_weights);
        let cr1 = vusdotq_s32(uv_bias, v1_f, cr_weights);

        let cb_0 = vqshrun_n_s32::<A_E>(cb0);
        let cb_1 = vqshrun_n_s32::<A_E>(cb1);

        let cr_0 = vqshrun_n_s32::<A_E>(cr0);
        let cr_1 = vqshrun_n_s32::<A_E>(cr1);

        let cb_vl = vqmovn_u16(vcombine_u16(cb_0, cb_1));
        let cr_vl = vqmovn_u16(vcombine_u16(cr_0, cr_1));

        vst1_u8(u_buffer.as_mut_ptr().cast(), cb_vl);
        vst1_u8(v_buffer.as_mut_ptr().cast(), cr_vl);

        std::ptr::copy_nonoverlapping(
            y_buffer0.as_ptr().cast(),
            y_plane0.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );
        std::ptr::copy_nonoverlapping(
            y_buffer1.as_ptr().cast(),
            y_plane1.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );

        let hv = diff.div_ceil(2);
        std::ptr::copy_nonoverlapping(
            u_buffer.as_ptr().cast(),
            u_ptr.get_unchecked_mut(ux..).as_mut_ptr(),
            hv,
        );
        std::ptr::copy_nonoverlapping(
            v_buffer.as_ptr().cast(),
            v_ptr.get_unchecked_mut(ux..).as_mut_ptr(),
            hv,
        );

        cx += diff;
        ux += hv;
    }

    ProcessedOffset { cx, ux }
}
