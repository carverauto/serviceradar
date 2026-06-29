// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Series-identity resolution: the per-series key, the device/SNMP-target
//! identity precedence, metadata lookups, and the attested distinguishing tags.

use std::collections::BTreeMap;

use addon_sdk::metric_pb::{Metric, MetricPoint, MetricResource, StringMapEntry};

use crate::verdict::first_non_empty;

const SERIES_DIMENSION_EXCLUDED_KEYS: &[&str] = &[
    "host_id",
    "agent_id",
    "device_id",
    "host_ip",
    "host",
    "target",
    "interface_uid",
    "source",
    "payload_kind",
    "producer_id",
    "producer_kind",
    "available",
    "metric",
    "packet_loss",
];

pub(crate) trait MetadataEntries {
    fn metadata_entries(&self) -> &[StringMapEntry];
}

impl MetadataEntries for Metric {
    fn metadata_entries(&self) -> &[StringMapEntry] {
        &self.metadata
    }
}

impl MetadataEntries for MetricPoint {
    fn metadata_entries(&self) -> &[StringMapEntry] {
        &self.metadata
    }
}

pub(crate) fn metadata_u32_value(source: &impl MetadataEntries, keys: &[&str]) -> Option<u32> {
    metadata_entry_value(source, keys).and_then(|value| value.parse::<u32>().ok())
}

pub(crate) fn metadata_f64_value(source: &impl MetadataEntries, keys: &[&str]) -> Option<f64> {
    metadata_entry_value(source, keys).and_then(|value| value.parse::<f64>().ok())
}

pub(crate) fn metadata_entry_value<'a>(
    source: &'a impl MetadataEntries,
    keys: &[&str],
) -> Option<&'a str> {
    keys.iter().find_map(|key| {
        source
            .metadata_entries()
            .iter()
            .find(|entry| entry.key == *key)
            .map(|entry| entry.value.as_str())
    })
}

pub(crate) fn series_key_for(
    resource: &MetricResource,
    metric: &Metric,
    point: &MetricPoint,
) -> String {
    let partition = if resource.partition.is_empty() {
        "default"
    } else {
        resource.partition.as_str()
    };

    if !point.series_identity_hint.is_empty() {
        [
            "v2".to_string(),
            safe_component("partition", partition),
            safe_component("hint", &point.series_identity_hint),
        ]
        .join("|")
    } else {
        // Fallback when the producer did not stamp a hint: resource identity +
        // metric + stable per-series dimensions keeps distinct streams apart
        // on one host. This mirrors central's canonical re-keying rules so edge
        // detection never collapses per-core or per-mount samples before core
        // sees the verdict. Remote SNMP polls use the polled target, not the
        // polling agent host.
        let resource_identity = series_resource_identity(resource, metric, point);
        let mut components = vec![
            "v2".to_string(),
            safe_component("partition", partition),
            safe_component("identity", &resource_identity),
            safe_component("metric", &metric.name),
        ];

        if !point.interface_uid.is_empty() {
            components.push(safe_component("interface_uid", &point.interface_uid));
        }

        if point.if_index > 0 {
            components.push(safe_component("if_index", &point.if_index.to_string()));
        }

        components.extend(series_dimension_components(metric, point));

        components.join("|")
    }
}

pub(crate) fn safe_component(name: &str, value: &str) -> String {
    format!("{name}={}", hex::encode(value.as_bytes()))
}

/// The seasonal-baseline lookup key for one sample: the canonical device-uid
/// joined with the metric name.
///
/// This deliberately does NOT match the per-series DETECTOR key
/// ([`series_key_for`], a fine edge-local `v2|partition|identity|metric|dims`
/// composite). It matches the keyspace of central's hour-of-week profile, which
/// is built with SRQL `series:uid` (`device_id AS series`) for a fixed metric —
/// i.e. one device-level series per metric. The core edge-baseline producer
/// delivers `seasonal_baselines` keyed by `<device_uid>|<metric_name>`, so this
/// is the key the engine must look the delivered baseline up by, even though the
/// rolling detector state stays keyed by the finer `series_key`.
///
/// `device_uid` uses the same identity precedence as the emitted verdict
/// ([`anomaly_device_uid`]), so the edge resolves the SAME canonical device the
/// central profile was keyed by. An empty metric name yields an empty key (no
/// baseline resolves — the rolling-only path, unchanged).
pub(crate) fn seasonal_series_key(
    resource: &MetricResource,
    metric_class: &str,
    metric: &Metric,
    point: &MetricPoint,
) -> String {
    if metric.name.is_empty() {
        return String::new();
    }

    let uid = anomaly_device_uid(resource, metric_class, metric, point);
    format!("{uid}|{}", metric.name)
}

pub(crate) fn series_resource_identity(
    resource: &MetricResource,
    metric: &Metric,
    point: &MetricPoint,
) -> String {
    let metric_class = metric_class(metric);
    first_non_empty(&[
        resource.device_id.as_str(),
        snmp_target_identity(resource, metric_class, metric, point),
        resource.host_id.as_str(),
        resource.agent_id.as_str(),
        resource.host_ip.as_str(),
    ])
    .to_string()
}

