/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use core::fmt::{Display, Formatter};

use super::{ConnectError, ConnectErrorEnum};

// The endpoint is rendered but never the userinfo: endpoints reaching this type are the
// host:port authority only, with credentials already split off by the parser.
impl Display for ConnectError {
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        match self.kind() {
            ConnectErrorEnum::NoEndpoints => write!(
                f,
                "No Endpoints: a client must target at least one endpoint"
            ),
            ConnectErrorEnum::InvalidEndpoint { endpoint, reason } => {
                write!(f, "Invalid Endpoint: '{endpoint}': {reason}")
            }
            ConnectErrorEnum::Transport(msg) => write!(f, "Transport Error: {msg}"),
            ConnectErrorEnum::Tls(msg) => write!(f, "TLS Error: {msg}"),
            ConnectErrorEnum::ClusterNotReady { code, message } => write!(
                f,
                "Cluster Not Ready: the cluster is not yet accepting requests ({code:?}: \
                 {message})"
            ),
            ConnectErrorEnum::ProbeFailed { code, message } => {
                write!(f, "Probe Failed: {code:?}: {message}")
            }
        }
    }
}
