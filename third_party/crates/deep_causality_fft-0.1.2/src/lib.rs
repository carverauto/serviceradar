/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Fast Fourier transforms for the DeepCausality stack.
//!
//! The crate provides plan-based forward and inverse transforms, generic
//! over [`deep_causality_algebra::RealField`] and operating on
//! [`deep_causality_num_complex::Complex`]:
//!
//! * [`FftPlan`] — 1-D complex FFT/inverse FFT for any length.
//! * [`RfftPlan`] — 1-D real-to-complex forward (rFFT) and complex-to-real
//!   inverse (irFFT) with the half-spectrum (Hermitian) layout.
//! * [`FftPlanNd`] / [`RfftPlanNd`] — N-dimensional transforms by
//!   row-column decomposition over the 1-D plans.
//!
//! # Algorithm layering
//!
//! Following the survey in `openspec/notes/fft/fft_state_of_the_art.md`,
//! the planner composes, by length: hardcoded small-N kernels (2–32),
//! an iterative mixed radix-4/radix-2 Stockham pipeline for larger powers
//! of two (regular, auto-vectorizable access, no bit-reversal pass), and
//! Bluestein's chirp-z fallback for everything else, so every length is
//! O(N log N).
//!
//! # Normalization contract
//!
//! The forward transform is unnormalized; the inverse scales by `1/N`.
//! The inverse is conjugation reuse of the forward path
//! (`ifft(x) = conj(fft(conj(x))) / N`), never a separate kernel, so the
//! pair stays consistent by construction: `ifft(fft(x)) = x` to rounding.
//!
//! # Plans and scratch
//!
//! Plans are immutable after construction and hold all precomputed state
//! (twiddles, stage schedules, chirp sequences). Execution borrows a
//! caller-provided scratch buffer of at least [`FftPlan::scratch_len`]
//! elements and performs no heap allocation (the opt-in `parallel`
//! feature allocates per-thread scratch inside parallel sections).

pub mod errors;
pub mod traits;
pub mod types;
pub mod utils;

pub use crate::errors::fft_error::FftError;
pub use crate::traits::fft_scalar::FftScalar;
pub use crate::types::dct_plan::{DctPlan, DctType};
pub use crate::types::fft_plan::FftPlan;
pub use crate::types::fft_plan_nd::FftPlanNd;
pub use crate::types::rfft_plan::RfftPlan;
pub use crate::types::rfft_plan_nd::RfftPlanNd;
pub use crate::utils::dct::{naive_dct_i, naive_dct_ii, naive_dct_iii};
pub use crate::utils::dft::{naive_dft, naive_idft};
