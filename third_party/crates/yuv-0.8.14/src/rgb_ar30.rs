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

type RgbRa30RowHandler<V> = unsafe fn(src: &[V], dst: &mut [u8]);

#[inline(always)]
fn default_row_converter<
    const AR30_LAYOUT: usize,
    const AR30_BYTE_ORDER: usize,
    const RGBA_LAYOUT: u8,
>(
    src: &[u8],
    dst: &mut [u8],
) {
    let rgba_layout: YuvSourceChannels = RGBA_LAYOUT.into();
    let ar30_layout: Rgb30 = AR30_LAYOUT.into();
    for (src, dst) in src
        .chunks_exact(rgba_layout.get_channels_count())
        .zip(dst.chunks_exact_mut(4))
    {
        let r = src[rgba_layout.get_r_channel_offset()];
        let g = src[rgba_layout.get_g_channel_offset()];
        let b = src[rgba_layout.get_b_channel_offset()];

        let r = u16::from_ne_bytes([r, r]) >> 6;
        let g = u16::from_ne_bytes([g, g]) >> 6;
        let b = u16::from_ne_bytes([b, b]) >> 6;

        let packed = if rgba_layout.has_alpha() {
            ar30_layout.pack_w_a::<AR30_BYTE_ORDER>(
                r as i32,
                g as i32,
                b as i32,
                src[3] as i32 >> 6,
            )
        } else {
            ar30_layout.pack::<AR30_BYTE_ORDER>(r as i32, g as i32, b as i32)
        };
        let v_bytes = packed.to_ne_bytes();
        dst[0] = v_bytes[0];
        dst[1] = v_bytes[1];
        dst[2] = v_bytes[2];
        dst[3] = v_bytes[3];
    }
}

#[inline(always)]
fn default_row_converter_hb<
    const AR30_LAYOUT: usize,
    const AR30_BYTE_ORDER: usize,
    const RGBA_LAYOUT: u8,
    const BIT_DEPTH: usize,
>(
    src: &[u16],
    dst: &mut [u8],
) {
    let rgba_layout: YuvSourceChannels = RGBA_LAYOUT.into();
    let ar30_layout: Rgb30 = AR30_LAYOUT.into();
    let target_shift = BIT_DEPTH - 10;
    let alpha_shift = BIT_DEPTH - 2;
    for (src, dst) in src
        .chunks_exact(rgba_layout.get_channels_count())
        .zip(dst.chunks_exact_mut(4))
    {
        let r = src[rgba_layout.get_r_channel_offset()];
        let g = src[rgba_layout.get_g_channel_offset()];
        let b = src[rgba_layout.get_b_channel_offset()];

        let r = r >> target_shift;
        let g = g >> target_shift;
        let b = b >> target_shift;

        let packed = if rgba_layout.has_alpha() {
            ar30_layout.pack_w_a::<AR30_BYTE_ORDER>(
                r as i32,
                g as i32,
                b as i32,
                src[3] as i32 >> alpha_shift,
            )
        } else {
            ar30_layout.pack::<AR30_BYTE_ORDER>(r as i32, g as i32, b as i32)
        };
        let v_bytes = packed.to_ne_bytes();
        dst[0] = v_bytes[0];
        dst[1] = v_bytes[1];
        dst[2] = v_bytes[2];
        dst[3] = v_bytes[3];
    }
}

#[cfg(all(
    any(target_arch = "x86", target_arch = "x86_64"),
    feature = "nightly_avx512"
))]
#[target_feature(enable = "avx512bw")]
unsafe fn default_row_converter_avx512<
    const AR30_LAYOUT: usize,
    const AR30_BYTE_ORDER: usize,
    const RGBA_LAYOUT: u8,
>(
    src: &[u8],
    dst: &mut [u8],
) {
    default_row_converter::<AR30_LAYOUT, AR30_BYTE_ORDER, RGBA_LAYOUT>(src, dst);
}

