/*
 * Copyright (c) Radzivon Bartoshyk, 01/2025. All rights reserved.
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

use std::arch::aarch64::*;

use crate::internals::ProcessedOffset;
use crate::neon::f16_utils::{
    xreinterpretq_u16_f16, xvcombine_f16, xvcvt_f16_f32, xvcvtq_f16_u16, xvmulq_f16,
};
use crate::neon::utils::*;
use crate::yuv_support::{
    CbCrInverseTransform, YuvChromaRange, YuvChromaSubsampling, YuvSourceChannels,
};
use core::f16;

pub(crate) unsafe fn neon_yuva_p16_to_rgba_f16_row<
    const DESTINATION_CHANNELS: u8,
    const SAMPLING: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const PRECISION: i32,
    const BIT_DEPTH: usize,
>(
    y_ld_ptr: &[u16],
    u_ld_ptr: &[u16],
    v_ld_ptr: &[u16],
    a_ld_ptr: &[u16],
    rgba: &mut [f16],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
) -> ProcessedOffset {
    if std::arch::is_aarch64_feature_detected!("fp16") {
        neon_yuva_p16_to_rgba_f16_fp16::<
            DESTINATION_CHANNELS,
            SAMPLING,
            ENDIANNESS,
            BYTES_POSITION,
            BIT_DEPTH,
        >(
            y_ld_ptr, u_ld_ptr, v_ld_ptr, a_ld_ptr, rgba, width, range, transform,
        )
    } else {
        neon_yuva_p16_to_rgba_f16_non_fp16::<
            DESTINATION_CHANNELS,
            SAMPLING,
            ENDIANNESS,
            BYTES_POSITION,
            BIT_DEPTH,
        >(
            y_ld_ptr, u_ld_ptr, v_ld_ptr, a_ld_ptr, rgba, width, range, transform,
        )
    }
}

unsafe fn neon_yuva_p16_to_rgba_f16_non_fp16<
    const DESTINATION_CHANNELS: u8,
    const SAMPLING: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const BIT_DEPTH: usize,
>(
    y_ld_ptr: &[u16],
    u_ld_ptr: &[u16],
    v_ld_ptr: &[u16],
    a_ld_ptr: &[u16],
    rgba: &mut [f16],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
) -> ProcessedOffset {
    neon_yuva_p16_to_rgba_f16_impl::<
        DESTINATION_CHANNELS,
        SAMPLING,
        ENDIANNESS,
        BYTES_POSITION,
        BIT_DEPTH,
        false,
    >(
        y_ld_ptr, u_ld_ptr, v_ld_ptr, a_ld_ptr, rgba, width, range, transform,
    )
}

#[target_feature(enable = "fp16")]
unsafe fn neon_yuva_p16_to_rgba_f16_fp16<
    const DESTINATION_CHANNELS: u8,
    const SAMPLING: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const BIT_DEPTH: usize,
>(
    y_ld_ptr: &[u16],
    u_ld_ptr: &[u16],
    v_ld_ptr: &[u16],
    a_ld_ptr: &[u16],
    rgba: &mut [f16],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
) -> ProcessedOffset {
    neon_yuva_p16_to_rgba_f16_impl::<
        DESTINATION_CHANNELS,
        SAMPLING,
        ENDIANNESS,
        BYTES_POSITION,
        BIT_DEPTH,
        true,
    >(
        y_ld_ptr, u_ld_ptr, v_ld_ptr, a_ld_ptr, rgba, width, range, transform,
    )
}

#[inline(always)]
unsafe fn neon_yuva_p16_to_rgba_f16_impl<
    const DESTINATION_CHANNELS: u8,
    const SAMPLING: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const BIT_DEPTH: usize,
    const FP_16: bool,
>(
    y_ld_ptr: &[u16],
    u_ld_ptr: &[u16],
    v_ld_ptr: &[u16],
    a_ld_ptr: &[u16],
    rgba: &mut [f16],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
) -> ProcessedOffset {
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = destination_channels.get_channels_count();
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    let dst_ptr = rgba;

    let y_corr = vdupq_n_u16(range.bias_y as u16);
    let uv_corr = vdupq_n_s16(range.bias_uv as i16);

    let weights_arr: [i16; 8] = [
        transform.y_coef as i16,
        transform.cr_coef as i16,
        transform.cb_coef as i16,
        -transform.g_coeff_1 as i16,
        -transform.g_coeff_2 as i16,
        0,
        0,
        0,
    ];

    let v_weights = vld1q_s16(weights_arr.as_ptr());

    let k_alpha: f16 = 1.;

    const PRECISION: i32 = 14;

    let v_alpha = vdupq_n_u16(k_alpha.to_bits());

    let a_multiplier = vdupq_n_f32(1. / (((1 << BIT_DEPTH) - 1) as f32));
    let v_multiplier = xvcombine_f16(xvcvt_f16_f32(a_multiplier), xvcvt_f16_f32(a_multiplier));

    let base_val = vdupq_n_s32((1 << (PRECISION - 1)) - 1);

    let mut cx = 0;
    let mut ux = 0;

    while cx + 8 < width as usize {
        let y_values: int16x8_t = vreinterpretq_s16_u16(vqsubq_u16(
            vreinterpretq_u16_s16(vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                y_ld_ptr.get_unchecked(cx..).as_ptr(),
            )),
            y_corr,
        ));

        let u_high: int16x4_t;
        let v_high: int16x4_t;
        let u_low: int16x4_t;
        let v_low: int16x4_t;

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            let mut u_values_l = vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                u_ld_ptr.get_unchecked(ux..).as_ptr(),
            );
            let mut v_values_l = vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                v_ld_ptr.get_unchecked(ux..).as_ptr(),
            );

            u_values_l = vsubq_s16(u_values_l, uv_corr);
            v_values_l = vsubq_s16(v_values_l, uv_corr);

            u_high = vget_high_s16(u_values_l);
            u_low = vget_low_s16(u_values_l);
            v_high = vget_high_s16(v_values_l);
            v_low = vget_low_s16(v_values_l);
        } else {
            let mut u_values_l = vld_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                u_ld_ptr.get_unchecked(ux..).as_ptr(),
            );
            let mut v_values_l = vld_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                v_ld_ptr.get_unchecked(ux..).as_ptr(),
            );
            u_values_l = vsub_s16(u_values_l, vget_low_s16(uv_corr));
            v_values_l = vsub_s16(v_values_l, vget_low_s16(uv_corr));

            u_high = vzip2_s16(u_values_l, u_values_l);
            v_high = vzip2_s16(v_values_l, v_values_l);

            u_low = vzip1_s16(u_values_l, u_values_l);
            v_low = vzip1_s16(v_values_l, v_values_l);
        }

        let y_high = vqdmlal_high_laneq_s16::<0>(base_val, y_values, v_weights);
        let y_low = vqdmlal_laneq_s16::<0>(base_val, vget_low_s16(y_values), v_weights);

        let rh = vqdmlal_laneq_s16::<1>(y_high, v_high, v_weights);
        let bh = vqdmlal_laneq_s16::<2>(y_high, u_high, v_weights);
        let gh = vqdmlal_laneq_s16::<3>(y_high, v_high, v_weights);
        let rl = vqdmlal_laneq_s16::<1>(y_low, v_low, v_weights);
        let bl = vqdmlal_laneq_s16::<2>(y_low, u_low, v_weights);
        let gl = vqdmlal_laneq_s16::<3>(y_low, v_low, v_weights);

        let a_values = vld1q_u16(a_ld_ptr.get_unchecked(cx..).as_ptr());

        if FP_16 {
            let r_high = vqshrun_n_s32::<PRECISION>(rh);
            let b_high = vqshrun_n_s32::<PRECISION>(bh);
            let g_high = vqshrun_n_s32::<PRECISION>(vqdmlal_laneq_s16::<4>(gh, u_high, v_weights));

            let r_low = vqshrun_n_s32::<PRECISION>(rl);
            let b_low = vqshrun_n_s32::<PRECISION>(bl);
            let g_low = vqshrun_n_s32::<PRECISION>(vqdmlal_laneq_s16::<4>(gl, u_low, v_weights));

            let rvu = vminq_u16(vcombine_u16(r_low, r_high), v_alpha);
            let gvu = vminq_u16(vcombine_u16(g_low, g_high), v_alpha);
            let bvu = vminq_u16(vcombine_u16(b_low, b_high), v_alpha);

            let mut r_values = xvcvtq_f16_u16(rvu);
            let mut g_values = xvcvtq_f16_u16(gvu);
            let mut b_values = xvcvtq_f16_u16(bvu);
            let mut a_values = xvcvtq_f16_u16(a_values);

            r_values = xvmulq_f16(r_values, v_multiplier);
            g_values = xvmulq_f16(g_values, v_multiplier);
            b_values = xvmulq_f16(b_values, v_multiplier);
            a_values = xvmulq_f16(a_values, v_multiplier);

            neon_store_rgb16::<DESTINATION_CHANNELS>(
                dst_ptr.get_unchecked_mut(cx * channels..).as_mut_ptr() as *mut u16,
                xreinterpretq_u16_f16(r_values),
                xreinterpretq_u16_f16(g_values),
                xreinterpretq_u16_f16(b_values),
                xreinterpretq_u16_f16(a_values),
            );
        } else {
            let mut r_high = vshrq_n_s32::<PRECISION>(rh);
            let mut b_high = vshrq_n_s32::<PRECISION>(bh);
            let mut g_high =
                vshrq_n_s32::<PRECISION>(vqdmlal_laneq_s16::<4>(gh, u_high, v_weights));

            let mut r_low = vshrq_n_s32::<PRECISION>(rl);
            let mut b_low = vshrq_n_s32::<PRECISION>(bl);
            let mut g_low = vshrq_n_s32::<PRECISION>(vqdmlal_laneq_s16::<4>(gl, u_low, v_weights));

            let zeros = vdupq_n_s32(0);

            r_high = vmaxq_s32(r_high, zeros);
            g_high = vmaxq_s32(g_high, zeros);
            b_high = vmaxq_s32(b_high, zeros);

            r_low = vmaxq_s32(r_low, zeros);
            g_low = vmaxq_s32(g_low, zeros);
            b_low = vmaxq_s32(b_low, zeros);

            let ah = vmovl_high_u16(a_values);
            let al = vmovl_u16(vget_low_u16(a_values));

            let mut r_high = vcvtq_f32_s32(r_high);
            let mut g_high = vcvtq_f32_s32(g_high);
            let mut b_high = vcvtq_f32_s32(b_high);
            let mut a_high = vcvtq_f32_u32(ah);

            let mut r_low = vcvtq_f32_s32(r_low);
            let mut g_low = vcvtq_f32_s32(g_low);
            let mut b_low = vcvtq_f32_s32(b_low);
            let mut a_low = vcvtq_f32_u32(al);

            r_high = vmulq_f32(r_high, a_multiplier);
            g_high = vmulq_f32(g_high, a_multiplier);
            b_high = vmulq_f32(b_high, a_multiplier);
            a_high = vmulq_f32(a_high, a_multiplier);

            r_low = vmulq_f32(r_low, a_multiplier);
            g_low = vmulq_f32(g_low, a_multiplier);
            b_low = vmulq_f32(b_low, a_multiplier);
            a_low = vmulq_f32(a_low, a_multiplier);

            let r_high = xvcvt_f16_f32(r_high);
            let g_high = xvcvt_f16_f32(g_high);
            let b_high = xvcvt_f16_f32(b_high);
            let a_high = xvcvt_f16_f32(a_high);

            let r_low = xvcvt_f16_f32(r_low);
            let g_low = xvcvt_f16_f32(g_low);
            let b_low = xvcvt_f16_f32(b_low);
            let a_low = xvcvt_f16_f32(a_low);

            let r_values = xreinterpretq_u16_f16(xvcombine_f16(r_low, r_high));
            let g_values = xreinterpretq_u16_f16(xvcombine_f16(g_low, g_high));
            let b_values = xreinterpretq_u16_f16(xvcombine_f16(b_low, b_high));
            let a_values = xreinterpretq_u16_f16(xvcombine_f16(a_low, a_high));

            neon_store_rgb16::<DESTINATION_CHANNELS>(
                dst_ptr.get_unchecked_mut(cx * channels..).as_mut_ptr() as *mut u16,
                r_values,
                g_values,
                b_values,
                a_values,
            );
        }

        cx += 8;

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                ux += 4;
            }
            YuvChromaSubsampling::Yuv444 => {
                ux += 8;
            }
        }
    }

    if cx < width as usize {
        let diff = width as usize - cx;
        assert!(diff <= 8);

        let mut y_buffer: [u16; 8] = [0; 8];
        let mut u_buffer: [u16; 8] = [0; 8];
        let mut v_buffer: [u16; 8] = [0; 8];
        let mut a_buffer: [u16; 8] = [0; 8];

        std::ptr::copy_nonoverlapping(
            y_ld_ptr.get_unchecked(cx..).as_ptr(),
            y_buffer.as_mut_ptr(),
            diff,
        );

        std::ptr::copy_nonoverlapping(
            a_ld_ptr.get_unchecked(cx..).as_ptr(),
            a_buffer.as_mut_ptr(),
            diff,
        );

        let y_values: int16x8_t = vreinterpretq_s16_u16(vqsubq_u16(
            vreinterpretq_u16_s16(vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                y_buffer.as_ptr(),
            )),
            y_corr,
        ));

        let u_high: int16x4_t;
        let v_high: int16x4_t;
        let u_low: int16x4_t;
        let v_low: int16x4_t;

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            std::ptr::copy_nonoverlapping(
                u_ld_ptr.get_unchecked(ux..).as_ptr(),
                u_buffer.as_mut_ptr(),
                diff,
            );
            std::ptr::copy_nonoverlapping(
                v_ld_ptr.get_unchecked(ux..).as_ptr(),
                v_buffer.as_mut_ptr(),
                diff,
            );

            let mut u_values_l =
                vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(u_buffer.as_ptr());
            let mut v_values_l =
                vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(v_buffer.as_ptr());

            u_values_l = vsubq_s16(u_values_l, uv_corr);
            v_values_l = vsubq_s16(v_values_l, uv_corr);

            u_high = vget_high_s16(u_values_l);
            u_low = vget_low_s16(u_values_l);
            v_high = vget_high_s16(v_values_l);
            v_low = vget_low_s16(v_values_l);
        } else {
            std::ptr::copy_nonoverlapping(
                u_ld_ptr.get_unchecked(ux..).as_ptr(),
                u_buffer.as_mut_ptr(),
                diff.div_ceil(2),
            );
            std::ptr::copy_nonoverlapping(
                v_ld_ptr.get_unchecked(ux..).as_ptr(),
                v_buffer.as_mut_ptr(),
                diff.div_ceil(2),
            );

            let mut u_values_l =
                vld_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(u_buffer.as_ptr());
            let mut v_values_l =
                vld_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(v_buffer.as_ptr());
            u_values_l = vsub_s16(u_values_l, vget_low_s16(uv_corr));
            v_values_l = vsub_s16(v_values_l, vget_low_s16(uv_corr));

            u_high = vzip2_s16(u_values_l, u_values_l);
            v_high = vzip2_s16(v_values_l, v_values_l);

            u_low = vzip1_s16(u_values_l, u_values_l);
            v_low = vzip1_s16(v_values_l, v_values_l);
        }

        let y_high = vqdmlal_high_laneq_s16::<0>(base_val, y_values, v_weights);
        let y_low = vqdmlal_laneq_s16::<0>(base_val, vget_low_s16(y_values), v_weights);

        let rh = vqdmlal_laneq_s16::<1>(y_high, v_high, v_weights);
        let bh = vqdmlal_laneq_s16::<2>(y_high, u_high, v_weights);
        let gh = vqdmlal_laneq_s16::<3>(y_high, v_high, v_weights);
        let rl = vqdmlal_laneq_s16::<1>(y_low, v_low, v_weights);
        let bl = vqdmlal_laneq_s16::<2>(y_low, u_low, v_weights);
        let gl = vqdmlal_laneq_s16::<3>(y_low, v_low, v_weights);

        let mut buffer: [f16; 8 * 4] = [0.; 8 * 4];

        let a_values = vld1q_u16(a_buffer.as_ptr());

        if FP_16 {
            let r_high = vqshrun_n_s32::<PRECISION>(rh);
            let b_high = vqshrun_n_s32::<PRECISION>(bh);
            let g_high = vqshrun_n_s32::<PRECISION>(vqdmlal_laneq_s16::<4>(gh, u_high, v_weights));

            let r_low = vqshrun_n_s32::<PRECISION>(rl);
            let b_low = vqshrun_n_s32::<PRECISION>(bl);
            let g_low = vqshrun_n_s32::<PRECISION>(vqdmlal_laneq_s16::<4>(gl, u_low, v_weights));

            let rvu = vminq_u16(vcombine_u16(r_low, r_high), v_alpha);
            let gvu = vminq_u16(vcombine_u16(g_low, g_high), v_alpha);
            let bvu = vminq_u16(vcombine_u16(b_low, b_high), v_alpha);

            let mut r_values = xvcvtq_f16_u16(rvu);
            let mut g_values = xvcvtq_f16_u16(gvu);
            let mut b_values = xvcvtq_f16_u16(bvu);
            let mut a_values = xvcvtq_f16_u16(a_values);

            r_values = xvmulq_f16(r_values, v_multiplier);
            g_values = xvmulq_f16(g_values, v_multiplier);
            b_values = xvmulq_f16(b_values, v_multiplier);
            a_values = xvmulq_f16(a_values, v_multiplier);

            neon_store_rgb16::<DESTINATION_CHANNELS>(
                buffer.as_mut_ptr() as *mut u16,
                xreinterpretq_u16_f16(r_values),
                xreinterpretq_u16_f16(g_values),
                xreinterpretq_u16_f16(b_values),
                xreinterpretq_u16_f16(a_values),
            );
        } else {
            let mut r_high = vshrq_n_s32::<PRECISION>(rh);
            let mut b_high = vshrq_n_s32::<PRECISION>(bh);
            let mut g_high =
                vshrq_n_s32::<PRECISION>(vqdmlal_laneq_s16::<4>(gh, u_high, v_weights));

            let mut r_low = vshrq_n_s32::<PRECISION>(rl);
            let mut b_low = vshrq_n_s32::<PRECISION>(bl);
            let mut g_low = vshrq_n_s32::<PRECISION>(vqdmlal_laneq_s16::<4>(gl, u_low, v_weights));

            let zeros = vdupq_n_s32(0);

            r_high = vmaxq_s32(r_high, zeros);
            g_high = vmaxq_s32(g_high, zeros);
            b_high = vmaxq_s32(b_high, zeros);

            r_low = vmaxq_s32(r_low, zeros);
            g_low = vmaxq_s32(g_low, zeros);
            b_low = vmaxq_s32(b_low, zeros);

            let ah = vmovl_high_u16(a_values);
            let al = vmovl_u16(vget_low_u16(a_values));

            let mut r_high = vcvtq_f32_s32(r_high);
            let mut g_high = vcvtq_f32_s32(g_high);
            let mut b_high = vcvtq_f32_s32(b_high);
            let mut a_high = vcvtq_f32_u32(ah);

            let mut r_low = vcvtq_f32_s32(r_low);
            let mut g_low = vcvtq_f32_s32(g_low);
            let mut b_low = vcvtq_f32_s32(b_low);
            let mut a_low = vcvtq_f32_u32(al);

            r_high = vmulq_f32(r_high, a_multiplier);
            g_high = vmulq_f32(g_high, a_multiplier);
            b_high = vmulq_f32(b_high, a_multiplier);
            a_high = vmulq_f32(a_high, a_multiplier);

            r_low = vmulq_f32(r_low, a_multiplier);
            g_low = vmulq_f32(g_low, a_multiplier);
            b_low = vmulq_f32(b_low, a_multiplier);
            a_low = vmulq_f32(a_low, a_multiplier);

            let r_high = xvcvt_f16_f32(r_high);
            let g_high = xvcvt_f16_f32(g_high);
            let b_high = xvcvt_f16_f32(b_high);
            let a_high = xvcvt_f16_f32(a_high);

            let r_low = xvcvt_f16_f32(r_low);
            let g_low = xvcvt_f16_f32(g_low);
            let b_low = xvcvt_f16_f32(b_low);
            let a_low = xvcvt_f16_f32(a_low);

            let r_values = xreinterpretq_u16_f16(xvcombine_f16(r_low, r_high));
            let g_values = xreinterpretq_u16_f16(xvcombine_f16(g_low, g_high));
            let b_values = xreinterpretq_u16_f16(xvcombine_f16(b_low, b_high));
            let a_values = xreinterpretq_u16_f16(xvcombine_f16(a_low, a_high));

            neon_store_rgb16::<DESTINATION_CHANNELS>(
                buffer.as_mut_ptr() as *mut u16,
                r_values,
                g_values,
                b_values,
                a_values,
            );
        }

        std::ptr::copy_nonoverlapping(
            buffer.as_ptr(),
            dst_ptr.get_unchecked_mut(cx * channels..).as_mut_ptr(),
            diff * channels,
        );

        cx += diff;

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                ux += diff.div_ceil(2);
            }
            YuvChromaSubsampling::Yuv444 => {
                ux += diff;
            }
        }
    }

    ProcessedOffset { cx, ux }
}
