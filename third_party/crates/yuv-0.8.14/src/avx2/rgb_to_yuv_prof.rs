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
    _mm256_affine_dot, _mm256_interleave_epi16, _mm256_load_deinterleave_rgb_for_yuv,
    avx2_pack_u16, avx_pairwise_avg_epi16_epi8_j, shuffle,
};
use crate::internals::ProcessedOffset;
use crate::yuv_support::{
    CbCrForwardTransform, YuvChromaRange, YuvChromaSubsampling, YuvSourceChannels,
};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn avx2_rgba_to_yuv_prof<
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
        let source_channels: YuvSourceChannels = ORIGIN_CHANNELS.into();
        if source_channels == YuvSourceChannels::Rgba || source_channels == YuvSourceChannels::Bgra
        {
            return avx2_rgba_to_yuv_impl_prof_4chan::<ORIGIN_CHANNELS, SAMPLING, PRECISION>(
                transform, range, y_plane, u_plane, v_plane, rgba, start_cx, start_ux, width,
            );
        }
        #[cfg(feature = "nightly_avx512")]
        #[allow(clippy::incompatible_msrv)]
        if std::arch::is_x86_feature_detected!("avxvnni") {
            return avx2_rgba_to_yuv_dot::<ORIGIN_CHANNELS, SAMPLING, PRECISION>(
                transform, range, y_plane, u_plane, v_plane, rgba, start_cx, start_ux, width,
            );
        }
        avx2_rgba_to_yuv_def::<ORIGIN_CHANNELS, SAMPLING, PRECISION>(
            transform, range, y_plane, u_plane, v_plane, rgba, start_cx, start_ux, width,
        )
    }
}

#[inline(always)]
unsafe fn encode_32_part<
    const ORIGIN_CHANNELS: u8,
    const SAMPLING: u8,
    const PRECISION: i32,
    const HAS_DOT: bool,
