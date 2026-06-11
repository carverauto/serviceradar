//! JetStream stream creation and config reconciliation: ensures the stream
//! exists with the required subjects, retention, and replica settings.

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

pub(super) async fn ensure_stream(
    jetstream: &jetstream::Context,
    config: &NATSConfig,
) -> Result<()> {
    debug!("Creating/verifying JetStream stream: {}", config.stream);
    let logs_subject = config
        .logs_subject
        .clone()
        .unwrap_or_else(|| format!("{}.logs", config.subject));
    let subjects = vec![
        format!("{}.traces.>", config.subject),
        format!("{}.metrics.>", config.subject),
        logs_subject.clone(),
    ];
    debug!("Stream will handle subjects: {subjects:?}");

    let desired_config = jetstream::stream::Config {
        name: config.stream.clone(),
        subjects: subjects.clone(),
        storage: StorageType::File,
        max_bytes: config.max_bytes,
        max_age: config.max_age,
        num_replicas: config.stream_replicas,
        ..Default::default()
    };

    match jetstream.get_or_create_stream(desired_config.clone()).await {
        Ok(mut stream) => {
            let stream_info = stream.info().await?;
            let existing_subjects = &stream_info.config.subjects;
            let mut needs_update = false;
            let mut updated_config = stream_info.config.clone();

            let missing_subjects = missing_subjects(existing_subjects, &subjects);

            if !missing_subjects.is_empty() {
                warn!(
                    "Stream '{}' exists but is missing subjects: {:?}",
                    config.stream, missing_subjects
                );
                warn!("Current subjects: {existing_subjects:?}");

                for subject in missing_subjects {
                    updated_config.subjects.push(subject);
                    needs_update = true;
                }
            }

            let reconciled_subjects = reconcile_subjects(existing_subjects, &subjects);
            if reconciled_subjects != *existing_subjects {
                let removed_subjects: Vec<String> = existing_subjects
                    .iter()
                    .filter(|subject| !reconciled_subjects.contains(*subject))
                    .cloned()
                    .collect();
                if !removed_subjects.is_empty() {
                    warn!(
                        "Stream '{}' has legacy subjects covered by required wildcards; removing to avoid JetStream overlap: {:?}",
                        config.stream, removed_subjects
                    );
                }
                updated_config.subjects = reconciled_subjects;
                needs_update = true;
            }

            if updated_config.max_bytes != config.max_bytes {
                debug!(
                    "Updating stream '{}' max_bytes from {} to {}",
                    config.stream, updated_config.max_bytes, config.max_bytes
                );
                updated_config.max_bytes = config.max_bytes;
                needs_update = true;
            }

            if updated_config.max_age != config.max_age {
                debug!(
                    "Updating stream '{}' max_age from {:?} to {:?}",
                    config.stream, updated_config.max_age, config.max_age
                );
                updated_config.max_age = config.max_age;
                needs_update = true;
            }

            if updated_config.num_replicas != config.stream_replicas {
                debug!(
                    "Updating stream '{}' replicas from {} to {}",
                    config.stream, updated_config.num_replicas, config.stream_replicas
                );
                updated_config.num_replicas = config.stream_replicas;
                needs_update = true;
            }

            if needs_update {
                debug!("Applying stream config update: {:?}", updated_config);
                match jetstream.update_stream(updated_config).await {
                    Ok(updated_info) => {
                        info!(
                            "Successfully updated stream '{}' configuration",
                            config.stream
                        );
                        debug!(
                            "Updated config: subjects={:?}, max_bytes={}, max_age={:?}",
                            updated_info.config.subjects,
                            updated_info.config.max_bytes,
                            updated_info.config.max_age
                        );
                    }
                    Err(e) => {
                        error!(
                            "Failed to update stream '{}' configuration: {e}",
                            config.stream
                        );
                    }
                }
            } else {
                info!(
                    "JetStream stream '{}' ready with subjects: {:?}",
                    config.stream, existing_subjects
                );
            }
        }
        Err(e) => {
            // Stream may already exist with different subjects (e.g., created by another
            // pipeline like Flowgger). Fall back to fetching and updating it.
            warn!(
                "get_or_create_stream failed for '{}': {e}; attempting fetch-and-update",
                config.stream
            );
            match jetstream.get_stream(&config.stream).await {
                Ok(mut stream) => {
                    let stream_info = stream.info().await?;
                    let existing_subjects = &stream_info.config.subjects;
                    let mut updated_config = stream_info.config.clone();
                    let mut needs_update = false;
                    let missing_subjects = missing_subjects(&updated_config.subjects, &subjects);

                    for subject in missing_subjects {
                        updated_config.subjects.push(subject);
                        needs_update = true;
                    }

                    let reconciled_subjects = reconcile_subjects(existing_subjects, &subjects);
                    if reconciled_subjects != *existing_subjects {
                        let removed_subjects: Vec<String> = existing_subjects
                            .iter()
                            .filter(|subject| !reconciled_subjects.contains(*subject))
                            .cloned()
                            .collect();
                        if !removed_subjects.is_empty() {
                            warn!(
                                "Stream '{}' has legacy subjects covered by required wildcards; removing to avoid JetStream overlap: {:?}",
                                config.stream, removed_subjects
                            );
                        }
                        updated_config.subjects = reconciled_subjects;
                        needs_update = true;
                    }

                    if updated_config.max_bytes != config.max_bytes {
                        updated_config.max_bytes = config.max_bytes;
                        needs_update = true;
                    }
                    if updated_config.max_age != config.max_age {
                        updated_config.max_age = config.max_age;
                        needs_update = true;
                    }
                    if updated_config.num_replicas != config.stream_replicas {
                        updated_config.num_replicas = config.stream_replicas;
                        needs_update = true;
                    }

                    if needs_update {
                        info!(
                            "Updating existing stream '{}' to add subjects: {:?}",
                            config.stream, subjects
                        );
                        jetstream
                            .update_stream(updated_config)
                            .await
                            .map_err(|ue| {
                                anyhow!(
                                    "Failed to update stream '{}' after config mismatch: {ue}",
                                    config.stream
                                )
                            })?;
                        info!("Successfully updated stream '{}'", config.stream);
                    } else {
                        info!(
                            "Stream '{}' already has all required subjects",
                            config.stream
                        );
                    }
                }
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
    }

    Ok(())
}

#[cfg(test)]
#[path = "stream_tests.rs"]
mod tests;
