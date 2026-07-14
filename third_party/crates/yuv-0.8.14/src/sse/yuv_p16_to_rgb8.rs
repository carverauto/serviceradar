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

#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

use crate::sse::{
    _mm_from_msb_epi16, _mm_store_interleave_half_rgb_for_yuv, _mm_store_shr_epi16_epi8,
};
use crate::yuv_support::{
    CbCrInverseTransform, YuvBytesPacking, YuvChromaRange, YuvChromaSubsampling, YuvEndianness,
    YuvSourceChannels,
};

pub(crate) fn sse_yuv_p16_to_rgba8_row<
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
        sse_yuv_p16_to_rgba8_row_impl::<
            DESTINATION_CHANNELS,
            SAMPLING,
            ENDIANNESS,
            BYTES_POSITION,
            BIT_DEPTH,
            PRECISION,
        >(y_plane, u_plane, v_plane, bgra, range, transform)
    }
}

#[target_feature(enable = "sse4.1")]
unsafe fn sse_yuv_p16_to_rgba8_row_impl<
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

    let v_alpha = _mm_set1_epi8(255u8 as i8);

    let y_corr = _mm_set1_epi16(bias_y as i16);
    let uv_corr = _mm_set1_epi16(bias_uv as i16);
    let uv_corr_q = _mm_set1_epi16(bias_uv as i16);
    let v_luma_coeff = _mm_set1_epi16(y_coef as i16);
    let v_cr_coeff = _mm_set1_epi16(cr_coef as i16);
    let v_cb_coeff = _mm_set1_epi16(cb_coef as i16);
    let v_g_coeff_1 = _mm_set1_epi16(-(g_coef_1 as i16));
    let v_g_coeff_2 = _mm_set1_epi16(-(g_coef_2 as i16));

    const SCALE: i32 = 2;
    #[cfg(feature = "big_endian")]
    let big_endian_shuffle_flag =
        _mm_setr_epi8(1, 0, 3, 2, 5, 4, 7, 6, 9, 8, 11, 10, 13, 12, 15, 14);

    let y_chunks = y_plane.chunks_exact(8);

    // For chroma, chunk size depends on subsampling
    let uv_chunk_size = match chroma_subsampling {
        YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => 4,
        YuvChromaSubsampling::Yuv444 => 8,
    };

    let u_chunks = u_plane.chunks_exact(uv_chunk_size);
    let v_chunks = v_plane.chunks_exact(uv_chunk_size);

    let dst_chunks = bgra.chunks_exact_mut(8 * channels);

    let remainder_y = y_chunks.remainder();
    let remainder_u = u_chunks.remainder();
    let remainder_v = v_chunks.remainder();

    for (((y_chunk, u_chunk), v_chunk), dst_chunk) in
        y_chunks.zip(u_chunks).zip(v_chunks).zip(dst_chunks)
    {
        let mut y_vl = _mm_loadu_si128(y_chunk.as_ptr() as *const __m128i);
        #[cfg(feature = "big_endian")]
        if _endianness == YuvEndianness::BigEndian {
            y_vl = _mm_shuffle_epi8(y_vl, big_endian_shuffle_flag);
        }
        if bytes_position == YuvBytesPacking::MostSignificantBytes {
            y_vl = _mm_from_msb_epi16::<BIT_DEPTH>(y_vl);
        }
        let mut y_values = _mm_subs_epu16(y_vl, y_corr);

        let mut u_values;
        let mut v_values;

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let mut u_vals = _mm_loadu_si64(u_chunk.as_ptr() as *const u8);
                let mut v_vals = _mm_loadu_si64(v_chunk.as_ptr() as *const u8);

                #[cfg(feature = "big_endian")]
                if _endianness == YuvEndianness::BigEndian {
                    u_vals = _mm_shuffle_epi8(u_vals, big_endian_shuffle_flag);
                    v_vals = _mm_shuffle_epi8(v_vals, big_endian_shuffle_flag);
                }
                if bytes_position == YuvBytesPacking::MostSignificantBytes {
                    u_vals = _mm_from_msb_epi16::<BIT_DEPTH>(u_vals);
                    v_vals = _mm_from_msb_epi16::<BIT_DEPTH>(v_vals);
                }

                let u_vl = _mm_unpacklo_epi16(u_vals, u_vals);
                let v_vl = _mm_unpacklo_epi16(v_vals, v_vals);

                u_values = _mm_sub_epi16(u_vl, uv_corr);
                v_values = _mm_sub_epi16(v_vl, uv_corr);
            }
            YuvChromaSubsampling::Yuv444 => {
                let mut u_vals = _mm_loadu_si128(u_chunk.as_ptr() as *const __m128i);
                let mut v_vals = _mm_loadu_si128(v_chunk.as_ptr() as *const __m128i);

                #[cfg(feature = "big_endian")]
                if _endianness == YuvEndianness::BigEndian {
                    u_vals = _mm_shuffle_epi8(u_vals, big_endian_shuffle_flag);
                    v_vals = _mm_shuffle_epi8(v_vals, big_endian_shuffle_flag);
                }
                if bytes_position == YuvBytesPacking::MostSignificantBytes {
                    u_vals = _mm_from_msb_epi16::<BIT_DEPTH>(u_vals);
                    v_vals = _mm_from_msb_epi16::<BIT_DEPTH>(v_vals);
                }
                u_values = _mm_sub_epi16(u_vals, uv_corr_q);
                v_values = _mm_sub_epi16(v_vals, uv_corr_q);
            }
        }

        u_values = _mm_slli_epi16::<SCALE>(u_values);
        v_values = _mm_slli_epi16::<SCALE>(v_values);
        y_values = _mm_slli_epi16::<SCALE>(y_values);

        let y_vals = _mm_mulhrs_epi16(y_values, v_luma_coeff);

        let r_vals = _mm_add_epi16(y_vals, _mm_mulhrs_epi16(v_values, v_cr_coeff));
        let b_vals = _mm_add_epi16(y_vals, _mm_mulhrs_epi16(u_values, v_cb_coeff));
        let g_vals = _mm_add_epi16(
            _mm_add_epi16(y_vals, _mm_mulhrs_epi16(v_values, v_g_coeff_1)),
            _mm_mulhrs_epi16(u_values, v_g_coeff_2),
        );

        let r_values = _mm_packus_epi16(
            _mm_store_shr_epi16_epi8::<BIT_DEPTH>(r_vals),
            _mm_setzero_si128(),
        );
        let g_values = _mm_packus_epi16(
            _mm_store_shr_epi16_epi8::<BIT_DEPTH>(g_vals),
            _mm_setzero_si128(),
        );
        let b_values = _mm_packus_epi16(
            _mm_store_shr_epi16_epi8::<BIT_DEPTH>(b_vals),
            _mm_setzero_si128(),
        );

        _mm_store_interleave_half_rgb_for_yuv::<DESTINATION_CHANNELS>(
            dst_chunk.as_mut_ptr(),
            r_values,
            g_values,
            b_values,
            v_alpha,
        );
    }

    let dst_chunks = bgra.chunks_exact_mut(8 * channels).into_remainder();

    if !remainder_y.is_empty() {
        let diff = remainder_y.len();
        assert!(diff <= 8);

        let mut y_buffer: [u16; 8] = [0; 8];
        let mut u_buffer: [u16; 8] = [0; 8];
        let mut v_buffer: [u16; 8] = [0; 8];

        let mut rgba: [u8; 8 * 4] = [0; 8 * 4];
        let (cut_rgba, _) = rgba.split_at_mut(channels * 8);

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

        sse_yuv_p16_to_rgba8_row_impl::<
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
