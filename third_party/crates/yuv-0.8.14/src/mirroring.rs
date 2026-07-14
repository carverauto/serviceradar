/*
 * Copyright (c) Radzivon Bartoshyk, 1/2025. All rights reserved.
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
use crate::geometry::map_ft_result;
use crate::YuvError;
use fast_transpose::{
    flip_plane, flip_plane16, flip_plane16_with_alpha, flip_plane_with_alpha, flip_rgb, flip_rgb16,
    flip_rgba, flip_rgba16, flop_plane, flop_plane16, flop_plane16_with_alpha,
    flop_plane_with_alpha, flop_rgb, flop_rgb16, flop_rgba, flop_rgba16,
};

/// Declares mirroring mode: vertical or horizontal
#[derive(Copy, Clone, Debug, Ord, PartialOrd, Eq, PartialEq, Hash)]
pub enum MirrorMode {
    Vertical,
    Horizontal,
}

/// Mirrors RGBA 8 bit image.
///
/// This mirrors any 4 channels image, channel order does not matter.
///
/// # Arguments
///
/// * `src`: Source image
/// * `src_stride`: Source image stride
/// * `dst`: Destination image
/// * `dst_stride`: Destination image stride
/// * `width`: Image width
/// * `height`: Image Height
/// * `mode`: Refer to [MirrorMode] for mode info
///
/// returns: Result<(), [YuvError]>
///
pub fn mirror_rgba(
    src: &[u8],
    src_stride: usize,
    dst: &mut [u8],
    dst_stride: usize,
    width: usize,
    height: usize,
    mode: MirrorMode,
) -> Result<(), YuvError> {
    let rs = match mode {
        MirrorMode::Vertical => flop_rgba(src, src_stride, dst, dst_stride, width, height),
        MirrorMode::Horizontal => flip_rgba(src, src_stride, dst, dst_stride, width, height),
    };
    map_ft_result(rs)
}

/// Mirrors RGB 8 bit image.
///
/// This mirrors any 3 channels image, channel order does not matter.
///
/// # Arguments
///
/// * `src`: Source image
/// * `src_stride`: Source image stride
/// * `dst`: Destination image
/// * `dst_stride`: Destination image stride
/// * `width`: Image width
/// * `height`: Image Height
/// * `mode`: Refer to [MirrorMode] for mode info
///
/// returns: Result<(), [YuvError]>
///
pub fn mirror_rgb(
    src: &[u8],
    src_stride: usize,
    dst: &mut [u8],
    dst_stride: usize,
    width: usize,
    height: usize,
    mode: MirrorMode,
) -> Result<(), YuvError> {
    let rs = match mode {
        MirrorMode::Vertical => flop_rgb(src, src_stride, dst, dst_stride, width, height),
        MirrorMode::Horizontal => flip_rgb(src, src_stride, dst, dst_stride, width, height),
    };
    map_ft_result(rs)
}

/// Mirrors CbCr 8 bit image.
///
/// This mirrors any 2 channels image, channel order does not matter.
///
/// # Arguments
///
/// * `src`: Source image
/// * `src_stride`: Source image stride
/// * `dst`: Destination image
/// * `dst_stride`: Destination image stride
/// * `width`: Image width
/// * `height`: Image Height
/// * `mode`: Refer to [MirrorMode] for mode info
///
/// returns: Result<(), [YuvError]>
///
pub fn mirror_cbcr(
    src: &[u8],
    src_stride: usize,
    dst: &mut [u8],
    dst_stride: usize,
    width: usize,
    height: usize,
    mode: MirrorMode,
) -> Result<(), YuvError> {
    let rs = match mode {
        MirrorMode::Vertical => {
            flop_plane_with_alpha(src, src_stride, dst, dst_stride, width, height)
        }
        MirrorMode::Horizontal => {
            flip_plane_with_alpha(src, src_stride, dst, dst_stride, width, height)
        }
    };
    map_ft_result(rs)
}

/// Mirrors Plane 8 bit image.
///
/// This mirrors any planar channels image.
///
/// # Arguments
///
/// * `src`: Source image
/// * `src_stride`: Source image stride
/// * `dst`: Destination image
/// * `dst_stride`: Destination image stride
/// * `width`: Image width
/// * `height`: Image Height
/// * `mode`: Refer to [MirrorMode] for mode info
///
/// returns: Result<(), [YuvError]>
///
pub fn mirror_plane(
    src: &[u8],
    src_stride: usize,
    dst: &mut [u8],
    dst_stride: usize,
    width: usize,
    height: usize,
    mode: MirrorMode,
) -> Result<(), YuvError> {
    let rs = match mode {
        MirrorMode::Vertical => flop_plane(src, src_stride, dst, dst_stride, width, height),
        MirrorMode::Horizontal => flip_plane(src, src_stride, dst, dst_stride, width, height),
    };
    map_ft_result(rs)
}

/// Mirrors RGBA 8+ bit image.
///
/// This mirrors any 4 channels image, channel order does not matter.
///
/// # Arguments
///
/// * `src`: Source image
/// * `src_stride`: Source image stride
/// * `dst`: Destination image
/// * `dst_stride`: Destination image stride
/// * `width`: Image width
/// * `height`: Image Height
/// * `mode`: Refer to [MirrorMode] for mode info
///
/// returns: Result<(), [YuvError]>
///
pub fn mirror_rgba16(
    src: &[u16],
    src_stride: usize,
    dst: &mut [u16],
    dst_stride: usize,
    width: usize,
    height: usize,
    mode: MirrorMode,
) -> Result<(), YuvError> {
    let rs = match mode {
        MirrorMode::Vertical => flop_rgba16(src, src_stride, dst, dst_stride, width, height),
        MirrorMode::Horizontal => flip_rgba16(src, src_stride, dst, dst_stride, width, height),
    };
    map_ft_result(rs)
}

/// Mirrors RGB 8+ bit image.
///
/// This mirrors any 3 channels image, channel order does not matter.
///
/// # Arguments
///
/// * `src`: Source image
/// * `src_stride`: Source image stride
/// * `dst`: Destination image
/// * `dst_stride`: Destination image stride
/// * `width`: Image width
/// * `height`: Image Height
/// * `mode`: Refer to [MirrorMode] for mode info
///
/// returns: Result<(), [YuvError]>
///
pub fn mirror_rgb16(
    src: &[u16],
    src_stride: usize,
    dst: &mut [u16],
    dst_stride: usize,
    width: usize,
    height: usize,
    mode: MirrorMode,
) -> Result<(), YuvError> {
    let rs = match mode {
        MirrorMode::Vertical => flop_rgb16(src, src_stride, dst, dst_stride, width, height),
        MirrorMode::Horizontal => flip_rgb16(src, src_stride, dst, dst_stride, width, height),
    };
    map_ft_result(rs)
}

/// Mirrors CbCr 8+ bit image.
///
/// This mirrors any 2 channels image, channel order does not matter.
///
/// # Arguments
///
/// * `src`: Source image
/// * `src_stride`: Source image stride
/// * `dst`: Destination image
/// * `dst_stride`: Destination image stride
/// * `width`: Image width
/// * `height`: Image Height
/// * `mode`: Refer to [MirrorMode] for mode info
///
/// returns: Result<(), [YuvError]>
///
pub fn mirror_cbcr16(
    src: &[u16],
    src_stride: usize,
    dst: &mut [u16],
    dst_stride: usize,
    width: usize,
    height: usize,
    mode: MirrorMode,
) -> Result<(), YuvError> {
    let rs = match mode {
        MirrorMode::Vertical => {
            flop_plane16_with_alpha(src, src_stride, dst, dst_stride, width, height)
        }
        MirrorMode::Horizontal => {
            flip_plane16_with_alpha(src, src_stride, dst, dst_stride, width, height)
        }
    };
    map_ft_result(rs)
}

/// Mirrors Plane 8+ bit image.
///
/// This mirrors any planar channels image.
///
/// # Arguments
///
/// * `src`: Source image
/// * `src_stride`: Source image stride
/// * `dst`: Destination image
/// * `dst_stride`: Destination image stride
/// * `width`: Image width
/// * `height`: Image Height
/// * `mode`: Refer to [MirrorMode] for mode info
///
/// returns: Result<(), [YuvError]>
///
pub fn mirror_plane16(
    src: &[u16],
    src_stride: usize,
    dst: &mut [u16],
    dst_stride: usize,
    width: usize,
    height: usize,
    mode: MirrorMode,
) -> Result<(), YuvError> {
    let rs = match mode {
        MirrorMode::Vertical => flop_plane16(src, src_stride, dst, dst_stride, width, height),
        MirrorMode::Horizontal => flip_plane16(src, src_stride, dst, dst_stride, width, height),
    };
    map_ft_result(rs)
}
