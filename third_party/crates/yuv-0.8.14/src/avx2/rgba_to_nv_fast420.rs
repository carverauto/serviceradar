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
    _mm256_expand_rgb_to_rgba, _mm256_interleave_epi8, _mm256_set4r_epi8, avx2_pack_u16,
};
use crate::internals::ProcessedOffset;
use crate::yuv_support::{CbCrForwardTransform, YuvChromaRange, YuvNVOrder, YuvSourceChannels};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn avx2_rgba_to_nv_fast_rgba420<const ORIGIN_CHANNELS: u8, const UV_ORDER: u8>(
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
        #[cfg(feature = "nightly_avx512")]
        {
            #[allow(clippy::incompatible_msrv)]
            if std::arch::is_x86_feature_detected!("avxvnni") {
                return avx2_rgba_to_yuv_fast_rgba_impl_dot420::<ORIGIN_CHANNELS, UV_ORDER>(
                    y_plane0, y_plane1, uv_plane, rgba0, rgba1, width, range, transform, start_cx,
                    start_ux,
                );
            }
        }
        avx2_rgba_to_yuv_fast_rgba_impl_ubs420::<ORIGIN_CHANNELS, UV_ORDER>(
            y_plane0, y_plane1, uv_plane, rgba0, rgba1, width, range, transform, start_cx, start_ux,
        )
    }
}

