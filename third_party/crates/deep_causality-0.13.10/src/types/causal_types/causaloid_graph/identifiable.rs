/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{CausaloidGraph, CausaloidId, Identifiable};

impl Identifiable for CausaloidGraph<CausaloidId> {
    fn id(&self) -> u64 {
        self.id
    }
}
