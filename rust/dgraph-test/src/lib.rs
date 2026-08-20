/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

//! Obtain a running Dgraph for a test, wherever the test happens to run.
//!
//! ```no_run
//! # use dgraph_test::DgraphInstance;
//! let dgraph = DgraphInstance::acquire()?;
//! // dgraph.connection_string() -> "dgraph://host:port[?sslmode=...]"
//! # Ok::<(), dgraph_test::FixtureError>(())
//! ```
//!
//! # One input decides everything
//!
//! `SERVICERADAR_ENV` names an environment; the committed instance for that environment supplies
//! the endpoint, and the environment's *kind* supplies the strategy for making that endpoint
//! usable. `localhost` provisions a `dgraph/standalone` container; `ci` verifies the Dgraph the
//! cluster already runs. Both come from the same [`Identity`], so the address a caller dials and
//! the way it was obtained cannot disagree.
//!
//! Deliberately NOT a Docker probe and NOT a `CI=true` variable. Detecting Docker answers "can I
//! start a container", never "may I" -- a workstation with Docker running and `SERVICERADAR_ENV=ci`
//! exported would happily start one while the configuration points at a shared cluster. A CI
//! variable is a second declaration of a fact this repository already declares once.
//!
//! # This crate does not connect to Dgraph
//!
//! Readiness is decided over Dgraph's HTTP `/health?all` endpoint, so nothing here links a gRPC
//! client and nothing here needs a CA: a liveness check asks whether something is serving, not who
//! it is. Establishing a verified session is the client's job, which is also what keeps the
//! dependency arrow pointing one way -- `dgraph-client`'s own tests can use this crate.
//!
//! # Ownership is part of the answer
//!
//! [`DgraphInstance::exclusivity`] reports whether this process created the instance. A container
//! it started is [`Exclusivity::Exclusive`] and may be wiped; the CI cluster is
//! [`Exclusivity::Shared`] and must not be. Callers that destroy data are expected to branch on
//! it, because nothing else can tell them apart from the endpoint alone.

#![forbid(unsafe_code)]

pub mod errors;
pub mod traits;
pub mod types;
pub mod utils_tests;

pub use crate::errors::fixture_error::{FixtureError, FixtureErrorEnum};
pub use crate::traits::instance_provider::InstanceProvider;
pub use crate::types::container_provider::ContainerProvider;
pub use crate::types::dgraph_instance::DgraphInstance;
pub use crate::types::endpoint::Endpoint;
pub use crate::types::exclusivity::Exclusivity;
pub use crate::types::existing_provider::ExistingProvider;
pub use crate::types::health_report::{HealthReport, ServerHealth};
pub use crate::types::run_id::RunId;
pub use crate::types::strategy::Strategy;
