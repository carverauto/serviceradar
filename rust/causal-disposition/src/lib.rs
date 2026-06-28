// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Graft #1 (panic-safety): no disposition closure may unwind across the future
// NIF/FFI boundary. An `unwrap`/`expect`/`panic` inside a `CausalFlow` closure
// would unwind through Rustler and take down a BEAM scheduler thread. Every gate
// (insufficient baseline, zero variance, non-finite sample) MUST return through
// the disposition/error channel as a [`Disposition`] variant instead. The
// `corrective_ddos_detector` template's `.expect("DetectorConfig present")` is
// exactly the antipattern this lint forbids. Keep this at the crate root.
#![deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

//! Central disposition kernels (seasonal residual-z, capacity forecast): robust
//! statistics hosted on the shared `CausalFlow` pipeline combinator from
//! `anomaly-core`. The hosting is plumbing — these kernels do not perform causal
//! inference (no SCM, intervention, or counterfactual).
//!
//! The operator directive moves seasonal and capacity statistics out of the BEAM
//! and runs them in Rust. This crate is the *second* consumer of
//! [`serviceradar_anomaly_core`] (the edge anomaly add-on is the first): it adds
//! the seasonal residual-z and the capacity forecast kernels on top of the same
//! `CausalFlow` pipeline-combinator + streaming primitives, so there is one
//! statistical implementation (hosted on, not reasoning with, that combinator) for
//! both delivery shapes.
//!
//! This crate carries **zero** new detector math beyond the disposition kernels;
//! the streaming primitives ([`serviceradar_anomaly_core::stats`], the
//! `CausalFlow` carrier, the clean/breach branch semantics) come from
//! `anomaly-core`. It also carries **no** `rustler` dependency by default — the
//! typed NIF ABI derives are feature-gated behind the `rustler` feature so this
//! crate stays linkable by bazel, by `cargo test`, and by `correlation-engine`
//! without pulling the proc-macro tree.
//!
//! Phase scope: this crate ships the seasonal kernel first (net-new, no parity
//! gate). The capacity port (`disposition::capacity`) is a parity-gated follow-up.

pub mod disposition;

pub use disposition::capacity::{
    CapacityConfig, CapacityDisposition, CapacityModelKind, CapacityPoint, CapacityRow,
    dispose_capacity,
};
pub use disposition::peak_profile::{
    PeakProfileAction, PeakProfileBand, PeakProfileConfig, PeakProfileDisposition, PeakProfileRow,
    dispose_peak_profile,
};
pub use disposition::seasonal::{
    SeasonalConfig, SeasonalDisposition, SeasonalRow, dispose_seasonal,
};
pub use disposition::{CapacityForecast, Disposition, RobustStatistic};
