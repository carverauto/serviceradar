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

mod topology_error_display;
mod topology_error_error;
#[cfg(test)]
mod topology_error_tests;

/// Why a topology operation failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TopologyError(TopologyErrorEnum);

/// Classification of [`TopologyError`].
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum TopologyErrorEnum {
    /// The cluster could not be reached.
    Connect { target: String, reason: String },
    /// A Dgraph operation failed.
    Dgraph(String),
    /// A Dgraph operation failed in a way a fresh attempt may not: a transport
    /// failure, an aborted transaction, or a cluster that is still starting.
    Transient(String),
    /// Response JSON was not the expected shape.
    Serde(String),
    /// A caller value cannot be placed in DQL (quote or newline).
    InvalidValue(String),
    /// Conditional upsert `@if` did not fire: named query block was empty.
    ConditionSkipped { block: String, key: String },
}

impl TopologyError {
    pub(crate) fn new(variant: TopologyErrorEnum) -> Self {
        Self(variant)
    }

    /// Classification, for callers that need to branch on the failure.
    #[must_use]
    pub fn kind(&self) -> &TopologyErrorEnum {
        &self.0
    }

    /// The target is redacted here, not by the caller: this variant reaches the
    /// application log on every failed write and must never carry the ACL
    /// password.
    #[allow(non_snake_case)]
    #[must_use]
    pub fn Connect(target: String, reason: String) -> Self {
        Self::new(TopologyErrorEnum::Connect {
            target: dgraph_migrate::redact_userinfo(&target),
            reason,
        })
    }

    #[allow(non_snake_case)]
    #[must_use]
    pub fn Dgraph(reason: String) -> Self {
        Self::new(TopologyErrorEnum::Dgraph(reason))
    }

    #[allow(non_snake_case)]
    #[must_use]
    pub fn Transient(reason: String) -> Self {
        Self::new(TopologyErrorEnum::Transient(reason))
    }

    /// Classify a failed Dgraph RPC, keeping the client's own retryability
    /// verdict and adding the failures a Zero or Alpha leader election causes,
    /// so every caller sees one classification instead of re-deriving it from
    /// message text later.
    pub(crate) fn from_dgraph(err: &dgraph_client::DgraphError) -> Self {
        if err.is_transport() || err.is_aborted() || err.is_cluster_not_ready() || election(err) {
            Self::Transient(err.to_string())
        } else {
            Self::Dgraph(err.to_string())
        }
    }

    /// Whether a fresh attempt of the same operation may succeed. Connection
    /// failures count: the cluster may be restarting or briefly unreachable.
    #[must_use]
    pub fn is_transient(&self) -> bool {
        matches!(
            self.0,
            TopologyErrorEnum::Transient(_) | TopologyErrorEnum::Connect { .. }
        )
    }

    #[allow(non_snake_case)]
    #[must_use]
    pub fn Serde(reason: String) -> Self {
        Self::new(TopologyErrorEnum::Serde(reason))
    }

    #[allow(non_snake_case)]
    #[must_use]
    pub fn InvalidValue(value: String) -> Self {
        Self::new(TopologyErrorEnum::InvalidValue(value))
    }

    #[allow(non_snake_case)]
    #[must_use]
    pub fn ConditionSkipped(block: String, key: String) -> Self {
        Self::new(TopologyErrorEnum::ConditionSkipped { block, key })
    }
}

/// Messages Dgraph returns, with gRPC code `Unknown`, while a Zero or Alpha
/// group has no leader or is moving its leader. Dgraph gives them no status
/// code of their own, so the text is the only signal; the Dgraph Go client
/// documents the same "Please retry" contract. Each clears once a leader is
/// elected, and the transaction was not committed.
const ELECTION_MESSAGES: [&str; 3] = [
    // Zero refused a commit or abort decision because it is not the leader.
    "Only leader can decide to commit or abort",
    // An Alpha has no connection to the group leader it must reach.
    "No connection exists",
    // A server that is starting or between leaders asks the client to retry.
    "Please retry",
];

/// Whether `err` is an RPC failure caused by a leader election: a deadline that
/// passed while the group had no leader, or one of [`ELECTION_MESSAGES`].
fn election(err: &dgraph_client::DgraphError) -> bool {
    match err.kind() {
        dgraph_client::DgraphErrorEnum::Rpc { code, message } => {
            *code == tonic::Code::DeadlineExceeded
                || (*code == tonic::Code::Unknown
                    && ELECTION_MESSAGES.iter().any(|text| message.contains(text)))
        }
        _ => false,
    }
}
