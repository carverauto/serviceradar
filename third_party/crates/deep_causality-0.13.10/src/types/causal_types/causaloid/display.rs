/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use super::*;

#[allow(clippy::type_complexity)]
impl<I, O, PS, C> Display for Causaloid<I, O, PS, C>
where
    I: Default,
    O: Default + Debug,
    PS: Default + Clone,
    C: Clone,
{
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        self.fmt_causaloid(f)
    }
}

impl<I, O, PS, C> Debug for Causaloid<I, O, PS, C>
where
    I: Default,
    O: Default + Debug,
    PS: Default + Clone,
    C: Clone,
{
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        self.fmt_causaloid(f)
    }
}

impl<I, O, PS, C> Causaloid<I, O, PS, C>
where
    I: Default,
    O: Default + Debug,
    PS: Default + Clone,
    C: Clone,
{
    fn fmt_causaloid(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "Causaloid id: {} \n Causaloid type: {} \n description: {}",
            self.id, self.causal_type, self.description,
        )
    }
}
