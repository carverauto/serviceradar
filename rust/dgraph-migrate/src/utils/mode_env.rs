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

/// Environment variable selecting the operation.
pub const MODE_ENV: &str = "DGRAPH_MIGRATION_MODE";

/// Environment variable acknowledging a destructive operation.
pub const CONFIRM_ENV: &str = "DGRAPH_MIGRATION_CONFIRM";

/// Where this run thinks it is (`LOCAL`, `CI`, `CLUSTER`).
pub const ENV_ENV: &str = "DGRAPH_ENV";

/// The value [`CONFIRM_ENV`] must hold. Deliberately not `true` or `1`.
pub const CONFIRM_VALUE: &str = "I-UNDERSTAND-THIS-DESTROYS-DATA";

/// A set, non-empty environment variable.
pub(crate) fn read(key: &str) -> Option<String> {
    std::env::var(key).ok().filter(|value| !value.is_empty())
}
