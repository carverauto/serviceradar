/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

// `Intervenable<Value>` is now a super-trait of `AlternatableValue<Value>`
// with a default `intervene` method that delegates to `alternate_value`,
// plus a blanket impl over `AlternatableValue<V>` (see
// `crate::traits::intervenable`). The carrier therefore picks up
// `Intervenable<Value>` automatically through its `AlternatableValue<Value>`
// impl in `alternatable_value.rs`. No explicit `Intervenable for
// CausalEffectPropagationProcess<...>` impl is required here, and adding
// one would conflict with the blanket.
//
// This file is kept to preserve the existing module wiring and as a
// signpost for future readers; the operation itself lives in
// `alternatable_value.rs`.
