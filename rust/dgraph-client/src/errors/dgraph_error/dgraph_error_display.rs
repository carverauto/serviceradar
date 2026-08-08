/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use core::fmt::{Display, Formatter};

use super::{DgraphError, DgraphErrorEnum};

impl Display for DgraphError {
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        match self.kind() {
            DgraphErrorEnum::ConnectionString(err) => write!(f, "{err}"),
            DgraphErrorEnum::Connect(err) => write!(f, "{err}"),
            DgraphErrorEnum::Auth(err) => write!(f, "{err}"),
            DgraphErrorEnum::Transaction(err) => write!(f, "{err}"),
            DgraphErrorEnum::Rpc { code, message } => {
                write!(f, "RPC Error: {code:?}: {message}")
            }
        }
    }
}
