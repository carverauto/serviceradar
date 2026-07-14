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
use crate::YuvError;
use fast_transpose::{
    rotate180_plane, rotate180_plane16, rotate180_plane16_with_alpha, rotate180_plane_with_alpha,
    rotate180_rgb, rotate180_rgb16, rotate180_rgba, rotate180_rgba16, transpose_plane,
    transpose_plane16, transpose_plane16_with_alpha, transpose_plane_with_alpha, transpose_rgb,
    transpose_rgb16, transpose_rgba, transpose_rgba16, FlipMode, FlopMode, TransposeError,
};

/// Declares rotation mode, 90, 180, 270
#[derive(Copy, Clone, Debug, Ord, PartialOrd, Eq, PartialEq, Hash)]
pub enum RotationMode {
    Rotate90,
    Rotate180,
    Rotate270,
}

#[inline]
pub(crate) fn map_ft_result(result: Result<(), TransposeError>) -> Result<(), YuvError> {
    match result {
        Ok(_) => Ok(()),
        Err(err) => match err {
            TransposeError::MismatchDimensions => Err(YuvError::ImageDimensionsNotMatch),
            TransposeError::InvalidArraySize => Err(YuvError::ImagesSizesNotMatch),
        },
    }
}

/// Rotates RGBA 8 bit image.
///
/// This rotates any 4 channels image, channel order does not matter.
///
/// # Arguments
///
/// * `src`: Source image
/// * `src_stride`: Source image stride
/// * `dst`: Destination image
/// * `dst_stride`: Destination image stride
/// * `width`: Image width
/// * `height`: Image Height
/// * `mode`: Refer to [RotationMode] for mode info
///
/// returns: Result<(), [YuvError]>
///
pub fn rotate_rgba(
    src: &[u8],
    src_stride: usize,
    dst: &mut [u8],
    dst_stride: usize,
    width: usize,
    height: usize,
    mode: RotationMode,
) -> Result<(), YuvError> {
    let rs = match mode {
        RotationMode::Rotate90 => transpose_rgba(
            src,
            src_stride,
            dst,
            dst_stride,
            width,
            height,
            FlipMode::NoFlip,
            FlopMode::NoFlop,
        ),
        RotationMode::Rotate180 => rotate180_rgba(src, src_stride, dst, dst_stride, width, height),
        RotationMode::Rotate270 => transpose_rgba(
            src,
            src_stride,
            dst,
            dst_stride,
            width,
            height,
            FlipMode::Flip,
            FlopMode::Flop,
        ),
    };
    map_ft_result(rs)
}

/// Rotates RGB 8 bit image.
///
/// This rotates any 3 channels image, channel order does not matter.
///
/// # Arguments
///
/// * `src`: Source image
/// * `src_stride`: Source image stride
/// * `dst`: Destination image
/// * `dst_stride`: Destination image stride
/// * `width`: Image width
/// * `height`: Image Height
/// * `mode`: Refer to [RotationMode] for mode info
///
/// returns: Result<(), [YuvError]>
///
pub fn rotate_rgb(
    src: &[u8],
    src_stride: usize,
    dst: &mut [u8],
    dst_stride: usize,
    width: usize,
    height: usize,
    mode: RotationMode,
) -> Result<(), YuvError> {
    let rs = match mode {
        RotationMode::Rotate90 => transpose_rgb(
            src,
            src_stride,
            dst,
            dst_stride,
            width,
            height,
            FlipMode::NoFlip,
            FlopMode::NoFlop,
        ),
        RotationMode::Rotate180 => rotate180_rgb(src, src_stride, dst, dst_stride, width, height),
        RotationMode::Rotate270 => transpose_rgb(
            src,
            src_stride,
            dst,
            dst_stride,
            width,
            height,
            FlipMode::Flip,
            FlopMode::Flop,
        ),
    };
    map_ft_result(rs)
}

