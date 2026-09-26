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

const GIB: i64 = 1024 * 1024 * 1024;

/// The collector's configured `events` shape: 2 GiB, 3 replicas, 30 minutes.
fn events_config() -> NATSConfig {
    NATSConfig {
        stream: "events".to_string(),
        subject: "otel".to_string(),
        max_bytes: 2 * GIB,
        max_age: std::time::Duration::from_secs(30 * 60),
        stream_replicas: 3,
        ..NATSConfig::default()
    }
}

/// An existing `events` stream as another writer left it: synthetic subjects
/// and sizes, optional owner claim.
fn existing_events(
    owner: Option<&str>,
    max_bytes: i64,
    replicas: usize,
) -> jetstream::stream::Config {
    let mut metadata = HashMap::new();
    if let Some(owner) = owner {
        metadata.insert(OWNER_METADATA_KEY.to_string(), owner.to_string());
    }
    jetstream::stream::Config {
        name: "events".to_string(),
        subjects: vec![
            "otel.traces.>".to_string(),
            "otel.metrics.>".to_string(),
            "otel.logs".to_string(),
        ],
        storage: StorageType::File,
        max_bytes,
        max_age: std::time::Duration::from_secs(30 * 60),
        num_replicas: replicas,
        metadata,
        ..Default::default()
    }
}

fn owner_of(config: &jetstream::stream::Config) -> Option<&str> {
    config.metadata.get(OWNER_METADATA_KEY).map(String::as_str)
}

#[test]
fn claim_overrides_an_event_writer_claim() {
    let mut existing = existing_events(Some("event-writer"), 2 * GIB, 3);
    existing
        .metadata
        .insert("example.note".to_string(), "kept".to_string());

    let plan = plan_reconcile(&existing, 0, &events_config());

    assert!(plan.needs_update());
    assert_eq!(owner_of(&plan.config), Some(OWNER_OTEL_LOG_COLLECTOR));
    assert_eq!(
        plan.change("metadata.serviceradar.owner"),
        Some(&ShapeChange {
            field: "metadata.serviceradar.owner",
            before: "event-writer".to_string(),
            after: OWNER_OTEL_LOG_COLLECTOR.to_string(),
        })
    );
    // Other metadata keys survive the claim.
    assert_eq!(
        plan.config.metadata.get("example.note").map(String::as_str),
        Some("kept")
    );
    // Shape already matched: the claim is the only change.
    assert_eq!(plan.changes.len(), 1);
}

#[test]
fn legacy_stream_without_metadata_is_claimed_and_reconciled() {
    let existing = existing_events(None, 8 * GIB, 1);

    let plan = plan_reconcile(&existing, GIB as u64, &events_config());

    assert!(plan.needs_update());
    assert_eq!(owner_of(&plan.config), Some(OWNER_OTEL_LOG_COLLECTOR));
    assert_eq!(
        plan.change("metadata.serviceradar.owner")
            .map(|c| c.before.as_str()),
        Some("<none>")
    );
    // The claim and the shape land in the same update.
    assert_eq!(plan.config.max_bytes, 2 * GIB);
    assert_eq!(plan.config.num_replicas, 3);
}

#[test]
fn shrink_below_stored_bytes_is_applied_discard_old_with_before_and_after() {
    // A full 10 GiB legacy buffer holding 9 GiB, configured down to 2 GiB.
    let existing = existing_events(Some("event-writer"), 10 * GIB, 1);
    let stored = 9 * GIB as u64;

    let plan = plan_reconcile(&existing, stored, &events_config());

    // Discard-old: the configured value is applied even though it is below
    // what is stored; NATS evicts the oldest messages.
    assert_eq!(plan.config.max_bytes, 2 * GIB);
    assert!(plan.evicts_oldest());
    assert_eq!(
        plan.change("max_bytes"),
        Some(&ShapeChange {
            field: "max_bytes",
            before: (10 * GIB).to_string(),
            after: (2 * GIB).to_string(),
        })
    );
    assert_eq!(
        plan.change("num_replicas"),
        Some(&ShapeChange {
            field: "num_replicas",
            before: "1".to_string(),
            after: "3".to_string(),
        })
    );
    // ...and in the same update that claims the stream.
    assert_eq!(owner_of(&plan.config), Some(OWNER_OTEL_LOG_COLLECTOR));

    // A grow of a full 1 GiB stream does not evict.
    let grow = plan_reconcile(&existing_events(None, GIB, 3), GIB as u64, &events_config());
    assert_eq!(grow.config.max_bytes, 2 * GIB);
    assert!(!grow.evicts_oldest());
}

#[test]
fn subjects_other_writers_added_are_kept_while_claiming() {
    // EventWriter created `events` and added its own subjects; the
    // collector's traces and metrics wildcards are missing.
    let mut existing = existing_events(Some("event-writer"), 2 * GIB, 3);
    existing.subjects = vec![
        "events.ocsf.>".to_string(),
        "logs.>".to_string(),
        "otel.logs".to_string(),
    ];

    let plan = plan_reconcile(&existing, 0, &events_config());

    assert_eq!(
        plan.config.subjects,
        vec![
            "events.ocsf.>".to_string(),
            "logs.>".to_string(),
            "otel.logs".to_string(),
            "otel.traces.>".to_string(),
            "otel.metrics.>".to_string(),
        ]
    );
    assert!(plan.removed_subjects.is_empty());
    assert_eq!(
        plan.missing_subjects,
        vec!["otel.traces.>".to_string(), "otel.metrics.>".to_string()]
    );
    assert_eq!(owner_of(&plan.config), Some(OWNER_OTEL_LOG_COLLECTOR));
}

#[test]
fn created_stream_is_claimed_at_the_configured_shape_and_then_stable() {
    let config = events_config();
    let created = create_stream_config(&config);

    assert_eq!(owner_of(&created), Some(OWNER_OTEL_LOG_COLLECTOR));
    assert_eq!(created.max_bytes, 2 * GIB);
    assert_eq!(created.num_replicas, 3);

    // A restart against the stream it created issues no update.
    let plan = plan_reconcile(&created, GIB as u64, &config);
    assert!(
        !plan.needs_update(),
        "unexpected changes: {:?}",
        plan.changes
    );
}
