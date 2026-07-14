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
use crate::yuv_support::{
    CbCrForwardTransform, YuvChromaRange, YuvChromaSubsampling, YuvSourceChannels,
};
use std::arch::aarch64::*;

#[allow(clippy::cast_abs_to_unsigned)]
pub(crate) unsafe fn neon_rgbx_to_yuv_fast<const ORIGIN_CHANNELS: u8, const SAMPLING: u8>(
    transform: &CbCrForwardTransform<i32>,
    range: &YuvChromaRange,
    y_plane: &mut [u8],
    u_plane: &mut [u8],
    v_plane: &mut [u8],
    rgba: &[u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    let source_channels: YuvSourceChannels = ORIGIN_CHANNELS.into();
    let channels = source_channels.get_channels_count();

    let y_ptr = y_plane;
    let u_ptr = u_plane;
    let v_ptr = v_plane;

    const A_E: i32 = 7;
    let y_bias = vdupq_n_u16(range.bias_y as u16 * (1 << A_E) + (1 << (A_E - 1)) - 1);
    let uv_bias = vdupq_n_u16(range.bias_uv as u16 * (1 << A_E) + (1 << (A_E - 1)) - 1);

    let v_yr = vdupq_n_u8(transform.yr as u8);
    let v_yg = vdupq_n_u8(transform.yg as u8);
    let v_yb = vdupq_n_u8(transform.yb as u8);
    let v_cb_r = vdupq_n_u8(transform.cb_r.abs() as u8);
    let v_cb_g = vdupq_n_u8(transform.cb_g.abs() as u8);
    let v_cb_b = vdupq_n_u8(transform.cb_b.abs() as u8);
    let v_cr_r = vdupq_n_u8(transform.cr_r.abs() as u8);
    let v_cr_g = vdupq_n_u8(transform.cr_g.abs() as u8);
    let v_cr_b = vdupq_n_u8(transform.cr_b.abs() as u8);

    let mut cx = start_cx;
    let mut ux = start_ux;

    while cx + 16 <= width {
        let src = rgba.get_unchecked(cx * channels..).as_ptr();

        let (r_values0, g_values0, b_values0) = neon_vld_rgb_for_yuv::<ORIGIN_CHANNELS>(src);

        let mut yh0 = vmlal_high_u8(y_bias, r_values0, v_yr);
        let mut yl0 = vmlal_u8(y_bias, vget_low_u8(r_values0), vget_low_u8(v_yr));

        yh0 = vmlal_high_u8(yh0, g_values0, v_yg);
        yl0 = vmlal_u8(yl0, vget_low_u8(g_values0), vget_low_u8(v_yg));

        yh0 = vmlal_high_u8(yh0, b_values0, v_yb);
        yl0 = vmlal_u8(yl0, vget_low_u8(b_values0), vget_low_u8(v_yb));

        let yn_0 = vqshrn_n_u16::<A_E>(yl0);
        let yn_1 = vqshrn_n_u16::<A_E>(yh0);

        let y_vl = vcombine_u8(yn_0, yn_1);

        vst1q_u8(y_ptr.get_unchecked_mut(cx..).as_mut_ptr(), y_vl);

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            let mut cb_lq = vmlal_u8(uv_bias, vget_low_u8(b_values0), vget_low_u8(v_cb_b));
            let mut cb_hq = vmlal_high_u8(uv_bias, b_values0, v_cb_b);
            let mut cr_lq = vmlal_u8(uv_bias, vget_low_u8(r_values0), vget_low_u8(v_cr_r));
            let mut cr_hq = vmlal_high_u8(uv_bias, r_values0, v_cr_r);

            cb_lq = vmlsl_u8(cb_lq, vget_low_u8(g_values0), vget_low_u8(v_cb_g));
            cb_hq = vmlsl_high_u8(cb_hq, g_values0, v_cb_g);
            cr_lq = vmlsl_u8(cr_lq, vget_low_u8(g_values0), vget_low_u8(v_cr_g));
            cr_hq = vmlsl_high_u8(cr_hq, g_values0, v_cr_g);

            cb_lq = vmlsl_u8(cb_lq, vget_low_u8(r_values0), vget_low_u8(v_cb_r));
            cb_hq = vmlsl_high_u8(cb_hq, r_values0, v_cb_r);
            cr_lq = vmlsl_u8(cr_lq, vget_low_u8(b_values0), vget_low_u8(v_cr_b));
            cr_hq = vmlsl_high_u8(cr_hq, b_values0, v_cr_b);

            let cb_0 = vqshrn_n_u16::<A_E>(cb_lq);
            let cb_1 = vqshrn_n_u16::<A_E>(cb_hq);

            let cr_0 = vqshrn_n_u16::<A_E>(cr_lq);
            let cr_1 = vqshrn_n_u16::<A_E>(cr_hq);

            let cb_vl = vcombine_u8(cb_0, cb_1);
            let cr_vl = vcombine_u8(cr_0, cr_1);

            vst1q_u8(u_ptr.get_unchecked_mut(ux..).as_mut_ptr(), cb_vl);
            vst1q_u8(v_ptr.get_unchecked_mut(ux..).as_mut_ptr(), cr_vl);

            ux += 16;
        } else if (chroma_subsampling == YuvChromaSubsampling::Yuv420)
            || (chroma_subsampling == YuvChromaSubsampling::Yuv422)
        {
            let rpv = vpaddlq_u8(r_values0);
            let gpv = vpaddlq_u8(g_values0);
            let bpv = vpaddlq_u8(b_values0);

            let rpv = vqshrn_n_u16::<1>(rpv);
            let gpv = vqshrn_n_u16::<1>(gpv);
            let bpv = vqshrn_n_u16::<1>(bpv);

            let mut cb_q = vmlal_u8(uv_bias, bpv, vget_low_u8(v_cb_b));
            let mut cr_q = vmlal_u8(uv_bias, rpv, vget_low_u8(v_cr_r));
            cb_q = vmlsl_u8(cb_q, gpv, vget_low_u8(v_cb_g));
            cr_q = vmlsl_u8(cr_q, gpv, vget_low_u8(v_cr_g));
            cb_q = vmlsl_u8(cb_q, rpv, vget_low_u8(v_cb_r));
            cr_q = vmlsl_u8(cr_q, bpv, vget_low_u8(v_cr_b));

            let cb = vqshrn_n_u16::<A_E>(cb_q);
            let cr = vqshrn_n_u16::<A_E>(cr_q);

            vst1_u8(u_ptr.get_unchecked_mut(ux..).as_mut_ptr(), cb);
            vst1_u8(v_ptr.get_unchecked_mut(ux..).as_mut_ptr(), cr);

            ux += 8;
        }

        cx += 16;
    }

    if cx < width {
        let diff = width - cx;
        assert!(diff <= 16);

        let mut src_buffer: [u8; 16 * 4] = [0; 16 * 4];
        let mut y_buffer: [u8; 16] = [0; 16];
        let mut u_buffer: [u8; 16] = [0; 16];
        let mut v_buffer: [u8; 16] = [0; 16];

        std::ptr::copy_nonoverlapping(
            rgba.get_unchecked(cx * channels..).as_ptr(),
            src_buffer.as_mut_ptr().cast(),
            diff * channels,
        );

        // Replicate last item to one more position for subsampling
        if chroma_subsampling != YuvChromaSubsampling::Yuv444 && diff % 2 != 0 {
            let lst = (width - 1) * channels;
            let last_items = rgba.get_unchecked(lst..(lst + channels));
            let dvb = diff * channels;
            let dst = src_buffer.get_unchecked_mut(dvb..(dvb + channels));
            for (dst, src) in dst.iter_mut().zip(last_items) {
                *dst = *src;
            }
        }

        let (r_values0, g_values0, b_values0) =
            neon_vld_rgb_for_yuv::<ORIGIN_CHANNELS>(src_buffer.as_ptr().cast());

        let mut yh0 = vmlal_high_u8(y_bias, r_values0, v_yr);
        let mut yl0 = vmlal_u8(y_bias, vget_low_u8(r_values0), vget_low_u8(v_yr));

        yh0 = vmlal_high_u8(yh0, g_values0, v_yg);
        yl0 = vmlal_u8(yl0, vget_low_u8(g_values0), vget_low_u8(v_yg));

        yh0 = vmlal_high_u8(yh0, b_values0, v_yb);
        yl0 = vmlal_u8(yl0, vget_low_u8(b_values0), vget_low_u8(v_yb));

        let yn_0 = vqshrn_n_u16::<A_E>(yl0);
        let yn_1 = vqshrn_n_u16::<A_E>(yh0);

        let y_vl = vcombine_u8(yn_0, yn_1);

        vst1q_u8(y_buffer.as_mut_ptr().cast(), y_vl);

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            let mut cb_lq = vmlal_u8(uv_bias, vget_low_u8(b_values0), vget_low_u8(v_cb_b));
            let mut cb_hq = vmlal_high_u8(uv_bias, b_values0, v_cb_b);
            let mut cr_lq = vmlal_u8(uv_bias, vget_low_u8(r_values0), vget_low_u8(v_cr_r));
            let mut cr_hq = vmlal_high_u8(uv_bias, r_values0, v_cr_r);

            cb_lq = vmlsl_u8(cb_lq, vget_low_u8(g_values0), vget_low_u8(v_cb_g));
            cb_hq = vmlsl_high_u8(cb_hq, g_values0, v_cb_g);
            cr_lq = vmlsl_u8(cr_lq, vget_low_u8(g_values0), vget_low_u8(v_cr_g));
            cr_hq = vmlsl_high_u8(cr_hq, g_values0, v_cr_g);

            cb_lq = vmlsl_u8(cb_lq, vget_low_u8(r_values0), vget_low_u8(v_cb_r));
            cb_hq = vmlsl_high_u8(cb_hq, r_values0, v_cb_r);
            cr_lq = vmlsl_u8(cr_lq, vget_low_u8(b_values0), vget_low_u8(v_cr_b));
            cr_hq = vmlsl_high_u8(cr_hq, b_values0, v_cr_b);

            let cb_0 = vqshrn_n_u16::<A_E>(cb_lq);
            let cb_1 = vqshrn_n_u16::<A_E>(cb_hq);

            let cr_0 = vqshrn_n_u16::<A_E>(cr_lq);
            let cr_1 = vqshrn_n_u16::<A_E>(cr_hq);

            let cb_vl = vcombine_u8(cb_0, cb_1);
            let cr_vl = vcombine_u8(cr_0, cr_1);

            vst1q_u8(u_buffer.as_mut_ptr().cast(), cb_vl);
            vst1q_u8(v_buffer.as_mut_ptr().cast(), cr_vl);
        } else if (chroma_subsampling == YuvChromaSubsampling::Yuv420)
            || (chroma_subsampling == YuvChromaSubsampling::Yuv422)
        {
            let rpv = vpaddlq_u8(r_values0);
            let gpv = vpaddlq_u8(g_values0);
            let bpv = vpaddlq_u8(b_values0);

            let rpv = vqshrn_n_u16::<1>(rpv);
            let gpv = vqshrn_n_u16::<1>(gpv);
            let bpv = vqshrn_n_u16::<1>(bpv);

            let mut cb_q = vmlal_u8(uv_bias, bpv, vget_low_u8(v_cb_b));
            let mut cr_q = vmlal_u8(uv_bias, rpv, vget_low_u8(v_cr_r));
            cb_q = vmlsl_u8(cb_q, gpv, vget_low_u8(v_cb_g));
            cr_q = vmlsl_u8(cr_q, gpv, vget_low_u8(v_cr_g));
            cb_q = vmlsl_u8(cb_q, rpv, vget_low_u8(v_cb_r));
            cr_q = vmlsl_u8(cr_q, bpv, vget_low_u8(v_cr_b));

            let cb = vqshrn_n_u16::<A_E>(cb_q);
            let cr = vqshrn_n_u16::<A_E>(cr_q);

            vst1_u8(u_buffer.as_mut_ptr().cast(), cb);
            vst1_u8(v_buffer.as_mut_ptr().cast(), cr);
        }

        std::ptr::copy_nonoverlapping(
            y_buffer.as_ptr().cast(),
            y_ptr.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );

        cx += diff;

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            std::ptr::copy_nonoverlapping(
                u_buffer.as_ptr().cast(),
                u_ptr.get_unchecked_mut(ux..).as_mut_ptr(),
                diff,
            );
            std::ptr::copy_nonoverlapping(
                v_buffer.as_ptr().cast(),
                v_ptr.get_unchecked_mut(ux..).as_mut_ptr(),
                diff,
            );

            ux += diff;
        } else if (chroma_subsampling == YuvChromaSubsampling::Yuv420)
            || (chroma_subsampling == YuvChromaSubsampling::Yuv422)
        {
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

            ux += hv;
        }
    }

    ProcessedOffset { cx, ux }
}
