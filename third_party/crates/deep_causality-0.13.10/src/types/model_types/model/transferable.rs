/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//!
//! Implementation of the Transferable trait for the Model struct.
//!

use crate::{Assumption, Model, Transferable};
use std::fmt::Debug;
use std::sync::Arc;

impl<I, O, C> Transferable for Model<I, O, C>
where
    I: Default,
    O: Default + Debug,
    C: Clone,
{
    fn get_assumptions(&self) -> &Option<Arc<Vec<Assumption>>> {
        &self.assumptions
    }
    // verify_assumptions is derived from the Transferable trait. Overwrite for customization.
    // fn verify_assumptions(&self, effect: &[PropagatingEffect]) -> Result<bool, AssumptionError> {}
}
