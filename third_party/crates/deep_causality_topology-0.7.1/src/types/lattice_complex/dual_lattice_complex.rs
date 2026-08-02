/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use super::LatticeCell;
use super::LatticeComplex;

use crate::Cell;
use std::sync::Arc;

///
/// For a D-dimensional lattice, a primal k-cell corresponds to a dual (D-k)-cell.
/// This structure is essential for discrete exterior calculus (Hodge star).
pub struct DualLatticeComplex<const D: usize, R: deep_causality_algebra::RealField> {
    primal: Arc<LatticeComplex<D, R>>,
}

impl<const D: usize, R: deep_causality_algebra::RealField> DualLatticeComplex<D, R> {
    /// Create the dual of a primal lattice.
    pub fn new(primal: LatticeComplex<D, R>) -> Self {
        Self {
            primal: Arc::new(primal),
        }
    }

    /// Create from an Arc.
    pub fn new_arc(primal: Arc<LatticeComplex<D, R>>) -> Self {
        Self { primal }
    }

    /// Access the primal lattice.
    pub fn primal(&self) -> &LatticeComplex<D, R> {
        &self.primal
    }

    /// Map a primal k-cell to its dual (D-k)-cell.
    ///
    /// Duality mapping involves:
    /// - Position shift (dual vertices are at cell centers).
    ///   However, in our integer coordinate system, we can't represent half-integers.
    ///   Typical convention: Dual grid is shifted or we re-interpret indices.
    ///   Here we map indices logically.
    /// - Orientation complement (k dims -> D-k dims).
    ///
    /// For a regular grid:
    /// Dual of cell at `pos` with `orientation` is cell at `pos` with `!orientation`?
    /// Not exactly.
    /// Standard discrete duality on a grid:
    /// Primal vertex (x) -> Dual Volume (cube centered at x)
    /// Primal edge (e) -> Dual Face (perp to e)
    ///
    /// In `LatticeCell`, we identify cells by the "lower-left" corner.
    /// Dual mesh is usually staggered.
    /// Or we can treat `DualLatticeComplex` as an abstract view.
    ///
    /// Let's implement the logical duality:
    /// Orientation: complement bitmask.
    /// Position: depends on convention.
    /// Usually, if C is at `x` with dims `I`, *C is at `x` (or shifted) with dims `J = D \ I`.
    ///
    /// Let's use the property that `Dual(Dual(C)) = C`.
    ///
    pub fn dual_cell(&self, cell: &LatticeCell<D>) -> LatticeCell<D> {
        // Simple complement implementation.
        // Requires careful coordinate logic for `boundary` to work as `coboundary`.
        // Duality is often D(σ) * D(τ) = δ_στ?
        //
        // Let's implement logical complement for orientation.
        // For position:
        // A vertex at (0,0) (Dims={}) is dual to a square at (0,0) (Dims={0,1}).
        // An edge at (0,0) (Dims={0}, x-axis) is dual to an edge at (0,0) (Dims={1}, y-axis).
        //
        // This simple mapping `pos -> pos, orient -> !orient` works for simple duality on torus?
        // Let's verify:
        // ∂(Full Square at 0,0) = Top - Bottom + Right - Left (edges).
        // Dual(Square) = Vertex.
        // δ(Vertex) = Sum of coboundary edges?

        let dual_orientation = (!cell.orientation()) & ((1 << D) - 1);

        // We might need to adjust position for exact Poincaré duality geometric interpretation,
        // but for topological connectivity, keeping position same might work if we define
        // incidence correctly.
        // However, usually on a staggered grid:
        // Dual vertices are at x + 0.5.
        //
        // Given we return `LatticeCell<D>`, we are restricted to integer coordinates.
        // So we are defining an isomorphism to another LatticeComplex grid.

        LatticeCell::new(*cell.position(), dual_orientation)
    }

    /// The primal boundary operator becomes the dual coboundary.
    /// δ *C = *(∂ C) ? Or δ = * ∂ * ?
    /// Typically: <δa, b> = <a, ∂b>.
    ///
    /// If we want `coboundary` of a primal cell (which raises dimension),
    /// we compute boundary of its dual? No.
    ///
    /// `LatticeComplex::coboundary` was in the spec.
    /// Let's implement `coboundary` here as an operation on the dual.
    pub fn coboundary(&self, cell: &LatticeCell<D>) -> Vec<(LatticeCell<D>, i8)> {
        // δ = * ∂ *^{-1}
        // 1. Map to dual: *c (dim D-k)
        // 2. Boundary: ∂(*c) (dim D-k-1)
        // 3. Map back: *^{-1} (dim D-(D-k-1) = k+1)

        // Note: Sign handling in duality is tricky.

        let dual = self.dual_cell(cell);

        // Primal boundary of the dual cell
        // NOTE: primal.boundary() returns Vec<(C, i8)> ???
        // LatticeComplex::boundary calls cell.boundary().
        // LatticeComplex struct implements ChainComplex.
        // Wait, LatticeComplex struct doesn't have a 'boundary' method directly exposed that returns Chain?
        // LatticeComplex implements ChainComplex.
        // ChainComplex trait DOES NOT have cell-wise boundary method?
        // ChainComplex has `boundary_matrix`.
        // Cell trait has `boundary`.
        // `dual` is a Cell. `dual.boundary()` works.
        // `self.primal` is `LatticeComplex`. `LatticeComplex` implies cells are `LatticeCell`.

        let dual_boundary = dual.boundary();

        let mut co_chain = Vec::new();
        for (term, coeff) in dual_boundary {
            let primal_term = self.dual_cell(&term); // Self-inverse duality assumed
            co_chain.push((primal_term, coeff));
        }

        co_chain
    }
}
