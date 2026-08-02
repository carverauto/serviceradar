/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! The direct spectral Neumann–Poisson solve on uniform wall-bounded
//! boxes (the neumann-poisson capability of add-walls-and-dec-stencils).
//!
//! With the boundary-corrected (clipped) Hodge star, the weighted grade-0
//! operator separates per axis, and each wall axis diagonalizes in the
//! **DCT-I** basis: the 1-D walled operator's eigenvectors are
//! `cos(πkj/(N−1))` with eigenvalues `λ_k = (2 − 2·cos(πk/(N−1)))/h²`
//! (the endpoint rows' factor-2 from the halved boundary mass is exactly
//! what makes the cosine modes exact — verified by the
//! residual-at-rounding gate). Periodic axes keep the DFT modes with
//! `λ_k = (2 − 2·cos(2πk/N))/h²`. The Neumann (no-flux) condition is
//! built into the basis; the gauge is the zero mode, zeroed spectrally.
//!
//! All-walls boxes run a pure real DCT-I pipeline; mixtures of periodic
//! and wall axes ride a complex carrier (complex FFT along periodic
//! axes, DCT-I applied independently to real and imaginary parts along
//! wall axes — the DCT is real-linear). Like the torus path, the solve
//! has no tolerance, iteration budget, or convergence-failure mode.
//!
//! Lattice vertex indexing is axis-0-fastest, so the pipelines run over
//! the *reversed* shape (lattice axis `d` is walk axis `D−1−d`).

use deep_causality_algebra::RealField;
use deep_causality_fft::{DctPlan, DctType, FftPlan};
use deep_causality_num::FromPrimitive;
use deep_causality_num_complex::Complex;
use deep_causality_par::MaybeParallel;

use crate::errors::topology_error::TopologyError;

fn to_topo(e: deep_causality_fft::FftError) -> TopologyError {
    TopologyError::InvalidInput(format!("Neumann Poisson solve: {e}"))
}

/// Per-axis eigenvalue table: DFT modes on periodic axes, DCT-I modes on
/// wall axes.
fn axis_weights<R>(n: usize, h: R, is_periodic: bool) -> Vec<R>
where
    R: RealField + FromPrimitive,
{
    let two = R::one() + R::one();
    let two_pi = R::pi() + R::pi();
    let pi = R::pi();
    let h2 = h * h;
    (0..n)
        .map(|j| {
            let jr = <R as FromPrimitive>::from_usize(j).expect("index is representable");
            let theta = if is_periodic {
                let nr = <R as FromPrimitive>::from_usize(n).expect("length is representable");
                two_pi * jr / nr
            } else {
                let mr = <R as FromPrimitive>::from_usize(n - 1).expect("length is representable");
                pi * jr / mr
            };
            (two - two * theta.cos()) / h2
        })
        .collect()
}

/// Walk every line along `axis` of a row-major array, gathering each into
/// a contiguous buffer, transforming, and scattering back.
fn for_each_line<T: Copy>(
    data: &mut [T],
    shape: &[usize],
    axis: usize,
    line: &mut [T],
    mut transform: impl FnMut(&mut [T]),
) {
    let len = shape[axis];
    let inner: usize = shape[axis + 1..].iter().product();
    let block = len * inner;
    for block_slice in data.chunks_exact_mut(block) {
        for r in 0..inner {
            for j in 0..len {
                line[j] = block_slice[j * inner + r];
            }
            transform(line);
            for j in 0..len {
                block_slice[j * inner + r] = line[j];
            }
        }
    }
}

