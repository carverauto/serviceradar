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
use crate::sse::{_mm_set4r_epi, shuffle};
use crate::yuv_support::{
    CbCrForwardTransform, YuvChromaRange, YuvChromaSubsampling, YuvSourceChannels,
};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn sse_rgba_to_yuv_dot_rgba<const ORIGIN_CHANNELS: u8, const SAMPLING: u8>(
    transform: &CbCrForwardTransform<i32>,
    range: &YuvChromaRange,
    y_plane: &mut [u8],
    u_plane: &mut [u8],
    v_plane: &mut [u8],
    rgba: &[u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    unsafe {
        sse41_rgba_to_yuv_dot_rgba_impl_ubs::<ORIGIN_CHANNELS, SAMPLING>(
            transform, range, y_plane, u_plane, v_plane, rgba, start_cx, start_ux, width,
        )
    }
}

#[target_feature(enable = "sse4.1")]
unsafe fn sse41_rgba_to_yuv_dot_rgba_impl_ubs<const ORIGIN_CHANNELS: u8, const SAMPLING: u8>(
    transform: &CbCrForwardTransform<i32>,
    range: &YuvChromaRange,
    y_plane: &mut [u8],
    u_plane: &mut [u8],
    v_plane: &mut [u8],
    rgba: &[u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    let source_channels: YuvSourceChannels = ORIGIN_CHANNELS.into();
    let channels = source_channels.get_channels_count();

    let y_ptr = y_plane;
    let u_ptr = u_plane;
    let v_ptr = v_plane;

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

    let rgb_shuffle = _mm_setr_epi8(0, 1, 2, -1, 3, 4, 5, -1, 6, 7, 8, -1, 9, 10, 11, -1);

    let mut cx = start_cx;
    let mut ux = start_ux;

    while cx + 16 <= width {
        let src = rgba.get_unchecked(cx * channels..).as_ptr();

        let (v0, v1, v2, v3);

        if source_channels == YuvSourceChannels::Rgba || source_channels == YuvSourceChannels::Bgra
        {
            v0 = _mm_loadu_si128(src as *const _);
            v1 = _mm_loadu_si128(src.add(16) as *const _);
            v2 = _mm_loadu_si128(src.add(32) as *const _);
            v3 = _mm_loadu_si128(src.add(48) as *const _);
        } else if source_channels == YuvSourceChannels::Bgr
            || source_channels == YuvSourceChannels::Rgb
        {
            let j0 = _mm_loadu_si128(src as *const _);
            let j1 = _mm_loadu_si128(src.add(16) as *const _);
            let j2 = _mm_loadu_si128(src.add(32) as *const _);

            v0 = _mm_shuffle_epi8(j0, rgb_shuffle);
            let m0 = _mm_alignr_epi8::<12>(j1, j0);
            let m1 = _mm_alignr_epi8::<8>(j2, j1);
            let m2 = _mm_srli_si128::<4>(j2);
            v1 = _mm_shuffle_epi8(m0, rgb_shuffle);
            v2 = _mm_shuffle_epi8(m1, rgb_shuffle);
            v3 = _mm_shuffle_epi8(m2, rgb_shuffle);
        } else {
            unimplemented!()
        }

        let y0s = _mm_maddubs_epi16(v0, y_weights);
        let y1s = _mm_maddubs_epi16(v1, y_weights);
        let y2s = _mm_maddubs_epi16(v2, y_weights);
        let y3s = _mm_maddubs_epi16(v3, y_weights);

        const SHUF_FLAG: i32 = shuffle(3, 1, 2, 0);

        let v0_s = if chroma_subsampling != YuvChromaSubsampling::Yuv444 {
            _mm_shuffle_epi32::<SHUF_FLAG>(v0)
        } else {
            _mm_setzero_si128()
        };
        let v1_s = if chroma_subsampling != YuvChromaSubsampling::Yuv444 {
            _mm_shuffle_epi32::<SHUF_FLAG>(v1)
        } else {
            _mm_setzero_si128()
        };
        let v2_s = if chroma_subsampling != YuvChromaSubsampling::Yuv444 {
            _mm_shuffle_epi32::<SHUF_FLAG>(v2)
        } else {
            _mm_setzero_si128()
        };
        let v3_s = if chroma_subsampling != YuvChromaSubsampling::Yuv444 {
            _mm_shuffle_epi32::<SHUF_FLAG>(v3)
        } else {
            _mm_setzero_si128()
        };

        let mut y0m = _mm_hadd_epi16(y0s, y1s);
        let mut y1m = _mm_hadd_epi16(y2s, y3s);

        y0m = _mm_add_epi16(y0m, y_bias);
        y1m = _mm_add_epi16(y1m, y_bias);

        y0m = _mm_srai_epi16::<A_E>(y0m);
        y1m = _mm_srai_epi16::<A_E>(y1m);

        let y_vl = _mm_packus_epi16(y0m, y1m);

        _mm_storeu_si128(y_ptr.get_unchecked_mut(cx..).as_mut_ptr() as *mut _, y_vl);

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            let cb0 = _mm_maddubs_epi16(v0, cb_weights);
            let cb1 = _mm_maddubs_epi16(v1, cb_weights);
            let cb2 = _mm_maddubs_epi16(v2, cb_weights);
            let cb3 = _mm_maddubs_epi16(v3, cb_weights);

            let cr0 = _mm_maddubs_epi16(v0, cr_weights);
            let cr1 = _mm_maddubs_epi16(v1, cr_weights);
            let cr2 = _mm_maddubs_epi16(v2, cr_weights);
            let cr3 = _mm_maddubs_epi16(v3, cr_weights);

            let mut cb00 = _mm_hadd_epi16(cb0, cb1);
            let mut cb01 = _mm_hadd_epi16(cb2, cb3);

            let mut cr00 = _mm_hadd_epi16(cr0, cr1);
            let mut cr01 = _mm_hadd_epi16(cr2, cr3);

            cb00 = _mm_add_epi16(cb00, uv_bias);
            cb01 = _mm_add_epi16(cb01, uv_bias);
            cr00 = _mm_add_epi16(cr00, uv_bias);
            cr01 = _mm_add_epi16(cr01, uv_bias);

            cb00 = _mm_srai_epi16::<A_E>(cb00);
            cb01 = _mm_srai_epi16::<A_E>(cb01);
            cr00 = _mm_srai_epi16::<A_E>(cr00);
            cr01 = _mm_srai_epi16::<A_E>(cr01);

            let cb_vl = _mm_packus_epi16(cb00, cb01);
            let cr_vl = _mm_packus_epi16(cr00, cr01);

            _mm_storeu_si128(u_ptr.get_unchecked_mut(ux..).as_mut_ptr() as *mut _, cb_vl);
            _mm_storeu_si128(v_ptr.get_unchecked_mut(ux..).as_mut_ptr() as *mut _, cr_vl);

            ux += 16;
        } else if (chroma_subsampling == YuvChromaSubsampling::Yuv420)
            || (chroma_subsampling == YuvChromaSubsampling::Yuv422)
        {
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

            let cb_vl = _mm_packus_epi16(cb00, cb00);
            let cr_vl = _mm_packus_epi16(cr00, cr00);

            _mm_storeu_si64(u_ptr.get_unchecked_mut(ux..).as_mut_ptr() as *mut _, cb_vl);
            _mm_storeu_si64(v_ptr.get_unchecked_mut(ux..).as_mut_ptr() as *mut _, cr_vl);

            ux += 8;
        }

        cx += 16;
    }

    if cx < width {
        let diff = width - cx;
        assert!(diff <= 16);

        let mut src_buffer: [u8; 16 * 4] = [0; 16 * 4];
        let mut y_buffer: [u8; 16] = [0; 16];
        let mut u_buffer: [u8; 16] = [0; 16];
        let mut v_buffer: [u8; 16] = [0; 16];

        std::ptr::copy_nonoverlapping(
            rgba.get_unchecked(cx * channels..).as_ptr(),
            src_buffer.as_mut_ptr().cast(),
            diff * channels,
        );

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

        let (v0, v1, v2, v3);

        if source_channels == YuvSourceChannels::Rgba || source_channels == YuvSourceChannels::Bgra
        {
            v0 = _mm_loadu_si128(src_buffer.as_ptr() as *const _);
            v1 = _mm_loadu_si128(src_buffer.as_ptr().add(16) as *const _);
            v2 = _mm_loadu_si128(src_buffer.as_ptr().add(32) as *const _);
            v3 = _mm_loadu_si128(src_buffer.as_ptr().add(48) as *const _);
        } else if source_channels == YuvSourceChannels::Bgr
            || source_channels == YuvSourceChannels::Rgb
        {
            let j0 = _mm_loadu_si128(src_buffer.as_ptr() as *const _);
            let j1 = _mm_loadu_si128(src_buffer.as_ptr().add(16) as *const _);
            let j2 = _mm_loadu_si128(src_buffer.as_ptr().add(32) as *const _);

            v0 = _mm_shuffle_epi8(j0, rgb_shuffle);
            let m0 = _mm_alignr_epi8::<12>(j1, j0);
            let m1 = _mm_alignr_epi8::<8>(j2, j1);
            let m2 = _mm_srli_si128::<4>(j2);
            v1 = _mm_shuffle_epi8(m0, rgb_shuffle);
            v2 = _mm_shuffle_epi8(m1, rgb_shuffle);
            v3 = _mm_shuffle_epi8(m2, rgb_shuffle);
        } else {
            unimplemented!()
        }

        let y0s = _mm_maddubs_epi16(v0, y_weights);
        let y1s = _mm_maddubs_epi16(v1, y_weights);
        let y2s = _mm_maddubs_epi16(v2, y_weights);
        let y3s = _mm_maddubs_epi16(v3, y_weights);

        const SHUF_FLAG: i32 = shuffle(3, 1, 2, 0);

        let v0_s = if chroma_subsampling != YuvChromaSubsampling::Yuv444 {
            _mm_shuffle_epi32::<SHUF_FLAG>(v0)
        } else {
            _mm_setzero_si128()
        };
        let v1_s = if chroma_subsampling != YuvChromaSubsampling::Yuv444 {
            _mm_shuffle_epi32::<SHUF_FLAG>(v1)
        } else {
            _mm_setzero_si128()
        };
        let v2_s = if chroma_subsampling != YuvChromaSubsampling::Yuv444 {
            _mm_shuffle_epi32::<SHUF_FLAG>(v2)
        } else {
            _mm_setzero_si128()
        };
        let v3_s = if chroma_subsampling != YuvChromaSubsampling::Yuv444 {
            _mm_shuffle_epi32::<SHUF_FLAG>(v3)
        } else {
            _mm_setzero_si128()
        };

        let mut y0m = _mm_hadd_epi16(y0s, y1s);
        let mut y1m = _mm_hadd_epi16(y2s, y3s);

        y0m = _mm_add_epi16(y0m, y_bias);
        y1m = _mm_add_epi16(y1m, y_bias);

        y0m = _mm_srai_epi16::<A_E>(y0m);
        y1m = _mm_srai_epi16::<A_E>(y1m);

        let y_vl = _mm_packus_epi16(y0m, y1m);

        _mm_storeu_si128(y_buffer.as_mut_ptr() as *mut _, y_vl);

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            let cb0 = _mm_maddubs_epi16(v0, cb_weights);
            let cb1 = _mm_maddubs_epi16(v1, cb_weights);
            let cb2 = _mm_maddubs_epi16(v2, cb_weights);
            let cb3 = _mm_maddubs_epi16(v3, cb_weights);

            let cr0 = _mm_maddubs_epi16(v0, cr_weights);
            let cr1 = _mm_maddubs_epi16(v1, cr_weights);
            let cr2 = _mm_maddubs_epi16(v2, cr_weights);
            let cr3 = _mm_maddubs_epi16(v3, cr_weights);

            let mut cb00 = _mm_hadd_epi16(cb0, cb1);
            let mut cb01 = _mm_hadd_epi16(cb2, cb3);

            let mut cr00 = _mm_hadd_epi16(cr0, cr1);
            let mut cr01 = _mm_hadd_epi16(cr2, cr3);

            cb00 = _mm_add_epi16(cb00, uv_bias);
            cb01 = _mm_add_epi16(cb01, uv_bias);
            cr00 = _mm_add_epi16(cr00, uv_bias);
            cr01 = _mm_add_epi16(cr01, uv_bias);

            cb00 = _mm_srai_epi16::<A_E>(cb00);
            cb01 = _mm_srai_epi16::<A_E>(cb01);
            cr00 = _mm_srai_epi16::<A_E>(cr00);
            cr01 = _mm_srai_epi16::<A_E>(cr01);

            let cb_vl = _mm_packus_epi16(cb00, cb01);
            let cr_vl = _mm_packus_epi16(cr00, cr01);

            _mm_storeu_si128(u_buffer.as_mut_ptr() as *mut _, cb_vl);
            _mm_storeu_si128(v_buffer.as_mut_ptr() as *mut _, cr_vl);
        } else if (chroma_subsampling == YuvChromaSubsampling::Yuv420)
            || (chroma_subsampling == YuvChromaSubsampling::Yuv422)
        {
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

            let cb_vl = _mm_packus_epi16(cb00, cb00);
            let cr_vl = _mm_packus_epi16(cr00, cr00);

            _mm_storeu_si64(u_buffer.as_mut_ptr() as *mut _, cb_vl);
            _mm_storeu_si64(v_buffer.as_mut_ptr() as *mut _, cr_vl);
        }

        std::ptr::copy_nonoverlapping(
            y_buffer.as_ptr().cast(),
            y_ptr.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );

        cx += diff;

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            std::ptr::copy_nonoverlapping(
                u_buffer.as_ptr().cast(),
                u_ptr.get_unchecked_mut(ux..).as_mut_ptr(),
                diff,
            );
            std::ptr::copy_nonoverlapping(
                v_buffer.as_ptr().cast(),
                v_ptr.get_unchecked_mut(ux..).as_mut_ptr(),
                diff,
            );

            ux += diff;
        } else if (chroma_subsampling == YuvChromaSubsampling::Yuv420)
            || (chroma_subsampling == YuvChromaSubsampling::Yuv422)
        {
            let hv = diff.div_ceil(2);
            std::ptr::copy_nonoverlapping(
                u_buffer.as_ptr().cast(),
                u_ptr.get_unchecked_mut(ux..).as_mut_ptr(),
                hv,
            );
            std::ptr::copy_nonoverlapping(
                v_buffer.as_ptr().cast(),
                v_ptr.get_unchecked_mut(ux..).as_mut_ptr(),
                hv,
            );

            ux += hv;
        }
    }

    ProcessedOffset { cx, ux }
}
