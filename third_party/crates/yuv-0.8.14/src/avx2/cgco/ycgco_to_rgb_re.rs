/*
 * Copyright (c) Radzivon Bartoshyk, 4/2026. All rights reserved.
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
use crate::avx2::avx2_utils::shuffle;
use crate::sse::{sse_store_rgb_u8, sse_store_rgba};
use crate::yuv_support::{YuvChromaRange, YuvSourceChannels};
use crate::YuvChromaSubsampling;
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

macro_rules! store_interleaved_16 {
    ($dst_chans:expr, $dst:expr, $r:expr, $g:expr, $b:expr, $alpha:expr) => {
        match $dst_chans {
            YuvSourceChannels::Rgb => {
                sse_store_rgb_u8($dst, $r, $g, $b);
            }
            YuvSourceChannels::Bgr => {
                sse_store_rgb_u8($dst, $b, $g, $r);
            }
            YuvSourceChannels::Rgba => {
                let a = _mm_set1_epi8($alpha as i8);
                sse_store_rgba($dst, $r, $g, $b, a);
            }
            YuvSourceChannels::Bgra => {
                let a = _mm_set1_epi8($alpha as i8);
                sse_store_rgba($dst, $b, $g, $r, a);
            }
        }
    };
}

#[inline(always)]
unsafe fn avx2_packus_fix(v: __m256i) -> __m128i {
    let packed = _mm256_packus_epi16(v, v);
    let permuted = _mm256_permute4x64_epi64::<{ shuffle(3, 1, 2, 0) }>(packed);
    _mm256_castsi256_si128(permuted)
}

#[inline(always)]
unsafe fn upsample_chroma(q: __m128i) -> __m256i {
    let lo = _mm_unpacklo_epi16(q, q);
    let hi = _mm_unpackhi_epi16(q, q);
    _mm256_set_m128i(hi, lo)
}

#[target_feature(enable = "avx2")]
pub(crate) unsafe fn ycgco_ro_re_u16_to_rgba_avx2<
    const SAMPLING: u8,
    const PRECISION: i32,
    const BIT_DEPTH: usize,
    const R_TYPE: usize,
    const DST_CHANS: u8,
>(
    y_plane: &[u16],
    u_plane: &[u16],
    v_plane: &[u16],
    rgba_data: &mut [u8],
    width: usize,
    chroma_range: YuvChromaRange,
    range_reduction_y: i32,
) {
    let sampling: YuvChromaSubsampling = SAMPLING.into();
    let dst_chans: YuvSourceChannels = DST_CHANS.into();
    let channels = dst_chans.get_channels_count();

    let max_colors = ((1u32 << BIT_DEPTH) - 1u32) as i32;

    let v_bias_y = _mm256_set1_epi16(chroma_range.bias_y as i16);
    let v_bias_uv = _mm256_set1_epi16(chroma_range.bias_uv as i16);
    let v_rry = _mm256_set1_epi16(range_reduction_y as i16);
    let v_round = _mm256_set1_epi32((1 << PRECISION) - 1);

    #[inline(always)]
    unsafe fn scale_and_shift_256_madd<const PRECISION: i32>(
        val: __m256i,
        v_rry: __m256i,
        v_round: __m256i,
    ) -> __m256i {
        let zero = _mm256_setzero_si256();
        let rry_lo = _mm256_unpacklo_epi16(v_rry, zero);

        let val_lo_pairs = _mm256_unpacklo_epi16(val, zero);
        let val_hi_pairs = _mm256_unpackhi_epi16(val, zero);
        let rry_hi = _mm256_unpackhi_epi16(v_rry, zero);

        let lo_scaled = _mm256_add_epi32(v_round, _mm256_madd_epi16(val_lo_pairs, rry_lo));
        let hi_scaled = _mm256_add_epi32(v_round, _mm256_madd_epi16(val_hi_pairs, rry_hi));

        let lo_shifted = _mm256_srai_epi32::<PRECISION>(lo_scaled);
        let hi_shifted = _mm256_srai_epi32::<PRECISION>(hi_scaled);

        _mm256_packus_epi32(lo_shifted, hi_shifted)
    }

    let mut ux = 0usize;
    let mut x = 0usize;

    while x + 16 <= width {
        let y_u16 = _mm256_loadu_si256(y_plane.get_unchecked(x) as *const _ as *const __m256i);

        let (cg_s16, co_s16) = match sampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let cg_raw =
                    _mm_loadu_si128(u_plane.get_unchecked(ux) as *const _ as *const __m128i);
                let co_raw =
                    _mm_loadu_si128(v_plane.get_unchecked(ux) as *const _ as *const __m128i);
                (upsample_chroma(cg_raw), upsample_chroma(co_raw))
            }
            YuvChromaSubsampling::Yuv444 => {
                let cg =
                    _mm256_loadu_si256(u_plane.get_unchecked(ux) as *const _ as *const __m256i);
                let co =
                    _mm256_loadu_si256(v_plane.get_unchecked(ux) as *const _ as *const __m256i);
                (cg, co)
            }
        };

        let y_val = _mm256_subs_epu16(y_u16, v_bias_y);
        let cg_val = _mm256_sub_epi16(cg_s16, v_bias_uv);
        let co_val = _mm256_sub_epi16(co_s16, v_bias_uv);

        let cg_half = _mm256_srai_epi16::<1>(cg_val);
        let co_half = _mm256_srai_epi16::<1>(co_val);
        let t0 = _mm256_sub_epi16(y_val, cg_half);
        let bz0 = _mm256_sub_epi16(t0, co_half);

        let r_s16 = _mm256_add_epi16(bz0, co_val);
        let g_s16 = _mm256_add_epi16(t0, cg_val);
        let b_s16 = bz0;

        let r_u16 = scale_and_shift_256_madd::<PRECISION>(r_s16, v_rry, v_round);
        let g_u16 = scale_and_shift_256_madd::<PRECISION>(g_s16, v_rry, v_round);
        let b_u16 = scale_and_shift_256_madd::<PRECISION>(b_s16, v_rry, v_round);

        let r8 = avx2_packus_fix(r_u16);
        let g8 = avx2_packus_fix(g_u16);
        let b8 = avx2_packus_fix(b_u16);
        let alpha = _mm_set1_epi8(max_colors as i8);
        let dst = rgba_data.get_unchecked_mut(x * channels..).as_mut_ptr();

        match dst_chans {
            YuvSourceChannels::Rgb => sse_store_rgb_u8(dst, r8, g8, b8),
            YuvSourceChannels::Bgr => sse_store_rgb_u8(dst, b8, g8, r8),
            YuvSourceChannels::Rgba => sse_store_rgba(dst, r8, g8, b8, alpha),
            YuvSourceChannels::Bgra => sse_store_rgba(dst, b8, g8, r8, alpha),
        }

        x += 16;
        ux += match sampling {
            YuvChromaSubsampling::Yuv422 | YuvChromaSubsampling::Yuv420 => 8,
            YuvChromaSubsampling::Yuv444 => 16,
        };
    }

    if x < width {
        let diff = width - x;
        assert!(diff < 16);

        let mut y_buffer: [u16; 16] = [0; 16];
        let mut u_buffer: [u16; 16] = [0; 16];
        let mut v_buffer: [u16; 16] = [0; 16];

        std::ptr::copy_nonoverlapping(
            y_plane.get_unchecked(x..).as_ptr(),
            y_buffer.as_mut_ptr(),
            diff,
        );

        let chroma_diff = if sampling == YuvChromaSubsampling::Yuv444 {
            diff
        } else {
            diff.div_ceil(2)
        };

        std::ptr::copy_nonoverlapping(
            u_plane.get_unchecked(ux..).as_ptr(),
            u_buffer.as_mut_ptr(),
            chroma_diff,
        );
        std::ptr::copy_nonoverlapping(
            v_plane.get_unchecked(ux..).as_ptr(),
            v_buffer.as_mut_ptr(),
            chroma_diff,
        );

        let mut buffer: [u8; 16 * 4] = [0; 16 * 4];
        ycgco_ro_re_u16_to_rgba_avx2::<SAMPLING, PRECISION, BIT_DEPTH, R_TYPE, DST_CHANS>(
            &y_buffer,
            &u_buffer,
            &v_buffer,
            &mut buffer,
            16,
            chroma_range,
            range_reduction_y,
        );

        std::ptr::copy_nonoverlapping(
            buffer.as_ptr(),
            rgba_data.get_unchecked_mut(x * channels..).as_mut_ptr(),
            diff * channels,
        );
    }
}

#[target_feature(enable = "avx2")]
pub(crate) unsafe fn ycgco_ro_re_u16_to_rgba_avx2_full<
    const SAMPLING: u8,
    const PRECISION: i32,
    const BIT_DEPTH: usize,
    const R_TYPE: usize,
    const DST_CHANS: u8,
>(
    y_plane: &[u16],
    u_plane: &[u16],
    v_plane: &[u16],
    rgba_data: &mut [u8],
    width: usize,
    chroma_range: YuvChromaRange,
    _range_reduction_y: i32,
) {
    let sampling: YuvChromaSubsampling = SAMPLING.into();
    let dst_chans: YuvSourceChannels = DST_CHANS.into();
    let channels = dst_chans.get_channels_count();

    let max_colors = ((1u32 << BIT_DEPTH) - 1u32) as i32;

    let v_bias_y = _mm256_set1_epi16(chroma_range.bias_y as i16);
    let v_bias_uv = _mm256_set1_epi16(chroma_range.bias_uv as i16);

    let mut ux = 0usize;
    let mut x = 0usize;

    while x + 16 <= width {
        let y_u16 = _mm256_loadu_si256(y_plane.get_unchecked(x) as *const _ as *const __m256i);

        let (cg_s16, co_s16) = match sampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let cg_raw =
                    _mm_loadu_si128(u_plane.get_unchecked(ux) as *const _ as *const __m128i);
                let co_raw =
                    _mm_loadu_si128(v_plane.get_unchecked(ux) as *const _ as *const __m128i);
                (upsample_chroma(cg_raw), upsample_chroma(co_raw))
            }
            YuvChromaSubsampling::Yuv444 => {
                let cg =
                    _mm256_loadu_si256(u_plane.get_unchecked(ux) as *const _ as *const __m256i);
                let co =
                    _mm256_loadu_si256(v_plane.get_unchecked(ux) as *const _ as *const __m256i);
                (cg, co)
            }
        };

        let y_val = _mm256_subs_epu16(y_u16, v_bias_y);
        let cg_val = _mm256_sub_epi16(cg_s16, v_bias_uv);
        let co_val = _mm256_sub_epi16(co_s16, v_bias_uv);

        // YCgCo-R(e/o) inverse:
        // t  = Y - Cg/2
        // B  = t - Co/2
        // R  = B + Co
        // G  = t + Cg
        let cg_half = _mm256_srai_epi16::<1>(cg_val);
        let co_half = _mm256_srai_epi16::<1>(co_val);
        let t0 = _mm256_sub_epi16(y_val, cg_half);
        let bz0 = _mm256_sub_epi16(t0, co_half);

        let r_s16 = _mm256_add_epi16(bz0, co_val);
        let g_s16 = _mm256_add_epi16(t0, cg_val);
        let b_s16 = bz0;

        let r8 = avx2_packus_fix(r_s16);
        let g8 = avx2_packus_fix(g_s16);
        let b8 = avx2_packus_fix(b_s16);

        let dst = rgba_data.get_unchecked_mut(x * channels..).as_mut_ptr();

        store_interleaved_16!(dst_chans, dst, r8, g8, b8, max_colors as u8);

        x += 16;
        ux += match sampling {
            YuvChromaSubsampling::Yuv422 | YuvChromaSubsampling::Yuv420 => 8,
            YuvChromaSubsampling::Yuv444 => 16,
        };
    }

    if x < width {
        let diff = width - x;
        assert!(diff < 16);

        let mut y_buffer: [u16; 16] = [0; 16];
        let mut u_buffer: [u16; 16] = [0; 16];
        let mut v_buffer: [u16; 16] = [0; 16];

        std::ptr::copy_nonoverlapping(
            y_plane.get_unchecked(x..).as_ptr(),
            y_buffer.as_mut_ptr(),
            diff,
        );

        let chroma_diff = if sampling == YuvChromaSubsampling::Yuv444 {
            diff
        } else {
            diff.div_ceil(2)
        };

        std::ptr::copy_nonoverlapping(
            u_plane.get_unchecked(ux..).as_ptr(),
            u_buffer.as_mut_ptr(),
            chroma_diff,
        );
        std::ptr::copy_nonoverlapping(
            v_plane.get_unchecked(ux..).as_ptr(),
            v_buffer.as_mut_ptr(),
            chroma_diff,
        );

        let mut buffer: [u8; 16 * 4] = [0; 16 * 4];

        ycgco_ro_re_u16_to_rgba_avx2_full::<SAMPLING, PRECISION, BIT_DEPTH, R_TYPE, DST_CHANS>(
            &y_buffer,
            &u_buffer,
            &v_buffer,
            &mut buffer,
            16,
            chroma_range,
            _range_reduction_y,
        );

        std::ptr::copy_nonoverlapping(
            buffer.as_ptr(),
            rgba_data.get_unchecked_mut(x * channels..).as_mut_ptr(),
            diff * channels,
        );
    }
}
