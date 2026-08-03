/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Link variable type for lattice gauge theory.
//!
//! A link variable U_μ(x) ∈ G is an element of the gauge group assigned
//! to the edge connecting lattice site x to x + μ̂.
//!

use crate::types::gauge::link_variable::random::RandomField;
use crate::{GaugeGroup, LinkVariableError};
use deep_causality_algebra::{ComplexField, DivisionAlgebra, Field, RealField};
use deep_causality_num::{FromPrimitive, ToPrimitive};
use deep_causality_tensor::CausalTensor;
use std::marker::PhantomData;

mod display;
mod getters;
mod ops;
mod part_eq;
pub(crate) mod random;

/// A link variable U_μ(n) ∈ G on a lattice edge.
///
/// For SU(N), this is an N×N unitary matrix with det = 1.
/// The matrix is stored as a flattened tensor.
///
/// # Type Parameters
///
/// * `G` - The gauge group (U1, SU2, SU3, etc.)
/// * `G` - The gauge group (U1, SU2, SU3, etc.)
/// * `M` - Matrix element type (Field + `DivisionAlgebra<R>`)
/// * `R` - Scalar type (RealField)
///
/// # Mathematical Properties
///
/// - **Unitarity:** U U† = 1
/// - **Orientation:** U_{-μ}(n + μ̂) = U_μ(n)†
/// - **Continuum limit:** U_μ(x) ≈ exp(ia A_μ(x))
#[derive(Debug, Clone)]
pub struct LinkVariable<G: GaugeGroup, M, R> {
    /// Matrix elements of the group element.
    /// Shape: [N, N] for SU(N) where N = matrix dimension.
    data: CausalTensor<M>,
    _gauge: PhantomData<G>,
    _scalar: PhantomData<R>,
}

impl<G: GaugeGroup, M: Field + Copy + Default + PartialOrd, R: RealField> LinkVariable<G, M, R> {
    /// Create the identity link (unit element of G).
    ///
    /// Returns the N×N identity matrix for SU(N).
    ///
    /// # Returns
    ///
    /// Identity link variable.
    ///
    /// # Errors
    ///
    /// Returns `LinkVariableError::TensorCreation` if matrix allocation fails.
    pub fn try_identity() -> Result<Self, LinkVariableError>
    where
        M: Field,
    {
        let n = G::matrix_dim();
        if n == 0 {
            return Err(LinkVariableError::InvalidDimension(n));
        }

        let mut data = vec![M::zero(); n * n];
        // Set diagonal to 1
        for i in 0..n {
            data[i * n + i] = M::one();
        }

        CausalTensor::new(data, vec![n, n])
            .map(|tensor| Self {
                data: tensor,
                _gauge: PhantomData,
                _scalar: PhantomData,
            })
            .map_err(|e| LinkVariableError::TensorCreation(format!("{:?}", e)))
    }

    /// Create the identity link (unit element of G).
    ///
    /// Convenience method that panics on failure. Use `try_identity()` for
    /// fallible construction.
    ///
    /// # Panics
    ///
    /// Panics if tensor creation fails (should never happen for valid groups).
    pub fn identity() -> Self
    where
        M: Field,
    {
        Self::try_identity()
            .unwrap_or_else(|e| panic!("Identity matrix creation failed for {}: {}", G::name(), e))
    }

    /// Create from raw matrix data with validation.
    ///
    /// # Arguments
    ///
    /// * `data` - Tensor of shape [N, N] for SU(N)
    ///
    /// # Returns
    ///
    /// The wrapped link variable.
    ///
    /// # Errors
    ///
    /// Returns `LinkVariableError::ShapeMismatch` if tensor shape doesn't match
    /// expected [N, N] for the gauge group.
    pub fn try_from_matrix(data: CausalTensor<M>) -> Result<Self, LinkVariableError> {
        let n = G::matrix_dim();
        let expected = vec![n, n];
        let got = data.shape().to_vec();

        if got != expected {
            return Err(LinkVariableError::ShapeMismatch { expected, got });
        }

        Ok(Self {
            data,
            _gauge: PhantomData,
            _scalar: PhantomData,
        })
    }

