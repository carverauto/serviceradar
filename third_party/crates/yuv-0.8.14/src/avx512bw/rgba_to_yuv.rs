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
    avx512_load_half_rgb_u8, avx512_load_rgb_u8, avx512_pack_u16, avx512_pairwise_avg_epi8,
};
use crate::internals::ProcessedOffset;
use crate::yuv_support::{
    CbCrForwardTransform, YuvChromaRange, YuvChromaSubsampling, YuvSourceChannels,
};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn avx512_rgba_to_yuv<
    const ORIGIN_CHANNELS: u8,
    const SAMPLING: u8,
    const HAS_VBMI: bool,
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
        if HAS_VBMI {
            avx512_rgba_to_yuv_bmi_impl::<ORIGIN_CHANNELS, SAMPLING>(
                transform, range, y_plane, u_plane, v_plane, rgba, start_cx, start_ux, width,
            )
        } else {
            avx512_rgba_to_yuv_def_impl::<ORIGIN_CHANNELS, SAMPLING>(
                transform, range, y_plane, u_plane, v_plane, rgba, start_cx, start_ux, width,
            )
        }
    }
}

#[target_feature(enable = "avx512bw", enable = "avx512f", enable = "avx512vbmi")]
unsafe fn avx512_rgba_to_yuv_bmi_impl<const ORIGIN_CHANNELS: u8, const SAMPLING: u8>(
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
    avx512_rgba_to_yuv_impl::<ORIGIN_CHANNELS, SAMPLING, true>(
        transform, range, y_plane, u_plane, v_plane, rgba, start_cx, start_ux, width,
    )
}

#[target_feature(enable = "avx512bw", enable = "avx512f")]
unsafe fn avx512_rgba_to_yuv_def_impl<const ORIGIN_CHANNELS: u8, const SAMPLING: u8>(
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
    avx512_rgba_to_yuv_impl::<ORIGIN_CHANNELS, SAMPLING, false>(
        transform, range, y_plane, u_plane, v_plane, rgba, start_cx, start_ux, width,
    )
}

