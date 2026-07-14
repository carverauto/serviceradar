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
    _mm_affine_transform, _mm_affine_v_dot, _mm_havg_epi16_epi32, _mm_interleave_epi16,
    _mm_load_deinterleave_rgb16_for_yuv, _mm_to_msb_epi16,
};
use crate::yuv_support::{
    CbCrForwardTransform, YuvChromaRange, YuvChromaSubsampling, YuvSourceChannels,
};
use crate::{YuvBytesPacking, YuvEndianness};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn sse_rgba_to_yuv_p16<
    const ORIGIN_CHANNELS: u8,
    const SAMPLING: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const PRECISION: i32,
    const BIT_DEPTH: usize,
>(
    transform: &CbCrForwardTransform<i32>,
    range: &YuvChromaRange,
    y_plane: &mut [u16],
    u_plane: &mut [u16],
    v_plane: &mut [u16],
    rgba: &[u16],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    unsafe {
        sse_rgba_to_yuv_impl::<
            ORIGIN_CHANNELS,
            SAMPLING,
            ENDIANNESS,
            BYTES_POSITION,
            PRECISION,
            BIT_DEPTH,
        >(
            transform, range, y_plane, u_plane, v_plane, rgba, start_cx, start_ux, width,
        )
    }
}

#[target_feature(enable = "sse4.1")]
unsafe fn sse_rgba_to_yuv_impl<
    const ORIGIN_CHANNELS: u8,
    const SAMPLING: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const PRECISION: i32,
    const BIT_DEPTH: usize,
