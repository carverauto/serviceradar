// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

use std::collections::BTreeMap;

use addon_sdk::metric_pb::{Metric, MetricPoint, MetricResource};

use super::support::entry;
use crate::identity::{
    anomaly_device_uid, attested_tags, metric_class, safe_component, seasonal_series_key,
    series_key_for, series_resource_identity,
};

fn tag_component(key: &str, value: &str) -> String {
    safe_component(&format!("tag_{}", hex::encode(key.as_bytes())), value)
}

#[test]
fn attested_tags_merges_metric_and_point_with_point_winning() {
    let metric = Metric {
        tags: vec![
            entry("source_zone", "rack-a"),
            entry("sensor", "metric-default"),
        ],
        ..Default::default()
    };
    let point = MetricPoint {
        attributes: vec![entry("sensor", "cpu0"), entry("core_id", "0")],
        ..Default::default()
    };

    let tags = attested_tags(&metric, &point);

    assert_eq!(
        tags.get("source_zone").and_then(|v| v.as_str()),
        Some("rack-a")
    );
    assert_eq!(tags.get("core_id").and_then(|v| v.as_str()), Some("0"));
    // point.attributes wins on a key collision so the per-core/per-mount
    // dimension central reconstructs matches what the point carried.
    assert_eq!(tags.get("sensor").and_then(|v| v.as_str()), Some("cpu0"));
}

#[test]
fn attested_tags_skips_empty_keys() {
    let metric = Metric {
        tags: vec![entry("", "ignored")],
        ..Default::default()
    };
    assert!(attested_tags(&metric, &MetricPoint::default()).is_empty());
}

#[test]
fn edge_series_key_encodes_partition_and_hint_boundaries() {
    let metric = Metric {
        name: "cpu.usage".to_string(),
        metric_type: "sysmon.cpu".to_string(),
        ..Default::default()
    };
    let point = MetricPoint {
        series_identity_hint: "host:a|core:0".to_string(),
        ..Default::default()
    };

    let first = MetricResource {
        partition: "prod:east".to_string(),
        ..Default::default()
    };
    let second = MetricResource {
        partition: "prod".to_string(),
        ..Default::default()
    };
    let second_point = MetricPoint {
        series_identity_hint: "east|host:a|core:0".to_string(),
        ..Default::default()
    };

    let first_key = series_key_for(&first, &metric, &point);
    let second_key = series_key_for(&second, &metric, &second_point);

    assert_ne!(first_key, second_key);
    assert!(first_key.contains(&safe_component("partition", "prod:east")));
    assert!(first_key.contains(&safe_component("hint", "host:a|core:0")));
    assert!(!first_key.contains("prod:east"));
    assert!(!first_key.contains("host:a|core:0"));
}

#[test]
fn edge_fallback_series_key_keeps_cpu_cores_distinct() {
    let resource = MetricResource {
        device_id: "device-a".to_string(),
        partition: "demo".to_string(),
        ..Default::default()
    };
    let metric = Metric {
        name: "cpu.usage_percent".to_string(),
        metric_type: "sysmon.cpu".to_string(),
        tags: vec![entry("host", "device-a")],
        ..Default::default()
    };
    let core0 = MetricPoint {
        attributes: vec![entry("core_id", "0"), entry("label", "cpu0")],
        ..Default::default()
    };
    let core1 = MetricPoint {
        attributes: vec![entry("core_id", "1"), entry("label", "cpu1")],
        ..Default::default()
    };

    let core0_key = series_key_for(&resource, &metric, &core0);
    let core1_key = series_key_for(&resource, &metric, &core1);

    assert_ne!(core0_key, core1_key);
    assert!(core0_key.contains(&tag_component("core_id", "0")));
    assert!(core1_key.contains(&tag_component("core_id", "1")));
    assert!(core0_key.contains(&tag_component("label", "cpu0")));
    assert!(core1_key.contains(&tag_component("label", "cpu1")));
    assert!(!core0_key.contains("device-a"));
    assert!(!core0_key.contains("cpu0"));
}

#[test]
fn edge_fallback_series_key_keeps_mounts_distinct() {
    let resource = MetricResource {
        device_id: "device-a".to_string(),
        partition: "demo".to_string(),
        ..Default::default()
    };
    let metric = Metric {
        name: "disk.usage_percent".to_string(),
        metric_type: "sysmon.disk".to_string(),
        ..Default::default()
    };
    let root = MetricPoint {
        attributes: vec![entry("mount_point", "/")],
        ..Default::default()
    };
    let var = MetricPoint {
        attributes: vec![entry("mount_point", "/var")],
        ..Default::default()
    };

    let root_key = series_key_for(&resource, &metric, &root);
    let var_key = series_key_for(&resource, &metric, &var);

    assert_ne!(root_key, var_key);
    assert!(root_key.contains(&tag_component("mount_point", "/")));
    assert!(var_key.contains(&tag_component("mount_point", "/var")));
}

