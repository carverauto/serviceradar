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
use crate::neon::utils::neon_vld_rgb_for_yuv;
use crate::yuv_support::{CbCrForwardTransform, YuvChromaRange, YuvSourceChannels};
use std::arch::aarch64::*;

#[allow(clippy::cast_abs_to_unsigned)]
pub(crate) unsafe fn neon_rgbx_to_yuv_fast420<const ORIGIN_CHANNELS: u8>(
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
    let channels = source_channels.get_channels_count();

    let u_ptr = u_plane;
    let v_ptr = v_plane;

    const A_E: i32 = 7;
    let y_bias = vdupq_n_u16(range.bias_y as u16 * (1 << A_E) + (1 << (A_E - 1)) - 1);
    let uv_bias = vdupq_n_u16(range.bias_uv as u16 * (1 << A_E) + (1 << (A_E - 1)) - 1);

    let mut cx = start_cx;
    let mut ux = start_ux;

    let v_yr = vdupq_n_u8(transform.yr as u8);
    let v_yg = vdupq_n_u8(transform.yg as u8);
    let v_yb = vdupq_n_u8(transform.yb as u8);
    let v_cb_r = vdup_n_u8(transform.cb_r.abs() as u8);
    let v_cb_g = vdup_n_u8(transform.cb_g.abs() as u8);
    let v_cb_b = vdup_n_u8(transform.cb_b.abs() as u8);
    let v_cr_r = vdup_n_u8(transform.cr_r.abs() as u8);
    let v_cr_g = vdup_n_u8(transform.cr_g.abs() as u8);
    let v_cr_b = vdup_n_u8(transform.cr_b.abs() as u8);

    while cx + 16 <= width {
        let src0 = rgba0.get_unchecked(cx * channels..).as_ptr();
        let src1 = rgba1.get_unchecked(cx * channels..).as_ptr();

        let (r_values0, g_values0, b_values0) = neon_vld_rgb_for_yuv::<ORIGIN_CHANNELS>(src0);
        let (r_values1, g_values1, b_values1) = neon_vld_rgb_for_yuv::<ORIGIN_CHANNELS>(src1);

        let mut yh0 = vmlal_high_u8(y_bias, r_values0, v_yr);
        let mut yh1 = vmlal_high_u8(y_bias, r_values1, v_yr);
        let mut yl0 = vmlal_u8(y_bias, vget_low_u8(r_values0), vget_low_u8(v_yr));
        let mut yl1 = vmlal_u8(y_bias, vget_low_u8(r_values1), vget_low_u8(v_yr));

        yh0 = vmlal_high_u8(yh0, g_values0, v_yg);
        yh1 = vmlal_high_u8(yh1, g_values1, v_yg);
        yl0 = vmlal_u8(yl0, vget_low_u8(g_values0), vget_low_u8(v_yg));
        yl1 = vmlal_u8(yl1, vget_low_u8(g_values1), vget_low_u8(v_yg));

        yh0 = vmlal_high_u8(yh0, b_values0, v_yb);
        yh1 = vmlal_high_u8(yh1, b_values1, v_yb);
        yl0 = vmlal_u8(yl0, vget_low_u8(b_values0), vget_low_u8(v_yb));
        yl1 = vmlal_u8(yl1, vget_low_u8(b_values1), vget_low_u8(v_yb));

        let yn_0 = vqshrn_n_u16::<A_E>(yl0);
        let yn_1 = vqshrn_n_u16::<A_E>(yh0);
        let yn_2 = vqshrn_n_u16::<A_E>(yl1);
        let yn_3 = vqshrn_n_u16::<A_E>(yh1);

        let y_vl0 = vcombine_u8(yn_0, yn_1);
        let y_vl1 = vcombine_u8(yn_2, yn_3);

        vst1q_u8(y_plane0.get_unchecked_mut(cx..).as_mut_ptr(), y_vl0);
        vst1q_u8(y_plane1.get_unchecked_mut(cx..).as_mut_ptr(), y_vl1);

        let rhv = vhaddq_u8(r_values0, r_values1);
        let ghv = vhaddq_u8(g_values0, g_values1);
        let bhv = vhaddq_u8(b_values0, b_values1);

        let rpv = vpaddlq_u8(rhv);
        let gpv = vpaddlq_u8(ghv);
        let bpv = vpaddlq_u8(bhv);

        let rpv = vqshrn_n_u16::<1>(rpv);
        let gpv = vqshrn_n_u16::<1>(gpv);
        let bpv = vqshrn_n_u16::<1>(bpv);

        let mut cb_q = vmlal_u8(uv_bias, bpv, v_cb_b);
        let mut cr_q = vmlal_u8(uv_bias, rpv, v_cr_r);
        cb_q = vmlsl_u8(cb_q, rpv, v_cb_r);
        cr_q = vmlsl_u8(cr_q, gpv, v_cr_g);
        cb_q = vmlsl_u8(cb_q, gpv, v_cb_g);
        cr_q = vmlsl_u8(cr_q, bpv, v_cr_b);

        let cb = vqshrn_n_u16::<A_E>(cb_q);
        let cr = vqshrn_n_u16::<A_E>(cr_q);

        vst1_u8(u_ptr.get_unchecked_mut(ux..).as_mut_ptr(), cb);
        vst1_u8(v_ptr.get_unchecked_mut(ux..).as_mut_ptr(), cr);

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

        let (r_values0, g_values0, b_values0) =
            neon_vld_rgb_for_yuv::<ORIGIN_CHANNELS>(src_buffer0.as_ptr().cast());
        let (r_values1, g_values1, b_values1) =
            neon_vld_rgb_for_yuv::<ORIGIN_CHANNELS>(src_buffer1.as_ptr().cast());

        let mut yh0 = vmlal_high_u8(y_bias, r_values0, v_yr);
        let mut yh1 = vmlal_high_u8(y_bias, r_values1, v_yr);
        let mut yl0 = vmlal_u8(y_bias, vget_low_u8(r_values0), vget_low_u8(v_yr));
        let mut yl1 = vmlal_u8(y_bias, vget_low_u8(r_values1), vget_low_u8(v_yr));

        yh0 = vmlal_high_u8(yh0, g_values0, v_yg);
        yh1 = vmlal_high_u8(yh1, g_values1, v_yg);
        yl0 = vmlal_u8(yl0, vget_low_u8(g_values0), vget_low_u8(v_yg));
        yl1 = vmlal_u8(yl1, vget_low_u8(g_values1), vget_low_u8(v_yg));

        yh0 = vmlal_high_u8(yh0, b_values0, v_yb);
        yh1 = vmlal_high_u8(yh1, b_values1, v_yb);
        yl0 = vmlal_u8(yl0, vget_low_u8(b_values0), vget_low_u8(v_yb));
        yl1 = vmlal_u8(yl1, vget_low_u8(b_values1), vget_low_u8(v_yb));

        let yn_0 = vqshrn_n_u16::<A_E>(yl0);
        let yn_1 = vqshrn_n_u16::<A_E>(yh0);
        let yn_2 = vqshrn_n_u16::<A_E>(yl1);
        let yn_3 = vqshrn_n_u16::<A_E>(yh1);

        let y_vl0 = vcombine_u8(yn_0, yn_1);
        let y_vl1 = vcombine_u8(yn_2, yn_3);

        vst1q_u8(y_buffer0.as_mut_ptr().cast(), y_vl0);
        vst1q_u8(y_buffer1.as_mut_ptr().cast(), y_vl1);

        let rhv = vhaddq_u8(r_values0, r_values1);
        let ghv = vhaddq_u8(g_values0, g_values1);
        let bhv = vhaddq_u8(b_values0, b_values1);

        let rpv = vpaddlq_u8(rhv);
        let gpv = vpaddlq_u8(ghv);
        let bpv = vpaddlq_u8(bhv);

        let rpv = vqshrn_n_u16::<1>(rpv);
        let gpv = vqshrn_n_u16::<1>(gpv);
        let bpv = vqshrn_n_u16::<1>(bpv);

        let mut cb_q = vmlal_u8(uv_bias, bpv, v_cb_b);
        let mut cr_q = vmlal_u8(uv_bias, rpv, v_cr_r);
        cb_q = vmlsl_u8(cb_q, rpv, v_cb_r);
        cr_q = vmlsl_u8(cr_q, gpv, v_cr_g);
        cb_q = vmlsl_u8(cb_q, gpv, v_cb_g);
        cr_q = vmlsl_u8(cr_q, bpv, v_cr_b);

        let cb = vqshrn_n_u16::<A_E>(cb_q);
        let cr = vqshrn_n_u16::<A_E>(cr_q);

        vst1_u8(u_buffer.as_mut_ptr().cast(), cb);
        vst1_u8(v_buffer.as_mut_ptr().cast(), cr);

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
