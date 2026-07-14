/*
 * Copyright (c) Radzivon Bartoshyk, 12/2024. All rights reserved.
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
use crate::avx2::avx2_utils::{_mm256_load_deinterleave_rgb, _mm256_store_interleave_rgb_for_yuv};
use crate::shuffle::ShuffleConverter;
use crate::yuv_support::YuvSourceChannels;
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

/// This is default shuffling with interleaving and de-interleaving.
///
/// For the same channels count there is more fast approach on x86 with reshuffling table
pub(crate) struct ShuffleConverterAvx2<const SRC: u8, const DST: u8> {}

impl<const SRC: u8, const DST: u8> Default for ShuffleConverterAvx2<SRC, DST> {
    fn default() -> Self {
        ShuffleConverterAvx2 {}
    }
}

impl<const SRC: u8, const DST: u8> ShuffleConverter<u8, SRC, DST>
    for ShuffleConverterAvx2<SRC, DST>
{
    fn convert(&self, src: &[u8], dst: &mut [u8], width: usize) {
        unsafe { shuffle_channels8_avx_impl::<SRC, DST>(src, dst, width) }
    }
}

#[target_feature(enable = "avx2")]
unsafe fn shuffle_channels8_avx_impl<const SRC: u8, const DST: u8>(
    src: &[u8],
    dst: &mut [u8],
    _: usize,
) {
    let src_channels: YuvSourceChannels = SRC.into();
    let dst_channels: YuvSourceChannels = DST.into();

    for (src, dst) in src
        .chunks_exact(32 * src_channels.get_channels_count())
        .zip(dst.chunks_exact_mut(32 * dst_channels.get_channels_count()))
    {
        let (a0, b0, c0, d0) = _mm256_load_deinterleave_rgb::<SRC>(src.as_ptr());
        _mm256_store_interleave_rgb_for_yuv::<DST>(dst.as_mut_ptr(), a0, b0, c0, d0);
    }

    let src = src
        .chunks_exact(32 * src_channels.get_channels_count())
        .remainder();
    let dst = dst
        .chunks_exact_mut(32 * dst_channels.get_channels_count())
        .into_remainder();

    if !src.is_empty() && !dst.is_empty() {
        assert!(src.len() < 32 * 4);
        assert!(dst.len() < 32 * 4);
        let mut transient_src: [u8; 32 * 4] = [0; 32 * 4];
        let mut transient_dst: [u8; 32 * 4] = [0; 32 * 4];
        std::ptr::copy_nonoverlapping(src.as_ptr(), transient_src.as_mut_ptr(), src.len());
        let (a0, b0, c0, d0) = _mm256_load_deinterleave_rgb::<SRC>(transient_src.as_ptr());
        _mm256_store_interleave_rgb_for_yuv::<DST>(transient_dst.as_mut_ptr(), a0, b0, c0, d0);
        std::ptr::copy_nonoverlapping(transient_dst.as_ptr(), dst.as_mut_ptr(), dst.len());
    }
}

/// This is shuffling only for 4 channels image
///
/// This is more fast method that just swaps channel positions
pub(crate) struct ShuffleQTableConverterAvx2<const SRC: u8, const DST: u8> {
    q_table_avx: [u8; 32],
}

const RGBA_TO_BGRA_TABLE_AVX2: [u8; 32] = [
    2,
    1,
    0,
    3,
    2 + 4,
    1 + 4,
    4,
    3 + 4,
    2 + 8,
    1 + 8,
    8,
    3 + 8,
    2 + 12,
    1 + 12,
    12,
    3 + 12,
    2,
    1,
    0,
    3,
    2 + 4,
    1 + 4,
    4,
    3 + 4,
    2 + 8,
    1 + 8,
    8,
    3 + 8,
    2 + 12,
    1 + 12,
    12,
    3 + 12,
];

impl<const SRC: u8, const DST: u8> ShuffleQTableConverterAvx2<SRC, DST> {
    pub(crate) fn create() -> Self {
        let src_channels: YuvSourceChannels = SRC.into();
        let dst_channels: YuvSourceChannels = DST.into();
        if src_channels.get_channels_count() != 4 || dst_channels.get_channels_count() != 4 {
            unimplemented!("Shuffle table implemented only for 4 channels");
        }
        let new_table_avx: [u8; 32] = match src_channels {
            YuvSourceChannels::Rgb => unreachable!(),
            YuvSourceChannels::Rgba => match dst_channels {
                YuvSourceChannels::Rgb => unreachable!(),
                YuvSourceChannels::Rgba => RGBA_TO_BGRA_TABLE_AVX2,
                YuvSourceChannels::Bgra => RGBA_TO_BGRA_TABLE_AVX2,
                YuvSourceChannels::Bgr => unreachable!(),
            },
            YuvSourceChannels::Bgra => match dst_channels {
                YuvSourceChannels::Rgb => unreachable!(),
                YuvSourceChannels::Rgba => RGBA_TO_BGRA_TABLE_AVX2,
                YuvSourceChannels::Bgra => RGBA_TO_BGRA_TABLE_AVX2,
                YuvSourceChannels::Bgr => unreachable!(),
            },
            YuvSourceChannels::Bgr => unreachable!(),
        };
        ShuffleQTableConverterAvx2 {
            q_table_avx: new_table_avx,
        }
    }
}

impl<const SRC: u8, const DST: u8> ShuffleConverter<u8, SRC, DST>
    for ShuffleQTableConverterAvx2<SRC, DST>
{
    fn convert(&self, src: &[u8], dst: &mut [u8], width: usize) {
        unsafe { shuffle_qtable_channels8_avx_impl::<SRC, DST>(src, dst, width, self.q_table_avx) }
    }
}

#[target_feature(enable = "avx2")]
unsafe fn shuffle_qtable_channels8_avx_impl<const SRC: u8, const DST: u8>(
    src: &[u8],
    dst: &mut [u8],
    _: usize,
    vq_table_avx: [u8; 32],
) {
    let src_channels: YuvSourceChannels = SRC.into();
    let dst_channels: YuvSourceChannels = DST.into();
    assert_eq!(src_channels.get_channels_count(), 4);
    assert_eq!(dst_channels.get_channels_count(), 4);

    let q_table_avx = _mm256_loadu_si256(vq_table_avx.as_ptr() as *const _);

    for (src, dst) in src.chunks_exact(32 * 4).zip(dst.chunks_exact_mut(32 * 4)) {
        let mut row_1 = _mm256_loadu_si256(src.as_ptr() as *const __m256i);
        let mut row_2 = _mm256_loadu_si256(src.as_ptr().add(32) as *const __m256i);
        let mut row_3 = _mm256_loadu_si256(src.as_ptr().add(64) as *const __m256i);
        let mut row_4 = _mm256_loadu_si256(src.as_ptr().add(96) as *const __m256i);

        row_1 = _mm256_shuffle_epi8(row_1, q_table_avx);
        row_2 = _mm256_shuffle_epi8(row_2, q_table_avx);
        row_3 = _mm256_shuffle_epi8(row_3, q_table_avx);
        row_4 = _mm256_shuffle_epi8(row_4, q_table_avx);

        _mm256_storeu_si256(dst.as_mut_ptr() as *mut __m256i, row_1);
        _mm256_storeu_si256(dst.as_mut_ptr().add(32) as *mut __m256i, row_2);
        _mm256_storeu_si256(dst.as_mut_ptr().add(64) as *mut __m256i, row_3);
        _mm256_storeu_si256(dst.as_mut_ptr().add(96) as *mut __m256i, row_4);
    }

    let src = src.chunks_exact(32 * 4).remainder();
    let dst = dst.chunks_exact_mut(32 * 4).into_remainder();

    for (src, dst) in src.chunks_exact(32).zip(dst.chunks_exact_mut(32)) {
        let mut row_1 = _mm256_loadu_si256(src.as_ptr() as *const __m256i);

        row_1 = _mm256_shuffle_epi8(row_1, q_table_avx);

        _mm256_storeu_si256(dst.as_mut_ptr() as *mut __m256i, row_1);
    }

    let src = src.chunks_exact(32).remainder();
    let dst = dst.chunks_exact_mut(32).into_remainder();

    if !src.is_empty() && !dst.is_empty() {
        assert!(src.len() < 32);
        assert!(dst.len() < 32);
        let mut transient_src: [u8; 32] = [0; 32];
        let mut transient_dst: [u8; 32] = [0; 32];
        std::ptr::copy_nonoverlapping(src.as_ptr(), transient_src.as_mut_ptr(), src.len());
        let mut row_1 = _mm256_loadu_si256(transient_src.as_ptr() as *const __m256i);
        row_1 = _mm256_shuffle_epi8(row_1, q_table_avx);
        _mm256_storeu_si256(transient_dst.as_mut_ptr() as *mut _, row_1);
        std::ptr::copy_nonoverlapping(transient_dst.as_ptr(), dst.as_mut_ptr(), dst.len());
    }
}
