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
use crate::sse::{
    _mm_expand8_hi_to_10, _mm_expand8_lo_to_10, _mm_store_interleave_half_rgb_for_yuv,
    _mm_store_interleave_rgb_for_yuv,
};
use crate::yuv_support::{
    CbCrInverseTransform, YuvChromaRange, YuvChromaSubsampling, YuvNVOrder, YuvSourceChannels,
};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

/// This is common NV row conversion to RGBx, supports any subsampling
pub(crate) fn sse_yuv_nv_to_rgba<
    const UV_ORDER: u8,
    const DESTINATION_CHANNELS: u8,
    const YUV_CHROMA_SAMPLING: u8,
>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane: &[u8],
    uv_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    unsafe {
        sse_yuv_nv_to_rgba_impl::<UV_ORDER, DESTINATION_CHANNELS, YUV_CHROMA_SAMPLING>(
            range, transform, y_plane, uv_plane, rgba, start_cx, start_ux, width,
        )
    }
}

#[target_feature(enable = "sse4.1")]
unsafe fn sse_yuv_nv_to_rgba_impl<
    const UV_ORDER: u8,
    const DESTINATION_CHANNELS: u8,
    const YUV_CHROMA_SAMPLING: u8,
>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane: &[u8],
    uv_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    let order: YuvNVOrder = UV_ORDER.into();
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let chroma_subsampling: YuvChromaSubsampling = YUV_CHROMA_SAMPLING.into();
    let channels = destination_channels.get_channels_count();

    let mut cx = start_cx;
    let mut uv_x = start_ux;

    let y_ptr = y_plane.as_ptr();
    let uv_ptr = uv_plane.as_ptr();
    let rgba_ptr = rgba.as_mut_ptr();

    let y_corr = _mm_set1_epi8(range.bias_y as i8);
    let uv_corr = _mm_set1_epi16(((range.bias_uv as i16) << 2) | ((range.bias_uv as i16) >> 6));
    let v_luma_coeff = _mm_set1_epi16(transform.y_coef as i16);
    let v_cr_coeff = _mm_set1_epi16(transform.cr_coef as i16);
    let v_cb_coeff = _mm_set1_epi16(transform.cb_coef as i16);
    let v_g_coeff_1 = _mm_set1_epi16(transform.g_coeff_1 as i16);
    let v_g_coeff_2 = _mm_set1_epi16(transform.g_coeff_2 as i16);

    let zeros = _mm_setzero_si128();

    while cx + 16 < width {
        let y_values = _mm_subs_epu8(_mm_loadu_si128(y_ptr.add(cx) as *const __m128i), y_corr);

        let (mut u_high_u16, mut v_high_u16, mut u_low_u16, mut v_low_u16);

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let uv_values_ = _mm_loadu_si128(uv_ptr.add(uv_x) as *const __m128i);

                let sh_e = _mm_setr_epi8(0, 0, 2, 2, 4, 4, 6, 6, 8, 8, 10, 10, 12, 12, 14, 14);
                let sh_o = _mm_setr_epi8(1, 1, 3, 3, 5, 5, 7, 7, 9, 9, 11, 11, 13, 13, 15, 15);

                let mut u = _mm_shuffle_epi8(uv_values_, sh_e);
                let mut v = _mm_shuffle_epi8(uv_values_, sh_o);

                if order == YuvNVOrder::VU {
                    std::mem::swap(&mut u, &mut v);
                }

                let uhw = _mm_unpackhi_epi8(u, u);
                let vhw = _mm_unpackhi_epi8(v, v);
                let ulw = _mm_unpacklo_epi8(u, u);
                let vlw = _mm_unpacklo_epi8(v, v);

                u_high_u16 = _mm_srli_epi16::<6>(uhw);
                v_high_u16 = _mm_srli_epi16::<6>(vhw);
                u_low_u16 = _mm_srli_epi16::<6>(ulw);
                v_low_u16 = _mm_srli_epi16::<6>(vlw);
            }
            YuvChromaSubsampling::Yuv444 => {
                let uv_source_ptr = uv_ptr.add(uv_x);
                let row0 = _mm_loadu_si128(uv_source_ptr as *const __m128i);
                let row1 = _mm_loadu_si128(uv_source_ptr.add(16) as *const __m128i);

                let sh_e = _mm_setr_epi8(0, 0, 2, 2, 4, 4, 6, 6, 8, 8, 10, 10, 12, 12, 14, 14);
                let sh_o = _mm_setr_epi8(1, 1, 3, 3, 5, 5, 7, 7, 9, 9, 11, 11, 13, 13, 15, 15);

                let uhw = _mm_shuffle_epi8(row1, sh_e);
                let vhw = _mm_shuffle_epi8(row1, sh_o);
                let ulw = _mm_shuffle_epi8(row0, sh_e);
                let vlw = _mm_shuffle_epi8(row0, sh_o);

                u_high_u16 = _mm_srli_epi16::<6>(uhw);
                v_high_u16 = _mm_srli_epi16::<6>(vhw);
                u_low_u16 = _mm_srli_epi16::<6>(ulw);
                v_low_u16 = _mm_srli_epi16::<6>(vlw);

                if order == YuvNVOrder::VU {
                    std::mem::swap(&mut u_high_u16, &mut v_high_u16);
                    std::mem::swap(&mut u_low_u16, &mut v_low_u16);
                }
            }
        }

        let u_high = _mm_sub_epi16(u_high_u16, uv_corr);
        let v_high = _mm_sub_epi16(v_high_u16, uv_corr);
        let y_high = _mm_mulhrs_epi16(_mm_expand8_hi_to_10(y_values), v_luma_coeff);

        let r_high = _mm_add_epi16(y_high, _mm_mulhrs_epi16(v_high, v_cr_coeff));
        let b_high = _mm_add_epi16(y_high, _mm_mulhrs_epi16(u_high, v_cb_coeff));
        let g_high = _mm_sub_epi16(
            y_high,
            _mm_add_epi16(
                _mm_mulhrs_epi16(v_high, v_g_coeff_1),
                _mm_mulhrs_epi16(u_high, v_g_coeff_2),
            ),
        );

        let u_low = _mm_sub_epi16(u_low_u16, uv_corr);
        let v_low = _mm_sub_epi16(v_low_u16, uv_corr);
        let y_low = _mm_mulhrs_epi16(_mm_expand8_lo_to_10(y_values), v_luma_coeff);

        let r_low = _mm_add_epi16(y_low, _mm_mulhrs_epi16(v_low, v_cr_coeff));
        let b_low = _mm_add_epi16(y_low, _mm_mulhrs_epi16(u_low, v_cb_coeff));
        let g_low = _mm_sub_epi16(
            y_low,
            _mm_add_epi16(
                _mm_mulhrs_epi16(v_low, v_g_coeff_1),
                _mm_mulhrs_epi16(u_low, v_g_coeff_2),
            ),
        );

        let r_values = _mm_packus_epi16(r_low, r_high);
        let g_values = _mm_packus_epi16(g_low, g_high);
        let b_values = _mm_packus_epi16(b_low, b_high);

        let dst_shift = cx * channels;

        let v_alpha = _mm_set1_epi8(255u8 as i8);

        _mm_store_interleave_rgb_for_yuv::<DESTINATION_CHANNELS>(
            rgba_ptr.add(dst_shift),
            r_values,
            g_values,
            b_values,
            v_alpha,
        );

        cx += 16;

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                uv_x += 16;
            }
            YuvChromaSubsampling::Yuv444 => {
                uv_x += 32;
            }
        }
    }

    while cx + 8 < width {
        let y_vl0 = _mm_loadu_si64(y_ptr.add(cx));

        let (u_low_u16, v_low_u16);

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let uv_values_ = _mm_loadu_si64(uv_ptr.add(uv_x));

                let sh_e = _mm_setr_epi8(0, 0, 0, 0, 2, 2, 2, 2, 4, 4, 4, 4, 6, 6, 6, 6);
                let sh_o = _mm_setr_epi8(1, 1, 1, 1, 3, 3, 3, 3, 5, 5, 5, 5, 7, 7, 7, 7);

                let wu = _mm_shuffle_epi8(uv_values_, sh_e);
                let wv = _mm_shuffle_epi8(uv_values_, sh_o);

                let u = _mm_srli_epi16::<6>(wu);
                let v = _mm_srli_epi16::<6>(wv);

                match order {
                    YuvNVOrder::UV => {
                        u_low_u16 = u;
                        v_low_u16 = v;
                    }
                    YuvNVOrder::VU => {
                        u_low_u16 = v;
                        v_low_u16 = u;
                    }
                }
            }
            YuvChromaSubsampling::Yuv444 => {
                let uv_source_ptr = uv_ptr.add(uv_x);
                let row0 = _mm_loadu_si128(uv_source_ptr as *const __m128i);

                let sh_e = _mm_setr_epi8(0, 0, 2, 2, 4, 4, 6, 6, 8, 8, 10, 10, 12, 12, 14, 14);
                let sh_o = _mm_setr_epi8(1, 1, 3, 3, 5, 5, 7, 7, 9, 9, 11, 11, 13, 13, 15, 15);

                let wu = _mm_shuffle_epi8(row0, sh_e);
                let wv = _mm_shuffle_epi8(row0, sh_o);

                let u = _mm_srli_epi16::<6>(wu);
                let v = _mm_srli_epi16::<6>(wv);

                match order {
                    YuvNVOrder::UV => {
                        u_low_u16 = u;
                        v_low_u16 = v;
                    }
                    YuvNVOrder::VU => {
                        u_low_u16 = v;
                        v_low_u16 = u;
                    }
                }
            }
        }

        let y_values = _mm_subs_epi8(y_vl0, y_corr);
        let u_low = _mm_sub_epi16(u_low_u16, uv_corr);
        let v_low = _mm_sub_epi16(v_low_u16, uv_corr);
        let y_low = _mm_mulhrs_epi16(_mm_expand8_lo_to_10(y_values), v_luma_coeff);

        let r_low = _mm_add_epi16(y_low, _mm_mulhrs_epi16(v_low, v_cr_coeff));
        let b_low = _mm_add_epi16(y_low, _mm_mulhrs_epi16(u_low, v_cb_coeff));
        let g_low = _mm_sub_epi16(
            y_low,
            _mm_add_epi16(
                _mm_mulhrs_epi16(v_low, v_g_coeff_1),
                _mm_mulhrs_epi16(u_low, v_g_coeff_2),
            ),
        );

        let r_values = _mm_packus_epi16(r_low, zeros);
        let g_values = _mm_packus_epi16(g_low, zeros);
        let b_values = _mm_packus_epi16(b_low, zeros);

        let dst_shift = cx * channels;
        let dst_ptr = rgba_ptr.add(dst_shift);

        let v_alpha = _mm_set1_epi8(255u8 as i8);

        _mm_store_interleave_half_rgb_for_yuv::<DESTINATION_CHANNELS>(
            dst_ptr, r_values, g_values, b_values, v_alpha,
        );

        cx += 8;

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                uv_x += 8;
            }
            YuvChromaSubsampling::Yuv444 => {
                uv_x += 16;
            }
        }
    }

    if cx < width {
        let diff = width - cx;

        assert!(diff <= 8);

        let mut dst_buffer: [u8; 8 * 4] = [0; 8 * 4];
        let mut y_buffer: [u8; 8] = [0; 8];
        let mut uv_buffer: [u8; 8 * 2] = [0; 8 * 2];

        std::ptr::copy_nonoverlapping(
            y_plane.get_unchecked(cx..).as_ptr(),
            y_buffer.as_mut_ptr().cast(),
            diff,
        );

        let hv = match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => diff.div_ceil(2) * 2,
            YuvChromaSubsampling::Yuv444 => diff * 2,
        };

        std::ptr::copy_nonoverlapping(
            uv_plane.get_unchecked(uv_x..).as_ptr(),
            uv_buffer.as_mut_ptr().cast(),
            hv,
        );

        let y_vl0 = _mm_loadu_si64(y_buffer.as_ptr() as *const _);

        let (u_low_u16, v_low_u16);

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let uv_values_ = _mm_loadu_si64(uv_buffer.as_ptr().cast());

                let sh_e = _mm_setr_epi8(0, 0, 0, 0, 2, 2, 2, 2, 4, 4, 4, 4, 6, 6, 6, 6);
                let sh_o = _mm_setr_epi8(1, 1, 1, 1, 3, 3, 3, 3, 5, 5, 5, 5, 7, 7, 7, 7);

                let wu = _mm_shuffle_epi8(uv_values_, sh_e);
                let wv = _mm_shuffle_epi8(uv_values_, sh_o);

                let u = _mm_srli_epi16::<6>(wu);
                let v = _mm_srli_epi16::<6>(wv);

                match order {
                    YuvNVOrder::UV => {
                        u_low_u16 = u;
                        v_low_u16 = v;
                    }
                    YuvNVOrder::VU => {
                        u_low_u16 = v;
                        v_low_u16 = u;
                    }
                }
            }
            YuvChromaSubsampling::Yuv444 => {
                let row0 = _mm_loadu_si128(uv_buffer.as_ptr() as *const __m128i);

                let sh_e = _mm_setr_epi8(0, 0, 2, 2, 4, 4, 6, 6, 8, 8, 10, 10, 12, 12, 14, 14);
                let sh_o = _mm_setr_epi8(1, 1, 3, 3, 5, 5, 7, 7, 9, 9, 11, 11, 13, 13, 15, 15);

                let wu = _mm_shuffle_epi8(row0, sh_e);
                let wv = _mm_shuffle_epi8(row0, sh_o);

                let u = _mm_srli_epi16::<6>(wu);
                let v = _mm_srli_epi16::<6>(wv);

                match order {
                    YuvNVOrder::UV => {
                        u_low_u16 = u;
                        v_low_u16 = v;
                    }
                    YuvNVOrder::VU => {
                        u_low_u16 = v;
                        v_low_u16 = u;
                    }
                }
            }
        }

        let y_values = _mm_subs_epi8(y_vl0, y_corr);
        let u_low = _mm_sub_epi16(u_low_u16, uv_corr);
        let v_low = _mm_sub_epi16(v_low_u16, uv_corr);
        let y_low = _mm_mulhrs_epi16(_mm_expand8_lo_to_10(y_values), v_luma_coeff);

        let r_low = _mm_add_epi16(y_low, _mm_mulhrs_epi16(v_low, v_cr_coeff));
        let b_low = _mm_add_epi16(y_low, _mm_mulhrs_epi16(u_low, v_cb_coeff));
        let g_low = _mm_sub_epi16(
            y_low,
            _mm_add_epi16(
                _mm_mulhrs_epi16(v_low, v_g_coeff_1),
                _mm_mulhrs_epi16(u_low, v_g_coeff_2),
            ),
        );

        let r_values = _mm_packus_epi16(r_low, zeros);
        let g_values = _mm_packus_epi16(g_low, zeros);
        let b_values = _mm_packus_epi16(b_low, zeros);

        let v_alpha = _mm_set1_epi8(255u8 as i8);

        _mm_store_interleave_half_rgb_for_yuv::<DESTINATION_CHANNELS>(
            dst_buffer.as_mut_ptr().cast(),
            r_values,
            g_values,
            b_values,
            v_alpha,
        );

        let dst_shift = cx * channels;

        std::ptr::copy_nonoverlapping(
            dst_buffer.as_ptr().cast(),
            rgba.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            diff * channels,
        );

        cx += diff;
        uv_x += hv;
    }

    ProcessedOffset { cx, ux: uv_x }
}
