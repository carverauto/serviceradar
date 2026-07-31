/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use tonic::Status;

use super::DgraphError;
use crate::errors::auth_error::AuthError;
use crate::errors::connect_error::ConnectError;
use crate::errors::connection_string_error::ConnectionStringError;
use crate::errors::transaction_error::TransactionError;

impl From<ConnectionStringError> for DgraphError {
    fn from(err: ConnectionStringError) -> Self {
        Self::ConnectionString(err)
    }
}

impl From<ConnectError> for DgraphError {
    fn from(err: ConnectError) -> Self {
        Self::Connect(err)
    }
}

impl From<AuthError> for DgraphError {
    fn from(err: AuthError) -> Self {
        Self::Auth(err)
    }
}

impl From<TransactionError> for DgraphError {
    fn from(err: TransactionError) -> Self {
        Self::Transaction(err)
    }
}

// Flatten the status at the boundary: `tonic::Status` is `Clone`-only, so retaining one
// would cost this crate's errors their `PartialEq`, and it would leak a transport type
// into the public API.
impl From<Status> for DgraphError {
    fn from(status: Status) -> Self {
        Self::Rpc(status.code(), status.message().to_string())
    }
}
