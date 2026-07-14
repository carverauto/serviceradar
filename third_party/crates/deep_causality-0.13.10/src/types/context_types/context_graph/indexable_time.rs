/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::traits::contextuable::space_temporal::SpaceTemporal;
use crate::traits::contextuable::spatial::Spatial;
use crate::traits::contextuable::temporal::Temporal;
use crate::{Context, CurrentTimeIndex, Datable, PreviousTimeIndex, Symbolic, TimeIndexable};

// Adds the default implementation to Context when the trait is imported. Can be overwritten to customize.
impl<D, S, T, ST, SYM, VS, VT> CurrentTimeIndex for Context<D, S, T, ST, SYM, VS, VT>
where
    D: Datable + Clone,
    S: Spatial<VS> + Clone,
    T: Temporal<VT> + Clone,
    ST: SpaceTemporal<VS, VT> + Clone,
    SYM: Symbolic + Clone,
    VS: Clone,
    VT: Clone,
{
}

// Adds the default implementation to Context when the trait is imported. Can be overwritten to customize.
impl<D, S, T, ST, SYM, VS, VT> PreviousTimeIndex for Context<D, S, T, ST, SYM, VS, VT>
where
    D: Datable + Clone,
    S: Spatial<VS> + Clone,
    T: Temporal<VT> + Clone,
    ST: SpaceTemporal<VS, VT> + Clone,
    SYM: Symbolic + Clone,
    VS: Clone,
    VT: Clone,
{
}

// Adds the set/get index methods used in CurrentTimeIndex and PreviousTimeIndex.
#[allow(clippy::type_complexity)]
impl<D, S, T, ST, SYM, VS, VT> TimeIndexable for Context<D, S, T, ST, SYM, VS, VT>
where
    D: Datable + Clone,
    S: Spatial<VS> + Clone,
    T: Temporal<VT> + Clone,
    ST: SpaceTemporal<VS, VT> + Clone,
    SYM: Symbolic + Clone,
    VS: Clone,
    VT: Clone,
{
    fn get_time_index(&self, key: &usize, current: bool) -> Option<&usize> {
        if current {
            self.current_index_map.get(key)
        } else {
            self.previous_index_map.get(key)
        }
    }

    fn set_time_index(&mut self, key: usize, index: usize, current: bool) {
        if current {
            self.current_index_map.insert(key, index);
        } else {
            self.previous_index_map.insert(key, index);
        }
    }
}
