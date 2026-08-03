/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::CausalTensor;
use crate::CausalTensorError;
use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;

/// Descriptive-statistics extension for a two-dimensional [`CausalTensor`].
///
/// The tensor is interpreted as a data matrix whose **rows are observations**
/// and whose **columns are variables**. Both methods are generic over any real
/// field `T` and use Bessel's correction (`ddof = 1`) for the covariance.
pub trait CausalTensorStatsExt<T> {
    /// Computes the per-column (per-variable) sample means.
    ///
    /// # Returns
    /// A 1-D `CausalTensor` of shape `[k]` holding the mean of each of the `k`
    /// columns, or a `CausalTensorError` if the tensor is not 2-D or is empty.
    fn sample_mean(&self) -> Result<CausalTensor<T>, CausalTensorError>;

    /// Computes the sample covariance matrix (`ddof = 1`).
    ///
    /// For a tensor with `n` observations (rows) and `k` variables (columns),
    /// returns the `k × k` matrix whose `(i, j)` entry is
    /// `Σ_r (x_ri − μ_i)(x_rj − μ_j) / (n − 1)`.
    ///
    /// # Returns
    /// A `CausalTensor` of shape `[k, k]`, or a `CausalTensorError` if the
    /// tensor is not 2-D, has no columns, or has fewer than two observations
    /// (the `ddof = 1` divisor `n − 1` would be zero or negative).
    fn sample_covariance(&self) -> Result<CausalTensor<T>, CausalTensorError>;

    /// Computes `log(Σ_i exp(x_i))` over all elements using the max-shift
    /// formulation, so the result does not overflow for large inputs.
    ///
    /// # Returns
    /// The log-sum-exp of every element. An empty tensor has an empty sum, so
    /// the result is `log(0) = −∞`.
    fn logsumexp(&self) -> T;

    /// Evaluates the one-dimensional normal log-density of every element given a
    /// shared `mean` and `variance`:
    /// `−½ · (log(2π·var) + (xᵢ − μ)² / var)`.
    ///
    /// A non-positive variance is floored to a small positive constant so the
    /// density stays finite.
    ///
    /// # Returns
    /// A `CausalTensor` of element-wise log-densities with the same shape as
    /// `self`.
    fn gaussian_log_density(
        &self,
        mean: T,
        variance: T,
    ) -> Result<CausalTensor<T>, CausalTensorError>;

    /// Computes the conditional variance of a target variable given a parent
    /// set, treating `self` as a joint covariance matrix.
    ///
    /// Returns the Schur complement `Σ_yy − Σ_yP Σ_PP⁻¹ Σ_Py`, the residual
    /// variance of regressing the target on its parents. The parent block is
    /// ridge-regularized (`Σ_PP + λI`) so the solve stays finite when the
    /// parents are collinear.
    ///
    /// # Arguments
    /// * `target` — row/column index of the target variable.
    /// * `parents` — indices of the conditioning variables (length `k`).
    /// * `ridge` — non-negative ridge `λ` added to the diagonal of `Σ_PP`.
    ///
    /// # Returns
    /// The conditional variance, or a `CausalTensorError` if `self` is not a
    /// square 2-D matrix or any index is out of bounds. An empty parent set
    /// returns the target's marginal variance `Σ_yy`.
    fn conditional_variance(
        &self,
        target: usize,
        parents: &[usize],
        ridge: T,
    ) -> Result<T, CausalTensorError>;
}

