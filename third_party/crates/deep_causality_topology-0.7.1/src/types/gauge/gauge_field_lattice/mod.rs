/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! LatticeComplex Gauge Field type for lattice gauge theory computations.
//!
//! A lattice gauge field assigns group-valued link variables to each edge
//! of a discrete lattice, enabling Wilson-formulation gauge theory.
//!
//! # Verification Status: ✓ Verified
//!
//! This implementation is verified against known results from lattice gauge theory.
//! See `verification_tests.rs` for 24 physics validation tests.
//!
//! | Category | Tests | Verification |
//! |----------|-------|--------------|
//! | 2D U(1) Exact Solution | 3 | Identity ⟨P⟩ = 1.0, Wilson S = 0, Bessel I₁/I₀ |
//! | Coupling Limits | 2 | Strong coupling ⟨P⟩ ≈ β/2, Weak coupling ⟨P⟩ → 1 |
//! | Wilson/Polyakov Loops | 2 | W(R,T) = 1 and P = 1 for identity config |
//! | Improved Actions | 4 | Symanzik, Iwasaki, DBW2 coefficients + normalization |
//! | LatticeComplex Structure | 3 | Plaquette counting in 2D, 3D, 4D |
//! | Gauge Invariance | 2 | Wilson action and ⟨P⟩ invariant under gauge transform |
//! | Topology Detection | 3 | Perturbation detection, random vs identity, 4D Q=0 |
//! | Thermalization | 3 | Hot/cold difference, Metropolis sweep, field modification |
//! | Anisotropy | 2 | Plaquette orientation detection, local perturbation effect |
//!
//! **Reference:** M. Creutz, *Quarks, Gluons and Lattices*, Cambridge (1983)
//!
//! # Mathematical Structure
//!
//! - **LatticeComplex:** Discrete spacetime Γ ⊂ ℤᴰ with spacing a
//! - **Link variables:** U_μ(x) ∈ G on each edge
//! - **Plaquettes:** Ordered product around elementary squares
//! - **Wilson action:** S = β Σ_p (1 - Re[Tr(U_p)]/N)

use crate::{ChainComplex, GaugeGroup, RandomField};
use crate::{LatticeCell, LatticeComplex, LinkVariable, TopologyError};
use deep_causality_algebra::{ComplexField, DivisionAlgebra, Field, RealField};
use deep_causality_num::{FromPrimitive, ToPrimitive};
// use deep_causality_tensor::TensorData; // Removed
use std::collections::HashMap;
use std::fmt::Debug;
use std::sync::Arc;

mod display;
mod getters;
pub mod ops_actions;
mod ops_continuum;
mod ops_gauge;
mod ops_gauge_transform;
pub mod ops_gradient_flow;
mod ops_metropolis;
mod ops_monte_carlo;
mod ops_plague;
pub mod ops_smearing;

mod ops_wilson;
mod utils;

/// A gauge field on a D-dimensional lattice.
///
/// Link variables U_μ(n) are stored on each edge of the lattice.
/// For a hypercubic lattice: D × num_vertices links total (periodic).
///
/// # Type Parameters
///
/// * `G` - Gauge group (U1, SU2, SU3, etc.)
/// * `D` - Spacetime dimension
/// * `M` - Matrix element type (Field + `DivisionAlgebra<R>`)
/// * `R` - Scalar type (RealField)
#[derive(Debug, Clone)]
pub struct LatticeGaugeField<G: GaugeGroup, const D: usize, M, R: RealField, S = ()> {
    /// The underlying lattice structure.
    lattice: Arc<LatticeComplex<D, R>>,

    /// Link variables indexed by LatticeCell (1-cells only).
    /// Key: edge cell, Value: group element
    links: HashMap<LatticeCell<D>, LinkVariable<G, M, R>>,

    /// Coupling parameter β = 2N/g².
    beta: R,

    /// The Source that generates the field.
    /// Defaults to () for Vacuum.
    source: S,
}

// ============================================================================
// Constructors
// ============================================================================

impl<
    G: GaugeGroup,
    const D: usize,
    M: Field + Copy + Default + PartialOrd + Debug + ComplexField<R> + DivisionAlgebra<R>,
    R: RealField + FromPrimitive + ToPrimitive,
    S: Default + Clone,
