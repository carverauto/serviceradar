/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Lazy per-grade memo of the diagonal Hodge ⋆ matrices.
//!
//! The diagonal star is **immutable** for a fixed (geometry, complex) pair,
//! yet [`super::has_hodge_star`] rebuilt the entire `CsrMatrix` — allocating
//! one triplet per cell and recomputing every per-cell volume/sign/clip — on
//! *every* call. `Manifold::codifferential` reads two stars (grade `k` and
//! `k−1`) per evaluation, so each Leray/Hodge solve's δω paid for two full
//! rebuilds before doing the two sparse matvecs it actually needed (the
//! dominant cost of the projection at 64³: ~19 ms of a ~30 ms projection).
//!
//! This memo mirrors `LatticeComplex`'s coboundary/boundary `OnceLock`
//! caches: lock-free reads after first init, and a borrowed return so
//! `hodge_star_matrix` hands back `Cow::Borrowed` instead of cloning.
//!
//! Unlike the complex's cache, the star memo is **fingerprint-guarded**. A
//! `CubicalReggeGeometry` is complex-agnostic by its trait signature
//! (`hodge_star_matrix(&self, complex, k)`), so the same metric value could
//! in principle be applied to differently-shaped complexes. The cache records
//! the lattice fingerprint (shape + periodicity) it was first populated
//! against; on a mismatch the star is rebuilt **uncached** (`Cow::Owned`),
//! preserving correctness without corrupting the memo. The common case — one
//! metric paired with one complex inside a `Manifold` — always hits the
//! borrowed fast path after the first build.

use std::sync::OnceLock;

use deep_causality_algebra::RealField;
use deep_causality_sparse::CsrMatrix;

/// Per-grade diagonal Hodge ⋆ memo, fingerprint-guarded on the lattice the
/// stars were first built for. See the module doc.
pub(super) struct StarCache<const D: usize, R: RealField> {
    inner: OnceLock<StarCacheData<D, R>>,
}

struct StarCacheData<const D: usize, R: RealField> {
    shape: [usize; D],
    periodic: [bool; D],
    /// One `OnceLock` per grade in `0..=D`, populated on first request.
    stars: Box<[OnceLock<CsrMatrix<R>>]>,
}

impl<const D: usize, R: RealField> StarCache<D, R> {
    /// An empty cache.
    pub(super) fn new() -> Self {
        Self {
            inner: OnceLock::new(),
        }
    }

    /// Drop all memoized stars. Called when the underlying geometry mutates
    /// (`metropolis_update`), since a changed edge length invalidates every
    /// cached diagonal.
    pub(super) fn invalidate(&mut self) {
        self.inner = OnceLock::new();
    }

    /// The per-grade slot table for `(shape, periodic)`, or `None` when the
    /// cache is already pinned to a different lattice fingerprint. The first
    /// call pins the fingerprint and allocates the `D + 1` empty slots.
    pub(super) fn slots(
        &self,
        shape: &[usize; D],
        periodic: &[bool; D],
    ) -> Option<&[OnceLock<CsrMatrix<R>>]> {
        let data = self.inner.get_or_init(|| StarCacheData {
            shape: *shape,
            periodic: *periodic,
            stars: (0..=D)
                .map(|_| OnceLock::new())
                .collect::<Vec<_>>()
                .into_boxed_slice(),
        });
        if &data.shape == shape && &data.periodic == periodic {
            Some(&data.stars)
        } else {
            None
        }
    }
}

impl<const D: usize, R: RealField> Default for StarCache<D, R> {
    fn default() -> Self {
        Self::new()
    }
}

impl<const D: usize, R: RealField> Clone for StarCache<D, R> {
    fn clone(&self) -> Self {
        // Filled slots are carried over (a CSR clone is a flat array copy);
        // the fingerprint guard keeps a clone re-paired with a different
        // complex correct (it falls through to an uncached rebuild). Mirrors
        // `LatticeComplex`'s clone-the-warm-cache rationale.
        match self.inner.get() {
            None => Self::new(),
            Some(data) => {
                let copied = OnceLock::new();
                let _ = copied.set(StarCacheData {
                    shape: data.shape,
                    periodic: data.periodic,
                    stars: data
                        .stars
                        .iter()
                        .map(|slot| {
                            let fresh = OnceLock::new();
                            if let Some(m) = slot.get() {
                                let _ = fresh.set(m.clone());
                            }
                            fresh
                        })
                        .collect::<Vec<_>>()
                        .into_boxed_slice(),
                });
                Self { inner: copied }
            }
        }
    }
}

impl<const D: usize, R: RealField> PartialEq for StarCache<D, R> {
    /// The cache is a derived memo, never part of geometric identity: two
    /// metrics are equal iff their edge lengths / signature agree, regardless
    /// of cache warmth.
    fn eq(&self, _other: &Self) -> bool {
        true
    }
}

impl<const D: usize, R: RealField> core::fmt::Debug for StarCache<D, R> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("StarCache")
            .field("warm", &self.inner.get().is_some())
            .finish()
    }
}
