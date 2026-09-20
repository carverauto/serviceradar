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

//! Rebuild Dgraph topology from mapper evidence, or checksum AGE vs Dgraph.
//!
//! | Variable | Meaning |
//! |---|---|
//! | `AGE_TO_DGRAPH_MODE` | `rebuild` (default), `checksum`, or `dump-load`. |
//! | `AGE_TO_DGRAPH_ALLOW_LAB_DUMP` | Required for dump-load. Live dumps never enter git. |
//! | `DGRAPH_URL` | Topology cluster. |

use age_to_dgraph::{MigratorError, Mode, run};

#[tokio::main]
async fn main() {
    let arg = std::env::args().nth(1);
    let env_mode = std::env::var("AGE_TO_DGRAPH_MODE").ok();
    let mode = match Mode::parse(arg.as_deref().or(env_mode.as_deref())) {
        Ok(mode) => mode,
        Err(err) => {
            eprintln!("{err}");
            std::process::exit(2);
        }
    };

    if let Err(err) = run(mode).await {
        eprintln!("{err}");
        let code = match err {
            MigratorError::ChecksumMismatch(_) => 1,
            MigratorError::UnknownMode(_) | MigratorError::DumpLoadRefused => 2,
            _ => 1,
        };
        std::process::exit(code);
    }
}
