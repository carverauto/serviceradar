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
#![forbid(unsafe_code)]
use crate::{YuvBytesPacking, YuvEndianness};
use std::ops::Shr;

#[inline(always)]
/// Saturating rounding shift right against bit depth
pub(crate) fn qrshr<const PRECISION: i32, const BIT_DEPTH: usize>(val: i32) -> i32 {
    let rounding: i32 = 1 << (PRECISION - 1);
    let max_value: i32 = (1 << BIT_DEPTH) - 1;
    ((val + rounding) >> PRECISION).min(max_value).max(0)
}

#[inline]
/// Integer division by 255 with rounding to nearest
pub(crate) fn div_by_255(v: u16) -> u8 {
    ((((v + 0x80) >> 8) + v + 0x80) >> 8) as u8
}

#[inline(always)]
/// Converts to MSB, if needed, and also to big endian
pub(crate) fn to_ne<const ENDIANNESS: u8, const BYTES_POSITION: u8>(v: u16, msb: i32) -> u16 {
    let endianness: YuvEndianness = ENDIANNESS.into();
    let bytes_position: YuvBytesPacking = BYTES_POSITION.into();
    let new_v = match endianness {
        #[cfg(feature = "big_endian")]
        YuvEndianness::BigEndian => u16::from_be(v),
        YuvEndianness::LittleEndian => u16::from_le(v),
    };
    match bytes_position {
        YuvBytesPacking::MostSignificantBytes => new_v.shr(msb),
        YuvBytesPacking::LeastSignificantBytes => new_v,
    }
}

#[inline(always)]
/// Saturating rounding shift right against bit depth
pub(crate) fn qrshr_n<const PRECISION: i32>(val: i32, max: i32) -> i32 {
    let rounding: i32 = 1 << (PRECISION - 1);
    ((val + rounding) >> PRECISION).min(max).max(0)
}
