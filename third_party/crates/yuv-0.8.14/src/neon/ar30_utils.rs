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

use crate::yuv_support::Rgb30;
use std::arch::aarch64::*;

#[inline(always)]
pub(crate) unsafe fn vrev128_u32(v: uint32x4_t) -> uint32x4_t {
    vreinterpretq_u32_u8(vrev32q_u8(vreinterpretq_u8_u32(v)))
}

#[inline(always)]
pub(crate) unsafe fn vzipq_4_ar30<const AR30_TYPE: usize, const AR30_ORDER: usize>(
    v: uint16x8x3_t,
) -> uint32x4x2_t {
    let ar_type: Rgb30 = AR30_TYPE.into();
    match ar_type {
        Rgb30::Ar30 | Rgb30::Ab30 => {
            let mut a0 = vdupq_n_u32(3);
            let mut a1 = vdupq_n_u32(3);

            let mut rw0 = vmovl_u16(vget_low_u16(v.2));
            let mut rw1 = vmovl_u16(vget_high_u16(v.2));
            let gw0 = vmovl_u16(vget_low_u16(v.1));
            let gw1 = vmovl_u16(vget_high_u16(v.1));
            let mut bw0 = vmovl_u16(vget_low_u16(v.0));
            let mut bw1 = vmovl_u16(vget_high_u16(v.0));

            if ar_type == Rgb30::Ab30 {
                std::mem::swap(&mut rw0, &mut bw0);
                std::mem::swap(&mut rw1, &mut bw1);
            }

            let r0 = vshlq_n_u32::<20>(rw0);
            let r1 = vshlq_n_u32::<20>(rw1);

            let g0 = vshlq_n_u32::<10>(gw0);
            let g1 = vshlq_n_u32::<10>(gw1);

            a0 = vorrq_u32(a0, r0);
            a1 = vorrq_u32(a1, r1);

            a0 = vorrq_u32(a0, g0);
            a1 = vorrq_u32(a1, g1);

            a0 = vorrq_u32(a0, bw0);
            a1 = vorrq_u32(a1, bw1);

            if AR30_ORDER == 0 {
                uint32x4x2_t(a0, a1)
            } else {
                uint32x4x2_t(vrev128_u32(a0), vrev128_u32(a1))
            }
        }
        Rgb30::Ra30 | Rgb30::Ba30 => {
            let mut a0 = vdupq_n_u32(3 << 30);
            let mut a1 = vdupq_n_u32(3 << 30);

            let mut rw0 = vmovl_u16(vget_low_u16(v.2));
            let mut rw1 = vmovl_u16(vget_high_u16(v.2));
            let gw0 = vmovl_u16(vget_low_u16(v.1));
            let gw1 = vmovl_u16(vget_high_u16(v.1));
            let mut bw0 = vmovl_u16(vget_low_u16(v.0));
            let mut bw1 = vmovl_u16(vget_high_u16(v.0));

            if ar_type == Rgb30::Ba30 {
                std::mem::swap(&mut rw0, &mut bw0);
                std::mem::swap(&mut rw1, &mut bw1);
            }

            let r0 = vshlq_n_u32::<22>(rw0);
            let r1 = vshlq_n_u32::<22>(rw1);

            a0 = vorrq_u32(a0, r0);
            a1 = vorrq_u32(a1, r1);

            let g0 = vshlq_n_u32::<12>(gw0);
            let g1 = vshlq_n_u32::<12>(gw1);

            let b0 = vshlq_n_u32::<2>(bw0);
            let b1 = vshlq_n_u32::<2>(bw1);

            a0 = vorrq_u32(a0, g0);
            a1 = vorrq_u32(a1, g1);

            a0 = vorrq_u32(a0, b0);
            a1 = vorrq_u32(a1, b1);

            if AR30_ORDER == 0 {
                uint32x4x2_t(a0, a1)
            } else {
                uint32x4x2_t(vrev128_u32(a0), vrev128_u32(a1))
            }
        }
    }
}
