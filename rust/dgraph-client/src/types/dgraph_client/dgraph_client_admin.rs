/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

//! Schema, namespace, lease, and transaction-less DQL operations.

use std::collections::BTreeMap;

use proto_dgraph::api;

use super::DgraphClient;
use crate::errors::dgraph_error::DgraphError;
use crate::types::lease_range::LeaseRange;
use crate::types::response::Response;

impl DgraphClient {
    /// Run one RPC, refreshing the access token once if it has expired.
    ///
    /// Generic over the closure rather than taking a boxed future, so the whole path stays
    /// statically dispatched.
    async fn with_token_refresh<T, F, Fut>(&self, mut call: F) -> Result<T, DgraphError>
    where
        F: FnMut() -> Fut,
        Fut: Future<Output = Result<T, tonic::Status>>,
    {
        let status = match call().await {
            Ok(value) => return Ok(value),
            Err(status) => status,
        };

        if !Self::is_token_expired(&status) || !self.can_refresh().await {
            return Err(status.into());
        }

        // Exactly one retry, no backoff, matching the Go client.
        self.refresh_token(&status).await?;
        call().await.map_err(Into::into)
    }

    async fn alter(&self, operation: api::Operation) -> Result<(), DgraphError> {
        self.with_token_refresh(|| {
            let operation = operation.clone();
            async move {
                let mut stub = self.stub();
                stub.alter(self.authenticated(operation).await)
                    .await
                    .map(|_| ())
            }
        })
        .await
    }

    /// Apply a schema definition.
    pub async fn set_schema(&self, schema: impl Into<String>) -> Result<(), DgraphError> {
        self.alter(api::Operation {
            schema: schema.into(),
            ..Default::default()
        })
        .await
    }

    /// Drop all data **and** schema. Irreversible.
    pub async fn drop_all(&self) -> Result<(), DgraphError> {
        self.alter(api::Operation {
            drop_all: true,
            drop_op: api::operation::DropOp::All as i32,
            ..Default::default()
        })
        .await
    }

    /// Drop all data, keeping the schema. Irreversible.
    pub async fn drop_data(&self) -> Result<(), DgraphError> {
        self.alter(api::Operation {
            drop_op: api::operation::DropOp::Data as i32,
            ..Default::default()
        })
        .await
    }

    /// Drop a single predicate and its data.
    pub async fn drop_predicate(&self, predicate: impl Into<String>) -> Result<(), DgraphError> {
        self.alter(api::Operation {
            drop_op: api::operation::DropOp::Attr as i32,
            drop_value: predicate.into(),
            ..Default::default()
        })
        .await
    }

    /// Drop a single type definition.
    pub async fn drop_type(&self, type_name: impl Into<String>) -> Result<(), DgraphError> {
        self.alter(api::Operation {
            drop_op: api::operation::DropOp::Type as i32,
            drop_value: type_name.into(),
            ..Default::default()
        })
        .await
    }

    /// Run DQL without an enclosing transaction.
    ///
    /// The query may be a read, a mutation, or an upsert.
    pub async fn run_dql(&self, query: impl Into<String>) -> Result<Response, DgraphError> {
        self.run_dql_with_vars(query, Vec::<(String, String)>::new(), false, false)
            .await
    }

    /// Run DQL without an enclosing transaction, with variables and read options.
    ///
    /// `best_effort` implies `read_only`, matching the Go client, where the option setter
    /// forces both.
    pub async fn run_dql_with_vars<K, V, I>(
        &self,
        query: impl Into<String>,
        vars: I,
        read_only: bool,
        best_effort: bool,
    ) -> Result<Response, DgraphError>
    where
        I: IntoIterator<Item = (K, V)>,
        K: Into<String>,
        V: Into<String>,
    {
        let request = api::RunDqlRequest {
            dql_query: query.into(),
            vars: vars
                .into_iter()
                .map(|(key, value)| (key.into(), value.into()))
                .collect(),
            read_only: read_only || best_effort,
            best_effort,
            resp_format: api::request::RespFormat::Json as i32,
        };

        let response = self
            .with_token_refresh(|| {
                let request = request.clone();
                async move {
                    let mut stub = self.stub();
                    stub.run_dql(self.authenticated(request).await)
                        .await
                        .map(tonic::Response::into_inner)
                }
            })
            .await?;

        Ok(Response::new(response))
    }

    /// Create a namespace, returning its id.
    pub async fn create_namespace(&self) -> Result<u64, DgraphError> {
        let response = self
            .with_token_refresh(|| async move {
                let mut stub = self.stub();
                stub.create_namespace(self.authenticated(api::CreateNamespaceRequest {}).await)
                    .await
                    .map(tonic::Response::into_inner)
            })
            .await?;

        Ok(response.namespace)
    }

    /// Drop a namespace by id. Irreversible.
    pub async fn drop_namespace(&self, namespace: u64) -> Result<(), DgraphError> {
        self.with_token_refresh(|| async move {
            let mut stub = self.stub();
            stub.drop_namespace(
                self.authenticated(api::DropNamespaceRequest { namespace })
                    .await,
            )
            .await
            .map(|_| ())
        })
        .await
    }

    /// List namespace ids.
    ///
    /// Returned as a `BTreeMap` so iteration order is deterministic, which the protobuf
    /// map does not guarantee.
    pub async fn list_namespaces(&self) -> Result<BTreeMap<u64, u64>, DgraphError> {
        let response = self
            .with_token_refresh(|| async move {
                let mut stub = self.stub();
                stub.list_namespaces(self.authenticated(api::ListNamespacesRequest {}).await)
                    .await
                    .map(tonic::Response::into_inner)
            })
            .await?;

        Ok(response
            .namespaces
            .into_iter()
            .map(|(id, namespace)| (id, namespace.id))
            .collect())
    }

    async fn allocate(
        &self,
        how_many: u64,
        lease_type: api::LeaseType,
    ) -> Result<LeaseRange, DgraphError> {
        let response = self
            .with_token_refresh(|| {
                let request = api::AllocateIDsRequest {
                    how_many,
                    lease_type: lease_type as i32,
                };
                async move {
                    let mut stub = self.stub();
                    // prost preserves the `IDs` acronym in the message name and renders
                    // the rpc as `allocate_i_ds`. Both spellings are generated, not ours.
                    stub.allocate_i_ds(self.authenticated(request).await)
                        .await
                        .map(tonic::Response::into_inner)
                }
            })
            .await?;

        Ok(LeaseRange::new(response.start, response.end))
    }

    /// Lease a range of node uids.
    pub async fn allocate_uids(&self, how_many: u64) -> Result<LeaseRange, DgraphError> {
        self.allocate(how_many, api::LeaseType::Uid).await
    }

    /// Lease a range of timestamps.
    pub async fn allocate_timestamps(&self, how_many: u64) -> Result<LeaseRange, DgraphError> {
        self.allocate(how_many, api::LeaseType::Ts).await
    }

    /// Lease a range of namespace ids.
    pub async fn allocate_namespaces(&self, how_many: u64) -> Result<LeaseRange, DgraphError> {
        self.allocate(how_many, api::LeaseType::Ns).await
    }

    /// Log in with the configured ACL credentials, replacing any cached tokens.
    ///
    /// Called automatically by the constructor when credentials are present.
    pub async fn relogin(&self) -> Result<(), DgraphError> {
        self.login().await
    }
}
