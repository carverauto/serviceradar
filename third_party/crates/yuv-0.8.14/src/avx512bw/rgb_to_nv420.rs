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

use crate::avx512bw::avx512_utils::{
    avx512_load_rgb_u8, avx512_pack_u16, avx512_pairwise_avg_epi16_epi8, avx512_zip_epi8,
};
use crate::internals::ProcessedOffset;
use crate::yuv_support::{CbCrForwardTransform, YuvChromaRange, YuvNVOrder, YuvSourceChannels};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

/// This is special path for 2 rows of 4:2:0 to reuse variables instead of computing them
pub(crate) fn avx512_rgba_to_nv420<
    const ORIGIN_CHANNELS: u8,
    const UV_ORDER: u8,
    const PRECISION: i32,
    const HAS_VBMI: bool,
>(
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
        if HAS_VBMI {
            avx512_rgba_to_nv_vbmi_impl::<ORIGIN_CHANNELS, UV_ORDER, PRECISION>(
                y_plane0, y_plane1, uv_plane, rgba0, rgba1, width, range, transform, start_cx,
                start_ux,
            )
        } else {
            avx512_rgba_to_nv_def_impl::<ORIGIN_CHANNELS, UV_ORDER, PRECISION>(
                y_plane0, y_plane1, uv_plane, rgba0, rgba1, width, range, transform, start_cx,
                start_ux,
            )
        }
    }
}

#[target_feature(enable = "avx512f", enable = "avx512bw")]
unsafe fn avx512_rgba_to_nv_def_impl<
    const ORIGIN_CHANNELS: u8,
    const UV_ORDER: u8,
    const PRECISION: i32,
>(
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
    avx512_rgba_to_nv_impl::<ORIGIN_CHANNELS, UV_ORDER, PRECISION, false>(
        y_plane0, y_plane1, uv_plane, rgba0, rgba1, width, range, transform, start_cx, start_ux,
    )
}

#[target_feature(enable = "avx512f", enable = "avx512bw", enable = "avx512vbmi")]
unsafe fn avx512_rgba_to_nv_vbmi_impl<
    const ORIGIN_CHANNELS: u8,
    const UV_ORDER: u8,
    const PRECISION: i32,
>(
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
    avx512_rgba_to_nv_impl::<ORIGIN_CHANNELS, UV_ORDER, PRECISION, true>(
        y_plane0, y_plane1, uv_plane, rgba0, rgba1, width, range, transform, start_cx, start_ux,
    )
}

#[inline(always)]
unsafe fn encode_64_part<
    const ORIGIN_CHANNELS: u8,
    const UV_ORDER: u8,
    const PRECISION: i32,
    const HAS_VBMI: bool,
