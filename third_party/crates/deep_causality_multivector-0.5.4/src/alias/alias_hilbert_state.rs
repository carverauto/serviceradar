/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{CausalMultiVector, CausalMultiVectorError, Metric};
use deep_causality_algebra::RealField;
use deep_causality_num::Zero;
use deep_causality_num_complex::Complex;
use deep_causality_tensor::CausalTensor;
use std::fmt::{Display, Formatter};

/// The distinguished minimal-left-ideal column of the matrix representation
/// used by the ket ↔ matrix bridge: the image of the primitive idempotent
/// `E = e₀e₀ᵀ` (column 0). Fixed by convention (ratified in the
/// `add-quantum-crate` Phase-0 gate); every bridge round-trip depends on it.
pub const KET_COLUMN: usize = 0;

/// A strong type representing a Quantum State Vector (Ket) |ψ>.
///
/// This represents a Minimal Left Ideal of the algebra Cl(10) (or others), acting as the Hilbert Space.
///
/// # Invariants
/// * The coefficients are `Complex<R>` for any `R: RealField` chosen by the caller
///   (`f32`, `f64`, `Float106`, …). The type parameter has no default — call sites
///   must spell the precision explicitly (e.g. `HilbertState::<f64>::new(...)`).
/// * The Metric is fixed at construction time (preventing mixed-algebra operations).
#[derive(Debug, Clone, PartialEq)]
pub struct HilbertState<R: RealField> {
    mv: CausalMultiVector<Complex<R>>,
}

impl<R: RealField> HilbertState<R> {
    /// Creates a new Hilbert State for the Grand Unified Algebra (Spin(10)).
    /// This enforces the metric Cl(10) (NonEuclidean, 10D).
    pub fn new_spin10(data: Vec<Complex<R>>) -> Result<Self, CausalMultiVectorError> {
        let metric = Metric::NonEuclidean(10);
        let mv = CausalMultiVector::new(data, metric)?;
        Ok(Self { mv })
    }

    /// Generic constructor for other quantum systems (e.g. Qubits / Cl(2)).
    pub fn new(data: Vec<Complex<R>>, metric: Metric) -> Result<Self, CausalMultiVectorError> {
        let mv = CausalMultiVector::new(data, metric)?;
        Ok(Self { mv })
    }

    pub fn new_unchecked(data: Vec<Complex<R>>, metric: Metric) -> Self {
        let mv = CausalMultiVector::unchecked(data, metric);
        Self { mv }
    }

    pub fn from_multivector(mv: CausalMultiVector<Complex<R>>) -> Self {
        Self { mv }
    }

    /// Unwraps the state to access the underlying algebraic object.
    /// Useful when you need to perform raw geometric operations.
    pub fn into_inner(self) -> CausalMultiVector<Complex<R>> {
        self.mv
    }

    /// Borrows the underlying algebraic object.
    pub fn as_inner(&self) -> &CausalMultiVector<Complex<R>> {
        &self.mv
    }

    pub fn mv(&self) -> &CausalMultiVector<Complex<R>> {
        &self.mv
    }
}

// The ket ↔ matrix bridge rides the `to_matrix`/`from_matrix` isomorphism,
// whose trace projection needs `Complex<R>: Default` (hence `R: Default`).
impl<R: RealField + Default> HilbertState<R> {
    /// The d-dimensional complex column of this ket in the matrix
    /// representation: column [`KET_COLUMN`] of `to_matrix()`, scaled by
    /// `1/√D` so that the raw column inner product `k(φ)ᴴ · k(ψ)` equals the
    /// metric-correct Dirac product `⟨φ|ψ⟩` on the minimal left ideal (and a
    /// Dirac-normalized ket yields a unit-trace `ρ = k·kᴴ`).
    ///
    /// Defined only for **even-dimensional** metrics, where `to_matrix()` is
    /// a bijection (`D² = 2ⁿ`) — including `Cl(0,10)` (`D = 32`).
    ///
    /// # Errors
    /// Returns a `DimensionMismatch` for an odd-dimensional metric (the
    /// `expected` field carries the next even dimension).
    pub fn to_ket(&self) -> Result<CausalTensor<Complex<R>>, CausalMultiVectorError> {
        let metric = self.mv.metric();
        let n = metric.dimension();
        if !n.is_multiple_of(2) {
            return Err(CausalMultiVectorError::dimension_mismatch(n + 1, n));
        }
        // The D×D matrix bridge (D = 2^(n/2)) must be addressable: reject
        // dimensions where the shift or D² would overflow usize (a debug panic,
        // or a masked and invalid D in release) instead of computing a bad width.
        let half = n / 2;
        if half >= usize::BITS as usize {
            return Err(CausalMultiVectorError::dimension_mismatch(n, n));
        }
        let d = 1usize << half;
        if d.checked_mul(d).is_none() {
            return Err(CausalMultiVectorError::dimension_mismatch(n, n));
        }
        let m = self.mv.to_matrix();
        let slice = m.as_slice();

        let mut d_r = R::zero();
        for _ in 0..d {
            d_r += R::one();
        }
        let inv_sqrt_d = R::one() / d_r.sqrt();

        let col: Vec<Complex<R>> = (0..d)
            .map(|i| {
                let c = slice[i * d + KET_COLUMN];
                Complex::new(c.re * inv_sqrt_d, c.im * inv_sqrt_d)
            })
            .collect();
        Ok(CausalTensor::from_slice(&col, &[d, 1]))
    }

