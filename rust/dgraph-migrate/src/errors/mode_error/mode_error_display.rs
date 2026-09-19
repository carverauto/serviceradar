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

use std::fmt::{Display, Formatter};

use super::{ModeError, ModeErrorEnum};
use crate::utils::mode_env::{CONFIRM_ENV, CONFIRM_VALUE};

impl Display for ModeError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match &self.0 {
            ModeErrorEnum::Unrecognised(value) => {
                write!(f, "unrecognised DGRAPH_MIGRATION_MODE: {value}")
            }
            ModeErrorEnum::RefusedInUnknownEnvironment => {
                write!(f, "deprovision is refused in an unknown environment")
            }
            ModeErrorEnum::ConfirmationRequired => {
                write!(
                    f,
                    "deprovision of CLUSTER requires {CONFIRM_ENV}={CONFIRM_VALUE}"
                )
            }
        }
    }
}
