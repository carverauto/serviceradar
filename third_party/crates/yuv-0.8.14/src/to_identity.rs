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
use crate::images::projected_rgba_plane;
use crate::numerics::qrshr;
use crate::yuv_error::check_rgba_destination;
use crate::yuv_support::{get_yuv_range, YuvSourceChannels};
use crate::{YuvChromaSubsampling, YuvError, YuvPlanarImageMut, YuvRange};
use num_traits::AsPrimitive;
use std::fmt::Debug;
use std::mem::size_of;

type RgbFullHandler<V> =
    unsafe fn(y_plane: &mut [V], u_plane: &mut [V], v_plane: &mut [V], rgba: &[V]);

type RgbLimitedHandler<V, J> = unsafe fn(
    y_plane: &mut [V],
    u_plane: &mut [V],
    v_plane: &mut [V],
    rgba: &[V],
    y_coef: J,
    y_bias: i32,
);

#[inline(always)]
unsafe fn default_full_converter<V: Copy + 'static, const CN: u8>(
    y_plane: &mut [V],
    u_plane: &mut [V],
    v_plane: &mut [V],
    rgba: &[V],
) {
    let cn: YuvSourceChannels = CN.into();

    for (((y_dst, u_dst), v_dst), rgb_dst) in y_plane
        .iter_mut()
        .zip(u_plane.iter_mut())
        .zip(v_plane.iter_mut())
        .zip(rgba.chunks_exact(cn.get_channels_count()))
    {
        *v_dst = rgb_dst[cn.get_r_channel_offset()];
        *y_dst = rgb_dst[cn.get_g_channel_offset()];
        *u_dst = rgb_dst[cn.get_b_channel_offset()];
    }
}

#[inline(always)]
unsafe fn default_limited_converter<
    V: Copy + 'static + AsPrimitive<i32>,
    J: Copy + AsPrimitive<i32>,
    const CN: u8,
    const BIT_DEPTH: usize,
    const PRECISION: i32,
>(
    y_plane: &mut [V],
    u_plane: &mut [V],
    v_plane: &mut [V],
    rgba: &[V],
    y_coef: J,
    y_bias: i32,
) where
    i32: AsPrimitive<V>,
{
    const PRECISION: i32 = 13;
    let cn: YuvSourceChannels = CN.into();

    // All channels on identity should use Y range
    for (((y_dst, u_dst), v_dst), rgb_dst) in y_plane
        .iter_mut()
        .zip(u_plane.iter_mut())
        .zip(v_plane.iter_mut())
        .zip(rgba.chunks_exact(cn.get_channels_count()))
    {
        let c_coef: i32 = y_coef.as_();
        *v_dst = qrshr::<PRECISION, BIT_DEPTH>(
            rgb_dst[cn.get_r_channel_offset()].as_() * c_coef + y_bias,
        )
        .as_();
        *y_dst = qrshr::<PRECISION, BIT_DEPTH>(
            rgb_dst[cn.get_g_channel_offset()].as_() * c_coef + y_bias,
        )
        .as_();
        *u_dst = qrshr::<PRECISION, BIT_DEPTH>(
            rgb_dst[cn.get_b_channel_offset()].as_() * c_coef + y_bias,
        )
        .as_();
    }
}

#[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "avx"))]
#[target_feature(enable = "avx2")]
unsafe fn default_full_converter_avx2<V: Copy + 'static, const CN: u8>(
    y_plane: &mut [V],
    u_plane: &mut [V],
    v_plane: &mut [V],
    rgba: &[V],
) {
    default_full_converter::<V, CN>(y_plane, u_plane, v_plane, rgba);
}

#[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "avx"))]
#[target_feature(enable = "avx2")]
unsafe fn default_limited_converter_avx2<
    V: Copy + 'static + AsPrimitive<i32>,
    J: Copy + AsPrimitive<i32>,
    const CN: u8,
    const BIT_DEPTH: usize,
    const PRECISION: i32,