impl<T> CausalTensorStatsExt<T> for CausalTensor<T>
where
    T: RealField + FromPrimitive,
{
    fn sample_mean(&self) -> Result<CausalTensor<T>, CausalTensorError> {
        let (n, k) = observations_shape(self)?;
        let data = self.as_slice();

        let n_t =
            <T as FromPrimitive>::from_usize(n).ok_or(CausalTensorError::InvalidParameter(
                "observation count is not representable in the tensor's field".to_string(),
            ))?;

        let mut means = vec![T::zero(); k];
        for row in 0..n {
            let base = row * k;
            for (col, mean) in means.iter_mut().enumerate() {
                *mean += data[base + col];
            }
        }
        for mean in means.iter_mut() {
            *mean /= n_t;
        }

        Ok(CausalTensor::from_slice(&means, &[k]))
    }

    fn sample_covariance(&self) -> Result<CausalTensor<T>, CausalTensorError> {
        let (n, k) = observations_shape(self)?;
        if n < 2 {
            // Bessel's correction divides by `n - 1`; with a single observation
            // (or none) that divisor is zero or negative and the statistic is
            // undefined.
            return Err(CausalTensorError::InvalidParameter(format!(
                "sample covariance needs at least 2 observations, got {n}"
            )));
        }

        let data = self.as_slice();
        let means = self.sample_mean()?;
        let means = means.as_slice();

        let denom =
            <T as FromPrimitive>::from_usize(n - 1).ok_or(CausalTensorError::InvalidParameter(
                "observation count is not representable in the tensor's field".to_string(),
            ))?;

        let mut cov = vec![T::zero(); k * k];
        for row in 0..n {
            let base = row * k;
            for i in 0..k {
                let di = data[base + i] - means[i];
                for j in 0..k {
                    let dj = data[base + j] - means[j];
                    cov[i * k + j] += di * dj;
                }
            }
        }
        for entry in cov.iter_mut() {
            *entry /= denom;
        }

        Ok(CausalTensor::from_slice(&cov, &[k, k]))
    }

    fn logsumexp(&self) -> T {
        let xs = self.as_slice();
        if xs.is_empty() {
            // The empty sum is 0, and log(0) = −∞.
            return T::zero().ln();
        }

        let max = xs
            .iter()
            .copied()
            .fold(xs[0], |acc, x| if x > acc { x } else { acc });

        // With an infinite (or NaN) maximum the shift `x - max` is undefined;
        // the saturated maximum is the only meaningful answer.
        if !max.is_finite() {
            return max;
        }

        let sum = xs
            .iter()
            .copied()
            .fold(T::zero(), |acc, x| acc + (x - max).exp());

        max + sum.ln()
    }

    fn gaussian_log_density(
        &self,
        mean: T,
        variance: T,
    ) -> Result<CausalTensor<T>, CausalTensorError> {
        if self.is_empty() {
            return Ok(CausalTensor::from_slice(&[], self.shape()));
        }

        let var = if variance > T::zero() {
            variance
        } else {
            variance_floor::<T>()
        };
        let half =
            <T as FromPrimitive>::from_f64(0.5).expect("0.5 is representable in every RealField");
        let two =
            <T as FromPrimitive>::from_f64(2.0).expect("2.0 is representable in every RealField");
        let log_two_pi_var = (two * T::pi() * var).ln();

        let new_data: Vec<T> = self
            .as_slice()
            .iter()
            .map(|&x| {
                let diff = x - mean;
                -half * (log_two_pi_var + (diff * diff) / var)
            })
            .collect();
        Ok(CausalTensor::from_slice(&new_data, self.shape()))
    }

    fn conditional_variance(
        &self,
        target: usize,
        parents: &[usize],
        ridge: T,
    ) -> Result<T, CausalTensorError> {
        let shape = self.shape();
        if shape.len() != 2 || shape[0] != shape[1] {
            return Err(CausalTensorError::DimensionMismatch);
        }
        let m = shape[0];

        let entry = |i: usize, j: usize| -> Result<T, CausalTensorError> {
            self.get(&[i, j])
                .copied()
                .ok_or(CausalTensorError::IndexOutOfBounds)
        };

        if target >= m || !parents.iter().all(|&p| p < m) {
            return Err(CausalTensorError::IndexOutOfBounds);
        }

        let sigma_yy = entry(target, target)?;

        let k = parents.len();
        if k == 0 {
            // No parents: the conditional variance is the marginal variance.
            return Ok(sigma_yy);
        }

        // Extract Σ_yP (target-to-parent covariances) and Σ_PP (parent block),
        // adding the ridge to the parent block's diagonal.
        let mut sigma_yp = vec![T::zero(); k];
        for (slot, &p) in sigma_yp.iter_mut().zip(parents.iter()) {
            *slot = entry(target, p)?;
        }

        let mut sigma_pp = vec![T::zero(); k * k];
        for (i, &pi) in parents.iter().enumerate() {
            for (j, &pj) in parents.iter().enumerate() {
                let mut v = entry(pi, pj)?;
                if i == j {
                    v += ridge;
                }
                sigma_pp[i * k + j] = v;
            }
        }

        // Solve (Σ_PP + λI) z = Σ_Py via Cholesky, then form Σ_yP · z.
        cholesky_in_place(&mut sigma_pp, k);
        let mut z = sigma_yp.clone();
        cholesky_solve_in_place(&sigma_pp, &mut z, k);

        let mut reduction = T::zero();
        for i in 0..k {
            reduction += sigma_yp[i] * z[i];
        }

        Ok(sigma_yy - reduction)
    }
}