#[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "avx"))]
#[target_feature(enable = "avx2")]
unsafe fn default_row_converter_avx2<
    const AR30_LAYOUT: usize,
    const AR30_BYTE_ORDER: usize,
    const RGBA_LAYOUT: u8,
>(
    src: &[u8],
    dst: &mut [u8],
) {
    default_row_converter::<AR30_LAYOUT, AR30_BYTE_ORDER, RGBA_LAYOUT>(src, dst);
}

#[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "sse"))]
#[target_feature(enable = "sse4.1")]
unsafe fn default_row_converter_sse4_1<
    const AR30_LAYOUT: usize,
    const AR30_BYTE_ORDER: usize,
    const RGBA_LAYOUT: u8,
>(
    src: &[u8],
    dst: &mut [u8],
) {
    default_row_converter::<AR30_LAYOUT, AR30_BYTE_ORDER, RGBA_LAYOUT>(src, dst);
}

trait ConverterFactory<V> {
    fn make_converter<
        const AR30_LAYOUT: usize,
        const AR30_BYTE_ORDER: usize,
        const RGBA_LAYOUT: u8,
        const BIT_DEPTH: usize,
    >() -> RgbRa30RowHandler<V>;
}

impl ConverterFactory<u8> for u8 {
    fn make_converter<
        const AR30_LAYOUT: usize,
        const AR30_BYTE_ORDER: usize,
        const RGBA_LAYOUT: u8,
        const BIT_DEPTH: usize,
    >() -> RgbRa30RowHandler<u8> {
        #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
        {
            #[cfg(feature = "nightly_avx512")]
            {
                if std::arch::is_x86_feature_detected!("avx512bw") {
                    return default_row_converter_avx512::<AR30_LAYOUT, AR30_BYTE_ORDER, RGBA_LAYOUT>;
                }
            }
            #[cfg(feature = "avx")]
            {
                if std::arch::is_x86_feature_detected!("avx2") {
                    return default_row_converter_avx2::<AR30_LAYOUT, AR30_BYTE_ORDER, RGBA_LAYOUT>;
                }
            }
            #[cfg(feature = "sse")]
            {
                if std::arch::is_x86_feature_detected!("sse4.1") {
                    return default_row_converter_sse4_1::<AR30_LAYOUT, AR30_BYTE_ORDER, RGBA_LAYOUT>;
                }
            }
        }
        default_row_converter::<AR30_LAYOUT, AR30_BYTE_ORDER, RGBA_LAYOUT>
    }
}

#[cfg(all(
    any(target_arch = "x86", target_arch = "x86_64"),
    feature = "nightly_avx512"
))]
#[target_feature(enable = "avx512bw")]
unsafe fn default_row_converter_hb_avx512<
    const AR30_LAYOUT: usize,
    const AR30_BYTE_ORDER: usize,
    const RGBA_LAYOUT: u8,
    const BIT_DEPTH: usize,
>(
    src: &[u16],
    dst: &mut [u8],
) {
    default_row_converter_hb::<AR30_LAYOUT, AR30_BYTE_ORDER, RGBA_LAYOUT, BIT_DEPTH>(src, dst);
}

#[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "avx"))]
#[target_feature(enable = "avx2")]
unsafe fn default_row_converter_hb_avx2<
    const AR30_LAYOUT: usize,
    const AR30_BYTE_ORDER: usize,
    const RGBA_LAYOUT: u8,
    const BIT_DEPTH: usize,
>(
    src: &[u16],
    dst: &mut [u8],
) {
    default_row_converter_hb::<AR30_LAYOUT, AR30_BYTE_ORDER, RGBA_LAYOUT, BIT_DEPTH>(src, dst);
}