    /// Embeds a d-dimensional complex column as a minimal-left-ideal ket:
    /// the column is placed (scaled by `√D`, the inverse of the [`Self::to_ket`]
    /// gain) at column [`KET_COLUMN`] of a `D×D` matrix and mapped back via
    /// `from_matrix`, so `to_ket(from_ket(v)) == v` exactly.
    ///
    /// Accepts a ket of shape `[D]` or `[D, 1]` with `D = 2^(n/2)`; defined
    /// only for even-dimensional metrics.
    ///
    /// # Errors
    /// Returns a `DimensionMismatch` for an odd-dimensional metric, or a
    /// `DataLengthMismatch` if the ket is not a `D`-vector / `D×1` column.
    pub fn from_ket(
        ket: &CausalTensor<Complex<R>>,
        metric: Metric,
    ) -> Result<Self, CausalMultiVectorError> {
        let n = metric.dimension();
        if !n.is_multiple_of(2) {
            return Err(CausalMultiVectorError::dimension_mismatch(n + 1, n));
        }
        // See `to_ket`: guard the D×D bridge against shift / D² overflow.
        let half = n / 2;
        if half >= usize::BITS as usize {
            return Err(CausalMultiVectorError::dimension_mismatch(n, n));
        }
        let d = 1usize << half;
        if d.checked_mul(d).is_none() {
            return Err(CausalMultiVectorError::dimension_mismatch(n, n));
        }
        let shape = ket.shape();
        if !(shape == [d] || shape == [d, 1]) {
            return Err(CausalMultiVectorError::data_length_mismatch(
                d,
                ket.as_slice().len(),
            ));
        }

        let mut d_r = R::zero();
        for _ in 0..d {
            d_r += R::one();
        }
        let sqrt_d = d_r.sqrt();

        let mut data = vec![Complex::zero(); d * d];
        for (i, c) in ket.as_slice().iter().enumerate() {
            data[i * d + KET_COLUMN] = Complex::new(c.re * sqrt_d, c.im * sqrt_d);
        }
        let matrix = CausalTensor::from_slice(&data, &[d, d]);
        Ok(Self {
            mv: CausalMultiVector::from_matrix(matrix, metric),
        })
    }
}

impl<R: RealField> Default for HilbertState<R> {
    fn default() -> Self {
        // Default to Scalar 0 in Euclidean(0) or similar
        let metric = Metric::Euclidean(0);
        let data = vec![Complex::zero()];
        let mv = CausalMultiVector::new(data.clone(), metric)
            .unwrap_or(CausalMultiVector::unchecked(data, metric));
        Self { mv }
    }
}

// Allow adding two Quantum States: |psi> + |phi> (Superposition)
impl<R: RealField> core::ops::Add for HilbertState<R> {
    type Output = Self;
    fn add(self, rhs: Self) -> Self::Output {
        Self {
            mv: self.mv + rhs.mv,
        }
    }
}

// Allow scaling a State: c * |psi>
impl<R: RealField> core::ops::Mul<Complex<R>> for HilbertState<R> {
    type Output = Self;
    fn mul(self, rhs: Complex<R>) -> Self::Output {
        Self { mv: self.mv * rhs }
    }
}

impl<R: RealField + core::fmt::Debug> Display for HilbertState<R> {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}", self.mv)
    }
}