// --- Key equivalence: new (buffer) == old (Vec/BTreeMap/join) -----------------
//
// The series key and the seasonal key are forwarded verbatim to central, which
// re-keys against them, so the optimized buffer-building path MUST produce a
// byte-identical key to the prior `Vec<String>` + `BTreeMap` + `join`
// implementation. These references reproduce that prior algorithm exactly, and
// the test pins the live functions to it across a battery of representative
// inputs (the hint path, the fallback identity path, per-core/per-mount
// dimensions, SNMP target/interface/if_index, duplicate-key point-wins, excluded
// and blank-valued tags, and the default-partition fallback).

const REF_SERIES_DIMENSION_EXCLUDED_KEYS: &[&str] = &[
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

fn ref_safe_component(name: &str, value: &str) -> String {
    format!("{name}={}", hex::encode(value.as_bytes()))
}

fn ref_tag_component(key: &str, value: &str) -> String {
    ref_safe_component(&format!("tag_{}", hex::encode(key.as_bytes())), value)
}

fn ref_series_dimension_components(metric: &Metric, point: &MetricPoint) -> Vec<String> {
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
            components.push(ref_tag_component(key, value));
        }
    }

    for (key, value) in tags {
        if key == "core_id"
            || key == "mount_point"
            || REF_SERIES_DIMENSION_EXCLUDED_KEYS.contains(&key.as_str())
        {
            continue;
        }
        components.push(ref_tag_component(&key, &value));
    }

    components
}

fn ref_series_key_for(resource: &MetricResource, metric: &Metric, point: &MetricPoint) -> String {
    let partition = if resource.partition.is_empty() {
        "default"
    } else {
        resource.partition.as_str()
    };

    if !point.series_identity_hint.is_empty() {
        [
            "v2".to_string(),
            ref_safe_component("partition", partition),
            ref_safe_component("hint", &point.series_identity_hint),
        ]
        .join("|")
    } else {
        let resource_identity = series_resource_identity(resource, metric, point);
        let mut components = vec![
            "v2".to_string(),
            ref_safe_component("partition", partition),
            ref_safe_component("identity", &resource_identity),
            ref_safe_component("metric", &metric.name),
        ];

        if !point.interface_uid.is_empty() {
            components.push(ref_safe_component("interface_uid", &point.interface_uid));
        }

        if point.if_index > 0 {
            components.push(ref_safe_component("if_index", &point.if_index.to_string()));
        }

        components.extend(ref_series_dimension_components(metric, point));

        components.join("|")
    }
}

fn ref_seasonal_series_key(
    resource: &MetricResource,
    metric_class: &str,
    metric: &Metric,
    point: &MetricPoint,
) -> String {
    if metric.name.is_empty() {
        return String::new();
    }
    let uid = anomaly_device_uid(resource, metric_class, metric, point);
    if point.if_index > 0 {
        format!("{uid}|{}|{}", metric.name, point.if_index)
    } else {
        format!("{uid}|{}", metric.name)
    }
}

