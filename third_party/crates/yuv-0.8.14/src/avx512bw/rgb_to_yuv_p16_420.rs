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
#[cfg(feature = "big_endian")]
use crate::avx512bw::avx512_setr::_v512_setr_epu8;
use crate::avx512bw::avx512_utils::{
    _mm512_affine_transform, _mm512_affine_uv_dot, _mm512_havg_epi16_epi32,
    _mm512_load_deinterleave_rgb16_for_yuv, _mm512_to_msb_epi16,
};
use crate::internals::ProcessedOffset;
use crate::yuv_support::{CbCrForwardTransform, YuvChromaRange, YuvSourceChannels};
use crate::{YuvBytesPacking, YuvEndianness};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn avx512_rgba_to_yuv_p16_420<
    const ORIGIN_CHANNELS: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const PRECISION: i32,
    const BIT_DEPTH: usize,
>(
    transform: &CbCrForwardTransform<i32>,
    range: &YuvChromaRange,
    y_plane0: &mut [u16],
    y_plane1: &mut [u16],
    u_plane: &mut [u16],
    v_plane: &mut [u16],
    rgba0: &[u16],
    rgba1: &[u16],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    unsafe {
        if std::arch::is_x86_feature_detected!("avx512vnni") {
            avx512_rgba_to_yuv_dot::<
                ORIGIN_CHANNELS,
                ENDIANNESS,
                BYTES_POSITION,
                PRECISION,
                BIT_DEPTH,
            >(
                transform, range, y_plane0, y_plane1, u_plane, v_plane, rgba0, rgba1, start_cx,
                start_ux, width,
            )
        } else {
            avx512_rgba_to_yuv_reg::<
                ORIGIN_CHANNELS,
                ENDIANNESS,
                BYTES_POSITION,
                PRECISION,
                BIT_DEPTH,
            >(
                transform, range, y_plane0, y_plane1, u_plane, v_plane, rgba0, rgba1, start_cx,
                start_ux, width,
            )
        }
    }
}

#[target_feature(enable = "avx512bw", enable = "avx512f")]
unsafe fn avx512_rgba_to_yuv_reg<
    const ORIGIN_CHANNELS: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const PRECISION: i32,
    const BIT_DEPTH: usize,
>(
    transform: &CbCrForwardTransform<i32>,
    range: &YuvChromaRange,
    y_plane0: &mut [u16],
    y_plane1: &mut [u16],
    u_plane: &mut [u16],
    v_plane: &mut [u16],
    rgba0: &[u16],
    rgba1: &[u16],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    avx512_rgba_to_yuv_impl::<
        ORIGIN_CHANNELS,
        ENDIANNESS,
        BYTES_POSITION,
        PRECISION,
        BIT_DEPTH,
        false,
    >(
        transform, range, y_plane0, y_plane1, u_plane, v_plane, rgba0, rgba1, start_cx, start_ux,
        width,
    )
}

#[target_feature(enable = "avx512bw", enable = "avx512f", enable = "avx512vnni")]
unsafe fn avx512_rgba_to_yuv_dot<
    const ORIGIN_CHANNELS: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const PRECISION: i32,
    const BIT_DEPTH: usize,
>(
    transform: &CbCrForwardTransform<i32>,
    range: &YuvChromaRange,
    y_plane0: &mut [u16],
    y_plane1: &mut [u16],
    u_plane: &mut [u16],
    v_plane: &mut [u16],
    rgba0: &[u16],
    rgba1: &[u16],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    avx512_rgba_to_yuv_impl::<ORIGIN_CHANNELS, ENDIANNESS, BYTES_POSITION, PRECISION, BIT_DEPTH, true>(
        transform, range, y_plane0, y_plane1, u_plane, v_plane, rgba0, rgba1, start_cx, start_ux,
        width,
    )
}

#[inline(always)]
unsafe fn avx512_rgba_to_yuv_impl<
    const ORIGIN_CHANNELS: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const PRECISION: i32,
    const BIT_DEPTH: usize,
    const HAS_DOT_PROD: bool,