>(
    y_plane: &mut [V],
    u_plane: &mut [V],
    v_plane: &mut [V],
    rgba: &[V],
    y_coef: J,
    y_bias: i32,
) where
    i32: AsPrimitive<V>,
{
    default_limited_converter::<V, J, CN, BIT_DEPTH, PRECISION>(
        y_plane, u_plane, v_plane, rgba, y_coef, y_bias,
    );
}

#[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "sse"))]
#[target_feature(enable = "sse4.1")]
unsafe fn default_full_converter_sse4_1<V: Copy + 'static, const CN: u8>(
    y_plane: &mut [V],
    u_plane: &mut [V],
    v_plane: &mut [V],
    rgba: &[V],
) {
    default_full_converter::<V, CN>(y_plane, u_plane, v_plane, rgba);
}

#[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "sse"))]
#[target_feature(enable = "sse4.1")]
unsafe fn default_limited_converter_sse4_1<
    V: Copy + 'static + AsPrimitive<i32>,
    J: Copy + AsPrimitive<i32>,
    const CN: u8,
    const BIT_DEPTH: usize,
    const PRECISION: i32,
>(
    y_plane: &mut [V],
    u_plane: &mut [V],
    v_plane: &mut [V],
    rgba: &[V],
    y_coef: J,
    y_bias: i32,
) where
    i32: AsPrimitive<V>,
{
    default_limited_converter::<V, J, CN, BIT_DEPTH, PRECISION>(
        y_plane, u_plane, v_plane, rgba, y_coef, y_bias,
    );
}

#[cfg(all(
    any(target_arch = "x86", target_arch = "x86_64"),
    feature = "nightly_avx512"
))]
#[target_feature(enable = "avx512bw")]
unsafe fn default_full_converter_avx512<V: Copy + 'static, const CN: u8>(
    y_plane: &mut [V],
    u_plane: &mut [V],
    v_plane: &mut [V],
    rgba: &[V],
) {
    default_full_converter::<V, CN>(y_plane, u_plane, v_plane, rgba);
}

#[cfg(all(
    any(target_arch = "x86", target_arch = "x86_64"),
    feature = "nightly_avx512"
))]
#[target_feature(enable = "avx512bw")]
unsafe fn default_limited_converter_avx512<
    V: Copy + 'static + AsPrimitive<i32>,
    J: Copy + AsPrimitive<i32>,
    const CN: u8,
    const BIT_DEPTH: usize,
    const PRECISION: i32,
>(
    y_plane: &mut [V],
    u_plane: &mut [V],
    v_plane: &mut [V],
    rgba: &[V],
    y_coef: J,
    y_bias: i32,
) where
    i32: AsPrimitive<V>,
{
    default_limited_converter::<V, J, CN, BIT_DEPTH, PRECISION>(
        y_plane, u_plane, v_plane, rgba, y_coef, y_bias,
    );
}

fn make_full_converter<V: Copy + 'static, const CN: u8>() -> RgbFullHandler<V> {
    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    {
        #[cfg(feature = "nightly_avx512")]
        if std::arch::is_x86_feature_detected!("avx512bw") {
            return default_full_converter_avx512::<V, CN>;
        }
        #[cfg(feature = "avx")]
        if std::arch::is_x86_feature_detected!("avx2") {
            return default_full_converter_avx2::<V, CN>;
        }
        #[cfg(feature = "sse")]
        if std::arch::is_x86_feature_detected!("sse4.1") {
            return default_full_converter_sse4_1::<V, CN>;
        }
    }
    default_full_converter::<V, CN>
}

fn make_limited_converter<
    V: Copy + 'static + AsPrimitive<i32>,
    J: Copy + AsPrimitive<i32>,
    const CN: u8,
    const BIT_DEPTH: usize,
    const PRECISION: i32,
