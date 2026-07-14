/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{Assumption, Causaloid, Model};
use std::fmt::Debug;
use std::sync::{Arc, RwLock};

impl<I, O, C> Model<I, O, C>
where
    I: Default,
    O: Default + Debug,
    C: Clone,
{
    pub fn id(&self) -> u64 {
        self.id
    }

    pub fn author(&self) -> &str {
        &self.author
    }

    pub fn description(&self) -> &str {
        &self.description
    }

    pub fn assumptions(&self) -> Option<&Arc<Vec<Assumption>>> {
        self.assumptions.as_ref()
    }

    /// Returns a reference to the root `Causaloid` of the model.
    ///
    /// The `Causaloid` encapsulates the core causal logic of the model.
    pub fn causaloid(&self) -> &Arc<Causaloid<I, O, (), Arc<RwLock<C>>>> {
        &self.causaloid
    }

    pub fn context(&self) -> Option<&Arc<RwLock<C>>> {
        self.context.as_ref()
    }
}
