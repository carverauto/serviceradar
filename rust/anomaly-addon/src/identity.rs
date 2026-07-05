// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Series-identity resolution: the per-series key, the device/SNMP-target
//! identity precedence, metadata lookups, and the attested distinguishing tags.

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
    "pid",
    "process_id",
    "start_time",
    "start_time_unix_nano",
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
        // v2|partition=<hex>|hint=<hex> — built into one pre-sized buffer instead
        // of a `Vec<String>` + `join`, so the per-point hot path does no
        // intermediate component allocation.
        let hint = point.series_identity_hint.as_str();
        let mut key = String::with_capacity(2 + 11 + partition.len() * 2 + 6 + hint.len() * 2);
        key.push_str("v2");
        push_pipe_component(&mut key, "partition", partition.as_bytes());
        push_pipe_component(&mut key, "hint", hint.as_bytes());
        key
    } else {
        // Fallback when the producer did not stamp a hint: resource identity +
        // metric + stable per-series dimensions keeps distinct streams apart
        // on one host. This mirrors central's canonical re-keying rules so edge
        // detection never collapses per-core or per-mount samples before core
        // sees the verdict. Remote SNMP polls use the polled target, not the
        // polling agent host.
        let resource_identity = series_resource_identity(resource, metric, point);
        let mut key = String::with_capacity(
            40 + (partition.len() + resource_identity.len() + metric.name.len()) * 2,
        );
        key.push_str("v2");
        push_pipe_component(&mut key, "partition", partition.as_bytes());
        push_pipe_component(&mut key, "identity", resource_identity.as_bytes());
        push_pipe_component(&mut key, "metric", metric.name.as_bytes());

        if !point.interface_uid.is_empty() {
            push_pipe_component(&mut key, "interface_uid", point.interface_uid.as_bytes());
        }

        if point.if_index > 0 {
            push_pipe_component(&mut key, "if_index", point.if_index.to_string().as_bytes());
        }

        push_series_dimension_components(&mut key, metric, point);

        key
    }
}

/// Owned `name=<hex(value)>` component. Retained as the reference encoder the
/// identity tests assert against; production now builds keys in place via
/// [`push_safe_component`] / [`push_pipe_component`].
#[cfg(test)]
pub(crate) fn safe_component(name: &str, value: &str) -> String {
    let mut buf = String::with_capacity(name.len() + 1 + value.len() * 2);
    push_safe_component(&mut buf, name, value.as_bytes());
    buf
}

const HEX_DIGITS: &[u8; 16] = b"0123456789abcdef";

/// Append the lowercase hex encoding of `bytes` to `buf`. Byte-for-byte identical
/// to `hex::encode`, but writes into the caller's buffer with no intermediate
/// `String` allocation.
fn push_hex(buf: &mut String, bytes: &[u8]) {
    buf.reserve(bytes.len() * 2);
    for &byte in bytes {
        // Hex digits are ASCII, so each `push` is a single UTF-8 byte.
        buf.push(HEX_DIGITS[(byte >> 4) as usize] as char);
        buf.push(HEX_DIGITS[(byte & 0x0f) as usize] as char);
    }
}

/// Append `name=<hex(value)>` to `buf` — the in-place form of [`safe_component`].
fn push_safe_component(buf: &mut String, name: &str, value: &[u8]) {
    buf.push_str(name);
    buf.push('=');
    push_hex(buf, value);
}

/// Append `|name=<hex(value)>` to `buf` — a `safe_component` joined onto a key
/// being built with `|` separators.
fn push_pipe_component(buf: &mut String, name: &str, value: &[u8]) {
    buf.push('|');
    push_safe_component(buf, name, value);
}

/// The seasonal-baseline lookup key for one sample: the canonical device-uid
/// joined with the metric name, plus `if_index` for per-interface metrics.
///
/// This deliberately does NOT match the per-series DETECTOR key
/// ([`series_key_for`], a fine edge-local `v2|partition|identity|metric|dims`
/// composite). It matches the keyspace of central's hour-of-week profile, which
/// is built with SRQL `series:uid` (`device_id AS series`) for a fixed metric —
/// i.e. one device-level series per metric. The core edge-baseline producer
/// delivers `seasonal_baselines` keyed by `<device_uid>|<metric_name>` for host
/// metrics and `<device_uid>|<metric_name>|<if_index>` for interface metrics, so
/// this is the key the engine must look the delivered baseline up by, even though
/// the rolling detector state stays keyed by the finer `series_key`.
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
    let mut key = String::with_capacity(uid.len() + 1 + metric.name.len());
    key.push_str(uid);
    key.push('|');
    key.push_str(&metric.name);
    if point.if_index > 0 {
        key.push('|');
        key.push_str(&point.if_index.to_string());
    }
    key
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

/// Append the stable per-series dimension components (`|tag_<hex(key)>=<hex(value)>`)
/// to the key buffer, in the canonical order: `core_id`, then `mount_point`, then
/// every remaining non-excluded dimension in sorted key order.
///
/// This collects BORROWED `(&str, &str)` pairs and sorts/dedups them in place
/// rather than cloning every tag key+value through a `BTreeMap<String, String>`.
/// The collision rule is preserved exactly: a later entry (`point.attributes`
/// after `metric.tags`) wins on a key clash, and the emitted order matches the
/// `BTreeMap`'s sorted, last-insert-wins iteration byte-for-byte.
fn push_series_dimension_components(buf: &mut String, metric: &Metric, point: &MetricPoint) {
    let mut pairs: Vec<(&str, &str)> =
        Vec::with_capacity(metric.tags.len() + point.attributes.len());
    for entry in metric.tags.iter().chain(point.attributes.iter()) {
        if entry.key.is_empty() || entry.value.trim().is_empty() {
            continue;
        }
        pairs.push((entry.key.as_str(), entry.value.as_str()));
    }

    // Stable sort by key so equal keys keep insertion order; collapse runs of the
    // same key keeping the LAST value (point-wins) — the `BTreeMap` insert order.
    pairs.sort_by(|left, right| left.0.cmp(right.0));
    let mut dims: Vec<(&str, &str)> = Vec::with_capacity(pairs.len());
    for pair in pairs {
        match dims.last_mut() {
            Some(last) if last.0 == pair.0 => last.1 = pair.1,
            _ => dims.push(pair),
        }
    }

    // core_id then mount_point lead, matching the prior explicit ordering.
    for leading in ["core_id", "mount_point"] {
        if let Some(value) = dims.iter().find(|(key, _)| *key == leading) {
            push_tag_component(buf, leading, value.1);
        }
    }

    for &(key, value) in &dims {
        if key == "core_id" || key == "mount_point" || SERIES_DIMENSION_EXCLUDED_KEYS.contains(&key)
        {
            continue;
        }
        push_tag_component(buf, key, value);
    }
}

/// Append `|tag_<hex(key)>=<hex(value)>` to `buf`. The in-place form of the prior
/// `safe_component(&format!("tag_{}", hex::encode(key)), value)`.
fn push_tag_component(buf: &mut String, key: &str, value: &str) {
    buf.push('|');
    buf.push_str("tag_");
    push_hex(buf, key.as_bytes());
    buf.push('=');
    push_hex(buf, value.as_bytes());
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
