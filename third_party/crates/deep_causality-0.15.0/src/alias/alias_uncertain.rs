/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{CausalityError, Context, ProposedAction};
use deep_causality_uncertain::Uncertain;

// Type alias for the uncertain activation predicate function pointer.
#[allow(clippy::type_complexity)]
pub type UncertainActivationPredicate<D, S, T, ST, SYM, VS, VT> =
    fn(
        &Context<D, S, T, ST, SYM, VS, VT>,
        &ProposedAction,
    ) -> Result<Uncertain<bool>, CausalityError>;