#[target_feature(enable = "avx2")]
unsafe fn avx2_rgba_to_yuv_fast_rgba_impl_ubs420<const ORIGIN_CHANNELS: u8, const UV_ORDER: u8>(
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
    let uv_order: YuvNVOrder = UV_ORDER.into();

    const A_E: i32 = 7;

    let y_weights = if source_channels == YuvSourceChannels::Rgba
        || source_channels == YuvSourceChannels::Rgb
    {
        _mm256_set4r_epi8(
            transform.yr as i8,
            transform.yg as i8,
            transform.yb as i8,
            0,
        )
    } else {
        _mm256_set4r_epi8(
            transform.yb as i8,
            transform.yg as i8,
            transform.yr as i8,
            0,
        )
    };
    let cb_weights = if source_channels == YuvSourceChannels::Rgba
        || source_channels == YuvSourceChannels::Rgb
    {
        _mm256_set4r_epi8(
            transform.cb_r as i8,
            transform.cb_g as i8,
            transform.cb_b as i8,
            0,
        )
    } else {
        _mm256_set4r_epi8(
            transform.cb_b as i8,
            transform.cb_g as i8,
            transform.cb_r as i8,
            0,
        )
    };
    let cr_weights = if source_channels == YuvSourceChannels::Rgba
        || source_channels == YuvSourceChannels::Rgb
    {
        _mm256_set4r_epi8(
            transform.cr_r as i8,
            transform.cr_g as i8,
            transform.cr_b as i8,
            0,
        )
    } else {
        _mm256_set4r_epi8(
            transform.cr_b as i8,
            transform.cr_g as i8,
            transform.cr_r as i8,
            0,
        )
    };

    let combined_fixup = _mm256_setr_epi32(0, 4, 1, 5, 2, 6, 3, 7);
    let ones_16 = _mm256_set1_epi16(1);
    let y_bias32 = _mm256_set1_epi32(range.bias_y as i32 * (1 << A_E) + (1 << (A_E - 1)) - 1);
    let uv_bias32 = _mm256_set1_epi32(range.bias_uv as i32 * (1 << A_E) + (1 << (A_E - 1)) - 1);

    let mut cx = start_cx;
    let mut ux = start_ux;

    while cx + 32 <= width as usize {
        let src0 = rgba0.get_unchecked(cx * channels..).as_ptr();
        let src1 = rgba1.get_unchecked(cx * channels..).as_ptr();

        let (v0, v1, v2, v3);
        let (v4, v5, v6, v7);

        if source_channels == YuvSourceChannels::Rgba || source_channels == YuvSourceChannels::Bgra
        {
            v0 = _mm256_loadu_si256(src0 as *const __m256i);
            v1 = _mm256_loadu_si256(src0.add(32) as *const __m256i);
            v2 = _mm256_loadu_si256(src0.add(64) as *const __m256i);
            v3 = _mm256_loadu_si256(src0.add(96) as *const __m256i);

            v4 = _mm256_loadu_si256(src1 as *const __m256i);
            v5 = _mm256_loadu_si256(src1.add(32) as *const __m256i);
            v6 = _mm256_loadu_si256(src1.add(64) as *const __m256i);
            v7 = _mm256_loadu_si256(src1.add(96) as *const __m256i);
        } else if source_channels == YuvSourceChannels::Bgr
            || source_channels == YuvSourceChannels::Rgb
        {
            let j0 = _mm256_loadu_si256(src0 as *const __m256i);
            let j1 = _mm256_loadu_si256(src0.add(32) as *const __m256i);
            let j2 = _mm256_loadu_si256(src0.add(64) as *const __m256i);

            let j3 = _mm256_loadu_si256(src1 as *const __m256i);
            let j4 = _mm256_loadu_si256(src1.add(32) as *const __m256i);
            let j5 = _mm256_loadu_si256(src1.add(64) as *const __m256i);

            (v0, v1, v2, v3) = _mm256_expand_rgb_to_rgba(j0, j1, j2);
            (v4, v5, v6, v7) = _mm256_expand_rgb_to_rgba(j3, j4, j5);
        } else {
            unimplemented!()
        }

        let y0s = _mm256_maddubs_epi16(v0, y_weights);
        let y1s = _mm256_maddubs_epi16(v1, y_weights);
        let y2s = _mm256_maddubs_epi16(v2, y_weights);
        let y3s = _mm256_maddubs_epi16(v3, y_weights);

        let uh0 = _mm256_avg_epu8(v0, v4);
        let uh1 = _mm256_avg_epu8(v1, v5);
        let uh2 = _mm256_avg_epu8(v2, v6);
        let uh3 = _mm256_avg_epu8(v3, v7);

        let y4s = _mm256_maddubs_epi16(v4, y_weights);
        let y5s = _mm256_maddubs_epi16(v5, y_weights);
        let y6s = _mm256_maddubs_epi16(v6, y_weights);
        let y7s = _mm256_maddubs_epi16(v7, y_weights);

        // Y channel: vpmaddwd path (i32 accumulation avoids i16 overflow)
        let y0m =
            _mm256_srai_epi32::<A_E>(_mm256_add_epi32(_mm256_madd_epi16(y0s, ones_16), y_bias32));
        let y1m =
            _mm256_srai_epi32::<A_E>(_mm256_add_epi32(_mm256_madd_epi16(y1s, ones_16), y_bias32));
        let y2m =
            _mm256_srai_epi32::<A_E>(_mm256_add_epi32(_mm256_madd_epi16(y2s, ones_16), y_bias32));
        let y3m =
            _mm256_srai_epi32::<A_E>(_mm256_add_epi32(_mm256_madd_epi16(y3s, ones_16), y_bias32));
        let y4m =
            _mm256_srai_epi32::<A_E>(_mm256_add_epi32(_mm256_madd_epi16(y4s, ones_16), y_bias32));
        let y5m =
            _mm256_srai_epi32::<A_E>(_mm256_add_epi32(_mm256_madd_epi16(y5s, ones_16), y_bias32));
        let y6m =
            _mm256_srai_epi32::<A_E>(_mm256_add_epi32(_mm256_madd_epi16(y6s, ones_16), y_bias32));
        let y7m =
            _mm256_srai_epi32::<A_E>(_mm256_add_epi32(_mm256_madd_epi16(y7s, ones_16), y_bias32));

        // Pack i32 -> i16 -> u8 with combined lane fixup
        let y01 = _mm256_packus_epi32(y0m, y1m);
        let y23 = _mm256_packus_epi32(y2m, y3m);
        let y45 = _mm256_packus_epi32(y4m, y5m);
        let y67 = _mm256_packus_epi32(y6m, y7m);

        let y_vl0 = _mm256_permutevar8x32_epi32(_mm256_packus_epi16(y01, y23), combined_fixup);
        let y_vl1 = _mm256_permutevar8x32_epi32(_mm256_packus_epi16(y45, y67), combined_fixup);

        _mm256_storeu_si256(
            y_plane0.get_unchecked_mut(cx..).as_mut_ptr() as *mut _,
            y_vl0,
        );
        _mm256_storeu_si256(
            y_plane1.get_unchecked_mut(cx..).as_mut_ptr() as *mut _,
            y_vl1,
        );

        let even_01 = _mm256_castps_si256(_mm256_shuffle_ps::<0x88>(
            _mm256_castsi256_ps(uh0),
            _mm256_castsi256_ps(uh1),
        ));
        let odd_01 = _mm256_castps_si256(_mm256_shuffle_ps::<0xDD>(
            _mm256_castsi256_ps(uh0),
            _mm256_castsi256_ps(uh1),
        ));
        let even_23 = _mm256_castps_si256(_mm256_shuffle_ps::<0x88>(
            _mm256_castsi256_ps(uh2),
            _mm256_castsi256_ps(uh3),
        ));

        let odd_23 = _mm256_castps_si256(_mm256_shuffle_ps::<0xDD>(
            _mm256_castsi256_ps(uh2),
            _mm256_castsi256_ps(uh3),
        ));

        let v0_f = _mm256_avg_epu8(even_01, odd_01);
        let v1_f = _mm256_avg_epu8(even_23, odd_23);

        let cb0 = _mm256_maddubs_epi16(v0_f, cb_weights);
        let cb1 = _mm256_maddubs_epi16(v1_f, cb_weights);

        let cr0 = _mm256_maddubs_epi16(v0_f, cr_weights);
        let cr1 = _mm256_maddubs_epi16(v1_f, cr_weights);
        let cb0_32 =
            _mm256_srai_epi32::<A_E>(_mm256_add_epi32(_mm256_madd_epi16(cb0, ones_16), uv_bias32));
        let cb1_32 =
            _mm256_srai_epi32::<A_E>(_mm256_add_epi32(_mm256_madd_epi16(cb1, ones_16), uv_bias32));
        let cr0_32 =
            _mm256_srai_epi32::<A_E>(_mm256_add_epi32(_mm256_madd_epi16(cr0, ones_16), uv_bias32));
        let cr1_32 =
            _mm256_srai_epi32::<A_E>(_mm256_add_epi32(_mm256_madd_epi16(cr1, ones_16), uv_bias32));

        let mut cb00 = _mm256_packs_epi32(cb0_32, cb1_32);
        let mut cr00 = _mm256_packs_epi32(cr0_32, cr1_32);

        cr00 = _mm256_permutevar8x32_epi32(cr00, combined_fixup);
        cb00 = _mm256_permutevar8x32_epi32(cb00, combined_fixup);

        let mut cb_vl = avx2_pack_u16(cb00, cb00);
        let mut cr_vl = avx2_pack_u16(cr00, cr00);

        if uv_order == YuvNVOrder::VU {
            std::mem::swap(&mut cb_vl, &mut cr_vl);
        }

        let uv_interleaved = _mm256_interleave_epi8(cb_vl, cr_vl);

        _mm256_storeu_si256(
            uv_plane.get_unchecked_mut(ux..).as_mut_ptr() as *mut _,
            uv_interleaved.0,
        );

        ux += 32;
        cx += 32;
    }

    if cx < width as usize {
        let diff = width as usize - cx;
        assert!(diff <= 32);

        let mut src_buffer0: [u8; 32 * 4] = [0; 32 * 4];
        let mut src_buffer1: [u8; 32 * 4] = [0; 32 * 4];
        let mut y_buffer0: [u8; 32] = [0; 32];
        let mut y_buffer1: [u8; 32] = [0; 32];
        let mut uv_buffer: [u8; 32] = [0; 32];

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
            v0 = _mm256_loadu_si256(src_buffer0.as_ptr() as *const __m256i);
            v1 = _mm256_loadu_si256(src_buffer0.as_ptr().add(32) as *const __m256i);
            v2 = _mm256_loadu_si256(src_buffer0.as_ptr().add(64) as *const __m256i);
            v3 = _mm256_loadu_si256(src_buffer0.as_ptr().add(96) as *const __m256i);

            v4 = _mm256_loadu_si256(src_buffer1.as_ptr() as *const __m256i);
            v5 = _mm256_loadu_si256(src_buffer1.as_ptr().add(32) as *const __m256i);
            v6 = _mm256_loadu_si256(src_buffer1.as_ptr().add(64) as *const __m256i);
            v7 = _mm256_loadu_si256(src_buffer1.as_ptr().add(96) as *const __m256i);
        } else if source_channels == YuvSourceChannels::Bgr
            || source_channels == YuvSourceChannels::Rgb
        {
            let j0 = _mm256_loadu_si256(src_buffer0.as_ptr() as *const __m256i);
            let j1 = _mm256_loadu_si256(src_buffer0.as_ptr().add(32) as *const __m256i);
            let j2 = _mm256_loadu_si256(src_buffer0.as_ptr().add(64) as *const __m256i);

            let j3 = _mm256_loadu_si256(src_buffer1.as_ptr() as *const __m256i);
            let j4 = _mm256_loadu_si256(src_buffer1.as_ptr().add(32) as *const __m256i);
            let j5 = _mm256_loadu_si256(src_buffer1.as_ptr().add(64) as *const __m256i);

            (v0, v1, v2, v3) = _mm256_expand_rgb_to_rgba(j0, j1, j2);
            (v4, v5, v6, v7) = _mm256_expand_rgb_to_rgba(j3, j4, j5);
        } else {
            unimplemented!()
        }

        let y0s = _mm256_maddubs_epi16(v0, y_weights);
        let y1s = _mm256_maddubs_epi16(v1, y_weights);
        let y2s = _mm256_maddubs_epi16(v2, y_weights);
        let y3s = _mm256_maddubs_epi16(v3, y_weights);

        let uh0 = _mm256_avg_epu8(v0, v4);
        let uh1 = _mm256_avg_epu8(v1, v5);
        let uh2 = _mm256_avg_epu8(v2, v6);
        let uh3 = _mm256_avg_epu8(v3, v7);

        let y4s = _mm256_maddubs_epi16(v4, y_weights);
        let y5s = _mm256_maddubs_epi16(v5, y_weights);
        let y6s = _mm256_maddubs_epi16(v6, y_weights);
        let y7s = _mm256_maddubs_epi16(v7, y_weights);

        // Y channel: vpmaddwd path (i32 accumulation avoids i16 overflow)
        let y0m =
            _mm256_srai_epi32::<A_E>(_mm256_add_epi32(_mm256_madd_epi16(y0s, ones_16), y_bias32));
        let y1m =
            _mm256_srai_epi32::<A_E>(_mm256_add_epi32(_mm256_madd_epi16(y1s, ones_16), y_bias32));
        let y2m =
            _mm256_srai_epi32::<A_E>(_mm256_add_epi32(_mm256_madd_epi16(y2s, ones_16), y_bias32));
        let y3m =
            _mm256_srai_epi32::<A_E>(_mm256_add_epi32(_mm256_madd_epi16(y3s, ones_16), y_bias32));
        let y4m =
            _mm256_srai_epi32::<A_E>(_mm256_add_epi32(_mm256_madd_epi16(y4s, ones_16), y_bias32));
        let y5m =
            _mm256_srai_epi32::<A_E>(_mm256_add_epi32(_mm256_madd_epi16(y5s, ones_16), y_bias32));
        let y6m =
            _mm256_srai_epi32::<A_E>(_mm256_add_epi32(_mm256_madd_epi16(y6s, ones_16), y_bias32));
        let y7m =
            _mm256_srai_epi32::<A_E>(_mm256_add_epi32(_mm256_madd_epi16(y7s, ones_16), y_bias32));

        // Pack i32 -> i16 -> u8 with combined lane fixup
        let y01 = _mm256_packus_epi32(y0m, y1m);
        let y23 = _mm256_packus_epi32(y2m, y3m);
        let y45 = _mm256_packus_epi32(y4m, y5m);
        let y67 = _mm256_packus_epi32(y6m, y7m);

        let y_vl0 = _mm256_permutevar8x32_epi32(_mm256_packus_epi16(y01, y23), combined_fixup);
        let y_vl1 = _mm256_permutevar8x32_epi32(_mm256_packus_epi16(y45, y67), combined_fixup);

        _mm256_storeu_si256(y_buffer0.as_mut_ptr() as *mut _, y_vl0);
        _mm256_storeu_si256(y_buffer1.as_mut_ptr() as *mut _, y_vl1);

        let even_01 = _mm256_castps_si256(_mm256_shuffle_ps::<0x88>(
            _mm256_castsi256_ps(uh0),
            _mm256_castsi256_ps(uh1),
        ));
        let odd_01 = _mm256_castps_si256(_mm256_shuffle_ps::<0xDD>(
            _mm256_castsi256_ps(uh0),
            _mm256_castsi256_ps(uh1),
        ));
        let even_23 = _mm256_castps_si256(_mm256_shuffle_ps::<0x88>(
            _mm256_castsi256_ps(uh2),
            _mm256_castsi256_ps(uh3),
        ));

        let odd_23 = _mm256_castps_si256(_mm256_shuffle_ps::<0xDD>(
            _mm256_castsi256_ps(uh2),
            _mm256_castsi256_ps(uh3),
        ));

        let v0_f = _mm256_avg_epu8(even_01, odd_01);
        let v1_f = _mm256_avg_epu8(even_23, odd_23);

        let cb0 = _mm256_maddubs_epi16(v0_f, cb_weights);
        let cb1 = _mm256_maddubs_epi16(v1_f, cb_weights);

        let cr0 = _mm256_maddubs_epi16(v0_f, cr_weights);
        let cr1 = _mm256_maddubs_epi16(v1_f, cr_weights);
        let cb0_32 =
            _mm256_srai_epi32::<A_E>(_mm256_add_epi32(_mm256_madd_epi16(cb0, ones_16), uv_bias32));
        let cb1_32 =
            _mm256_srai_epi32::<A_E>(_mm256_add_epi32(_mm256_madd_epi16(cb1, ones_16), uv_bias32));
        let cr0_32 =
            _mm256_srai_epi32::<A_E>(_mm256_add_epi32(_mm256_madd_epi16(cr0, ones_16), uv_bias32));
        let cr1_32 =
            _mm256_srai_epi32::<A_E>(_mm256_add_epi32(_mm256_madd_epi16(cr1, ones_16), uv_bias32));

        let mut cb00 = _mm256_packs_epi32(cb0_32, cb1_32);
        let mut cr00 = _mm256_packs_epi32(cr0_32, cr1_32);

        cr00 = _mm256_permutevar8x32_epi32(cr00, combined_fixup);
        cb00 = _mm256_permutevar8x32_epi32(cb00, combined_fixup);

        let mut cb_vl = avx2_pack_u16(cb00, cb00);
        let mut cr_vl = avx2_pack_u16(cr00, cr00);

        if uv_order == YuvNVOrder::VU {
            std::mem::swap(&mut cb_vl, &mut cr_vl);
        }

        let uv_interleaved = _mm256_interleave_epi8(cb_vl, cr_vl);

        _mm256_storeu_si256(uv_buffer.as_mut_ptr() as *mut _, uv_interleaved.0);

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

#[cfg(feature = "nightly_avx512")]
#[target_feature(enable = "avx2", enable = "avxvnni")]
unsafe fn avx2_rgba_to_yuv_fast_rgba_impl_dot420<const ORIGIN_CHANNELS: u8, const UV_ORDER: u8>(
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
    let uv_order: YuvNVOrder = UV_ORDER.into();

    const A_E: i32 = 7;
    let y_bias = _mm256_set1_epi32(range.bias_y as i32 * (1 << A_E) + (1 << (A_E - 1)) - 1);
    let uv_bias = _mm256_set1_epi32(range.bias_uv as i32 * (1 << A_E) + (1 << (A_E - 1)) - 1);

    let y_weights = if source_channels == YuvSourceChannels::Rgba
        || source_channels == YuvSourceChannels::Rgb
    {
        _mm256_set4r_epi8(
            transform.yr as i8,
            transform.yg as i8,
            transform.yb as i8,
            0,
        )
    } else {
        _mm256_set4r_epi8(
            transform.yb as i8,
            transform.yg as i8,
            transform.yr as i8,
            0,
        )
    };
    let cb_weights = if source_channels == YuvSourceChannels::Rgba
        || source_channels == YuvSourceChannels::Rgb
    {
        _mm256_set4r_epi8(
            transform.cb_r as i8,
            transform.cb_g as i8,
            transform.cb_b as i8,
            0,
        )
    } else {
        _mm256_set4r_epi8(
            transform.cb_b as i8,
            transform.cb_g as i8,
            transform.cb_r as i8,
            0,
        )
    };
    let cr_weights = if source_channels == YuvSourceChannels::Rgba
        || source_channels == YuvSourceChannels::Rgb
    {
        _mm256_set4r_epi8(
            transform.cr_r as i8,
            transform.cr_g as i8,
            transform.cr_b as i8,
            0,
        )
    } else {
        _mm256_set4r_epi8(
            transform.cr_b as i8,
            transform.cr_g as i8,
            transform.cr_r as i8,
            0,
        )
    };

    use crate::avx2::avx2_utils::avx2_pack_u32;

    let v422_shuffle = _mm256_setr_epi32(0, 2, 4, 6, 1, 3, 5, 7);

    let mut cx = start_cx;
    let mut ux = start_ux;

    while cx + 32 <= width as usize {
        let src0 = rgba0.get_unchecked(cx * channels..).as_ptr();
        let src1 = rgba1.get_unchecked(cx * channels..).as_ptr();

        let (v0, v1, v2, v3);
        let (v4, v5, v6, v7);

        if source_channels == YuvSourceChannels::Rgba || source_channels == YuvSourceChannels::Bgra
        {
            v0 = _mm256_loadu_si256(src0 as *const __m256i);
            v1 = _mm256_loadu_si256(src0.add(32) as *const __m256i);
            v2 = _mm256_loadu_si256(src0.add(64) as *const __m256i);
            v3 = _mm256_loadu_si256(src0.add(96) as *const __m256i);

            v4 = _mm256_loadu_si256(src1 as *const __m256i);
            v5 = _mm256_loadu_si256(src1.add(32) as *const __m256i);
            v6 = _mm256_loadu_si256(src1.add(64) as *const __m256i);
            v7 = _mm256_loadu_si256(src1.add(96) as *const __m256i);
        } else if source_channels == YuvSourceChannels::Bgr
            || source_channels == YuvSourceChannels::Rgb
        {
            let j0 = _mm256_loadu_si256(src0 as *const __m256i);
            let j1 = _mm256_loadu_si256(src0.add(32) as *const __m256i);
            let j2 = _mm256_loadu_si256(src0.add(64) as *const __m256i);

            let j3 = _mm256_loadu_si256(src1 as *const __m256i);
            let j4 = _mm256_loadu_si256(src1.add(32) as *const __m256i);
            let j5 = _mm256_loadu_si256(src1.add(64) as *const __m256i);

            (v0, v1, v2, v3) = _mm256_expand_rgb_to_rgba(j0, j1, j2);
            (v4, v5, v6, v7) = _mm256_expand_rgb_to_rgba(j3, j4, j5);
        } else {
            unimplemented!()
        }

        let y0s = _mm256_dpbusd_avx_epi32(y_bias, v0, y_weights);
        let y1s = _mm256_dpbusd_avx_epi32(y_bias, v1, y_weights);
        let y2s = _mm256_dpbusd_avx_epi32(y_bias, v2, y_weights);
        let y3s = _mm256_dpbusd_avx_epi32(y_bias, v3, y_weights);

        let uh0 = _mm256_avg_epu8(v0, v4);
        let uh1 = _mm256_avg_epu8(v1, v5);
        let uh2 = _mm256_avg_epu8(v2, v6);
        let uh3 = _mm256_avg_epu8(v3, v7);

        let y4s = _mm256_dpbusd_avx_epi32(y_bias, v4, y_weights);
        let y5s = _mm256_dpbusd_avx_epi32(y_bias, v5, y_weights);
        let y6s = _mm256_dpbusd_avx_epi32(y_bias, v6, y_weights);
        let y7s = _mm256_dpbusd_avx_epi32(y_bias, v7, y_weights);

        let v0_s = _mm256_permutevar8x32_epi32(uh0, v422_shuffle);
        let v1_s = _mm256_permutevar8x32_epi32(uh1, v422_shuffle);
        let v2_s = _mm256_permutevar8x32_epi32(uh2, v422_shuffle);
        let v3_s = _mm256_permutevar8x32_epi32(uh3, v422_shuffle);

        let mut y0m = avx2_pack_u32(y0s, y1s);
        let mut y1m = avx2_pack_u32(y2s, y3s);
        let mut y2m = avx2_pack_u32(y4s, y5s);
        let mut y3m = avx2_pack_u32(y6s, y7s);

        y0m = _mm256_srai_epi16::<A_E>(y0m);
        y1m = _mm256_srai_epi16::<A_E>(y1m);
        y2m = _mm256_srai_epi16::<A_E>(y2m);
        y3m = _mm256_srai_epi16::<A_E>(y3m);

        let y_vl0 = avx2_pack_u16(y0m, y1m);
        let y_vl1 = avx2_pack_u16(y2m, y3m);

        _mm256_storeu_si256(
            y_plane0.get_unchecked_mut(cx..).as_mut_ptr() as *mut _,
            y_vl0,
        );
        _mm256_storeu_si256(
            y_plane1.get_unchecked_mut(cx..).as_mut_ptr() as *mut _,
            y_vl1,
        );

        let h0 = _mm256_extracti128_si256::<1>(v0_s);
        let h1 = _mm256_extracti128_si256::<1>(v1_s);
        let h2 = _mm256_extracti128_si256::<1>(v2_s);
        let h3 = _mm256_extracti128_si256::<1>(v3_s);

        let vh0 = _mm_avg_epu8(_mm256_castsi256_si128(v0_s), h0);
        let vh1 = _mm_avg_epu8(_mm256_castsi256_si128(v1_s), h1);
        let vh2 = _mm_avg_epu8(_mm256_castsi256_si128(v2_s), h2);
        let vh3 = _mm_avg_epu8(_mm256_castsi256_si128(v3_s), h3);

        let v0_f = _mm256_set_m128i(vh1, vh0);
        let v1_f = _mm256_set_m128i(vh3, vh2);

        let cb0 = _mm256_dpbusd_avx_epi32(uv_bias, v0_f, cb_weights);
        let cb1 = _mm256_dpbusd_avx_epi32(uv_bias, v1_f, cb_weights);

        let cr0 = _mm256_dpbusd_avx_epi32(uv_bias, v0_f, cr_weights);
        let cr1 = _mm256_dpbusd_avx_epi32(uv_bias, v1_f, cr_weights);

        let mut cb00 = avx2_pack_u32(cb0, cb1);
        let mut cr00 = avx2_pack_u32(cr0, cr1);

        cb00 = _mm256_srai_epi16::<A_E>(cb00);
        cr00 = _mm256_srai_epi16::<A_E>(cr00);

        let mut cb_vl = avx2_pack_u16(cb00, cb00);
        let mut cr_vl = avx2_pack_u16(cr00, cr00);

        if uv_order == YuvNVOrder::VU {
            std::mem::swap(&mut cb_vl, &mut cr_vl);
        }

        let uv_interleaved = _mm256_interleave_epi8(cb_vl, cr_vl);

        _mm256_storeu_si256(
            uv_plane.get_unchecked_mut(ux..).as_mut_ptr() as *mut _,
            uv_interleaved.0,
        );

        ux += 32;
        cx += 32;
    }

    if cx < width as usize {
        let diff = width as usize - cx;
        assert!(diff <= 32);

        let mut src_buffer0: [u8; 32 * 4] = [0; 32 * 4];
        let mut src_buffer1: [u8; 32 * 4] = [0; 32 * 4];
        let mut y_buffer0: [u8; 32] = [0; 32];
        let mut y_buffer1: [u8; 32] = [0; 32];
        let mut uv_buffer: [u8; 32] = [0; 32];

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

        let (v0, v1, v2, v3);
        let (v4, v5, v6, v7);

        if source_channels == YuvSourceChannels::Rgba || source_channels == YuvSourceChannels::Bgra
        {
            v0 = _mm256_loadu_si256(src_buffer0.as_ptr() as *const __m256i);
            v1 = _mm256_loadu_si256(src_buffer0.as_ptr().add(32) as *const __m256i);
            v2 = _mm256_loadu_si256(src_buffer0.as_ptr().add(64) as *const __m256i);
            v3 = _mm256_loadu_si256(src_buffer0.as_ptr().add(96) as *const __m256i);

            v4 = _mm256_loadu_si256(src_buffer1.as_ptr() as *const __m256i);
            v5 = _mm256_loadu_si256(src_buffer1.as_ptr().add(32) as *const __m256i);
            v6 = _mm256_loadu_si256(src_buffer1.as_ptr().add(64) as *const __m256i);
            v7 = _mm256_loadu_si256(src_buffer1.as_ptr().add(96) as *const __m256i);
        } else if source_channels == YuvSourceChannels::Bgr
            || source_channels == YuvSourceChannels::Rgb
        {
            let j0 = _mm256_loadu_si256(src_buffer0.as_ptr() as *const __m256i);
            let j1 = _mm256_loadu_si256(src_buffer0.as_ptr().add(32) as *const __m256i);
            let j2 = _mm256_loadu_si256(src_buffer0.as_ptr().add(64) as *const __m256i);

            let j3 = _mm256_loadu_si256(src_buffer1.as_ptr() as *const __m256i);
            let j4 = _mm256_loadu_si256(src_buffer1.as_ptr().add(32) as *const __m256i);
            let j5 = _mm256_loadu_si256(src_buffer1.as_ptr().add(64) as *const __m256i);

            (v0, v1, v2, v3) = _mm256_expand_rgb_to_rgba(j0, j1, j2);
            (v4, v5, v6, v7) = _mm256_expand_rgb_to_rgba(j3, j4, j5);
        } else {
            unimplemented!()
        }

        let y0s = _mm256_dpbusd_avx_epi32(y_bias, v0, y_weights);
        let y1s = _mm256_dpbusd_avx_epi32(y_bias, v1, y_weights);
        let y2s = _mm256_dpbusd_avx_epi32(y_bias, v2, y_weights);
        let y3s = _mm256_dpbusd_avx_epi32(y_bias, v3, y_weights);

        let uh0 = _mm256_avg_epu8(v0, v4);
        let uh1 = _mm256_avg_epu8(v1, v5);
        let uh2 = _mm256_avg_epu8(v2, v6);
        let uh3 = _mm256_avg_epu8(v3, v7);

        let y4s = _mm256_dpbusd_avx_epi32(y_bias, v4, y_weights);
        let y5s = _mm256_dpbusd_avx_epi32(y_bias, v5, y_weights);
        let y6s = _mm256_dpbusd_avx_epi32(y_bias, v6, y_weights);
        let y7s = _mm256_dpbusd_avx_epi32(y_bias, v7, y_weights);

        let v0_s = _mm256_permutevar8x32_epi32(uh0, v422_shuffle);
        let v1_s = _mm256_permutevar8x32_epi32(uh1, v422_shuffle);
        let v2_s = _mm256_permutevar8x32_epi32(uh2, v422_shuffle);
        let v3_s = _mm256_permutevar8x32_epi32(uh3, v422_shuffle);

        let mut y0m = avx2_pack_u32(y0s, y1s);
        let mut y1m = avx2_pack_u32(y2s, y3s);
        let mut y2m = avx2_pack_u32(y4s, y5s);
        let mut y3m = avx2_pack_u32(y6s, y7s);

        y0m = _mm256_srai_epi16::<A_E>(y0m);
        y1m = _mm256_srai_epi16::<A_E>(y1m);
        y2m = _mm256_srai_epi16::<A_E>(y2m);
        y3m = _mm256_srai_epi16::<A_E>(y3m);

        let y_vl0 = avx2_pack_u16(y0m, y1m);
        let y_vl1 = avx2_pack_u16(y2m, y3m);

        _mm256_storeu_si256(y_buffer0.as_mut_ptr() as *mut _, y_vl0);
        _mm256_storeu_si256(y_buffer1.as_mut_ptr() as *mut _, y_vl1);

        let h0 = _mm256_extracti128_si256::<1>(v0_s);
        let h1 = _mm256_extracti128_si256::<1>(v1_s);
        let h2 = _mm256_extracti128_si256::<1>(v2_s);
        let h3 = _mm256_extracti128_si256::<1>(v3_s);

        let vh0 = _mm_avg_epu8(_mm256_castsi256_si128(v0_s), h0);
        let vh1 = _mm_avg_epu8(_mm256_castsi256_si128(v1_s), h1);
        let vh2 = _mm_avg_epu8(_mm256_castsi256_si128(v2_s), h2);
        let vh3 = _mm_avg_epu8(_mm256_castsi256_si128(v3_s), h3);

        let v0_f = _mm256_set_m128i(vh1, vh0);
        let v1_f = _mm256_set_m128i(vh3, vh2);

        let cb0 = _mm256_dpbusd_avx_epi32(uv_bias, v0_f, cb_weights);
        let cb1 = _mm256_dpbusd_avx_epi32(uv_bias, v1_f, cb_weights);

        let cr0 = _mm256_dpbusd_avx_epi32(uv_bias, v0_f, cr_weights);
        let cr1 = _mm256_dpbusd_avx_epi32(uv_bias, v1_f, cr_weights);

        let mut cb00 = avx2_pack_u32(cb0, cb1);
        let mut cr00 = avx2_pack_u32(cr0, cr1);

        cb00 = _mm256_srai_epi16::<A_E>(cb00);
        cr00 = _mm256_srai_epi16::<A_E>(cr00);

        let mut cb_vl = avx2_pack_u16(cb00, cb00);
        let mut cr_vl = avx2_pack_u16(cr00, cr00);

        if uv_order == YuvNVOrder::VU {
            std::mem::swap(&mut cb_vl, &mut cr_vl);
        }

        let uv_interleaved = _mm256_interleave_epi8(cb_vl, cr_vl);

        _mm256_storeu_si256(uv_buffer.as_mut_ptr() as *mut _, uv_interleaved.0);

        std::ptr::copy_nonoverlapping(
            y_buffer0.as_ptr(),
            y_plane0.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );
        std::ptr::copy_nonoverlapping(
            y_buffer1.as_ptr(),
            y_plane1.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );

        cx += diff;

        let hv = diff.div_ceil(2) * 2;
        std::ptr::copy_nonoverlapping(
            uv_buffer.as_ptr(),
            uv_plane.get_unchecked_mut(ux..).as_mut_ptr(),
            hv,
        );

        ux += hv;
    }

    ProcessedOffset { cx, ux }
}
