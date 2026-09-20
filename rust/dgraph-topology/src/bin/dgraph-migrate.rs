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

//! One-shot topology schema migrator. Configuration is environmental.
//!
//! | Variable | Meaning |
//! |---|---|
//! | `DGRAPH_ENV` | `LOCAL`, `CI`, or `CLUSTER`. Empty is LOCAL. |
//! | `DGRAPH_URL` | Full `dgraph://` URL. Wins over host/port. |
//! | `DGRAPH_HOST` / `DGRAPH_PORT` | Assembled URL when `DGRAPH_URL` is unset. |
//! | `DGRAPH_MIGRATION_MODE` | `MIGRATE` (default), `STATUS`, or `DEPROVISION`. |
//! | `DGRAPH_MIGRATION_CONFIRM` | Required to deprovision CLUSTER. |

use dgraph_migrate::{EXIT_FAILED, EXIT_REJECTED, MigrateErrorEnum, run_from_env};
use dgraph_topology::schema_spec;

#[tokio::main]
async fn main() {
    match run_from_env(schema_spec()).await {
        Ok(outcome) => {
            eprintln!("{outcome:?}");
            std::process::exit(i32::from(outcome.exit_code()));
        }
        Err(err) => {
            eprintln!("{err}");
            let code = match err.kind() {
                MigrateErrorEnum::Mode(_) | MigrateErrorEnum::Endpoint(_) => EXIT_REJECTED,
                _ => EXIT_FAILED,
            };
            std::process::exit(i32::from(code));
        }
    }
}
