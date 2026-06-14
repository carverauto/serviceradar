/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

//! Generated prost bindings for ServiceRadar's canonical metric envelope.

pub mod pb {
    include!(concat!(env!("OUT_DIR"), "/serviceradar.metric.v1.rs"));
}

pub use pb::*;

#[cfg(test)]
mod tests {
    use prost::Message;

    use crate::pb::{
        IngestIdentity, Metric, MetricBatch, MetricKind, MetricPoint, MetricResource,
        MetricTemporality, MetricValueType, StringMapEntry,
    };

    #[test]
    fn metric_batch_round_trips_gauge_and_cumulative_counter_fields() {
        let batch = MetricBatch {
            schema_version: "serviceradar.metric.v1".to_owned(),
            resource: Some(MetricResource {
                agent_id: "agent-1".to_owned(),
                gateway_id: "gateway-1".to_owned(),
                partition: "default".to_owned(),
                service_name: "sysmon".to_owned(),
                service_type: "sysmon".to_owned(),
                ..Default::default()
            }),
            ingest_identity: Some(IngestIdentity {
                source: "sysmon-metrics".to_owned(),
                payload_kind: "serviceradar.metric.v1".to_owned(),
                producer_id: "agent-1".to_owned(),
                producer_kind: "agent".to_owned(),
                attested_by: "gateway-1".to_owned(),
                ..Default::default()
            }),
            ingress_id: "00000645-50de-8e80-8000-000000000001".to_owned(),
            ingress_timestamp_unix_nano: 1_765_500_000_000_000_000,
            emitted_at_unix_nano: 1_765_500_000_000_000_000,
            metrics: vec![
                Metric {
                    name: "cpu.usage_percent".to_owned(),
                    metric_type: "sysmon.cpu".to_owned(),
                    kind: MetricKind::Gauge as i32,
                    unit: "%".to_owned(),
                    points: vec![MetricPoint {
                        value: 42.5,
                        raw_value: "42.5".to_owned(),
                        raw_value_type: MetricValueType::Double as i32,
                        observed_at_unix_nano: 1_765_500_000_000_000_000,
                        attributes: vec![StringMapEntry {
                            key: "cpu".to_owned(),
                            value: "0".to_owned(),
                        }],
                        ..Default::default()
                    }],
                    ..Default::default()
                },
                Metric {
                    name: "ifHCInOctets".to_owned(),
                    metric_type: "snmp".to_owned(),
                    kind: MetricKind::Sum as i32,
                    temporality: MetricTemporality::Cumulative as i32,
                    is_monotonic: true,
                    counter_width: 64,
                    unit: "By".to_owned(),
                    points: vec![MetricPoint {
                        value: 1234.0,
                        raw_value: "1234".to_owned(),
                        raw_value_type: MetricValueType::Uint64 as i32,
                        observed_at_unix_nano: 1_765_500_000_000_000_000,
                        start_time_unix_nano: 1_765_499_000_000_000_000,
                        reset_anchor: "sysUpTime:100".to_owned(),
                        if_index: 7,
                        interface_uid: "ifindex:7".to_owned(),
                        ..Default::default()
                    }],
                    ..Default::default()
                },
            ],
        };

        let decoded = MetricBatch::decode(batch.encode_to_vec().as_slice()).expect("decode batch");
        assert_eq!(decoded.schema_version, "serviceradar.metric.v1");
        assert_eq!(decoded.resource.as_ref().unwrap().agent_id, "agent-1");
        assert_eq!(
            decoded.ingest_identity.as_ref().unwrap().attested_by,
            "gateway-1"
        );
        assert_eq!(decoded.metrics[0].kind, MetricKind::Gauge as i32);
        assert_eq!(decoded.metrics[1].kind, MetricKind::Sum as i32);
        assert_eq!(
            decoded.metrics[1].temporality,
            MetricTemporality::Cumulative as i32
        );
        assert!(decoded.metrics[1].is_monotonic);
        assert_eq!(decoded.metrics[1].points[0].raw_value, "1234");
        assert_eq!(
            decoded.metrics[1].points[0].raw_value_type,
            MetricValueType::Uint64 as i32
        );
        assert_eq!(
            decoded.metrics[1].points[0].start_time_unix_nano,
            1_765_499_000_000_000_000
        );
        assert_eq!(decoded.metrics[1].points[0].reset_anchor, "sysUpTime:100");
    }
}
