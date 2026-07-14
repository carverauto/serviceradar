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
use crate::neon::utils::{neon_store_half_rgb8, neon_store_rgb8, neon_vld_h_rgb, neon_vld_rgb};
use crate::shuffle::ShuffleConverter;
use crate::yuv_support::YuvSourceChannels;

/// This is default shuffling with interleaving and de-interleaving.
///
pub(crate) struct ShuffleConverterNeon<const SRC: u8, const DST: u8> {}

impl<const SRC: u8, const DST: u8> Default for ShuffleConverterNeon<SRC, DST> {
    fn default() -> Self {
        ShuffleConverterNeon {}
    }
}

impl<const SRC: u8, const DST: u8> ShuffleConverter<u8, SRC, DST>
    for ShuffleConverterNeon<SRC, DST>
{
    fn convert(&self, src: &[u8], dst: &mut [u8], width: usize) {
        unsafe { shuffle_channels8_impl::<SRC, DST>(src, dst, width) }
    }
}

#[inline(always)]
unsafe fn shuffle_channels8_impl<const SRC: u8, const DST: u8>(
    src: &[u8],
    dst: &mut [u8],
    _: usize,
) {
    let src_channels: YuvSourceChannels = SRC.into();
    let dst_channels: YuvSourceChannels = DST.into();
    for (src, dst) in src
        .chunks_exact(16 * src_channels.get_channels_count())
        .zip(dst.chunks_exact_mut(16 * dst_channels.get_channels_count()))
    {
        let (a0, b0, c0, d0) = neon_vld_rgb::<SRC>(src.as_ptr());
        neon_store_rgb8::<DST>(dst.as_mut_ptr(), a0, b0, c0, d0);
    }

    let src = src
        .chunks_exact(16 * src_channels.get_channels_count())
        .remainder();
    let dst = dst
        .chunks_exact_mut(16 * dst_channels.get_channels_count())
        .into_remainder();

    for (src, dst) in src
        .chunks_exact(8 * src_channels.get_channels_count())
        .zip(dst.chunks_exact_mut(8 * dst_channels.get_channels_count()))
    {
        let (a0, b0, c0, d0) = neon_vld_h_rgb::<SRC>(src.as_ptr());
        neon_store_half_rgb8::<DST>(dst.as_mut_ptr(), a0, b0, c0, d0);
    }

    let src = src
        .chunks_exact(8 * src_channels.get_channels_count())
        .remainder();
    let dst = dst
        .chunks_exact_mut(8 * dst_channels.get_channels_count())
        .into_remainder();

    if !src.is_empty() && !dst.is_empty() {
        assert!(src.len() < 64);
        assert!(dst.len() < 64);
        let mut transient_src: [u8; 64] = [0; 64];
        let mut transient_dst: [u8; 64] = [0; 64];
        std::ptr::copy_nonoverlapping(src.as_ptr(), transient_src.as_mut_ptr(), src.len());
        let (a0, b0, c0, d0) = neon_vld_h_rgb::<SRC>(transient_src.as_ptr());
        neon_store_half_rgb8::<DST>(transient_dst.as_mut_ptr(), a0, b0, c0, d0);
        std::ptr::copy_nonoverlapping(transient_dst.as_ptr(), dst.as_mut_ptr(), dst.len());
    }
}
