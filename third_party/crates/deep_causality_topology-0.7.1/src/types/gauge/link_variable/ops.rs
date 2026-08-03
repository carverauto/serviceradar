/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{GaugeGroup, LinkVariable, LinkVariableError};
use deep_causality_algebra::{ComplexField, Field, RealField};
use deep_causality_num::FromPrimitive;
use deep_causality_tensor::CausalTensor;
use std::fmt::Debug;
use std::marker::PhantomData;

impl<
    G: GaugeGroup,
    M: Field + Copy + Default + PartialOrd + Debug,
    R: RealField + FromPrimitive + deep_causality_num::ToPrimitive,
> LinkVariable<G, M, R>
{
    /// Hermitian conjugate U†.
    ///
    /// For real matrices, this is the transpose.
    /// For complex matrices, this is transpose + complex conjugate.
    ///
    /// # Returns
    ///
    /// The Hermitian conjugate.
    ///
    /// # Errors
    ///
    /// Returns error if tensor creation fails.
    /// Returns error if tensor creation fails.
    pub fn try_dagger(&self) -> Result<Self, LinkVariableError>
    where
        M: ComplexField<R>,
        R: RealField,
    {
        let n = G::matrix_dim();
        let slice = self.data.as_slice();
        let mut result = vec![M::default(); n * n];

        // Transpose + Conjugate
        for i in 0..n {
            for j in 0..n {
                result[j * n + i] = slice[i * n + j].conjugate();
            }
        }

        CausalTensor::new(result, vec![n, n])
            .map(|tensor| Self {
                data: tensor,
                _gauge: PhantomData,
                _scalar: PhantomData,
            })
            .map_err(|e| LinkVariableError::TensorCreation(format!("{:?}", e)))
    }

    /// Hermitian conjugate U† (convenience method).
    ///
    /// For real matrices, this is the transpose.
    /// Hermitian conjugate U† (convenience method).
    ///
    /// For real matrices, this is the transpose.
    pub fn dagger(&self) -> Self
    where
        M: ComplexField<R>,
        R: RealField,
    {
        // This is a simple memory operation that cannot fail for valid LinkVariable
        let n = G::matrix_dim();
        let slice = self.data.as_slice();
        let mut result = vec![M::default(); n * n];

        for i in 0..n {
            for j in 0..n {
                result[j * n + i] = slice[i * n + j].conjugate();
            }
        }

        // Safe because we're creating the correct shape
        Self {
            data: CausalTensor::new(result, vec![n, n])
                .unwrap_or_else(|_| panic!("Dagger failed for valid {}x{} matrix", n, n)),
            _gauge: PhantomData,
            _scalar: PhantomData,
        }
    }

    /// Group multiplication: self * other.
    ///
    /// Standard matrix multiplication for group elements.
    ///
    /// # Arguments
    ///
    /// * `other` - The matrix to multiply with (on the right)
    ///
    /// # Returns
    ///
    /// The product $U \cdot V$.
    ///
    /// # Errors
    ///
    /// Returns error if tensor creation fails.
    /// Returns error if tensor creation fails.
    pub fn try_mul(&self, other: &Self) -> Result<Self, LinkVariableError>
    where
        M: Field,
    {
        let n = G::matrix_dim();
        let a = self.data.as_slice();
        let b = other.data.as_slice();
        let mut result = vec![M::default(); n * n];

        // Standard matrix multiplication: C[i,j] = Σ_k A[i,k] * B[k,j]
        for i in 0..n {
            for j in 0..n {
                let mut sum = M::default();
                for k in 0..n {
                    let prod = a[i * n + k] * b[k * n + j];
                    sum = sum + prod;
                }
                result[i * n + j] = sum;
            }
        }

        CausalTensor::new(result, vec![n, n])
            .map(|tensor| Self {
                data: tensor,
                _gauge: PhantomData,
                _scalar: PhantomData,
            })
            .map_err(|e| LinkVariableError::TensorCreation(format!("{:?}", e)))
    }

    /// Group multiplication: self * other (convenience method).
    pub fn mul(&self, other: &Self) -> Self
    where
        M: Field,
    {
        let n = G::matrix_dim();
        let a = self.data.as_slice();
        let b = other.data.as_slice();
        let mut result = vec![M::default(); n * n];

        for i in 0..n {
            for j in 0..n {
                let mut sum = M::default();
                for k in 0..n {
                    let prod = a[i * n + k] * b[k * n + j];
                    sum = sum + prod;
                }
                result[i * n + j] = sum;
            }
        }

        Self {
            data: CausalTensor::new(result, vec![n, n])
                .unwrap_or_else(|_| panic!("Matrix multiply failed for {}x{}", n, n)),
            _gauge: PhantomData,
            _scalar: PhantomData,
        }
    }

    /// Matrix addition: self + other.
    ///
    /// # Errors
    ///
    /// Returns error if tensor creation fails.
    /// Returns error if tensor creation fails.
    pub fn try_add(&self, other: &Self) -> Result<Self, LinkVariableError>
    where
        M: Field,
    {
        let n = G::matrix_dim();
        let a = self.data.as_slice();
        let b = other.data.as_slice();
        let mut result = vec![M::default(); n * n];

        for i in 0..(n * n) {
            result[i] = a[i] + b[i];
        }

        CausalTensor::new(result, vec![n, n])
            .map(|tensor| Self {
                data: tensor,
                _gauge: PhantomData,
                _scalar: PhantomData,
            })
            .map_err(|e| LinkVariableError::TensorCreation(format!("{:?}", e)))
    }

    /// Matrix addition: self + other (convenience method).
    pub fn add(&self, other: &Self) -> Self
    where
        M: Field,
    {
        let n = G::matrix_dim();
        let a = self.data.as_slice();
        let b = other.data.as_slice();
        let mut result = vec![M::default(); n * n];

        for i in 0..(n * n) {
            result[i] = a[i] + b[i];
        }

        Self {
            data: CausalTensor::new(result, vec![n, n])
                .unwrap_or_else(|_| panic!("Matrix add failed")),
            _gauge: PhantomData,
            _scalar: PhantomData,
        }
    }

    /// Scalar multiplication: α * self.
    ///
    /// # Errors
    ///
    /// Returns error if tensor creation fails.
    /// Returns error if tensor creation fails.
    pub fn try_scale(&self, alpha: &M) -> Result<Self, LinkVariableError>
    where
        M: Field,
    {
        let n = G::matrix_dim();
        let a = self.data.as_slice();
        let mut result = vec![M::default(); n * n];

        for i in 0..(n * n) {
            result[i] = *alpha * a[i];
        }

        CausalTensor::new(result, vec![n, n])
            .map(|tensor| Self {
                data: tensor,
                _gauge: PhantomData,
                _scalar: PhantomData,
            })
            .map_err(|e| LinkVariableError::TensorCreation(format!("{:?}", e)))
    }

    /// Scalar multiplication: α * self (convenience method).
    pub fn scale(&self, alpha: &M) -> Self
    where
        M: Field,
    {
        let n = G::matrix_dim();
        let a = self.data.as_slice();
        let mut result = vec![M::default(); n * n];

        for i in 0..(n * n) {
            result[i] = *alpha * a[i];
        }

        Self {
            data: CausalTensor::new(result, vec![n, n])
                .unwrap_or_else(|_| panic!("Matrix scale failed")),
            _gauge: PhantomData,
            _scalar: PhantomData,
        }
    }

    /// Trace of the matrix: Tr(U) = Σ_i U_ii.
    pub fn trace(&self) -> M
    where
        M: Field,
    {
        let n = G::matrix_dim();
        let slice = self.data.as_slice();
        let mut sum = M::default();

        for i in 0..n {
            sum = sum + slice[i * n + i];
        }
        sum
    }

    /// Real part of trace (for action computation with real scalars).
    ///
    /// Returns the real component R of the trace.
    #[inline]
    pub fn re_trace(&self) -> R
    where
        M: ComplexField<R>,
        R: RealField,
    {
        self.trace().real()
    }

    /// Frobenius norm squared: ||U||²_F = Tr(U†U) = Σ_{ij} |U_ij|².
    ///
    /// For real matrices: Σ_{ij} U_ij².
    /// For complex matrices: Σ_{ij} |z_ij|² (returns R).
    pub fn frobenius_norm_sq(&self) -> R
    where
        M: ComplexField<R>,
        R: RealField,
    {
        let slice = self.data.as_slice();
        let mut sum = R::zero();

        for val in slice {
            // Use norm_sqr() to get real-valued squared norm |z|^2
            sum += val.norm_sqr();
        }
        sum
    }

    /// Project to SU(N) using polar decomposition.
    ///
    /// Given a general matrix M, computes U = M (M†M)^{-1/2}
    /// which is the closest unitary matrix to M in Frobenius norm.
    ///
    /// # Returns
    ///
    /// The projected SU(N) matrix.
    ///
    /// # Errors
    ///
    /// Returns `LinkVariableError::SingularMatrix` if M†M is not invertible.
    /// Returns `LinkVariableError::NumericalError` for other numerical issues.
    /// Project to SU(N) using polar decomposition.
    ///
    /// Given a general matrix M, computes U = M (M†M)^{-1/2}
    /// which is the closest unitary matrix to M in Frobenius norm.
    ///
    /// # Returns
    ///
    /// The projected SU(N) matrix.
    ///
    /// # Errors
    ///
    /// Returns `LinkVariableError::SingularMatrix` if M†M is not invertible.
    /// Returns `LinkVariableError::NumericalError` for other numerical issues.
    pub fn project_sun(&self) -> Result<Self, LinkVariableError>
    where
        M: ComplexField<R>,
        R: RealField,
    {
        // For real matrices, polar decomposition: U = M (M^T M)^{-1/2}
        // We use iterative Newton-Schulz iteration:
        // X_{k+1} = 0.5 * X_k (3I - X_k^T X_k)
        // Converges to U where M = UP, P positive semi-definite

        let mut x = self.clone();
        let epsilon = R::from_f64(1e-24).ok_or_else(|| {
            LinkVariableError::NumericalError("Failed to convert 1e-24 to T".to_string())
        })?;

        // Normalize by Frobenius norm for numerical stability
        // norm_sq is R
        let norm_sq = self.frobenius_norm_sq();
        let zero = R::zero();

        if norm_sq.partial_cmp(&zero) != Some(std::cmp::Ordering::Greater) {
            // Zero matrix - return identity
            return Self::try_identity();
        }

        // inv_norm is R
        let inv_norm = R::one() / norm_sq.sqrt();
        // Convert R to M for scaling
        let inv_norm_m = M::from_re_im(inv_norm, R::zero());
        x = x.scale(&inv_norm_m);

        // Newton-Schulz iteration (typically converges in 10-20 iterations)
        let max_iter = 50;
        let three_r = R::from_f64(3.0).ok_or_else(|| {
            LinkVariableError::NumericalError("Failed to convert 3.0 to T".to_string())
        })?;
        let half_r = R::from_f64(0.5).ok_or_else(|| {
            LinkVariableError::NumericalError("Failed to convert 0.5 to T".to_string())
        })?;

        // Convert to M
        let three_m = M::from_re_im(three_r, R::zero());
        let half_m = M::from_re_im(half_r, R::zero());
        let minus_one_m = M::from_re_im(R::from_f64(-1.0).unwrap(), R::zero());

        for _ in 0..max_iter {
            let x_dag = x.try_dagger()?;
            let xdx = x_dag.try_mul(&x)?;

            // Check convergence before next iteration (compute_identity_deviation returns ||X-I||_F^2)
            let residual_sq = compute_identity_deviation::<G, M, R>(&xdx)?;
            if residual_sq < epsilon {
                break;
            }

            // 3I - X†X
            let identity = Self::try_identity()?;
            let three_i = identity.scale(&three_m);
            // xdx * -1
            let xdx_neg = xdx.scale(&minus_one_m);
            let diff = three_i.try_add(&xdx_neg)?;

            // X_{k+1} = 0.5 * X * diff
            // order: X * diff * 0.5
            x = x.try_mul(&diff)?.scale(&half_m);
        }

        // Ensure determinant = 1 for SU(N) by dividing by det^{1/N}
        // This is only required for non-Abelian groups like SU(2), SU(3)
        // Abelian groups like U(1) are unitary U(1) = circle group, det=u, so u/det^1 = 1 which is wrong
        // So we only apply this if N >= 2
        let n = G::matrix_dim();
        if n >= 2 {
            let det = self.try_determinant(&x)?;
            // Compute phase factor to remove: alpha = det^{-1/N}
            // det = r * exp(i * theta) -> because it's unitary, r=1
            // det^{-1/N} = exp(-i * theta / N)

            // arg() returns R
            let theta = det.arg();
            let n_r = R::from_usize(n).ok_or_else(|| {
                LinkVariableError::NumericalError("Failed to convert N to T".to_string())
            })?;
            let theta_norm = theta / n_r;

            // Correction factor: exp(-i * theta/N)
            // cis(-theta) = cos(-theta) + i sin(-theta)
            let neg_theta = -theta_norm;
            let phase_correction = M::from_polar(R::one(), neg_theta);

            // Apply correction
            x = x.scale(&phase_correction);
        }

        Ok(x)
    }

    /// Compute determinant of the matrix.
    ///
    /// Only implemented for N=2 and N=3.
    fn try_determinant(&self, link: &Self) -> Result<M, LinkVariableError>
    where
        M: ComplexField<R>,
    {
        let n = G::matrix_dim();
        let s = link.as_slice();

        match n {
            2 => {
                // | a b |
                // | c d |
                // det = ad - bc
                let a = s[0];
                let b = s[1];
                let c = s[2];
                let d = s[3];
                Ok(a * d - b * c)
            }
            3 => {
                // Rule of Sarrus
                let m00 = s[0];
                let m01 = s[1];
                let m02 = s[2];
                let m10 = s[3];
                let m11 = s[4];
                let m12 = s[5];
                let m20 = s[6];
                let m21 = s[7];
                let m22 = s[8];

                let term1 = m00 * m11 * m22;
                let term2 = m01 * m12 * m20;
                let term3 = m02 * m10 * m21;

                let term4 = m02 * m11 * m20;
                let term5 = m01 * m10 * m22;
                let term6 = m00 * m12 * m21;

                Ok(term1 + term2 + term3 - term4 - term5 - term6)
            }
            _ => Err(LinkVariableError::InvalidDimension(n)),
        }
    }
}

/// Compute ||X - I||_F for checking how close X is to identity.
fn compute_identity_deviation<G: GaugeGroup, M, R>(
    x: &LinkVariable<G, M, R>,
) -> Result<R, LinkVariableError>
where
    M: ComplexField<R> + Debug + Copy,
    R: RealField,
{
    let n = G::matrix_dim();
    let slice = x.as_slice();
    let mut sum = R::zero();
    let one = M::one();

    for i in 0..n {
        for j in 0..n {
            let val = slice[i * n + j];
            let diff = if i == j { val - one } else { val };
            // norm_sqr returns R
            self_diff_sq(diff, &mut sum);
        }
    }

    Ok(sum)
}

#[inline]
fn self_diff_sq<M: ComplexField<R>, R: RealField>(diff: M, sum: &mut R) {
    *sum += diff.norm_sqr();
}

// Helpers for generic float math
