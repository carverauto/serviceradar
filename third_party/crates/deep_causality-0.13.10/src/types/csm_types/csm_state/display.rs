/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalState;
use std::fmt::{Debug, Display, Formatter};

impl<I, O, C> Display for CausalState<I, O, C>
where
    I: Debug + Default,
    O: Default + Debug,
    C: Clone,
{
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "CausalState: id: {} version: {} data: {{:?}} causaloid: {} {}",
            self.id, self.version, self.data, self.causaloid,
        )
    }
}
