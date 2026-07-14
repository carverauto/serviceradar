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
    _mm256_deinterleave_rgba_epi8, _mm256_double_affine_uv_dot, _mm256_double_affine_uv_s_dot,
    avx2_deinterleave_rgb, shuffle,
};
use crate::internals::ProcessedOffset;
use crate::rdp::RdpChannels;
use crate::yuv_support::CbCrForwardTransform;
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn rdp_avx2_rgba_to_yuv<const ORIGIN_CHANNELS: u8, const Q: i32>(
    transform: &CbCrForwardTransform<i32>,
    y_plane: &mut [i16],
    u_plane: &mut [i16],
    v_plane: &mut [i16],
    rgba: &[u8],
    width: usize,
) -> ProcessedOffset {
    unsafe {
        let source_channels: RdpChannels = ORIGIN_CHANNELS.into();
        if source_channels == RdpChannels::Abgr
            || source_channels == RdpChannels::Argb
            || source_channels == RdpChannels::Bgra
            || source_channels == RdpChannels::Rgba
        {
            rdp_avx2_4chan_to_yuv_impl::<ORIGIN_CHANNELS, Q>(
                transform, y_plane, u_plane, v_plane, rgba, width,
            )
        } else {
            rdp_avx2_rgba_to_yuv_impl::<ORIGIN_CHANNELS, Q>(
                transform, y_plane, u_plane, v_plane, rgba, width,
            )
        }
    }
}

#[inline(always)]
unsafe fn _mm256_load_rdp_deinterleave_rgb_for_yuv<const ORIGINS: u8>(
    ptr: *const u8,
) -> (__m256i, __m256i, __m256i) {
    let source_channels: RdpChannels = ORIGINS.into();

    let (r_values, g_values, b_values);

    let row_1 = _mm256_loadu_si256(ptr as *const __m256i);
    let row_2 = _mm256_loadu_si256(ptr.add(32) as *const __m256i);
    let row_3 = _mm256_loadu_si256(ptr.add(64) as *const __m256i);

    match source_channels {
        RdpChannels::Rgb | RdpChannels::Bgr => {
            let (it1, it2, it3) = avx2_deinterleave_rgb(row_1, row_2, row_3);
            if source_channels == RdpChannels::Rgb {
                r_values = it1;
                g_values = it2;
                b_values = it3;
            } else {
                r_values = it3;
                g_values = it2;
                b_values = it1;
            }
        }
        RdpChannels::Rgba | RdpChannels::Bgra => {
            let row_4 = _mm256_loadu_si256(ptr.add(96) as *const __m256i);

            let (it1, it2, it3, _) = _mm256_deinterleave_rgba_epi8(row_1, row_2, row_3, row_4);
            if source_channels == RdpChannels::Rgba {
                r_values = it1;
                g_values = it2;
                b_values = it3;
            } else {
                r_values = it3;
                g_values = it2;
                b_values = it1;
            }
        }
        RdpChannels::Abgr => {
            let row_4 = _mm256_loadu_si256(ptr.add(96) as *const __m256i);

            let (_, b, g, r) = _mm256_deinterleave_rgba_epi8(row_1, row_2, row_3, row_4);
            r_values = r;
            g_values = g;
            b_values = b;
        }
        RdpChannels::Argb => {
            let row_4 = _mm256_loadu_si256(ptr.add(96) as *const __m256i);

            let (_, r, g, b) = _mm256_deinterleave_rgba_epi8(row_1, row_2, row_3, row_4);
            r_values = r;
            g_values = g;
            b_values = b;
        }
    }

    (r_values, g_values, b_values)
}