>(
    src0: &[u8],
    src1: &[u8],
    y_dst0: &mut [u8],
    y_dst1: &mut [u8],
    uv_dst: &mut [u8],
    range: &YuvChromaRange,
    transform: &CbCrForwardTransform<i32>,
) {
    let order: YuvNVOrder = UV_ORDER.into();

    const V_S: u32 = 4;
    const A_E: u32 = 2;
    let y_bias = _mm512_set1_epi16(range.bias_y as i16 * (1 << A_E));
    let uv_bias = _mm512_set1_epi16(range.bias_uv as i16 * (1 << A_E) + (1 << (A_E - 1)) - 1);
    let v_yr = _mm512_set1_epi16(transform.yr as i16);
    let v_yg = _mm512_set1_epi16(transform.yg as i16);
    let v_yb = _mm512_set1_epi16(transform.yb as i16);
    let v_cb_r = _mm512_set1_epi16(transform.cb_r as i16);
    let v_cb_g = _mm512_set1_epi16(transform.cb_g as i16);
    let v_cb_b = _mm512_set1_epi16(transform.cb_b as i16);
    let v_cr_r = _mm512_set1_epi16(transform.cr_r as i16);
    let v_cr_g = _mm512_set1_epi16(transform.cr_g as i16);
    let v_cr_b = _mm512_set1_epi16(transform.cr_b as i16);

    let (r_values0, g_values0, b_values0) =
        avx512_load_rgb_u8::<ORIGIN_CHANNELS, HAS_VBMI>(src0.as_ptr());
    let (r_values1, g_values1, b_values1) =
        avx512_load_rgb_u8::<ORIGIN_CHANNELS, HAS_VBMI>(src1.as_ptr());

    let r0_low = _mm512_srli_epi16::<V_S>(_mm512_unpacklo_epi8(r_values0, r_values0));
    let r0_high = _mm512_srli_epi16::<V_S>(_mm512_unpackhi_epi8(r_values0, r_values0));
    let g0_low = _mm512_srli_epi16::<V_S>(_mm512_unpacklo_epi8(g_values0, g_values0));
    let g0_high = _mm512_srli_epi16::<V_S>(_mm512_unpackhi_epi8(g_values0, g_values0));
    let b0_low = _mm512_srli_epi16::<V_S>(_mm512_unpacklo_epi8(b_values0, b_values0));
    let b0_high = _mm512_srli_epi16::<V_S>(_mm512_unpackhi_epi8(b_values0, b_values0));

    let y0_l = _mm512_srli_epi16::<A_E>(_mm512_add_epi16(
        y_bias,
        _mm512_add_epi16(
            _mm512_add_epi16(
                _mm512_mulhrs_epi16(r0_low, v_yr),
                _mm512_mulhrs_epi16(g0_low, v_yg),
            ),
            _mm512_mulhrs_epi16(b0_low, v_yb),
        ),
    ));

    let y0_h = _mm512_srli_epi16::<A_E>(_mm512_add_epi16(
        y_bias,
        _mm512_add_epi16(
            _mm512_add_epi16(
                _mm512_mulhrs_epi16(r0_high, v_yr),
                _mm512_mulhrs_epi16(g0_high, v_yg),
            ),
            _mm512_mulhrs_epi16(b0_high, v_yb),
        ),
    ));

    let r1_low = _mm512_srli_epi16::<V_S>(_mm512_unpacklo_epi8(r_values1, r_values1));
    let r1_high = _mm512_srli_epi16::<V_S>(_mm512_unpackhi_epi8(r_values1, r_values1));
    let g1_low = _mm512_srli_epi16::<V_S>(_mm512_unpacklo_epi8(g_values1, g_values1));
    let g1_high = _mm512_srli_epi16::<V_S>(_mm512_unpackhi_epi8(g_values1, g_values1));
    let b1_low = _mm512_srli_epi16::<V_S>(_mm512_unpacklo_epi8(b_values1, b_values1));
    let b1_high = _mm512_srli_epi16::<V_S>(_mm512_unpackhi_epi8(b_values1, b_values1));

    let y1_l = _mm512_srli_epi16::<A_E>(_mm512_add_epi16(
        y_bias,
        _mm512_add_epi16(
            _mm512_add_epi16(
                _mm512_mulhrs_epi16(r1_low, v_yr),
                _mm512_mulhrs_epi16(g1_low, v_yg),
            ),
            _mm512_mulhrs_epi16(b1_low, v_yb),
        ),
    ));

    let y1_h = _mm512_srli_epi16::<A_E>(_mm512_add_epi16(
        y_bias,
        _mm512_add_epi16(
            _mm512_add_epi16(
                _mm512_mulhrs_epi16(r1_high, v_yr),
                _mm512_mulhrs_epi16(g1_high, v_yg),
            ),
            _mm512_mulhrs_epi16(b1_high, v_yb),
        ),
    ));

    let y0_yuv = _mm512_packus_epi16(y0_l, y0_h);
    let y1_yuv = _mm512_packus_epi16(y1_l, y1_h);

    _mm512_storeu_si512(y_dst0.as_mut_ptr() as *mut _, y0_yuv);
    _mm512_storeu_si512(y_dst1.as_mut_ptr() as *mut _, y1_yuv);

    let r1 = avx512_pairwise_avg_epi16_epi8(r_values0, r_values1, 1 << (16 - V_S - 8 - 1));
    let g1 = avx512_pairwise_avg_epi16_epi8(g_values0, g_values1, 1 << (16 - V_S - 8 - 1));
    let b1 = avx512_pairwise_avg_epi16_epi8(b_values0, b_values1, 1 << (16 - V_S - 8 - 1));

    let cb = _mm512_srli_epi16::<A_E>(_mm512_add_epi16(
        uv_bias,
        _mm512_add_epi16(
            _mm512_add_epi16(
                _mm512_mulhrs_epi16(r1, v_cb_r),
                _mm512_mulhrs_epi16(g1, v_cb_g),
            ),
            _mm512_mulhrs_epi16(b1, v_cb_b),
        ),
    ));

    let cr = _mm512_srli_epi16::<A_E>(_mm512_add_epi16(
        uv_bias,
        _mm512_add_epi16(
            _mm512_add_epi16(
                _mm512_mulhrs_epi16(r1, v_cr_r),
                _mm512_mulhrs_epi16(g1, v_cr_g),
            ),
            _mm512_mulhrs_epi16(b1, v_cr_b),
        ),
    ));

    let cb = avx512_pack_u16(cb, cb);
    let cr = avx512_pack_u16(cr, cr);

    let (row0, _) = match order {
        YuvNVOrder::UV => avx512_zip_epi8::<HAS_VBMI>(cb, cr),
        YuvNVOrder::VU => avx512_zip_epi8::<HAS_VBMI>(cr, cb),
    };

    _mm512_storeu_si512(uv_dst.as_mut_ptr() as *mut _, row0);
}

