/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

pub(crate) mod hkt_multivector;

pub(crate) mod hkt_multifield;
pub(crate) mod scalar_eval;
pub(crate) mod scalar_multivector;

// Iso extension: structural pack/unpack between CausalMultiField and
// its underlying carrier tuple. No feature flag; both
// `deep_causality_tensor` and `deep_causality_metric` are already
// multivector deps.
pub mod iso_multifield;