#[target_feature(enable = "avx2")]
unsafe fn rdp_avx2_rgba_to_yuv_impl<const ORIGIN_CHANNELS: u8, const Q: i32>(
    transform: &CbCrForwardTransform<i32>,
    y_plane: &mut [i16],
    u_plane: &mut [i16],
    v_plane: &mut [i16],
    rgba: &[u8],
    width: usize,
) -> ProcessedOffset {
    let source_channels: RdpChannels = ORIGIN_CHANNELS.into();
    let channels = source_channels.channel_count();

    let src_ptr = rgba;
    let uv_bias = _mm256_setzero_si256();
    let v_cbr_cbg = _mm256_set1_epi32(transform._interleaved_cbr_cbg());
    let v_cb_b = _mm256_set1_epi16(transform.cb_b as i16);
    let v_crr_vcrg = _mm256_set1_epi32(transform._interleaved_crr_crg());
    let v_cr_b = _mm256_set1_epi16(transform.cr_b as i16);
    let j_y_bias = _mm256_set1_epi16(4096);

    let mut cx = 0;
    let mut ux = 0;

    while cx + 32 <= width {
        let src_ptr = src_ptr.get_unchecked(cx * channels..);

        let (r_values, g_values, b_values) =
            _mm256_load_rdp_deinterleave_rgb_for_yuv::<ORIGIN_CHANNELS>(src_ptr.as_ptr());

        let r_lo = _mm256_cvtepu8_epi16(_mm256_castsi256_si128(r_values));
        let g_lo = _mm256_cvtepu8_epi16(_mm256_castsi256_si128(g_values));
        let b_lo = _mm256_cvtepu8_epi16(_mm256_castsi256_si128(b_values));
        let r_hi = _mm256_cvtepu8_epi16(_mm256_extracti128_si256::<1>(r_values));
        let g_hi = _mm256_cvtepu8_epi16(_mm256_extracti128_si256::<1>(g_values));
        let b_hi = _mm256_cvtepu8_epi16(_mm256_extracti128_si256::<1>(b_values));

        let (r_g_lo0, r_g_hi0) = (
            _mm256_unpacklo_epi16(r_lo, g_lo),
            _mm256_unpackhi_epi16(r_lo, g_lo),
        );
        let b_hi0 = _mm256_unpackhi_epi16(b_lo, _mm256_setzero_si256());
        let b_lo0 = _mm256_unpacklo_epi16(b_lo, _mm256_setzero_si256());

        let (r_g_lo1, r_g_hi1) = (
            _mm256_unpacklo_epi16(r_hi, g_hi),
            _mm256_unpackhi_epi16(r_hi, g_hi),
        );
        let b_hi1 = _mm256_unpackhi_epi16(b_hi, _mm256_setzero_si256());
        let b_lo1 = _mm256_unpacklo_epi16(b_hi, _mm256_setzero_si256());

        let v_yr_yg = _mm256_set1_epi32(transform._interleaved_yr_yg());
        let v_yb = _mm256_set1_epi16(transform.yb as i16);

        let (mut y_vl0, mut y_vl1) = _mm256_double_affine_uv_s_dot::<Q>(
            r_g_lo0, r_g_hi0, r_g_lo1, r_g_hi1, b_lo0, b_hi0, b_lo1, b_hi1, v_yr_yg, v_yb,
        );

        y_vl0 = _mm256_sub_epi16(y_vl0, j_y_bias);
        y_vl1 = _mm256_sub_epi16(y_vl1, j_y_bias);

        _mm256_storeu_si256(
            y_plane.get_unchecked_mut(cx..).as_mut_ptr() as *mut __m256i,
            y_vl0,
        );
        _mm256_storeu_si256(
            y_plane.get_unchecked_mut((cx + 16)..).as_mut_ptr() as *mut __m256i,
            y_vl1,
        );

        let cb_vl = _mm256_double_affine_uv_dot::<Q>(
            uv_bias, r_g_lo0, r_g_hi0, r_g_lo1, r_g_hi1, b_lo0, b_hi0, b_lo1, b_hi1, v_cbr_cbg,
            v_cb_b,
        );

        _mm256_storeu_si256(
            u_plane.get_unchecked_mut(ux..).as_mut_ptr() as *mut __m256i,
            cb_vl.0,
        );
        _mm256_storeu_si256(
            u_plane.get_unchecked_mut((ux + 16)..).as_mut_ptr() as *mut __m256i,
            cb_vl.1,
        );

        let cr_vl = _mm256_double_affine_uv_dot::<Q>(
            uv_bias, r_g_lo0, r_g_hi0, r_g_lo1, r_g_hi1, b_lo0, b_hi0, b_lo1, b_hi1, v_crr_vcrg,
            v_cr_b,
        );

        _mm256_storeu_si256(
            v_plane.get_unchecked_mut(ux..).as_mut_ptr() as *mut __m256i,
            cr_vl.0,
        );

        _mm256_storeu_si256(
            v_plane.get_unchecked_mut((ux + 16)..).as_mut_ptr() as *mut __m256i,
            cr_vl.1,
        );

        ux += 32;
        cx += 32;
    }

    if cx < width {
        let diff = width - cx;
        assert!(diff <= 32);
        let mut src_buffer: [u8; 32 * 4] = [0; 32 * 4];
        let mut y_buffer: [i16; 32] = [0; 32];
        let mut u_buffer: [i16; 32] = [0; 32];
        let mut v_buffer: [i16; 32] = [0; 32];

        std::ptr::copy_nonoverlapping(
            rgba.get_unchecked(cx * channels..).as_ptr(),
            src_buffer.as_mut_ptr().cast(),
            diff * channels,
        );

        let (r_values, g_values, b_values) =
            _mm256_load_rdp_deinterleave_rgb_for_yuv::<ORIGIN_CHANNELS>(src_buffer.as_ptr().cast());

        let r_lo = _mm256_cvtepu8_epi16(_mm256_castsi256_si128(r_values));
        let g_lo = _mm256_cvtepu8_epi16(_mm256_castsi256_si128(g_values));
        let b_lo = _mm256_cvtepu8_epi16(_mm256_castsi256_si128(b_values));
        let r_hi = _mm256_cvtepu8_epi16(_mm256_extracti128_si256::<1>(r_values));
        let g_hi = _mm256_cvtepu8_epi16(_mm256_extracti128_si256::<1>(g_values));
        let b_hi = _mm256_cvtepu8_epi16(_mm256_extracti128_si256::<1>(b_values));

        let (r_g_lo0, r_g_hi0) = (
            _mm256_unpacklo_epi16(r_lo, g_lo),
            _mm256_unpackhi_epi16(r_lo, g_lo),
        );
        let b_hi0 = _mm256_unpackhi_epi16(b_lo, _mm256_setzero_si256());
        let b_lo0 = _mm256_unpacklo_epi16(b_lo, _mm256_setzero_si256());

        let (r_g_lo1, r_g_hi1) = (
            _mm256_unpacklo_epi16(r_hi, g_hi),
            _mm256_unpackhi_epi16(r_hi, g_hi),
        );
        let b_hi1 = _mm256_unpackhi_epi16(b_hi, _mm256_setzero_si256());
        let b_lo1 = _mm256_unpacklo_epi16(b_hi, _mm256_setzero_si256());

        let v_yr_yg = _mm256_set1_epi32(transform._interleaved_yr_yg());
        let v_yb = _mm256_set1_epi16(transform.yb as i16);

        let (mut y_vl0, mut y_vl1) = _mm256_double_affine_uv_s_dot::<Q>(
            r_g_lo0, r_g_hi0, r_g_lo1, r_g_hi1, b_lo0, b_hi0, b_lo1, b_hi1, v_yr_yg, v_yb,
        );

        y_vl0 = _mm256_sub_epi16(y_vl0, j_y_bias);
        y_vl1 = _mm256_sub_epi16(y_vl1, j_y_bias);

        _mm256_storeu_si256(y_buffer.as_mut_ptr() as *mut __m256i, y_vl0);
        _mm256_storeu_si256(
            y_buffer.get_unchecked_mut(16..).as_mut_ptr() as *mut __m256i,
            y_vl1,
        );

        let cb_vl = _mm256_double_affine_uv_dot::<Q>(
            uv_bias, r_g_lo0, r_g_hi0, r_g_lo1, r_g_hi1, b_lo0, b_hi0, b_lo1, b_hi1, v_cbr_cbg,
            v_cb_b,
        );

        _mm256_storeu_si256(u_buffer.as_mut_ptr() as *mut __m256i, cb_vl.0);
        _mm256_storeu_si256(
            u_buffer.get_unchecked_mut(16..).as_mut_ptr() as *mut __m256i,
            cb_vl.1,
        );

        let cr_vl = _mm256_double_affine_uv_dot::<Q>(
            uv_bias, r_g_lo0, r_g_hi0, r_g_lo1, r_g_hi1, b_lo0, b_hi0, b_lo1, b_hi1, v_crr_vcrg,
            v_cr_b,
        );

        _mm256_storeu_si256(v_buffer.as_mut_ptr() as *mut __m256i, cr_vl.0);

        _mm256_storeu_si256(
            v_buffer.get_unchecked_mut(16..).as_mut_ptr() as *mut __m256i,
            cr_vl.1,
        );

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

        std::ptr::copy_nonoverlapping(
            y_buffer.as_ptr().cast(),
            y_plane.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );

        cx += diff;
        ux += diff;
    }

    ProcessedOffset { ux, cx }
}

