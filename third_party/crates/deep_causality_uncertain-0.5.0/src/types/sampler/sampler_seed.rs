/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Deterministic seeding for the `Uncertain` sampler.
//!
//! `Uncertain`'s Monte-Carlo draws ([`Uncertain::sample`](crate::Uncertain::sample),
//! [`Uncertain::take_samples`](crate::Uncertain), and the presence/collapse gates built on them)
//! default to `deep_causality_rand`'s OS-entropy thread RNG, so a program produces a fresh stream
//! on every run. [`seed_sampler`] installs a seeded `Xoshiro256` for the current thread: every
//! subsequent draw — both the sample-index selection and the distribution draw inside
//! [`SequentialSampler`](crate::SequentialSampler) — is taken from it, so the run is reproducible.
//! [`clear_sampler_seed`] restores the OS-entropy default.
//!
//! The seed is **thread-local**: it governs only the thread that called [`seed_sampler`], matching
//! the per-thread sampling model and avoiding cross-thread interference. The borrow never escapes
//! ([`with_seed_slot`]), mirroring `with_global_cache`.

use deep_causality_rand::Xoshiro256;
use std::cell::RefCell;

thread_local! {
    /// The active seeded RNG for this thread, or `None` for OS-entropy randomness.
    static SAMPLER_SEED: RefCell<Option<Xoshiro256>> = const { RefCell::new(None) };
}

/// Seed the sampler RNG for the current thread with `seed`, making every subsequent `Uncertain`
/// draw on this thread reproducible. Call once before sampling; re-seeding restarts the stream.
pub fn seed_sampler(seed: u64) {
    SAMPLER_SEED.with(|cell| *cell.borrow_mut() = Some(Xoshiro256::from_seed(seed)));
}

/// Clear the sampler seed for the current thread, restoring the OS-entropy thread RNG.
pub fn clear_sampler_seed() {
    SAMPLER_SEED.with(|cell| *cell.borrow_mut() = None);
}

/// Run `closure` against the active sampler RNG slot: `Some(&mut Xoshiro256)` when [`seed_sampler`]
/// is in effect on this thread, otherwise `None` (the caller falls back to a fresh
/// `deep_causality_rand` thread RNG). Encapsulates the thread-local so the borrow never escapes.
pub(crate) fn with_seed_slot<R>(closure: impl FnOnce(Option<&mut Xoshiro256>) -> R) -> R {
    SAMPLER_SEED.with(|cell| closure(cell.borrow_mut().as_mut()))
}

/// Draw a `u64` sample index from the active sampler RNG (seeded when in effect, else the thread
/// RNG). Used to pick reproducible sample indices in [`Uncertain::sample`](crate::Uncertain) and
/// [`Uncertain::take_samples`](crate::Uncertain).
pub(crate) fn next_sample_index() -> u64 {
    use deep_causality_rand::Rng;
    with_seed_slot(|slot| match slot {
        Some(rng) => rng.random::<u64>(),
        None => deep_causality_rand::rng().random::<u64>(),
    })
}