>(
    src: &[u8],
    y_dst: &mut [u8],
    u_dst: &mut [u8],
    v_dst: &mut [u8],
    range: &YuvChromaRange,
    transform: &CbCrForwardTransform<i32>,
) {
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();

    let rounding_const_y = (1 << (PRECISION - 1)) - 1;
    let y_bias = _mm256_set1_epi32(range.bias_y as i32 * (1 << PRECISION) + rounding_const_y);
    let v_yr_yg = _mm256_set1_epi32(transform._interleaved_yr_yg());
    let v_yb = _mm256_set1_epi32(transform.yb);

    let precision_uv = match chroma_subsampling {
        YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => PRECISION + 1,
        YuvChromaSubsampling::Yuv444 => PRECISION,
    };
    let rounding_const_uv = (1 << (precision_uv - 1)) - 1;

    let uv_bias = _mm256_set1_epi32(range.bias_uv as i32 * (1 << precision_uv) + rounding_const_uv);
    let v_cb_r_g = _mm256_set1_epi32(transform._interleaved_cbr_cbg());
    let v_cb_b = _mm256_set1_epi32(transform.cb_b);
    let v_cr_r_g = _mm256_set1_epi32(transform._interleaved_crr_crg());
    let v_cr_b = _mm256_set1_epi32(transform.cr_b);

    let (r_values, g_values, b_values) =
        _mm256_load_deinterleave_rgb_for_yuv::<ORIGIN_CHANNELS>(src.as_ptr());

    let rl0 = _mm256_unpacklo_epi8(r_values, _mm256_setzero_si256());
    let gl0 = _mm256_unpacklo_epi8(g_values, _mm256_setzero_si256());
    let bl0 = _mm256_unpacklo_epi8(b_values, _mm256_setzero_si256());

    let (rl_gl0, rl_gl1) = _mm256_interleave_epi16(rl0, gl0);
    let (b_lo0, b_lo1) = _mm256_interleave_epi16(bl0, _mm256_setzero_si256());

    let y00_vl = _mm256_affine_dot::<PRECISION, HAS_DOT>(
        y_bias, rl_gl0, rl_gl1, b_lo0, b_lo1, v_yr_yg, v_yb,
    );

    let rh0 = _mm256_unpackhi_epi8(r_values, _mm256_setzero_si256());
    let gh0 = _mm256_unpackhi_epi8(g_values, _mm256_setzero_si256());
    let bh0 = _mm256_unpackhi_epi8(b_values, _mm256_setzero_si256());

    let (rl_gh0, rl_gh1) = _mm256_interleave_epi16(rh0, gh0);
    let (b_h0, b_h1) = _mm256_interleave_epi16(bh0, _mm256_setzero_si256());

    let y01_vl =
        _mm256_affine_dot::<PRECISION, HAS_DOT>(y_bias, rl_gh0, rl_gh1, b_h0, b_h1, v_yr_yg, v_yb);

    let y0_values = _mm256_packus_epi16(y00_vl, y01_vl);
    _mm256_storeu_si256(y_dst.as_mut_ptr() as *mut __m256i, y0_values);

    if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
        let cb_l = _mm256_affine_dot::<PRECISION, HAS_DOT>(
            uv_bias, rl_gl0, rl_gl1, b_lo0, b_lo1, v_cb_r_g, v_cb_b,
        );
        let cb_h = _mm256_affine_dot::<PRECISION, HAS_DOT>(
            uv_bias, rl_gh0, rl_gh1, b_h0, b_h1, v_cb_r_g, v_cb_b,
        );
        let cr_l = _mm256_affine_dot::<PRECISION, HAS_DOT>(
            uv_bias, rl_gl0, rl_gl1, b_lo0, b_lo1, v_cr_r_g, v_cr_b,
        );
        let cr_h = _mm256_affine_dot::<PRECISION, HAS_DOT>(
            uv_bias, rl_gh0, rl_gh1, b_h0, b_h1, v_cr_r_g, v_cr_b,
        );

        let cb = _mm256_packus_epi16(cb_l, cb_h);
        let cr = _mm256_packus_epi16(cr_l, cr_h);

        _mm256_storeu_si256(u_dst.as_mut_ptr() as *mut __m256i, cb);
        _mm256_storeu_si256(v_dst.as_mut_ptr() as *mut __m256i, cr);
    } else if chroma_subsampling == YuvChromaSubsampling::Yuv422
        || (chroma_subsampling == YuvChromaSubsampling::Yuv420)
    {
        let r1 = avx_pairwise_avg_epi16_epi8_j(r_values, 1);
        let g1 = avx_pairwise_avg_epi16_epi8_j(g_values, 1);
        let b1 = avx_pairwise_avg_epi16_epi8_j(b_values, 1);

        let (rhv0, rhv1) = _mm256_interleave_epi16(r1, g1);
        let (bhv0, bhv1) = _mm256_interleave_epi16(b1, _mm256_setzero_si256());

        let cb_s =
            _mm256_affine_dot::<16, HAS_DOT>(uv_bias, rhv0, rhv1, bhv0, bhv1, v_cb_r_g, v_cb_b);

        let cr_s =
            _mm256_affine_dot::<16, HAS_DOT>(uv_bias, rhv0, rhv1, bhv0, bhv1, v_cr_r_g, v_cr_b);

        let cb = avx2_pack_u16(cb_s, cb_s);
        let cr = avx2_pack_u16(cr_s, cr_s);

        _mm_storeu_si128(u_dst.as_mut_ptr() as *mut _, _mm256_castsi256_si128(cb));
        _mm_storeu_si128(v_dst.as_mut_ptr() as *mut _, _mm256_castsi256_si128(cr));
    }
}

#[target_feature(enable = "avx2")]
unsafe fn avx2_rgba_to_yuv_def<
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
    avx2_rgba_to_yuv_impl_prof::<ORIGIN_CHANNELS, SAMPLING, PRECISION, false>(
        transform, range, y_plane, u_plane, v_plane, rgba, start_cx, start_ux, width,
    )
}

#[cfg(feature = "nightly_avx512")]
#[target_feature(enable = "avx2", enable = "avxvnni")]
unsafe fn avx2_rgba_to_yuv_dot<
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
    avx2_rgba_to_yuv_impl_prof::<ORIGIN_CHANNELS, SAMPLING, PRECISION, true>(
        transform, range, y_plane, u_plane, v_plane, rgba, start_cx, start_ux, width,
    )
}