#[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "sse"))]
#[target_feature(enable = "sse4.1")]
unsafe fn default_row_converter_hb_sse4_1<
    const AR30_LAYOUT: usize,
    const AR30_BYTE_ORDER: usize,
    const RGBA_LAYOUT: u8,
    const BIT_DEPTH: usize,
>(
    src: &[u16],
    dst: &mut [u8],
) {
    default_row_converter_hb::<AR30_LAYOUT, AR30_BYTE_ORDER, RGBA_LAYOUT, BIT_DEPTH>(src, dst);
}

impl ConverterFactory<u16> for u16 {
    fn make_converter<
        const AR30_LAYOUT: usize,
        const AR30_BYTE_ORDER: usize,
        const RGBA_LAYOUT: u8,
        const BIT_DEPTH: usize,
    >() -> RgbRa30RowHandler<u16> {
        #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
        {
            #[cfg(feature = "nightly_avx512")]
            {
                if std::arch::is_x86_feature_detected!("avx512bw") {
                    return default_row_converter_hb_avx512::<
                        AR30_LAYOUT,
                        AR30_BYTE_ORDER,
                        RGBA_LAYOUT,
                        BIT_DEPTH,
                    >;
                }
            }
            #[cfg(feature = "avx")]
            {
                if std::arch::is_x86_feature_detected!("avx2") {
                    return default_row_converter_hb_avx2::<
                        AR30_LAYOUT,
                        AR30_BYTE_ORDER,
                        RGBA_LAYOUT,
                        BIT_DEPTH,
                    >;
                }
            }
            #[cfg(feature = "sse")]
            {
                if std::arch::is_x86_feature_detected!("sse4.1") {
                    return default_row_converter_hb_sse4_1::<
                        AR30_LAYOUT,
                        AR30_BYTE_ORDER,
                        RGBA_LAYOUT,
                        BIT_DEPTH,
                    >;
                }
            }
        }
        default_row_converter_hb::<AR30_LAYOUT, AR30_BYTE_ORDER, RGBA_LAYOUT, BIT_DEPTH>
    }
}

#[inline]
fn rgb_to_ar30_impl<
    V: Copy + 'static + ConverterFactory<V>,
    const AR30_LAYOUT: usize,
    const AR30_BYTE_ORDER: usize,
    const RGBA_LAYOUT: u8,
    const BIT_DEPTH: usize,
>(
    ar30: &mut [u8],
    ar30_stride: u32,
    rgba: &[V],
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

    let row_handler = V::make_converter::<AR30_LAYOUT, AR30_BYTE_ORDER, RGBA_LAYOUT, BIT_DEPTH>();

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
        $rgb_l: expr,
        $tpz: ident,
        $bp: expr
    ) => {
        #[doc = concat!("Converts ",$rgb_l," ", stringify!($bp)," bit depth to ",$ab_format, " (", $ab_f_format, ")\n",
                                                                                        "# Arguments

* `", $ab_l_format, "`: Dest ", $ab_format, " data
* `", $ab_l_format, "_stride`: Dest ", $ab_format, " stride
* `byte_order`: See [Rgb30ByteOrder] for more info
* `", $rgb_s,"`: Source ",$rgb_l, stringify!($bp)," data
* `", $rgb_s,"_stride`: Source ",$rgb_l, stringify!($bp)," stride
* `width`: Image width
* `height`: Image height")]
        pub fn $method_name(
            ar30: &mut [u8],
            ar30_stride: u32,
            byte_order: Rgb30ByteOrder,
            rgb: &[$tpz],
            rgb_stride: u32,
            width: u32,
            height: u32,
        ) -> Result<(), YuvError> {
            match byte_order {
                Rgb30ByteOrder::Host => rgb_to_ar30_impl::<
                    $tpz,
                    { $ar_dst as usize },
                    { Rgb30ByteOrder::Host as usize },
                    { $rgb_src as u8 },
                    $bp,
                >(ar30, ar30_stride, rgb, rgb_stride, width, height),
                Rgb30ByteOrder::Network => {
                    rgb_to_ar30_impl::<
                        $tpz,
                        { $ar_dst as usize },
                        { Rgb30ByteOrder::Network as usize },
                        { $rgb_src as u8 },
                        $bp,
                    >(ar30, ar30_stride, rgb, rgb_stride, width, height)
                }
            }
        }
    };
}

