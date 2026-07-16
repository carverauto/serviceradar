/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::sync::{Arc, RwLock};

use crate::{DescriptionValue, EvalFn, IdentificationValue};

mod assumable;
mod debug;
mod display;
mod identifiable;

// Interior mutability in Rust, part 2: thread safety
// https://ricardomartins.cc/2016/06/25/interior-mutability-thread-safety
type ArcRWLock<T> = Arc<RwLock<T>>;

#[derive(Clone)]
pub struct Assumption {
    id: IdentificationValue,
    description: DescriptionValue,
    assumption_fn: EvalFn,
    assumption_tested: ArcRWLock<bool>,
    assumption_valid: ArcRWLock<bool>,
}

// Constructor
impl Assumption {
    pub fn new(
        id: IdentificationValue,
        description: DescriptionValue,
        assumption_fn: EvalFn,
    ) -> Self {
        Self {
            id,
            description,
            assumption_fn,
            assumption_tested: Arc::new(RwLock::new(false)),
            assumption_valid: Arc::new(RwLock::new(false)),
        }
    }
}
