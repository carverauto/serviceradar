/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{BaseTopology, GaugeGroup, Manifold, SimplicialComplex, TopologyError};
use deep_causality_metric::Metric;
use deep_causality_tensor::CausalTensor;
use std::marker::PhantomData;

mod display;
mod getters;

use deep_causality_algebra::{Field, RealField};

/// A gauge field over a base manifold.
///
/// A gauge field is a principal fiber bundle with connection, parameterized by:
/// - A gauge group G defining the local symmetry
/// - A matrix element type M (e.g., `Complex<f64>`)
/// - A scalar type R (e.g., f64)
///
/// # Type Parameters
///
/// * `G` - The gauge group (U1, SU2, SU3, Lorentz, etc.)
/// * `M` - The matrix element type (field values)
/// * `R` - The real scalar type (base manifold, metric)
///
/// # Mathematical Structure
///
/// ```text
/// Connection (Gauge Potential):
///   A_μ^a  where μ ∈ {0,1,2,3} (spacetime index), a ∈ {1..dim(g)} (Lie algebra index)
///   Shape: [num_points, spacetime_dim, lie_algebra_dim]
///
/// Field Strength (Curvature):
///   Abelian (U(1)):     F_μν = ∂_μ A_ν - ∂_ν A_μ
///   Non-Abelian (SU(N)): F_μν^a = ∂_μ A_ν^a - ∂_ν A_μ^a + g f^{abc} A_μ^b A_ν^c
///   Shape: [num_points, spacetime_dim, spacetime_dim, lie_algebra_dim]
/// ```
///
/// # Gauge Theory Correspondence
///
/// | Theory | Gauge Group | Connection        | Field Strength    |
/// |--------|-------------|-------------------|-------------------|
/// | QED    | U(1)        | 4-potential A_μ   | F_μν (E, B)       |
/// | QCD    | SU(3)       | Gluon field G_μ^a | G_μν^a            |
/// | GR     | SO(3,1)     | Christoffel Γ     | Riemann R^ρ_σμν   |
#[derive(Debug, Clone)]
pub struct GaugeField<G: GaugeGroup, M, R: RealField> {
    /// Base manifold (spacetime). Private for invariant preservation.
    base: Manifold<SimplicialComplex<R>, R>,

    /// Spacetime metric signature (Minkowski, Euclidean, etc.).
    metric: Metric,

    /// Gauge connection (potential).
    /// Shape: [num_points, spacetime_dim, lie_algebra_dim]
    connection: CausalTensor<M>,

    /// Field strength (curvature).
    /// Shape: [num_points, spacetime_dim, spacetime_dim, lie_algebra_dim]
    field_strength: CausalTensor<M>,

    /// Gauge group marker.
    _gauge: PhantomData<G>,
}

impl<G: GaugeGroup, M: Field, R: RealField> GaugeField<G, M, R> {
    /// Creates a new gauge field with an explicit metric.
    ///
    /// # Mathematical Definition
    ///
    /// A gauge field (A, F) satisfies the structure equation:
    /// ```text
    /// F = dA + A ∧ A   (non-abelian)
    /// F = dA           (abelian, when IS_ABELIAN = true)
    /// ```
    ///
    /// # Arguments
    ///
    /// * `base` - The base manifold (spacetime)
    /// * `metric` - The spacetime metric signature
    /// * `connection` - The gauge connection tensor, shape: [num_points, spacetime_dim, lie_algebra_dim]
    /// * `field_strength` - The field strength tensor, shape: [num_points, dim, dim, lie_algebra_dim]
    ///
    /// # Errors
    ///
    /// Returns `TopologyError::GaugeFieldError` if tensor shapes don't match expected dimensions.
    ///
    /// # Example
    ///
    /// ```ignore
    /// use deep_causality_metric::Metric;
    /// use deep_causality_topology::{GaugeField, U1};
    ///
    /// let em_field = GaugeField::<U1, f64, f64, f64>::new(
    ///     spacetime,
    ///     Metric::Minkowski(4),
    ///     potential,
    ///     field_tensor,
    /// )?;
    /// ```
    pub fn new(
        base: Manifold<SimplicialComplex<R>, R>,
        metric: Metric,
        connection: CausalTensor<M>,
        field_strength: CausalTensor<M>,
    ) -> Result<Self, TopologyError> {
        // Validate connection shape: [num_points, spacetime_dim, lie_algebra_dim]
        let num_points = base.len().max(1);
        let spacetime_dim = G::SPACETIME_DIM;
        let lie_dim = G::LIE_ALGEBRA_DIM;
        let conn_shape = connection.shape();

        // Allow flexible validation: check that total elements are consistent
        // or that shape matches expected pattern
        let expected_conn_elements = num_points * spacetime_dim * lie_dim;
        let actual_conn_elements: usize = conn_shape.iter().product();

        if actual_conn_elements != expected_conn_elements {
            return Err(TopologyError::GaugeFieldError(format!(
                "Connection shape mismatch for {}: got {:?} ({} elements), \
                 expected [num_points={}, spacetime_dim={}, lie_dim={}] ({} elements)",
                G::name(),
                conn_shape,
                actual_conn_elements,
                num_points,
                spacetime_dim,
                lie_dim,
                expected_conn_elements
            )));
        }

        // Validate field strength shape: [num_points, dim, dim, lie_algebra_dim]
        let expected_fs_elements = num_points * spacetime_dim * spacetime_dim * lie_dim;
        let fs_shape = field_strength.shape();
        let actual_fs_elements: usize = fs_shape.iter().product();

        if actual_fs_elements != expected_fs_elements {
            return Err(TopologyError::GaugeFieldError(format!(
                "Field strength shape mismatch for {}: got {:?} ({} elements), \
                 expected [num_points={}, dim={}, dim={}, lie_dim={}] ({} elements)",
                G::name(),
                fs_shape,
                actual_fs_elements,
                num_points,
                spacetime_dim,
                spacetime_dim,
                lie_dim,
                expected_fs_elements
            )));
        }

        Ok(Self {
            base,
            metric,
            connection,
            field_strength,
            _gauge: PhantomData,
        })
    }

    /// Creates a new gauge field with the default metric for the gauge group.
    ///
    /// The default metric is determined by `G::default_metric()`:
    /// - Most gauge groups: West Coast Minkowski (+---)
    /// - Lorentz (GR): East Coast Minkowski (-+++)
    ///
    /// # Arguments
    ///
    /// * `base` - The base manifold (spacetime)
    /// * `connection` - The gauge connection tensor
    /// * `field_strength` - The field strength tensor
    ///
    /// # Errors
    ///
    /// Returns `TopologyError::GaugeFieldError` if tensor shapes don't match expected dimensions.
    pub fn with_default_metric(
        base: Manifold<SimplicialComplex<R>, R>,
        connection: CausalTensor<M>,
        field_strength: CausalTensor<M>,
    ) -> Result<Self, TopologyError> {
        Self::new(base, G::default_metric(), connection, field_strength)
    }
}
