/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

pub mod ext_hkt;

// Some extensions are feature-gated. `ext_iso` bridges to
// `deep_causality_tensor` (the CausalTensor <-> CsrMatrix iso) and is
// opt-in via the `tensor-iso` Cargo feature so default sparse users
// don't pay the dep cost.
#[cfg(feature = "tensor-iso")]
pub mod ext_iso;
