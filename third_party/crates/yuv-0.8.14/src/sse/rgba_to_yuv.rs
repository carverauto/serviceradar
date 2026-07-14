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
    _mm_load_deinterleave_half_rgb_for_yuv, _mm_load_deinterleave_rgb_for_yuv,
    sse_pairwise_avg_epi8_j,
};
use crate::yuv_support::{
    CbCrForwardTransform, YuvChromaRange, YuvChromaSubsampling, YuvSourceChannels,
};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn sse_rgba_to_yuv_row<
    const ORIGIN_CHANNELS: u8,
    const SAMPLING: u8,
    const PRECISION: i32,
>(
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
        sse_rgba_to_yuv_row_impl::<ORIGIN_CHANNELS, SAMPLING, PRECISION>(
            transform, range, y_plane, u_plane, v_plane, rgba, start_cx, start_ux, width,
        )
    }
}

#[inline(always)]
unsafe fn encode_8_part<const ORIGIN_CHANNELS: u8, const SAMPLING: u8, const PRECISION: i32>(
    src: &[u8],
    y_dst: &mut [u8],
    u_dst: &mut [u8],
    v_dst: &mut [u8],
    transform: &CbCrForwardTransform<i32>,
    range: &YuvChromaRange,
) {
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    const V_S: i32 = 4;
    const A_E: i32 = 2;

    let (r_values, g_values, b_values) =
        _mm_load_deinterleave_half_rgb_for_yuv::<ORIGIN_CHANNELS>(src.as_ptr());

    let rl = _mm_unpacklo_epi8(r_values, r_values);
    let gl = _mm_unpacklo_epi8(g_values, g_values);
    let bl = _mm_unpacklo_epi8(b_values, b_values);

    let r_low = _mm_srli_epi16::<V_S>(rl);
    let g_low = _mm_srli_epi16::<V_S>(gl);
    let b_low = _mm_srli_epi16::<V_S>(bl);

    let y_bias = _mm_set1_epi16(range.bias_y as i16 * (1 << A_E));
    let v_yr = _mm_set1_epi16(transform.yr as i16);
    let v_yg = _mm_set1_epi16(transform.yg as i16);
    let v_yb = _mm_set1_epi16(transform.yb as i16);

    let y_l = _mm_srli_epi16::<A_E>(_mm_add_epi16(
        y_bias,
        _mm_add_epi16(
            _mm_add_epi16(_mm_mulhrs_epi16(r_low, v_yr), _mm_mulhrs_epi16(g_low, v_yg)),
            _mm_mulhrs_epi16(b_low, v_yb),
        ),
    ));

    let y_yuv = _mm_packus_epi16(y_l, _mm_setzero_si128());
    _mm_storeu_si64(y_dst.as_mut_ptr(), y_yuv);

    let uv_bias = _mm_set1_epi16(range.bias_uv as i16 * (1 << A_E) + (1 << (A_E - 1)) - 1);
    let v_cb_r = _mm_set1_epi16(transform.cb_r as i16);
    let v_cb_g = _mm_set1_epi16(transform.cb_g as i16);
    let v_cb_b = _mm_set1_epi16(transform.cb_b as i16);
    let v_cr_r = _mm_set1_epi16(transform.cr_r as i16);
    let v_cr_g = _mm_set1_epi16(transform.cr_g as i16);
    let v_cr_b = _mm_set1_epi16(transform.cr_b as i16);

    if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
        let cb_l = _mm_srli_epi16::<A_E>(_mm_add_epi16(
            uv_bias,
            _mm_add_epi16(
                _mm_add_epi16(
                    _mm_mulhrs_epi16(r_low, v_cb_r),
                    _mm_mulhrs_epi16(g_low, v_cb_g),
                ),
                _mm_mulhrs_epi16(b_low, v_cb_b),
            ),
        ));
        let cr_l = _mm_srli_epi16::<A_E>(_mm_add_epi16(
            uv_bias,
            _mm_add_epi16(
                _mm_add_epi16(
                    _mm_mulhrs_epi16(r_low, v_cr_r),
                    _mm_mulhrs_epi16(g_low, v_cr_g),
                ),
                _mm_mulhrs_epi16(b_low, v_cr_b),
            ),
        ));

        let cb = _mm_packus_epi16(cb_l, _mm_setzero_si128());
        let cr = _mm_packus_epi16(cr_l, _mm_setzero_si128());

        _mm_storeu_si64(u_dst.as_mut_ptr(), cb);
        _mm_storeu_si64(v_dst.as_mut_ptr(), cr);
    } else if chroma_subsampling == YuvChromaSubsampling::Yuv422
        || (chroma_subsampling == YuvChromaSubsampling::Yuv420)
    {
        let r1 = sse_pairwise_avg_epi8_j(r_values, 1 << (16 - V_S - 8 - 1));
        let g1 = sse_pairwise_avg_epi8_j(g_values, 1 << (16 - V_S - 8 - 1));
        let b1 = sse_pairwise_avg_epi8_j(b_values, 1 << (16 - V_S - 8 - 1));

        let cbk = _mm_srli_epi16::<A_E>(_mm_add_epi16(
            uv_bias,
            _mm_add_epi16(
                _mm_add_epi16(_mm_mulhrs_epi16(r1, v_cb_r), _mm_mulhrs_epi16(g1, v_cb_g)),
                _mm_mulhrs_epi16(b1, v_cb_b),
            ),
        ));

        let crk = _mm_srli_epi16::<A_E>(_mm_add_epi16(
            uv_bias,
            _mm_add_epi16(
                _mm_add_epi16(_mm_mulhrs_epi16(r1, v_cr_r), _mm_mulhrs_epi16(g1, v_cr_g)),
                _mm_mulhrs_epi16(b1, v_cr_b),
            ),
        ));

        let cb = _mm_packus_epi16(cbk, cbk);
        let cr = _mm_packus_epi16(crk, crk);

        _mm_storeu_si32(u_dst.as_mut_ptr(), cb);
        _mm_storeu_si32(v_dst.as_mut_ptr(), cr);
    }
}