>(
    transform: &CbCrForwardTransform<i32>,
    range: &YuvChromaRange,
    y_plane: &mut [u16],
    u_plane: &mut [u16],
    v_plane: &mut [u16],
    rgba: &[u16],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    let source_channels: YuvSourceChannels = ORIGIN_CHANNELS.into();
    let _endianness: YuvEndianness = ENDIANNESS.into();
    let bytes_position: YuvBytesPacking = BYTES_POSITION.into();
    let channels = source_channels.get_channels_count();

    let rounding_const_bias: i32 = (1 << (PRECISION - 1)) - 1;
    let bias_y = range.bias_y as i32 * (1 << PRECISION) + rounding_const_bias;
    let bias_uv = range.bias_uv as i32 * (1 << PRECISION) + rounding_const_bias;

    let src_ptr = rgba;

    let y_bias = _mm_set1_epi32(bias_y);
    let uv_bias = _mm_set1_epi32(bias_uv);
    let v_yr_yg = _mm_set1_epi32(transform._interleaved_yr_yg());
    let v_yb = _mm_set1_epi32(transform.yb);
    let v_cbr_cbg = _mm_set1_epi32(transform._interleaved_cbr_cbg());
    let v_cb_b = _mm_set1_epi32(transform.cb_b);
    let v_crr_vcrg = _mm_set1_epi32(transform._interleaved_crr_crg());
    let v_cr_b = _mm_set1_epi32(transform.cr_b);

    #[cfg(feature = "big_endian")]
    let big_endian_shuffle_flag =
        _mm_setr_epi8(1, 0, 3, 2, 5, 4, 7, 6, 9, 8, 11, 10, 13, 12, 15, 14);

    let mut cx = start_cx;
    let mut ux = start_ux;

    let zeros = _mm_setzero_si128();

    while cx + 8 < width {
        let src_ptr = src_ptr.get_unchecked(cx * channels..);
        let (r_values, g_values, b_values) =
            _mm_load_deinterleave_rgb16_for_yuv::<ORIGIN_CHANNELS>(src_ptr.as_ptr());

        let (r_g_lo, r_g_hi) = _mm_interleave_epi16(r_values, g_values);
        let b_hi = _mm_unpackhi_epi16(b_values, zeros);
        let b_lo = _mm_unpacklo_epi16(b_values, zeros);

        let mut y_vl =
            _mm_affine_v_dot::<PRECISION>(y_bias, r_g_lo, r_g_hi, b_lo, b_hi, v_yr_yg, v_yb);

        if bytes_position == YuvBytesPacking::MostSignificantBytes {
            y_vl = _mm_to_msb_epi16::<BIT_DEPTH>(y_vl);
        }

        #[cfg(feature = "big_endian")]
        if _endianness == YuvEndianness::BigEndian {
            y_vl = _mm_shuffle_epi8(y_vl, big_endian_shuffle_flag);
        }

        _mm_storeu_si128(
            y_plane.get_unchecked_mut(cx..).as_mut_ptr() as *mut __m128i,
            y_vl,
        );

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            let mut cb_vl = _mm_affine_v_dot::<PRECISION>(
                uv_bias, r_g_lo, r_g_hi, b_lo, b_hi, v_cbr_cbg, v_cb_b,
            );

            let mut cr_vl = _mm_affine_v_dot::<PRECISION>(
                uv_bias, r_g_lo, r_g_hi, b_lo, b_hi, v_crr_vcrg, v_cr_b,
            );

            if bytes_position == YuvBytesPacking::MostSignificantBytes {
                cb_vl = _mm_to_msb_epi16::<BIT_DEPTH>(cb_vl);
                cr_vl = _mm_to_msb_epi16::<BIT_DEPTH>(cr_vl);
            }

            #[cfg(feature = "big_endian")]
            if _endianness == YuvEndianness::BigEndian {
                cb_vl = _mm_shuffle_epi8(cb_vl, big_endian_shuffle_flag);
                cr_vl = _mm_shuffle_epi8(cr_vl, big_endian_shuffle_flag);
            }

            _mm_storeu_si128(
                u_plane.get_unchecked_mut(ux..).as_mut_ptr() as *mut __m128i,
                cb_vl,
            );
            _mm_storeu_si128(
                v_plane.get_unchecked_mut(ux..).as_mut_ptr() as *mut __m128i,
                cr_vl,
            );

            ux += 8;
        } else {
            let r_values = _mm_havg_epi16_epi32(r_values);
            let g_values = _mm_havg_epi16_epi32(g_values);
            let b_hadd = _mm_havg_epi16_epi32(b_values);

            let r_g_values = _mm_or_si128(r_values, _mm_slli_epi32::<16>(g_values));

            let mut cb_s =
                _mm_affine_transform::<PRECISION>(uv_bias, r_g_values, b_hadd, v_cbr_cbg, v_cb_b);

            let mut cr_s =
                _mm_affine_transform::<PRECISION>(uv_bias, r_g_values, b_hadd, v_crr_vcrg, v_cr_b);

            if bytes_position == YuvBytesPacking::MostSignificantBytes {
                cb_s = _mm_to_msb_epi16::<BIT_DEPTH>(cb_s);
                cr_s = _mm_to_msb_epi16::<BIT_DEPTH>(cr_s);
            }

            #[cfg(feature = "big_endian")]
            if _endianness == YuvEndianness::BigEndian {
                cb_s = _mm_shuffle_epi8(cb_s, big_endian_shuffle_flag);
                cr_s = _mm_shuffle_epi8(cr_s, big_endian_shuffle_flag);
            }

            _mm_storeu_si64(
                u_plane.get_unchecked_mut(ux..).as_mut_ptr() as *mut u8,
                cb_s,
            );
            _mm_storeu_si64(
                v_plane.get_unchecked_mut(ux..).as_mut_ptr() as *mut u8,
                cr_s,
            );

            ux += 4;
        }

        cx += 8;
    }

    if cx < width {
        let diff = width - cx;
        assert!(diff <= 8);
        let mut src_buffer: [u16; 8 * 4] = [0; 8 * 4];
        let mut y_buffer: [u16; 8] = [0; 8];
        let mut u_buffer: [u16; 8] = [0; 8];
        let mut v_buffer: [u16; 8] = [0; 8];

        // Replicate last item to one more position for subsampling
        if chroma_subsampling != YuvChromaSubsampling::Yuv444 && diff % 2 != 0 {
            let lst = (width - 1) * channels;
            let last_items = rgba.get_unchecked(lst..(lst + channels));
            let dvb = diff * channels;
            let dst = src_buffer.get_unchecked_mut(dvb..(dvb + channels));
            for (dst, src) in dst.iter_mut().zip(last_items) {
                *dst = *src;
            }
        }

        std::ptr::copy_nonoverlapping(
            rgba.get_unchecked(cx * channels..).as_ptr(),
            src_buffer.as_mut_ptr().cast(),
            diff * channels,
        );

        let (r_values, g_values, b_values) =
            _mm_load_deinterleave_rgb16_for_yuv::<ORIGIN_CHANNELS>(src_buffer.as_ptr().cast());

        let (r_g_lo, r_g_hi) = _mm_interleave_epi16(r_values, g_values);
        let b_hi = _mm_unpackhi_epi16(b_values, zeros);
        let b_lo = _mm_unpacklo_epi16(b_values, zeros);

        let mut y_vl =
            _mm_affine_v_dot::<PRECISION>(y_bias, r_g_lo, r_g_hi, b_lo, b_hi, v_yr_yg, v_yb);

        if bytes_position == YuvBytesPacking::MostSignificantBytes {
            y_vl = _mm_to_msb_epi16::<BIT_DEPTH>(y_vl);
        }

        #[cfg(feature = "big_endian")]
        if _endianness == YuvEndianness::BigEndian {
            y_vl = _mm_shuffle_epi8(y_vl, big_endian_shuffle_flag);
        }

        _mm_storeu_si128(y_buffer.as_mut_ptr() as *mut __m128i, y_vl);

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            let mut cb_vl = _mm_affine_v_dot::<PRECISION>(
                uv_bias, r_g_lo, r_g_hi, b_lo, b_hi, v_cbr_cbg, v_cb_b,
            );

            let mut cr_vl = _mm_affine_v_dot::<PRECISION>(
                uv_bias, r_g_lo, r_g_hi, b_lo, b_hi, v_crr_vcrg, v_cr_b,
            );

            if bytes_position == YuvBytesPacking::MostSignificantBytes {
                cb_vl = _mm_to_msb_epi16::<BIT_DEPTH>(cb_vl);
                cr_vl = _mm_to_msb_epi16::<BIT_DEPTH>(cr_vl);
            }

            #[cfg(feature = "big_endian")]
            if _endianness == YuvEndianness::BigEndian {
                cb_vl = _mm_shuffle_epi8(cb_vl, big_endian_shuffle_flag);
                cr_vl = _mm_shuffle_epi8(cr_vl, big_endian_shuffle_flag);
            }

            _mm_storeu_si128(u_buffer.as_mut_ptr() as *mut __m128i, cb_vl);
            _mm_storeu_si128(v_buffer.as_mut_ptr() as *mut __m128i, cr_vl);
        } else {
            let r_values = _mm_havg_epi16_epi32(r_values);
            let g_values = _mm_havg_epi16_epi32(g_values);
            let b_hadd = _mm_havg_epi16_epi32(b_values);

            let r_g_values = _mm_or_si128(r_values, _mm_slli_epi32::<16>(g_values));

            let mut cb_s =
                _mm_affine_transform::<PRECISION>(uv_bias, r_g_values, b_hadd, v_cbr_cbg, v_cb_b);

            let mut cr_s =
                _mm_affine_transform::<PRECISION>(uv_bias, r_g_values, b_hadd, v_crr_vcrg, v_cr_b);

            if bytes_position == YuvBytesPacking::MostSignificantBytes {
                cb_s = _mm_to_msb_epi16::<BIT_DEPTH>(cb_s);
                cr_s = _mm_to_msb_epi16::<BIT_DEPTH>(cr_s);
            }

            #[cfg(feature = "big_endian")]
            if _endianness == YuvEndianness::BigEndian {
                cb_s = _mm_shuffle_epi8(cb_s, big_endian_shuffle_flag);
                cr_s = _mm_shuffle_epi8(cr_s, big_endian_shuffle_flag);
            }

            _mm_storeu_si64(u_buffer.as_mut_ptr() as *mut u8, cb_s);
            _mm_storeu_si64(v_buffer.as_mut_ptr() as *mut u8, cr_s);
        }

        std::ptr::copy_nonoverlapping(
            y_buffer.as_ptr().cast(),
            y_plane.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );

        cx += diff;

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            std::ptr::copy_nonoverlapping(
                u_buffer.as_ptr().cast(),
                u_plane.get_unchecked_mut(ux..).as_mut_ptr(),
                diff,
            );
            std::ptr::copy_nonoverlapping(
                v_buffer.as_ptr().cast(),
                v_plane.get_unchecked_mut(ux..).as_mut_ptr(),
                diff,
            );

            ux += diff;
        } else if (chroma_subsampling == YuvChromaSubsampling::Yuv420)
            || (chroma_subsampling == YuvChromaSubsampling::Yuv422)
        {
            let hv = diff.div_ceil(2);
            std::ptr::copy_nonoverlapping(
                u_buffer.as_ptr().cast(),
                u_plane.get_unchecked_mut(ux..).as_mut_ptr(),
                hv,
            );
            std::ptr::copy_nonoverlapping(
                v_buffer.as_ptr().cast(),
                v_plane.get_unchecked_mut(ux..).as_mut_ptr(),
                hv,
            );

            ux += hv;
        }
    }

    ProcessedOffset { ux, cx }
}