/// Pointwise divide by `λ = Σ_a w_a(k_a)` with the zero mode zeroed.
fn divide_by_eigenvalues<R, T, Scale>(
    data: &mut [T],
    shape: &[usize],
    weights: &[Vec<R>],
    mut scale: Scale,
) where
    R: RealField,
    Scale: FnMut(&mut T, R),
{
    let d = shape.len();
    let mut idx = vec![0usize; d];
    let mut first = true;
    for z in data.iter_mut() {
        if first {
            scale(z, R::zero());
            first = false;
        } else {
            let mut lambda = R::zero();
            for (a, &i) in idx.iter().enumerate() {
                lambda += weights[a][i];
            }
            scale(z, R::one() / lambda);
        }
        for a in (0..d).rev() {
            idx[a] += 1;
            if idx[a] < shape[a] {
                break;
            }
            idx[a] = 0;
        }
    }
}

/// Solve the gauge-fixed grade-0 Neumann–Poisson problem on a uniform
/// box whose axes are each periodic or walled (at least one wall axis;
/// the all-periodic case belongs to the rFFT torus path). `shape`,
/// `periodic`, and `spacings` are in lattice axis order (axis 0 fastest
/// in memory). The returned potential carries the zero-mode gauge.
pub(super) fn neumann_poisson_solve<R>(
    shape: &[usize],
    periodic: &[bool],
    spacings: &[R],
    rhs: &[R],
) -> Result<Vec<R>, TopologyError>
where
    R: RealField + MaybeParallel + FromPrimitive,
{
    let d = shape.len();
    // Walk order: reversed lattice axes (axis 0 fastest in memory ⇒ last
    // walk axis).
    let walk_shape: Vec<usize> = shape.iter().rev().copied().collect();
    let walk_periodic: Vec<bool> = periodic.iter().rev().copied().collect();
    let walk_h: Vec<R> = spacings.iter().rev().copied().collect();

    let weights: Vec<Vec<R>> = (0..d)
        .map(|a| axis_weights(walk_shape[a], walk_h[a], walk_periodic[a]))
        .collect();

    let max_len = walk_shape.iter().copied().max().unwrap_or(1);
    let any_periodic = walk_periodic.iter().any(|&p| p);

    if !any_periodic {
        // Pure real DCT-I pipeline.
        let mut data = rhs.to_vec();
        let mut line = vec![R::zero(); max_len];
        let mut out = vec![R::zero(); max_len];
        let mut plans: Vec<DctPlan<R>> = Vec::with_capacity(d);
        for &n in &walk_shape {
            plans.push(DctPlan::new(n, DctType::I).map_err(to_topo)?);
        }
        let mut rs = vec![
            R::zero();
            plans
                .iter()
                .map(|p| p.scratch_real_len())
                .max()
                .unwrap_or(0)
        ];
        let czero = Complex::new(R::zero(), R::zero());
        let mut cs = vec![
            czero;
            plans
                .iter()
                .map(|p| p.scratch_complex_len())
                .max()
                .unwrap_or(0)
        ];

        for a in 0..d {
            let n = walk_shape[a];
            let plan = &plans[a];
            for_each_line(&mut data, &walk_shape, a, &mut line[..n], |l| {
                plan.execute(l, &mut out[..n], &mut rs, &mut cs)
                    .expect("buffer lengths fixed at construction");
                l.copy_from_slice(&out[..n]);
            });
        }
        divide_by_eigenvalues(&mut data, &walk_shape, &weights, |v: &mut R, inv| {
            *v *= inv;
        });
        for a in 0..d {
            let n = walk_shape[a];
            let plan = &plans[a];
            for_each_line(&mut data, &walk_shape, a, &mut line[..n], |l| {
                plan.execute_inverse(l, &mut out[..n], &mut rs, &mut cs)
                    .expect("buffer lengths fixed at construction");
                l.copy_from_slice(&out[..n]);
            });
        }
        return Ok(data);
    }

    // Mixed periodic/wall axes: complex carrier (DCT applied to re and im
    // independently — the DCT is real-linear).
    let czero = Complex::new(R::zero(), R::zero());
    let mut data: Vec<Complex<R>> = rhs.iter().map(|&x| Complex::new(x, R::zero())).collect();
    let mut cline = vec![czero; max_len];
    let mut re = vec![R::zero(); max_len];
    let mut im = vec![R::zero(); max_len];
    let mut re_out = vec![R::zero(); max_len];
    let mut im_out = vec![R::zero(); max_len];

    enum AxisPlan<R: deep_causality_fft::FftScalar> {
        Periodic(FftPlan<R>),
        Wall(DctPlan<R>),
    }
    let mut plans: Vec<AxisPlan<R>> = Vec::with_capacity(d);
    for a in 0..d {
        if walk_periodic[a] {
            plans.push(AxisPlan::Periodic(
                FftPlan::new(walk_shape[a]).map_err(to_topo)?,
            ));
        } else {
            plans.push(AxisPlan::Wall(
                DctPlan::new(walk_shape[a], DctType::I).map_err(to_topo)?,
            ));
        }
    }
    let mut fft_scratch = vec![
        czero;
        plans
            .iter()
            .map(|p| match p {
                AxisPlan::Periodic(f) => f.scratch_len(),
                AxisPlan::Wall(w) => w.scratch_complex_len(),
            })
            .max()
            .unwrap_or(0)
    ];
    let mut rs = vec![
        R::zero();
        plans
            .iter()
            .map(|p| match p {
                AxisPlan::Periodic(_) => 0,
                AxisPlan::Wall(w) => w.scratch_real_len(),
            })
            .max()
            .unwrap_or(0)
    ];

    let pass = |data: &mut [Complex<R>],
                inverse: bool,
                plans: &[AxisPlan<R>],
                cline: &mut [Complex<R>],
                re: &mut [R],
                im: &mut [R],
                re_out: &mut [R],
                im_out: &mut [R],
                fft_scratch: &mut [Complex<R>],
                rs: &mut [R]| {
        for a in 0..d {
            let n = walk_shape[a];
            match &plans[a] {
                AxisPlan::Periodic(plan) => {
                    for_each_line(data, &walk_shape, a, &mut cline[..n], |l| {
                        if inverse {
                            plan.execute_inverse(l, fft_scratch)
                                .expect("buffer lengths fixed at construction");
                        } else {
                            plan.execute(l, fft_scratch)
                                .expect("buffer lengths fixed at construction");
                        }
                    });
                }
                AxisPlan::Wall(plan) => {
                    for_each_line(data, &walk_shape, a, &mut cline[..n], |l| {
                        for (j, z) in l.iter().enumerate() {
                            re[j] = z.re;
                            im[j] = z.im;
                        }
                        if inverse {
                            plan.execute_inverse(&re[..n], &mut re_out[..n], rs, fft_scratch)
                                .expect("buffer lengths fixed at construction");
                            plan.execute_inverse(&im[..n], &mut im_out[..n], rs, fft_scratch)
                                .expect("buffer lengths fixed at construction");
                        } else {
                            plan.execute(&re[..n], &mut re_out[..n], rs, fft_scratch)
                                .expect("buffer lengths fixed at construction");
                            plan.execute(&im[..n], &mut im_out[..n], rs, fft_scratch)
                                .expect("buffer lengths fixed at construction");
                        }
                        for (j, z) in l.iter_mut().enumerate() {
                            *z = Complex::new(re_out[j], im_out[j]);
                        }
                    });
                }
            }
        }
    };

    pass(
        &mut data,
        false,
        &plans,
        &mut cline,
        &mut re,
        &mut im,
        &mut re_out,
        &mut im_out,
        &mut fft_scratch,
        &mut rs,
    );
    divide_by_eigenvalues(
        &mut data,
        &walk_shape,
        &weights,
        |z: &mut Complex<R>, inv| {
            *z = Complex::new(z.re * inv, z.im * inv);
        },
    );
    pass(
        &mut data,
        true,
        &plans,
        &mut cline,
        &mut re,
        &mut im,
        &mut re_out,
        &mut im_out,
        &mut fft_scratch,
        &mut rs,
    );

    Ok(data.into_iter().map(|z| z.re).collect())
}
