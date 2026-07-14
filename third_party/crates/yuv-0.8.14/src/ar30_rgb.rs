/*
 * Copyright (c) Radzivon Bartoshyk, 11/2024. All rights reserved.
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
use crate::yuv_error::check_rgba_destination;
use crate::yuv_support::{Rgb30, YuvSourceChannels};
use crate::{Rgb30ByteOrder, YuvError};

#[inline]
fn ar30_to_rgb8_impl<
    const AR30_LAYOUT: usize,
    const AR30_BYTE_ORDER: usize,
    const RGBA_LAYOUT: u8,
>(
    ar30: &[u8],
    ar30_stride: u32,
    rgba: &mut [u8],
    rgba_stride: u32,
    width: u32,
    height: u32,
) -> Result<(), YuvError> {
    let rgba_layout: YuvSourceChannels = RGBA_LAYOUT.into();
    let ar30_layout: Rgb30 = AR30_LAYOUT.into();
    check_rgba_destination(ar30, ar30_stride, width, height, 4)?;
    check_rgba_destination(
        rgba,
        rgba_stride,
        width,
        height,
        rgba_layout.get_channels_count(),
    )?;

    for (dst, src) in rgba
        .chunks_exact_mut(rgba_stride as usize)
        .zip(ar30.chunks_exact(ar30_stride as usize))
    {
        let src = &src[..width as usize * 4];
        let dst = &mut dst[..width as usize * rgba_layout.get_channels_count()];
        for (dst, src) in dst
            .chunks_exact_mut(rgba_layout.get_channels_count())
            .zip(src.chunks_exact(4))
        {
            let ar30_v = u32::from_ne_bytes([src[0], src[1], src[2], src[3]]);
            let unpacked = ar30_layout.unpack::<AR30_BYTE_ORDER>(ar30_v);
            let r = unpacked.0 >> 2;
            let g = unpacked.1 >> 2;
            let b = unpacked.2 >> 2;
            dst[rgba_layout.get_r_channel_offset()] = r as u8;
            dst[rgba_layout.get_g_channel_offset()] = g as u8;
            dst[rgba_layout.get_b_channel_offset()] = b as u8;
            if rgba_layout.has_alpha() {
                let expanded_a =
                    (unpacked.3 << 6) | (unpacked.3 << 4) | (unpacked.3 << 2) | unpacked.3;
                dst[rgba_layout.get_a_channel_offset()] = expanded_a as u8;
            }
        }
    }
    Ok(())
}

/// Converts RGBA2101010 to RGB 8 bit depth
///
/// # Arguments
///
/// * `ar30`: Source AR30 data
/// * `ar30_stride`: Source AR30 stride
/// * `byte_order`: See [Rgb30ByteOrder] for more info
/// * `rgb`: Destination RGB data
/// * `rgb_stride`: Destination RGB stride
/// * `width`: Image width
/// * `height`: Image height
///
pub fn ar30_to_rgb8(
    ar30: &[u8],
    ar30_stride: u32,
    byte_order: Rgb30ByteOrder,
    rgb: &mut [u8],
    rgb_stride: u32,
    width: u32,
    height: u32,
) -> Result<(), YuvError> {
    match byte_order {
        Rgb30ByteOrder::Host => ar30_to_rgb8_impl::<
            { Rgb30::Ar30 as usize },
            { Rgb30ByteOrder::Host as usize },
            { YuvSourceChannels::Rgb as u8 },
        >(ar30, ar30_stride, rgb, rgb_stride, width, height),
        Rgb30ByteOrder::Network => ar30_to_rgb8_impl::<
            { Rgb30::Ar30 as usize },
            { Rgb30ByteOrder::Network as usize },
            { YuvSourceChannels::Rgb as u8 },
        >(ar30, ar30_stride, rgb, rgb_stride, width, height),
    }
}

/// Converts BGBA2101010 to RGB 8 bit depth
///
/// # Arguments
///
/// * `ab30`: Source AR30 data
/// * `ab30_stride`: Source AR30 stride
/// * `byte_order`: See [Rgb30ByteOrder] for more info
/// * `rgb`: Destination RGB data
/// * `rgb_stride`: Destination RGB stride
/// * `width`: Image width
/// * `height`: Image height
///
pub fn ab30_to_rgb8(
    ab30: &[u8],
    ab30_stride: u32,
    byte_order: Rgb30ByteOrder,
    rgb: &mut [u8],
    rgb_stride: u32,
    width: u32,
    height: u32,
) -> Result<(), YuvError> {
    match byte_order {
        Rgb30ByteOrder::Host => ar30_to_rgb8_impl::<
            { Rgb30::Ab30 as usize },
            { Rgb30ByteOrder::Host as usize },
            { YuvSourceChannels::Rgb as u8 },
        >(ab30, ab30_stride, rgb, rgb_stride, width, height),
        Rgb30ByteOrder::Network => ar30_to_rgb8_impl::<
            { Rgb30::Ab30 as usize },
            { Rgb30ByteOrder::Network as usize },
            { YuvSourceChannels::Rgb as u8 },
        >(ab30, ab30_stride, rgb, rgb_stride, width, height),
    }
}

/// Converts RGBA1010102 to RGB 8 bit depth
///
/// # Arguments
///
/// * `ar30`: Source RA30 data
/// * `ar30_stride`: Source RA30 stride
/// * `byte_order`: See [Rgb30ByteOrder] for more info
/// * `rgb`: Destination RGB data
/// * `rgb_stride`: Destination RGB stride
/// * `width`: Image width
/// * `height`: Image height
///
pub fn ra30_to_rgb8(
    ar30: &[u8],
    ar30_stride: u32,
    byte_order: Rgb30ByteOrder,
    rgb: &mut [u8],
    rgb_stride: u32,
    width: u32,
    height: u32,
) -> Result<(), YuvError> {
    match byte_order {
        Rgb30ByteOrder::Host => ar30_to_rgb8_impl::<
            { Rgb30::Ra30 as usize },
            { Rgb30ByteOrder::Host as usize },
            { YuvSourceChannels::Rgb as u8 },
        >(ar30, ar30_stride, rgb, rgb_stride, width, height),
        Rgb30ByteOrder::Network => ar30_to_rgb8_impl::<
            { Rgb30::Ra30 as usize },
            { Rgb30ByteOrder::Network as usize },
            { YuvSourceChannels::Rgb as u8 },
        >(ar30, ar30_stride, rgb, rgb_stride, width, height),
    }
}

/// Converts BGRA1010102 to RGB 8 bit depth
///
/// # Arguments
///
/// * `ar30`: Source RA30 data
/// * `ar30_stride`: Source RA30 stride
/// * `byte_order`: See [Rgb30ByteOrder] for more info
/// * `rgb`: Destination RGB data
/// * `rgb_stride`: Destination RGB stride
/// * `width`: Image width
/// * `height`: Image height
///
pub fn ba30_to_rgb8(
    ar30: &[u8],
    ar30_stride: u32,
    byte_order: Rgb30ByteOrder,
    rgb: &mut [u8],
    rgb_stride: u32,
    width: u32,
    height: u32,
) -> Result<(), YuvError> {
    match byte_order {
        Rgb30ByteOrder::Host => ar30_to_rgb8_impl::<
            { Rgb30::Ba30 as usize },
            { Rgb30ByteOrder::Host as usize },
            { YuvSourceChannels::Rgb as u8 },
        >(ar30, ar30_stride, rgb, rgb_stride, width, height),
        Rgb30ByteOrder::Network => ar30_to_rgb8_impl::<
            { Rgb30::Ba30 as usize },
            { Rgb30ByteOrder::Network as usize },
            { YuvSourceChannels::Rgb as u8 },
        >(ar30, ar30_stride, rgb, rgb_stride, width, height),
    }
}

/// Converts RGBA2101010 to RGB 8 bit depth
///
/// # Arguments
///
/// * `ar30`: Source AR30 data
/// * `ar30_stride`: Source AR30 stride
/// * `byte_order`: See [Rgb30ByteOrder] for more info
/// * `rgba`: Destination RGBA data
/// * `rgba_stride`: Destination RGBA stride
/// * `width`: Image width
/// * `height`: Image height
///
pub fn ar30_to_rgba8(
    ar30: &[u8],
    ar30_stride: u32,
    byte_order: Rgb30ByteOrder,
    rgba: &mut [u8],
    rgba_stride: u32,
    width: u32,
    height: u32,
) -> Result<(), YuvError> {
    match byte_order {
        Rgb30ByteOrder::Host => ar30_to_rgb8_impl::<
            { Rgb30::Ar30 as usize },
            { Rgb30ByteOrder::Host as usize },
            { YuvSourceChannels::Rgba as u8 },
        >(ar30, ar30_stride, rgba, rgba_stride, width, height),
        Rgb30ByteOrder::Network => ar30_to_rgb8_impl::<
            { Rgb30::Ar30 as usize },
            { Rgb30ByteOrder::Network as usize },
            { YuvSourceChannels::Rgba as u8 },
        >(ar30, ar30_stride, rgba, rgba_stride, width, height),
    }
}

/// Converts RGBA1010102 to RGB 8 bit depth
///
/// # Arguments
///
/// * `ar30`: Source RA30 data
/// * `ar30_stride`: Source RA30 stride
/// * `byte_order`: See [Rgb30ByteOrder] for more info
/// * `rgba`: Destination RGBA data
/// * `rgba_stride`: Destination RGBA stride
/// * `width`: Image width
/// * `height`: Image height
///
pub fn ra30_to_rgba8(
    ra30: &[u8],
    ra30_stride: u32,
    byte_order: Rgb30ByteOrder,
    rgba: &mut [u8],
    rgba_stride: u32,
    width: u32,
    height: u32,
) -> Result<(), YuvError> {
    match byte_order {
        Rgb30ByteOrder::Host => ar30_to_rgb8_impl::<
            { Rgb30::Ra30 as usize },
            { Rgb30ByteOrder::Host as usize },
            { YuvSourceChannels::Rgba as u8 },
        >(ra30, ra30_stride, rgba, rgba_stride, width, height),
        Rgb30ByteOrder::Network => ar30_to_rgb8_impl::<
            { Rgb30::Ra30 as usize },
            { Rgb30ByteOrder::Network as usize },
            { YuvSourceChannels::Rgba as u8 },
        >(ra30, ra30_stride, rgba, rgba_stride, width, height),
    }
}
