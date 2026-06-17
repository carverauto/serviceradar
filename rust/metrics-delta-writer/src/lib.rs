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

//! `serviceradar-metrics-delta-writer` — batch-writes raw metric points from the
//! metrics JetStream durable into a Delta Lake table on object storage.
//!
//! Skeleton (OpenSpec: `add-delta-metrics-lakehouse`). The NATS -> decode -> row
//! pipeline is wired against a pluggable [`sink::DeltaSink`]; the real Delta sink
//! (the `deltalake` crate) is task 3.1 and is currently stubbed by
//! [`sink::LoggingSink`] so this crate compiles and the ingest path can be
//! exercised end to end before the heavy dependency lands.

pub mod config;
pub mod pipeline;
pub mod sink;

use thiserror::Error;

/// Errors raised by the writer pipeline.
#[derive(Debug, Error)]
pub enum Error {
    /// A NATS / JetStream operation failed.
    #[error("nats: {0}")]
    Nats(String),
    /// A `MetricBatch` payload could not be decoded.
    #[error("decode: {0}")]
    Decode(#[from] prost::DecodeError),
    /// The Delta sink rejected a write.
    #[error("sink: {0}")]
    Sink(String),
    /// Any other error.
    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

/// Crate result alias.
pub type Result<T> = std::result::Result<T, Error>;
