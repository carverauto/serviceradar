/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::traits::rng::Rng;
use crate::traits::rng_core::RngCore;

// Xoshiro256 prng
pub struct Xoshiro256 {
    s: [u64; 4],
}

impl Default for Xoshiro256 {
    fn default() -> Self {
        Self::new()
    }
}

impl Xoshiro256 {
    pub fn new() -> Self {
        use std::collections::hash_map::RandomState;
        use std::hash::BuildHasher;
        use std::thread;

        // Base seed for deterministic behavior within a single thread
        let base_seed = 0x736f6d6570736575u64;

        // Combine base seed with thread ID to ensure each thread gets a unique seed
        let hash_builder = RandomState::new();
        let thread_component = hash_builder.hash_one(thread::current().id());

        Self::from_seed(base_seed.wrapping_add(thread_component))
    }

    /// Creates a generator from an explicit 64-bit seed.
    ///
    /// The seed is expanded into the four-word state with SplitMix64 (the same
    /// expansion [`Xoshiro256::new`] applies to its thread-derived seed). Two
    /// generators built from the same seed produce identical streams, so this is
    /// the constructor to use when a run must be reproducible.
    pub fn from_seed(seed: u64) -> Self {
        let mut sm_state = seed;

        let mut s = [0; 4];
        for item in &mut s {
            // Seeding with SplitMix64
            sm_state = sm_state.wrapping_add(0x9E3779B97F4A7C15);
            let mut z = sm_state;
            z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
            *item = z ^ (z >> 31);
        }
        Xoshiro256 { s }
    }
}

impl RngCore for Xoshiro256 {
    fn next_u32(&mut self) -> u32 {
        (self.next_u64() >> 32) as u32
    }

    fn next_u64(&mut self) -> u64 {
        let result = self.s[1].wrapping_mul(5).rotate_left(7).wrapping_mul(9);
        let t = self.s[1] << 17;

        self.s[2] ^= self.s[0];
        self.s[3] ^= self.s[1];
        self.s[1] ^= self.s[2];
        self.s[0] ^= self.s[3];

        self.s[2] ^= t;
        self.s[3] = self.s[3].rotate_left(45);

        result
    }

    fn fill_bytes(&mut self, dst: &mut [u8]) {
        for chunk in dst.chunks_mut(8) {
            let val = self.next_u64();
            chunk.copy_from_slice(&val.to_ne_bytes()[..chunk.len()]);
        }
    }
}

impl Rng for Xoshiro256 {}
