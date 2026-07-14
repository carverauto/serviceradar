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
    _mm256_load_deinterleave_rgb16_for_yuv, _mm256_rphadd_epi32_epi16, _mm256_to_msb_epi16,
    avx2_pack_u32,
};
use crate::internals::ProcessedOffset;
use crate::yuv_support::{
    CbCrForwardTransform, YuvChromaRange, YuvChromaSubsampling, YuvSourceChannels,
};
use crate::{YuvBytesPacking, YuvEndianness};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn avx_rgba_to_yuv_p16_d16<
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
        #[cfg(feature = "nightly_avx512")]
        #[allow(clippy::incompatible_msrv)]
        if std::arch::is_x86_feature_detected!("avxvnni") {
            return avx_rgba_to_yuv_vnni_d16::<
                ORIGIN_CHANNELS,
                SAMPLING,
                ENDIANNESS,
                BYTES_POSITION,
                PRECISION,
                BIT_DEPTH,
            >(
                transform, range, y_plane, u_plane, v_plane, rgba, start_cx, start_ux, width,
            );
        }
        avx_rgba_to_yuv_reg_d16::<
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

#[target_feature(enable = "avx2")]
unsafe fn avx_rgba_to_yuv_reg_d16<
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
    avx_rgba_to_yuv_d16_impl::<
        ORIGIN_CHANNELS,
        SAMPLING,
        ENDIANNESS,
        BYTES_POSITION,
        PRECISION,
        BIT_DEPTH,
        false,
    >(
        transform, range, y_plane, u_plane, v_plane, rgba, start_cx, start_ux, width,
    )
}

#[cfg(feature = "nightly_avx512")]
#[target_feature(enable = "avx2", enable = "avxvnni")]
unsafe fn avx_rgba_to_yuv_vnni_d16<
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
    avx_rgba_to_yuv_d16_impl::<
        ORIGIN_CHANNELS,
        SAMPLING,
        ENDIANNESS,
        BYTES_POSITION,
        PRECISION,
        BIT_DEPTH,
        true,
    >(
        transform, range, y_plane, u_plane, v_plane, rgba, start_cx, start_ux, width,
    )
}

