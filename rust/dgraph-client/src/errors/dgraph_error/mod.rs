/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

mod dgraph_error_display;
mod dgraph_error_error;
mod dgraph_error_from;

use tonic::Code;

use crate::errors::auth_error::AuthError;
use crate::errors::connect_error::ConnectError;
use crate::errors::connection_string_error::ConnectionStringError;
use crate::errors::transaction_error::TransactionError;

/// The error type returned by every fallible operation on this crate's public API.
///
/// The wrapped classification is private; branch on [`DgraphError::kind`].
#[derive(Debug, Clone, PartialEq)]
pub struct DgraphError(DgraphErrorEnum);

/// Detailed classification of Dgraph client errors.
#[derive(Debug, Clone, PartialEq)]
#[non_exhaustive]
pub enum DgraphErrorEnum {
    /// A `dgraph://` connection string could not be parsed or validated.
    ConnectionString(ConnectionStringError),
    /// A connection could not be established or validated.
    Connect(ConnectError),
    /// Login or token refresh failed.
    Auth(AuthError),
    /// A transaction operation failed.
    Transaction(TransactionError),
    /// An RPC failed for a reason with no more specific classification.
    Rpc { code: Code, message: String },
}

impl DgraphError {
    pub(crate) fn new(variant: DgraphErrorEnum) -> Self {
        Self(variant)
    }

    /// Classification, for callers that need to branch on the failure.
    pub fn kind(&self) -> &DgraphErrorEnum {
        &self.0
    }

    /// Whether the failure was an aborted transaction, which the caller may wish to retry
    /// in a fresh transaction.
    pub fn is_aborted(&self) -> bool {
        match &self.0 {
            DgraphErrorEnum::Transaction(err) => err.is_aborted(),
            _ => false,
        }
    }

    /// Whether the failure was "cluster is still starting", which the caller may retry.
    pub fn is_cluster_not_ready(&self) -> bool {
        match &self.0 {
            DgraphErrorEnum::Connect(err) => err.is_cluster_not_ready(),
            _ => false,
        }
    }

    #[allow(non_snake_case)]
    pub fn ConnectionString(err: ConnectionStringError) -> Self {
        Self::new(DgraphErrorEnum::ConnectionString(err))
    }

    #[allow(non_snake_case)]
    pub fn Connect(err: ConnectError) -> Self {
        Self::new(DgraphErrorEnum::Connect(err))
    }

    #[allow(non_snake_case)]
    pub fn Auth(err: AuthError) -> Self {
        Self::new(DgraphErrorEnum::Auth(err))
    }

    #[allow(non_snake_case)]
    pub fn Transaction(err: TransactionError) -> Self {
        Self::new(DgraphErrorEnum::Transaction(err))
    }

    #[allow(non_snake_case)]
    pub fn Rpc(code: Code, message: String) -> Self {
        Self::new(DgraphErrorEnum::Rpc { code, message })
    }
}
