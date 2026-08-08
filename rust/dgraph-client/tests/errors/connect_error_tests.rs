/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use dgraph_client::{ConnectError, ConnectErrorEnum};
use tonic::Code;

// The Go client documents "the error text will contain Please retry" as the readiness
// contract. This replaces that with a typed predicate.
#[test]
fn cluster_not_ready_is_detectable_without_string_matching() {
    let err = ConnectError::ClusterNotReady(Code::Unavailable, "Please retry".to_string());

    assert!(err.is_cluster_not_ready());
    assert!(matches!(
        err.kind(),
        ConnectErrorEnum::ClusterNotReady { .. }
    ));
}

#[test]
fn other_failures_are_not_cluster_not_ready() {
    assert!(!ConnectError::NoEndpoints().is_cluster_not_ready());
    assert!(!ConnectError::Transport("boom".to_string()).is_cluster_not_ready());
    assert!(!ConnectError::ProbeFailed(Code::Internal, "boom".to_string()).is_cluster_not_ready());
}

#[test]
fn transport_failures_are_detectable_without_string_matching() {
    assert!(ConnectError::Transport("broken pipe".to_string()).is_transport());

    // A server that answered and said no is not a transport failure, however unavailable
    // the code sounds: retrying it would retry a rejection.
    assert!(
        !ConnectError::ClusterNotReady(Code::Unavailable, "Please retry".to_string())
            .is_transport()
    );
    assert!(!ConnectError::NoEndpoints().is_transport());
    assert!(!ConnectError::ProbeFailed(Code::Internal, "boom".to_string()).is_transport());
}

#[test]
fn invalid_endpoint_reports_which_endpoint() {
    let err = ConnectError::InvalidEndpoint("bad:host".to_string(), "reason".to_string());

    assert!(format!("{err}").contains("bad:host"));
}
