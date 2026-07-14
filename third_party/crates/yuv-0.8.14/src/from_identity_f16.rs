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
use crate::numerics::qrshr;
use crate::yuv_error::check_rgba_destination;
use crate::yuv_support::{get_yuv_range, YuvSourceChannels};
use crate::{YuvChromaSubsampling, YuvError, YuvPlanarImage, YuvRange};
use core::f16;
use num_traits::AsPrimitive;
#[cfg(feature = "rayon")]
use rayon::iter::{IndexedParallelIterator, ParallelIterator};
#[cfg(feature = "rayon")]
use rayon::prelude::{ParallelSlice, ParallelSliceMut};
use std::fmt::Debug;
use std::marker::PhantomData;
use std::mem::size_of;
use std::ops::Sub;

trait FullRowHandle<V: Copy + 'static + Sized + Debug + Send + Sync + Default + CastableToF16> {
    unsafe fn process_row(&self, dst: &mut [f16], y_src: &[V], u_src: &[V], v_src: &[V]);
}

trait CastableToF16 {
    fn cast_to_f16<const BIT_DEPTH: usize>(self) -> f16;
}

impl CastableToF16 for u16 {
    fn cast_to_f16<const BIT_DEPTH: usize>(self) -> f16 {
        if BIT_DEPTH == 16 {
            (self as i32) as f16
        } else {
            (self as i16) as f16
        }
    }
}

trait LimitedRowHandle<
    V: Copy + AsPrimitive<J> + 'static + Sized + Debug + Send + Sync,
    J: Copy + Sub<Output = J> + AsPrimitive<i32>,
>
{
    unsafe fn process_row(
        &self,
        dst: &mut [f16],
        y_src: &[V],
        u_src: &[V],
        v_src: &[V],
        y_bias: J,
        y_coef: i16,
    );
}

macro_rules! exec_cv_full {
    ($dst: expr, $y_src: expr, $u_src: expr, $v_src: expr, $cn: expr, $bit_depth: expr) => {
        let max_value = (1 << $bit_depth) - 1;
        let max_value_f16 = 1f32 as f16;
        let rgb_chunks = $dst.chunks_exact_mut($cn.get_channels_count());
        let scale = (1f32 / max_value as f32) as f16;

        for (((&y_src, &u_src), &v_src), rgb_dst) in
            $y_src.iter().zip($u_src).zip($v_src).zip(rgb_chunks)
        {
            rgb_dst[$cn.get_r_channel_offset()] = v_src.cast_to_f16::<$bit_depth>() * scale;
            rgb_dst[$cn.get_g_channel_offset()] = y_src.cast_to_f16::<$bit_depth>() * scale;
            rgb_dst[$cn.get_b_channel_offset()] = u_src.cast_to_f16::<$bit_depth>() * scale;
            if $cn.has_alpha() {
                rgb_dst[$cn.get_a_channel_offset()] = max_value_f16;
            }
        }
    };
}

macro_rules! exec_cv_limited {
    ($dst: expr, $y_src: expr, $u_src: expr, $v_src: expr, $cn: expr, $bit_depth: expr, $y_bias: expr, $y_coef: expr, $precision: expr) => {
        let max_value = (1 << $bit_depth) - 1;
        let max_value_f16 = 1f32 as f16;
        let rgb_chunks = $dst.chunks_exact_mut($cn.get_channels_count());
        let scale = (1f32 / max_value as f32) as f16;

        for (((&y_src, &u_src), &v_src), rgb_dst) in
            $y_src.iter().zip($u_src).zip($v_src).zip(rgb_chunks)
        {
            rgb_dst[$cn.get_r_channel_offset()] =
                qrshr::<$precision, $bit_depth>((v_src.as_() - $y_bias).as_() * $y_coef as i32)
                    as f16
                    * scale;
            rgb_dst[$cn.get_g_channel_offset()] =
                qrshr::<$precision, $bit_depth>((y_src.as_() - $y_bias).as_() * $y_coef as i32)
                    as f16
                    * scale;
            rgb_dst[$cn.get_b_channel_offset()] =
                qrshr::<$precision, $bit_depth>((u_src.as_() - $y_bias).as_() * $y_coef as i32)
                    as f16
                    * scale;
            if $cn.has_alpha() {
                rgb_dst[$cn.get_a_channel_offset()] = max_value_f16;
            }
        }
    };
}

#[derive(Default)]
struct DefaultFullRowHandle<
    V: Copy + 'static + Sized + Debug + Send + Sync + Default + CastableToF16,
    const CHANNELS: u8,
    const BIT_DEPTH: usize,
> {
    _phantom: PhantomData<V>,
}