#[inline(always)]
unsafe fn avx_rgba_to_yuv_d16_impl<
    const ORIGIN_CHANNELS: u8,
    const SAMPLING: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const PRECISION: i32,
    const BIT_DEPTH: usize,
    const HAS_DOT: bool,
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

    #[cfg(feature = "big_endian")]
    let big_endian_shuffle_flag = _mm256_setr_epi8(
        1, 0, 3, 2, 5, 4, 7, 6, 9, 8, 11, 10, 13, 12, 15, 14, 1, 0, 3, 2, 5, 4, 7, 6, 9, 8, 11, 10,
        13, 12, 15, 14,
    );

    let mut cx = start_cx;
    let mut ux = start_ux;

    while cx + 16 <= width {
        let src_ptr = src_ptr.get_unchecked(cx * channels..);
        let (r_values, g_values, b_values) =
            _mm256_load_deinterleave_rgb16_for_yuv::<ORIGIN_CHANNELS>(src_ptr.as_ptr());

        let (r_lo, r_hi) = (
            _mm256_unpacklo_epi16(r_values, _mm256_setzero_si256()),
            _mm256_unpackhi_epi16(r_values, _mm256_setzero_si256()),
        );
        let (g_lo, g_hi) = (
            _mm256_unpacklo_epi16(g_values, _mm256_setzero_si256()),
            _mm256_unpackhi_epi16(g_values, _mm256_setzero_si256()),
        );
        let b_hi = _mm256_unpackhi_epi16(b_values, _mm256_setzero_si256());
        let b_lo = _mm256_unpacklo_epi16(b_values, _mm256_setzero_si256());

        let y_bias = _mm256_set1_epi32(bias_y);
        let v_yr = _mm256_set1_epi32(transform.yr);
        let v_yb = _mm256_set1_epi32(transform.yb);
        let v_yg = _mm256_set1_epi32(transform.yg);

        let mut y_vl0 = _mm256_mullo_epi32(r_lo, v_yr);
        let mut y_vl1 = _mm256_mullo_epi32(r_hi, v_yr);

        let y_vl0_1 = _mm256_mullo_epi32(g_lo, v_yg);
        let y_vl1_1 = _mm256_mullo_epi32(g_hi, v_yg);

        y_vl0 = _mm256_add_epi32(y_vl0, y_vl0_1);
        y_vl1 = _mm256_add_epi32(y_vl1, y_vl1_1);

        let y_vl0_2 = _mm256_mullo_epi32(b_lo, v_yb);
        let y_vl1_2 = _mm256_mullo_epi32(b_hi, v_yb);

        y_vl0 = _mm256_add_epi32(y_vl0, y_bias);
        y_vl1 = _mm256_add_epi32(y_vl1, y_bias);

        y_vl0 = _mm256_add_epi32(y_vl0, y_vl0_2);
        y_vl1 = _mm256_add_epi32(y_vl1, y_vl1_2);

        y_vl0 = _mm256_srai_epi32::<PRECISION>(y_vl0);
        y_vl1 = _mm256_srai_epi32::<PRECISION>(y_vl1);

        let mut y_vl = _mm256_packus_epi32(y_vl0, y_vl1);

        if bytes_position == YuvBytesPacking::MostSignificantBytes {
            y_vl = _mm256_to_msb_epi16::<BIT_DEPTH>(y_vl);
        }

        #[cfg(feature = "big_endian")]
        if _endianness == YuvEndianness::BigEndian {
            y_vl = _mm256_shuffle_epi8(y_vl, big_endian_shuffle_flag);
        }

        _mm256_storeu_si256(
            y_plane.get_unchecked_mut(cx..).as_mut_ptr() as *mut __m256i,
            y_vl,
        );

        let uv_bias = _mm256_set1_epi32(bias_uv);
        let v_cb_r = _mm256_set1_epi32(transform.cb_r);
        let v_cb_g = _mm256_set1_epi32(transform.cb_g);
        let v_cb_b = _mm256_set1_epi32(transform.cb_b);
        let v_cr_r = _mm256_set1_epi32(transform.cr_r);
        let v_cr_g = _mm256_set1_epi32(transform.cr_g);
        let v_cr_b = _mm256_set1_epi32(transform.cr_b);

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            let mut cb_vl0 = _mm256_mullo_epi32(r_lo, v_cb_r);
            let mut cb_vl1 = _mm256_mullo_epi32(r_hi, v_cb_r);
            let mut cr_vl0 = _mm256_mullo_epi32(r_lo, v_cr_r);
            let mut cr_vl1 = _mm256_mullo_epi32(r_hi, v_cr_r);

            let cb_vl0_g = _mm256_mullo_epi32(g_lo, v_cb_g);
            let cb_vl1_g = _mm256_mullo_epi32(g_hi, v_cb_g);

            let cr_vl0_g = _mm256_mullo_epi32(g_lo, v_cr_g);
            let cr_vl1_g = _mm256_mullo_epi32(g_hi, v_cr_g);

            cb_vl0 = _mm256_add_epi32(cb_vl0, cb_vl0_g);
            cb_vl1 = _mm256_add_epi32(cb_vl1, cb_vl1_g);
            cr_vl0 = _mm256_add_epi32(cr_vl0, cr_vl0_g);
            cr_vl1 = _mm256_add_epi32(cr_vl1, cr_vl1_g);

            let cb_vl0_b = _mm256_mullo_epi32(b_lo, v_cb_b);
            let cb_vl1_b = _mm256_mullo_epi32(b_hi, v_cb_b);

            let cr_vl0_b = _mm256_mullo_epi32(b_lo, v_cr_b);
            let cr_vl1_b = _mm256_mullo_epi32(b_hi, v_cr_b);

            cb_vl0 = _mm256_add_epi32(cb_vl0, uv_bias);
            cb_vl1 = _mm256_add_epi32(cb_vl1, uv_bias);
            cr_vl0 = _mm256_add_epi32(cr_vl0, uv_bias);
            cr_vl1 = _mm256_add_epi32(cr_vl1, uv_bias);

            cb_vl0 = _mm256_add_epi32(cb_vl0, cb_vl0_b);
            cb_vl1 = _mm256_add_epi32(cb_vl1, cb_vl1_b);
            cr_vl0 = _mm256_add_epi32(cr_vl0, cr_vl0_b);
            cr_vl1 = _mm256_add_epi32(cr_vl1, cr_vl1_b);

            cb_vl0 = _mm256_srai_epi32::<PRECISION>(cb_vl0);
            cb_vl1 = _mm256_srai_epi32::<PRECISION>(cb_vl1);
            cr_vl0 = _mm256_srai_epi32::<PRECISION>(cr_vl0);
            cr_vl1 = _mm256_srai_epi32::<PRECISION>(cr_vl1);

            let mut cb_vl = _mm256_packus_epi32(cb_vl0, cb_vl1);
            let mut cr_vl = _mm256_packus_epi32(cr_vl0, cr_vl1);

            if bytes_position == YuvBytesPacking::MostSignificantBytes {
                cb_vl = _mm256_to_msb_epi16::<BIT_DEPTH>(cb_vl);
                cr_vl = _mm256_to_msb_epi16::<BIT_DEPTH>(cr_vl);
            }
            #[cfg(feature = "big_endian")]
            if _endianness == YuvEndianness::BigEndian {
                cb_vl = _mm256_shuffle_epi8(cb_vl, big_endian_shuffle_flag);
                cr_vl = _mm256_shuffle_epi8(cr_vl, big_endian_shuffle_flag);
            }

            _mm256_storeu_si256(
                u_plane.get_unchecked_mut(ux..).as_mut_ptr() as *mut __m256i,
                cb_vl,
            );
            _mm256_storeu_si256(
                v_plane.get_unchecked_mut(ux..).as_mut_ptr() as *mut __m256i,
                cr_vl,
            );

            ux += 16;
        } else {
            let r_values = _mm256_rphadd_epi32_epi16(r_values);
            let g_values = _mm256_rphadd_epi32_epi16(g_values);
            let b_values = _mm256_rphadd_epi32_epi16(b_values);

            let mut cb_0 = _mm256_mullo_epi32(r_values, v_cb_r);
            let mut cr_0 = _mm256_mullo_epi32(r_values, v_cr_r);

            let cb_1 = _mm256_mullo_epi32(g_values, v_cb_g);
            let cr_1 = _mm256_mullo_epi32(g_values, v_cr_g);

            let cb_2 = _mm256_mullo_epi32(b_values, v_cb_b);
            let cr_2 = _mm256_mullo_epi32(b_values, v_cr_b);

            cb_0 = _mm256_add_epi32(cb_0, uv_bias);
            cr_0 = _mm256_add_epi32(cr_0, uv_bias);

            cb_0 = _mm256_add_epi32(cb_0, cb_1);
            cr_0 = _mm256_add_epi32(cr_0, cr_1);

            cb_0 = _mm256_add_epi32(cb_0, cb_2);
            cr_0 = _mm256_add_epi32(cr_0, cr_2);

            cb_0 = _mm256_srai_epi32::<PRECISION>(cb_0);
            cr_0 = _mm256_srai_epi32::<PRECISION>(cr_0);

            let mut cb_s = avx2_pack_u32(cb_0, cb_0);
            let mut cr_s = avx2_pack_u32(cr_0, cr_0);

            if bytes_position == YuvBytesPacking::MostSignificantBytes {
                cb_s = _mm256_to_msb_epi16::<BIT_DEPTH>(cb_s);
                cr_s = _mm256_to_msb_epi16::<BIT_DEPTH>(cr_s);
            }
            #[cfg(feature = "big_endian")]
            if _endianness == YuvEndianness::BigEndian {
                cb_s = _mm256_shuffle_epi8(cb_s, big_endian_shuffle_flag);
                cr_s = _mm256_shuffle_epi8(cr_s, big_endian_shuffle_flag);
            }

            _mm_storeu_si128(
                u_plane.get_unchecked_mut(ux..).as_mut_ptr() as *mut __m128i,
                _mm256_castsi256_si128(cb_s),
            );
            _mm_storeu_si128(
                v_plane.get_unchecked_mut(ux..).as_mut_ptr() as *mut __m128i,
                _mm256_castsi256_si128(cr_s),
            );

            ux += 8;
        }

        cx += 16;
    }

    if cx < width {
        let diff = width - cx;
        assert!(diff <= 16);
        let mut src_buffer: [u16; 16 * 4] = [0; 16 * 4];
        let mut y_buffer: [u16; 16] = [0; 16];
        let mut u_buffer: [u16; 16] = [0; 16];
        let mut v_buffer: [u16; 16] = [0; 16];

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
            _mm256_load_deinterleave_rgb16_for_yuv::<ORIGIN_CHANNELS>(src_buffer.as_ptr().cast());

        let (r_lo, r_hi) = (
            _mm256_unpacklo_epi16(r_values, _mm256_setzero_si256()),
            _mm256_unpackhi_epi16(r_values, _mm256_setzero_si256()),
        );
        let (g_lo, g_hi) = (
            _mm256_unpacklo_epi16(g_values, _mm256_setzero_si256()),
            _mm256_unpackhi_epi16(g_values, _mm256_setzero_si256()),
        );
        let b_hi = _mm256_unpackhi_epi16(b_values, _mm256_setzero_si256());
        let b_lo = _mm256_unpacklo_epi16(b_values, _mm256_setzero_si256());

        let y_bias = _mm256_set1_epi32(bias_y);
        let v_yr = _mm256_set1_epi32(transform.yr);
        let v_yb = _mm256_set1_epi32(transform.yb);
        let v_yg = _mm256_set1_epi32(transform.yg);

        let mut y_vl0 = _mm256_mullo_epi32(r_lo, v_yr);
        let mut y_vl1 = _mm256_mullo_epi32(r_hi, v_yr);

        let y_vl0_1 = _mm256_mullo_epi32(g_lo, v_yg);
        let y_vl1_1 = _mm256_mullo_epi32(g_hi, v_yg);

        y_vl0 = _mm256_add_epi32(y_vl0, y_vl0_1);
        y_vl1 = _mm256_add_epi32(y_vl1, y_vl1_1);

        let y_vl0_2 = _mm256_mullo_epi32(b_lo, v_yb);
        let y_vl1_2 = _mm256_mullo_epi32(b_hi, v_yb);

        y_vl0 = _mm256_add_epi32(y_vl0, y_bias);
        y_vl1 = _mm256_add_epi32(y_vl1, y_bias);

        y_vl0 = _mm256_add_epi32(y_vl0, y_vl0_2);
        y_vl1 = _mm256_add_epi32(y_vl1, y_vl1_2);

        y_vl0 = _mm256_srai_epi32::<PRECISION>(y_vl0);
        y_vl1 = _mm256_srai_epi32::<PRECISION>(y_vl1);

        let mut y_vl = _mm256_packus_epi32(y_vl0, y_vl1);

        if bytes_position == YuvBytesPacking::MostSignificantBytes {
            y_vl = _mm256_to_msb_epi16::<BIT_DEPTH>(y_vl);
        }

        #[cfg(feature = "big_endian")]
        if _endianness == YuvEndianness::BigEndian {
            y_vl = _mm256_shuffle_epi8(y_vl, big_endian_shuffle_flag);
        }

        _mm256_storeu_si256(y_buffer.as_mut_ptr() as *mut __m256i, y_vl);

        let uv_bias = _mm256_set1_epi32(bias_uv);
        let v_cb_r = _mm256_set1_epi32(transform.cb_r);
        let v_cb_g = _mm256_set1_epi32(transform.cb_g);
        let v_cb_b = _mm256_set1_epi32(transform.cb_b);
        let v_cr_r = _mm256_set1_epi32(transform.cr_r);
        let v_cr_g = _mm256_set1_epi32(transform.cr_g);
        let v_cr_b = _mm256_set1_epi32(transform.cr_b);

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            let mut cb_vl0 = _mm256_mullo_epi32(r_lo, v_cb_r);
            let mut cb_vl1 = _mm256_mullo_epi32(r_hi, v_cb_r);
            let mut cr_vl0 = _mm256_mullo_epi32(r_lo, v_cr_r);
            let mut cr_vl1 = _mm256_mullo_epi32(r_hi, v_cr_r);

            let cb_vl0_g = _mm256_mullo_epi32(g_lo, v_cb_g);
            let cb_vl1_g = _mm256_mullo_epi32(g_hi, v_cb_g);

            let cr_vl0_g = _mm256_mullo_epi32(g_lo, v_cr_g);
            let cr_vl1_g = _mm256_mullo_epi32(g_hi, v_cr_g);

            cb_vl0 = _mm256_add_epi32(cb_vl0, cb_vl0_g);
            cb_vl1 = _mm256_add_epi32(cb_vl1, cb_vl1_g);
            cr_vl0 = _mm256_add_epi32(cr_vl0, cr_vl0_g);
            cr_vl1 = _mm256_add_epi32(cr_vl1, cr_vl1_g);

            let cb_vl0_b = _mm256_mullo_epi32(b_lo, v_cb_b);
            let cb_vl1_b = _mm256_mullo_epi32(b_hi, v_cb_b);

            let cr_vl0_b = _mm256_mullo_epi32(b_lo, v_cr_b);
            let cr_vl1_b = _mm256_mullo_epi32(b_hi, v_cr_b);

            cb_vl0 = _mm256_add_epi32(cb_vl0, uv_bias);
            cb_vl1 = _mm256_add_epi32(cb_vl1, uv_bias);
            cr_vl0 = _mm256_add_epi32(cr_vl0, uv_bias);
            cr_vl1 = _mm256_add_epi32(cr_vl1, uv_bias);

            cb_vl0 = _mm256_add_epi32(cb_vl0, cb_vl0_b);
            cb_vl1 = _mm256_add_epi32(cb_vl1, cb_vl1_b);
            cr_vl0 = _mm256_add_epi32(cr_vl0, cr_vl0_b);
            cr_vl1 = _mm256_add_epi32(cr_vl1, cr_vl1_b);

            cb_vl0 = _mm256_srai_epi32::<PRECISION>(cb_vl0);
            cb_vl1 = _mm256_srai_epi32::<PRECISION>(cb_vl1);
            cr_vl0 = _mm256_srai_epi32::<PRECISION>(cr_vl0);
            cr_vl1 = _mm256_srai_epi32::<PRECISION>(cr_vl1);

            let mut cb_vl = _mm256_packus_epi32(cb_vl0, cb_vl1);
            let mut cr_vl = _mm256_packus_epi32(cr_vl0, cr_vl1);

            if bytes_position == YuvBytesPacking::MostSignificantBytes {
                cb_vl = _mm256_to_msb_epi16::<BIT_DEPTH>(cb_vl);
                cr_vl = _mm256_to_msb_epi16::<BIT_DEPTH>(cr_vl);
            }
            #[cfg(feature = "big_endian")]
            if _endianness == YuvEndianness::BigEndian {
                cb_vl = _mm256_shuffle_epi8(cb_vl, big_endian_shuffle_flag);
                cr_vl = _mm256_shuffle_epi8(cr_vl, big_endian_shuffle_flag);
            }

            _mm256_storeu_si256(u_buffer.as_mut_ptr() as *mut __m256i, cb_vl);
            _mm256_storeu_si256(v_buffer.as_mut_ptr() as *mut __m256i, cr_vl);
        } else {
            let r_values = _mm256_rphadd_epi32_epi16(r_values);
            let g_values = _mm256_rphadd_epi32_epi16(g_values);
            let b_values = _mm256_rphadd_epi32_epi16(b_values);

            let mut cb_0 = _mm256_mullo_epi32(r_values, v_cb_r);
            let mut cr_0 = _mm256_mullo_epi32(r_values, v_cr_r);

            let cb_1 = _mm256_mullo_epi32(g_values, v_cb_g);
            let cr_1 = _mm256_mullo_epi32(g_values, v_cr_g);

            let cb_2 = _mm256_mullo_epi32(b_values, v_cb_b);
            let cr_2 = _mm256_mullo_epi32(b_values, v_cr_b);

            cb_0 = _mm256_add_epi32(cb_0, uv_bias);
            cr_0 = _mm256_add_epi32(cr_0, uv_bias);

            cb_0 = _mm256_add_epi32(cb_0, cb_1);
            cr_0 = _mm256_add_epi32(cr_0, cr_1);

            cb_0 = _mm256_add_epi32(cb_0, cb_2);
            cr_0 = _mm256_add_epi32(cr_0, cr_2);

            cb_0 = _mm256_srai_epi32::<PRECISION>(cb_0);
            cr_0 = _mm256_srai_epi32::<PRECISION>(cr_0);

            let mut cb_s = avx2_pack_u32(cb_0, cb_0);
            let mut cr_s = avx2_pack_u32(cr_0, cr_0);

            if bytes_position == YuvBytesPacking::MostSignificantBytes {
                cb_s = _mm256_to_msb_epi16::<BIT_DEPTH>(cb_s);
                cr_s = _mm256_to_msb_epi16::<BIT_DEPTH>(cr_s);
            }
            #[cfg(feature = "big_endian")]
            if _endianness == YuvEndianness::BigEndian {
                cb_s = _mm256_shuffle_epi8(cb_s, big_endian_shuffle_flag);
                cr_s = _mm256_shuffle_epi8(cr_s, big_endian_shuffle_flag);
            }

            _mm_storeu_si128(
                u_buffer.as_mut_ptr() as *mut __m128i,
                _mm256_castsi256_si128(cb_s),
            );
            _mm_storeu_si128(
                v_buffer.as_mut_ptr() as *mut __m128i,
                _mm256_castsi256_si128(cr_s),
            );
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
