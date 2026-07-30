/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::TopologyError;
use crate::traits::has_hodge_star::HasHodgeStar;
use crate::{ReggeGeometry, SimplicialComplex};
use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;
use deep_causality_sparse::CsrMatrix;
use std::borrow::Cow;

/// Simplicial backend for the `HasHodgeStar<R>` capability trait.
///
/// The discrete Hodge ⋆ on a simplicial complex is pre-computed at construction time
/// and cached on the complex itself (see [`SimplicialComplex::hodge_star_operators`]).
/// This impl therefore acts as a thin, zero-copy adapter: it borrows the cached
/// `CsrMatrix<R>` for the requested grade and vends it through the trait surface so
/// that generic differential operators on `Manifold<K, R>` can resolve the simplicial
/// path through the same call as the cubical path (R4.3+ deliver the cubical impl).
///
/// `&self` is unused by design: the simplicial Hodge ⋆ is fully determined by the
/// complex's cached operator table and does not depend on any additional state
/// carried by `ReggeGeometry<R>`. The geometry's edge-length data is consumed at the
/// time the complex is constructed (and its Hodge operators are baked in); after that
/// the metric instance is informational only for this trait.
impl<R> HasHodgeStar<R> for ReggeGeometry<R>
where
    R: RealField + FromPrimitive,
{
    type Complex = SimplicialComplex<R>;

    fn hodge_star_matrix<'a>(
        &'a self,
        complex: &'a Self::Complex,
        k: usize,
    ) -> Result<Cow<'a, CsrMatrix<R>>, TopologyError> {
        let ops = complex.hodge_star_operators()?;
        Ok(Cow::Borrowed(&ops[k]))
    }
}
