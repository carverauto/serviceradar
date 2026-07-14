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
    _mm256_from_msb_epi16, _mm256_interleave_epi16, _mm256_store_interleave_rgb_for_yuv,
    _mm256_store_shr_epi16_epi8, avx2_pack_u16,
};
use crate::yuv_support::{
    CbCrInverseTransform, YuvBytesPacking, YuvChromaRange, YuvChromaSubsampling, YuvEndianness,
    YuvSourceChannels,
};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn avx_yuv_p16_to_rgba8_row<
    const DESTINATION_CHANNELS: u8,
    const SAMPLING: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const BIT_DEPTH: usize,
    const PRECISION: i32,
>(
    y_plane: &[u16],
    u_plane: &[u16],
    v_plane: &[u16],
    bgra: &mut [u8],
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
) {
    unsafe {
        avx_yuv_p16_to_rgba_row8_impl::<
            DESTINATION_CHANNELS,
            SAMPLING,
            ENDIANNESS,
            BYTES_POSITION,
            BIT_DEPTH,
            PRECISION,
        >(y_plane, u_plane, v_plane, bgra, range, transform)
    }
}

#[target_feature(enable = "avx2")]
unsafe fn avx_yuv_p16_to_rgba_row8_impl<
    const DESTINATION_CHANNELS: u8,
    const SAMPLING: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const BIT_DEPTH: usize,
    const PRECISION: i32,
