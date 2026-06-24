// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

use addon_sdk::metric_pb::{Metric, MetricPoint};

use super::support::entry;
use crate::metrics_classify::{counter_width, max_counter_rate_per_second};

#[test]
fn counter_width_prefers_typed_metric_field() {
    let metric = Metric {
        counter_width: 64,
        metadata: vec![entry("counter_width", "32")],
        ..Default::default()
    };

    assert_eq!(counter_width(&metric, &MetricPoint::default()), 64);
}

#[test]
fn counter_width_falls_back_to_point_then_metric_metadata() {
    let metric = Metric {
        metadata: vec![entry("counter_bits", "64")],
        ..Default::default()
    };
    let point = MetricPoint {
        metadata: vec![entry("pdu_width", "32")],
        ..Default::default()
    };

    assert_eq!(counter_width(&metric, &point), 32);
    assert_eq!(counter_width(&metric, &MetricPoint::default()), 64);
}

#[test]
fn max_counter_rate_uses_point_metadata_before_metric_metadata() {
    let metric = Metric {
        metadata: vec![entry("max_counter_rate_per_second", "1000")],
        ..Default::default()
    };
    let point = MetricPoint {
        metadata: vec![entry("max_counter_rate_per_second", "250")],
        ..Default::default()
    };

    assert_eq!(max_counter_rate_per_second(&metric, &point), Some(250.0));
    assert_eq!(
        max_counter_rate_per_second(&metric, &MetricPoint::default()),
        Some(1000.0)
    );
}
