/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use std::collections::HashMap;

use proto_dgraph::api;

/// A query or mutation response.
///
/// This is an owned wrapper around the generated protobuf message. The generated type is
/// never exposed: keeping it internal is what lets the bindings be regenerated without
/// breaking consumers of this crate.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Response {
    inner: api::Response,
}

impl Response {
    pub(crate) fn new(inner: api::Response) -> Self {
        Self { inner }
    }

    /// JSON payload of a query response. Empty when the RDF format was requested.
    pub fn json(&self) -> &[u8] {
        &self.inner.json
    }

    /// RDF payload of a query response. Empty unless the RDF format was requested.
    pub fn rdf(&self) -> &[u8] {
        &self.inner.rdf
    }

    /// Mapping of blank node label to allocated uid. Only populated by mutations.
    pub fn uids(&self) -> &HashMap<String, String> {
        &self.inner.uids
    }

    /// Start timestamp of the transaction this response belongs to, if any.
    pub fn start_ts(&self) -> Option<u64> {
        self.inner.txn.as_ref().map(|txn| txn.start_ts)
    }

    /// Commit timestamp, populated once the transaction has committed.
    pub fn commit_ts(&self) -> Option<u64> {
        self.inner.txn.as_ref().map(|txn| txn.commit_ts)
    }

    /// Whether the server reports this transaction as aborted.
    pub fn aborted(&self) -> bool {
        self.inner.txn.as_ref().is_some_and(|txn| txn.aborted)
    }

    /// Conflict-detection keys returned by the server for this request.
    pub fn keys(&self) -> &[String] {
        self.inner.txn.as_ref().map_or(&[], |txn| &txn.keys)
    }

    /// Predicates involved in this request.
    pub fn preds(&self) -> &[String] {
        self.inner.txn.as_ref().map_or(&[], |txn| &txn.preds)
    }

    pub(crate) fn txn_context(&self) -> Option<&api::TxnContext> {
        self.inner.txn.as_ref()
    }
}
