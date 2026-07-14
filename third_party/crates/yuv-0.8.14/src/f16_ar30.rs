/*
 * Copyright (c) Radzivon Bartoshyk, 5/2025. All rights reserved.
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
use core::f16;

type RgbRa30RowHandler<V> = unsafe fn(src: &[V], dst: &mut [u8]);

#[inline(always)]
fn default_row_converter<
    const AR30_LAYOUT: usize,
    const AR30_BYTE_ORDER: usize,
    const RGBA_LAYOUT: u8,
>(
    src: &[f16],
    dst: &mut [u8],
) {
    let rgba_layout: YuvSourceChannels = RGBA_LAYOUT.into();
    let ar30_layout: Rgb30 = AR30_LAYOUT.into();
    let scale_value: f16 = 1023.;
    let scale_alpha: f16 = 3.;
    for (src, dst) in src
        .chunks_exact(rgba_layout.get_channels_count())
        .zip(dst.chunks_exact_mut(4))
    {
        let r = src[rgba_layout.get_r_channel_offset()];
        let g = src[rgba_layout.get_g_channel_offset()];
        let b = src[rgba_layout.get_b_channel_offset()];

        let r = ((r * scale_value) as i32).min(1023).max(0);
        let g = ((g * scale_value) as i32).min(1023).max(0);
        let b = ((b * scale_value) as i32).min(1023).max(0);

        let packed = if rgba_layout.has_alpha() {
            ar30_layout.pack_w_a::<AR30_BYTE_ORDER>(
                r,
                g,
                b,
                ((src[3] * scale_alpha) as i32).min(3).max(0),
            )
        } else {
            ar30_layout.pack::<AR30_BYTE_ORDER>(r, g, b)
        };
        let v_bytes = packed.to_ne_bytes();
        dst[0] = v_bytes[0];
        dst[1] = v_bytes[1];
        dst[2] = v_bytes[2];
        dst[3] = v_bytes[3];
    }
}

#[cfg(target_arch = "aarch64")]
#[target_feature(enable = "fp16")]
unsafe fn default_row_converter_fp16_neon<
    const AR30_LAYOUT: usize,
    const AR30_BYTE_ORDER: usize,
    const RGBA_LAYOUT: u8,
>(
    src: &[f16],
    dst: &mut [u8],
) {
    default_row_converter::<AR30_LAYOUT, AR30_BYTE_ORDER, RGBA_LAYOUT>(src, dst);
}

#[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "avx"))]
#[target_feature(enable = "avx2", enable = "f16c")]
unsafe fn default_row_converter_avx2<
    const AR30_LAYOUT: usize,
    const AR30_BYTE_ORDER: usize,
    const RGBA_LAYOUT: u8,
>(
    src: &[f16],
    dst: &mut [u8],
) {
    default_row_converter::<AR30_LAYOUT, AR30_BYTE_ORDER, RGBA_LAYOUT>(src, dst);
}

fn make_converter<const AR30_LAYOUT: usize, const AR30_BYTE_ORDER: usize, const RGBA_LAYOUT: u8>(
) -> RgbRa30RowHandler<f16> {
    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    {
        #[cfg(feature = "avx")]
        {
            if std::arch::is_x86_feature_detected!("avx2") && std::is_x86_feature_detected!("f16c")
            {
                return default_row_converter_avx2::<AR30_LAYOUT, AR30_BYTE_ORDER, RGBA_LAYOUT>;
            }
        }
    }
    #[cfg(target_arch = "aarch64")]
    {
        if std::arch::is_aarch64_feature_detected!("fp16") {
            return default_row_converter_fp16_neon::<AR30_LAYOUT, AR30_BYTE_ORDER, RGBA_LAYOUT>;
        }
    }
    default_row_converter::<AR30_LAYOUT, AR30_BYTE_ORDER, RGBA_LAYOUT>
}

#[inline]
fn rgb_to_ar30_impl<
    const AR30_LAYOUT: usize,
    const AR30_BYTE_ORDER: usize,
    const RGBA_LAYOUT: u8,
>(
    ar30: &mut [u8],
    ar30_stride: u32,
    rgba: &[f16],
    rgba_stride: u32,
    width: u32,
    height: u32,
) -> Result<(), YuvError> {
    let rgba_layout: YuvSourceChannels = RGBA_LAYOUT.into();
    check_rgba_destination(ar30, ar30_stride, width, height, 4)?;
    check_rgba_destination(
        rgba,
        rgba_stride,
        width,
        height,
        rgba_layout.get_channels_count(),
    )?;

    let row_handler = make_converter::<AR30_LAYOUT, AR30_BYTE_ORDER, RGBA_LAYOUT>();

    for (src, dst) in rgba
        .chunks_exact(rgba_stride as usize)
        .zip(ar30.chunks_exact_mut(ar30_stride as usize))
    {
        let src = &src[..width as usize * rgba_layout.get_channels_count()];
        let dst = &mut dst[..width as usize * 4];
        unsafe {
            row_handler(src, dst);
        }
    }
    Ok(())
}

macro_rules! rgb102_cnv {
    (
        $method_name:ident,
        $ab_format:expr,
        $ab_f_format:expr,
        $ab_l_format:expr,
        $ar_dst: expr,
        $rgb_src: expr,
        $rgb_s: expr,
        $rgb_l: expr
    ) => {
        #[doc = concat!("Converts ",$rgb_l," to ",$ab_format, " (", $ab_f_format, ")\n",
                                                                                        "# Arguments

* `", $ab_l_format, "`: Dest ", $ab_format, " data
* `", $ab_l_format, "_stride`: Dest ", $ab_format, " stride
* `byte_order`: See [Rgb30ByteOrder] for more info
* `", $rgb_s,"`: Source ",$rgb_l," data
* `", $rgb_s,"_stride`: Source ",$rgb_l, " stride
* `width`: Image width
* `height`: Image height")]
        pub fn $method_name(
            ar30: &mut [u8],
            ar30_stride: u32,
            byte_order: Rgb30ByteOrder,
            rgb: &[f16],
            rgb_stride: u32,
            width: u32,
            height: u32,
        ) -> Result<(), YuvError> {
            match byte_order {
                Rgb30ByteOrder::Host => rgb_to_ar30_impl::<
                    { $ar_dst as usize },
                    { Rgb30ByteOrder::Host as usize },
                    { $rgb_src as u8 },
                >(ar30, ar30_stride, rgb, rgb_stride, width, height),
                Rgb30ByteOrder::Network => {
                    rgb_to_ar30_impl::<
                        { $ar_dst as usize },
                        { Rgb30ByteOrder::Network as usize },
                        { $rgb_src as u8 },
                    >(ar30, ar30_stride, rgb, rgb_stride, width, height)
                }
            }
        }
    };
}

rgb102_cnv!(
    rgb_f16_to_ar30,
    "AR30",
    "ARGB2101010",
    "ar30",
    Rgb30::Ar30,
    YuvSourceChannels::Rgb,
    "rgb",
    "RGB F16"
);
rgb102_cnv!(
    rgb_f16_to_ra30,
    "RA30",
    "RGBA1010102",
    "ra30",
    Rgb30::Ra30,
    YuvSourceChannels::Rgb,
    "rgb",
    "RGB F16"
);
rgb102_cnv!(
    rgba_f16_to_ar30,
    "AR30",
    "ARGB2101010",
    "ar30",
    Rgb30::Ar30,
    YuvSourceChannels::Rgba,
    "rgba",
    "RGBA F16"
);
rgb102_cnv!(
    rgba_f16_to_ra30,
    "RA30",
    "RGBA1010102",
    "ra30",
    Rgb30::Ra30,
    YuvSourceChannels::Rgba,
    "rgba",
    "RGBA F16"
);
