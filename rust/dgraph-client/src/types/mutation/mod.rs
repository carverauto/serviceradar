/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use proto_dgraph::api;

/// A set of data changes to apply in a transaction.
///
/// Changes can be expressed as JSON or as RDF N-Quads, and a single mutation may both set
/// and delete. Building a mutation issues no RPC; it is applied by
/// [`Txn::mutate`](crate::Txn) or [`Txn::upsert`](crate::Txn).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Mutation {
    inner: api::Mutation,
}

impl Mutation {
    /// An empty mutation.
    pub fn new() -> Self {
        Self::default()
    }

    /// Set data expressed as JSON.
    pub fn set_json(mut self, json: impl Into<Vec<u8>>) -> Self {
        self.inner.set_json = json.into();
        self
    }

    /// Delete data expressed as JSON.
    pub fn delete_json(mut self, json: impl Into<Vec<u8>>) -> Self {
        self.inner.delete_json = json.into();
        self
    }

    /// Set data expressed as RDF N-Quads.
    pub fn set_nquads(mut self, nquads: impl Into<Vec<u8>>) -> Self {
        self.inner.set_nquads = nquads.into();
        self
    }

    /// Delete data expressed as RDF N-Quads.
    pub fn delete_nquads(mut self, nquads: impl Into<Vec<u8>>) -> Self {
        self.inner.del_nquads = nquads.into();
        self
    }

    /// Condition guarding an upsert, as an `@if` directive.
    pub fn cond(mut self, cond: impl Into<String>) -> Self {
        self.inner.cond = cond.into();
        self
    }

    /// Commit the enclosing transaction in the same round trip.
    pub fn commit_now(mut self) -> Self {
        self.inner.commit_now = true;
        self
    }

    /// Delete every edge of `predicates` on the node `uid`.
    ///
    /// Builds the mutation only; nothing is sent until it is applied.
    pub fn delete_edges<I, S>(mut self, uid: impl Into<String>, predicates: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        let uid = uid.into();
        let star_all = api::Value {
            val: Some(api::value::Val::DefaultVal("_STAR_ALL".to_string())),
        };

        self.inner
            .del
            .extend(predicates.into_iter().map(|predicate| api::NQuad {
                subject: uid.clone(),
                predicate: predicate.into(),
                object_value: Some(star_all.clone()),
                ..Default::default()
            }));

        self
    }

    /// Whether this mutation commits its transaction.
    pub fn is_commit_now(&self) -> bool {
        self.inner.commit_now
    }

    pub(crate) fn into_proto(self) -> api::Mutation {
        self.inner
    }
}