#[inline(always)]
unsafe fn encode_32_part<const ORIGIN_CHANNELS: u8, const SAMPLING: u8, const HAS_VBMI: bool>(
    src: &[u8],
    y_dst: &mut [u8],
    u_dst: &mut [u8],
    v_dst: &mut [u8],
    transform: &CbCrForwardTransform<i32>,
    range: &YuvChromaRange,
) {
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
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

    let (r_values, g_values, b_values) =
        avx512_load_half_rgb_u8::<ORIGIN_CHANNELS, HAS_VBMI>(src.as_ptr());

    let mask = _mm512_setr_epi64(0, 0, 1, 0, 2, 0, 3, 0);

    let r_o = _mm512_permutexvar_epi64(mask, r_values);
    let g_o = _mm512_permutexvar_epi64(mask, g_values);
    let b_o = _mm512_permutexvar_epi64(mask, b_values);

    let r_low = _mm512_srli_epi16::<V_S>(_mm512_unpacklo_epi8(r_o, r_o));
    let g_low = _mm512_srli_epi16::<V_S>(_mm512_unpacklo_epi8(g_o, g_o));
    let b_low = _mm512_srli_epi16::<V_S>(_mm512_unpacklo_epi8(b_o, b_o));

    let y_l = _mm512_srli_epi16::<A_E>(_mm512_add_epi16(
        y_bias,
        _mm512_add_epi16(
            _mm512_add_epi16(
                _mm512_mulhrs_epi16(r_low, v_yr),
                _mm512_mulhrs_epi16(g_low, v_yg),
            ),
            _mm512_mulhrs_epi16(b_low, v_yb),
        ),
    ));

    let y_yuv = avx512_pack_u16(y_l, _mm512_setzero_si512());
    _mm256_storeu_si256(
        y_dst.as_mut_ptr() as *mut __m256i,
        _mm512_castsi512_si256(y_yuv),
    );

    if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
        let cb_l = _mm512_srli_epi16::<A_E>(_mm512_add_epi16(
            uv_bias,
            _mm512_add_epi16(
                _mm512_add_epi16(
                    _mm512_mulhrs_epi16(r_low, v_cb_r),
                    _mm512_mulhrs_epi16(g_low, v_cb_g),
                ),
                _mm512_mulhrs_epi16(b_low, v_cb_b),
            ),
        ));
        let cr_l = _mm512_srli_epi16::<A_E>(_mm512_add_epi16(
            uv_bias,
            _mm512_add_epi16(
                _mm512_add_epi16(
                    _mm512_mulhrs_epi16(r_low, v_cr_r),
                    _mm512_mulhrs_epi16(g_low, v_cr_g),
                ),
                _mm512_mulhrs_epi16(b_low, v_cr_b),
            ),
        ));

        let cb = avx512_pack_u16(cb_l, _mm512_setzero_si512());
        let cr = avx512_pack_u16(cr_l, _mm512_setzero_si512());

        _mm256_storeu_si256(
            u_dst.as_mut_ptr() as *mut __m256i,
            _mm512_castsi512_si256(cb),
        );
        _mm256_storeu_si256(
            v_dst.as_mut_ptr() as *mut __m256i,
            _mm512_castsi512_si256(cr),
        );
    } else if chroma_subsampling == YuvChromaSubsampling::Yuv422
        || (chroma_subsampling == YuvChromaSubsampling::Yuv420)
    {
        let r1 = avx512_pairwise_avg_epi8(r_values, 1 << (16 - V_S - 8 - 1));
        let g1 = avx512_pairwise_avg_epi8(g_values, 1 << (16 - V_S - 8 - 1));
        let b1 = avx512_pairwise_avg_epi8(b_values, 1 << (16 - V_S - 8 - 1));

        let cbk = _mm512_srli_epi16::<A_E>(_mm512_add_epi16(
            uv_bias,
            _mm512_add_epi16(
                _mm512_add_epi16(
                    _mm512_mulhrs_epi16(r1, v_cb_r),
                    _mm512_mulhrs_epi16(g1, v_cb_g),
                ),
                _mm512_mulhrs_epi16(b1, v_cb_b),
            ),
        ));

        let crk = _mm512_srli_epi16::<A_E>(_mm512_add_epi16(
            uv_bias,
            _mm512_add_epi16(
                _mm512_add_epi16(
                    _mm512_mulhrs_epi16(r1, v_cr_r),
                    _mm512_mulhrs_epi16(g1, v_cr_g),
                ),
                _mm512_mulhrs_epi16(b1, v_cr_b),
            ),
        ));

        let cb = avx512_pack_u16(cbk, cbk);
        let cr = avx512_pack_u16(crk, crk);

        _mm_storeu_si128(u_dst.as_mut_ptr() as *mut _, _mm512_castsi512_si128(cb));
        _mm_storeu_si128(v_dst.as_mut_ptr() as *mut _, _mm512_castsi512_si128(cr));
    }
}