>() -> RgbLimitedHandler<V, J>
where
    i32: AsPrimitive<V>,
{
    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    {
        #[cfg(feature = "nightly_avx512")]
        if std::arch::is_x86_feature_detected!("avx512bw") {
            return default_limited_converter_avx512::<V, J, CN, BIT_DEPTH, PRECISION>;
        }
        #[cfg(feature = "avx")]
        if std::arch::is_x86_feature_detected!("avx2") {
            return default_limited_converter_avx2::<V, J, CN, BIT_DEPTH, PRECISION>;
        }
        #[cfg(feature = "sse")]
        if std::arch::is_x86_feature_detected!("sse4.1") {
            return default_limited_converter_sse4_1::<V, J, CN, BIT_DEPTH, PRECISION>;
        }
    }
    default_limited_converter::<V, J, CN, BIT_DEPTH, PRECISION>
}

fn rgbx_to_gbr_impl<
    V: Copy + AsPrimitive<i32> + 'static + Sized + Debug + Default,
    J: Copy + AsPrimitive<i32>,
    const CN: u8,
    const BIT_DEPTH: usize,
>(
    image: &mut YuvPlanarImageMut<V>,
    rgba: &[V],
    rgba_stride: u32,
    yuv_range: YuvRange,
) -> Result<(), YuvError>
where
    i32: AsPrimitive<V> + AsPrimitive<J>,
{
    let cn: YuvSourceChannels = CN.into();
    let channels = cn.get_channels_count();
    assert!(
        channels == 3 || channels == 4,
        "GBR -> RGB is implemented only on 3 and 4 channels"
    );
    assert!(
        (8..=16).contains(&BIT_DEPTH),
        "Invalid bit depth is provided"
    );
    assert!(
        if BIT_DEPTH > 8 {
            size_of::<V>() == 2
        } else {
            size_of::<V>() == 1
        },
        "Unsupported bit depth and data type combination"
    );

    image.check_constraints(YuvChromaSubsampling::Yuv444)?;
    check_rgba_destination(rgba, rgba_stride, image.width, image.height, channels)?;

    let width = image.width;
    let height = image.height;

    let y_stride = image.y_stride as usize;
    let u_stride = image.u_stride as usize;
    let v_stride = image.v_stride as usize;

    let (y_plane, u_plane, v_plane) = image.projected_planes_mut(YuvChromaSubsampling::Yuv444);
    let rgba = projected_rgba_plane(rgba, width, height, rgba_stride, cn);

    let y_iter = y_plane.chunks_mut(y_stride);
    let rgba_iter = rgba.chunks(rgba_stride as usize);
    let u_iter = u_plane.chunks_mut(u_stride);
    let v_iter = v_plane.chunks_mut(v_stride);

    match yuv_range {
        YuvRange::Limited => {
            const PRECISION: i32 = 13;
            // All channels on identity should use Y range
            let range = get_yuv_range(BIT_DEPTH as u32, yuv_range);
            let range_rgba = (1 << BIT_DEPTH) - 1;
            let y_coef: J = (((range.range_y as f32 / range_rgba as f32) * (1 << PRECISION) as f32)
                .round() as i32)
                .as_();
            let y_bias = range.bias_y as i32 * (1 << PRECISION);

            let row_handler = make_limited_converter::<V, J, CN, BIT_DEPTH, PRECISION>();

            for (((y_dst, u_dst), v_dst), rgba) in y_iter.zip(u_iter).zip(v_iter).zip(rgba_iter) {
                let y_dst = &mut y_dst[..width as usize];
                let u_dst = &mut u_dst[..width as usize];
                let v_dst = &mut v_dst[..width as usize];

                unsafe {
                    row_handler(y_dst, u_dst, v_dst, rgba, y_coef, y_bias);
                }
            }
        }
        YuvRange::Full => {
            let row_handler = make_full_converter::<V, CN>();
            for (((y_dst, u_dst), v_dst), rgba) in y_iter.zip(u_iter).zip(v_iter).zip(rgba_iter) {
                let y_dst = &mut y_dst[..width as usize];
                let u_dst = &mut u_dst[..width as usize];
                let v_dst = &mut v_dst[..width as usize];

                unsafe {
                    row_handler(y_dst, u_dst, v_dst, rgba);
                }
            }
        }
    }

    Ok(())
}