/// Smallest variance the Gaussian log-density will use; non-positive variances
/// are floored to this value to keep the density finite.
fn variance_floor<T>() -> T
where
    T: RealField + FromPrimitive,
{
    <T as FromPrimitive>::from_f64(1e-12).expect("1e-12 is representable in every RealField")
}

/// Overwrites the lower triangle of `a` (row-major `k × k`) with its Cholesky
/// factor `L`. A non-positive pivot is floored to `T::epsilon()` so the
/// factorization always completes (ridge regularization normally prevents this).
fn cholesky_in_place<T>(a: &mut [T], k: usize)
where
    T: RealField,
{
    for j in 0..k {
        // Diagonal: L[j,j] = sqrt(a[j,j] − Σ_{p<j} L[j,p]²).
        let mut diag = a[j * k + j];
        for p in 0..j {
            let l_jp = a[j * k + p];
            diag -= l_jp * l_jp;
        }
        let pivot = if diag > T::zero() { diag } else { T::epsilon() };
        let l_jj = pivot.sqrt();
        a[j * k + j] = l_jj;

        // Below-diagonal: L[i,j] = (a[i,j] − Σ_{p<j} L[i,p] L[j,p]) / L[j,j].
        for i in (j + 1)..k {
            let mut s = a[i * k + j];
            for p in 0..j {
                s -= a[i * k + p] * a[j * k + p];
            }
            a[i * k + j] = s / l_jj;
        }
    }
}

/// Solves `(L Lᵀ) x = b` in place, given the lower Cholesky factor `l`
/// (row-major `k × k`). On entry `b` holds the right-hand side; on return it
/// holds the solution `x`.
fn cholesky_solve_in_place<T>(l: &[T], b: &mut [T], k: usize)
where
    T: RealField,
{
    // Forward substitution: L y = b.
    for i in 0..k {
        let mut s = b[i];
        for p in 0..i {
            s -= l[i * k + p] * b[p];
        }
        b[i] = s / l[i * k + i];
    }
    // Back substitution: Lᵀ x = y.
    for i in (0..k).rev() {
        let mut s = b[i];
        for p in (i + 1)..k {
            s -= l[p * k + i] * b[p];
        }
        b[i] = s / l[i * k + i];
    }
}

/// Validates that `tensor` is a non-empty 2-D matrix and returns `(rows, cols)`.
fn observations_shape<T>(tensor: &CausalTensor<T>) -> Result<(usize, usize), CausalTensorError> {
    let shape = tensor.shape();
    if shape.len() != 2 {
        return Err(CausalTensorError::DimensionMismatch);
    }
    let (n, k) = (shape[0], shape[1]);
    if n == 0 || k == 0 {
        return Err(CausalTensorError::EmptyTensor);
    }
    Ok((n, k))
}
