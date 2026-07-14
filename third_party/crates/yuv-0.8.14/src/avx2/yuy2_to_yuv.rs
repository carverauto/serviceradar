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
    _mm256_deinterleave_rgba_epi8, _mm256_interleave_epi8, _mm256_interleave_x2_epi8,
};
use crate::yuv_support::{YuvChromaSubsampling, Yuy2Description};
use crate::yuv_to_yuy2::YuvToYuy2Navigation;
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn yuy2_to_yuv_avx<const SAMPLING: u8, const YUY2_TARGET: usize>(
    y_plane: &mut [u8],
    u_plane: &mut [u8],
    v_plane: &mut [u8],
    yuy2_store: &[u8],
    width: u32,
    nav: YuvToYuy2Navigation,
) -> YuvToYuy2Navigation {
    unsafe {
        yuy2_to_yuv_avx_impl::<SAMPLING, YUY2_TARGET>(
            y_plane, u_plane, v_plane, yuy2_store, width, nav,
        )
    }
}

#[target_feature(enable = "avx2")]
unsafe fn yuy2_to_yuv_avx_impl<const SAMPLING: u8, const YUY2_TARGET: usize>(
    y_plane: &mut [u8],
    u_plane: &mut [u8],
    v_plane: &mut [u8],
    yuy2_store: &[u8],
    width: u32,
    nav: YuvToYuy2Navigation,
) -> YuvToYuy2Navigation {
    let yuy2_source: Yuy2Description = YUY2_TARGET.into();
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();

    let mut cx = nav.cx;
    let mut uv_x = nav.uv_x;
    let mut _yuy2_x = nav.x;

    while cx + 64 < width as usize {
        let dst_offset = cx * 2;
        let u_pos = uv_x;
        let v_pos = uv_x;
        let y_pos = cx;

        let yuy2_ptr = yuy2_store.get_unchecked(dst_offset..);

        let j0 = _mm256_loadu_si256(yuy2_ptr.as_ptr() as *const __m256i);
        let j1 = _mm256_loadu_si256(yuy2_ptr.get_unchecked(32..).as_ptr() as *const __m256i);
        let j2 = _mm256_loadu_si256(yuy2_ptr.get_unchecked(64..).as_ptr() as *const __m256i);
        let j3 = _mm256_loadu_si256(yuy2_ptr.get_unchecked(96..).as_ptr() as *const __m256i);

        let pixel_set = _mm256_deinterleave_rgba_epi8(j0, j1, j2, j3);
        let mut y_first = match yuy2_source {
            Yuy2Description::YUYV | Yuy2Description::YVYU => pixel_set.0,
            Yuy2Description::UYVY | Yuy2Description::VYUY => pixel_set.1,
        };
        let mut y_second = match yuy2_source {
            Yuy2Description::YUYV | Yuy2Description::YVYU => pixel_set.2,
            Yuy2Description::UYVY | Yuy2Description::VYUY => pixel_set.3,
        };

        (y_first, y_second) = _mm256_interleave_epi8(y_first, y_second);

        let u_value = match yuy2_source {
            Yuy2Description::YUYV => pixel_set.1,
            Yuy2Description::UYVY => pixel_set.0,
            Yuy2Description::YVYU => pixel_set.3,
            Yuy2Description::VYUY => pixel_set.2,
        };
        let v_value = match yuy2_source {
            Yuy2Description::YUYV => pixel_set.3,
            Yuy2Description::UYVY => pixel_set.2,
            Yuy2Description::YVYU => pixel_set.1,
            Yuy2Description::VYUY => pixel_set.0,
        };

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            let (low_u_value, high_u_value) = _mm256_interleave_x2_epi8(u_value, u_value);
            let (low_v_value, high_v_value) = _mm256_interleave_x2_epi8(v_value, v_value);

            let u_plane_ptr = u_plane.get_unchecked_mut(u_pos..);
            let v_plane_ptr = v_plane.get_unchecked_mut(v_pos..);

            _mm256_storeu_si256(u_plane_ptr.as_mut_ptr() as *mut __m256i, low_u_value);
            _mm256_storeu_si256(
                u_plane_ptr.get_unchecked_mut(32..).as_mut_ptr() as *mut __m256i,
                high_u_value,
            );
            _mm256_storeu_si256(v_plane_ptr.as_mut_ptr() as *mut __m256i, low_v_value);
            _mm256_storeu_si256(
                v_plane_ptr.get_unchecked_mut(32..).as_mut_ptr() as *mut __m256i,
                high_v_value,
            );
        } else {
            _mm256_storeu_si256(
                u_plane.get_unchecked_mut(u_pos..).as_mut_ptr() as *mut __m256i,
                u_value,
            );
            _mm256_storeu_si256(
                v_plane.get_unchecked_mut(v_pos..).as_mut_ptr() as *mut __m256i,
                v_value,
            );
        }

        let y_plane_ptr = y_plane.get_unchecked_mut(y_pos..);

        _mm256_storeu_si256(y_plane_ptr.as_mut_ptr() as *mut __m256i, y_first);
        _mm256_storeu_si256(
            y_plane_ptr.get_unchecked_mut(32..).as_mut_ptr() as *mut __m256i,
            y_second,
        );

        uv_x += match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => 32,
            YuvChromaSubsampling::Yuv444 => 64,
        };
        cx += 64;
    }

    _yuy2_x = cx;

    YuvToYuy2Navigation {
        cx,
        uv_x,
        x: _yuy2_x,
    }
}
