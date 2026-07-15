/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use super::{CausalCommand, CausalCommandWitness};
use deep_causality_haft::{Functor, HKT, NoConstraint, Satisfies};

impl HKT for CausalCommandWitness {
    type Constraint = NoConstraint;
    type Type<T> = CausalCommand<T>;
}

impl Functor<CausalCommandWitness> for CausalCommandWitness {
    /// Maps the single sub-program hole; `RelayTo`'s target index is structure, not a hole.
    /// Total, identity- and composition-preserving (the precondition `Free` needs of its functor).
    fn fmap<A, B, Func>(m_a: CausalCommand<A>, mut f: Func) -> CausalCommand<B>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        Func: FnMut(A) -> B,
    {
        match m_a {
            CausalCommand::RelayTo(target, k) => CausalCommand::RelayTo(target, f(k)),
        }
    }
}