>(
    y_plane: &[u16],
    u_plane: &[u16],
    v_plane: &[u16],
    bgra: &mut [u8],
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
) {
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = destination_channels.get_channels_count();
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    let _endianness: YuvEndianness = ENDIANNESS.into();
    let bytes_position: YuvBytesPacking = BYTES_POSITION.into();
    let cr_coef = transform.cr_coef;
    let cb_coef = transform.cb_coef;
    let y_coef = transform.y_coef;
    let g_coef_1 = transform.g_coeff_1;
    let g_coef_2 = transform.g_coeff_2;

    let bias_y = range.bias_y as i32;
    let bias_uv = range.bias_uv as i32;

    let v_alpha = _mm256_set1_epi8(255u8 as i8);

    let y_corr = _mm256_set1_epi16(bias_y as i16);
    let uv_corr = _mm256_set1_epi16(bias_uv as i16);
    let v_luma_coeff = _mm256_set1_epi16(y_coef as i16);
    let v_cr_coeff = _mm256_set1_epi16(cr_coef as i16);
    let v_cb_coeff = _mm256_set1_epi16(cb_coef as i16);
    let v_g_coeff_1 = _mm256_set1_epi16(-(g_coef_1 as i16));
    let v_g_coeff_2 = _mm256_set1_epi16(-(g_coef_2 as i16));

    #[cfg(feature = "big_endian")]
    let big_endian_shuffle_flag = _mm256_setr_epi8(
        1, 0, 3, 2, 5, 4, 7, 6, 9, 8, 11, 10, 13, 12, 15, 14, 1, 0, 3, 2, 5, 4, 7, 6, 9, 8, 11, 10,
        13, 12, 15, 14,
    );

    const SCALE: i32 = 2;

    // For chroma, chunk size depends on subsampling
    let uv_chunk_size = match chroma_subsampling {
        YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => 16,
        YuvChromaSubsampling::Yuv444 => 32,
    };

    let y_chunks = y_plane.chunks_exact(32);

    let u_chunks = u_plane.chunks_exact(uv_chunk_size);
    let v_chunks = v_plane.chunks_exact(uv_chunk_size);

    let dst_chunks = bgra.chunks_exact_mut(32 * channels);

    let remainder_y = y_chunks.remainder();
    let remainder_u = u_chunks.remainder();
    let remainder_v = v_chunks.remainder();

    for (((y_chunk, u_chunk), v_chunk), dst_chunk) in
        y_chunks.zip(u_chunks).zip(v_chunks).zip(dst_chunks)
    {
        let mut y_vl0 = _mm256_loadu_si256(y_chunk.as_ptr() as *const __m256i);
        let mut y_vl1 = _mm256_loadu_si256(y_chunk.get_unchecked(16..).as_ptr() as *const __m256i);
        #[cfg(feature = "big_endian")]
        if _endianness == YuvEndianness::BigEndian {
            y_vl0 = _mm256_shuffle_epi8(y_vl0, big_endian_shuffle_flag);
            y_vl1 = _mm256_shuffle_epi8(y_vl1, big_endian_shuffle_flag);
        }
        if bytes_position == YuvBytesPacking::MostSignificantBytes {
            y_vl0 = _mm256_from_msb_epi16::<BIT_DEPTH>(y_vl0);
            y_vl1 = _mm256_from_msb_epi16::<BIT_DEPTH>(y_vl1);
        }
        let mut y_values0 = _mm256_subs_epu16(y_vl0, y_corr);
        let mut y_values1 = _mm256_subs_epu16(y_vl1, y_corr);

        let mut u_values0;
        let mut v_values0;

        let mut u_values1;
        let mut v_values1;

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let mut u_vals = _mm256_loadu_si256(u_chunk.as_ptr() as *const __m256i);
                let mut v_vals = _mm256_loadu_si256(v_chunk.as_ptr() as *const __m256i);

                #[cfg(feature = "big_endian")]
                if _endianness == YuvEndianness::BigEndian {
                    u_vals = _mm256_shuffle_epi8(u_vals, big_endian_shuffle_flag);
                    v_vals = _mm256_shuffle_epi8(v_vals, big_endian_shuffle_flag);
                }

                if bytes_position == YuvBytesPacking::MostSignificantBytes {
                    u_vals = _mm256_from_msb_epi16::<BIT_DEPTH>(u_vals);
                    v_vals = _mm256_from_msb_epi16::<BIT_DEPTH>(v_vals);
                }

                (u_values0, u_values1) = _mm256_interleave_epi16(u_vals, u_vals);
                (v_values0, v_values1) = _mm256_interleave_epi16(v_vals, v_vals);

                u_values0 = _mm256_sub_epi16(u_values0, uv_corr);
                v_values0 = _mm256_sub_epi16(v_values0, uv_corr);

                u_values1 = _mm256_sub_epi16(u_values1, uv_corr);
                v_values1 = _mm256_sub_epi16(v_values1, uv_corr);
            }
            YuvChromaSubsampling::Yuv444 => {
                let mut u_vals0 = _mm256_loadu_si256(u_chunk.as_ptr() as *const __m256i);
                let mut v_vals0 = _mm256_loadu_si256(v_chunk.as_ptr() as *const __m256i);
                let mut u_vals1 =
                    _mm256_loadu_si256(u_chunk.get_unchecked(16..).as_ptr() as *const __m256i);
                let mut v_vals1 =
                    _mm256_loadu_si256(v_chunk.get_unchecked(16..).as_ptr() as *const __m256i);
                #[cfg(feature = "big_endian")]
                if _endianness == YuvEndianness::BigEndian {
                    u_vals0 = _mm256_shuffle_epi8(u_vals0, big_endian_shuffle_flag);
                    v_vals0 = _mm256_shuffle_epi8(v_vals0, big_endian_shuffle_flag);

                    u_vals1 = _mm256_shuffle_epi8(u_vals1, big_endian_shuffle_flag);
                    v_vals1 = _mm256_shuffle_epi8(v_vals1, big_endian_shuffle_flag);
                }
                if bytes_position == YuvBytesPacking::MostSignificantBytes {
                    u_vals0 = _mm256_from_msb_epi16::<BIT_DEPTH>(u_vals0);
                    v_vals0 = _mm256_from_msb_epi16::<BIT_DEPTH>(v_vals0);
                    u_vals1 = _mm256_from_msb_epi16::<BIT_DEPTH>(u_vals1);
                    v_vals1 = _mm256_from_msb_epi16::<BIT_DEPTH>(v_vals1);
                }
                u_values0 = _mm256_sub_epi16(u_vals0, uv_corr);
                v_values0 = _mm256_sub_epi16(v_vals0, uv_corr);

                u_values1 = _mm256_sub_epi16(u_vals1, uv_corr);
                v_values1 = _mm256_sub_epi16(v_vals1, uv_corr);
            }
        }

        u_values0 = _mm256_slli_epi16::<SCALE>(u_values0);
        v_values0 = _mm256_slli_epi16::<SCALE>(v_values0);
        y_values0 = _mm256_slli_epi16::<SCALE>(y_values0);

        u_values1 = _mm256_slli_epi16::<SCALE>(u_values1);
        v_values1 = _mm256_slli_epi16::<SCALE>(v_values1);
        y_values1 = _mm256_slli_epi16::<SCALE>(y_values1);

        let y_vals0 = _mm256_mulhrs_epi16(y_values0, v_luma_coeff);
        let y_vals1 = _mm256_mulhrs_epi16(y_values1, v_luma_coeff);

        let rvl0 = _mm256_mulhrs_epi16(v_values0, v_cr_coeff);
        let bvl0 = _mm256_mulhrs_epi16(u_values0, v_cb_coeff);
        let gvl0 = _mm256_mulhrs_epi16(v_values0, v_g_coeff_1);
        let gvl1 = _mm256_mulhrs_epi16(u_values0, v_g_coeff_2);

        let r_vals0 = _mm256_add_epi16(y_vals0, rvl0);
        let b_vals0 = _mm256_add_epi16(y_vals0, bvl0);
        let g_vals0 = _mm256_add_epi16(_mm256_add_epi16(y_vals0, gvl0), gvl1);

        let rvl1 = _mm256_mulhrs_epi16(v_values1, v_cr_coeff);
        let bvl1 = _mm256_mulhrs_epi16(u_values1, v_cb_coeff);
        let gvl10 = _mm256_mulhrs_epi16(v_values1, v_g_coeff_1);
        let gvl11 = _mm256_mulhrs_epi16(u_values1, v_g_coeff_2);

        let r_vals1 = _mm256_add_epi16(y_vals1, rvl1);
        let b_vals1 = _mm256_add_epi16(y_vals1, bvl1);
        let g_vals1 = _mm256_add_epi16(_mm256_add_epi16(y_vals1, gvl10), gvl11);

        let r_values0 = avx2_pack_u16(
            _mm256_store_shr_epi16_epi8::<BIT_DEPTH>(r_vals0),
            _mm256_store_shr_epi16_epi8::<BIT_DEPTH>(r_vals1),
        );
        let g_values0 = avx2_pack_u16(
            _mm256_store_shr_epi16_epi8::<BIT_DEPTH>(g_vals0),
            _mm256_store_shr_epi16_epi8::<BIT_DEPTH>(g_vals1),
        );
        let b_values0 = avx2_pack_u16(
            _mm256_store_shr_epi16_epi8::<BIT_DEPTH>(b_vals0),
            _mm256_store_shr_epi16_epi8::<BIT_DEPTH>(b_vals1),
        );

        _mm256_store_interleave_rgb_for_yuv::<DESTINATION_CHANNELS>(
            dst_chunk.as_mut_ptr(),
            r_values0,
            g_values0,
            b_values0,
            v_alpha,
        );
    }

    let dst_chunks = bgra.chunks_exact_mut(32 * channels).into_remainder();

    if !remainder_y.is_empty() {
        let diff = remainder_y.len();
        assert!(diff <= 32);

        let mut y_buffer: [u16; 32] = [0; 32];
        let mut u_buffer: [u16; 32] = [0; 32];
        let mut v_buffer: [u16; 32] = [0; 32];

        let mut rgba: [u8; 32 * 4] = [0; 32 * 4];
        let (cut_rgba, _) = rgba.split_at_mut(channels * 32);

        y_buffer[..diff].copy_from_slice(remainder_y);
        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let uv_size = diff.div_ceil(2);
                u_buffer[..uv_size].copy_from_slice(remainder_u);
                v_buffer[..uv_size].copy_from_slice(remainder_v);
            }
            YuvChromaSubsampling::Yuv444 => {
                u_buffer[..diff].copy_from_slice(remainder_u);
                v_buffer[..diff].copy_from_slice(remainder_v);
            }
        }

        avx_yuv_p16_to_rgba_row8_impl::<
            DESTINATION_CHANNELS,
            SAMPLING,
            ENDIANNESS,
            BYTES_POSITION,
            BIT_DEPTH,
            PRECISION,
        >(&y_buffer, &u_buffer, &v_buffer, cut_rgba, range, transform);

        dst_chunks.copy_from_slice(&cut_rgba[..dst_chunks.len()]);
    }
}