/// Rotates CbCr 8 bit image.
///
/// This rotates any 2 channels image, channel order does not matter.
///
/// # Arguments
///
/// * `src`: Source image
/// * `src_stride`: Source image stride
/// * `dst`: Destination image
/// * `dst_stride`: Destination image stride
/// * `width`: Image width
/// * `height`: Image Height
/// * `mode`: Refer to [RotationMode] for mode info
///
/// returns: Result<(), [YuvError]>
///
pub fn rotate_cbcr(
    src: &[u8],
    src_stride: usize,
    dst: &mut [u8],
    dst_stride: usize,
    width: usize,
    height: usize,
    mode: RotationMode,
) -> Result<(), YuvError> {
    let rs = match mode {
        RotationMode::Rotate90 => transpose_plane_with_alpha(
            src,
            src_stride,
            dst,
            dst_stride,
            width,
            height,
            FlipMode::NoFlip,
            FlopMode::NoFlop,
        ),
        RotationMode::Rotate180 => {
            rotate180_plane_with_alpha(src, src_stride, dst, dst_stride, width, height)
        }
        RotationMode::Rotate270 => transpose_plane_with_alpha(
            src,
            src_stride,
            dst,
            dst_stride,
            width,
            height,
            FlipMode::Flip,
            FlopMode::Flop,
        ),
    };
    map_ft_result(rs)
}

/// Rotates Planar 8 bit image.
///
/// This rotates planar image.
///
/// # Arguments
///
/// * `src`: Source image
/// * `src_stride`: Source image stride
/// * `dst`: Destination image
/// * `dst_stride`: Destination image stride
/// * `width`: Image width
/// * `height`: Image Height
/// * `mode`: Refer to [RotationMode] for mode info
///
/// returns: Result<(), [YuvError]>
///
pub fn rotate_plane(
    src: &[u8],
    src_stride: usize,
    dst: &mut [u8],
    dst_stride: usize,
    width: usize,
    height: usize,
    mode: RotationMode,
) -> Result<(), YuvError> {
    let rs = match mode {
        RotationMode::Rotate90 => transpose_plane(
            src,
            src_stride,
            dst,
            dst_stride,
            width,
            height,
            FlipMode::NoFlip,
            FlopMode::NoFlop,
        ),
        RotationMode::Rotate180 => rotate180_plane(src, src_stride, dst, dst_stride, width, height),
        RotationMode::Rotate270 => transpose_plane(
            src,
            src_stride,
            dst,
            dst_stride,
            width,
            height,
            FlipMode::Flip,
            FlopMode::Flop,
        ),
    };
    map_ft_result(rs)
}

/// Rotates RGBA 8+ bit image.
///
/// This rotates any 4 channels image, channel order does not matter.
///
/// # Arguments
///
/// * `src`: Source image
/// * `src_stride`: Source image stride
/// * `dst`: Destination image
/// * `dst_stride`: Destination image stride
/// * `width`: Image width
/// * `height`: Image Height
/// * `mode`: Refer to [RotationMode] for mode info
///
/// returns: Result<(), [YuvError]>
///
pub fn rotate_rgba16(
    src: &[u16],
    src_stride: usize,
    dst: &mut [u16],
    dst_stride: usize,
    width: usize,
    height: usize,
    mode: RotationMode,
) -> Result<(), YuvError> {
    let rs = match mode {
        RotationMode::Rotate90 => transpose_rgba16(
            src,
            src_stride,
            dst,
            dst_stride,
            width,
            height,
            FlipMode::NoFlip,
            FlopMode::NoFlop,
        ),
        RotationMode::Rotate180 => {
            rotate180_rgba16(src, src_stride, dst, dst_stride, width, height)
        }
        RotationMode::Rotate270 => transpose_rgba16(
            src,
            src_stride,
            dst,
            dst_stride,
            width,
            height,
            FlipMode::Flip,
            FlopMode::Flop,
        ),
    };
    map_ft_result(rs)
}

