/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::types::effect_value::EffectValue;
use core::fmt::Display;
use core::fmt::Formatter;

impl<T: Display> Display for EffectValue<T> {
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::None => write!(f, "None"),
            Self::Value(v) => write!(f, "Value({})", v),
            Self::ContextualLink(ctx_id, ctxoid_id) => {
                write!(f, "ContextualLink({}, {})", ctx_id, ctxoid_id)
            }
            Self::RelayTo(target, _) => write!(f, "RelayTo({})", target),
            #[cfg(feature = "std")]
            Self::Map(_) => write!(f, "Map(...)"),
        }
    }
}
