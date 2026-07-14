/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::types::effect_value::EffectValue;

impl<T> EffectValue<T> {
    pub const fn is_none(&self) -> bool {
        matches!(self, Self::None)
    }

    pub const fn is_value(&self) -> bool {
        matches!(self, Self::Value(_))
    }

    pub const fn is_contextual_link(&self) -> bool {
        matches!(self, Self::ContextualLink(_, _))
    }

    pub const fn is_relay_to(&self) -> bool {
        matches!(self, Self::RelayTo(_, _))
    }

    #[cfg(feature = "std")]
    pub const fn is_map(&self) -> bool {
        matches!(self, Self::Map(_))
    }

    pub const fn as_value(&self) -> Option<&T> {
        match self {
            Self::Value(v) => Some(v),
            _ => None,
        }
    }

    pub fn into_value(self) -> Option<T> {
        match self {
            Self::Value(v) => Some(v),
            _ => None,
        }
    }
}
