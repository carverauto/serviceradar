/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::EffectValue;

impl<T: PartialEq> PartialEq for EffectValue<T> {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::None, Self::None) => true,
            (Self::Value(a), Self::Value(b)) => a == b,
            (Self::ContextualLink(a1, a2), Self::ContextualLink(b1, b2)) => a1 == b1 && a2 == b2,
            (Self::RelayTo(a_target, _), Self::RelayTo(b_target, _)) => a_target == b_target,
            #[cfg(feature = "std")]
            (Self::Map(_), Self::Map(_)) => false, // Maps are not comparable
            _ => false,
        }
    }
}
