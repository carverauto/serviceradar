/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use super::*;

#[allow(clippy::type_complexity)]
impl<I, O, PS, C> PartialEq for Causaloid<I, O, PS, C>
where
    I: Default,
    O: Default + Debug,
    PS: Default + Clone,
    C: Clone,
{
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id
    }
}