rgb102_cnv!(
    rgb8_to_ar30,
    "AR30",
    "ARGB2101010",
    "ar30",
    Rgb30::Ar30,
    YuvSourceChannels::Rgb,
    "rgb",
    "RGB",
    u8,
    8
);
rgb102_cnv!(
    rgb8_to_ra30,
    "RA30",
    "RGBA1010102",
    "ra30",
    Rgb30::Ra30,
    YuvSourceChannels::Rgb,
    "rgb",
    "RGB",
    u8,
    8
);
rgb102_cnv!(
    rgba8_to_ar30,
    "AR30",
    "ARGB2101010",
    "ar30",
    Rgb30::Ar30,
    YuvSourceChannels::Rgba,
    "rgba",
    "RGBA",
    u8,
    8
);
rgb102_cnv!(
    rgba8_to_ra30,
    "RA30",
    "RGBA1010102",
    "ra30",
    Rgb30::Ra30,
    YuvSourceChannels::Rgba,
    "rgba",
    "RGBA",
    u8,
    8
);

rgb102_cnv!(
    rgb10_to_ar30,
    "AR30",
    "ARGB2101010",
    "ar30",
    Rgb30::Ar30,
    YuvSourceChannels::Rgb,
    "rgb",
    "RGB",
    u16,
    10
);
rgb102_cnv!(
    rgb10_to_ra30,
    "RA30",
    "RGBA1010102",
    "ra30",
    Rgb30::Ra30,
    YuvSourceChannels::Rgb,
    "rgb",
    "RGB",
    u16,
    10
);
rgb102_cnv!(
    rgb12_to_ar30,
    "AR30",
    "ARGB2101010",
    "ar30",
    Rgb30::Ar30,
    YuvSourceChannels::Rgb,
    "rgb",
    "RGB",
    u16,
    12
);
rgb102_cnv!(
    rgb12_to_ra30,
    "RA30",
    "RGBA1010102",
    "ra30",
    Rgb30::Ra30,
    YuvSourceChannels::Rgb,
    "rgb",
    "RGB",
    u16,
    12
);

