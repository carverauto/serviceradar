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
use crate::numerics::{qrshr, to_ne};
use crate::yuv_error::check_rgba_destination;
use crate::yuv_support::{
    get_yuv_range, search_inverse_transform, Rgb30, YuvBytesPacking, YuvChromaSubsampling,
    YuvEndianness, YuvRange, YuvStandardMatrix,
};
use crate::{Rgb30ByteOrder, YuvError, YuvPlanarImage};
#[cfg(feature = "rayon")]
use rayon::iter::{IndexedParallelIterator, ParallelIterator};
#[cfg(feature = "rayon")]
use rayon::prelude::{ParallelSlice, ParallelSliceMut};

fn yuv_p16_to_image_ar30<
    const AR30_LAYOUT: usize,
    const AR30_STORE: usize,
    const SAMPLING: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const BIT_DEPTH: usize,
>(
    image: &YuvPlanarImage<u16>,
    rgba: &mut [u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    let ar30_layout: Rgb30 = AR30_LAYOUT.into();

    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    let chroma_range = get_yuv_range(BIT_DEPTH as u32, range);

    image.check_constraints(chroma_subsampling)?;
    check_rgba_destination(rgba, rgba_stride, image.width, image.height, 4)?;

    let kr_kb = matrix.get_kr_kb();
    const AR30_DEPTH: usize = 10;
    const PRECISION: i32 = 14;
    let i_transform = search_inverse_transform(
        PRECISION,
        BIT_DEPTH as u32,
        range,
        matrix,
        chroma_range,
        kr_kb,
    );
    let cr_coef = i_transform.cr_coef;
    let cb_coef = i_transform.cb_coef;
    let y_coef = i_transform.y_coef;
    let g_coef_1 = i_transform.g_coeff_1;
    let g_coef_2 = i_transform.g_coeff_2;

    let bias_y = chroma_range.bias_y as i32;
    let bias_uv = chroma_range.bias_uv as i32;

    let msb_shift = (16 - BIT_DEPTH) as i32;

    let process_halved_chroma_row = |y_plane: &[u16],
                                     u_plane: &[u16],
                                     v_plane: &[u16],
                                     rgba: &mut [u8]| {
        for (((rgba, y_src), &u_src), &v_src) in rgba
            .chunks_exact_mut(2 * 4)
            .zip(y_plane.chunks_exact(2))
            .zip(u_plane.iter())
            .zip(v_plane.iter())
        {
            let y_value0 =
                (to_ne::<ENDIANNESS, BYTES_POSITION>(y_src[0], msb_shift) as i32 - bias_y) * y_coef;
            let cb_value = to_ne::<ENDIANNESS, BYTES_POSITION>(u_src, msb_shift) as i32 - bias_uv;
            let cr_value = to_ne::<ENDIANNESS, BYTES_POSITION>(v_src, msb_shift) as i32 - bias_uv;

            let r0 = qrshr::<PRECISION, AR30_DEPTH>(y_value0 + cr_coef * cr_value);
            let b0 = qrshr::<PRECISION, AR30_DEPTH>(y_value0 + cb_coef * cb_value);
            let g0 = qrshr::<PRECISION, AR30_DEPTH>(
                y_value0 - g_coef_1 * cr_value - g_coef_2 * cb_value,
            );

            let rgba_2 = &mut rgba[..8];

            let pixel0 = ar30_layout.pack::<AR30_STORE>(r0, g0, b0).to_ne_bytes();
            rgba_2[0] = pixel0[0];
            rgba_2[1] = pixel0[1];
            rgba_2[2] = pixel0[2];
            rgba_2[3] = pixel0[3];

            let y_value1 =
                (to_ne::<ENDIANNESS, BYTES_POSITION>(y_src[1], msb_shift) as i32 - bias_y) * y_coef;

            let r1 = qrshr::<PRECISION, BIT_DEPTH>(y_value1 + cr_coef * cr_value);
            let b1 = qrshr::<PRECISION, BIT_DEPTH>(y_value1 + cb_coef * cb_value);
            let g1 =
                qrshr::<PRECISION, BIT_DEPTH>(y_value1 - g_coef_1 * cr_value - g_coef_2 * cb_value);

            let pixel1 = ar30_layout.pack::<AR30_STORE>(r1, g1, b1).to_ne_bytes();
            rgba_2[4] = pixel1[0];
            rgba_2[5] = pixel1[1];
            rgba_2[6] = pixel1[2];
            rgba_2[7] = pixel1[3];
        }

        if image.width & 1 != 0 {
            let y_value0 = (to_ne::<ENDIANNESS, BYTES_POSITION>(*y_plane.last().unwrap(), msb_shift)
                as i32
                - bias_y)
                * y_coef;
            let cb_value = to_ne::<ENDIANNESS, BYTES_POSITION>(*u_plane.last().unwrap(), msb_shift)
                as i32
                - bias_uv;
            let cr_value = to_ne::<ENDIANNESS, BYTES_POSITION>(*v_plane.last().unwrap(), msb_shift)
                as i32
                - bias_uv;
            let rgba = rgba.chunks_exact_mut(4).last().unwrap();

            let r0 = qrshr::<PRECISION, BIT_DEPTH>(y_value0 + cr_coef * cr_value);
            let b0 = qrshr::<PRECISION, BIT_DEPTH>(y_value0 + cb_coef * cb_value);
            let g0 =
                qrshr::<PRECISION, BIT_DEPTH>(y_value0 - g_coef_1 * cr_value - g_coef_2 * cb_value);
            let pixel0 = ar30_layout.pack::<AR30_STORE>(r0, g0, b0).to_ne_bytes();
            rgba[0] = pixel0[0];
            rgba[1] = pixel0[1];
            rgba[2] = pixel0[2];
            rgba[3] = pixel0[3];
        }
    };

    if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = rgba
                .par_chunks_exact_mut(rgba_stride as usize)
                .zip(image.y_plane.par_chunks_exact(image.y_stride as usize))
                .zip(image.u_plane.par_chunks_exact(image.u_stride as usize))
                .zip(image.v_plane.par_chunks_exact(image.v_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = rgba
                .chunks_exact_mut(rgba_stride as usize)
                .zip(image.y_plane.chunks_exact(image.y_stride as usize))
                .zip(image.u_plane.chunks_exact(image.u_stride as usize))
                .zip(image.v_plane.chunks_exact(image.v_stride as usize));
        }
        iter.for_each(|(((rgba, y_plane), u_plane), v_plane)| {
            for (((rgba, &y_src), &u_src), &v_src) in rgba
                .chunks_exact_mut(4)
                .zip(y_plane.iter())
                .zip(u_plane.iter())
                .zip(v_plane.iter())
            {
                let y_value = (to_ne::<ENDIANNESS, BYTES_POSITION>(y_src, msb_shift) as i32
                    - bias_y)
                    * y_coef;
                let cb_value =
                    to_ne::<ENDIANNESS, BYTES_POSITION>(u_src, msb_shift) as i32 - bias_uv;
                let cr_value =
                    to_ne::<ENDIANNESS, BYTES_POSITION>(v_src, msb_shift) as i32 - bias_uv;

                let r = qrshr::<PRECISION, BIT_DEPTH>(y_value + cr_coef * cr_value);
                let b = qrshr::<PRECISION, BIT_DEPTH>(y_value + cb_coef * cb_value);
                let g = qrshr::<PRECISION, BIT_DEPTH>(
                    y_value - g_coef_1 * cr_value - g_coef_2 * cb_value,
                );

                let pixel0 = ar30_layout.pack::<AR30_STORE>(r, g, b).to_ne_bytes();
                rgba[0] = pixel0[0];
                rgba[1] = pixel0[1];
                rgba[2] = pixel0[2];
                rgba[3] = pixel0[3];
            }
        });
    } else if chroma_subsampling == YuvChromaSubsampling::Yuv422 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = rgba
                .par_chunks_exact_mut(rgba_stride as usize)
                .zip(image.y_plane.par_chunks_exact(image.y_stride as usize))
                .zip(image.u_plane.par_chunks_exact(image.u_stride as usize))
                .zip(image.v_plane.par_chunks_exact(image.v_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = rgba
                .chunks_exact_mut(rgba_stride as usize)
                .zip(image.y_plane.chunks_exact(image.y_stride as usize))
                .zip(image.u_plane.chunks_exact(image.u_stride as usize))
                .zip(image.v_plane.chunks_exact(image.v_stride as usize));
        }
        iter.for_each(|(((rgba, y_plane), u_plane), v_plane)| {
            process_halved_chroma_row(
                &y_plane[..image.width as usize],
                &u_plane[..(image.width as usize).div_ceil(2)],
                &v_plane[..(image.width as usize).div_ceil(2)],
                &mut rgba[..image.width as usize * 4],
            );
        });
    } else if chroma_subsampling == YuvChromaSubsampling::Yuv420 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = rgba
                .par_chunks_exact_mut(rgba_stride as usize * 2)
                .zip(image.y_plane.par_chunks_exact(image.y_stride as usize * 2))
                .zip(image.u_plane.par_chunks_exact(image.u_stride as usize))
                .zip(image.v_plane.par_chunks_exact(image.v_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = rgba
                .chunks_exact_mut(rgba_stride as usize * 2)
                .zip(image.y_plane.chunks_exact(image.y_stride as usize * 2))
                .zip(image.u_plane.chunks_exact(image.u_stride as usize))
                .zip(image.v_plane.chunks_exact(image.v_stride as usize));
        }
        iter.for_each(|(((rgba, y_plane), u_plane), v_plane)| {
            for (rgba, y_plane) in rgba
                .chunks_exact_mut(rgba_stride as usize)
                .zip(y_plane.chunks_exact(image.y_stride as usize))
            {
                process_halved_chroma_row(
                    &y_plane[..image.width as usize],
                    &u_plane[..(image.width as usize).div_ceil(2)],
                    &v_plane[..(image.width as usize).div_ceil(2)],
                    &mut rgba[..image.width as usize * 4],
                );
            }
        });

        if image.height & 1 != 0 {
            let rgba = rgba.chunks_exact_mut(rgba_stride as usize).last().unwrap();
            let u_plane = image
                .u_plane
                .chunks_exact(image.u_stride as usize)
                .last()
                .unwrap();
            let v_plane = image
                .v_plane
                .chunks_exact(image.v_stride as usize)
                .last()
                .unwrap();
            let y_plane = image
                .y_plane
                .chunks_exact(image.y_stride as usize)
                .last()
                .unwrap();
            process_halved_chroma_row(
                &y_plane[..image.width as usize],
                &u_plane[..(image.width as usize).div_ceil(2)],
                &v_plane[..(image.width as usize).div_ceil(2)],
                &mut rgba[..image.width as usize * 4],
            );
        }
    } else {
        unreachable!();
    }

    Ok(())
}

macro_rules! build_cnv {
    ($method: ident, $ar_fmt: expr, $subsampling: expr,
    $bit_depth: expr, $sampling_written: expr,
    $px_written: expr, $px_written_small: expr) => {
        #[doc = concat!("
Convert ",$sampling_written, " planar format with ", $bit_depth," bit pixel format to ", $px_written," format.

This function takes ", $sampling_written, " planar data with ",$bit_depth," bit precision.
and converts it to ", $px_written," format.

# Arguments

* `planar_image` - Source ",$sampling_written," planar image.
* `", $px_written_small, "` - A mutable slice to store the converted ", $px_written," format.
* `", $px_written_small, "_stride` - The stride (components per row) for ", $px_written," format.
* `range` - The YUV range (limited or full).
* `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).

# Panics

This function panics if the lengths of the planes or the input ", $px_written," data are not valid based
on the specified width, height, and strides, or if invalid YUV range or matrix is provided.")]
        pub fn $method(
            planar_image: &YuvPlanarImage<u16>,
            dst: &mut [u8],
            dst_stride: u32,
            byte_order: Rgb30ByteOrder,
            range: YuvRange,
            matrix: YuvStandardMatrix,
        ) -> Result<(), YuvError> {
               match byte_order {
                    Rgb30ByteOrder::Host => yuv_p16_to_image_ar30::<
                        { $ar_fmt as usize },
                        { Rgb30ByteOrder::Host as usize },
                        { $subsampling as u8 },
                        { YuvEndianness::LittleEndian as u8 },
                        { YuvBytesPacking::LeastSignificantBytes as u8 },
                        $bit_depth,
                    >(planar_image, dst, dst_stride, range, matrix),
                    Rgb30ByteOrder::Network => yuv_p16_to_image_ar30::<
                        { $ar_fmt as usize },
                        { Rgb30ByteOrder::Network as usize },
                        { $subsampling as u8 },
                        { YuvEndianness::LittleEndian as u8 },
                        { YuvBytesPacking::LeastSignificantBytes as u8 },
                        $bit_depth,
                    >(planar_image, dst, dst_stride, range, matrix),
            }
        }
    };
}

build_cnv!(
    i010_to_ar30,
    Rgb30::Ar30,
    YuvChromaSubsampling::Yuv420,
    10,
    "I010",
    "AR30",
    "ar30"
);
build_cnv!(
    i012_to_ar30,
    Rgb30::Ar30,
    YuvChromaSubsampling::Yuv420,
    12,
    "I012",
    "AR30",
    "ar30"
);
build_cnv!(
    i014_to_ar30,
    Rgb30::Ar30,
    YuvChromaSubsampling::Yuv420,
    14,
    "I014",
    "AR30",
    "ar30"
);
build_cnv!(
    i010_to_ra30,
    Rgb30::Ra30,
    YuvChromaSubsampling::Yuv420,
    10,
    "I010",
    "RA30",
    "ra30"
);
build_cnv!(
    i012_to_ra30,
    Rgb30::Ra30,
    YuvChromaSubsampling::Yuv420,
    12,
    "I012",
    "RA30",
    "ra30"
);
build_cnv!(
    i014_to_ra30,
    Rgb30::Ra30,
    YuvChromaSubsampling::Yuv420,
    14,
    "I014",
    "RA30",
    "ra30"
);

build_cnv!(
    i210_to_ar30,
    Rgb30::Ar30,
    YuvChromaSubsampling::Yuv422,
    10,
    "I210",
    "AR30",
    "ar30"
);
build_cnv!(
    i212_to_ar30,
    Rgb30::Ar30,
    YuvChromaSubsampling::Yuv422,
    12,
    "I212",
    "AR30",
    "ar30"
);
build_cnv!(
    i214_to_ar30,
    Rgb30::Ar30,
    YuvChromaSubsampling::Yuv422,
    14,
    "I214",
    "AR30",
    "ar30"
);
build_cnv!(
    i210_to_ra30,
    Rgb30::Ra30,
    YuvChromaSubsampling::Yuv422,
    10,
    "I210",
    "RA30",
    "ra30"
);
build_cnv!(
    i212_to_ra30,
    Rgb30::Ra30,
    YuvChromaSubsampling::Yuv422,
    12,
    "I212",
    "RA30",
    "ra30"
);
build_cnv!(
    i214_to_ra30,
    Rgb30::Ra30,
    YuvChromaSubsampling::Yuv422,
    14,
    "I214",
    "RA30",
    "ra30"
);

build_cnv!(
    i410_to_ar30,
    Rgb30::Ar30,
    YuvChromaSubsampling::Yuv444,
    10,
    "I410",
    "AR30",
    "ar30"
);
build_cnv!(
    i412_to_ar30,
    Rgb30::Ar30,
    YuvChromaSubsampling::Yuv444,
    12,
    "I412",
    "AR30",
    "ar30"
);
build_cnv!(
    i414_to_ar30,
    Rgb30::Ar30,
    YuvChromaSubsampling::Yuv444,
    14,
    "I414",
    "AR30",
    "ar30"
);
build_cnv!(
    i410_to_ra30,
    Rgb30::Ra30,
    YuvChromaSubsampling::Yuv444,
    10,
    "I410",
    "RA30",
    "ra30"
);
build_cnv!(
    i412_to_ra30,
    Rgb30::Ra30,
    YuvChromaSubsampling::Yuv444,
    12,
    "I412",
    "RA30",
    "ra30"
);
build_cnv!(
    i414_to_ra30,
    Rgb30::Ra30,
    YuvChromaSubsampling::Yuv444,
    14,
    "I414",
    "RA30",
    "ra30"
);
