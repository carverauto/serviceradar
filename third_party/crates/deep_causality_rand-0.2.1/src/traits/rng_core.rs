/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::ops::DerefMut;

pub trait RngCore {
    fn next_u32(&mut self) -> u32 {
        (self.next_u64() >> 32) as u32
    }

    fn next_u64(&mut self) -> u64;

    fn fill_bytes(&mut self, dst: &mut [u8]) {
        for chunk in dst.chunks_mut(8) {
            let val = self.next_u64();
            chunk.copy_from_slice(&val.to_ne_bytes()[..chunk.len()]);
        }
    }
}

impl<T: DerefMut> RngCore for T
where
    T::Target: RngCore,
{
    #[inline]
    fn next_u32(&mut self) -> u32 {
        self.deref_mut().next_u32()
    }

    #[inline]
    fn next_u64(&mut self) -> u64 {
        self.deref_mut().next_u64()
    }

    #[inline]
    fn fill_bytes(&mut self, dst: &mut [u8]) {
        self.deref_mut().fill_bytes(dst);
    }
}
