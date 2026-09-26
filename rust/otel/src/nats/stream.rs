//! JetStream stream creation, ownership claim and config reconciliation:
//! ensures the stream exists with the required subjects, claims it for the
//! otel log-collector and reconciles its retention and replica settings.
//!
//! Ownership (openspec `update-jetstream-storage-budget`, D6): the stream's
//! JetStream metadata key [`OWNER_METADATA_KEY`] names the one component that
//! reconciles its shape. The otel log-collector is the dedicated owner of its
//! stream (`events` by default), so on every start it sets the key to
//! [`OWNER_OTEL_LOG_COLLECTOR`], overriding an EventWriter fallback claim and
//! claiming a legacy stream with no metadata, in the same update that
//! reconciles the shape. The stream is a discard-old buffer, so `max_bytes` is
//! reconciled to the configured value even when that is below the bytes
//! stored: NATS then evicts the oldest messages.

use std::collections::HashMap;

use anyhow::{Result, anyhow};
use async_nats::jetstream;
use async_nats::jetstream::stream::StorageType;
use log::{debug, error, info, warn};

use super::NATSConfig;

fn subject_matches(pattern: &str, subject: &str) -> bool {
    let pattern_tokens: Vec<&str> = pattern.split('.').collect();
    let subject_tokens: Vec<&str> = subject.split('.').collect();

    let mut subject_index = 0;
    for (idx, token) in pattern_tokens.iter().enumerate() {
        match *token {
            ">" => return idx == pattern_tokens.len() - 1,
            "*" => {
                if subject_index >= subject_tokens.len() {
                    return false;
                }
                subject_index += 1;
            }
            literal => {
                if subject_index >= subject_tokens.len() || subject_tokens[subject_index] != literal
                {
                    return false;
                }
                subject_index += 1;
            }
        }
    }

    subject_index == subject_tokens.len()
}

fn missing_subjects(existing_subjects: &[String], required_subjects: &[String]) -> Vec<String> {
    required_subjects
        .iter()
        .filter(|required| {
            !existing_subjects
                .iter()
                .any(|existing| subject_matches(existing, required))
        })
        .cloned()
        .collect()
}

fn subject_is_wildcard(subject: &str) -> bool {
    subject.split('.').any(|token| matches!(token, "*" | ">"))
}

fn reconcile_subjects(existing_subjects: &[String], required_subjects: &[String]) -> Vec<String> {
    let mut reconciled = existing_subjects.to_vec();

    for required in required_subjects {
        if subject_is_wildcard(required) {
            reconciled
                .retain(|existing| existing == required || !subject_matches(required, existing));
        }

        if !reconciled
            .iter()
            .any(|existing| subject_matches(existing, required))
        {
            reconciled.push(required.clone());
        }
    }

    reconciled
}

/// Stream metadata key recording which component owns the stream shape.
pub(crate) const OWNER_METADATA_KEY: &str = "serviceradar.owner";
/// Ownership claim value of the otel log-collector.
pub(crate) const OWNER_OTEL_LOG_COLLECTOR: &str = "otel-log-collector";

/// Subjects the collector publishes to and therefore requires on the stream.
fn required_subjects(config: &NATSConfig) -> Vec<String> {
    let logs_subject = config
        .logs_subject
        .clone()
        .unwrap_or_else(|| format!("{}.logs", config.subject));
    vec![
        format!("{}.traces.>", config.subject),
        format!("{}.metrics.>", config.subject),
        logs_subject,
    ]
}

/// Config used when the stream is absent: created already claimed and at the
/// configured shape, so claim and shape land together.
fn create_stream_config(config: &NATSConfig) -> jetstream::stream::Config {
    jetstream::stream::Config {
        name: config.stream.clone(),
        subjects: required_subjects(config),
        storage: StorageType::File,
        max_bytes: config.max_bytes,
        max_age: config.max_age,
        num_replicas: config.stream_replicas,
        metadata: HashMap::from([(
            OWNER_METADATA_KEY.to_string(),
            OWNER_OTEL_LOG_COLLECTOR.to_string(),
        )]),
        ..Default::default()
    }
}