rgb102_cnv!(
    rgba10_to_ar30,
    "AR30",
    "ARGB2101010",
    "ar30",
    Rgb30::Ar30,
    YuvSourceChannels::Rgba,
    "rgba",
    "RGBA",
    u16,
    10
);
rgb102_cnv!(
    rgba10_to_ra30,
    "RA30",
    "RGBA1010102",
    "ra30",
    Rgb30::Ra30,
    YuvSourceChannels::Rgba,
    "rgba",
    "RGBA",
    u16,
    10
);
rgb102_cnv!(
    rgba12_to_ar30,
    "AR30",
    "ARGB2101010",
    "ar30",
    Rgb30::Ar30,
    YuvSourceChannels::Rgba,
    "rgba",
    "RGBA",
    u16,
    12
);
rgb102_cnv!(
    rgba12_to_ra30,
    "RA30",
    "RGBA1010102",
    "ra30",
    Rgb30::Ra30,
    YuvSourceChannels::Rgba,
    "rgba",
    "RGBA",
    u16,
    12
);

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ar30_to_rgb8;
    use rand::RngExt;

    #[test]
    fn ar30_rgb_round_trip_host() {
        let image_width = 64usize;
        let image_height = 64usize;

        let random_point_x = rand::rng().random_range(0..image_width);
        let random_point_y = rand::rng().random_range(0..image_height);

        let random_r = rand::rng().random_range(0..255) as u8;
        let random_g = rand::rng().random_range(0..255) as u8;
        let random_b = rand::rng().random_range(0..255) as u8;

        const CN: usize = 3;

        let mut source_rgb = vec![0u8; image_width * image_height * CN];

        for chunk in source_rgb.chunks_exact_mut(CN) {
            chunk[0] = random_r;
            chunk[1] = random_g;
            chunk[2] = random_b;
        }

        let mut dst_ar30 = vec![0u8; image_width * image_height * 4];
        rgb8_to_ar30(
            &mut dst_ar30,
            image_width as u32 * 4,
            Rgb30ByteOrder::Host,
            &source_rgb,
            image_width as u32 * CN as u32,
            image_width as u32,
            image_height as u32,
        )
        .unwrap();

        ar30_to_rgb8(
            &dst_ar30,
            image_width as u32 * 4,
            Rgb30ByteOrder::Host,
            &mut source_rgb,
            image_width as u32 * CN as u32,
            image_width as u32,
            image_height as u32,
        )
        .unwrap();

        assert_eq!(
            source_rgb[random_point_x * CN],
            random_r,
            "R invalid {}, expected {} Point ({}, {})",
            source_rgb[random_point_x * CN],
            random_r,
            random_point_x,
            random_point_y
        );
        assert_eq!(
            source_rgb[random_point_x * CN + 1],
            random_g,
            "G invalid {}, expected {} Point ({}, {})",
            source_rgb[random_point_x * CN + 1],
            random_r,
            random_point_x,
            random_point_y
        );
        assert_eq!(
            source_rgb[random_point_x * CN + 2],
            random_b,
            "B invalid {}, expected {} Point ({}, {})",
            source_rgb[random_point_x * CN + 2],
            random_r,
            random_point_x,
            random_point_y
        );
    }

    #[test]
    fn ar30_rgb_round_trip_network() {
        let image_width = 64usize;
        let image_height = 64usize;

        let random_point_x = rand::rng().random_range(0..image_width);
        let random_point_y = rand::rng().random_range(0..image_height);

        let random_r = rand::rng().random_range(0..255) as u8;
        let random_g = rand::rng().random_range(0..255) as u8;
        let random_b = rand::rng().random_range(0..255) as u8;

        const CN: usize = 3;

        let mut source_rgb = vec![0u8; image_width * image_height * CN];

        for chunk in source_rgb.chunks_exact_mut(CN) {
            chunk[0] = random_r;
            chunk[1] = random_g;
            chunk[2] = random_b;
        }

        let mut dst_ar30 = vec![0u8; image_width * image_height * 4];
        rgb8_to_ar30(
            &mut dst_ar30,
            image_width as u32 * 4,
            Rgb30ByteOrder::Network,
            &source_rgb,
            image_width as u32 * CN as u32,
            image_width as u32,
            image_height as u32,
        )
        .unwrap();

        ar30_to_rgb8(
            &dst_ar30,
            image_width as u32 * 4,
            Rgb30ByteOrder::Network,
            &mut source_rgb,
            image_width as u32 * CN as u32,
            image_width as u32,
            image_height as u32,
        )
        .unwrap();

        assert_eq!(
            source_rgb[random_point_x * CN],
            random_r,
            "R invalid {}, expected {} Point ({}, {})",
            source_rgb[random_point_x * CN],
            random_r,
            random_point_x,
            random_point_y
        );
        assert_eq!(
            source_rgb[random_point_x * CN + 1],
            random_g,
            "G invalid {}, expected {} Point ({}, {})",
            source_rgb[random_point_x * CN + 1],
            random_r,
            random_point_x,
            random_point_y
        );
        assert_eq!(
            source_rgb[random_point_x * CN + 2],
            random_b,
            "B invalid {}, expected {} Point ({}, {})",
            source_rgb[random_point_x * CN + 2],
            random_r,
            random_point_x,
            random_point_y
        );
    }
}
