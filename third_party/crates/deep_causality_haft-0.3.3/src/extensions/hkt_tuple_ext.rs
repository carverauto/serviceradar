/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Bifunctor, HKT2Unbound, HKT3Unbound, NoConstraint, Promonad};

// -----------------------------------------------------------------------------
// Tuple 2 (Pair) Extensions
// -----------------------------------------------------------------------------

/// `Tuple2Witness` acts as a witness for the `(A, B)` type constructor.
pub struct Tuple2Witness;

impl HKT2Unbound for Tuple2Witness {
    type Constraint = NoConstraint;
    type Type<A, B> = (A, B);
}

impl Bifunctor<Tuple2Witness> for Tuple2Witness {
    fn bimap<A, B, C, D, F1, F2>(fab: (A, B), mut f1: F1, mut f2: F2) -> (C, D)
    where
        F1: FnMut(A) -> C,
        F2: FnMut(B) -> D,
    {
        (f1(fab.0), f2(fab.1))
    }
}

// -----------------------------------------------------------------------------
// Tuple 3 (Triple) Extensions
// -----------------------------------------------------------------------------

/// `Tuple3Witness` acts as a witness for the `(A, B, C)` type constructor.
pub struct Tuple3Witness;

impl HKT3Unbound for Tuple3Witness {
    type Constraint = NoConstraint;
    type Type<A, B, C> = (A, B, C);
}

impl Promonad<Tuple3Witness> for Tuple3Witness {
    fn merge<A, B, C, F>(pa: (A, A, A), pb: (B, B, B), mut f: F) -> (C, C, C)
    where
        F: FnMut(A, B) -> C,
    {
        (f(pa.0, pb.0), f(pa.1, pb.1), f(pa.2, pb.2))
    }

    /// # Panics
    ///
    /// This method always panics. For a tuple `(A, B, C)`, "fusion" without a merge
    /// function isn't well-defined because we cannot produce a `C` from just `A` and `B`.
    ///
    /// `Promonad::fuse` is designed for types like `Interaction<A, B, C>` where the
    /// third parameter represents an output that can be derived from the fusion process.
    /// For a plain tuple, this operation is not meaningful.
    fn fuse<A, B, C>(_input_a: A, _input_b: B) -> (A, B, C) {
        panic!("Tuple3Witness::fuse is not supported: C cannot be derived from A and B alone.")
    }
}