    /// Create from raw matrix data without validation.
    ///
    /// # Safety
    ///
    /// Caller must ensure the tensor has correct shape [N, N].
    pub fn from_matrix_unchecked(data: CausalTensor<M>) -> Self {
        Self {
            data,
            _gauge: PhantomData,
            _scalar: PhantomData,
        }
    }

    /// Create a zero matrix.
    ///
    /// # Errors
    ///
    /// Returns error if tensor creation fails.
    pub fn try_zero() -> Result<Self, LinkVariableError>
    where
        M: Field,
    {
        let n = G::matrix_dim();
        if n == 0 {
            return Err(LinkVariableError::InvalidDimension(n));
        }

        let data = vec![M::zero(); n * n];
        CausalTensor::new(data, vec![n, n])
            .map(|tensor| Self {
                data: tensor,
                _gauge: PhantomData,
                _scalar: PhantomData,
            })
            .map_err(|e| LinkVariableError::TensorCreation(format!("{:?}", e)))
    }

    /// Create a random link variable for Monte Carlo initialization.
    ///
    /// Generates a random group element suitable for "hot start" Monte Carlo
    /// simulations, where configurations begin far from equilibrium.
    ///
    /// # Mathematics
    ///
    /// For SU(N), generates a random unitary matrix by:
    /// 1. Creating a random N×N matrix M with entries uniform in [-1, 1]
    /// 2. Projecting to SU(N) via `project_sun()` (polar decomposition)
    ///
    /// The resulting matrix satisfies:
    /// - **Unitarity:** U U† = 𝟙
    /// - **Special:** det(U) = 1 (for SU(N))
    ///
    /// # Physics
    ///
    /// Random link variables represent a "hot start" configuration for
    /// lattice gauge theory simulations. The configuration is far from
    /// the classical vacuum and requires thermalization before measurements.
    ///
    /// # Arguments
    ///
    /// * `rng` - Random number generator implementing `deep_causality_rand::Rng`
    ///
    /// # Returns
    ///
    /// A random SU(N) link variable.
    ///
    /// # Errors
    ///
    /// Returns `LinkVariableError::TensorCreation` if matrix allocation fails,
    /// or `LinkVariableError::SingularMatrix` if projection fails.
    ///
    /// # Example
    ///
    /// ```ignore
    /// use deep_causality_topology::{LinkVariable, SU2};
    /// use deep_causality_rand::rng;
    ///
    /// let mut rng = rng();
    /// let link: LinkVariable<SU2, f64> = LinkVariable::try_random(&mut rng)?;
    /// ```
    pub fn try_random<RngType>(rng: &mut RngType) -> Result<Self, LinkVariableError>
    where
        RngType: deep_causality_rand::Rng,
        M: RandomField + DivisionAlgebra<R> + Field + ComplexField<R> + std::fmt::Debug,
        R: RealField + FromPrimitive + ToPrimitive,
    {
        let n = G::matrix_dim();
        if n == 0 {
            return Err(LinkVariableError::InvalidDimension(n));
        }

        // Generate random matrix with entries in [-0.5, 0.5] via RandomField
        let mut data = Vec::with_capacity(n * n);
        for _ in 0..(n * n) {
            let val = M::generate_uniform(rng);
            data.push(val);
        }

        let tensor = CausalTensor::new(data, vec![n, n])
            .map_err(|e| LinkVariableError::TensorCreation(format!("{:?}", e)))?;

        let random_matrix = Self {
            data: tensor,
            _gauge: PhantomData,
            _scalar: PhantomData,
        };

        // Project to SU(N) to ensure unitarity and det = 1
        random_matrix.project_sun()
    }

