/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

//! Generic Dgraph schema runner extracted from scrith's migrator shape.
//!
//! The schema **string** and the predicate/type **lists** are parameters
//! ([`SchemaSpec`]). This crate never owns a product schema and never calls
//! `drop_all`. Scrith's SMDB schema stays in scrith; ServiceRadar topology
//! schema lives in `dgraph-topology`.

mod errors;
mod types;
mod utils;

pub use crate::errors::{MigrateError, MigrateErrorEnum, ModeError, ModeErrorEnum};
pub use crate::types::{
    EXIT_CURRENT, EXIT_DEPROVISIONED, EXIT_FAILED, EXIT_MIGRATED, EXIT_REJECTED, Environment, Mode,
    Outcome, SchemaReport, SchemaSpec,
};
pub use crate::utils::endpoint::{
    HOST_ENV, PORT_DEFAULT, PORT_ENV, URL_ENV, resolve, resolve_from,
};
pub use crate::utils::migrate::{connect, run, run_from_env, run_with_client};
pub use crate::utils::mode_env::{CONFIRM_ENV, CONFIRM_VALUE, ENV_ENV, MODE_ENV};
pub use crate::utils::schema::{apply, remove, verify};
