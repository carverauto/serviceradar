/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

//! Operations available only on a read-write transaction.

use proto_dgraph::api;
use tonic::Code;

use super::Txn;
use crate::errors::dgraph_error::DgraphError;
use crate::errors::transaction_error::TransactionError;
use crate::types::mutation::Mutation;
use crate::types::read_write::ReadWrite;
use crate::types::response::Response;

impl Txn<ReadWrite> {
    /// Apply a mutation.
    ///
    /// When the mutation is marked commit-now the transaction is committed in the same
    /// round trip and cannot be reused afterwards.
    ///
    /// If the mutation fails the transaction is discarded and every later operation
    /// returns [`TransactionError::Finished`].
    pub async fn mutate(&mut self, mutation: Mutation) -> Result<Response, DgraphError> {
        let commit_now = mutation.is_commit_now();
        let request = api::Request {
            mutations: vec![mutation.into_proto()],
            commit_now,
            ..Default::default()
        };

        self.do_request(request).await
    }

    /// Run a query and one or more mutations as a single upsert.
    pub async fn upsert<I>(
        &mut self,
        query: impl Into<String>,
        mutations: I,
        commit_now: bool,
    ) -> Result<Response, DgraphError>
    where
        I: IntoIterator<Item = Mutation>,
    {
        let request = api::Request {
            query: query.into(),
            mutations: mutations.into_iter().map(Mutation::into_proto).collect(),
            commit_now,
            ..Default::default()
        };

        self.do_request(request).await
    }

    /// Commit the transaction.
    ///
    /// Consumes the transaction, so reuse afterwards does not compile. Committing a
    /// transaction that never mutated succeeds without issuing an RPC.
    ///
    /// Returns [`TransactionError::Aborted`] when a concurrent transaction modified the
    /// same data. Retrying is the caller's decision, and requires a new transaction.
    pub async fn commit(mut self) -> Result<(), DgraphError> {
        if self.finished {
            return Err(TransactionError::Finished().into());
        }

        self.finished = true;

        if !self.mutated {
            return Ok(());
        }

        let context = self.txn_context(false);
        match self.send_commit_or_abort(context).await {
            Ok(_) => Ok(()),
            Err(status) if status.code() == Code::Aborted => {
                Err(TransactionError::Aborted(status.code(), status.message().to_string()).into())
            }
            Err(status) => Err(status.into()),
        }
    }
}