pub(crate) fn anomaly_device_uid<'a>(
    resource: &'a MetricResource,
    metric_class: &str,
    metric: &'a Metric,
    point: &'a MetricPoint,
) -> &'a str {
    first_non_empty(&[
        resource.device_id.as_str(),
        snmp_target_identity(resource, metric_class, metric, point),
        resource.host_id.as_str(),
        resource.agent_id.as_str(),
        resource.host_ip.as_str(),
    ])
}

pub(crate) fn metric_class(metric: &Metric) -> &str {
    if metric.metric_type.is_empty() {
        "metric"
    } else {
        metric.metric_type.as_str()
    }
}

// Must stay parallel to the Elixir metric-envelope `target_device_ip` resolution
// (#4290): the addon orders `resource.target_device_ip → metadata → tags[host] →
// tags[target]`, while Elixir checks `tags[host]` before metadata — they converge
// only because both canonicalize through `DeviceCorrelation.resolve`.
pub(crate) fn snmp_target_identity<'a>(
    resource: &'a MetricResource,
    metric_class: &str,
    metric: &'a Metric,
    point: &'a MetricPoint,
) -> &'a str {
    if !is_snmp_metric_class(metric_class) {
        return "";
    }

    [
        resource.target_device_ip.as_str(),
        metadata_entry_value(metric, &["target_device_ip"]).unwrap_or(""),
        metadata_entry_value(point, &["target_device_ip"]).unwrap_or(""),
        entry_value(&metric.tags, &["host"]).unwrap_or(""),
        entry_value(&point.attributes, &["host"]).unwrap_or(""),
        entry_value(&metric.tags, &["target"]).unwrap_or(""),
        entry_value(&point.attributes, &["target"]).unwrap_or(""),
    ]
    .into_iter()
    .find(|value| !value.is_empty())
    .unwrap_or("")
}

pub(crate) fn is_snmp_metric_class(metric_class: &str) -> bool {
    metric_class == "snmp" || metric_class.starts_with("snmp.")
}

pub(crate) fn target_device_ip_for<'a>(
    resource: &'a MetricResource,
    metric_class: &str,
    metric: &'a Metric,
    point: &'a MetricPoint,
) -> &'a str {
    if !resource.target_device_ip.is_empty() {
        resource.target_device_ip.as_str()
    } else {
        snmp_target_identity(resource, metric_class, metric, point)
    }
}

pub(crate) fn snmp_polled_device_identity<'a>(
    resource: &'a MetricResource,
    metric_class: &str,
    metric: &'a Metric,
    point: &'a MetricPoint,
) -> &'a str {
    if !is_snmp_metric_class(metric_class) {
        return "";
    }

    [
        resource.device_id.as_str(),
        target_device_ip_for(resource, metric_class, metric, point),
    ]
    .into_iter()
    .find(|value| !value.is_empty())
    .unwrap_or("")
}

pub(crate) fn entry_value<'a>(entries: &'a [StringMapEntry], keys: &[&str]) -> Option<&'a str> {
    keys.iter().find_map(|key| {
        entries
            .iter()
            .find(|entry| entry.key == *key)
            .map(|entry| entry.value.as_str())
    })
}

fn series_dimension_components(metric: &Metric, point: &MetricPoint) -> Vec<String> {
    let mut tags = BTreeMap::new();

    for entry in metric.tags.iter().chain(point.attributes.iter()) {
        if entry.key.is_empty() || entry.value.trim().is_empty() {
            continue;
        }

        tags.insert(entry.key.clone(), entry.value.clone());
    }

    let mut components = Vec::new();

    for key in ["core_id", "mount_point"] {
        if let Some(value) = tags.get(key) {
            components.push(tag_component(key, value));
        }
    }

    for (key, value) in tags {
        if key == "core_id"
            || key == "mount_point"
            || SERIES_DIMENSION_EXCLUDED_KEYS.contains(&key.as_str())
        {
            continue;
        }

        components.push(tag_component(&key, &value));
    }

    components
}

fn tag_component(key: &str, value: &str) -> String {
    safe_component(&format!("tag_{}", hex::encode(key.as_bytes())), value)
}

/// Merge the attested distinguishing tags into a JSON object for `source_identity`:
/// `metric.tags` first, then `point.attributes` (the per-point dimensions like
/// `core_id`/`mount_point`), point winning on a key collision. The raw attested
/// set is forwarded as-is; central applies its own identity/volatile-key
/// exclusions when it recomputes the canonical series_key.
pub(crate) fn attested_tags(
    metric: &Metric,
    point: &MetricPoint,
) -> serde_json::Map<String, serde_json::Value> {
    let mut tags = serde_json::Map::new();

    for entry in metric.tags.iter().chain(point.attributes.iter()) {
        if !entry.key.is_empty() {
            tags.insert(
                entry.key.clone(),
                serde_json::Value::String(entry.value.clone()),
            );
        }
    }

    tags
}
