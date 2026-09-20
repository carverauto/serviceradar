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

mod environment;
mod mode;
mod outcome;
mod schema_report;
mod schema_spec;

pub use environment::Environment;
pub use mode::Mode;
pub use outcome::{
    EXIT_CURRENT, EXIT_DEPROVISIONED, EXIT_FAILED, EXIT_MIGRATED, EXIT_REJECTED, Outcome,
};
pub use schema_report::SchemaReport;
pub use schema_spec::SchemaSpec;
