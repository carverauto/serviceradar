//! Viz metadata builders for network entities: interfaces, flows, and BMP
//! routing events.

use super::{ColumnSemantic, ColumnType, VizKind, VizMeta, VizSuggestion, col};

pub(super) fn interfaces() -> VizMeta {
    VizMeta {
        columns: vec![
            col(
                "timestamp",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col("device_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("interface_uid", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("device_ip", ColumnType::Text, None),
            col("if_name", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("if_descr", ColumnType::Text, None),
            col("if_alias", ColumnType::Text, None),
            col("if_index", ColumnType::Int, None),
            col("if_type", ColumnType::Int, None),
            col("if_type_name", ColumnType::Text, None),
            col("interface_kind", ColumnType::Text, None),
            col("if_speed", ColumnType::Int, None),
            col("speed_bps", ColumnType::Int, None),
            col("mtu", ColumnType::Int, None),
            col("duplex", ColumnType::Text, None),
            col("if_phys_address", ColumnType::Text, None),
            col("ip_addresses", ColumnType::TextArray, None),
            col("if_admin_status", ColumnType::Int, None),
            col("if_oper_status", ColumnType::Int, None),
            col("agent_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("gateway_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("metadata", ColumnType::Jsonb, None),
            col(
                "created_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
        ],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Table,
            x: None,
            y: None,
            series: None,
        }],
    }
}

pub(super) fn threat_intel_matches() -> VizMeta {
    VizMeta {
        columns: vec![
            col("match_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("match_kind", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("observed_ip", ColumnType::Text, None),
            col("indicator_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("indicator", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("indicator_type", ColumnType::Text, None),
            col("source", ColumnType::Text, None),
            col("label", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("severity", ColumnType::Int, None),
            col("confidence", ColumnType::Int, None),
            col(
                "evaluated_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col("cache_expires_at", ColumnType::Timestamptz, None),
            col(
                "indicator_first_seen_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col(
                "indicator_last_seen_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col("indicator_expires_at", ColumnType::Timestamptz, None),
            col("indicator_match_count", ColumnType::Int, None),
            col("stale", ColumnType::Bool, None),
        ],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Table,
            x: None,
            y: None,
            series: None,
        }],
    }
}

pub(super) fn bmp_events() -> VizMeta {
    VizMeta {
        columns: vec![
            col("time", ColumnType::Timestamptz, Some(ColumnSemantic::Time)),
            col("id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("event_type", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("severity_id", ColumnType::Int, None),
            col("router_id", ColumnType::Text, None),
            col("router_ip", ColumnType::Text, None),
            col("peer_ip", ColumnType::Text, None),
            col("peer_asn", ColumnType::Int, None),
            col("local_asn", ColumnType::Int, None),
            col("prefix", ColumnType::Text, None),
            col("message", ColumnType::Text, None),
            col("metadata", ColumnType::Jsonb, None),
            col("raw_data", ColumnType::Text, None),
            col(
                "created_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
        ],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Table,
            x: None,
            y: None,
            series: None,
        }],
    }
}

pub(super) fn flows() -> VizMeta {
    VizMeta {
        columns: vec![
            col("time", ColumnType::Timestamptz, Some(ColumnSemantic::Time)),
            col("src_endpoint_ip", ColumnType::Text, None),
            col("src_endpoint_port", ColumnType::Int, None),
            col("dst_endpoint_ip", ColumnType::Text, None),
            col("dst_endpoint_port", ColumnType::Int, None),
            col("protocol_num", ColumnType::Int, None),
            col("protocol_name", ColumnType::Text, None),
            col("bytes_total", ColumnType::Int, Some(ColumnSemantic::Value)),
            col(
                "packets_total",
                ColumnType::Int,
                Some(ColumnSemantic::Value),
            ),
            col("bytes_in", ColumnType::Int, Some(ColumnSemantic::Value)),
            col("bytes_out", ColumnType::Int, Some(ColumnSemantic::Value)),
            col("sampler_address", ColumnType::Text, None),
            col("exporter_name", ColumnType::Text, None),
            col("in_if_name", ColumnType::Text, None),
            col("out_if_name", ColumnType::Text, None),
            col("in_if_speed_bps", ColumnType::Int, None),
            col("out_if_speed_bps", ColumnType::Int, None),
            col("attribution_status", ColumnType::Text, None),
            col("pid", ColumnType::Text, None),
            col("process", ColumnType::Text, None),
            col("cmdline", ColumnType::Text, None),
            col("uid", ColumnType::Text, None),
            col("container_id", ColumnType::Text, None),
            col("agent_id", ColumnType::Text, None),
            col("pod_namespace", ColumnType::Text, None),
            col("pod_name", ColumnType::Text, None),
            col("container_name", ColumnType::Text, None),
            col("image", ColumnType::Text, None),
            col("ocsf_payload", ColumnType::Jsonb, None),
        ],
        suggestions: vec![
            VizSuggestion {
                kind: VizKind::Table,
                x: None,
                y: None,
                series: None,
            },
            VizSuggestion {
                kind: VizKind::Timeseries,
                x: Some("time".to_string()),
                y: Some("bytes_total".to_string()),
                series: Some("src_endpoint_ip".to_string()),
            },
        ],
    }
}

pub(super) fn public_endpoints() -> VizMeta {
    VizMeta {
        columns: vec![
            col(
                "observed_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col("cluster_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("ip", ColumnType::Text, None),
            col("hostname", ColumnType::Text, None),
            col("port", ColumnType::Int, None),
            col("protocol", ColumnType::Text, None),
            col(
                "exposure_class",
                ColumnType::Text,
                Some(ColumnSemantic::Label),
            ),
            col("namespace", ColumnType::Text, None),
            col(
                "service_name",
                ColumnType::Text,
                Some(ColumnSemantic::Label),
            ),
            col("gateway_name", ColumnType::Text, None),
            col("listener_name", ColumnType::Text, None),
            col("route_kind", ColumnType::Text, None),
            col("route_name", ColumnType::Text, None),
            col("service_target_port", ColumnType::Int, None),
            col("endpoint_targets", ColumnType::Jsonb, None),
            col("backend_refs", ColumnType::Jsonb, None),
        ],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Table,
            x: None,
            y: None,
            series: None,
        }],
    }
}

pub(super) fn camera_sources() -> VizMeta {
    VizMeta {
        columns: vec![
            col("id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col(
                "display_name",
                ColumnType::Text,
                Some(ColumnSemantic::Label),
            ),
            col("device_uid", ColumnType::Text, None),
            col("vendor", ColumnType::Text, None),
            col("vendor_camera_id", ColumnType::Text, None),
            col(
                "availability_status",
                ColumnType::Text,
                Some(ColumnSemantic::Label),
            ),
            col("availability_reason", ColumnType::Text, None),
            col("assigned_agent_id", ColumnType::Text, None),
            col("assigned_gateway_id", ColumnType::Text, None),
            col("last_activity_at", ColumnType::Timestamptz, None),
            col("last_event_at", ColumnType::Timestamptz, None),
            col("last_event_type", ColumnType::Text, None),
            col(
                "updated_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col("stream_profiles", ColumnType::Jsonb, None),
        ],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Table,
            x: None,
            y: None,
            series: None,
        }],
    }
}

pub(super) fn camera_observations() -> VizMeta {
    VizMeta {
        columns: vec![
            col("id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("observation_key", ColumnType::Text, None),
            col("pack_id", ColumnType::Text, None),
            col("pipeline_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("pipeline_version", ColumnType::Text, None),
            col("worker_kind", ColumnType::Text, None),
            col("worker_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("model_id", ColumnType::Text, None),
            col("model_version", ColumnType::Text, None),
            col("job_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col(
                "catalog_entry_id",
                ColumnType::Text,
                Some(ColumnSemantic::Id),
            ),
            col(
                "camera_source_id",
                ColumnType::Text,
                Some(ColumnSemantic::Id),
            ),
            col(
                "camera_display_name",
                ColumnType::Text,
                Some(ColumnSemantic::Label),
            ),
            col(
                "stream_profile_id",
                ColumnType::Text,
                Some(ColumnSemantic::Id),
            ),
            col("source_mode", ColumnType::Text, None),
            col("fragment_sequence", ColumnType::Int, None),
            col("frame_sequence", ColumnType::Int, None),
            col("media_pts_ns", ColumnType::Int, None),
            col(
                "timeline_ts_us",
                ColumnType::Int,
                Some(ColumnSemantic::Time),
            ),
            col("time_basis", ColumnType::Text, None),
            col("track_id", ColumnType::Text, None),
            col("category", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("label", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("confidence", ColumnType::Float, Some(ColumnSemantic::Value)),
            col("bbox", ColumnType::Jsonb, None),
            col("attributes", ColumnType::Jsonb, None),
            col("signal_schema_id", ColumnType::Text, None),
            col("signal_schema_version", ColumnType::Text, None),
            col("display_contract_id", ColumnType::Text, None),
            col("has_crop", ColumnType::Bool, None),
            col(
                "inserted_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col(
                "updated_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
        ],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Table,
            x: None,
            y: None,
            series: None,
        }],
    }
}

pub(super) fn websites() -> VizMeta {
    VizMeta {
        columns: vec![
            col("id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("name", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("canonical_origin", ColumnType::Text, None),
            col("allowed_origins", ColumnType::TextArray, None),
            col("allowed_query_keys", ColumnType::TextArray, None),
            col("trace_propagate_origins", ColumnType::TextArray, None),
            col("environment", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("tags", ColumnType::Jsonb, None),
            col("prefix_tags", ColumnType::Jsonb, None),
            col("rum_enabled", ColumnType::Bool, None),
            col("rum_site_key", ColumnType::Text, None),
            col("rum_sample_rate", ColumnType::Float, None),
            col("anonymize_client_ip", ColumnType::Bool, None),
            col("edge_provider", ColumnType::Text, None),
            col("observed_vips", ColumnType::TextArray, None),
            col("observed_asns", ColumnType::IntArray, None),
            col("tls_not_after", ColumnType::Timestamptz, None),
            col("tls_issuer", ColumnType::Text, None),
            col("last_posture_checked_at", ColumnType::Timestamptz, None),
            col(
                "created_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col(
                "updated_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col("binding_count", ColumnType::Int, None),
        ],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Table,
            x: None,
            y: None,
            series: None,
        }],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn threat_intel_matches_exposes_indicator_timestamps() {
        let meta = threat_intel_matches();
        let names: Vec<_> = meta
            .columns
            .iter()
            .map(|column| column.name.as_str())
            .collect();
        for name in [
            "indicator_first_seen_at",
            "indicator_last_seen_at",
            "indicator_expires_at",
        ] {
            assert!(
                names.contains(&name),
                "expected {name} in threat_intel_matches viz columns, got {names:?}"
            );
        }
    }
}
