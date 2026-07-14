/*
 * Copyright (c) Radzivon Bartoshyk, 1/2025. All rights reserved.
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

use crate::f16_converter::{SurfaceFloat16ToUnsigned, SurfaceToFloat16};
use crate::neon::f16_utils::{
    x_float16x8x2_t, xreinterpretq_f16_u16, xvcombine_f16, xvcvt_f16_f32, xvcvt_f32_f16,
    xvcvtaq_u16_f16, xvcvtq_f16_u16, xvget_high_f16, xvget_low_f16, xvldq_f16, xvmulq_f16,
    xvstq_f16, xvstq_f16_x2,
};
use core::f16;
use std::arch::aarch64::*;

#[derive(Default)]
pub(crate) struct SurfaceU8ToFloat16NeonFallback {}

impl SurfaceToFloat16<u8> for SurfaceU8ToFloat16NeonFallback {
    fn to_float16(&self, src: &[u8], dst: &mut [f16], _: usize) {
        unsafe {
            let v_scale = vdupq_n_f32(1. / 255.);

            for (src, dst) in src.chunks_exact(16).zip(dst.chunks_exact_mut(16)) {
                let items = vld1q_u8(src.as_ptr());
                let lo_16 = vmovl_u8(vget_low_u8(items));
                let hi_16 = vmovl_high_u8(items);

                let l0 = vmovl_u16(vget_low_u16(lo_16));
                let l1 = vmovl_high_u16(lo_16);
                let l2 = vmovl_u16(vget_low_u16(hi_16));
                let l3 = vmovl_high_u16(hi_16);

                let j0 = vcvtq_f32_u32(l0);
                let j1 = vcvtq_f32_u32(l1);
                let j2 = vcvtq_f32_u32(l2);
                let j3 = vcvtq_f32_u32(l3);

                let lo_lo_32 = vmulq_f32(j0, v_scale);
                let lo_hi_32 = vmulq_f32(j1, v_scale);
                let hi_lo_32 = vmulq_f32(j2, v_scale);
                let hi_hi_32 = vmulq_f32(j3, v_scale);

                let lo_lo_f16 = xvcvt_f16_f32(lo_lo_32);
                let lo_hi_f16 = xvcvt_f16_f32(lo_hi_32);
                let hi_lo_f16 = xvcvt_f16_f32(hi_lo_32);
                let hi_hi_f16 = xvcvt_f16_f32(hi_hi_32);

                let lo_f16 = xvcombine_f16(lo_lo_f16, lo_hi_f16);
                xvstq_f16(dst.as_mut_ptr(), lo_f16);

                let hi_f16 = xvcombine_f16(hi_lo_f16, hi_hi_f16);
                xvstq_f16(dst.get_unchecked_mut(8..).as_mut_ptr(), hi_f16);
            }

            let src_rem = src.chunks_exact(16).remainder();
            let dst_rem = dst.chunks_exact_mut(16).into_remainder();

            for (src, dst) in src_rem.chunks_exact(8).zip(dst_rem.chunks_exact_mut(8)) {
                let items = vld1_u8(src.as_ptr());
                let lo_16 = vmovl_u8(items);

                let l0 = vmovl_u16(vget_low_u16(lo_16));
                let l1 = vmovl_high_u16(lo_16);

                let j0 = vcvtq_f32_u32(l0);
                let j1 = vcvtq_f32_u32(l1);

                let lo_lo_32 = vmulq_f32(j0, v_scale);
                let lo_hi_32 = vmulq_f32(j1, v_scale);

                let lo_lo_f16 = xvcvt_f16_f32(lo_lo_32);
                let lo_hi_f16 = xvcvt_f16_f32(lo_hi_32);

                let lo_f16 = xvcombine_f16(lo_lo_f16, lo_hi_f16);
                xvstq_f16(dst.as_mut_ptr(), lo_f16);
            }

            let src_rem = src_rem.chunks_exact(8).remainder();
            let dst_rem = dst_rem.chunks_exact_mut(8).into_remainder();

            if !src_rem.is_empty() && !dst_rem.is_empty() {
                assert!(src_rem.len() <= 8);
                assert!(dst_rem.len() <= 8);
                let mut src_buffer: [u8; 8] = [0; 8];
                let mut dst_buffer: [f16; 8] = [0.; 8];
                std::ptr::copy_nonoverlapping(
                    src_rem.as_ptr(),
                    src_buffer.as_mut_ptr(),
                    src_rem.len(),
                );
                let items = vld1_u8(src_buffer.as_ptr());
                let lo_16 = vmovl_u8(items);

                let l0 = vmovl_u16(vget_low_u16(lo_16));
                let l1 = vmovl_high_u16(lo_16);

                let j0 = vcvtq_f32_u32(l0);
                let j1 = vcvtq_f32_u32(l1);

                let lo_lo_32 = vmulq_f32(j0, v_scale);
                let lo_hi_32 = vmulq_f32(j1, v_scale);

                let lo_lo_f16 = xvcvt_f16_f32(lo_lo_32);
                let lo_hi_f16 = xvcvt_f16_f32(lo_hi_32);

                let lo_f16 = xvcombine_f16(lo_lo_f16, lo_hi_f16);
                xvstq_f16(dst_buffer.as_mut_ptr(), lo_f16);

                std::ptr::copy_nonoverlapping(
                    dst_buffer.as_ptr(),
                    dst_rem.as_mut_ptr(),
                    dst_rem.len(),
                );
            }
        }
    }
}

#[derive(Default)]
pub(crate) struct SurfaceU8ToFloat16Neon {}

impl SurfaceU8ToFloat16Neon {
    #[target_feature(enable = "fp16")]
    unsafe fn to_float16_impl(&self, src: &[u8], dst: &mut [f16]) {
        let v_scale = xreinterpretq_f16_u16(vdupq_n_u16(7172)); // 1. / 255.
        for (src, dst) in src.chunks_exact(16).zip(dst.chunks_exact_mut(16)) {
            let items = vld1q_u8(src.as_ptr());

            let w0 = vmovl_u8(vget_low_u8(items));
            let w1 = vmovl_high_u8(items);

            let v0 = xvcvtq_f16_u16(w0);
            let v1 = xvcvtq_f16_u16(w1);

            let lo_16 = xvmulq_f16(v0, v_scale);
            let hi_16 = xvmulq_f16(v1, v_scale);

            xvstq_f16(dst.as_mut_ptr(), lo_16);
            xvstq_f16(dst.get_unchecked_mut(8..).as_mut_ptr(), hi_16);
        }

        let src_rem = src.chunks_exact(16).remainder();
        let dst_rem = dst.chunks_exact_mut(16).into_remainder();

        for (src, dst) in src_rem.chunks_exact(8).zip(dst_rem.chunks_exact_mut(8)) {
            let items = vld1_u8(src.as_ptr());
            let lo_16 = vmovl_u8(items);

            let lo_f16 = xvmulq_f16(xvcvtq_f16_u16(lo_16), v_scale);

            xvstq_f16(dst.as_mut_ptr(), lo_f16);
        }

        let src_rem = src_rem.chunks_exact(8).remainder();
        let dst_rem = dst_rem.chunks_exact_mut(8).into_remainder();

        if !src_rem.is_empty() && !dst_rem.is_empty() {
            assert!(src_rem.len() <= 8);
            assert!(dst_rem.len() <= 8);
            let mut src_buffer: [u8; 8] = [0; 8];
            let mut dst_buffer: [f16; 8] = [0.; 8];

            std::ptr::copy_nonoverlapping(src_rem.as_ptr(), src_buffer.as_mut_ptr(), src_rem.len());
            let items = vld1_u8(src_buffer.as_ptr());
            let lo_16 = vmovl_u8(items);

            let lo_f16 = xvmulq_f16(xvcvtq_f16_u16(lo_16), v_scale);
            xvstq_f16(dst_buffer.as_mut_ptr(), lo_f16);

            std::ptr::copy_nonoverlapping(dst_buffer.as_ptr(), dst_rem.as_mut_ptr(), dst_rem.len());
        }
    }
}

impl SurfaceToFloat16<u8> for SurfaceU8ToFloat16Neon {
    fn to_float16(&self, src: &[u8], dst: &mut [f16], _: usize) {
        unsafe { self.to_float16_impl(src, dst) }
    }
}

#[derive(Default)]
pub(crate) struct SurfaceU16ToFloat16NeonFallback {}

impl SurfaceToFloat16<u16> for SurfaceU16ToFloat16NeonFallback {
    fn to_float16(&self, src: &[u16], dst: &mut [f16], bit_depth: usize) {
        unsafe {
            let max_colors = (1 << bit_depth) - 1;
            let v_scale = vdupq_n_f32(1. / max_colors as f32);

            for (src, dst) in src.chunks_exact(8).zip(dst.chunks_exact_mut(8)) {
                let items = vld1q_u16(src.as_ptr());

                let w0 = vmovl_u16(vget_low_u16(items));
                let w1 = vmovl_high_u16(items);

                let v0 = vcvtq_f32_u32(w0);
                let v1 = vcvtq_f32_u32(w1);

                let lo_lo_32 = vmulq_f32(v0, v_scale);
                let lo_hi_32 = vmulq_f32(v1, v_scale);

                let lo_lo_f16 = xvcvt_f16_f32(lo_lo_32);
                let lo_hi_f16 = xvcvt_f16_f32(lo_hi_32);
                let lo_f16 = xvcombine_f16(lo_lo_f16, lo_hi_f16);
                xvstq_f16(dst.as_mut_ptr(), lo_f16);
            }

            let src_rem = src.chunks_exact(8).remainder();
            let dst_rem = dst.chunks_exact_mut(8).into_remainder();

            if !src_rem.is_empty() && !dst_rem.is_empty() {
                assert!(src_rem.len() <= 8);
                assert!(dst_rem.len() <= 8);
                let mut src_buffer: [u16; 8] = [0; 8];
                let mut dst_buffer: [f16; 8] = [0.; 8];
                std::ptr::copy_nonoverlapping(
                    src_rem.as_ptr(),
                    src_buffer.as_mut_ptr(),
                    src_rem.len(),
                );
                let items = vld1q_u16(src_buffer.as_ptr());

                let w0 = vmovl_u16(vget_low_u16(items));
                let w1 = vmovl_high_u16(items);

                let v0 = vcvtq_f32_u32(w0);
                let v1 = vcvtq_f32_u32(w1);

                let lo_lo_32 = vmulq_f32(v0, v_scale);
                let lo_hi_32 = vmulq_f32(v1, v_scale);

                let lo_lo_f16 = xvcvt_f16_f32(lo_lo_32);
                let lo_hi_f16 = xvcvt_f16_f32(lo_hi_32);

                let lo_f16 = xvcombine_f16(lo_lo_f16, lo_hi_f16);
                xvstq_f16(dst_buffer.as_mut_ptr(), lo_f16);

                std::ptr::copy_nonoverlapping(
                    dst_buffer.as_ptr(),
                    dst_rem.as_mut_ptr(),
                    dst_rem.len(),
                );
            }
        }
    }
}

#[derive(Default)]
pub(crate) struct SurfaceU16ToFloat16Neon {}

impl SurfaceU16ToFloat16Neon {
    #[target_feature(enable = "fp16")]
    unsafe fn to_float16_impl(&self, src: &[u16], dst: &mut [f16], bit_depth: usize) {
        let max_colors = (1 << bit_depth) - 1;
        let v_scale_h = xvcvt_f16_f32(vdupq_n_f32(1. / max_colors as f32));
        let v_scale = xvcombine_f16(v_scale_h, v_scale_h);

        for (src, dst) in src.chunks_exact(16).zip(dst.chunks_exact_mut(16)) {
            let items0 = vld1q_u16(src.as_ptr());
            let items1 = vld1q_u16(src.get_unchecked(8..).as_ptr());

            let j0 = xvcvtq_f16_u16(items0);
            let j1 = xvcvtq_f16_u16(items1);

            let values0 = xvmulq_f16(j0, v_scale);
            let values1 = xvmulq_f16(j1, v_scale);
            xvstq_f16_x2(dst.as_mut_ptr(), x_float16x8x2_t(values0, values1));
        }

        let src_rem = src.chunks_exact(16).remainder();
        let dst_rem = dst.chunks_exact_mut(16).into_remainder();

        for (src, dst) in src_rem.chunks_exact(8).zip(dst_rem.chunks_exact_mut(8)) {
            let items = vld1q_u16(src.as_ptr());
            let values = xvmulq_f16(xvcvtq_f16_u16(items), v_scale);
            xvstq_f16(dst.as_mut_ptr(), values);
        }

        let src_rem = src.chunks_exact(8).remainder();
        let dst_rem = dst.chunks_exact_mut(8).into_remainder();

        if !src_rem.is_empty() && !dst_rem.is_empty() {
            assert!(src_rem.len() <= 8);
            assert!(dst_rem.len() <= 8);
            let mut src_buffer: [u16; 8] = [0; 8];
            let mut dst_buffer: [f16; 8] = [0.; 8];
            std::ptr::copy_nonoverlapping(src_rem.as_ptr(), src_buffer.as_mut_ptr(), src_rem.len());
            let items = vld1q_u16(src_buffer.as_ptr());
            let values = xvmulq_f16(xvcvtq_f16_u16(items), v_scale);

            xvstq_f16(dst_buffer.as_mut_ptr(), values);

            std::ptr::copy_nonoverlapping(dst_buffer.as_ptr(), dst_rem.as_mut_ptr(), dst_rem.len());
        }
    }
}

impl SurfaceToFloat16<u16> for SurfaceU16ToFloat16Neon {
    fn to_float16(&self, src: &[u16], dst: &mut [f16], bit_depth: usize) {
        unsafe {
            self.to_float16_impl(src, dst, bit_depth);
        }
    }
}

#[derive(Default)]
pub(crate) struct SurfaceF16ToUnsigned8NeonFallback {}

impl SurfaceFloat16ToUnsigned<u8> for SurfaceF16ToUnsigned8NeonFallback {
    fn to_unsigned(&self, src: &[f16], dst: &mut [u8], _: usize) {
        unsafe {
            let v_scale = vdupq_n_f32(255.);
            for (src, dst) in src.chunks_exact(8).zip(dst.chunks_exact_mut(8)) {
                let items = xreinterpretq_f16_u16(vld1q_u16(src.as_ptr() as *const _));

                let w0 = xvcvt_f32_f16(xvget_high_f16(items));
                let w1 = xvcvt_f32_f16(xvget_low_f16(items));

                let v0 = vmulq_f32(w0, v_scale);
                let v1 = vmulq_f32(w1, v_scale);

                let m0 = vcvtaq_u32_f32(v0);
                let m1 = vcvtaq_u32_f32(v1);

                let lo = vmovn_u32(m0);
                let hi = vmovn_u32(m1);
                let merged = vqmovn_u16(vcombine_u16(lo, hi));
                vst1_u8(dst.as_mut_ptr(), merged)
            }

            let src_rem = src.chunks_exact(8).remainder();
            let dst_rem = dst.chunks_exact_mut(8).into_remainder();

            if !src_rem.is_empty() && !dst_rem.is_empty() {
                assert!(src_rem.len() <= 8);
                assert!(dst_rem.len() <= 8);
                let mut src_buffer: [f16; 8] = [0.; 8];
                let mut dst_buffer: [u8; 8] = [0; 8];
                std::ptr::copy_nonoverlapping(
                    src_rem.as_ptr(),
                    src_buffer.as_mut_ptr(),
                    src_rem.len(),
                );

                let items = xreinterpretq_f16_u16(vld1q_u16(src_buffer.as_ptr() as *const _));
                let w0 = xvcvt_f32_f16(xvget_high_f16(items));
                let w1 = xvcvt_f32_f16(xvget_low_f16(items));

                let v0 = vmulq_f32(w0, v_scale);
                let v1 = vmulq_f32(w1, v_scale);

                let m0 = vcvtaq_u32_f32(v0);
                let m1 = vcvtaq_u32_f32(v1);

                let lo = vmovn_u32(m0);
                let hi = vmovn_u32(m1);
                let merged = vqmovn_u16(vcombine_u16(lo, hi));
                vst1_u8(dst_buffer.as_mut_ptr(), merged);

                std::ptr::copy_nonoverlapping(
                    dst_buffer.as_ptr(),
                    dst_rem.as_mut_ptr(),
                    dst_rem.len(),
                );
            }
        }
    }
}

#[derive(Default)]
pub(crate) struct SurfaceF16ToUnsigned8Neon {}

impl SurfaceF16ToUnsigned8Neon {
    #[target_feature(enable = "neon")]
    unsafe fn to_unsigned_impl(&self, src: &[f16], dst: &mut [u8]) {
        let v_scale = xreinterpretq_f16_u16(vdupq_n_u16(23544)); // 255_f16

        for (src, dst) in src.chunks_exact(16).zip(dst.chunks_exact_mut(16)) {
            let items0 = xvldq_f16(src.as_ptr());
            let items1 = xvldq_f16(src.get_unchecked(8..).as_ptr());

            let s1 = xvmulq_f16(items0, v_scale);
            let s2 = xvmulq_f16(items1, v_scale);

            let values0 = xvcvtaq_u16_f16(s1);
            let values1 = xvcvtaq_u16_f16(s2);
            let merged = vcombine_u8(vqmovn_u16(values0), vqmovn_u16(values1));

            vst1q_u8(dst.as_mut_ptr(), merged);
        }

        let src_rem = src.chunks_exact(16).remainder();
        let dst_rem = dst.chunks_exact_mut(16).into_remainder();

        for (src, dst) in src_rem.chunks_exact(8).zip(dst_rem.chunks_exact_mut(8)) {
            let items = xvldq_f16(src.as_ptr());

            let values = xvcvtaq_u16_f16(xvmulq_f16(items, v_scale));
            let merged = vqmovn_u16(values);

            vst1_u8(dst.as_mut_ptr(), merged);
        }

        let src_rem = src_rem.chunks_exact(8).remainder();
        let dst_rem = dst_rem.chunks_exact_mut(8).into_remainder();

        if !src_rem.is_empty() && !dst_rem.is_empty() {
            assert!(src_rem.len() <= 8);
            assert!(dst_rem.len() <= 8);
            let mut src_buffer: [f16; 8] = [0.; 8];
            let mut dst_buffer: [u8; 8] = [0; 8];
            std::ptr::copy_nonoverlapping(src_rem.as_ptr(), src_buffer.as_mut_ptr(), src_rem.len());

            let items = xvldq_f16(src_buffer.as_ptr());

            let values = xvcvtaq_u16_f16(xvmulq_f16(items, v_scale));
            let merged = vqmovn_u16(values);
            vst1_u8(dst_buffer.as_mut_ptr(), merged);

            std::ptr::copy_nonoverlapping(dst_buffer.as_ptr(), dst_rem.as_mut_ptr(), dst_rem.len());
        }
    }
}

impl SurfaceFloat16ToUnsigned<u8> for SurfaceF16ToUnsigned8Neon {
    fn to_unsigned(&self, src: &[f16], dst: &mut [u8], _: usize) {
        unsafe { self.to_unsigned_impl(src, dst) }
    }
}

#[derive(Default)]
pub(crate) struct SurfaceF16ToUnsigned16NeonFallback {}

impl SurfaceFloat16ToUnsigned<u16> for SurfaceF16ToUnsigned16NeonFallback {
    fn to_unsigned(&self, src: &[f16], dst: &mut [u16], bit_depth: usize) {
        unsafe {
            let v_scale = vdupq_n_f32(((1 << bit_depth) - 1) as f32);
            for (src, dst) in src.chunks_exact(8).zip(dst.chunks_exact_mut(8)) {
                let items = xreinterpretq_f16_u16(vld1q_u16(src.as_ptr() as *const _));
                let j0 = xvcvt_f32_f16(xvget_high_f16(items));
                let j1 = xvcvt_f32_f16(xvget_low_f16(items));

                let v0 = vmulq_f32(j0, v_scale);
                let v1 = vmulq_f32(j1, v_scale);

                let l0 = vcvtaq_u32_f32(v0);
                let l1 = vcvtaq_u32_f32(v1);

                let lo = vmovn_u32(l0);
                let hi = vmovn_u32(l1);
                let merged = vcombine_u16(lo, hi);
                vst1q_u16(dst.as_mut_ptr(), merged);
            }

            let src_rem = src.chunks_exact(8).remainder();
            let dst_rem = dst.chunks_exact_mut(8).into_remainder();

            if !src_rem.is_empty() && !dst_rem.is_empty() {
                assert!(src_rem.len() <= 8);
                assert!(dst_rem.len() <= 8);
                let mut src_buffer: [f16; 8] = [0.; 8];
                let mut dst_buffer: [u16; 8] = [0; 8];
                std::ptr::copy_nonoverlapping(
                    src_rem.as_ptr(),
                    src_buffer.as_mut_ptr(),
                    src_rem.len(),
                );

                let items = xreinterpretq_f16_u16(vld1q_u16(src_buffer.as_ptr() as *const _));

                let j0 = xvcvt_f32_f16(xvget_high_f16(items));
                let j1 = xvcvt_f32_f16(xvget_low_f16(items));

                let v0 = vmulq_f32(j0, v_scale);
                let v1 = vmulq_f32(j1, v_scale);

                let l0 = vcvtaq_u32_f32(v0);
                let l1 = vcvtaq_u32_f32(v1);

                let lo = vmovn_u32(l0);
                let hi = vmovn_u32(l1);
                let merged = vcombine_u16(lo, hi);

                vst1q_u16(dst_buffer.as_mut_ptr(), merged);

                std::ptr::copy_nonoverlapping(
                    dst_buffer.as_ptr(),
                    dst_rem.as_mut_ptr(),
                    dst_rem.len(),
                );
            }
        }
    }
}

#[derive(Default)]
pub(crate) struct SurfaceF16ToUnsigned16Neon {}

impl SurfaceF16ToUnsigned16Neon {
    #[target_feature(enable = "fp16")]
    unsafe fn to_unsigned_impl(&self, src: &[f16], dst: &mut [u16], bit_depth: usize) {
        let v_scale_h = xvcvt_f16_f32(vdupq_n_f32(((1 << bit_depth) - 1) as f32));
        let v_scale = xvcombine_f16(v_scale_h, v_scale_h);

        for (src, dst) in src.chunks_exact(16).zip(dst.chunks_exact_mut(16)) {
            let items0 = xvldq_f16(src.as_ptr() as *const _);
            let items1 = xvldq_f16(src.get_unchecked(8..).as_ptr() as *const _);

            let j0 = xvmulq_f16(items0, v_scale);
            let j1 = xvmulq_f16(items1, v_scale);

            let values0 = xvcvtaq_u16_f16(j0);
            let values1 = xvcvtaq_u16_f16(j1);

            vst1q_u16(dst.as_mut_ptr(), values0);
            vst1q_u16(dst.get_unchecked_mut(8..).as_mut_ptr(), values1);
        }

        let src_rem = src.chunks_exact(16).remainder();
        let dst_rem = dst.chunks_exact_mut(16).into_remainder();

        for (src, dst) in src_rem.chunks_exact(8).zip(dst_rem.chunks_exact_mut(8)) {
            let items = xvldq_f16(src.as_ptr() as *const _);

            let values = xvcvtaq_u16_f16(xvmulq_f16(items, v_scale));

            vst1q_u16(dst.as_mut_ptr(), values);
        }

        let src_rem = src_rem.chunks_exact(8).remainder();
        let dst_rem = dst_rem.chunks_exact_mut(8).into_remainder();

        if !src_rem.is_empty() && !dst_rem.is_empty() {
            assert!(src_rem.len() <= 8);
            assert!(dst_rem.len() <= 8);
            let mut src_buffer: [f16; 8] = [0.; 8];
            let mut dst_buffer: [u16; 8] = [0; 8];
            std::ptr::copy_nonoverlapping(src_rem.as_ptr(), src_buffer.as_mut_ptr(), src_rem.len());

            let items = xvldq_f16(src_buffer.as_ptr() as *const _);
            let values = xvcvtaq_u16_f16(xvmulq_f16(items, v_scale));
            vst1q_u16(dst_buffer.as_mut_ptr(), values);

            std::ptr::copy_nonoverlapping(dst_buffer.as_ptr(), dst_rem.as_mut_ptr(), dst_rem.len());
        }
    }
}

impl SurfaceFloat16ToUnsigned<u16> for SurfaceF16ToUnsigned16Neon {
    fn to_unsigned(&self, src: &[f16], dst: &mut [u16], bit_depth: usize) {
        unsafe {
            self.to_unsigned_impl(src, dst, bit_depth);
        }
    }
}