macro_rules! d_cvn {
    ($method: ident, $px_fmt: expr, $clazz: ident, $bp: expr, $gb_name: expr, $rgb_name: expr, $rgb_ident: ident, $rgb_stride_ident: ident, $intermediate: ident) => {
        #[doc = concat!("Convert ",$rgb_name, stringify!($bp)," to ", $gb_name,"

This function takes ", $rgb_name," image format data with ", $bp,"-bit precision,
and converts it to ", $gb_name," YUV format.

# Arguments

* `image` - Target ", $gb_name," image.
* `rgb` - A slice to load ",$rgb_name, stringify!($bp)," data.
* `rgb_stride` - The stride (components per row) for the ",$rgb_name, stringify!($bp)," plane.
* `range` - Yuv values range.

# Panics

This function panics if the lengths of the planes or the input ",$rgb_name, stringify!($bp)," data are not valid based
on the specified width, height, and strides is provided.")]
        pub fn $method(
            image: &mut YuvPlanarImageMut<$clazz>,
            $rgb_ident: &[$clazz],
            $rgb_stride_ident: u32,
            range: YuvRange,
        ) -> Result<(), YuvError> {
            rgbx_to_gbr_impl::<$clazz, $intermediate, { $px_fmt as u8 }, $bp>(
                image, $rgb_ident, $rgb_stride_ident, range,
            )
        }
    };
}

d_cvn!(
    rgb_to_gbr,
    YuvSourceChannels::Rgb,
    u8,
    8,
    "GBR",
    "RGB",
    rgb,
    rgb_stride,
    i16
);
d_cvn!(
    bgr_to_gbr,
    YuvSourceChannels::Bgr,
    u8,
    8,
    "GBR",
    "BGR",
    bgr,
    bgr_stride,
    i16
);
d_cvn!(
    bgra_to_gbr,
    YuvSourceChannels::Bgra,
    u8,
    8,
    "GBR",
    "BGRA",
    bgra,
    bgra_stride,
    i16
);
d_cvn!(
    rgba_to_gbr,
    YuvSourceChannels::Rgba,
    u8,
    8,
    "GBR",
    "RGBA",
    rgba,
    rgba_stride,
    i16
);
d_cvn!(
    rgb10_to_gb10,
    YuvSourceChannels::Rgb,
    u16,
    10,
    "GB10",
    "RGB",
    rgb10,
    rgb10_stride,
    i16
);
d_cvn!(
    rgba10_to_gb10,
    YuvSourceChannels::Rgba,
    u16,
    10,
    "GB10",
    "RGBA",
    rgba10,
    rgba10_stride,
    i16
);
d_cvn!(
    rgb12_to_gb12,
    YuvSourceChannels::Rgb,
    u16,
    12,
    "GB12",
    "RGB",
    rgb12,
    rgb12_stride,
    i16
);
d_cvn!(
    rgba12_to_gb12,
    YuvSourceChannels::Rgba,
    u16,
    12,
    "GB12",
    "RGBA",
    rgba12,
    rgba12_stride,
    i16
);
d_cvn!(
    rgb14_to_gb14,
    YuvSourceChannels::Rgb,
    u16,
    14,
    "GB14",
    "RGB",
    rgb14,
    rgb14_stride,
    i16
);
d_cvn!(
    rgba14_to_gb14,
    YuvSourceChannels::Rgba,
    u16,
    14,
    "GB14",
    "RGBA",
    rgba14,
    rgba14_stride,
    i16
);
d_cvn!(
    rgb16_to_gb16,
    YuvSourceChannels::Rgb,
    u16,
    16,
    "GB16",
    "RGB",
    rgb16,
    rgb16_stride,
    i32
);
d_cvn!(
    rgba16_to_gb16,
    YuvSourceChannels::Rgba,
    u16,
    16,
    "GB16",
    "RGBA",
    rgba16,
    rgba16_stride,
    i32
);