>(
    transform: &CbCrForwardTransform<i32>,
    range: &YuvChromaRange,
    y_plane0: &mut [u16],
    y_plane1: &mut [u16],
    u_plane: &mut [u16],
    v_plane: &mut [u16],
    rgba0: &[u16],
    rgba1: &[u16],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    let source_channels: YuvSourceChannels = ORIGIN_CHANNELS.into();
    let _endianness: YuvEndianness = ENDIANNESS.into();
    let bytes_position: YuvBytesPacking = BYTES_POSITION.into();
    let channels = source_channels.get_channels_count();

    let rounding_const_bias: i32 = (1 << (PRECISION - 1)) - 1;
    let bias_y = range.bias_y as i32 * (1 << PRECISION) + rounding_const_bias;
    let bias_uv = range.bias_uv as i32 * (1 << PRECISION) + rounding_const_bias;

    let y_bias = _mm512_set1_epi32(bias_y);
    let uv_bias = _mm512_set1_epi32(bias_uv);
    let v_yr_yg = _mm512_set1_epi32(transform._interleaved_yr_yg());
    let v_yb = _mm512_set1_epi16(transform.yb as i16);
    let v_cbr_cbg = _mm512_set1_epi32(transform._interleaved_cbr_cbg());
    let v_cb_b = _mm512_set1_epi16(transform.cb_b as i16);
    let v_crr_vcrg = _mm512_set1_epi32(transform._interleaved_crr_crg());
    let v_cr_b = _mm512_set1_epi16(transform.cr_b as i16);

    #[cfg(feature = "big_endian")]
    let big_endian_shuffle_flag = _v512_setr_epu8(
        1, 0, 3, 2, 5, 4, 7, 6, 9, 8, 11, 10, 13, 12, 15, 14, 17, 16, 19, 18, 21, 20, 23, 22, 25,
        24, 27, 26, 29, 28, 31, 30, 33, 32, 35, 34, 37, 36, 39, 38, 41, 40, 43, 42, 45, 44, 47, 46,
        49, 48, 51, 50, 53, 52, 55, 54, 57, 56, 59, 58, 61, 60, 63, 62,
    );

    let mut cx = start_cx;
    let mut ux = start_ux;

    const PREC: u32 = 15;

    while cx + 32 < width {
        let src_ptr0 = rgba0.get_unchecked(cx * channels..);
        let (r_values0, g_values0, b_values0) =
            _mm512_load_deinterleave_rgb16_for_yuv::<ORIGIN_CHANNELS>(src_ptr0.as_ptr());
        let src_ptr1 = rgba1.get_unchecked(cx * channels..);
        let (r_values1, g_values1, b_values1) =
            _mm512_load_deinterleave_rgb16_for_yuv::<ORIGIN_CHANNELS>(src_ptr1.as_ptr());

        let zeros = _mm512_setzero_si512();
        let (r_g_lo0, r_g_hi0) = (
            _mm512_unpacklo_epi16(r_values0, g_values0),
            _mm512_unpackhi_epi16(r_values0, g_values0),
        );
        let b_hi0 = _mm512_unpackhi_epi16(b_values0, zeros);
        let b_lo0 = _mm512_unpacklo_epi16(b_values0, zeros);

        let mut y0_vl = _mm512_affine_uv_dot::<PREC, HAS_DOT_PROD>(
            y_bias, r_g_lo0, r_g_hi0, b_lo0, b_hi0, v_yr_yg, v_yb,
        );

        let (r_g_lo1, r_g_hi1) = (
            _mm512_unpacklo_epi16(r_values1, g_values1),
            _mm512_unpackhi_epi16(r_values1, g_values1),
        );
        let b_hi1 = _mm512_unpackhi_epi16(b_values1, zeros);
        let b_lo1 = _mm512_unpacklo_epi16(b_values1, zeros);

        let mut y1_vl = _mm512_affine_uv_dot::<PREC, HAS_DOT_PROD>(
            y_bias, r_g_lo1, r_g_hi1, b_lo1, b_hi1, v_yr_yg, v_yb,
        );

        if bytes_position == YuvBytesPacking::MostSignificantBytes {
            y0_vl = _mm512_to_msb_epi16::<BIT_DEPTH>(y0_vl);
            y1_vl = _mm512_to_msb_epi16::<BIT_DEPTH>(y1_vl);
        }

        #[cfg(feature = "big_endian")]
        if _endianness == YuvEndianness::BigEndian {
            y0_vl = _mm512_shuffle_epi8(y0_vl, big_endian_shuffle_flag);
            y1_vl = _mm512_shuffle_epi8(y1_vl, big_endian_shuffle_flag);
        }

        _mm512_storeu_si512(
            y_plane0.get_unchecked_mut(cx..).as_mut_ptr() as *mut _,
            y0_vl,
        );

        _mm512_storeu_si512(
            y_plane1.get_unchecked_mut(cx..).as_mut_ptr() as *mut _,
            y1_vl,
        );

        let rvl = _mm512_avg_epu16(r_values0, r_values1);
        let gvl = _mm512_avg_epu16(g_values0, g_values1);
        let bvl = _mm512_avg_epu16(b_values0, b_values1);

        let r_values = _mm512_havg_epi16_epi32(rvl);
        let g_values = _mm512_havg_epi16_epi32(gvl);
        let b_values = _mm512_havg_epi16_epi32(bvl);

        let r_g_values = _mm512_or_si512(r_values, _mm512_slli_epi32::<16>(g_values));

        let mut cb_s = _mm512_affine_transform::<PREC, HAS_DOT_PROD>(
            uv_bias, r_g_values, b_values, v_cbr_cbg, v_cb_b,
        );

        let mut cr_s = _mm512_affine_transform::<PREC, HAS_DOT_PROD>(
            uv_bias, r_g_values, b_values, v_crr_vcrg, v_cr_b,
        );

        if bytes_position == YuvBytesPacking::MostSignificantBytes {
            cb_s = _mm512_to_msb_epi16::<BIT_DEPTH>(cb_s);
            cr_s = _mm512_to_msb_epi16::<BIT_DEPTH>(cr_s);
        }

        #[cfg(feature = "big_endian")]
        if _endianness == YuvEndianness::BigEndian {
            cb_s = _mm512_shuffle_epi8(cb_s, big_endian_shuffle_flag);
            cr_s = _mm512_shuffle_epi8(cr_s, big_endian_shuffle_flag);
        }

        _mm256_storeu_si256(
            u_plane.get_unchecked_mut(ux..).as_mut_ptr() as *mut __m256i,
            _mm512_castsi512_si256(cb_s),
        );
        _mm256_storeu_si256(
            v_plane.get_unchecked_mut(ux..).as_mut_ptr() as *mut __m256i,
            _mm512_castsi512_si256(cr_s),
        );

        ux += 16;
        cx += 32;
    }

    if cx < width {
        let diff = width - cx;
        assert!(diff <= 32);
        let mut src_buffer0: [u16; 32 * 4] = [0; 32 * 4];
        let mut src_buffer1: [u16; 32 * 4] = [0; 32 * 4];

        // Replicate last item to one more position for subsampling
        if diff % 2 != 0 {
            let lst = (width - 1) * channels;
            let last_items0 = rgba0.get_unchecked(lst..(lst + channels));
            let last_items1 = rgba1.get_unchecked(lst..(lst + channels));
            let dvb = diff * channels;
            let dst0 = src_buffer0.get_unchecked_mut(dvb..(dvb + channels));
            let dst1 = src_buffer1.get_unchecked_mut(dvb..(dvb + channels));
            for (dst, src) in dst0.iter_mut().zip(last_items0) {
                *dst = *src;
            }
            for (dst, src) in dst1.iter_mut().zip(last_items1) {
                *dst = *src;
            }
        }

        std::ptr::copy_nonoverlapping(
            rgba0.get_unchecked(cx * channels..).as_ptr(),
            src_buffer0.as_mut_ptr(),
            diff * channels,
        );
        std::ptr::copy_nonoverlapping(
            rgba1.get_unchecked(cx * channels..).as_ptr(),
            src_buffer1.as_mut_ptr(),
            diff * channels,
        );

        let (r_values0, g_values0, b_values0) =
            _mm512_load_deinterleave_rgb16_for_yuv::<ORIGIN_CHANNELS>(src_buffer0.as_ptr());
        let (r_values1, g_values1, b_values1) =
            _mm512_load_deinterleave_rgb16_for_yuv::<ORIGIN_CHANNELS>(src_buffer1.as_ptr());

        let zeros = _mm512_setzero_si512();
        let (r_g_lo0, r_g_hi0) = (
            _mm512_unpacklo_epi16(r_values0, g_values0),
            _mm512_unpackhi_epi16(r_values0, g_values0),
        );
        let b_hi0 = _mm512_unpackhi_epi16(b_values0, zeros);
        let b_lo0 = _mm512_unpacklo_epi16(b_values0, zeros);

        let mut y0_vl = _mm512_affine_uv_dot::<PREC, HAS_DOT_PROD>(
            y_bias, r_g_lo0, r_g_hi0, b_lo0, b_hi0, v_yr_yg, v_yb,
        );

        let (r_g_lo1, r_g_hi1) = (
            _mm512_unpacklo_epi16(r_values1, g_values1),
            _mm512_unpackhi_epi16(r_values1, g_values1),
        );
        let b_hi1 = _mm512_unpackhi_epi16(b_values1, zeros);
        let b_lo1 = _mm512_unpacklo_epi16(b_values1, zeros);

        let mut y1_vl = _mm512_affine_uv_dot::<PREC, HAS_DOT_PROD>(
            y_bias, r_g_lo1, r_g_hi1, b_lo1, b_hi1, v_yr_yg, v_yb,
        );

        if bytes_position == YuvBytesPacking::MostSignificantBytes {
            y0_vl = _mm512_to_msb_epi16::<BIT_DEPTH>(y0_vl);
            y1_vl = _mm512_to_msb_epi16::<BIT_DEPTH>(y1_vl);
        }

        #[cfg(feature = "big_endian")]
        if _endianness == YuvEndianness::BigEndian {
            y0_vl = _mm512_shuffle_epi8(y0_vl, big_endian_shuffle_flag);
            y1_vl = _mm512_shuffle_epi8(y1_vl, big_endian_shuffle_flag);
        }

        let mask = 0xffff_ffffu32 >> (32 - diff as u32);

        _mm512_mask_storeu_epi16(
            y_plane0.get_unchecked_mut(cx..).as_mut_ptr() as *mut _,
            mask,
            y0_vl,
        );
        _mm512_mask_storeu_epi16(
            y_plane1.get_unchecked_mut(cx..).as_mut_ptr() as *mut _,
            mask,
            y1_vl,
        );

        let rvl = _mm512_avg_epu16(r_values0, r_values1);
        let gvl = _mm512_avg_epu16(g_values0, g_values1);
        let bvl = _mm512_avg_epu16(b_values0, b_values1);

        let r_values = _mm512_havg_epi16_epi32(rvl);
        let g_values = _mm512_havg_epi16_epi32(gvl);
        let b_values = _mm512_havg_epi16_epi32(bvl);

        let r_g_values = _mm512_or_si512(r_values, _mm512_slli_epi32::<16>(g_values));

        let mut cb_s = _mm512_affine_transform::<PREC, HAS_DOT_PROD>(
            uv_bias, r_g_values, b_values, v_cbr_cbg, v_cb_b,
        );

        let mut cr_s = _mm512_affine_transform::<PREC, HAS_DOT_PROD>(
            uv_bias, r_g_values, b_values, v_crr_vcrg, v_cr_b,
        );

        if bytes_position == YuvBytesPacking::MostSignificantBytes {
            cb_s = _mm512_to_msb_epi16::<BIT_DEPTH>(cb_s);
            cr_s = _mm512_to_msb_epi16::<BIT_DEPTH>(cr_s);
        }

        #[cfg(feature = "big_endian")]
        if _endianness == YuvEndianness::BigEndian {
            cb_s = _mm512_shuffle_epi8(cb_s, big_endian_shuffle_flag);
            cr_s = _mm512_shuffle_epi8(cr_s, big_endian_shuffle_flag);
        }

        let halved_mask = 0xffff_ffffu32 >> (32 - diff.div_ceil(2) as u32);

        _mm512_mask_storeu_epi16(
            u_plane.get_unchecked_mut(ux..).as_mut_ptr() as *mut _,
            halved_mask,
            cb_s,
        );
        _mm512_mask_storeu_epi16(
            v_plane.get_unchecked_mut(ux..).as_mut_ptr() as *mut _,
            halved_mask,
            cr_s,
        );

        cx += diff;

        let hv = diff.div_ceil(2);

        ux += hv;
    }

    ProcessedOffset { ux, cx }
}
