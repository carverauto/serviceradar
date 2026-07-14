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
use crate::wasm32::utils::{wasm_unpackhi_i8x16, wasm_unpacklo_i8x16};
use std::arch::wasm32::*;

#[inline]
pub(crate) unsafe fn v128_deinterleave_u8_x2(a: v128, b: v128) -> (v128, v128) {
    let x0 = u8x16_shuffle::<0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30>(a, b);
    let x1 = u8x16_shuffle::<1, 3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 23, 25, 27, 29, 31>(a, b);
    (x0, x1)
}

#[inline]
pub(crate) unsafe fn v128_load_deinterleave_u8_x2(ptr: *const u8) -> (v128, v128) {
    let a = v128_load(ptr as *const v128);
    let b = v128_load(ptr.add(16) as *const v128);
    v128_deinterleave_u8_x2(a, b)
}

#[inline]
pub(crate) unsafe fn v128_load_deinterleave_half_u8_x2(ptr: *const u8) -> (v128, v128) {
    let a = v128_load(ptr as *const v128);
    v128_deinterleave_u8_x2(a, u8x16_splat(0))
}

#[inline]
pub(crate) unsafe fn wasm_store_interleave_u8x4(ptr: *mut u8, packed: (v128, v128, v128, v128)) {
    let a = packed.0;
    let b = packed.1;
    let c = packed.2;
    let d = packed.3;
    // a0 a1 a2 a3 ....
    // b0 b1 b2 b3 ....
    // c0 c1 c2 c3 ....
    // d0 d1 d2 d3 ....
    let u0 = wasm_unpacklo_i8x16(a, c); // a0 c0 a1 c1 ...
    let u1 = wasm_unpackhi_i8x16(a, c); // a8 c8 a9 c9 ...
    let u2 = wasm_unpacklo_i8x16(b, d); // b0 d0 b1 d1 ...
    let u3 = wasm_unpackhi_i8x16(b, d); // b8 d8 b9 d9 ...

    let v0 = wasm_unpacklo_i8x16(u0, u2); // a0 b0 c0 d0 ...
    let v1 = wasm_unpackhi_i8x16(u0, u2); // a4 b4 c4 d4 ...
    let v2 = wasm_unpacklo_i8x16(u1, u3); // a8 b8 c8 d8 ...
    let v3 = wasm_unpackhi_i8x16(u1, u3); // a12 b12 c12 d12 ...

    v128_store(ptr as *mut v128, v0);
    v128_store(ptr.add(16) as *mut v128, v1);
    v128_store(ptr.add(32) as *mut v128, v2);
    v128_store(ptr.add(48) as *mut v128, v3);
}

#[inline]
pub(crate) unsafe fn wasm_store_interleave_u8x3(ptr: *mut u8, packed: (v128, v128, v128)) {
    let a = packed.0;
    let b = packed.1;
    let c = packed.2;
    let t00 = u8x16_shuffle::<0, 16, 0, 1, 17, 0, 2, 18, 0, 3, 19, 0, 4, 20, 0, 5>(a, b);
    let t01 = u8x16_shuffle::<21, 0, 6, 22, 0, 7, 23, 0, 8, 24, 0, 9, 25, 0, 10, 26>(a, b);
    let t02 = u8x16_shuffle::<0, 11, 27, 0, 12, 28, 0, 13, 29, 0, 14, 30, 0, 15, 31, 0>(a, b);

    let t10 = u8x16_shuffle::<0, 1, 16, 3, 4, 17, 6, 7, 18, 9, 10, 19, 12, 13, 20, 15>(t00, c);
    let t11 = u8x16_shuffle::<0, 21, 2, 3, 22, 5, 6, 23, 8, 9, 24, 11, 12, 25, 14, 15>(t01, c);
    let t12 = u8x16_shuffle::<26, 1, 2, 27, 4, 5, 28, 7, 8, 29, 10, 11, 30, 13, 14, 31>(t02, c);

    v128_store(ptr as *mut v128, t10);
    v128_store(ptr.add(16) as *mut v128, t11);
    v128_store(ptr.add(32) as *mut v128, t12);
}
