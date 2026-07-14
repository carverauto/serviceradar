/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

mod errors;
mod extensions;
mod traits;
pub mod types;
mod utils;

// Errors
pub use crate::errors::bernoulli_error::BernoulliDistributionError;
pub use crate::errors::normal_error::NormalDistributionError;
pub use crate::errors::rng_error::RngError;
pub use crate::errors::uniform_error::UniformDistributionError;
// Extensions

// Traits
pub use crate::traits::distribution::Distribution;
pub use crate::traits::fill::Fill;
pub use crate::traits::real_rng::RealRng;
pub use crate::traits::rng::Rng;
pub use crate::traits::rng_core::RngCore;
pub use crate::traits::sample_borrow::SampleBorrow;
pub use crate::traits::sample_range::SampleRange;
pub use crate::traits::sample_uniform::{SampleUniform, UniformSampler};
// Inverse-CDF transforms
pub use crate::utils::inverse_cdf::{
    bernoulli_inverse_cdf, standard_normal_inverse_cdf, standard_normal_inverse_cdf_f106,
    uniform_inverse_cdf,
};
// Types
pub use crate::types::Xoshiro256;
pub use crate::types::distr::bernoulli::Bernoulli;
pub use crate::types::distr::normal::Normal;
pub use crate::types::distr::normal::standard_normal::StandardNormal;
pub use crate::types::distr::uniform::standard_uniform::StandardUniform;
pub use crate::types::distr::uniform::{Uniform, UniformFloat};
pub use crate::types::iter::Iter;
pub use crate::types::map::Map;
pub use crate::types::qmc::sobol::{MAX_SOBOL_DIM, SobolSequence};
pub use crate::types::range::{Open01, OpenClosed01};

#[cfg(not(feature = "os-random"))]
use std::cell::RefCell;

#[cfg(not(feature = "os-random"))]
thread_local! {
    static THREAD_RNG: RefCell<Xoshiro256> = RefCell::new(Xoshiro256::new());
}

#[cfg(not(feature = "os-random"))]
pub struct ThreadRng;

#[cfg(not(feature = "os-random"))]
impl RngCore for ThreadRng {
    fn next_u32(&mut self) -> u32 {
        THREAD_RNG.with(|rng| rng.borrow_mut().next_u32())
    }
    fn next_u64(&mut self) -> u64 {
        THREAD_RNG.with(|rng| rng.borrow_mut().next_u64())
    }
    fn fill_bytes(&mut self, dest: &mut [u8]) {
        THREAD_RNG.with(|rng| rng.borrow_mut().fill_bytes(dest))
    }
}

#[cfg(not(feature = "os-random"))]
impl Rng for ThreadRng {}

/// Returns a new random number generator.
///
/// By default, this returns a `ThreadRng` backed by `Xoshiro256` PRNG, with each
/// thread getting a unique seed derived from the thread ID.
/// If the `os-random` feature is enabled, it returns an `OsRandomRng` that
/// sources entropy from the operating system.
/// If the `aead-random` feature is enabled, it returns a `ChaCha20Rng` seeded from
/// the OS CSPRNG. This is the preferred secure option.
pub fn rng() -> impl Rng {
    #[cfg(feature = "os-random")]
    {
        #[cfg(feature = "os-random")]
        use crate::types::OsRandomRng;

        OsRandomRng::new().expect("Failed to create OsRandomRng")
    }
    #[cfg(not(feature = "os-random"))]
    {
        ThreadRng
    }
}