impl CbCrForwardTransform<i32> {
    #[inline]
    fn rdp_avx_make_transform_y(&self, cn: RdpChannels) -> i64 {
        let r = self.yr.to_ne_bytes();
        let g = self.yg.to_ne_bytes();
        let b = self.yb.to_ne_bytes();
        match cn {
            RdpChannels::Rgba => i64::from_ne_bytes([r[0], r[1], g[0], g[1], b[0], b[1], 0, 0]),
            RdpChannels::Bgra => i64::from_ne_bytes([b[0], b[1], g[0], g[1], r[0], r[1], 0, 0]),
            RdpChannels::Abgr => i64::from_ne_bytes([0, 0, b[0], b[1], g[0], g[1], r[0], r[1]]),
            RdpChannels::Argb => i64::from_ne_bytes([0, 0, r[0], r[1], g[0], g[1], b[0], b[1]]),
            _ => unreachable!(),
        }
    }

    #[inline]
    fn rdp_avx_make_transform_cb(&self, cn: RdpChannels) -> i64 {
        let r = self.cb_r.to_ne_bytes();
        let g = self.cb_g.to_ne_bytes();
        let b = self.cb_b.to_ne_bytes();
        match cn {
            RdpChannels::Rgba => i64::from_ne_bytes([r[0], r[1], g[0], g[1], b[0], b[1], 0, 0]),
            RdpChannels::Bgra => i64::from_ne_bytes([b[0], b[1], g[0], g[1], r[0], r[1], 0, 0]),
            RdpChannels::Abgr => i64::from_ne_bytes([0, 0, b[0], b[1], g[0], g[1], r[0], r[1]]),
            RdpChannels::Argb => i64::from_ne_bytes([0, 0, r[0], r[1], g[0], g[1], b[0], b[1]]),
            _ => unreachable!(),
        }
    }

