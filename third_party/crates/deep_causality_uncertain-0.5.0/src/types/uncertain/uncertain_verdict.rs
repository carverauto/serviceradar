/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! [`Verdict`] instances for the uncertain carriers — the collection-aggregation carrier bound
//! (`core.verdict.closure`) for `Uncertain<bool>` and `Uncertain<f64>`.
//!
//! Both instances are **lazy**: each operation extends the computation graph; the algebra laws
//! hold in distribution (per sample, the underlying `bool`/`f64` operation is the corresponding
//! pointwise `Verdict` operation).
//!
//! - `Uncertain<bool>` is the **Boolean** class lifted pointwise: `meet = &`, `join = |`,
//!   `complement = !`, bounds = the point masses at `false`/`true`.
//! - `Uncertain<f64>` is the **MV** class on `[0, 1]` lifted pointwise (`meet = min`,
//!   `join = max`, `complement = 1 − p`), mirroring `Prob`/`f64`; the caller keeps sampled
//!   values in `[0, 1]`, as with the scalar carriers.

use crate::{ArithmeticOperator, Uncertain, UncertainNodeContent};
use deep_causality_algebra::Verdict;

impl Verdict for Uncertain<bool> {
    #[inline]
    fn bottom() -> Self {
        Uncertain::<bool>::point(false)
    }
    #[inline]
    fn top() -> Self {
        Uncertain::<bool>::point(true)
    }
    #[inline]
    fn meet(self, other: Self) -> Self {
        self & other
    }
    #[inline]
    fn join(self, other: Self) -> Self {
        self | other
    }
    #[inline]
    fn complement(self) -> Self {
        !self
    }
}

impl Verdict for Uncertain<f64> {
    #[inline]
    fn bottom() -> Self {
        Uncertain::<f64>::point(0.0)
    }
    #[inline]
    fn top() -> Self {
        Uncertain::<f64>::point(1.0)
    }
    #[inline]
    fn meet(self, other: Self) -> Self {
        Self::from_root_node(UncertainNodeContent::ArithmeticOp {
            op: ArithmeticOperator::Min,
            lhs: self.root_node,
            rhs: other.root_node,
        })
    }
    #[inline]
    fn join(self, other: Self) -> Self {
        Self::from_root_node(UncertainNodeContent::ArithmeticOp {
            op: ArithmeticOperator::Max,
            lhs: self.root_node,
            rhs: other.root_node,
        })
    }
    #[inline]
    fn complement(self) -> Self {
        Uncertain::<f64>::point(1.0) - self
    }
}
