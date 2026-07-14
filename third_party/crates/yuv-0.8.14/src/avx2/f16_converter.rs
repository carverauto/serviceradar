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
use crate::f16_converter::SurfaceToFloat16;
use core::f16;
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

#[derive(Default)]
pub(crate) struct SurfaceU16ToFloat16Avx2 {}

impl SurfaceU16ToFloat16Avx2 {
    #[target_feature(enable = "avx2", enable = "f16c")]
    unsafe fn to_float16_impl(&self, src: &[u16], dst: &mut [f16], bit_depth: usize) {
        let max_colors = (1 << bit_depth) - 1;
        let v_scale_h = _mm256_set1_ps(1. / max_colors as f32);

        for (src, dst) in src.chunks_exact(16).zip(dst.chunks_exact_mut(16)) {
            let items = _mm256_loadu_si256(src.as_ptr() as *const _);

            let lc = _mm256_cvtepi16_epi32(_mm256_castsi256_si128(items));
            let hc = _mm256_cvtepi16_epi32(_mm256_extracti128_si256::<1>(items));

            let elc = _mm256_cvtepi32_ps(lc);
            let ehc = _mm256_cvtepi32_ps(hc);

            let mlc = _mm256_mul_ps(elc, v_scale_h);
            let mhc = _mm256_mul_ps(ehc, v_scale_h);

            let lo = _mm256_cvtps_ph::<_MM_FROUND_TO_NEAREST_INT>(mlc);
            let hi = _mm256_cvtps_ph::<_MM_FROUND_TO_NEAREST_INT>(mhc);

            let vals = _mm256_set_m128i(hi, lo);

            _mm256_storeu_si256(dst.as_mut_ptr() as *mut _, vals);
        }

        let src_rem = src.chunks_exact(16).remainder();
        let dst_rem = dst.chunks_exact_mut(16).into_remainder();

        for (src, dst) in src_rem.chunks_exact(8).zip(dst_rem.chunks_exact_mut(8)) {
            let items = _mm_loadu_si128(src.as_ptr() as *const _);

            let lo = _mm256_cvtps_ph::<_MM_FROUND_TO_NEAREST_INT>(_mm256_mul_ps(
                _mm256_cvtepi32_ps(_mm256_cvtepi16_epi32(items)),
                v_scale_h,
            ));

            _mm_storeu_si128(dst.as_mut_ptr() as *mut _, lo);
        }

        let src_rem = src.chunks_exact(8).remainder();
        let dst_rem = dst.chunks_exact_mut(8).into_remainder();

        if !src_rem.is_empty() && !dst_rem.is_empty() {
            assert!(src_rem.len() <= 8);
            assert!(dst_rem.len() <= 8);
            let mut src_buffer: [u16; 8] = [0; 8];
            let mut dst_buffer: [f16; 8] = [0.; 8];

            std::ptr::copy_nonoverlapping(src_rem.as_ptr(), src_buffer.as_mut_ptr(), src_rem.len());

            let items = _mm_loadu_si128(src_buffer.as_ptr() as *const _);

            let lo = _mm256_cvtps_ph::<_MM_FROUND_TO_NEAREST_INT>(_mm256_mul_ps(
                _mm256_cvtepi32_ps(_mm256_cvtepi16_epi32(items)),
                v_scale_h,
            ));

            _mm_storeu_si128(dst_buffer.as_mut_ptr() as *mut _, lo);

            std::ptr::copy_nonoverlapping(dst_buffer.as_ptr(), dst_rem.as_mut_ptr(), dst_rem.len());
        }
    }
}

impl SurfaceToFloat16<u16> for SurfaceU16ToFloat16Avx2 {
    fn to_float16(&self, src: &[u16], dst: &mut [f16], bit_depth: usize) {
        unsafe {
            self.to_float16_impl(src, dst, bit_depth);
        }
    }
}

#[derive(Default)]
pub(crate) struct SurfaceU8ToFloat16Avx2 {}