impl<
        V: Copy + 'static + Sized + Debug + Send + Sync + Default + CastableToF16,
        const CHANNELS: u8,
        const BIT_DEPTH: usize,
    > FullRowHandle<V> for DefaultFullRowHandle<V, CHANNELS, BIT_DEPTH>
{
    unsafe fn process_row(&self, dst: &mut [f16], y_src: &[V], u_src: &[V], v_src: &[V]) {
        let cn: YuvSourceChannels = CHANNELS.into();
        exec_cv_full!(dst, y_src, u_src, v_src, cn, BIT_DEPTH);
    }
}

#[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
#[derive(Default)]
struct DefaultFullRowHandleNeonFp16<
    V: Copy + 'static + Sized + Debug + Send + Sync + Default + CastableToF16,
    const CHANNELS: u8,
    const BIT_DEPTH: usize,
> {
    _phantom: PhantomData<V>,
}

#[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
impl<
        V: Copy + 'static + Sized + Debug + Send + Sync + Default + CastableToF16,
        const CHANNELS: u8,
        const BIT_DEPTH: usize,
    > FullRowHandle<V> for DefaultFullRowHandleNeonFp16<V, CHANNELS, BIT_DEPTH>
{
    #[target_feature(enable = "fp16")]
    unsafe fn process_row(&self, dst: &mut [f16], y_src: &[V], u_src: &[V], v_src: &[V]) {
        let cn: YuvSourceChannels = CHANNELS.into();
        exec_cv_full!(dst, y_src, u_src, v_src, cn, BIT_DEPTH);
    }
}

#[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "avx"))]
#[derive(Default)]
struct DefaultFullRowHandleAvxFp16c<
    V: Copy + 'static + Sized + Debug + Send + Sync + Default + CastableToF16,
    const CHANNELS: u8,
    const BIT_DEPTH: usize,
> {
    _phantom: PhantomData<V>,
}

#[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "avx"))]
impl<
        V: Copy + 'static + Sized + Debug + Send + Sync + Default + CastableToF16,
        const CHANNELS: u8,
        const BIT_DEPTH: usize,
    > FullRowHandle<V> for DefaultFullRowHandleAvxFp16c<V, CHANNELS, BIT_DEPTH>
{
    #[target_feature(enable = "avx2", enable = "f16c")]
    unsafe fn process_row(&self, dst: &mut [f16], y_src: &[V], u_src: &[V], v_src: &[V]) {
        let cn: YuvSourceChannels = CHANNELS.into();
        exec_cv_full!(dst, y_src, u_src, v_src, cn, BIT_DEPTH);
    }
}

#[derive(Default)]
struct DefaultLimitedRowHandle<
    V: Copy + AsPrimitive<J> + 'static + Sized + Debug + Send + Sync + Default,
    J: Copy + Sub<Output = J> + AsPrimitive<i32> + Default,
    const CHANNELS: u8,
    const BIT_DEPTH: usize,
    const PRECISION: i32,
> {
    _phantom: PhantomData<V>,
    _phantom2: PhantomData<J>,
}

impl<
        V: Copy + AsPrimitive<J> + 'static + Sized + Debug + Send + Sync + Default,
        J: Copy + Sub<Output = J> + AsPrimitive<i32> + Default + Send + Sync,
        const CHANNELS: u8,
        const BIT_DEPTH: usize,
        const PRECISION: i32,
    > LimitedRowHandle<V, J> for DefaultLimitedRowHandle<V, J, CHANNELS, BIT_DEPTH, PRECISION>
{
    unsafe fn process_row(
        &self,
        dst: &mut [f16],
        y_src: &[V],
        u_src: &[V],
        v_src: &[V],
        y_bias: J,
        y_coef: i16,
    ) {
        let cn: YuvSourceChannels = CHANNELS.into();
        exec_cv_limited!(dst, y_src, u_src, v_src, cn, BIT_DEPTH, y_bias, y_coef, PRECISION);
    }
}

#[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
#[derive(Default)]
struct DefaultLimitedRowHandleNeonFp16<
    V: Copy + AsPrimitive<J> + 'static + Sized + Debug + Send + Sync,
    J: Copy + Sub<Output = J> + AsPrimitive<i32> + Default + Send + Sync,
    const CHANNELS: u8,
    const BIT_DEPTH: usize,
    const PRECISION: i32,
> {
    _phantom: PhantomData<V>,
    _phantom2: PhantomData<J>,
}