#[inline(always)]
unsafe fn avx512_rgba_to_nv_impl<
    const ORIGIN_CHANNELS: u8,
    const UV_ORDER: u8,
    const PRECISION: i32,
    const HAS_VBMI: bool,
>(
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
    let channels = source_channels.get_channels_count();

    let mut cx = start_cx;
    let mut uv_x = start_ux;

    while cx + 64 < width as usize {
        let px = cx * channels;

        encode_64_part::<ORIGIN_CHANNELS, UV_ORDER, PRECISION, HAS_VBMI>(
            rgba0.get_unchecked(px..),
            rgba1.get_unchecked(px..),
            y_plane0.get_unchecked_mut(cx..),
            y_plane1.get_unchecked_mut(cx..),
            uv_plane.get_unchecked_mut(uv_x..),
            range,
            transform,
        );

        uv_x += 64;
        cx += 64;
    }

    if cx < width as usize {
        let diff = width as usize - cx;

        assert!(diff <= 64);

        let mut src_buffer0: [u8; 64 * 4] = [0; 64 * 4];
        let mut src_buffer1: [u8; 64 * 4] = [0; 64 * 4];
        let mut y_buffer0: [u8; 64] = [0; 64];
        let mut y_buffer1: [u8; 64] = [0; 64];
        let mut uv_buffer: [u8; 64 * 2] = [0; 64 * 2];

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

        encode_64_part::<ORIGIN_CHANNELS, UV_ORDER, PRECISION, HAS_VBMI>(
            src_buffer0.as_slice(),
            src_buffer1.as_slice(),
            y_buffer0.as_mut_slice(),
            y_buffer1.as_mut_slice(),
            uv_buffer.as_mut_slice(),
            range,
            transform,
        );

        std::ptr::copy_nonoverlapping(
            y_buffer0.as_mut_ptr(),
            y_plane0.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );

        std::ptr::copy_nonoverlapping(
            y_buffer1.as_mut_ptr(),
            y_plane1.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );

        let ux_size = diff.div_ceil(2) * 2;

        std::ptr::copy_nonoverlapping(
            uv_buffer.as_mut_ptr(),
            uv_plane.get_unchecked_mut(uv_x..).as_mut_ptr(),
            ux_size,
        );

        cx += diff;
        uv_x += ux_size;
    }

    ProcessedOffset { cx, ux: uv_x }
}
