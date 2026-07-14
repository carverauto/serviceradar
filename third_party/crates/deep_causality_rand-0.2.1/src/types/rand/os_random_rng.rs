/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

#[cfg(feature = "os-random")]
use crate::errors::rng_error::RngError;
#[cfg(feature = "os-random")]
use crate::traits::rng::Rng; // Import RngCore

// Conditional import of the getrandom functions
#[cfg(feature = "os-random")]
use crate::traits::rng_core::RngCore;
#[cfg(all(feature = "os-random", not(target_arch = "wasm32")))]
use getrandom::{u32 as getrandom_u32, u64 as getrandom_u64};
// Removed Error as GetRandomError

#[cfg(feature = "os-random")]
pub struct OsRandomRng {
    // No internal state needed for OS random number generator
}

#[cfg(feature = "os-random")]
impl OsRandomRng {
    pub fn new() -> Result<Self, RngError> {
        Ok(OsRandomRng {})
    }
}

#[cfg(feature = "os-random")]
impl RngCore for OsRandomRng {
    fn next_u32(&mut self) -> u32 {
        #[cfg(all(feature = "os-random", not(target_arch = "wasm32")))]
        {
            match getrandom_u32() {
                Ok(val) => val,
                Err(e) => panic!("Failed to get random u32 from OS: {}", e),
            }
        }
        #[cfg(any(not(feature = "os-random"), target_arch = "wasm32"))]
        {
            panic!("OsRandomRng::next_u32 called without os-random feature or on wasm32 target");
        }
    }

    fn next_u64(&mut self) -> u64 {
        #[cfg(all(feature = "os-random", not(target_arch = "wasm32")))]
        {
            match getrandom_u64() {
                Ok(val) => val,
                Err(e) => panic!("Failed to get random u64 from OS: {}", e),
            }
        }
        #[cfg(any(not(feature = "os-random"), target_arch = "wasm32"))]
        {
            panic!("OsRandomRng::next_u64 called without os-random feature or on wasm32 target");
        }
    }

    // Removed fill_bytes implementation b/c its marked and safe and instead
    // rely on default RngCore implementation
}

#[cfg(feature = "os-random")]
impl Rng for OsRandomRng {}