#[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
impl<
        V: Copy + AsPrimitive<J> + 'static + Sized + Debug + Send + Sync,
        J: Copy + Sub<Output = J> + AsPrimitive<i32> + Default + Send + Sync,
        const CHANNELS: u8,
        const BIT_DEPTH: usize,
        const PRECISION: i32,
    > LimitedRowHandle<V, J>
    for DefaultLimitedRowHandleNeonFp16<V, J, CHANNELS, BIT_DEPTH, PRECISION>
{
    #[target_feature(enable = "fp16")]
    unsafe fn process_row(
        &self,
        dst: &mut [f16],
        y_src: &[V],
        u_src: &[V],
        v_src: &[V],
        y_bias: J,
        y_coef: i16,
    ) {
        let cn: YuvSourceChannels = CHANNELS.into();
        exec_cv_limited!(dst, y_src, u_src, v_src, cn, BIT_DEPTH, y_bias, y_coef, PRECISION);
    }
}

#[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "avx"))]
#[derive(Default)]
struct DefaultLimitedRowHandleAvxFp16c<
    V: Copy + AsPrimitive<J> + 'static + Sized + Debug + Send + Sync,
    J: Copy + Sub<Output = J> + AsPrimitive<i32> + Default + Send + Sync,
    const CHANNELS: u8,
    const BIT_DEPTH: usize,
    const PRECISION: i32,
> {
    _phantom: PhantomData<V>,
    _phantom2: PhantomData<J>,
}

#[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "avx"))]
impl<
        V: Copy + AsPrimitive<J> + 'static + Sized + Debug + Send + Sync,
        J: Copy + Sub<Output = J> + AsPrimitive<i32> + Default + Send + Sync,
        const CHANNELS: u8,
        const BIT_DEPTH: usize,
        const PRECISION: i32,
    > LimitedRowHandle<V, J>
    for DefaultLimitedRowHandleAvxFp16c<V, J, CHANNELS, BIT_DEPTH, PRECISION>
{
    #[target_feature(enable = "avx2", enable = "f16c")]
    unsafe fn process_row(
        &self,
        dst: &mut [f16],
        y_src: &[V],
        u_src: &[V],
        v_src: &[V],
        y_bias: J,
        y_coef: i16,
    ) {
        let cn: YuvSourceChannels = CHANNELS.into();
        exec_cv_limited!(dst, y_src, u_src, v_src, cn, BIT_DEPTH, y_bias, y_coef, PRECISION);
    }
}

#[inline]
fn gbr_to_rgbx_f16_impl<
    V: Copy + AsPrimitive<J> + 'static + Sized + Debug + Send + Sync + Default + CastableToF16,
    J: Copy + Sub<Output = J> + AsPrimitive<i32> + Default + Send + Sync,
    const CHANNELS: u8,
    const BIT_DEPTH: usize,
>(
    image: &YuvPlanarImage<V>,
    rgba: &mut [f16],
    rgba_stride: u32,
    yuv_range: YuvRange,
) -> Result<(), YuvError>
where
    u32: AsPrimitive<J>,
{
    let cn: YuvSourceChannels = CHANNELS.into();
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
    let y_plane = image.y_plane;
    let u_plane = image.u_plane;
    let v_plane = image.v_plane;
    let y_stride = image.y_stride as usize;
    let u_stride = image.u_stride as usize;
    let v_stride = image.v_stride as usize;
    let height = image.height;

    image.check_constraints(YuvChromaSubsampling::Yuv444)?;
    check_rgba_destination(rgba, rgba_stride, image.width, height, channels)?;

    let y_iter;
    let rgb_iter;
    let u_iter;
    let v_iter;

    #[cfg(feature = "rayon")]
    {
        y_iter = y_plane.par_chunks_exact(y_stride);
        rgb_iter = rgba.par_chunks_exact_mut(rgba_stride as usize);
        u_iter = u_plane.par_chunks_exact(u_stride);
        v_iter = v_plane.par_chunks_exact(v_stride);
    }
    #[cfg(not(feature = "rayon"))]
    {
        y_iter = y_plane.chunks_exact(y_stride);
        rgb_iter = rgba.chunks_exact_mut(rgba_stride as usize);
        u_iter = u_plane.chunks_exact(u_stride);
        v_iter = v_plane.chunks_exact(v_stride);
    }

    match yuv_range {
        YuvRange::Limited => {
            const PRECISION: i32 = 13;
            // All channels on identity should use Y range
            let range = get_yuv_range(BIT_DEPTH as u32, yuv_range);
            let range_rgba = (1 << BIT_DEPTH) - 1;
            let y_coef =
                ((range_rgba as f32 / range.range_y as f32) * (1 << PRECISION) as f32) as i16;
            let y_bias = range.bias_y.as_();

            let iter = y_iter.zip(u_iter).zip(v_iter).zip(rgb_iter);

            iter.for_each(|(((y_src, u_src), v_src), rgb)| {
                let y_src = &y_src[..image.width as usize];
                let mut _row_processor: Box<dyn LimitedRowHandle<V, J> + Send + Sync> =
                    Box::new(DefaultLimitedRowHandle::<
                        V,
                        J,
                        CHANNELS,
                        BIT_DEPTH,
                        PRECISION,
                    >::default());

                #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
                if std::arch::is_aarch64_feature_detected!("fp16") {
                    _row_processor = Box::new(DefaultLimitedRowHandleNeonFp16::<
                        V,
                        J,
                        CHANNELS,
                        BIT_DEPTH,
                        PRECISION,
                    >::default());
                }

                #[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "avx"))]
                {
                    if std::arch::is_x86_feature_detected!("avx2")
                        && std::arch::is_x86_feature_detected!("f16c")
                    {
                        _row_processor = Box::new(DefaultLimitedRowHandleAvxFp16c::<
                            V,
                            J,
                            CHANNELS,
                            BIT_DEPTH,
                            PRECISION,
                        >::default());
                    }
                }

                unsafe {
                    _row_processor.process_row(rgb, y_src, u_src, v_src, y_bias, y_coef);
                }
            });
        }
        YuvRange::Full => {
            let iter = y_iter.zip(u_iter).zip(v_iter).zip(rgb_iter);

            let mut _row_processor: Box<dyn FullRowHandle<V> + Send + Sync> =
                Box::new(DefaultFullRowHandle::<V, CHANNELS, BIT_DEPTH>::default());

            #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
            if std::arch::is_aarch64_feature_detected!("fp16") {
                _row_processor =
                    Box::new(DefaultFullRowHandleNeonFp16::<V, CHANNELS, BIT_DEPTH>::default());
            }

            #[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "avx"))]
            {
                if std::arch::is_x86_feature_detected!("avx2")
                    && std::arch::is_x86_feature_detected!("f16c")
                {
                    _row_processor =
                        Box::new(DefaultFullRowHandleAvxFp16c::<V, CHANNELS, BIT_DEPTH>::default());
                }
            }

            iter.for_each(|(((y_src, u_src), v_src), rgb)| {
                let y_src = &y_src[..image.width as usize];
                unsafe {
                    _row_processor.process_row(rgb, y_src, u_src, v_src);
                }
            });
        }
    }

    Ok(())
}