    /// Create a link variable from a U(1) phase angle.
    ///
    /// Constructs a gauge group element that encodes a phase rotation in the
    /// U(1) sector of the gauge group. For pure U(1), this is exp(iφ). For
    /// product groups like SU(2)×U(1), the phase is encoded in the U(1) factor
    /// while the SU(2) factor remains identity.
    ///
    /// # Mathematics
    ///
    /// For a phase φ:
    /// - **U(1)**: Returns exp(iφ) ∈ U(1)
    /// - **SU(2)×U(1)**: Returns diag(1, 1, exp(iφ)) - identity in SU(2), phase in U(1)
    /// - **SU(n)**: Returns diag(exp(iφ), exp(-iφ/(n-1)), ...) to preserve det = 1
    ///
    /// # Physics Application
    ///
    /// In chrono-gauge theory, the phase encodes gravitational time dilation:
    /// - φ ∝ (1 - dτ/dt) where dτ/dt is the clock drift rate
    /// - The Polyakov loop then measures ∏_t exp(iφ_t) ≈ exp(-GM/rc²)
    ///
    /// # Arguments
    ///
    /// * `phase` - The phase angle in radians
    ///
    /// # Returns
    ///
    /// A link variable encoding the phase rotation.
    ///
    /// # Errors
    ///
    /// Returns `LinkVariableError::TensorCreation` if matrix allocation fails.
    ///
    /// # Example
    ///
    /// ```ignore
    /// use deep_causality_topology::{LinkVariable, SU2_U1};
    /// use deep_causality_num_complex::Complex;
    ///
    /// let phase = 0.001;  // Small phase for weak gravitational field
    /// let link: LinkVariable<SU2_U1, Complex<f64>, f64> =
    ///     LinkVariable::try_from_phase(phase)?;
    /// ```
    pub fn try_from_phase(phase: R) -> Result<Self, LinkVariableError>
    where
        M: ComplexField<R> + Field,
        R: RealField + FromPrimitive,
    {
        let n = G::matrix_dim();
        if n == 0 {
            return Err(LinkVariableError::InvalidDimension(n));
        }

        // Create block-diagonal matrix with phase in U(1) sector.
        //
        // Dispatch is by matrix dimension only — an earlier draft had a
        // `G::name() == "SU2_U1"` special case that produced output identical to the
        // n = 3 general arm below, and the name string mismatched the actual
        // `SU2_U1::name()` return ("SU(2)×U(1)") making it dead code.
        let mut data = vec![M::zero(); n * n];

        match n {
            1 => {
                // Pure U(1): exp(iφ)
                data[0] = M::from_polar(R::one(), phase);
            }
            2 => {
                // SU(2): encode as exp(iφσ_3/2) = diag(exp(iφ/2), exp(-iφ/2))
                // This preserves det = 1
                let two = R::one() + R::one();
                let half_phase = phase / two;
                data[0] = M::from_polar(R::one(), half_phase);
                data[3] = M::from_polar(R::one(), -half_phase);
            }
            3 => {
                // SU(2)×U(1): block-diagonal (2×2 SU(2) identity) + (1×1 U(1) phase)
                // [[1, 0, 0],
                //  [0, 1, 0],
                //  [0, 0, exp(iφ)]]
                data[0] = M::one(); // SU(2) block: identity
                data[4] = M::one(); // SU(2) block: identity
                data[8] = M::from_polar(R::one(), phase); // U(1) sector: exp(iφ)
            }
            _ => {
                // General SU(n): encode phase along diagonal with det = 1
                // diag(exp(iφ), exp(-iφ/(n-1)), exp(-iφ/(n-1)), ...)
                let n_minus_1_f = R::from_usize(n - 1).ok_or_else(|| {
                    LinkVariableError::NumericalError(format!(
                        "Cannot represent dimension {} as underlying real type",
                        n - 1
                    ))
                })?;
                let compensating_phase = -phase / n_minus_1_f;

                data[0] = M::from_polar(R::one(), phase);
                for i in 1..n {
                    data[i * n + i] = M::from_polar(R::one(), compensating_phase);
                }
            }
        }

        CausalTensor::new(data, vec![n, n])
            .map(|tensor| Self {
                data: tensor,
                _gauge: PhantomData,
                _scalar: PhantomData,
            })
            .map_err(|e| LinkVariableError::TensorCreation(e.to_string()))
    }

    /// Create a link variable from a U(1) phase angle (convenience method).
    ///
    /// See [`try_from_phase`](Self::try_from_phase) for details.
    ///
    /// # Panics
    ///
    /// Panics if tensor creation fails (should never happen for valid groups).
    pub fn from_phase(phase: R) -> Self
    where
        M: ComplexField<R> + Field,
        R: RealField + FromPrimitive,
    {
        Self::try_from_phase(phase)
            .unwrap_or_else(|e| panic!("Phase link creation failed for {}: {}", G::name(), e))
    }
}