impl SurfaceU8ToFloat16Avx2 {
    #[target_feature(enable = "avx2", enable = "f16c")]
    unsafe fn to_float16_impl(&self, src: &[u8], dst: &mut [f16], bit_depth: usize) {
        let max_colors = (1 << bit_depth) - 1;
        let v_scale_h = _mm256_set1_ps(1. / max_colors as f32);

        for (src, dst) in src.chunks_exact(16).zip(dst.chunks_exact_mut(16)) {
            let items = _mm_loadu_si128(src.as_ptr() as *const _);

            let lo_items = _mm_unpacklo_epi8(items, _mm_setzero_si128());
            let hi_items = _mm_unpackhi_epi8(items, _mm_setzero_si128());

            let l_e32 = _mm256_cvtepi16_epi32(lo_items);
            let h_e32 = _mm256_cvtepi16_epi32(hi_items);

            let lc_ps = _mm256_cvtepi32_ps(l_e32);
            let hc_ps = _mm256_cvtepi32_ps(h_e32);

            let mut ls_ps = _mm256_mul_ps(lc_ps, v_scale_h);
            let mut hs_ps = _mm256_mul_ps(hc_ps, v_scale_h);

            ls_ps = _mm256_round_ps::<0x0>(ls_ps);
            hs_ps = _mm256_round_ps::<0x0>(hs_ps);

            let lo = _mm256_cvtps_ph::<_MM_FROUND_TO_NEAREST_INT>(ls_ps);
            let hi = _mm256_cvtps_ph::<_MM_FROUND_TO_NEAREST_INT>(hs_ps);

            let vals = _mm256_set_m128i(hi, lo);

            _mm256_storeu_si256(dst.as_mut_ptr() as *mut _, vals);
        }

        let src_rem = src.chunks_exact(16).remainder();
        let dst_rem = dst.chunks_exact_mut(16).into_remainder();

        for (src, dst) in src_rem.chunks_exact(8).zip(dst_rem.chunks_exact_mut(8)) {
            let items = _mm_unpacklo_epi8(
                _mm_loadu_si64(src.as_ptr() as *const _),
                _mm_setzero_si128(),
            );

            let lo = _mm256_cvtps_ph::<_MM_FROUND_TO_NEAREST_INT>(_mm256_round_ps::<0x0>(
                _mm256_mul_ps(_mm256_cvtepi32_ps(_mm256_cvtepi16_epi32(items)), v_scale_h),
            ));

            _mm_storeu_si128(dst.as_mut_ptr() as *mut _, lo);
        }

        let src_rem = src.chunks_exact(8).remainder();
        let dst_rem = dst.chunks_exact_mut(8).into_remainder();

        if !src_rem.is_empty() && !dst_rem.is_empty() {
            assert!(src_rem.len() <= 8);
            assert!(dst_rem.len() <= 8);
            let mut src_buffer: [u8; 8] = [0; 8];
            let mut dst_buffer: [f16; 8] = [0.; 8];

            std::ptr::copy_nonoverlapping(src_rem.as_ptr(), src_buffer.as_mut_ptr(), src_rem.len());

            let items = _mm_unpacklo_epi16(
                _mm_loadu_si64(src_buffer.as_ptr() as *const _),
                _mm_setzero_si128(),
            );

            let lo = _mm256_cvtps_ph::<_MM_FROUND_TO_NEAREST_INT>(_mm256_round_ps::<0x0>(
                _mm256_mul_ps(_mm256_cvtepi32_ps(_mm256_cvtepi16_epi32(items)), v_scale_h),
            ));

            _mm_storeu_si128(dst_buffer.as_mut_ptr() as *mut _, lo);

            std::ptr::copy_nonoverlapping(dst_buffer.as_ptr(), dst_rem.as_mut_ptr(), dst_rem.len());
        }
    }
}

impl SurfaceToFloat16<u8> for SurfaceU8ToFloat16Avx2 {
    fn to_float16(&self, src: &[u8], dst: &mut [f16], bit_depth: usize) {
        unsafe {
            self.to_float16_impl(src, dst, bit_depth);
        }
    }
}