#[target_feature(enable = "sse4.1")]
unsafe fn sse_rgba_to_yuv_row_impl<
    const ORIGIN_CHANNELS: u8,
    const SAMPLING: u8,
    const PRECISION: i32,
>(
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

    let y_ptr = y_plane.as_mut_ptr();
    let u_ptr = u_plane.as_mut_ptr();
    let v_ptr = v_plane.as_mut_ptr();
    let rgba_ptr = rgba.as_ptr();

    let mut cx = start_cx;
    let mut uv_x = start_ux;

    const V_S: i32 = 4;
    const A_E: i32 = 2;
    let y_bias = _mm_set1_epi16(range.bias_y as i16 * (1 << A_E));
    let uv_bias = _mm_set1_epi16(range.bias_uv as i16 * (1 << A_E) + (1 << (A_E - 1)) - 1);
    let v_yr = _mm_set1_epi16(transform.yr as i16);
    let v_yg = _mm_set1_epi16(transform.yg as i16);
    let v_yb = _mm_set1_epi16(transform.yb as i16);
    let v_cb_r = _mm_set1_epi16(transform.cb_r as i16);
    let v_cb_g = _mm_set1_epi16(transform.cb_g as i16);
    let v_cb_b = _mm_set1_epi16(transform.cb_b as i16);
    let v_cr_r = _mm_set1_epi16(transform.cr_r as i16);
    let v_cr_g = _mm_set1_epi16(transform.cr_g as i16);
    let v_cr_b = _mm_set1_epi16(transform.cr_b as i16);

    while cx + 16 < width {
        let px = cx * channels;

        let (r_values, g_values, b_values) =
            _mm_load_deinterleave_rgb_for_yuv::<ORIGIN_CHANNELS>(rgba_ptr.add(px));

        let rl = _mm_unpacklo_epi8(r_values, r_values);
        let rh = _mm_unpackhi_epi8(r_values, r_values);
        let gl = _mm_unpacklo_epi8(g_values, g_values);
        let gh = _mm_unpackhi_epi8(g_values, g_values);
        let bl = _mm_unpacklo_epi8(b_values, b_values);
        let bh = _mm_unpackhi_epi8(b_values, b_values);

        let r_low = _mm_srli_epi16::<V_S>(rl);
        let r_high = _mm_srli_epi16::<V_S>(rh);
        let g_low = _mm_srli_epi16::<V_S>(gl);
        let g_high = _mm_srli_epi16::<V_S>(gh);
        let b_low = _mm_srli_epi16::<V_S>(bl);
        let b_high = _mm_srli_epi16::<V_S>(bh);

        let rlc = _mm_mulhrs_epi16(r_low, v_yr);
        let glc = _mm_mulhrs_epi16(g_low, v_yg);
        let blc = _mm_mulhrs_epi16(b_low, v_yb);
        let rhc = _mm_mulhrs_epi16(r_high, v_yr);
        let ghc = _mm_mulhrs_epi16(g_high, v_yg);
        let bhc = _mm_mulhrs_epi16(b_high, v_yb);

        let ylc = _mm_add_epi16(rlc, glc);
        let yhc = _mm_add_epi16(rhc, ghc);
        let ylw = _mm_add_epi16(ylc, blc);
        let yhw = _mm_add_epi16(yhc, bhc);

        let ylw0 = _mm_add_epi16(y_bias, ylw);
        let yhw0 = _mm_add_epi16(y_bias, yhw);

        let y_l = _mm_srli_epi16::<A_E>(ylw0);
        let y_h = _mm_srli_epi16::<A_E>(yhw0);

        let y_yuv = _mm_packus_epi16(y_l, y_h);
        _mm_storeu_si128(y_ptr.add(cx) as *mut __m128i, y_yuv);

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            let cblc = _mm_mulhrs_epi16(r_low, v_cb_r);
            let cbgc = _mm_mulhrs_epi16(g_low, v_cb_g);
            let crlc = _mm_mulhrs_epi16(r_low, v_cr_r);
            let crgc = _mm_mulhrs_epi16(g_low, v_cr_g);
            let cbbc = _mm_mulhrs_epi16(b_low, v_cb_b);
            let crbc = _mm_mulhrs_epi16(b_low, v_cr_b);

            let cbbl = _mm_add_epi16(cblc, cbgc);
            let crrl = _mm_add_epi16(crlc, crgc);

            let cbbw = _mm_add_epi16(cbbl, cbbc);
            let crrw = _mm_add_epi16(crrl, crbc);

            let cb_l = _mm_srli_epi16::<A_E>(_mm_add_epi16(uv_bias, cbbw));
            let cr_l = _mm_srli_epi16::<A_E>(_mm_add_epi16(uv_bias, crrw));

            let cb_h = _mm_srli_epi16::<A_E>(_mm_add_epi16(
                uv_bias,
                _mm_add_epi16(
                    _mm_add_epi16(
                        _mm_mulhrs_epi16(r_high, v_cb_r),
                        _mm_mulhrs_epi16(g_high, v_cb_g),
                    ),
                    _mm_mulhrs_epi16(b_high, v_cb_b),
                ),
            ));
            let cr_h = _mm_srli_epi16::<A_E>(_mm_add_epi16(
                uv_bias,
                _mm_add_epi16(
                    _mm_add_epi16(
                        _mm_mulhrs_epi16(r_high, v_cr_r),
                        _mm_mulhrs_epi16(g_high, v_cr_g),
                    ),
                    _mm_mulhrs_epi16(b_high, v_cr_b),
                ),
            ));

            let cb = _mm_packus_epi16(cb_l, cb_h);
            let cr = _mm_packus_epi16(cr_l, cr_h);

            _mm_storeu_si128(u_ptr.add(uv_x) as *mut __m128i, cb);
            _mm_storeu_si128(v_ptr.add(uv_x) as *mut __m128i, cr);
            uv_x += 16;
        } else if chroma_subsampling == YuvChromaSubsampling::Yuv422
            || (chroma_subsampling == YuvChromaSubsampling::Yuv420)
        {
            let r1 = sse_pairwise_avg_epi8_j(r_values, 1 << (16 - V_S - 8 - 1));
            let g1 = sse_pairwise_avg_epi8_j(g_values, 1 << (16 - V_S - 8 - 1));
            let b1 = sse_pairwise_avg_epi8_j(b_values, 1 << (16 - V_S - 8 - 1));

            let cbrc = _mm_mulhrs_epi16(r1, v_cb_r);
            let crrc = _mm_mulhrs_epi16(r1, v_cr_r);
            let cbgc = _mm_mulhrs_epi16(g1, v_cb_g);
            let crgc = _mm_mulhrs_epi16(g1, v_cr_g);
            let cbbc = _mm_mulhrs_epi16(b1, v_cb_b);
            let crbc = _mm_mulhrs_epi16(b1, v_cr_b);

            let cbo = _mm_add_epi16(cbrc, cbgc);
            let cro = _mm_add_epi16(crrc, crgc);

            let cbl = _mm_add_epi16(cbo, cbbc);
            let crl = _mm_add_epi16(cro, crbc);

            let cbk = _mm_srli_epi16::<A_E>(_mm_add_epi16(uv_bias, cbl));
            let crk = _mm_srli_epi16::<A_E>(_mm_add_epi16(uv_bias, crl));

            let cb = _mm_packus_epi16(cbk, cbk);
            let cr = _mm_packus_epi16(crk, crk);

            _mm_storeu_si64(u_ptr.add(uv_x), cb);
            _mm_storeu_si64(v_ptr.add(uv_x), cr);
            uv_x += 8;
        }

        cx += 16;
    }

    while cx + 8 < width {
        let px = cx * channels;

        encode_8_part::<ORIGIN_CHANNELS, SAMPLING, PRECISION>(
            rgba.get_unchecked(px..),
            y_plane.get_unchecked_mut(cx..),
            u_plane.get_unchecked_mut(uv_x..),
            v_plane.get_unchecked_mut(uv_x..),
            transform,
            range,
        );

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            uv_x += 8;
        } else if chroma_subsampling == YuvChromaSubsampling::Yuv422
            || (chroma_subsampling == YuvChromaSubsampling::Yuv420)
        {
            uv_x += 4;
        }

        cx += 8;
    }

    if cx < width {
        let diff = width - cx;
        assert!(diff <= 8);

        let mut src_buffer: [u8; 8 * 4] = [0; 8 * 4];
        let mut y_buffer: [u8; 8] = [0; 8];
        let mut u_buffer: [u8; 8] = [0; 8];
        let mut v_buffer: [u8; 8] = [0; 8];

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

        encode_8_part::<ORIGIN_CHANNELS, SAMPLING, PRECISION>(
            src_buffer.as_slice(),
            y_buffer.as_mut_slice(),
            u_buffer.as_mut_slice(),
            v_buffer.as_mut_slice(),
            transform,
            range,
        );

        std::ptr::copy_nonoverlapping(
            y_buffer.as_ptr().cast(),
            y_plane.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );

        cx += diff;
        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            std::ptr::copy_nonoverlapping(
                u_buffer.as_ptr().cast(),
                u_plane.get_unchecked_mut(uv_x..).as_mut_ptr(),
                diff,
            );
            std::ptr::copy_nonoverlapping(
                v_buffer.as_ptr().cast(),
                v_plane.get_unchecked_mut(uv_x..).as_mut_ptr(),
                diff,
            );

            uv_x += diff;
        } else if (chroma_subsampling == YuvChromaSubsampling::Yuv420)
            || (chroma_subsampling == YuvChromaSubsampling::Yuv422)
        {
            let hv = diff.div_ceil(2);
            std::ptr::copy_nonoverlapping(
                u_buffer.as_ptr().cast(),
                u_plane.get_unchecked_mut(uv_x..).as_mut_ptr(),
                hv,
            );
            std::ptr::copy_nonoverlapping(
                v_buffer.as_ptr().cast(),
                v_plane.get_unchecked_mut(uv_x..).as_mut_ptr(),
                hv,
            );

            uv_x += hv;
        }
    }

    ProcessedOffset { cx, ux: uv_x }
}