/// One field the reconcile changes, with its value before and after.
#[derive(Debug, Clone, PartialEq, Eq)]
struct ShapeChange {
    field: &'static str,
    before: String,
    after: String,
}

/// The update the collector applies to an existing stream.
#[derive(Debug, Clone)]
struct ReconcilePlan {
    /// The full stream config to send; equals the existing config when
    /// nothing changes.
    config: jetstream::stream::Config,
    /// Every changed field, in application order.
    changes: Vec<ShapeChange>,
    /// Subjects required by the collector that the stream did not cover.
    missing_subjects: Vec<String>,
    /// Legacy subjects replaced by a required wildcard that covers them.
    removed_subjects: Vec<String>,
    /// Bytes stored when the plan was made.
    stored_bytes: u64,
}

impl ReconcilePlan {
    fn needs_update(&self) -> bool {
        !self.changes.is_empty()
    }

    fn change(&self, field: &str) -> Option<&ShapeChange> {
        self.changes.iter().find(|change| change.field == field)
    }

    /// True when the new `max_bytes` is below what the stream holds, so
    /// applying it makes NATS evict the oldest messages (discard-old).
    fn evicts_oldest(&self) -> bool {
        self.change("max_bytes").is_some()
            && self.config.max_bytes > 0
            && self.stored_bytes > self.config.max_bytes.unsigned_abs()
    }
}

fn record_change<T: std::fmt::Debug + PartialEq>(
    changes: &mut Vec<ShapeChange>,
    field: &'static str,
    current: &mut T,
    desired: T,
) {
    if *current != desired {
        changes.push(ShapeChange {
            field,
            before: format!("{current:?}"),
            after: format!("{desired:?}"),
        });
        *current = desired;
    }
}

/// Decides how the collector reconciles an existing stream.
///
/// - Claims the stream: sets [`OWNER_METADATA_KEY`] to
///   [`OWNER_OTEL_LOG_COLLECTOR`] whatever it was before (an `event-writer`
///   claim or no metadata at all), keeping every other metadata key.
/// - Keeps every subject other writers added and adds the required ones
///   (a required wildcard replaces the specific subjects it covers).
/// - Reconciles `max_bytes`, `max_age` and `num_replicas` to the configured
///   values under the discard-old rule: the configured `max_bytes` is applied
///   even when it is below `stored_bytes`.
fn plan_reconcile(
    existing: &jetstream::stream::Config,
    stored_bytes: u64,
    config: &NATSConfig,
) -> ReconcilePlan {
    let required = required_subjects(config);
    let mut desired = existing.clone();
    let mut changes = Vec::new();

    let previous_owner = existing.metadata.get(OWNER_METADATA_KEY).cloned();
    if previous_owner.as_deref() != Some(OWNER_OTEL_LOG_COLLECTOR) {
        changes.push(ShapeChange {
            field: "metadata.serviceradar.owner",
            before: previous_owner.unwrap_or_else(|| "<none>".to_string()),
            after: OWNER_OTEL_LOG_COLLECTOR.to_string(),
        });
        desired.metadata.insert(
            OWNER_METADATA_KEY.to_string(),
            OWNER_OTEL_LOG_COLLECTOR.to_string(),
        );
    }

    let missing = missing_subjects(&existing.subjects, &required);
    let reconciled_subjects = reconcile_subjects(&existing.subjects, &required);
    let removed_subjects: Vec<String> = existing
        .subjects
        .iter()
        .filter(|subject| !reconciled_subjects.contains(*subject))
        .cloned()
        .collect();
    record_change(
        &mut changes,
        "subjects",
        &mut desired.subjects,
        reconciled_subjects,
    );

    record_change(
        &mut changes,
        "max_bytes",
        &mut desired.max_bytes,
        config.max_bytes,
    );
    record_change(
        &mut changes,
        "max_age",
        &mut desired.max_age,
        config.max_age,
    );
    record_change(
        &mut changes,
        "num_replicas",
        &mut desired.num_replicas,
        config.stream_replicas,
    );

    ReconcilePlan {
        config: desired,
        changes,
        missing_subjects: missing,
        removed_subjects,
        stored_bytes,
    }
}

