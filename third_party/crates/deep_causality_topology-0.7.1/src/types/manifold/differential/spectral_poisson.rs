/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! The spectral grade-0 Poisson solve on fully periodic lattices.
//!
//! On a flat torus the discrete Laplacian `Δ₀ = M₀⁻¹ ∂₁ M₁ ∂₁ᵀ` is a
//! convolution, so the DFT diagonalizes it exactly with eigenvalues
//!
//! ```text
//! λ_k = Σ_d (2 − 2·cos(2π·k_d / N_d)) / h_d²
//! ```
//!
//! The solve is a forward real FFT of the right-hand side, a pointwise
//! divide by `λ_k` with the `k = 0` bin zeroed (the spectral expression
//! of the mean-subtraction gauge fix), and an inverse real FFT —
//! O(N log N), exact to rounding, with no tolerance, iteration budget,
//! or convergence-failure mode. `solve_laplacian` dispatches here for
//! grade 0 when the complex reports a fully periodic uniform lattice
//! and the metric reports per-axis Euclidean spacings; everything else
//! stays on CG.
//!
//! Lattice vertex indexing is axis-0-fastest (see
//! `LatticeComplex::cell_index`), so the FFT runs over the *reversed*
//! shape: lattice axis `d` is FFT axis `D−1−d`, and axis 0 is the
//! contiguous rFFT axis.
//!
//! Plan construction per solve is deliberate: for solver-relevant axis
//! lengths the per-axis twiddle tables are tiny and construction
//! measures at ~1% of one transform, far below the CG solve this path
//! replaces. The eigenvalues are combined on the fly from per-axis
//! weight tables (`Σ N_d` entries), never materialized as a full
//! `O(N)` table.

use deep_causality_algebra::RealField;
use deep_causality_fft::RfftPlanNd;
use deep_causality_num::FromPrimitive;
use deep_causality_num_complex::Complex;
use deep_causality_par::MaybeParallel;

use crate::errors::topology_error::TopologyError;

/// Solve `Δ₀ φ = rhs` spectrally on a fully periodic uniform lattice.
///
/// `shape` and `spacings` are in lattice axis order (axis 0 fastest in
/// memory); `rhs` is vertex-indexed. The returned potential has zero
/// mean by construction.
pub(super) fn spectral_poisson_solve<R>(
    shape: &[usize],
    spacings: &[R],
    rhs: &[R],
) -> Result<Vec<R>, TopologyError>
where
    R: RealField + MaybeParallel + FromPrimitive,
{
    let to_topo = |e: deep_causality_fft::FftError| {
        TopologyError::InvalidInput(format!("spectral Poisson solve: {e}"))
    };

    // Lattice axis 0 varies fastest, so the FFT sees the reversed shape.
    let fft_shape: Vec<usize> = shape.iter().rev().copied().collect();
    let plan = RfftPlanNd::<R>::new(&fft_shape).map_err(to_topo)?;

    let czero = Complex::new(R::zero(), R::zero());
    let mut spectrum = vec![czero; plan.spectrum_len()];
    let mut scratch = vec![czero; plan.scratch_len()];
    plan.execute(rhs, &mut spectrum, &mut scratch)
        .map_err(to_topo)?;

    // Per-FFT-axis weight tables w_a[j] = (2 − 2·cos(2π·j/N)) / h²,
    // where FFT axis `a` is lattice axis `D−1−a`. The half-spectrum axis
    // (the last) only carries j = 0..=N/2 bins.
    let spec_shape = plan.spectrum_shape().to_vec();
    let d = spec_shape.len();
    let two_pi = R::pi() + R::pi();
    let two = R::one() + R::one();
    let mut weights: Vec<Vec<R>> = Vec::with_capacity(d);
    for (a, &bins) in spec_shape.iter().enumerate() {
        let lattice_axis = d - 1 - a;
        let n = fft_shape[a];
        let h = spacings[lattice_axis];
        let h2 = h * h;
        let nr = <R as FromPrimitive>::from_usize(n).expect("axis length is representable");
        let table: Vec<R> = (0..bins)
            .map(|j| {
                let jr = <R as FromPrimitive>::from_usize(j).expect("bin index is representable");
                let theta = two_pi * jr / nr;
                (two - two * theta.cos()) / h2
            })
            .collect();
        weights.push(table);
    }

    // Pointwise divide with a multi-index walk (last axis fastest). The
    // zero mode is the gauge: φ̂_0 = 0 ⇔ mean-free potential.
    let mut idx = vec![0usize; d];
    for z in spectrum.iter_mut() {
        let is_zero_mode = idx.iter().all(|&i| i == 0);
        if is_zero_mode {
            *z = czero;
        } else {
            let mut lambda = R::zero();
            for (a, &i) in idx.iter().enumerate() {
                lambda += weights[a][i];
            }
            let inv = R::one() / lambda;
            *z = Complex::new(z.re * inv, z.im * inv);
        }
        // Odometer increment, last axis fastest.
        for a in (0..d).rev() {
            idx[a] += 1;
            if idx[a] < spec_shape[a] {
                break;
            }
            idx[a] = 0;
        }
    }

    let mut phi = vec![R::zero(); rhs.len()];
    plan.execute_inverse(&mut spectrum, &mut phi, &mut scratch)
        .map_err(to_topo)?;
    Ok(phi)
}
