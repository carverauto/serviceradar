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
use crate::sse::_mm_set4r_epi;
use crate::yuv_support::{CbCrForwardTransform, YuvChromaRange, YuvNVOrder, YuvSourceChannels};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn sse_rgba_to_nv_fast_rgba420<const ORIGIN_CHANNELS: u8, const UV_ORDER: u8>(
    y_plane0: &mut [u8],
    y_plane1: &mut [u8],
    uv_plane: &mut [u8],
    rgba0: &[u8],
    rgba1: &[u8],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrForwardTransform<i32>,
    start_cx: usize,
    start_ux: usize,
) -> ProcessedOffset {
    unsafe {
        sse41_rgba_to_nv_fast_rgba_impl_ubs420::<ORIGIN_CHANNELS, UV_ORDER>(
            y_plane0, y_plane1, uv_plane, rgba0, rgba1, width, range, transform, start_cx, start_ux,
        )
    }
}

#[target_feature(enable = "sse4.1")]
unsafe fn sse41_rgba_to_nv_fast_rgba_impl_ubs420<const ORIGIN_CHANNELS: u8, const UV_ORDER: u8>(
    y_plane0: &mut [u8],
    y_plane1: &mut [u8],
    uv_plane: &mut [u8],
    rgba0: &[u8],
    rgba1: &[u8],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrForwardTransform<i32>,
    start_cx: usize,
    start_ux: usize,
) -> ProcessedOffset {
    let source_channels: YuvSourceChannels = ORIGIN_CHANNELS.into();
    let uv_order: YuvNVOrder = UV_ORDER.into();
    let channels = source_channels.get_channels_count();

    const A_E: i32 = 7;
    let y_bias = _mm_set1_epi16(range.bias_y as i16 * (1 << A_E) + (1 << (A_E - 1)) - 1);
    let uv_bias = _mm_set1_epi16(range.bias_uv as i16 * (1 << A_E) + (1 << (A_E - 1)) - 1);

    let y_weights = if source_channels == YuvSourceChannels::Rgba
        || source_channels == YuvSourceChannels::Rgb
    {
        _mm_set4r_epi(
            transform.yr as i8,
            transform.yg as i8,
            transform.yb as i8,
            0,
        )
    } else {
        _mm_set4r_epi(
            transform.yb as i8,
            transform.yg as i8,
            transform.yr as i8,
            0,
        )
    };
    let cb_weights = if source_channels == YuvSourceChannels::Rgba
        || source_channels == YuvSourceChannels::Rgb
    {
        _mm_set4r_epi(
            transform.cb_r as i8,
            transform.cb_g as i8,
            transform.cb_b as i8,
            0,
        )
    } else {
        _mm_set4r_epi(
            transform.cb_b as i8,
            transform.cb_g as i8,
            transform.cb_r as i8,
            0,
        )
    };
    let cr_weights = if source_channels == YuvSourceChannels::Rgba
        || source_channels == YuvSourceChannels::Rgb
    {
        _mm_set4r_epi(
            transform.cr_r as i8,
            transform.cr_g as i8,
            transform.cr_b as i8,
            0,
        )
    } else {
        _mm_set4r_epi(
            transform.cr_b as i8,
            transform.cr_g as i8,
            transform.cr_r as i8,
            0,
        )
    };

    let mut cx = start_cx;
    let mut ux = start_ux;

    let rgb_shuffle = _mm_setr_epi8(0, 1, 2, -1, 3, 4, 5, -1, 6, 7, 8, -1, 9, 10, 11, -1);

    while cx + 16 < width as usize {
        let src0 = rgba0.get_unchecked(cx * channels..).as_ptr();
        let src1 = rgba1.get_unchecked(cx * channels..).as_ptr();

        let (v0, v1, v2, v3);
        let (v4, v5, v6, v7);

        if source_channels == YuvSourceChannels::Rgba || source_channels == YuvSourceChannels::Bgra
        {
            v0 = _mm_loadu_si128(src0 as *const _);
            v1 = _mm_loadu_si128(src0.add(16) as *const _);
            v2 = _mm_loadu_si128(src0.add(32) as *const _);
            v3 = _mm_loadu_si128(src0.add(48) as *const _);

            v4 = _mm_loadu_si128(src1 as *const _);
            v5 = _mm_loadu_si128(src1.add(16) as *const _);
            v6 = _mm_loadu_si128(src1.add(32) as *const _);
            v7 = _mm_loadu_si128(src1.add(48) as *const _);
        } else if source_channels == YuvSourceChannels::Bgr
            || source_channels == YuvSourceChannels::Rgb
        {
            let j0 = _mm_loadu_si128(src0 as *const _);
            let j1 = _mm_loadu_si128(src0.add(16) as *const _);
            let j2 = _mm_loadu_si128(src0.add(32) as *const _);

            let j3 = _mm_loadu_si128(src1 as *const _);
            let j4 = _mm_loadu_si128(src1.add(16) as *const _);
            let j5 = _mm_loadu_si128(src1.add(32) as *const _);

            v0 = _mm_shuffle_epi8(j0, rgb_shuffle);
            let m0 = _mm_alignr_epi8::<12>(j1, j0);
            let m1 = _mm_alignr_epi8::<8>(j2, j1);
            let m2 = _mm_srli_si128::<4>(j2);

            let m3 = _mm_alignr_epi8::<12>(j4, j3);
            let m4 = _mm_alignr_epi8::<8>(j5, j4);
            let m5 = _mm_srli_si128::<4>(j5);
            v1 = _mm_shuffle_epi8(m0, rgb_shuffle);
            v2 = _mm_shuffle_epi8(m1, rgb_shuffle);
            v3 = _mm_shuffle_epi8(m2, rgb_shuffle);
            v4 = _mm_shuffle_epi8(j3, rgb_shuffle);
            v5 = _mm_shuffle_epi8(m3, rgb_shuffle);
            v6 = _mm_shuffle_epi8(m4, rgb_shuffle);
            v7 = _mm_shuffle_epi8(m5, rgb_shuffle);
        } else {
            unimplemented!()
        }

        let y0s = _mm_maddubs_epi16(v0, y_weights);
        let y1s = _mm_maddubs_epi16(v1, y_weights);
        let y2s = _mm_maddubs_epi16(v2, y_weights);
        let y3s = _mm_maddubs_epi16(v3, y_weights);

        let uh0 = _mm_avg_epu8(v0, v4);
        let uh1 = _mm_avg_epu8(v1, v5);
        let uh2 = _mm_avg_epu8(v2, v6);
        let uh3 = _mm_avg_epu8(v3, v7);

        let y4s = _mm_maddubs_epi16(v4, y_weights);
        let y5s = _mm_maddubs_epi16(v5, y_weights);
        let y6s = _mm_maddubs_epi16(v6, y_weights);
        let y7s = _mm_maddubs_epi16(v7, y_weights);

        const SHUF_FLAG: i32 = crate::sse::shuffle(3, 1, 2, 0);

        let v0_s = _mm_shuffle_epi32::<SHUF_FLAG>(uh0);
        let v1_s = _mm_shuffle_epi32::<SHUF_FLAG>(uh1);
        let v2_s = _mm_shuffle_epi32::<SHUF_FLAG>(uh2);
        let v3_s = _mm_shuffle_epi32::<SHUF_FLAG>(uh3);

        let mut y0m = _mm_hadd_epi16(y0s, y1s);
        let mut y1m = _mm_hadd_epi16(y2s, y3s);
        let mut y2m = _mm_hadd_epi16(y4s, y5s);
        let mut y3m = _mm_hadd_epi16(y6s, y7s);

        y0m = _mm_add_epi16(y0m, y_bias);
        y1m = _mm_add_epi16(y1m, y_bias);
        y2m = _mm_add_epi16(y2m, y_bias);
        y3m = _mm_add_epi16(y3m, y_bias);

        y0m = _mm_srai_epi16::<A_E>(y0m);
        y1m = _mm_srai_epi16::<A_E>(y1m);
        y2m = _mm_srai_epi16::<A_E>(y2m);
        y3m = _mm_srai_epi16::<A_E>(y3m);

        let y_vl0 = _mm_packus_epi16(y0m, y1m);
        let y_vl1 = _mm_packus_epi16(y2m, y3m);

        _mm_storeu_si128(
            y_plane0.get_unchecked_mut(cx..).as_mut_ptr() as *mut _,
            y_vl0,
        );
        _mm_storeu_si128(
            y_plane1.get_unchecked_mut(cx..).as_mut_ptr() as *mut _,
            y_vl1,
        );

        let h0 = _mm_unpackhi_epi64(v0_s, v0_s);
        let h1 = _mm_unpackhi_epi64(v1_s, v1_s);
        let h2 = _mm_unpackhi_epi64(v2_s, v2_s);
        let h3 = _mm_unpackhi_epi64(v3_s, v3_s);

        let vh0 = _mm_avg_epu8(v0_s, h0);
        let vh1 = _mm_avg_epu8(v1_s, h1);
        let vh2 = _mm_avg_epu8(v2_s, h2);
        let vh3 = _mm_avg_epu8(v3_s, h3);

        let v0_f = _mm_unpacklo_epi64(vh0, vh1);
        let v1_f = _mm_unpacklo_epi64(vh2, vh3);

        let cb0 = _mm_maddubs_epi16(v0_f, cb_weights);
        let cb1 = _mm_maddubs_epi16(v1_f, cb_weights);

        let cr0 = _mm_maddubs_epi16(v0_f, cr_weights);
        let cr1 = _mm_maddubs_epi16(v1_f, cr_weights);

        let mut cb00 = _mm_hadd_epi16(cb0, cb1);
        let mut cr00 = _mm_hadd_epi16(cr0, cr1);

        cb00 = _mm_add_epi16(cb00, uv_bias);
        cr00 = _mm_add_epi16(cr00, uv_bias);

        cb00 = _mm_srai_epi16::<A_E>(cb00);
        cr00 = _mm_srai_epi16::<A_E>(cr00);

        let mut cb_vl = _mm_packus_epi16(cb00, cb00);
        let mut cr_vl = _mm_packus_epi16(cr00, cr00);

        if uv_order == YuvNVOrder::VU {
            std::mem::swap(&mut cb_vl, &mut cr_vl);
        }
        let packed = _mm_unpacklo_epi8(cb_vl, cr_vl);

        _mm_storeu_si128(
            uv_plane.get_unchecked_mut(ux..).as_mut_ptr() as *mut _,
            packed,
        );

        ux += 16;
        cx += 16;
    }

    if cx < width as usize {
        let diff = width as usize - cx;
        assert!(diff <= 16);

        let mut src_buffer0: [u8; 16 * 4] = [0; 16 * 4];
        let mut src_buffer1: [u8; 16 * 4] = [0; 16 * 4];
        let mut y_buffer0: [u8; 16] = [0; 16];
        let mut y_buffer1: [u8; 16] = [0; 16];
        let mut uv_buffer: [u8; 16] = [0; 16];

        std::ptr::copy_nonoverlapping(
            rgba0.get_unchecked(cx * channels..).as_ptr(),
            src_buffer0.as_mut_ptr().cast(),
            diff * channels,
        );
        std::ptr::copy_nonoverlapping(
            rgba1.get_unchecked(cx * channels..).as_ptr(),
            src_buffer1.as_mut_ptr().cast(),
            diff * channels,
        );

        // Replicate last item to one more position for subsampling
        if diff % 2 != 0 {
            let lst = (width as usize - 1) * channels;
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

        let (v0, v1, v2, v3);
        let (v4, v5, v6, v7);

        if source_channels == YuvSourceChannels::Rgba || source_channels == YuvSourceChannels::Bgra
        {
            v0 = _mm_loadu_si128(src_buffer0.as_ptr() as *const _);
            v1 = _mm_loadu_si128(src_buffer0.as_ptr().add(16) as *const _);
            v2 = _mm_loadu_si128(src_buffer0.as_ptr().add(32) as *const _);
            v3 = _mm_loadu_si128(src_buffer0.as_ptr().add(48) as *const _);

            v4 = _mm_loadu_si128(src_buffer1.as_ptr() as *const _);
            v5 = _mm_loadu_si128(src_buffer1.as_ptr().add(16) as *const _);
            v6 = _mm_loadu_si128(src_buffer1.as_ptr().add(32) as *const _);
            v7 = _mm_loadu_si128(src_buffer1.as_ptr().add(48) as *const _);
        } else if source_channels == YuvSourceChannels::Bgr
            || source_channels == YuvSourceChannels::Rgb
        {
            let j0 = _mm_loadu_si128(src_buffer0.as_ptr() as *const _);
            let j1 = _mm_loadu_si128(src_buffer0.as_ptr().add(16) as *const _);
            let j2 = _mm_loadu_si128(src_buffer0.as_ptr().add(32) as *const _);

            let j3 = _mm_loadu_si128(src_buffer1.as_ptr() as *const _);
            let j4 = _mm_loadu_si128(src_buffer1.as_ptr().add(16) as *const _);
            let j5 = _mm_loadu_si128(src_buffer1.as_ptr().add(32) as *const _);

            v0 = _mm_shuffle_epi8(j0, rgb_shuffle);
            let m0 = _mm_alignr_epi8::<12>(j1, j0);
            let m1 = _mm_alignr_epi8::<8>(j2, j1);
            let m2 = _mm_srli_si128::<4>(j2);

            let m3 = _mm_alignr_epi8::<12>(j4, j3);
            let m4 = _mm_alignr_epi8::<8>(j5, j4);
            let m5 = _mm_srli_si128::<4>(j5);
            v1 = _mm_shuffle_epi8(m0, rgb_shuffle);
            v2 = _mm_shuffle_epi8(m1, rgb_shuffle);
            v3 = _mm_shuffle_epi8(m2, rgb_shuffle);
            v4 = _mm_shuffle_epi8(j3, rgb_shuffle);
            v5 = _mm_shuffle_epi8(m3, rgb_shuffle);
            v6 = _mm_shuffle_epi8(m4, rgb_shuffle);
            v7 = _mm_shuffle_epi8(m5, rgb_shuffle);
        } else {
            unimplemented!()
        }

        let y0s = _mm_maddubs_epi16(v0, y_weights);
        let y1s = _mm_maddubs_epi16(v1, y_weights);
        let y2s = _mm_maddubs_epi16(v2, y_weights);
        let y3s = _mm_maddubs_epi16(v3, y_weights);

        let uh0 = _mm_avg_epu8(v0, v4);
        let uh1 = _mm_avg_epu8(v1, v5);
        let uh2 = _mm_avg_epu8(v2, v6);
        let uh3 = _mm_avg_epu8(v3, v7);

        let y4s = _mm_maddubs_epi16(v4, y_weights);
        let y5s = _mm_maddubs_epi16(v5, y_weights);
        let y6s = _mm_maddubs_epi16(v6, y_weights);
        let y7s = _mm_maddubs_epi16(v7, y_weights);

        const SHUF_FLAG: i32 = crate::sse::shuffle(3, 1, 2, 0);

        let v0_s = _mm_shuffle_epi32::<SHUF_FLAG>(uh0);
        let v1_s = _mm_shuffle_epi32::<SHUF_FLAG>(uh1);
        let v2_s = _mm_shuffle_epi32::<SHUF_FLAG>(uh2);
        let v3_s = _mm_shuffle_epi32::<SHUF_FLAG>(uh3);

        let mut y0m = _mm_hadd_epi16(y0s, y1s);
        let mut y1m = _mm_hadd_epi16(y2s, y3s);
        let mut y2m = _mm_hadd_epi16(y4s, y5s);
        let mut y3m = _mm_hadd_epi16(y6s, y7s);

        y0m = _mm_add_epi16(y0m, y_bias);
        y1m = _mm_add_epi16(y1m, y_bias);
        y2m = _mm_add_epi16(y2m, y_bias);
        y3m = _mm_add_epi16(y3m, y_bias);

        y0m = _mm_srai_epi16::<A_E>(y0m);
        y1m = _mm_srai_epi16::<A_E>(y1m);
        y2m = _mm_srai_epi16::<A_E>(y2m);
        y3m = _mm_srai_epi16::<A_E>(y3m);

        let y_vl0 = _mm_packus_epi16(y0m, y1m);
        let y_vl1 = _mm_packus_epi16(y2m, y3m);

        _mm_storeu_si128(y_buffer0.as_mut_ptr() as *mut _, y_vl0);
        _mm_storeu_si128(y_buffer1.as_mut_ptr() as *mut _, y_vl1);

        let h0 = _mm_unpackhi_epi64(v0_s, v0_s);
        let h1 = _mm_unpackhi_epi64(v1_s, v1_s);
        let h2 = _mm_unpackhi_epi64(v2_s, v2_s);
        let h3 = _mm_unpackhi_epi64(v3_s, v3_s);

        let vh0 = _mm_avg_epu8(v0_s, h0);
        let vh1 = _mm_avg_epu8(v1_s, h1);
        let vh2 = _mm_avg_epu8(v2_s, h2);
        let vh3 = _mm_avg_epu8(v3_s, h3);

        let v0_f = _mm_unpacklo_epi64(vh0, vh1);
        let v1_f = _mm_unpacklo_epi64(vh2, vh3);

        let cb0 = _mm_maddubs_epi16(v0_f, cb_weights);
        let cb1 = _mm_maddubs_epi16(v1_f, cb_weights);

        let cr0 = _mm_maddubs_epi16(v0_f, cr_weights);
        let cr1 = _mm_maddubs_epi16(v1_f, cr_weights);

        let mut cb00 = _mm_hadd_epi16(cb0, cb1);
        let mut cr00 = _mm_hadd_epi16(cr0, cr1);

        cb00 = _mm_add_epi16(cb00, uv_bias);
        cr00 = _mm_add_epi16(cr00, uv_bias);

        cb00 = _mm_srai_epi16::<A_E>(cb00);
        cr00 = _mm_srai_epi16::<A_E>(cr00);

        let mut cb_vl = _mm_packus_epi16(cb00, cb00);
        let mut cr_vl = _mm_packus_epi16(cr00, cr00);

        if uv_order == YuvNVOrder::VU {
            std::mem::swap(&mut cb_vl, &mut cr_vl);
        }
        let packed = _mm_unpacklo_epi8(cb_vl, cr_vl);

        _mm_storeu_si128(uv_buffer.as_mut_ptr() as *mut _, packed);

        std::ptr::copy_nonoverlapping(
            y_buffer0.as_ptr().cast(),
            y_plane0.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );
        std::ptr::copy_nonoverlapping(
            y_buffer1.as_ptr().cast(),
            y_plane1.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );

        cx += diff;

        let hv = diff.div_ceil(2) * 2;
        std::ptr::copy_nonoverlapping(
            uv_buffer.as_ptr().cast(),
            uv_plane.get_unchecked_mut(ux..).as_mut_ptr(),
            hv,
        );

        ux += hv;
    }

    ProcessedOffset { cx, ux }
}
