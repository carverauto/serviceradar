/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{CausalAction, CausalState};
use std::collections::HashMap;

/// A tuple consisting of a causal state and an associated causal action.
///
/// This is used to represent the result of state-action reasoning steps.
pub type StateAction<I, O, C> = (CausalState<I, O, C>, CausalAction);

pub type CSMMap<I, O, C> = HashMap<usize, StateAction<I, O, C>>;

pub type CSMStateActions<I, O, C> = [StateAction<I, O, C>];
