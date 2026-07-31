/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use dgraph_client::{TransactionError, TransactionErrorEnum};
use tonic::Code;

#[test]
fn constructors_produce_matching_classification() {
    assert!(matches!(
        TransactionError::Finished().kind(),
        TransactionErrorEnum::Finished
    ));
    assert!(matches!(
        TransactionError::ReadOnly().kind(),
        TransactionErrorEnum::ReadOnly
    ));
}

// Unlike the Go client, which overwrites the status with a fixed sentinel, the abort
// reason survives.
#[test]
fn aborted_retains_status_code_and_message() {
    let err = TransactionError::Aborted(Code::Aborted, "conflicting txn".to_string());

    match err.kind() {
        TransactionErrorEnum::Aborted { code, message } => {
            assert_eq!(*code, Code::Aborted);
            assert_eq!(message, "conflicting txn");
        }
        other => panic!("unexpected classification: {other:?}"),
    }
}

#[test]
fn is_aborted_predicate_avoids_string_matching() {
    assert!(TransactionError::Aborted(Code::Aborted, String::new()).is_aborted());
    assert!(!TransactionError::Finished().is_aborted());
}

#[test]
fn display_does_not_require_callers_to_string_match() {
    let err = TransactionError::Aborted(Code::Aborted, "conflict".to_string());

    // Display is for humans; the predicate above is the programmatic contract.
    assert!(format!("{err}").contains("Aborted"));
}
