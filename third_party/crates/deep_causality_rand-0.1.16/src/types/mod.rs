/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

pub mod distr;
pub mod misc;
pub(crate) mod rand;
pub mod range;

#[cfg(feature = "os-random")]
pub use rand::os_random_rng::OsRandomRng;

#[cfg(feature = "aead-random")]
pub use rand::chacha_rng::ChaCha20Rng;

pub use rand::std_rng::Xoshiro256;
