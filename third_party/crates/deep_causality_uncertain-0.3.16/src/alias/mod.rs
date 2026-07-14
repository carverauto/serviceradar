/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{MaybeUncertain, Uncertain};

pub type UncertainBool = Uncertain<bool>;
pub type UncertainF64 = Uncertain<f64>;

pub type MaybeUncertainBool = MaybeUncertain<bool>;
pub type MaybeUncertainF64 = MaybeUncertain<f64>;