/// Rotates RGB 8+ bit image.
///
/// This rotates any 3 channels image, channel order does not matter.
///
/// # Arguments
///
/// * `src`: Source image
/// * `src_stride`: Source image stride
/// * `dst`: Destination image
/// * `dst_stride`: Destination image stride
/// * `width`: Image width
/// * `height`: Image Height
/// * `mode`: Refer to [RotationMode] for mode info
///
/// returns: Result<(), [YuvError]>
///
pub fn rotate_rgb16(
    src: &[u16],
    src_stride: usize,
    dst: &mut [u16],
    dst_stride: usize,
    width: usize,
    height: usize,
    mode: RotationMode,
) -> Result<(), YuvError> {
    let rs = match mode {
        RotationMode::Rotate90 => transpose_rgb16(
            src,
            src_stride,
            dst,
            dst_stride,
            width,
            height,
            FlipMode::NoFlip,
            FlopMode::NoFlop,
        ),
        RotationMode::Rotate180 => rotate180_rgb16(src, src_stride, dst, dst_stride, width, height),
        RotationMode::Rotate270 => transpose_rgb16(
            src,
            src_stride,
            dst,
            dst_stride,
            width,
            height,
            FlipMode::Flip,
            FlopMode::Flop,
        ),
    };
    map_ft_result(rs)
}

/// Rotates CbCr 8+ bit image.
///
/// This rotates any 2 channels image, channel order does not matter.
///
/// # Arguments
///
/// * `src`: Source image
/// * `src_stride`: Source image stride
/// * `dst`: Destination image
/// * `dst_stride`: Destination image stride
/// * `width`: Image width
/// * `height`: Image Height
/// * `mode`: Refer to [RotationMode] for mode info
///
/// returns: Result<(), [YuvError]>
///
pub fn rotate_cbcr16(
    src: &[u16],
    src_stride: usize,
    dst: &mut [u16],
    dst_stride: usize,
    width: usize,
    height: usize,
    mode: RotationMode,
) -> Result<(), YuvError> {
    let rs = match mode {
        RotationMode::Rotate90 => transpose_plane16_with_alpha(
            src,
            src_stride,
            dst,
            dst_stride,
            width,
            height,
            FlipMode::NoFlip,
            FlopMode::NoFlop,
        ),
        RotationMode::Rotate180 => {
            rotate180_plane16_with_alpha(src, src_stride, dst, dst_stride, width, height)
        }
        RotationMode::Rotate270 => transpose_plane16_with_alpha(
            src,
            src_stride,
            dst,
            dst_stride,
            width,
            height,
            FlipMode::Flip,
            FlopMode::Flop,
        ),
    };
    map_ft_result(rs)
}

/// Rotates Planar 8+ bit image.
///
/// This rotates planar image.
///
/// # Arguments
///
/// * `src`: Source image
/// * `src_stride`: Source image stride
/// * `dst`: Destination image
/// * `dst_stride`: Destination image stride
/// * `width`: Image width
/// * `height`: Image Height
/// * `mode`: Refer to [RotationMode] for mode info
///
/// returns: Result<(), [YuvError]>
///
pub fn rotate_plane16(
    src: &[u16],
    src_stride: usize,
    dst: &mut [u16],
    dst_stride: usize,
    width: usize,
    height: usize,
    mode: RotationMode,
) -> Result<(), YuvError> {
    let rs = match mode {
        RotationMode::Rotate90 => transpose_plane16(
            src,
            src_stride,
            dst,
            dst_stride,
            width,
            height,
            FlipMode::NoFlip,
            FlopMode::NoFlop,
        ),
        RotationMode::Rotate180 => {
            rotate180_plane16(src, src_stride, dst, dst_stride, width, height)
        }
        RotationMode::Rotate270 => transpose_plane16(
            src,
            src_stride,
            dst,
            dst_stride,
            width,
            height,
            FlipMode::Flip,
            FlopMode::Flop,
        ),
    };
    map_ft_result(rs)
}