macro_rules! d_cv {
    ($method: ident, $px_fmt: expr, $bit_depth: expr, $rgb_name: expr, $dst_name: ident, $stride_name: ident, $tr: ident) => {
        #[doc = concat!("Convert GBR", $bit_depth," to ", $rgb_name,"F16, IEEE float16 format.

This function takes GBR planar format data with ", stringify!($bit_depth) ," bit precision,
and converts it to ", $rgb_name,"F16 IEEE float16 format.

# Arguments

* `image` - Source GB", stringify!($bit_depth)," image.
* `", stringify!($dst_name),"` - A slice to store the ",$rgb_name,"F16 data.
* `", stringify!($stride_name), "` - The stride (components per row) for the ", $rgb_name,"F16.
* `range` - YUV values range.

# Panics

This function panics if the lengths of the planes or the input ",$rgb_name," data are not valid based
on the specified width, height, and strides is provided.")]
        pub fn $method(
            image: &YuvPlanarImage<u16>,
            $dst_name: &mut [f16],
            $stride_name: u32,
            range: YuvRange,
        ) -> Result<(), YuvError> {
            gbr_to_rgbx_f16_impl::<u16, $tr, { $px_fmt as u8 }, $bit_depth>(
                image, $dst_name, $stride_name, range,
            )
        }
    };
}

d_cv!(
    gb10_to_rgba_f16,
    YuvSourceChannels::Rgba,
    10,
    "RGBA",
    rgba,
    rgba_stride,
    i16
);
d_cv!(
    gb12_to_rgba_f16,
    YuvSourceChannels::Rgba,
    12,
    "RGBA",
    rgba,
    rgba_stride,
    i16
);
d_cv!(
    gb14_to_rgba_f16,
    YuvSourceChannels::Rgba,
    14,
    "RGBA",
    rgba,
    rgba_stride,
    i16
);
d_cv!(
    gb16_to_rgba_f16,
    YuvSourceChannels::Rgba,
    16,
    "RGBA",
    rgba,
    rgba_stride,
    i32
);

d_cv!(
    gb10_to_rgb_f16,
    YuvSourceChannels::Rgb,
    10,
    "RGB",
    rgb,
    rgb_stride,
    i16
);
d_cv!(
    gb12_to_rgb_f16,
    YuvSourceChannels::Rgb,
    12,
    "RGB",
    rgb,
    rgb_stride,
    i16
);
d_cv!(
    gb14_to_rgb_f16,
    YuvSourceChannels::Rgb,
    14,
    "RGB",
    rgb,
    rgb_stride,
    i16
);
d_cv!(
    gb16_to_rgb_f16,
    YuvSourceChannels::Rgb,
    16,
    "RGB",
    rgb,
    rgb_stride,
    i32
);
