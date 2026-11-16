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

use dgraph_client::DgraphError;
use tonic::Code;

use super::TopologyError;

fn rpc(code: Code, message: &str) -> TopologyError {
    TopologyError::from_dgraph(&DgraphError::Rpc(code, message.to_string()))
}

// A Zero or Alpha leader change surfaces as these RPC failures. Each clears once a
// leader is elected, so a fresh attempt may succeed.
#[test]
fn leader_change_and_election_failures_are_transient() {
    for (code, message) in [
        (Code::Unknown, "Only leader can decide to commit or abort"),
        (Code::Unknown, "No connection exists"),
        (
            Code::Unknown,
            "Please retry again, server is not ready to accept requests",
        ),
        (Code::DeadlineExceeded, "context deadline exceeded"),
        (Code::Unavailable, "connection refused"),
    ] {
        assert!(
            rpc(code, message).is_transient(),
            "{code:?}: {message} must be transient"
        );
    }
}

// Rejections of the request itself fail the same way on every attempt.
#[test]
fn schema_and_validation_rejections_stay_permanent() {
    for (code, message) in [
        (
            Code::Unknown,
            "Schema not defined for predicate: device.example",
        ),
        (
            Code::InvalidArgument,
            "while lexing upsert block: unexpected token",
        ),
        (
            Code::PermissionDenied,
            "unauthorized to mutate the predicate",
        ),
    ] {
        assert!(
            !rpc(code, message).is_transient(),
            "{code:?}: {message} must stay permanent"
        );
    }
}
