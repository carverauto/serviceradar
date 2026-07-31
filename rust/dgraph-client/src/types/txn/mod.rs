/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

mod txn_drop;
mod txn_read_only;
mod txn_read_write;

use std::collections::BTreeSet;
use std::marker::PhantomData;

use proto_dgraph::api;
use proto_dgraph::api::dgraph_client::DgraphClient as DgraphStub;
use tonic::Code;
use tonic::transport::Channel;

use crate::errors::dgraph_error::DgraphError;
use crate::errors::transaction_error::TransactionError;
use crate::types::dgraph_client::DgraphClient;
use crate::types::response::Response;

/// A single atomic transaction.
///
/// The state parameter separates what a transaction may do:
///
/// - [`Txn<ReadWrite>`] can query, mutate, commit, and discard.
/// - [`Txn<ReadOnly>`] can query, request best-effort reads, and discard. Mutating or
///   committing one does not compile.
///
/// `commit` and `discard` consume the transaction, so using one after completion does not
/// compile either.
///
/// # Dropping without completing
///
/// Dropping a transaction that performed mutations without committing or discarding does
/// **not** issue any RPC: async work cannot run in `Drop`. Server-side state persists
/// until the cluster times the transaction out. A warning is logged through `tracing` when
/// this happens. Prefer an explicit `commit` or `discard`.
pub struct Txn<State> {
    client: DgraphClient,
    /// Pinned for the transaction's lifetime. A transaction is server-side state tied to
    /// one alpha, so round-robining mid-transaction would break it.
    channel: Channel,
    start_ts: u64,
    hash: String,
    keys: BTreeSet<String>,
    preds: BTreeSet<String>,
    mutated: bool,
    finished: bool,
    best_effort: bool,
    /// Mirrors the type-state onto the wire request. The type is the authority; this is
    /// set once by the constructor so the request builder does not need a `'static`
    /// bound just to ask what state it is in.
    read_only: bool,
    state: PhantomData<State>,
}

impl<State> Txn<State> {
    pub(crate) fn create(client: DgraphClient, read_only: bool) -> Self {
        let channel = client.next_channel();
        Self {
            client,
            channel,
            start_ts: 0,
            hash: String::new(),
            keys: BTreeSet::new(),
            preds: BTreeSet::new(),
            mutated: false,
            finished: false,
            best_effort: false,
            read_only,
            state: PhantomData,
        }
    }

    fn stub(&self) -> DgraphStub<Channel> {
        DgraphStub::new(self.channel.clone())
    }

    fn is_read_only(&self) -> bool {
        self.read_only
    }

    /// Run a query returning JSON.
    pub async fn query(&mut self, query: impl Into<String>) -> Result<Response, DgraphError> {
        self.query_with_vars(query, Vec::<(String, String)>::new())
            .await
    }

    /// Run a query returning JSON, with query variables.
    ///
    /// Variables are sent as a separate map rather than interpolated, which is what makes
    /// them injection-safe.
    pub async fn query_with_vars<K, V, I>(
        &mut self,
        query: impl Into<String>,
        vars: I,
    ) -> Result<Response, DgraphError>
    where
        I: IntoIterator<Item = (K, V)>,
        K: Into<String>,
        V: Into<String>,
    {
        let request = self.build_query(query, vars, api::request::RespFormat::Json);
        self.do_request(request).await
    }

    /// Run a query returning RDF.
    pub async fn query_rdf(&mut self, query: impl Into<String>) -> Result<Response, DgraphError> {
        self.query_rdf_with_vars(query, Vec::<(String, String)>::new())
            .await
    }

    /// Run a query returning RDF, with query variables.
    pub async fn query_rdf_with_vars<K, V, I>(
        &mut self,
        query: impl Into<String>,
        vars: I,
    ) -> Result<Response, DgraphError>
    where
        I: IntoIterator<Item = (K, V)>,
        K: Into<String>,
        V: Into<String>,
    {
        let request = self.build_query(query, vars, api::request::RespFormat::Rdf);
        self.do_request(request).await
    }

    fn build_query<K, V, I>(
        &self,
        query: impl Into<String>,
        vars: I,
        format: api::request::RespFormat,
    ) -> api::Request
    where
        I: IntoIterator<Item = (K, V)>,
        K: Into<String>,
        V: Into<String>,
    {
        api::Request {
            query: query.into(),
            vars: vars
                .into_iter()
                .map(|(key, value)| (key.into(), value.into()))
                .collect(),
            read_only: self.is_read_only(),
            best_effort: self.best_effort,
            resp_format: format as i32,
            ..Default::default()
        }
    }