fn log_plan(stream: &str, plan: &ReconcilePlan) {
    if !plan.missing_subjects.is_empty() {
        warn!(
            "Stream '{stream}' exists but is missing subjects: {:?}",
            plan.missing_subjects
        );
    }
    if !plan.removed_subjects.is_empty() {
        warn!(
            "Stream '{stream}' has legacy subjects covered by required wildcards; removing to avoid JetStream overlap: {:?}",
            plan.removed_subjects
        );
    }
    for change in &plan.changes {
        info!(
            "Reconciling stream '{stream}' {}: before={} after={}",
            change.field, change.before, change.after
        );
    }
    if plan.evicts_oldest() {
        warn!(
            "Stream '{stream}' holds {} bytes, above the configured max_bytes {}; \
             discard-old: NATS will evict the oldest messages",
            plan.stored_bytes, plan.config.max_bytes
        );
    }
}

pub(super) async fn ensure_stream(
    jetstream: &jetstream::Context,
    config: &NATSConfig,
) -> Result<()> {
    debug!("Creating/verifying JetStream stream: {}", config.stream);
    let create_config = create_stream_config(config);
    debug!("Stream will handle subjects: {:?}", create_config.subjects);

    // `fallback` marks the path where get-or-create failed and the stream was
    // fetched instead; there a failed update is fatal, as before.
    let (stream_info, fallback) = match jetstream.get_or_create_stream(create_config).await {
        Ok(mut stream) => (stream.info().await?.clone(), false),
        Err(e) => {
            // Stream may already exist with different subjects (e.g., created by another
            // pipeline like Flowgger). Fall back to fetching and updating it.
            warn!(
                "get_or_create_stream failed for '{}': {e}; attempting fetch-and-update",
                config.stream
            );
            match jetstream.get_stream(&config.stream).await {
                Ok(mut stream) => (stream.info().await?.clone(), true),
                Err(fetch_err) => {
                    error!(
                        "Failed to fetch existing stream '{}': {fetch_err}",
                        config.stream
                    );
                    return Err(anyhow!(
                        "Cannot create or update stream '{}': create={e}, fetch={fetch_err}",
                        config.stream
                    ));
                }
            }
        }
    };

    let plan = plan_reconcile(&stream_info.config, stream_info.state.bytes, config);
    if !plan.needs_update() {
        info!(
            "JetStream stream '{}' ready, claimed by {OWNER_OTEL_LOG_COLLECTOR}, with subjects: {:?}",
            config.stream, stream_info.config.subjects
        );
        return Ok(());
    }

    log_plan(&config.stream, &plan);
    info!(
        "Stream '{}' before update: owner={:?} max_bytes={} max_age={:?} replicas={} stored_bytes={}",
        config.stream,
        stream_info.config.metadata.get(OWNER_METADATA_KEY),
        stream_info.config.max_bytes,
        stream_info.config.max_age,
        stream_info.config.num_replicas,
        stream_info.state.bytes
    );
    debug!("Applying stream config update: {:?}", plan.config);

    match jetstream.update_stream(plan.config).await {
        Ok(updated) => {
            info!(
                "Stream '{}' after update: owner={:?} max_bytes={} max_age={:?} replicas={} stored_bytes={} subjects={:?}",
                config.stream,
                updated.config.metadata.get(OWNER_METADATA_KEY),
                updated.config.max_bytes,
                updated.config.max_age,
                updated.config.num_replicas,
                updated.state.bytes,
                updated.config.subjects
            );
            Ok(())
        }
        Err(e) if fallback => Err(anyhow!(
            "Failed to update stream '{}' after config mismatch: {e}",
            config.stream
        )),
        Err(e) => {
            error!(
                "Failed to update stream '{}' configuration: {e}",
                config.stream
            );
            Ok(())
        }
    }
}

#[cfg(test)]
#[path = "stream_tests.rs"]
mod tests;