#[inline(always)]
unsafe fn avx2_rgba_to_yuv_impl_prof<
    const ORIGIN_CHANNELS: u8,
    const SAMPLING: u8,
    const PRECISION: i32,
    const HAS_DOT: bool,
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

    let mut cx = start_cx;
    let mut uv_x = start_ux;

    while cx + 32 <= width {
        let px = cx * channels;

        encode_32_part::<ORIGIN_CHANNELS, SAMPLING, PRECISION, HAS_DOT>(
            rgba.get_unchecked(px..),
            y_plane.get_unchecked_mut(cx..),
            u_plane.get_unchecked_mut(uv_x..),
            v_plane.get_unchecked_mut(uv_x..),
            range,
            transform,
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
        let mut y_buffer0: [u8; 32] = [0; 32];
        let mut u_buffer: [u8; 32] = [0; 32];
        let mut v_buffer: [u8; 32] = [0; 32];

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

        encode_32_part::<ORIGIN_CHANNELS, SAMPLING, PRECISION, HAS_DOT>(
            src_buffer.as_slice(),
            y_buffer0.as_mut_slice(),
            u_buffer.as_mut_slice(),
            v_buffer.as_mut_slice(),
            range,
            transform,
        );

        std::ptr::copy_nonoverlapping(
            y_buffer0.as_ptr().cast(),
            y_plane.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );

        let ux_size = match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => diff.div_ceil(2),
            YuvChromaSubsampling::Yuv444 => diff,
        };

        std::ptr::copy_nonoverlapping(
            u_buffer.as_ptr().cast(),
            u_plane.get_unchecked_mut(uv_x..).as_mut_ptr(),
            ux_size,
        );
        std::ptr::copy_nonoverlapping(
            v_buffer.as_ptr().cast(),
            v_plane.get_unchecked_mut(uv_x..).as_mut_ptr(),
            ux_size,
        );

        cx += diff;
        uv_x += ux_size;
    }

    ProcessedOffset { cx, ux: uv_x }
}

