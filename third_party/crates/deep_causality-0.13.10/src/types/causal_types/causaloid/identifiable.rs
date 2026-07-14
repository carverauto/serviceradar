/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{Causaloid, Identifiable};
use std::fmt::Debug;

#[allow(clippy::type_complexity)]
impl<I, O, PS, C> Identifiable for Causaloid<I, O, PS, C>
where
    I: Default,
    O: Default + Debug,
    PS: Default + Clone,
    C: Clone,
{
    fn id(&self) -> u64 {
        self.id
    }
}