#[inline(always)]
unsafe fn avx512_rgba_to_yuv_impl<
    const ORIGIN_CHANNELS: u8,
    const SAMPLING: u8,
    const HAS_VBMI: bool,
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

    while cx + 64 < width {
        let px = cx * channels;

        let (r_values, g_values, b_values) =
            avx512_load_rgb_u8::<ORIGIN_CHANNELS, HAS_VBMI>(rgba_ptr.add(px));

        let r_low = _mm512_srli_epi16::<V_S>(_mm512_unpacklo_epi8(r_values, r_values));
        let r_high = _mm512_srli_epi16::<V_S>(_mm512_unpackhi_epi8(r_values, r_values));
        let g_low = _mm512_srli_epi16::<V_S>(_mm512_unpacklo_epi8(g_values, g_values));
        let g_high = _mm512_srli_epi16::<V_S>(_mm512_unpackhi_epi8(g_values, g_values));
        let b_low = _mm512_srli_epi16::<V_S>(_mm512_unpacklo_epi8(b_values, b_values));
        let b_high = _mm512_srli_epi16::<V_S>(_mm512_unpackhi_epi8(b_values, b_values));

        let y_l = _mm512_srli_epi16::<A_E>(_mm512_add_epi16(
            y_bias,
            _mm512_add_epi16(
                _mm512_add_epi16(
                    _mm512_mulhrs_epi16(r_low, v_yr),
                    _mm512_mulhrs_epi16(g_low, v_yg),
                ),
                _mm512_mulhrs_epi16(b_low, v_yb),
            ),
        ));

        let y_h = _mm512_srli_epi16::<A_E>(_mm512_add_epi16(
            y_bias,
            _mm512_add_epi16(
                _mm512_add_epi16(
                    _mm512_mulhrs_epi16(r_high, v_yr),
                    _mm512_mulhrs_epi16(g_high, v_yg),
                ),
                _mm512_mulhrs_epi16(b_high, v_yb),
            ),
        ));

        let y_yuv = _mm512_packus_epi16(y_l, y_h);
        _mm512_storeu_si512(y_ptr.add(cx) as *mut _, y_yuv);

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            let cb_l = _mm512_srli_epi16::<A_E>(_mm512_add_epi16(
                uv_bias,
                _mm512_add_epi16(
                    _mm512_add_epi16(
                        _mm512_mulhrs_epi16(r_low, v_cb_r),
                        _mm512_mulhrs_epi16(g_low, v_cb_g),
                    ),
                    _mm512_mulhrs_epi16(b_low, v_cb_b),
                ),
            ));
            let cr_l = _mm512_srli_epi16::<A_E>(_mm512_add_epi16(
                uv_bias,
                _mm512_add_epi16(
                    _mm512_add_epi16(
                        _mm512_mulhrs_epi16(r_low, v_cr_r),
                        _mm512_mulhrs_epi16(g_low, v_cr_g),
                    ),
                    _mm512_mulhrs_epi16(b_low, v_cr_b),
                ),
            ));
            let cb_h = _mm512_srli_epi16::<A_E>(_mm512_add_epi16(
                uv_bias,
                _mm512_add_epi16(
                    _mm512_add_epi16(
                        _mm512_mulhrs_epi16(r_high, v_cb_r),
                        _mm512_mulhrs_epi16(g_high, v_cb_g),
                    ),
                    _mm512_mulhrs_epi16(b_high, v_cb_b),
                ),
            ));
            let cr_h = _mm512_srli_epi16::<A_E>(_mm512_add_epi16(
                uv_bias,
                _mm512_add_epi16(
                    _mm512_add_epi16(
                        _mm512_mulhrs_epi16(r_high, v_cr_r),
                        _mm512_mulhrs_epi16(g_high, v_cr_g),
                    ),
                    _mm512_mulhrs_epi16(b_high, v_cr_b),
                ),
            ));

            let cb = _mm512_packus_epi16(cb_l, cb_h);
            let cr = _mm512_packus_epi16(cr_l, cr_h);

            _mm512_storeu_si512(u_ptr.add(uv_x) as *mut _, cb);
            _mm512_storeu_si512(v_ptr.add(uv_x) as *mut _, cr);
            uv_x += 64;
        } else if chroma_subsampling == YuvChromaSubsampling::Yuv422
            || (chroma_subsampling == YuvChromaSubsampling::Yuv420)
        {
            let r1 = avx512_pairwise_avg_epi8(r_values, 1 << (16 - V_S - 8 - 1));
            let g1 = avx512_pairwise_avg_epi8(g_values, 1 << (16 - V_S - 8 - 1));
            let b1 = avx512_pairwise_avg_epi8(b_values, 1 << (16 - V_S - 8 - 1));

            let cbk = _mm512_srli_epi16::<A_E>(_mm512_add_epi16(
                uv_bias,
                _mm512_add_epi16(
                    _mm512_add_epi16(
                        _mm512_mulhrs_epi16(r1, v_cb_r),
                        _mm512_mulhrs_epi16(g1, v_cb_g),
                    ),
                    _mm512_mulhrs_epi16(b1, v_cb_b),
                ),
            ));

            let crk = _mm512_srli_epi16::<A_E>(_mm512_add_epi16(
                uv_bias,
                _mm512_add_epi16(
                    _mm512_add_epi16(
                        _mm512_mulhrs_epi16(r1, v_cr_r),
                        _mm512_mulhrs_epi16(g1, v_cr_g),
                    ),
                    _mm512_mulhrs_epi16(b1, v_cr_b),
                ),
            ));

            let cb = avx512_pack_u16(cbk, cbk);
            let cr = avx512_pack_u16(crk, crk);

            _mm256_storeu_si256(
                u_ptr.add(uv_x) as *mut _ as *mut __m256i,
                _mm512_castsi512_si256(cb),
            );
            _mm256_storeu_si256(
                v_ptr.add(uv_x) as *mut _ as *mut __m256i,
                _mm512_castsi512_si256(cr),
            );
            uv_x += 32;
        }

        cx += 64;
    }

    while cx + 32 < width {
        let px = cx * channels;

        encode_32_part::<ORIGIN_CHANNELS, SAMPLING, HAS_VBMI>(
            rgba.get_unchecked(px..),
            y_plane.get_unchecked_mut(cx..),
            u_plane.get_unchecked_mut(uv_x..),
            v_plane.get_unchecked_mut(uv_x..),
            transform,
            range,
        );

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            uv_x += 32;
        } else if chroma_subsampling == YuvChromaSubsampling::Yuv422
            || (chroma_subsampling == YuvChromaSubsampling::Yuv420)
        {
            uv_x += 16;
        }

        cx += 32;
    }

    if cx < width {
        let diff = width - cx;
        assert!(diff <= 32);

        let mut src_buffer: [u8; 32 * 4] = [0; 32 * 4];
        let mut y_buffer: [u8; 32] = [0; 32];
        let mut u_buffer: [u8; 32] = [0; 32];
        let mut v_buffer: [u8; 32] = [0; 32];

        std::ptr::copy_nonoverlapping(
            rgba.get_unchecked(cx * channels..).as_ptr(),
            src_buffer.as_mut_ptr(),
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

        encode_32_part::<ORIGIN_CHANNELS, SAMPLING, HAS_VBMI>(
            src_buffer.as_slice(),
            y_buffer.as_mut_slice(),
            u_buffer.as_mut_slice(),
            v_buffer.as_mut_slice(),
            transform,
            range,
        );

        std::ptr::copy_nonoverlapping(
            y_buffer.as_ptr(),
            y_plane.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );

        cx += diff;
        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            std::ptr::copy_nonoverlapping(
                u_buffer.as_ptr(),
                u_plane.get_unchecked_mut(uv_x..).as_mut_ptr(),
                diff,
            );
            std::ptr::copy_nonoverlapping(
                v_buffer.as_ptr(),
                v_plane.get_unchecked_mut(uv_x..).as_mut_ptr(),
                diff,
            );

            uv_x += diff;
        } else if (chroma_subsampling == YuvChromaSubsampling::Yuv420)
            || (chroma_subsampling == YuvChromaSubsampling::Yuv422)
        {
            let hv = diff.div_ceil(2);
            std::ptr::copy_nonoverlapping(
                u_buffer.as_ptr(),
                u_plane.get_unchecked_mut(uv_x..).as_mut_ptr(),
                hv,
            );
            std::ptr::copy_nonoverlapping(
                v_buffer.as_ptr(),
                v_plane.get_unchecked_mut(uv_x..).as_mut_ptr(),
                hv,
            );

            uv_x += hv;
        }
    }

    ProcessedOffset { cx, ux: uv_x }
}
