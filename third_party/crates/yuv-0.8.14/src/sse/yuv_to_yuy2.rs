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
use crate::sse::_mm_havg_epu8;
use crate::sse::utils::{
    __mm128x4, _mm_combineh_epi8, _mm_combinel_epi8, _mm_gethigh_epi8, _mm_getlow_epi8,
    _mm_loadu_si128_x2, _mm_storeu_si128_x4, sse_interleave_rgba,
};
use crate::yuv_support::{YuvChromaSubsampling, Yuy2Description};
use crate::yuv_to_yuy2::YuvToYuy2Navigation;
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn yuv_to_yuy2_sse<const SAMPLING: u8, const YUY2_TARGET: usize>(
    y_plane: &[u8],
    u_plane: &[u8],
    v_plane: &[u8],
    yuy2_store: &mut [u8],
    width: u32,
    nav: YuvToYuy2Navigation,
) -> YuvToYuy2Navigation {
    unsafe {
        yuv_to_yuy2_sse_impl::<SAMPLING, YUY2_TARGET>(
            y_plane, u_plane, v_plane, yuy2_store, width, nav,
        )
    }
}

#[target_feature(enable = "sse4.1")]
unsafe fn yuv_to_yuy2_sse_impl<const SAMPLING: u8, const YUY2_TARGET: usize>(
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

    let chroma_big_step_size = match chroma_subsampling {
        YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => 16,
        YuvChromaSubsampling::Yuv444 => 32,
    };

    let chroma_small_step_size = match chroma_subsampling {
        YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => 8,
        YuvChromaSubsampling::Yuv444 => 16,
    };

    unsafe {
        #[rustfmt::skip]
        let v_shuffle = _mm_setr_epi8(0, 2, 4, 6, 8, 10, 12, 14,
                                                1, 3, 5, 7, 9, 11, 13, 15);

        while _cx + 32 < width as usize {
            let u_pos = _uv_x;
            let v_pos = _uv_x;
            let y_pos = _cx;

            let u_pixels;
            let v_pixels;
            let y_pixels = _mm_loadu_si128_x2(y_plane.as_ptr().add(y_pos));

            if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
                let full_u = _mm_loadu_si128_x2(u_plane.as_ptr().add(u_pos));
                let full_v = _mm_loadu_si128_x2(v_plane.as_ptr().add(v_pos));

                u_pixels = _mm_havg_epu8(full_u.0, full_u.1);
                v_pixels = _mm_havg_epu8(full_v.0, full_v.1);
            } else {
                u_pixels = _mm_loadu_si128(u_plane.as_ptr().add(u_pos) as *const __m128i);
                v_pixels = _mm_loadu_si128(v_plane.as_ptr().add(v_pos) as *const __m128i);
            }

            let y_pixels_low = _mm_shuffle_epi8(y_pixels.0, v_shuffle);
            let y_pixels_high = _mm_shuffle_epi8(y_pixels.1, v_shuffle);

            let low_y = _mm_combinel_epi8(y_pixels_low, y_pixels_high);
            let high_y = _mm_combineh_epi8(y_pixels_low, y_pixels_high);

            let storage = match yuy2_target {
                Yuy2Description::YUYV => __mm128x4(low_y, u_pixels, high_y, v_pixels),
                Yuy2Description::UYVY => __mm128x4(u_pixels, low_y, v_pixels, high_y),
                Yuy2Description::YVYU => __mm128x4(low_y, v_pixels, high_y, u_pixels),
                Yuy2Description::VYUY => __mm128x4(v_pixels, low_y, u_pixels, high_y),
            };

            let dst_offset = _cx * 2;

            let inverleaved = sse_interleave_rgba(storage.0, storage.1, storage.2, storage.3);
            let converted = __mm128x4(inverleaved.0, inverleaved.1, inverleaved.2, inverleaved.3);

            _mm_storeu_si128_x4(yuy2_store.as_mut_ptr().add(dst_offset), converted);
            _cx += 32;
            _uv_x += chroma_big_step_size;
        }

        while _cx + 16 < width as usize {
            let u_pos = _uv_x;
            let v_pos = _uv_x;
            let y_pos = _cx;

            let u_pixels;
            let v_pixels;
            let mut y_pixels;

            y_pixels = _mm_loadu_si128(y_plane.as_ptr().add(y_pos) as *const __m128i);

            if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
                let full_u = _mm_loadu_si128(u_plane.as_ptr().add(u_pos) as *const __m128i);
                let full_v = _mm_loadu_si128(v_plane.as_ptr().add(v_pos) as *const __m128i);

                let low_u = _mm_getlow_epi8(full_u);
                let high_u = _mm_gethigh_epi8(full_u);
                u_pixels = _mm_havg_epu8(low_u, high_u);

                let low_v = _mm_getlow_epi8(full_v);
                let high_v = _mm_gethigh_epi8(full_v);

                v_pixels = _mm_havg_epu8(low_v, high_v);
            } else {
                u_pixels = _mm_loadu_si64(u_plane.as_ptr().add(u_pos));
                v_pixels = _mm_loadu_si64(v_plane.as_ptr().add(v_pos));
            }

            y_pixels = _mm_shuffle_epi8(y_pixels, v_shuffle);

            let low_y = _mm_getlow_epi8(y_pixels);
            let high_y = _mm_gethigh_epi8(y_pixels);

            let storage = match yuy2_target {
                Yuy2Description::YUYV => __mm128x4(low_y, u_pixels, high_y, v_pixels),
                Yuy2Description::UYVY => __mm128x4(u_pixels, low_y, v_pixels, high_y),
                Yuy2Description::YVYU => __mm128x4(low_y, v_pixels, high_y, u_pixels),
                Yuy2Description::VYUY => __mm128x4(v_pixels, low_y, u_pixels, high_y),
            };

            let inverleaved = sse_interleave_rgba(storage.0, storage.1, storage.2, storage.3);
            let converted = __mm128x4(inverleaved.0, inverleaved.1, inverleaved.2, inverleaved.3);

            let dst_offset = _cx * 2;

            let ptr = yuy2_store.as_mut_ptr().add(dst_offset);

            _mm_storeu_si128(ptr as *mut __m128i, converted.0);
            _mm_storeu_si128(ptr.add(16) as *mut __m128i, converted.1);

            _cx += 16;
            _uv_x += chroma_small_step_size;
        }

        _yuy2_x = _cx;
    }

    YuvToYuy2Navigation {
        cx: _cx,
        uv_x: _uv_x,
        x: _yuy2_x,
    }
}