    /// Send a caller-built request.
    ///
    /// This is the escape hatch for driving the protocol directly. Because the request may
    /// carry mutations the type system cannot see, the read-only check is enforced here at
    /// runtime; everywhere else it is a compile error.
    pub(crate) async fn do_request(
        &mut self,
        mut request: api::Request,
    ) -> Result<Response, DgraphError> {
        if self.finished {
            return Err(TransactionError::Finished().into());
        }

        let has_mutations = !request.mutations.is_empty();
        if has_mutations {
            if self.is_read_only() {
                return Err(TransactionError::ReadOnly().into());
            }
            // Set before the RPC: a mutation that fails still dirtied the transaction, so
            // the commit path must know it needs a server-side abort.
            self.mutated = true;
        }

        // The transaction's own context always wins over whatever the caller set.
        request.start_ts = self.start_ts;
        request.hash = self.hash.clone();
        let commit_now = request.commit_now;

        match self.send_query(request).await {
            Ok(response) => {
                if commit_now {
                    self.finished = true;
                }
                self.merge_context(response)
            }
            Err(status) => {
                if has_mutations {
                    // Match the Go client: a failed mutation ends the transaction. The
                    // discard error is deliberately dropped so the caller sees the cause.
                    let _ = self.abort().await;
                    self.finished = true;

                    if status.code() == Code::Aborted {
                        return Err(TransactionError::Aborted(
                            status.code(),
                            status.message().to_string(),
                        )
                        .into());
                    }
                }
                Err(status.into())
            }
        }
    }

    /// Issue the query RPC, refreshing the access token once if it has expired.
    async fn send_query(&self, request: api::Request) -> Result<api::Response, tonic::Status> {
        let mut stub = self.stub();

        let first = stub
            .query(self.client.authenticated(request.clone()).await)
            .await;

        let status = match first {
            Ok(response) => return Ok(response.into_inner()),
            Err(status) => status,
        };

        if !DgraphClient::is_token_expired(&status) || !self.client.can_refresh().await {
            return Err(status);
        }

        // Exactly one retry, with no backoff, matching the Go client.
        if self.client.refresh_token(&status).await.is_err() {
            return Err(status);
        }

        stub.query(self.client.authenticated(request).await)
            .await
            .map(tonic::Response::into_inner)
    }

    /// Merge the server's transaction context into ours.
    fn merge_context(&mut self, response: api::Response) -> Result<Response, DgraphError> {
        let wrapped = Response::new(response);

        let Some(context) = wrapped.txn_context() else {
            return Ok(wrapped);
        };

        self.hash = context.hash.clone();

        if self.start_ts == 0 {
            self.start_ts = context.start_ts;
        } else if self.start_ts != context.start_ts {
            // Client and server disagree about which transaction this is. The Go client
            // returns both the response and this error; retaining the response keeps that
            // information rather than dropping it into a `Result`'s error arm.
            let expected = self.start_ts;
            let found = context.start_ts;
            return Err(TransactionError::StartTsMismatch(expected, found, wrapped).into());
        }

        self.keys.extend(context.keys.iter().cloned());
        self.preds.extend(context.preds.iter().cloned());

        Ok(wrapped)
    }

    /// Send `CommitOrAbort`, refreshing the access token once if it has expired.
    async fn send_commit_or_abort(
        &self,
        context: api::TxnContext,
    ) -> Result<api::TxnContext, tonic::Status> {
        let mut stub = self.stub();

        let first = stub
            .commit_or_abort(self.client.authenticated(context.clone()).await)
            .await;

        let status = match first {
            Ok(response) => return Ok(response.into_inner()),
            Err(status) => status,
        };

        if !DgraphClient::is_token_expired(&status) || !self.client.can_refresh().await {
            return Err(status);
        }

        if self.client.refresh_token(&status).await.is_err() {
            return Err(status);
        }

        stub.commit_or_abort(self.client.authenticated(context).await)
            .await
            .map(tonic::Response::into_inner)
    }

    fn txn_context(&self, aborted: bool) -> api::TxnContext {
        api::TxnContext {
            start_ts: self.start_ts,
            hash: self.hash.clone(),
            aborted,
            keys: self.keys.iter().cloned().collect(),
            preds: self.preds.iter().cloned().collect(),
            ..Default::default()
        }
    }

    /// Abort server-side state without consuming `self`, for the internal poison path.
    async fn abort(&mut self) -> Result<(), DgraphError> {
        if !self.mutated {
            return Ok(());
        }
        self.send_commit_or_abort(self.txn_context(true)).await?;
        Ok(())
    }

    /// Discard the transaction, releasing server-side state.
    ///
    /// A no-op that issues no RPC when nothing was mutated, and safe to call on a
    /// transaction that has already finished.
    pub async fn discard(mut self) -> Result<(), DgraphError> {
        if self.finished || !self.mutated {
            self.finished = true;
            return Ok(());
        }

        self.finished = true;
        self.send_commit_or_abort(self.txn_context(true)).await?;
        Ok(())
    }

    /// Start timestamp, once the server has assigned one. Zero before the first request.
    pub fn start_ts(&self) -> u64 {
        self.start_ts
    }

    /// Whether this transaction has performed any mutation.
    pub fn has_mutated(&self) -> bool {
        self.mutated
    }
}
