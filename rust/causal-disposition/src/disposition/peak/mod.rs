// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Peak disposition — the Uncertainty-Aware Shrinkage Band (UASB).
//!
//! Judges an edge spike peak against the series' normal hour-of-day peak at
//! matched resolution (the hourly `max_value` profile), ramping suppression up
//! from limited data with a poison-bounded, two-sided, `(series,hod)`-localized
//! band. Mirrors the structure of the `seasonal` disposition: a robust summary is
//! aggregated in SQL, this kernel makes the O(1) `CausalFlow` decision.
//!
//! Design + invariants: `openspec/changes/add-anomaly-finding-disposition`.

mod band;
mod flow;
#[cfg(test)]
mod tests;
mod types;

pub use band::decide;
pub use flow::dispose_peak;
pub use types::{PassReason, PeakConfig, PeakDisposition, PeakOutcome, PeakRow};
