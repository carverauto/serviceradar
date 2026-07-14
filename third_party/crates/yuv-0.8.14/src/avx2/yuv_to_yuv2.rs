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
use crate::avx2::avx2_utils::{
    _mm256_deinterleave_x2_epi8, _mm256_havg_epu8, _mm256_store_interleaved_epi8,
};
use crate::yuv_support::{YuvChromaSubsampling, Yuy2Description};
use crate::yuv_to_yuy2::YuvToYuy2Navigation;
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn yuv_to_yuy2_avx2_row<const SAMPLING: u8, const YUY2_TARGET: usize>(
    y_plane: &[u8],
    u_plane: &[u8],
    v_plane: &[u8],
    yuy2_store: &mut [u8],
    width: u32,
    nav: YuvToYuy2Navigation,
) -> YuvToYuy2Navigation {
    unsafe {
        yuv_to_yuy2_avx2_row_impl::<SAMPLING, YUY2_TARGET>(
            y_plane, u_plane, v_plane, yuy2_store, width, nav,
        )
    }
}

#[target_feature(enable = "avx2")]
pub(crate) unsafe fn yuv_to_yuy2_avx2_row_impl<const SAMPLING: u8, const YUY2_TARGET: usize>(
    y_plane: &[u8],
    u_plane: &[u8],
    v_plane: &[u8],
    yuy2_store: &mut [u8],
    width: u32,
    nav: YuvToYuy2Navigation,
) -> YuvToYuy2Navigation {
    let yuy2_target: Yuy2Description = YUY2_TARGET.into();
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();

    let mut _cx = nav.cx;
    let mut _uv_x = nav.uv_x;
    let mut _yuy2_x = nav.x;
    let chroma_big_step = match chroma_subsampling {
        YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => 32,
        YuvChromaSubsampling::Yuv444 => 64,
    };
    unsafe {
        while _cx + 64 < width as usize {
            let u_pos = _uv_x;
            let v_pos = _uv_x;
            let y_pos = _cx;

            let u_pixels;
            let v_pixels;

            let y_ptr = y_plane.as_ptr().add(y_pos);
            let y_pixels = (
                _mm256_loadu_si256(y_ptr as *const __m256i),
                _mm256_loadu_si256(y_ptr.add(32) as *const __m256i),
            );

            if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
                let u_ptr = u_plane.as_ptr().add(u_pos);
                let full_u = (
                    _mm256_loadu_si256(u_ptr as *const __m256i),
                    _mm256_loadu_si256(u_ptr.add(32) as *const __m256i),
                );
                let v_ptr = v_plane.as_ptr().add(v_pos);
                let full_v = (
                    _mm256_loadu_si256(v_ptr as *const __m256i),
                    _mm256_loadu_si256(v_ptr.add(32) as *const __m256i),
                );

                u_pixels = _mm256_havg_epu8(full_u.0, full_u.1);
                v_pixels = _mm256_havg_epu8(full_v.0, full_v.1);
            } else {
                u_pixels = _mm256_loadu_si256(u_plane.as_ptr().add(u_pos) as *const __m256i);
                v_pixels = _mm256_loadu_si256(v_plane.as_ptr().add(v_pos) as *const __m256i);
            }

            let (low_y, high_y) = _mm256_deinterleave_x2_epi8(y_pixels.0, y_pixels.1);

            let storage = match yuy2_target {
                Yuy2Description::YUYV => (low_y, u_pixels, high_y, v_pixels),
                Yuy2Description::UYVY => (u_pixels, low_y, v_pixels, high_y),
                Yuy2Description::YVYU => (low_y, v_pixels, high_y, u_pixels),
                Yuy2Description::VYUY => (v_pixels, low_y, u_pixels, high_y),
            };

            let dst_offset = _cx * 2;

            _mm256_store_interleaved_epi8(
                yuy2_store.as_mut_ptr().add(dst_offset),
                storage.0,
                storage.1,
                storage.2,
                storage.3,
            );

            _uv_x += chroma_big_step;
            _cx += 64;
        }

        _yuy2_x = _cx;

        YuvToYuy2Navigation {
            cx: _cx,
            uv_x: _uv_x,
            x: _yuy2_x,
        }
    }
}
