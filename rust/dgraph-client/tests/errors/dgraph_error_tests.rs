/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use dgraph_client::{
    ConnectError, ConnectionStringError, DgraphError, DgraphErrorEnum, TransactionError,
};
use tonic::{Code, Status};

#[test]
fn wraps_each_component_error() {
    let err = DgraphError::from(ConnectionStringError::MissingPort());
    assert!(matches!(err.kind(), DgraphErrorEnum::ConnectionString(_)));

    let err = DgraphError::from(ConnectError::NoEndpoints());
    assert!(matches!(err.kind(), DgraphErrorEnum::Connect(_)));

    let err = DgraphError::from(TransactionError::Finished());
    assert!(matches!(err.kind(), DgraphErrorEnum::Transaction(_)));
}

// Status is flattened at the boundary so this crate's errors stay Clone + PartialEq and
// no transport type reaches the public API.
#[test]
fn flattens_status_into_code_and_message() {
    let err = DgraphError::from(Status::new(Code::NotFound, "missing"));

    match err.kind() {
        DgraphErrorEnum::Rpc { code, message } => {
            assert_eq!(*code, Code::NotFound);
            assert_eq!(message, "missing");
        }
        other => panic!("unexpected classification: {other:?}"),
    }
}

#[test]
fn predicates_delegate_to_the_wrapped_error() {
    let aborted = DgraphError::from(TransactionError::Aborted(Code::Aborted, String::new()));
    assert!(aborted.is_aborted());
    assert!(!aborted.is_cluster_not_ready());

    let not_ready = DgraphError::from(ConnectError::ClusterNotReady(
        Code::Unavailable,
        "Please retry".to_string(),
    ));
    assert!(not_ready.is_cluster_not_ready());
    assert!(!not_ready.is_aborted());
}

#[test]
fn display_delegates_to_the_wrapped_error() {
    let inner = ConnectionStringError::MissingPort();
    let expected = format!("{inner}");

    let err = DgraphError::from(inner);
    assert_eq!(format!("{err}"), expected);
}
