//! Unit tests for the private subject-matching and stream-subject
//! reconciliation helpers in [`super`] (included via `#[path]` so the
//! source file stays lean).

use super::*;

#[test]
fn subject_matching_respects_nats_wildcards() {
    assert!(subject_matches("logs.>", "logs.otel"));
    assert!(subject_matches("logs.*", "logs.otel"));
    assert!(subject_matches("otel.metrics.>", "otel.metrics.raw"));
    assert!(!subject_matches("logs.otel", "logs.>"));
    assert!(!subject_matches("logs.*", "logs.otel.raw"));
}

#[test]
fn missing_subjects_skips_required_subjects_covered_by_existing_wildcards() {
    let existing_subjects = vec!["logs.>".to_string(), "otel.metrics".to_string()];
    let required_subjects = vec![
        "logs.otel".to_string(),
        "logs.audit".to_string(),
        "otel.metrics".to_string(),
        "otel.metrics.raw".to_string(),
    ];

    assert_eq!(
        missing_subjects(&existing_subjects, &required_subjects),
        vec!["otel.metrics.raw".to_string()]
    );
}

#[test]
fn reconcile_subjects_replaces_legacy_specific_subjects_with_required_wildcards() {
    let existing_subjects = vec![
        "otel.traces".to_string(),
        "otel.metrics".to_string(),
        "otel.metrics.raw".to_string(),
        "logs.otel".to_string(),
    ];
    let required_subjects = vec![
        "otel.traces.>".to_string(),
        "otel.metrics.>".to_string(),
        "logs.otel".to_string(),
    ];

    assert_eq!(
        reconcile_subjects(&existing_subjects, &required_subjects),
        vec![
            "logs.otel".to_string(),
            "otel.traces.>".to_string(),
            "otel.metrics.>".to_string(),
        ]
    );
}