/// Representative `(resource, metric, point)` fixtures spanning every branch of
/// the key builders.
fn key_equivalence_fixtures() -> Vec<(MetricResource, Metric, MetricPoint)> {
    vec![
        // 1. Hint path with a punctuated partition.
        (
            MetricResource {
                partition: "prod:east".to_string(),
                device_id: "device-a".to_string(),
                ..Default::default()
            },
            Metric {
                name: "cpu.usage".to_string(),
                metric_type: "sysmon.cpu".to_string(),
                ..Default::default()
            },
            MetricPoint {
                series_identity_hint: "host:a|core:0".to_string(),
                ..Default::default()
            },
        ),
        // 2. Fallback CPU core with extra dimension + an excluded `host` tag.
        (
            MetricResource {
                device_id: "device-a".to_string(),
                partition: "demo".to_string(),
                ..Default::default()
            },
            Metric {
                name: "cpu.usage_percent".to_string(),
                metric_type: "sysmon.cpu".to_string(),
                tags: vec![entry("host", "device-a"), entry("zone", "rack-a")],
                ..Default::default()
            },
            MetricPoint {
                attributes: vec![entry("core_id", "3"), entry("label", "cpu3")],
                ..Default::default()
            },
        ),
        // 3. Fallback disk mount.
        (
            MetricResource {
                device_id: "device-a".to_string(),
                partition: "demo".to_string(),
                ..Default::default()
            },
            Metric {
                name: "disk.usage_percent".to_string(),
                metric_type: "sysmon.disk".to_string(),
                ..Default::default()
            },
            MetricPoint {
                attributes: vec![entry("mount_point", "/var")],
                ..Default::default()
            },
        ),
        // 4. SNMP interface: target identity + interface_uid + if_index, plus tags
        //    that sort across the special-key boundary.
        (
            MetricResource {
                partition: "net".to_string(),
                target_device_ip: "192.168.1.5".to_string(),
                ..Default::default()
            },
            Metric {
                name: "ifHCInOctets".to_string(),
                metric_type: "snmp.interface".to_string(),
                tags: vec![entry("ifName", "Gi0/1"), entry("alpha", "z")],
                ..Default::default()
            },
            MetricPoint {
                interface_uid: "if-uid-7".to_string(),
                if_index: 7,
                attributes: vec![entry("mount_point", "ignored?")],
                ..Default::default()
            },
        ),
        // 5. Duplicate key across metric.tags and point.attributes (point wins), a
        //    blank-valued tag that must be skipped, and an empty key.
        (
            MetricResource {
                device_id: "device-b".to_string(),
                partition: "demo".to_string(),
                ..Default::default()
            },
            Metric {
                name: "custom.value".to_string(),
                metric_type: "custom".to_string(),
                tags: vec![
                    entry("sensor", "from-metric"),
                    entry("blank", "   "),
                    entry("", "no-key"),
                    entry("core_id", "9"),
                ],
                ..Default::default()
            },
            MetricPoint {
                attributes: vec![
                    entry("sensor", "from-point"),
                    entry("device_id", "excluded"),
                    entry("beta", "b"),
                ],
                ..Default::default()
            },
        ),
        // 6. Default-partition fallback (empty resource partition) with no tags.
        (
            MetricResource {
                host_id: "host-c".to_string(),
                ..Default::default()
            },
            Metric {
                name: "mem.used_percent".to_string(),
                metric_type: "sysmon.memory".to_string(),
                ..Default::default()
            },
            MetricPoint::default(),
        ),
        // 7. Empty metric name (seasonal key must be empty; series key still builds).
        (
            MetricResource {
                device_id: "device-d".to_string(),
                partition: "demo".to_string(),
                ..Default::default()
            },
            Metric {
                name: String::new(),
                metric_type: "custom".to_string(),
                ..Default::default()
            },
            MetricPoint {
                attributes: vec![entry("k", "v")],
                ..Default::default()
            },
        ),
    ]
}

#[test]
fn series_key_for_matches_legacy_builder() {
    for (resource, metric, point) in key_equivalence_fixtures() {
        let optimized = series_key_for(&resource, &metric, &point);
        let reference = ref_series_key_for(&resource, &metric, &point);
        assert_eq!(
            optimized, reference,
            "series_key_for diverged from the legacy builder for {metric:?} / {point:?}"
        );
        assert!(optimized.starts_with("v2"), "key must keep the v2 prefix");
    }
}

#[test]
fn seasonal_series_key_matches_legacy_builder() {
    for (resource, metric, point) in key_equivalence_fixtures() {
        let class = metric_class(&metric);
        let optimized = seasonal_series_key(&resource, class, &metric, &point);
        let reference = ref_seasonal_series_key(&resource, class, &metric, &point);
        assert_eq!(
            optimized, reference,
            "seasonal_series_key diverged from the legacy builder for {metric:?} / {point:?}"
        );
    }
}

#[test]
fn seasonal_series_key_appends_if_index_for_interface_baselines() {
    let resource = MetricResource {
        partition: "net".to_string(),
        target_device_ip: "192.168.1.5".to_string(),
        ..Default::default()
    };
    let metric = Metric {
        name: "ifInOctets".to_string(),
        metric_type: "snmp.interface".to_string(),
        ..Default::default()
    };
    let point = MetricPoint {
        if_index: 7,
        ..Default::default()
    };

    let class = metric_class(&metric);
    assert_eq!(
        seasonal_series_key(&resource, class, &metric, &point),
        "192.168.1.5|ifInOctets|7"
    );
}