> LatticeGaugeField<G, D, M, R, S>
{
    /// Create with all links set to identity.
    ///
    /// This is a "cold start" configuration representing the trivial vacuum.
    ///
    /// # Errors
    ///
    /// Returns `TopologyError` if link creation fails.
    pub fn try_identity(lattice: Arc<LatticeComplex<D, R>>, beta: R) -> Result<Self, TopologyError>
    where
        M: Field,
        R: RealField,
    {
        let mut links = HashMap::new();

        // Iterate over all 1-cells (edges)
        for cell in lattice.cells(1) {
            let link = LinkVariable::try_identity().map_err(TopologyError::from)?;
            links.insert(cell, link);
        }

        Ok(Self {
            lattice,
            links,
            beta,
            source: S::default(),
        })
    }

    /// Create with all links set to identity (convenience method).
    ///
    /// # Panics
    ///
    /// Panics if link creation fails (should not happen for valid lattice).
    pub fn identity(lattice: Arc<LatticeComplex<D, R>>, beta: R) -> Self
    where
        M: Field,
        R: RealField,
    {
        Self::try_identity(lattice, beta)
            .unwrap_or_else(|e| panic!("Identity field creation failed: {}", e))
    }

    /// Create from explicit link data.
    ///
    /// # Arguments
    ///
    /// * `lattice` - The underlying lattice structure
    /// * `links` - Map of edge cells to link variables
    /// * `beta` - Coupling parameter
    ///
    /// # Returns
    ///
    /// A new `LatticeGaugeField` or error if validation fails.
    ///
    /// # Errors
    ///
    /// Returns error if links are missing for some edges.
    pub fn try_from_links(
        lattice: Arc<LatticeComplex<D, R>>,
        links: HashMap<LatticeCell<D>, LinkVariable<G, M, R>>,
        beta: R,
    ) -> Result<Self, TopologyError> {
        // Validate that we have links for all edges
        let expected_count = lattice.num_cells(1);
        if links.len() != expected_count {
            return Err(TopologyError::LatticeGaugeError(format!(
                "Link count mismatch: expected {}, got {}",
                expected_count,
                links.len()
            )));
        }

        Ok(Self {
            lattice,
            links,
            beta,
            source: S::default(),
        })
    }

    /// Create with random links ("hot start" for Monte Carlo).
    ///
    /// Initializes all link variables to random SU(N) elements.
    /// This represents a "hot start" configuration far from equilibrium.
    ///
    /// # Physics
    ///
    /// Hot start configurations:
    /// - Begin far from the classical vacuum (all identity)
    /// - Require thermalization before measurements
    /// - Are used to verify thermalization independence
    ///
    /// In contrast, "cold start" (`identity()`) begins at the trivial vacuum.
    ///
    /// # Arguments
    ///
    /// * `lattice` - The underlying lattice structure
    /// * `beta` - Coupling parameter β = 2N/g²
    /// * `rng` - Random number generator
    ///
    /// # Errors
    ///
    /// Returns `TopologyError` if link creation fails.
    pub fn try_random<RngType>(
        lattice: Arc<LatticeComplex<D, R>>,
        beta: R,
        rng: &mut RngType,
    ) -> Result<Self, TopologyError>
    where
        RngType: deep_causality_rand::Rng,
        M: RandomField + DivisionAlgebra<R> + Field,
        R: RealField,
    {
        let mut links = HashMap::new();

        for cell in lattice.cells(1) {
            let link = LinkVariable::try_random(rng).map_err(TopologyError::from)?;
            links.insert(cell, link);
        }

        Ok(Self {
            lattice,
            links,
            beta,
            source: S::default(),
        })
    }

    /// Create with random links (convenience method).
    ///
    /// See [`try_random`](Self::try_random) for details.
    ///
    /// # Panics
    ///
    /// Panics if link creation fails.
    pub fn random<RngType>(lattice: Arc<LatticeComplex<D, R>>, beta: R, rng: &mut RngType) -> Self
    where
        RngType: deep_causality_rand::Rng,
        M: RandomField + DivisionAlgebra<R> + Field,
        R: RealField,
    {
        Self::try_random(lattice, beta, rng)
            .unwrap_or_else(|e| panic!("Random field creation failed: {}", e))
    }
}

// Separate impl block without Clone + Default bounds for HKT compatibility
impl<G: GaugeGroup, const D: usize, M, R: RealField, S> LatticeGaugeField<G, D, M, R, S> {
    /// Create from explicit link data without validation.
    ///
    /// This constructor has minimal bounds for HKT compatibility.
    ///
    /// # Arguments
    ///
    /// * `lattice` - The underlying lattice structure
    /// * `links` - Map of edge cells to link variables
    /// * `beta` - Coupling parameter
    /// * `source` - The source field
    ///
    /// # Returns
    ///
    /// A new `LatticeGaugeField`.
    pub fn from_links_unchecked(
        lattice: Arc<LatticeComplex<D, R>>,
        links: HashMap<LatticeCell<D>, LinkVariable<G, M, R>>,
        beta: R,
        source: S,
    ) -> Self {
        Self {
            lattice,
            links,
            beta,
            source,
        }
    }

    /// Returns a reference to the field source.
    pub fn source(&self) -> &S {
        &self.source
    }

    /// Returns a mutable reference to the field source.
    pub fn source_mut(&mut self) -> &mut S {
        &mut self.source
    }

    /// Replaces the source and returns the old one.
    pub fn replace_source(&mut self, new_source: S) -> S {
        std::mem::replace(&mut self.source, new_source)
    }

    /// Attaches a new source to the field, transforming the type.
    ///
    /// Consumes the current field and returns a new field with the given source.
    /// The link variables and lattice structure are preserved.
    pub fn with_source<NewS>(self, source: NewS) -> LatticeGaugeField<G, D, M, R, NewS> {
        LatticeGaugeField {
            lattice: self.lattice,
            links: self.links,
            beta: self.beta,
            source,
        }
    }
}