#[target_feature(enable = "avx2")]
unsafe fn avx2_rgba_to_yuv_impl_prof_4chan<
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

    let y_transform = _mm256_set1_epi64x(transform.avx_make_transform_y(source_channels));
    let cb_transform = _mm256_set1_epi64x(transform.avx_make_transform_cb(source_channels));
    let cr_transform = _mm256_set1_epi64x(transform.avx_make_transform_cr(source_channels));
    let rounding_const_y = (1 << (PRECISION - 1)) - 1;
    let y_bias = _mm256_set1_epi32(range.bias_y as i32 * (1 << PRECISION) + rounding_const_y);
    let precision_uv = if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
        PRECISION
    } else {
        PRECISION + 1
    };
    let rounding_const_uv = (1 << (precision_uv - 1)) - 1;
    let shuf_uv = _mm256_setr_epi8(
        0, 4, 1, 5, 2, 6, -1, -1, 8, 12, 9, 13, 10, 14, -1, -1, 0, 4, 1, 5, 2, 6, -1, -1, 8, 12, 9,
        13, 10, 14, -1, -1,
    );

    const M: i32 = shuffle(3, 1, 2, 0);

    let uv_bias = _mm256_set1_epi32(range.bias_uv as i32 * (1 << precision_uv) + rounding_const_uv);

    let shuf_uv_back = _mm256_setr_epi32(0, 4, 1, 5, -1, -1, -1, -1);

    let mut cx = start_cx;
    let mut uv_x = start_ux;

    while cx + 32 <= width {
        let src_ptr0 = rgba.get_unchecked(cx * channels..);

        let row_z0_0 = _mm256_loadu_si256(src_ptr0.as_ptr() as *const _);
        let row_z1_0 = _mm256_loadu_si256(src_ptr0.get_unchecked(32..).as_ptr() as *const _);
        let row_z2_0 = _mm256_loadu_si256(src_ptr0.get_unchecked(64..).as_ptr() as *const _);
        let row_z3_0 = _mm256_loadu_si256(src_ptr0.get_unchecked(96..).as_ptr() as *const _);

        let w0 = _mm256_unpacklo_epi8(row_z0_0, _mm256_setzero_si256());
        let w1 = _mm256_unpackhi_epi8(row_z0_0, _mm256_setzero_si256());
        let w2 = _mm256_unpacklo_epi8(row_z1_0, _mm256_setzero_si256());
        let w3 = _mm256_unpackhi_epi8(row_z1_0, _mm256_setzero_si256());

        let mut f_y0 = _mm256_hadd_epi32(
            _mm256_madd_epi16(w0, y_transform),
            _mm256_madd_epi16(w1, y_transform),
        );
        f_y0 = _mm256_add_epi32(f_y0, y_bias);
        f_y0 = _mm256_srai_epi32::<PRECISION>(f_y0);

        let mut f_y1 = _mm256_hadd_epi32(
            _mm256_madd_epi16(w2, y_transform),
            _mm256_madd_epi16(w3, y_transform),
        );
        f_y1 = _mm256_add_epi32(f_y1, y_bias);
        f_y1 = _mm256_srai_epi32::<PRECISION>(f_y1);

        // --- Y plane: second 16 pixels ---
        let w4 = _mm256_unpacklo_epi8(row_z2_0, _mm256_setzero_si256());
        let w5 = _mm256_unpackhi_epi8(row_z2_0, _mm256_setzero_si256());
        let w6 = _mm256_unpacklo_epi8(row_z3_0, _mm256_setzero_si256());
        let w7 = _mm256_unpackhi_epi8(row_z3_0, _mm256_setzero_si256());

        let mut f_y2 = _mm256_hadd_epi32(
            _mm256_madd_epi16(w4, y_transform),
            _mm256_madd_epi16(w5, y_transform),
        );
        f_y2 = _mm256_add_epi32(f_y2, y_bias);
        f_y2 = _mm256_srai_epi32::<PRECISION>(f_y2);

        let mut f_y3 = _mm256_hadd_epi32(
            _mm256_madd_epi16(w6, y_transform),
            _mm256_madd_epi16(w7, y_transform),
        );
        f_y3 = _mm256_add_epi32(f_y3, y_bias);
        f_y3 = _mm256_srai_epi32::<PRECISION>(f_y3);

        let z_y0 = _mm256_permute4x64_epi64::<M>(_mm256_packus_epi16(
            _mm256_permute4x64_epi64::<M>(_mm256_packus_epi32(f_y0, f_y1)),
            _mm256_permute4x64_epi64::<M>(_mm256_packus_epi32(f_y2, f_y3)),
        ));

        _mm256_storeu_si256(y_plane.get_unchecked_mut(cx..).as_mut_ptr().cast(), z_y0);

        if chroma_subsampling == YuvChromaSubsampling::Yuv422
            || chroma_subsampling == YuvChromaSubsampling::Yuv420
        {
            let avgu0_v = avx_pairwise_avg_epi16_epi8_j(_mm256_shuffle_epi8(row_z0_0, shuf_uv), 1);
            let avgu1_v = avx_pairwise_avg_epi16_epi8_j(_mm256_shuffle_epi8(row_z1_0, shuf_uv), 1);

            let mut f_cb0 = _mm256_permute4x64_epi64::<M>(_mm256_hadd_epi32(
                _mm256_madd_epi16(avgu0_v, cb_transform),
                _mm256_madd_epi16(avgu1_v, cb_transform),
            ));
            let mut f_cr0 = _mm256_permute4x64_epi64::<M>(_mm256_hadd_epi32(
                _mm256_madd_epi16(avgu0_v, cr_transform),
                _mm256_madd_epi16(avgu1_v, cr_transform),
            ));
            f_cb0 = _mm256_srai_epi32::<16>(_mm256_add_epi32(f_cb0, uv_bias));
            f_cr0 = _mm256_srai_epi32::<16>(_mm256_add_epi32(f_cr0, uv_bias));

            let avgu2_v = avx_pairwise_avg_epi16_epi8_j(_mm256_shuffle_epi8(row_z2_0, shuf_uv), 1);
            let avgu3_v = avx_pairwise_avg_epi16_epi8_j(_mm256_shuffle_epi8(row_z3_0, shuf_uv), 1);

            let mut f_cb1 = _mm256_permute4x64_epi64::<M>(_mm256_hadd_epi32(
                _mm256_madd_epi16(avgu2_v, cb_transform),
                _mm256_madd_epi16(avgu3_v, cb_transform),
            ));
            let mut f_cr1 = _mm256_permute4x64_epi64::<M>(_mm256_hadd_epi32(
                _mm256_madd_epi16(avgu2_v, cr_transform),
                _mm256_madd_epi16(avgu3_v, cr_transform),
            ));
            f_cb1 = _mm256_srai_epi32::<16>(_mm256_add_epi32(f_cb1, uv_bias));
            f_cr1 = _mm256_srai_epi32::<16>(_mm256_add_epi32(f_cr1, uv_bias));

            let z_cb0 = _mm256_permutevar8x32_epi32(
                _mm256_packus_epi16(_mm256_packus_epi32(f_cb0, f_cb1), _mm256_setzero_si256()),
                shuf_uv_back,
            );

            let z_cr0 = _mm256_permutevar8x32_epi32(
                _mm256_packus_epi16(_mm256_packus_epi32(f_cr0, f_cr1), _mm256_setzero_si256()),
                shuf_uv_back,
            );

            _mm_storeu_si128(
                u_plane.get_unchecked_mut(uv_x..).as_mut_ptr() as *mut _,
                _mm256_castsi256_si128(z_cb0),
            );
            _mm_storeu_si128(
                v_plane.get_unchecked_mut(uv_x..).as_mut_ptr() as *mut _,
                _mm256_castsi256_si128(z_cr0),
            );
        } else {
            let mut f_cb0 = _mm256_hadd_epi32(
                _mm256_madd_epi16(w0, cb_transform),
                _mm256_madd_epi16(w1, cb_transform),
            );
            let mut f_cr0 = _mm256_hadd_epi32(
                _mm256_madd_epi16(w0, cr_transform),
                _mm256_madd_epi16(w1, cr_transform),
            );
            let mut f_cb1 = _mm256_hadd_epi32(
                _mm256_madd_epi16(w2, cb_transform),
                _mm256_madd_epi16(w3, cb_transform),
            );
            let mut f_cr1 = _mm256_hadd_epi32(
                _mm256_madd_epi16(w2, cr_transform),
                _mm256_madd_epi16(w3, cr_transform),
            );

            f_cb0 = _mm256_srai_epi32::<PRECISION>(_mm256_add_epi32(f_cb0, uv_bias));
            f_cr0 = _mm256_srai_epi32::<PRECISION>(_mm256_add_epi32(f_cr0, uv_bias));
            f_cb1 = _mm256_srai_epi32::<PRECISION>(_mm256_add_epi32(f_cb1, uv_bias));
            f_cr1 = _mm256_srai_epi32::<PRECISION>(_mm256_add_epi32(f_cr1, uv_bias));

            let mut f_cb2 = _mm256_hadd_epi32(
                _mm256_madd_epi16(w4, cb_transform),
                _mm256_madd_epi16(w5, cb_transform),
            );
            let mut f_cr2 = _mm256_hadd_epi32(
                _mm256_madd_epi16(w4, cr_transform),
                _mm256_madd_epi16(w5, cr_transform),
            );
            let mut f_cb3 = _mm256_hadd_epi32(
                _mm256_madd_epi16(w6, cb_transform),
                _mm256_madd_epi16(w7, cb_transform),
            );
            let mut f_cr3 = _mm256_hadd_epi32(
                _mm256_madd_epi16(w6, cr_transform),
                _mm256_madd_epi16(w7, cr_transform),
            );

            f_cb2 = _mm256_srai_epi32::<PRECISION>(_mm256_add_epi32(f_cb2, uv_bias));
            f_cr2 = _mm256_srai_epi32::<PRECISION>(_mm256_add_epi32(f_cr2, uv_bias));
            f_cb3 = _mm256_srai_epi32::<PRECISION>(_mm256_add_epi32(f_cb3, uv_bias));
            f_cr3 = _mm256_srai_epi32::<PRECISION>(_mm256_add_epi32(f_cr3, uv_bias));

            let z_cb0 = _mm256_permute4x64_epi64::<M>(_mm256_packus_epi16(
                _mm256_permute4x64_epi64::<M>(_mm256_packus_epi32(f_cb0, f_cb1)),
                _mm256_permute4x64_epi64::<M>(_mm256_packus_epi32(f_cb2, f_cb3)),
            ));

            let z_cr0 = _mm256_permute4x64_epi64::<M>(_mm256_packus_epi16(
                _mm256_permute4x64_epi64::<M>(_mm256_packus_epi32(f_cr0, f_cr1)),
                _mm256_permute4x64_epi64::<M>(_mm256_packus_epi32(f_cr2, f_cr3)),
            ));

            _mm256_storeu_si256(u_plane.get_unchecked_mut(uv_x..).as_mut_ptr().cast(), z_cb0);
            _mm256_storeu_si256(v_plane.get_unchecked_mut(uv_x..).as_mut_ptr().cast(), z_cr0);
        }

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            uv_x += 32;
        } else if chroma_subsampling == YuvChromaSubsampling::Yuv422
            || chroma_subsampling == YuvChromaSubsampling::Yuv420
        {
            uv_x += 16;
        }

        cx += 32;
    }

    while cx + 16 <= width {
        let src_ptr0 = rgba.get_unchecked(cx * channels..);

        let row_z0_0 = _mm256_loadu_si256(src_ptr0.as_ptr() as *const _);
        let row_z1_0 = _mm256_loadu_si256(src_ptr0.get_unchecked(32..).as_ptr() as *const _);

        let w0 = _mm256_unpacklo_epi8(row_z0_0, _mm256_setzero_si256());
        let w1 = _mm256_unpackhi_epi8(row_z0_0, _mm256_setzero_si256());

        let rgba0_row0 = _mm256_madd_epi16(w0, y_transform);
        let rgba0_row1 = _mm256_madd_epi16(w1, y_transform);

        let mut f_y0 = _mm256_hadd_epi32(rgba0_row0, rgba0_row1);
        f_y0 = _mm256_add_epi32(f_y0, y_bias);
        f_y0 = _mm256_srai_epi32::<PRECISION>(f_y0);

        let w2 = _mm256_unpacklo_epi8(row_z1_0, _mm256_setzero_si256());
        let w3 = _mm256_unpackhi_epi8(row_z1_0, _mm256_setzero_si256());

        let rgba1_row0 = _mm256_madd_epi16(w2, y_transform);
        let rgba1_row1 = _mm256_madd_epi16(w3, y_transform);

        let mut f_y1 = _mm256_hadd_epi32(rgba1_row0, rgba1_row1);
        f_y1 = _mm256_add_epi32(f_y1, y_bias);
        f_y1 = _mm256_srai_epi32::<PRECISION>(f_y1);

        let z_y = _mm256_permute4x64_epi64::<M>(_mm256_packus_epi16(
            _mm256_permute4x64_epi64::<M>(_mm256_packus_epi32(f_y0, f_y1)),
            _mm256_setzero_si256(),
        ));

        _mm_storeu_si128(
            y_plane.get_unchecked_mut(cx..).as_mut_ptr() as *mut _,
            _mm256_castsi256_si128(z_y),
        );

        if chroma_subsampling == YuvChromaSubsampling::Yuv422
            || (chroma_subsampling == YuvChromaSubsampling::Yuv420)
        {
            let avgu0_v = avx_pairwise_avg_epi16_epi8_j(_mm256_shuffle_epi8(row_z0_0, shuf_uv), 1);
            let avgu1_v = avx_pairwise_avg_epi16_epi8_j(_mm256_shuffle_epi8(row_z1_0, shuf_uv), 1);

            let cb_row0 = _mm256_madd_epi16(avgu0_v, cb_transform);
            let cb_row1 = _mm256_madd_epi16(avgu1_v, cb_transform);
            let cr_row0 = _mm256_madd_epi16(avgu0_v, cr_transform);
            let cr_row1 = _mm256_madd_epi16(avgu1_v, cr_transform);

            const M: i32 = shuffle(3, 1, 2, 0);

            let mut f_cb0 = _mm256_permute4x64_epi64::<M>(_mm256_hadd_epi32(cb_row0, cb_row1));
            let mut f_cr0 = _mm256_permute4x64_epi64::<M>(_mm256_hadd_epi32(cr_row0, cr_row1));

            f_cb0 = _mm256_add_epi32(f_cb0, uv_bias);
            f_cr0 = _mm256_add_epi32(f_cr0, uv_bias);

            f_cb0 = _mm256_srai_epi32::<16>(f_cb0);
            f_cr0 = _mm256_srai_epi32::<16>(f_cr0);

            let z_cb = _mm256_permutevar8x32_epi32(
                _mm256_packus_epi16(
                    _mm256_packus_epi32(f_cb0, _mm256_setzero_si256()),
                    _mm256_setzero_si256(),
                ),
                shuf_uv_back,
            );
            let z_cr = _mm256_permutevar8x32_epi32(
                _mm256_packus_epi16(
                    _mm256_packus_epi32(f_cr0, _mm256_setzero_si256()),
                    _mm256_setzero_si256(),
                ),
                shuf_uv_back,
            );

            _mm_storeu_si64(
                u_plane.get_unchecked_mut(uv_x..).as_mut_ptr() as *mut _,
                _mm256_castsi256_si128(z_cb),
            );
            _mm_storeu_si64(
                v_plane.get_unchecked_mut(uv_x..).as_mut_ptr() as *mut _,
                _mm256_castsi256_si128(z_cr),
            );
        } else {
            let cb0_row0 = _mm256_madd_epi16(w0, cb_transform);
            let cb0_row1 = _mm256_madd_epi16(w1, cb_transform);
            let cr0_row0 = _mm256_madd_epi16(w0, cr_transform);
            let cr0_row1 = _mm256_madd_epi16(w1, cr_transform);

            let mut f_cb0 = _mm256_hadd_epi32(cb0_row0, cb0_row1);
            let mut f_cr0 = _mm256_hadd_epi32(cr0_row0, cr0_row1);

            let cb1_row0 = _mm256_madd_epi16(w2, cb_transform);
            let cb1_row1 = _mm256_madd_epi16(w3, cb_transform);
            let cr1_row0 = _mm256_madd_epi16(w2, cr_transform);
            let cr1_row1 = _mm256_madd_epi16(w3, cr_transform);

            let mut f_cb1 = _mm256_hadd_epi32(cb1_row0, cb1_row1);
            let mut f_cr1 = _mm256_hadd_epi32(cr1_row0, cr1_row1);

            f_cb0 = _mm256_add_epi32(f_cb0, uv_bias);
            f_cr0 = _mm256_add_epi32(f_cr0, uv_bias);

            f_cb1 = _mm256_add_epi32(f_cb1, uv_bias);
            f_cr1 = _mm256_add_epi32(f_cr1, uv_bias);

            f_cb0 = _mm256_srai_epi32::<PRECISION>(f_cb0);
            f_cr0 = _mm256_srai_epi32::<PRECISION>(f_cr0);

            f_cb1 = _mm256_srai_epi32::<PRECISION>(f_cb1);
            f_cr1 = _mm256_srai_epi32::<PRECISION>(f_cr1);

            let z_cb = _mm256_permute4x64_epi64::<M>(_mm256_packus_epi16(
                _mm256_permute4x64_epi64::<M>(_mm256_packus_epi32(f_cb0, f_cb1)),
                _mm256_setzero_si256(),
            ));
            let z_cr = _mm256_permute4x64_epi64::<M>(_mm256_packus_epi16(
                _mm256_permute4x64_epi64::<M>(_mm256_packus_epi32(f_cr0, f_cr1)),
                _mm256_setzero_si256(),
            ));

            _mm_storeu_si128(
                u_plane.get_unchecked_mut(uv_x..).as_mut_ptr() as *mut _,
                _mm256_castsi256_si128(z_cb),
            );
            _mm_storeu_si128(
                v_plane.get_unchecked_mut(uv_x..).as_mut_ptr() as *mut _,
                _mm256_castsi256_si128(z_cr),
            );
        }

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            uv_x += 16;
        } else if chroma_subsampling == YuvChromaSubsampling::Yuv422
            || (chroma_subsampling == YuvChromaSubsampling::Yuv420)
        {
            uv_x += 8;
        }

        cx += 16;
    }

    if cx < width {
        let diff = width - cx;
        assert!(diff <= 16);

        let mut src_buffer: [u8; 16 * 4] = [0; 16 * 4];
        let mut y_buffer0: [u8; 16] = [0; 16];
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

        avx2_rgba_to_yuv_impl_prof_4chan::<ORIGIN_CHANNELS, SAMPLING, PRECISION>(
            transform,
            range,
            &mut y_buffer0,
            &mut u_buffer,
            &mut v_buffer,
            &src_buffer,
            0,
            0,
            16,
        );

        std::ptr::copy_nonoverlapping(
            y_buffer0.as_ptr().cast(),
            y_plane.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );

        let ux_size = match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => diff.div_ceil(2),
            YuvChromaSubsampling::Yuv444 => diff,
        };

        std::ptr::copy_nonoverlapping(
            u_buffer.as_ptr().cast(),
            u_plane.get_unchecked_mut(uv_x..).as_mut_ptr(),
            ux_size,
        );
        std::ptr::copy_nonoverlapping(
            v_buffer.as_ptr().cast(),
            v_plane.get_unchecked_mut(uv_x..).as_mut_ptr(),
            ux_size,
        );

        cx += diff;
        uv_x += ux_size;
    }

    ProcessedOffset { cx, ux: uv_x }
}
