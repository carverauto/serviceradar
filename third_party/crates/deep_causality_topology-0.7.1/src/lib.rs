/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
extern crate core;

mod errors;
mod extensions;
mod traits;
mod types;
mod utils;

pub mod alias;
pub mod utils_tests;

// Re-export errors
pub use crate::errors::light_cone_violation::LightConeViolation;
pub use crate::errors::link_variable_error::LinkVariableError;
pub use crate::errors::topology_error::{TopologyError, TopologyErrorEnum};

// Re-export extensions
pub use crate::extensions::hkt_cell_complex::CellComplexWitness;
pub use crate::extensions::hkt_graph::GraphWitness;
pub use crate::extensions::hkt_hypergraph::HypergraphWitness;
pub use crate::extensions::hkt_lattice_complex::LatticeComplexWitness;
pub use crate::extensions::hkt_manifold::{
    GenericManifoldWitness, ManifoldWitness, SimplicialManifoldWitness,
};
pub use crate::extensions::hkt_mixed_graph::MixedGraphWitness;
pub use crate::extensions::hkt_point_cloud::PointCloudWitness;
pub use crate::extensions::hkt_simplicial_complex::ChainWitness;
pub use crate::extensions::hkt_topology::TopologyWitness;

// Re-export gauge field HKT extensions
pub use crate::extensions::hkt_gauge::hkt_curvature::{CurvatureTensorWitness, TensorVector};
pub use crate::extensions::hkt_gauge::hkt_gauge_witness::{GaugeFieldHKT, GaugeFieldWitness};
pub use crate::extensions::hkt_gauge::hkt_lattice_gauge::LatticeGaugeFieldWitness;
// Re-export traits
pub use crate::traits::base_topology::BaseTopology;
pub use crate::traits::cell::Cell;
pub use crate::traits::chain_complex::ChainComplex;
pub use crate::traits::gauge_group::GaugeGroup;
pub use crate::traits::graph_topology::GraphTopology;
pub use crate::traits::has_hodge_star::HasHodgeStar;
pub use crate::traits::hypergraph_topology::HypergraphTopology;
pub use crate::traits::manifold_topology::ManifoldTopology;
pub use crate::traits::mixed_graph_topology::MixedGraphTopology;
pub use crate::traits::neighborhood::{CellId, Neighborhood};
pub use crate::traits::simplicial_topology::SimplicialTopology;
pub use extensions::hkt_gauge::hkt_adjunction_stokes::{
    BoundaryWitness, ExteriorDerivativeWitness, StokesAdjunction, StokesContext,
};

// Re-export types
pub use crate::types::cell_complex::{BoundaryOperator, CellComplex};
pub use crate::types::chain::Chain;
pub use crate::types::lattice_complex::dual_lattice_complex::DualLatticeComplex;
pub use crate::types::lattice_complex::specialized::{
    HeavyHexLattice, HoneycombLattice, KagomeLattice, TriangularLattice,
};
pub use crate::types::lattice_complex::{LatticeCell, LatticeComplex};

/// Textbook alias: a cubical complex is the regular cellular decomposition of a
/// lattice. Both terms refer to the same structure here; `LatticeComplex<D, R>` is the
/// canonical name (it makes the underlying ℤᴰ grid and the metric precision explicit
/// and stays consistent with the physics vocabulary used elsewhere in the crate,
/// e.g. `LatticeGaugeField`).
pub type CubicalComplex<const D: usize, R> = LatticeComplex<D, R>;
/// Textbook alias for `LatticeCell<D>`. See `CubicalComplex<D>`.
pub type CubicalCell<const D: usize> = LatticeCell<D>;
pub use crate::extensions::iso_de_rham::{DeRhamSharpIso, FieldCarrier};
pub use crate::types::cubical_regge_geometry::{
    AcceptReject, CubicalReggeGeometry, Euclidean, Lorentzian, RejectReason, SignatureMarker,
};
pub use crate::types::cut_cell::{
    CellClass, CutCell, CutCellRegistry, CutConstraintKind, CutFaceConstraint, CutFaceFragment,
    Primitive, SourceGeometry,
};
pub use crate::types::graph::Graph;
pub use crate::types::hodge_decomposition::HodgeDecomposition;
pub use crate::types::hypergraph::Hypergraph;
pub use crate::types::leray_projection::LerayProjection;
pub use crate::types::manifold::DecStencilTables;
pub use crate::types::manifold::HodgeDecomposeOptions;
pub use crate::types::manifold::{Manifold, SimplicialManifold};
pub use crate::types::mixed_graph::{Edge, EdgeKind, Mark, MixedGraph};
pub use crate::types::neighborhood::{
    CofaceAdjacent, CofaceAdjacentIter, FaceAdjacent, FaceAdjacentIter, KRing, KRingIter, Moore,
    MooreIter, VonNeumann, VonNeumannIter,
};
pub use crate::types::point_cloud::PointCloud;
pub use crate::types::regge_geometry::ReggeGeometry;
pub use crate::types::simplex::Simplex;
pub use crate::types::simplicial_complex::{SimplicialComplex, SimplicialComplexBuilder};
pub use crate::types::skeleton::Skeleton;
pub use crate::types::topological_invariants::TopologicalInvariants;
pub use crate::types::topology::Topology;

// Re-export gauge field types
pub use crate::types::curvature_tensor::{
    CurvatureSymmetry, CurvatureTensor, CurvatureTensorVector,
};
pub use crate::types::differential_form::DifferentialForm;
pub use crate::types::gauge::gauge_field_lattice::ops_actions::ActionCoeffs;
pub use crate::types::gauge::gauge_field_lattice::ops_gradient_flow::{FlowMethod, FlowParams};
pub use crate::types::gauge::gauge_field_lattice::ops_smearing::SmearingParams;
pub use crate::types::gauge::gauge_groups::{SE3, SO3_1, SU2, SU2_U1, SU3, SU3_SU2_U1, U1};
pub use crate::types::gauge::link_variable::random::RandomField;
pub use crate::types::gauge::{GaugeField, LatticeGaugeField, LinkVariable};