    #[inline]
    fn rdp_avx_make_transform_cr(&self, cn: RdpChannels) -> i64 {
        let r = self.cr_r.to_ne_bytes();
        let g = self.cr_g.to_ne_bytes();
        let b = self.cr_b.to_ne_bytes();
        match cn {
            RdpChannels::Rgba => i64::from_ne_bytes([r[0], r[1], g[0], g[1], b[0], b[1], 0, 0]),
            RdpChannels::Bgra => i64::from_ne_bytes([b[0], b[1], g[0], g[1], r[0], r[1], 0, 0]),
            RdpChannels::Abgr => i64::from_ne_bytes([0, 0, b[0], b[1], g[0], g[1], r[0], r[1]]),
            RdpChannels::Argb => i64::from_ne_bytes([0, 0, r[0], r[1], g[0], g[1], b[0], b[1]]),
            _ => unreachable!(),
        }
    }
}

#[target_feature(enable = "avx2")]
unsafe fn rdp_avx2_4chan_to_yuv_impl<const ORIGIN_CHANNELS: u8, const Q: i32>(
    transform: &CbCrForwardTransform<i32>,
    y_plane: &mut [i16],
    u_plane: &mut [i16],
    v_plane: &mut [i16],
    rgba: &[u8],
    width: usize,
) -> ProcessedOffset {
    let source_channels: RdpChannels = ORIGIN_CHANNELS.into();
    assert!(
        source_channels == RdpChannels::Abgr
            || source_channels == RdpChannels::Argb
            || source_channels == RdpChannels::Bgra
            || source_channels == RdpChannels::Rgba
    );
    let channels = source_channels.channel_count();

    let src_ptr = rgba;
    let y_transform = _mm256_set1_epi64x(transform.rdp_avx_make_transform_y(source_channels));
    let cb_transform = _mm256_set1_epi64x(transform.rdp_avx_make_transform_cb(source_channels));
    let cr_transform = _mm256_set1_epi64x(transform.rdp_avx_make_transform_cr(source_channels));
    let j_y_bias = _mm256_set1_epi32(4096);

    let mut cx = 0;
    let mut ux = 0;

    while cx + 16 <= width {
        let src_ptr = src_ptr.get_unchecked(cx * channels..);

        let row_z0 = _mm256_loadu_si256(src_ptr.as_ptr() as *const _);

        let row0_z0 = _mm256_unpacklo_epi8(row_z0, _mm256_setzero_si256());
        let row1_z0 = _mm256_unpackhi_epi8(row_z0, _mm256_setzero_si256());

        let row_z1 = _mm256_loadu_si256(src_ptr.get_unchecked(32..).as_ptr() as *const _);

        let y_row0 = _mm256_madd_epi16(row0_z0, y_transform);
        let y_row1 = _mm256_madd_epi16(row1_z0, y_transform);
        let cb_row0 = _mm256_madd_epi16(row0_z0, cb_transform);
        let cb_row1 = _mm256_madd_epi16(row1_z0, cb_transform);
        let cr_row0 = _mm256_madd_epi16(row0_z0, cr_transform);
        let cr_row1 = _mm256_madd_epi16(row1_z0, cr_transform);

        const M: i32 = shuffle(3, 1, 2, 0);

        let mut f_y0 = _mm256_hadd_epi32(y_row0, y_row1);
        let mut f_cb0 = _mm256_hadd_epi32(cb_row0, cb_row1);
        let mut f_cr0 = _mm256_hadd_epi32(cr_row0, cr_row1);

        let row0_z1 = _mm256_unpacklo_epi8(row_z1, _mm256_setzero_si256());
        let row1_z1 = _mm256_unpackhi_epi8(row_z1, _mm256_setzero_si256());

        let y1_row0 = _mm256_madd_epi16(row0_z1, y_transform);
        let y1_row1 = _mm256_madd_epi16(row1_z1, y_transform);
        let cb1_row0 = _mm256_madd_epi16(row0_z1, cb_transform);
        let cb1_row1 = _mm256_madd_epi16(row1_z1, cb_transform);
        let cr1_row0 = _mm256_madd_epi16(row0_z1, cr_transform);
        let cr1_row1 = _mm256_madd_epi16(row1_z1, cr_transform);

        f_y0 = _mm256_srai_epi32::<Q>(f_y0);
        f_cb0 = _mm256_srai_epi32::<Q>(f_cb0);
        f_cr0 = _mm256_srai_epi32::<Q>(f_cr0);

        let mut f_y1 = _mm256_hadd_epi32(y1_row0, y1_row1);
        let mut f_cb1 = _mm256_hadd_epi32(cb1_row0, cb1_row1);
        let mut f_cr1 = _mm256_hadd_epi32(cr1_row0, cr1_row1);

        f_y1 = _mm256_srai_epi32::<Q>(f_y1);
        f_cb1 = _mm256_srai_epi32::<Q>(f_cb1);
        f_cr1 = _mm256_srai_epi32::<Q>(f_cr1);

        f_y0 = _mm256_sub_epi32(f_y0, j_y_bias);
        f_y1 = _mm256_sub_epi32(f_y1, j_y_bias);

        let z_y = _mm256_permute4x64_epi64::<M>(_mm256_packs_epi32(f_y0, f_y1));
        let z_cb = _mm256_permute4x64_epi64::<M>(_mm256_packs_epi32(f_cb0, f_cb1));
        let z_cr = _mm256_permute4x64_epi64::<M>(_mm256_packs_epi32(f_cr0, f_cr1));

        _mm256_storeu_si256(u_plane.get_unchecked_mut(ux..).as_mut_ptr() as *mut _, z_cb);
        _mm256_storeu_si256(v_plane.get_unchecked_mut(ux..).as_mut_ptr() as *mut _, z_cr);
        _mm256_storeu_si256(y_plane.get_unchecked_mut(ux..).as_mut_ptr() as *mut _, z_y);

        ux += 16;
        cx += 16;
    }

    while cx + 8 <= width {
        let src_ptr = src_ptr.get_unchecked(cx * channels..);

        let row = _mm256_loadu_si256(src_ptr.as_ptr() as *const _);

        let row0 = _mm256_unpacklo_epi8(row, _mm256_setzero_si256());
        let row1 = _mm256_unpackhi_epi8(row, _mm256_setzero_si256());

        let y_row0 = _mm256_madd_epi16(row0, y_transform);
        let y_row1 = _mm256_madd_epi16(row1, y_transform);
        let cb_row0 = _mm256_madd_epi16(row0, cb_transform);
        let cb_row1 = _mm256_madd_epi16(row1, cb_transform);
        let cr_row0 = _mm256_madd_epi16(row0, cr_transform);
        let cr_row1 = _mm256_madd_epi16(row1, cr_transform);

        const M: i32 = shuffle(3, 1, 2, 0);

        let mut f_y = _mm256_hadd_epi32(y_row0, y_row1);
        let mut f_cb = _mm256_hadd_epi32(cb_row0, cb_row1);
        let mut f_cr = _mm256_hadd_epi32(cr_row0, cr_row1);

        f_y = _mm256_srai_epi32::<Q>(f_y);
        f_cb = _mm256_srai_epi32::<Q>(f_cb);
        f_cr = _mm256_srai_epi32::<Q>(f_cr);

        f_y = _mm256_sub_epi32(f_y, j_y_bias);

        let z_y = _mm256_permute4x64_epi64::<M>(_mm256_packs_epi32(f_y, _mm256_setzero_si256()));
        let z_cb = _mm256_permute4x64_epi64::<M>(_mm256_packs_epi32(f_cb, _mm256_setzero_si256()));
        let z_cr = _mm256_permute4x64_epi64::<M>(_mm256_packs_epi32(f_cr, _mm256_setzero_si256()));

        _mm_storeu_si128(
            u_plane.get_unchecked_mut(ux..).as_mut_ptr() as *mut _,
            _mm256_castsi256_si128(z_cb),
        );
        _mm_storeu_si128(
            v_plane.get_unchecked_mut(ux..).as_mut_ptr() as *mut _,
            _mm256_castsi256_si128(z_cr),
        );
        _mm_storeu_si128(
            y_plane.get_unchecked_mut(ux..).as_mut_ptr() as *mut _,
            _mm256_castsi256_si128(z_y),
        );

        ux += 8;
        cx += 8;
    }

    if cx < width {
        let diff = width - cx;
        assert!(diff <= 8);
        let mut src_buffer: [u8; 32] = [0; 32];
        let mut y_buffer: [i16; 8] = [0; 8];
        let mut u_buffer: [i16; 8] = [0; 8];
        let mut v_buffer: [i16; 8] = [0; 8];

        std::ptr::copy_nonoverlapping(
            rgba.get_unchecked(cx * channels..).as_ptr(),
            src_buffer.as_mut_ptr().cast(),
            diff * channels,
        );

        let row = _mm256_loadu_si256(src_buffer.as_ptr() as *const _);

        let row0 = _mm256_unpacklo_epi8(row, _mm256_setzero_si256());
        let row1 = _mm256_unpackhi_epi8(row, _mm256_setzero_si256());

        let y_row0 = _mm256_madd_epi16(row0, y_transform);
        let y_row1 = _mm256_madd_epi16(row1, y_transform);
        let cb_row0 = _mm256_madd_epi16(row0, cb_transform);
        let cb_row1 = _mm256_madd_epi16(row1, cb_transform);
        let cr_row0 = _mm256_madd_epi16(row0, cr_transform);
        let cr_row1 = _mm256_madd_epi16(row1, cr_transform);

        const M: i32 = shuffle(3, 1, 2, 0);

        let mut f_y = _mm256_hadd_epi32(y_row0, y_row1);
        let mut f_cb = _mm256_hadd_epi32(cb_row0, cb_row1);
        let mut f_cr = _mm256_hadd_epi32(cr_row0, cr_row1);

        f_y = _mm256_srai_epi32::<Q>(f_y);
        f_cb = _mm256_srai_epi32::<Q>(f_cb);
        f_cr = _mm256_srai_epi32::<Q>(f_cr);

        f_y = _mm256_sub_epi32(f_y, j_y_bias);

        let z_y = _mm256_permute4x64_epi64::<M>(_mm256_packs_epi32(f_y, _mm256_setzero_si256()));
        let z_cb = _mm256_permute4x64_epi64::<M>(_mm256_packs_epi32(f_cb, _mm256_setzero_si256()));
        let z_cr = _mm256_permute4x64_epi64::<M>(_mm256_packs_epi32(f_cr, _mm256_setzero_si256()));

        _mm_storeu_si128(
            u_buffer.as_mut_ptr() as *mut _,
            _mm256_castsi256_si128(z_cb),
        );
        _mm_storeu_si128(
            v_buffer.as_mut_ptr() as *mut _,
            _mm256_castsi256_si128(z_cr),
        );
        _mm_storeu_si128(y_buffer.as_mut_ptr() as *mut _, _mm256_castsi256_si128(z_y));

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

        std::ptr::copy_nonoverlapping(
            y_buffer.as_ptr().cast(),
            y_plane.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );

        cx += diff;
        ux += diff;
    }

    ProcessedOffset { ux, cx }
}
