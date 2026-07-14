/*
 * Copyright (c) Radzivon Bartoshyk, 3/2026. All rights reserved.
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
use crate::avx2::avx2_utils::{_mm256_store_interleave_rgb_for_yuv, avx2_pack_u16};
use crate::internals::ProcessedOffset;
use crate::yuv_support::{YuvChromaRange, YuvSourceChannels};
use crate::YuvChromaSubsampling;
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) unsafe fn avx2_ycgco_full_range_to_rgb<
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
    unsafe {
        avx2_ycgco_full_range_to_rgb_impl::<DESTINATION_CHANNELS, SAMPLING>(
            y_plane,
            u_plane,
            v_plane,
            rgba,
            width,
            chroma_range,
        )
    }
}

#[target_feature(enable = "avx2")]
unsafe fn avx2_ycgco_full_range_to_rgb_impl<const DESTINATION_CHANNELS: u8, const SAMPLING: u8>(
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

    let rgba_ptr = rgba.as_mut_ptr();

    let bias_y = _mm256_set1_epi8(chroma_range.bias_y as i8);
    let bias_uv = _mm256_set1_epi8(chroma_range.bias_uv as i8);

    while cx + 32 <= width {
        let y_raw = _mm256_loadu_si256(y_plane.get_unchecked(cx..).as_ptr() as *const __m256i);
        let y_values = _mm256_subs_epu8(
            y_raw,
            _mm256_broadcastb_epi8(_mm256_castsi256_si128(bias_y)),
        );

        let (u_values, v_values) = match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let u_raw =
                    _mm_loadu_si128(u_plane.get_unchecked(uv_x..).as_ptr() as *const __m128i);
                let v_raw =
                    _mm_loadu_si128(v_plane.get_unchecked(uv_x..).as_ptr() as *const __m128i);
                let bias_uv_128 = _mm256_castsi256_si128(bias_uv);
                let u_sub = _mm_sub_epi8(u_raw, bias_uv_128);
                let v_sub = _mm_sub_epi8(v_raw, bias_uv_128);
                let u_interleaved = _mm_unpacklo_epi8(u_sub, u_sub);
                let u_high = _mm_unpackhi_epi8(u_sub, u_sub);
                let v_interleaved = _mm_unpacklo_epi8(v_sub, v_sub);
                let v_high = _mm_unpackhi_epi8(v_sub, v_sub);
                (
                    _mm256_set_m128i(u_high, u_interleaved),
                    _mm256_set_m128i(v_high, v_interleaved),
                )
            }
            YuvChromaSubsampling::Yuv444 => {
                let u_raw =
                    _mm256_loadu_si256(u_plane.get_unchecked(uv_x..).as_ptr() as *const __m256i);
                let v_raw =
                    _mm256_loadu_si256(v_plane.get_unchecked(uv_x..).as_ptr() as *const __m256i);
                (
                    _mm256_sub_epi8(u_raw, bias_uv),
                    _mm256_sub_epi8(v_raw, bias_uv),
                )
            }
        };

        let y_low = _mm256_cvtepu8_epi16(_mm256_castsi256_si128(y_values));
        let y_high = _mm256_cvtepu8_epi16(_mm256_extracti128_si256::<1>(y_values));

        let cg_low = _mm256_cvtepi8_epi16(_mm256_castsi256_si128(u_values));
        let cg_high = _mm256_cvtepi8_epi16(_mm256_extracti128_si256::<1>(u_values));
        let co_low = _mm256_cvtepi8_epi16(_mm256_castsi256_si128(v_values));
        let co_high = _mm256_cvtepi8_epi16(_mm256_extracti128_si256::<1>(v_values));

        // t = Y - Cg
        let t_low = _mm256_sub_epi16(y_low, cg_low);
        let t_high = _mm256_sub_epi16(y_high, cg_high);

        // R = t + Co, B = t - Co, G = Y + Cg
        let r_low = _mm256_add_epi16(t_low, co_low);
        let r_high = _mm256_add_epi16(t_high, co_high);
        let b_low = _mm256_sub_epi16(t_low, co_low);
        let b_high = _mm256_sub_epi16(t_high, co_high);
        let g_low = _mm256_add_epi16(y_low, cg_low);
        let g_high = _mm256_add_epi16(y_high, cg_high);

        // Pack i16 -> u8 with unsigned saturation
        let r_values = avx2_pack_u16(r_low, r_high);
        let g_values = avx2_pack_u16(g_low, g_high);
        let b_values = avx2_pack_u16(b_low, b_high);

        let dst_shift = cx * channels;
        _mm256_store_interleave_rgb_for_yuv::<DESTINATION_CHANNELS>(
            rgba_ptr.add(dst_shift),
            r_values,
            g_values,
            b_values,
            _mm256_set1_epi8(255u8 as i8),
        );

        cx += 32;
        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => uv_x += 16,
            YuvChromaSubsampling::Yuv444 => uv_x += 32,
        }
    }

    if cx < width {
        let diff = width - cx;
        assert!(diff < 32);

        let mut y_buffer: [u8; 32] = [0; 32];
        let mut u_buffer: [u8; 32] = [0; 32];
        let mut v_buffer: [u8; 32] = [0; 32];
        let mut dst_buffer: [u8; 32 * 4] = [0; 32 * 4];

        let ux_diff = match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => diff.div_ceil(2),
            YuvChromaSubsampling::Yuv444 => diff,
        };

        std::ptr::copy_nonoverlapping(
            y_plane.get_unchecked(cx..).as_ptr(),
            y_buffer.as_mut_ptr(),
            diff,
        );
        std::ptr::copy_nonoverlapping(
            u_plane.get_unchecked(uv_x..).as_ptr(),
            u_buffer.as_mut_ptr(),
            ux_diff,
        );
        std::ptr::copy_nonoverlapping(
            v_plane.get_unchecked(uv_x..).as_ptr(),
            v_buffer.as_mut_ptr(),
            ux_diff,
        );

        if chroma_subsampling != YuvChromaSubsampling::Yuv444 && diff % 2 != 0 {
            u_buffer[ux_diff] = u_buffer[ux_diff - 1];
            v_buffer[ux_diff] = v_buffer[ux_diff - 1];
        }

        avx2_ycgco_full_range_to_rgb::<DESTINATION_CHANNELS, SAMPLING>(
            &y_buffer,
            &u_buffer,
            &v_buffer,
            &mut dst_buffer,
            32,
            chroma_range,
        );

        let dst_shift = cx * channels;
        std::ptr::copy_nonoverlapping(
            dst_buffer.as_ptr(),
            rgba.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            diff * channels,
        );

        cx += diff;
        uv_x += ux_diff;
    }

    ProcessedOffset { cx, ux: uv_x }
}
