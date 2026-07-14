/*
 * Copyright (c) Radzivon Bartoshyk, 04/2026. All rights reserved.
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
    _avx_from_msb_epi16, _mm256_expand_bp_by2, _mm256_from_msb_epi16, _mm256_interleave_epi16,
    _mm256_store_interleave_rgb16_for_yuv,
};
use crate::yuv_support::{
    CbCrInverseTransform, YuvBytesPacking, YuvChromaRange, YuvEndianness, YuvSourceChannels,
};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn avx_yuv_p16_to_rgba_row420<
    const DESTINATION_CHANNELS: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const BIT_DEPTH: usize,
    const PRECISION: i32,
>(
    y_plane0: &[u16],
    y_plane1: &[u16],
    u_plane: &[u16],
    v_plane: &[u16],
    bgra0: &mut [u16],
    bgra1: &mut [u16],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
) {
    unsafe {
        avx_yuv_p16_to_rgba_row420_impl::<
            DESTINATION_CHANNELS,
            ENDIANNESS,
            BYTES_POSITION,
            BIT_DEPTH,
            PRECISION,
        >(
            y_plane0, y_plane1, u_plane, v_plane, bgra0, bgra1, width, range, transform,
        )
    }
}

#[target_feature(enable = "avx2")]
unsafe fn avx_yuv_p16_to_rgba_row420_impl<
    const DESTINATION_CHANNELS: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const BIT_DEPTH: usize,
    const PRECISION: i32,
>(
    y_plane0: &[u16],
    y_plane1: &[u16],
    u_plane: &[u16],
    v_plane: &[u16],
    bgra0: &mut [u16],
    bgra1: &mut [u16],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
) {
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = destination_channels.get_channels_count();
    let _endianness: YuvEndianness = ENDIANNESS.into();
    let bytes_position: YuvBytesPacking = BYTES_POSITION.into();
    let cr_coef = transform.cr_coef;
    let cb_coef = transform.cb_coef;
    let y_coef = transform.y_coef;
    let g_coef_1 = transform.g_coeff_1;
    let g_coef_2 = transform.g_coeff_2;

    let bias_y = range.bias_y as i32;
    let bias_uv = range.bias_uv as i32;

    let v_max_colors = _mm256_set1_epi16((1i16 << BIT_DEPTH as i16) - 1);

    let y_corr = _mm256_set1_epi16(bias_y as i16);
    let uv_corr = _mm256_set1_epi16(bias_uv as i16);
    let v_luma_coeff = _mm256_set1_epi16(y_coef as i16);
    let v_cr_coeff = _mm256_set1_epi16(cr_coef as i16);
    let v_cb_coeff = _mm256_set1_epi16(cb_coef as i16);
    let zeros = _mm256_setzero_si256();
    let v_g_coeff_1 = _mm256_set1_epi16(-(g_coef_1 as i16));
    let v_g_coeff_2 = _mm256_set1_epi16(-(g_coef_2 as i16));

    let mut cx = 0usize;
    let mut ux = 0usize;

    #[cfg(feature = "big_endian")]
    let big_endian_shuffle_flag = _mm256_setr_epi8(
        1, 0, 3, 2, 5, 4, 7, 6, 9, 8, 11, 10, 13, 12, 15, 14, 1, 0, 3, 2, 5, 4, 7, 6, 9, 8, 11, 10,
        13, 12, 15, 14,
    );

    #[cfg(feature = "big_endian")]
    let big_endian_shuffle_flag_sse =
        _mm_setr_epi8(1, 0, 3, 2, 5, 4, 7, 6, 9, 8, 11, 10, 13, 12, 15, 14);

    const SCALE: i32 = 2;

    while cx + 32 <= width as usize {
        // --- load and expand chroma (shared for both rows) ---
        let mut u_vals = _mm256_loadu_si256(u_plane.get_unchecked(ux..).as_ptr() as *const __m256i);
        let mut v_vals = _mm256_loadu_si256(v_plane.get_unchecked(ux..).as_ptr() as *const __m256i);

        #[cfg(feature = "big_endian")]
        if _endianness == YuvEndianness::BigEndian {
            u_vals = _mm256_shuffle_epi8(u_vals, big_endian_shuffle_flag);
            v_vals = _mm256_shuffle_epi8(v_vals, big_endian_shuffle_flag);
        }
        if bytes_position == YuvBytesPacking::MostSignificantBytes {
            u_vals = _mm256_from_msb_epi16::<BIT_DEPTH>(u_vals);
            v_vals = _mm256_from_msb_epi16::<BIT_DEPTH>(v_vals);
        }

        let (u_expanded0, u_expanded1) = _mm256_interleave_epi16(u_vals, u_vals);
        let (v_expanded0, v_expanded1) = _mm256_interleave_epi16(v_vals, v_vals);

        let u_values0 = _mm256_slli_epi16::<SCALE>(_mm256_sub_epi16(u_expanded0, uv_corr));
        let v_values0 = _mm256_slli_epi16::<SCALE>(_mm256_sub_epi16(v_expanded0, uv_corr));
        let u_values1 = _mm256_slli_epi16::<SCALE>(_mm256_sub_epi16(u_expanded1, uv_corr));
        let v_values1 = _mm256_slli_epi16::<SCALE>(_mm256_sub_epi16(v_expanded1, uv_corr));

        // --- row 0 ---
        let mut y_vl0_r0 =
            _mm256_loadu_si256(y_plane0.get_unchecked(cx..).as_ptr() as *const __m256i);
        let mut y_vl1_r0 =
            _mm256_loadu_si256(y_plane0.get_unchecked((cx + 16)..).as_ptr() as *const __m256i);

        #[cfg(feature = "big_endian")]
        if _endianness == YuvEndianness::BigEndian {
            y_vl0_r0 = _mm256_shuffle_epi8(y_vl0_r0, big_endian_shuffle_flag);
            y_vl1_r0 = _mm256_shuffle_epi8(y_vl1_r0, big_endian_shuffle_flag);
        }
        if bytes_position == YuvBytesPacking::MostSignificantBytes {
            y_vl0_r0 = _mm256_from_msb_epi16::<BIT_DEPTH>(y_vl0_r0);
            y_vl1_r0 = _mm256_from_msb_epi16::<BIT_DEPTH>(y_vl1_r0);
        }

        let y_values0_r0 = _mm256_expand_bp_by2::<BIT_DEPTH>(_mm256_subs_epu16(y_vl0_r0, y_corr));
        let y_values1_r0 = _mm256_expand_bp_by2::<BIT_DEPTH>(_mm256_subs_epu16(y_vl1_r0, y_corr));

        let y_vals0_r0 = _mm256_mulhrs_epi16(y_values0_r0, v_luma_coeff);
        let y_vals1_r0 = _mm256_mulhrs_epi16(y_values1_r0, v_luma_coeff);

        let r_vals0_r0 = _mm256_add_epi16(y_vals0_r0, _mm256_mulhrs_epi16(v_values0, v_cr_coeff));
        let b_vals0_r0 = _mm256_add_epi16(y_vals0_r0, _mm256_mulhrs_epi16(u_values0, v_cb_coeff));
        let g_vals0_r0 = _mm256_add_epi16(
            _mm256_add_epi16(y_vals0_r0, _mm256_mulhrs_epi16(v_values0, v_g_coeff_1)),
            _mm256_mulhrs_epi16(u_values0, v_g_coeff_2),
        );

        let r_vals1_r0 = _mm256_add_epi16(y_vals1_r0, _mm256_mulhrs_epi16(v_values1, v_cr_coeff));
        let b_vals1_r0 = _mm256_add_epi16(y_vals1_r0, _mm256_mulhrs_epi16(u_values1, v_cb_coeff));
        let g_vals1_r0 = _mm256_add_epi16(
            _mm256_add_epi16(y_vals1_r0, _mm256_mulhrs_epi16(v_values1, v_g_coeff_1)),
            _mm256_mulhrs_epi16(u_values1, v_g_coeff_2),
        );

        let r_values0_r0 = _mm256_min_epu16(_mm256_max_epi16(r_vals0_r0, zeros), v_max_colors);
        let g_values0_r0 = _mm256_min_epu16(_mm256_max_epi16(g_vals0_r0, zeros), v_max_colors);
        let b_values0_r0 = _mm256_min_epu16(_mm256_max_epi16(b_vals0_r0, zeros), v_max_colors);
        let r_values1_r0 = _mm256_min_epu16(_mm256_max_epi16(r_vals1_r0, zeros), v_max_colors);
        let g_values1_r0 = _mm256_min_epu16(_mm256_max_epi16(g_vals1_r0, zeros), v_max_colors);
        let b_values1_r0 = _mm256_min_epu16(_mm256_max_epi16(b_vals1_r0, zeros), v_max_colors);

        let dst_ptr0 = bgra0.get_unchecked_mut(cx * channels..);
        _mm256_store_interleave_rgb16_for_yuv::<DESTINATION_CHANNELS>(
            dst_ptr0.as_mut_ptr(),
            r_values0_r0,
            g_values0_r0,
            b_values0_r0,
            v_max_colors,
        );
        _mm256_store_interleave_rgb16_for_yuv::<DESTINATION_CHANNELS>(
            dst_ptr0.get_unchecked_mut(16 * channels..).as_mut_ptr(),
            r_values1_r0,
            g_values1_r0,
            b_values1_r0,
            v_max_colors,
        );

        // --- row 1 (same chroma u_values0/1, v_values0/1) ---
        let mut y_vl0_r1 =
            _mm256_loadu_si256(y_plane1.get_unchecked(cx..).as_ptr() as *const __m256i);
        let mut y_vl1_r1 =
            _mm256_loadu_si256(y_plane1.get_unchecked((cx + 16)..).as_ptr() as *const __m256i);

        #[cfg(feature = "big_endian")]
        if _endianness == YuvEndianness::BigEndian {
            y_vl0_r1 = _mm256_shuffle_epi8(y_vl0_r1, big_endian_shuffle_flag);
            y_vl1_r1 = _mm256_shuffle_epi8(y_vl1_r1, big_endian_shuffle_flag);
        }
        if bytes_position == YuvBytesPacking::MostSignificantBytes {
            y_vl0_r1 = _mm256_from_msb_epi16::<BIT_DEPTH>(y_vl0_r1);
            y_vl1_r1 = _mm256_from_msb_epi16::<BIT_DEPTH>(y_vl1_r1);
        }

        let y_values0_r1 = _mm256_expand_bp_by2::<BIT_DEPTH>(_mm256_subs_epu16(y_vl0_r1, y_corr));
        let y_values1_r1 = _mm256_expand_bp_by2::<BIT_DEPTH>(_mm256_subs_epu16(y_vl1_r1, y_corr));

        let y_vals0_r1 = _mm256_mulhrs_epi16(y_values0_r1, v_luma_coeff);
        let y_vals1_r1 = _mm256_mulhrs_epi16(y_values1_r1, v_luma_coeff);

        let r_vals0_r1 = _mm256_add_epi16(y_vals0_r1, _mm256_mulhrs_epi16(v_values0, v_cr_coeff));
        let b_vals0_r1 = _mm256_add_epi16(y_vals0_r1, _mm256_mulhrs_epi16(u_values0, v_cb_coeff));
        let g_vals0_r1 = _mm256_add_epi16(
            _mm256_add_epi16(y_vals0_r1, _mm256_mulhrs_epi16(v_values0, v_g_coeff_1)),
            _mm256_mulhrs_epi16(u_values0, v_g_coeff_2),
        );

        let r_vals1_r1 = _mm256_add_epi16(y_vals1_r1, _mm256_mulhrs_epi16(v_values1, v_cr_coeff));
        let b_vals1_r1 = _mm256_add_epi16(y_vals1_r1, _mm256_mulhrs_epi16(u_values1, v_cb_coeff));
        let g_vals1_r1 = _mm256_add_epi16(
            _mm256_add_epi16(y_vals1_r1, _mm256_mulhrs_epi16(v_values1, v_g_coeff_1)),
            _mm256_mulhrs_epi16(u_values1, v_g_coeff_2),
        );

        let r_values0_r1 = _mm256_min_epu16(_mm256_max_epi16(r_vals0_r1, zeros), v_max_colors);
        let g_values0_r1 = _mm256_min_epu16(_mm256_max_epi16(g_vals0_r1, zeros), v_max_colors);
        let b_values0_r1 = _mm256_min_epu16(_mm256_max_epi16(b_vals0_r1, zeros), v_max_colors);
        let r_values1_r1 = _mm256_min_epu16(_mm256_max_epi16(r_vals1_r1, zeros), v_max_colors);
        let g_values1_r1 = _mm256_min_epu16(_mm256_max_epi16(g_vals1_r1, zeros), v_max_colors);
        let b_values1_r1 = _mm256_min_epu16(_mm256_max_epi16(b_vals1_r1, zeros), v_max_colors);

        let dst_ptr1 = bgra1.get_unchecked_mut(cx * channels..);
        _mm256_store_interleave_rgb16_for_yuv::<DESTINATION_CHANNELS>(
            dst_ptr1.as_mut_ptr(),
            r_values0_r1,
            g_values0_r1,
            b_values0_r1,
            v_max_colors,
        );
        _mm256_store_interleave_rgb16_for_yuv::<DESTINATION_CHANNELS>(
            dst_ptr1.get_unchecked_mut(16 * channels..).as_mut_ptr(),
            r_values1_r1,
            g_values1_r1,
            b_values1_r1,
            v_max_colors,
        );

        cx += 32;
        ux += 16;
    }

    while cx + 16 <= width as usize {
        let mut u_vals = _mm_loadu_si128(u_plane.get_unchecked(ux..).as_ptr() as *const __m128i);
        let mut v_vals = _mm_loadu_si128(v_plane.get_unchecked(ux..).as_ptr() as *const __m128i);

        #[cfg(feature = "big_endian")]
        if _endianness == YuvEndianness::BigEndian {
            u_vals = _mm_shuffle_epi8(u_vals, big_endian_shuffle_flag_sse);
            v_vals = _mm_shuffle_epi8(v_vals, big_endian_shuffle_flag_sse);
        }
        if bytes_position == YuvBytesPacking::MostSignificantBytes {
            u_vals = _avx_from_msb_epi16::<BIT_DEPTH>(u_vals);
            v_vals = _avx_from_msb_epi16::<BIT_DEPTH>(v_vals);
        }

        let u_expanded = _mm256_slli_epi16::<SCALE>(_mm256_sub_epi16(
            _mm256_set_m128i(
                _mm_unpackhi_epi16(u_vals, u_vals),
                _mm_unpacklo_epi16(u_vals, u_vals),
            ),
            uv_corr,
        ));
        let v_expanded = _mm256_slli_epi16::<SCALE>(_mm256_sub_epi16(
            _mm256_set_m128i(
                _mm_unpackhi_epi16(v_vals, v_vals),
                _mm_unpacklo_epi16(v_vals, v_vals),
            ),
            uv_corr,
        ));

        // --- row 0 ---
        let mut y_vl_r0 =
            _mm256_loadu_si256(y_plane0.get_unchecked(cx..).as_ptr() as *const __m256i);

        #[cfg(feature = "big_endian")]
        if _endianness == YuvEndianness::BigEndian {
            y_vl_r0 = _mm256_shuffle_epi8(y_vl_r0, big_endian_shuffle_flag);
        }
        if bytes_position == YuvBytesPacking::MostSignificantBytes {
            y_vl_r0 = _mm256_from_msb_epi16::<BIT_DEPTH>(y_vl_r0);
        }

        let y_values_r0 = _mm256_expand_bp_by2::<BIT_DEPTH>(_mm256_subs_epu16(y_vl_r0, y_corr));
        let y_vals_r0 = _mm256_mulhrs_epi16(y_values_r0, v_luma_coeff);

        let r_vals_r0 = _mm256_add_epi16(y_vals_r0, _mm256_mulhrs_epi16(v_expanded, v_cr_coeff));
        let b_vals_r0 = _mm256_add_epi16(y_vals_r0, _mm256_mulhrs_epi16(u_expanded, v_cb_coeff));
        let g_vals_r0 = _mm256_add_epi16(
            _mm256_add_epi16(y_vals_r0, _mm256_mulhrs_epi16(v_expanded, v_g_coeff_1)),
            _mm256_mulhrs_epi16(u_expanded, v_g_coeff_2),
        );

        let r_values_r0 = _mm256_min_epu16(_mm256_max_epi16(r_vals_r0, zeros), v_max_colors);
        let g_values_r0 = _mm256_min_epu16(_mm256_max_epi16(g_vals_r0, zeros), v_max_colors);
        let b_values_r0 = _mm256_min_epu16(_mm256_max_epi16(b_vals_r0, zeros), v_max_colors);

        _mm256_store_interleave_rgb16_for_yuv::<DESTINATION_CHANNELS>(
            bgra0.get_unchecked_mut(cx * channels..).as_mut_ptr(),
            r_values_r0,
            g_values_r0,
            b_values_r0,
            v_max_colors,
        );

        // --- row 1 (same chroma u_expanded, v_expanded) ---
        let mut y_vl_r1 =
            _mm256_loadu_si256(y_plane1.get_unchecked(cx..).as_ptr() as *const __m256i);

        #[cfg(feature = "big_endian")]
        if _endianness == YuvEndianness::BigEndian {
            y_vl_r1 = _mm256_shuffle_epi8(y_vl_r1, big_endian_shuffle_flag);
        }
        if bytes_position == YuvBytesPacking::MostSignificantBytes {
            y_vl_r1 = _mm256_from_msb_epi16::<BIT_DEPTH>(y_vl_r1);
        }

        let y_values_r1 = _mm256_expand_bp_by2::<BIT_DEPTH>(_mm256_subs_epu16(y_vl_r1, y_corr));
        let y_vals_r1 = _mm256_mulhrs_epi16(y_values_r1, v_luma_coeff);

        let r_vals_r1 = _mm256_add_epi16(y_vals_r1, _mm256_mulhrs_epi16(v_expanded, v_cr_coeff));
        let b_vals_r1 = _mm256_add_epi16(y_vals_r1, _mm256_mulhrs_epi16(u_expanded, v_cb_coeff));
        let g_vals_r1 = _mm256_add_epi16(
            _mm256_add_epi16(y_vals_r1, _mm256_mulhrs_epi16(v_expanded, v_g_coeff_1)),
            _mm256_mulhrs_epi16(u_expanded, v_g_coeff_2),
        );

        let r_values_r1 = _mm256_min_epu16(_mm256_max_epi16(r_vals_r1, zeros), v_max_colors);
        let g_values_r1 = _mm256_min_epu16(_mm256_max_epi16(g_vals_r1, zeros), v_max_colors);
        let b_values_r1 = _mm256_min_epu16(_mm256_max_epi16(b_vals_r1, zeros), v_max_colors);

        _mm256_store_interleave_rgb16_for_yuv::<DESTINATION_CHANNELS>(
            bgra1.get_unchecked_mut(cx * channels..).as_mut_ptr(),
            r_values_r1,
            g_values_r1,
            b_values_r1,
            v_max_colors,
        );

        cx += 16;
        ux += 8;
    }

    if cx < width as usize {
        let diff = width as usize - cx;
        assert!(diff <= 16);

        let uv_size = diff.div_ceil(2);

        let mut y_buffer0: [u16; 16] = [0; 16];
        let mut y_buffer1: [u16; 16] = [0; 16];
        let mut u_buffer: [u16; 16] = [0; 16];
        let mut v_buffer: [u16; 16] = [0; 16];

        y_buffer0[..diff].copy_from_slice(&y_plane0[cx..cx + diff]);
        y_buffer1[..diff].copy_from_slice(&y_plane1[cx..cx + diff]);
        u_buffer[..uv_size].copy_from_slice(&u_plane[ux..ux + uv_size]);
        v_buffer[..uv_size].copy_from_slice(&v_plane[ux..ux + uv_size]);

        let mut wh_rgba0: [u16; 16 * 4] = [0; 16 * 4];
        let mut wh_rgba1: [u16; 16 * 4] = [0; 16 * 4];
        let (cut_rgba0, _) = wh_rgba0.split_at_mut(channels * 16);
        let (cut_rgba1, _) = wh_rgba1.split_at_mut(channels * 16);

        avx_yuv_p16_to_rgba_row420_impl::<
            DESTINATION_CHANNELS,
            ENDIANNESS,
            BYTES_POSITION,
            BIT_DEPTH,
            PRECISION,
        >(
            &y_buffer0, &y_buffer1, &u_buffer, &v_buffer, cut_rgba0, cut_rgba1, 16, range,
            transform,
        );

        bgra0[cx * channels..cx * channels + channels * diff]
            .copy_from_slice(&cut_rgba0[..channels * diff]);
        bgra1[cx * channels..cx * channels + channels * diff]
            .copy_from_slice(&cut_rgba1[..channels * diff]);
    }
}
