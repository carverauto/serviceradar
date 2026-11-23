//! Viz metadata builders for Horizon entities: outages, BGP events, BGP
//! zombies, and path hops.

use super::{ColumnSemantic, ColumnType, VizKind, VizMeta, VizSuggestion, col};

pub(super) fn outages() -> VizMeta {
    VizMeta {
        columns: vec![
            col("time", ColumnType::Timestamptz, Some(ColumnSemantic::Time)),
            col("outage_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("status", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("severity", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("entity_type", ColumnType::Text, None),
            col("entity_key", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("region", ColumnType::Text, None),
            col("covering_prefix", ColumnType::Text, None),
            col("origin_asn", ColumnType::Int, None),
            col(
                "corroborating_pop_count",
                ColumnType::Int,
                Some(ColumnSemantic::Value),
            ),
            col(
                "avg_forwarding_loss_pct",
                ColumnType::Float,
                Some(ColumnSemantic::Value),
            ),
            col(
                "avg_synthetic_failure_pct",
                ColumnType::Float,
                Some(ColumnSemantic::Value),
            ),
            col("window_start_ms", ColumnType::Int, None),
            col("window_end_ms", ColumnType::Int, None),
            col("correlated_bgp_event_ids", ColumnType::Jsonb, None),
            col("raw_data", ColumnType::Jsonb, None),
        ],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Table,
            x: None,
            y: None,
            series: None,
        }],
    }
}

pub(super) fn bgp_events() -> VizMeta {
    VizMeta {
        columns: vec![
            col("time", ColumnType::Timestamptz, Some(ColumnSemantic::Time)),
            col("event_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("kind", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("level", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("prefix", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("origin_asn", ColumnType::Int, None),
            col("as_path", ColumnType::Jsonb, None),
            col("rpki_status", ColumnType::Text, None),
            col("caida_leak_inference", ColumnType::Text, None),
            col("watchlist_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("client_label", ColumnType::Text, None),
            col("raw_data", ColumnType::Jsonb, None),
        ],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Table,
            x: None,
            y: None,
            series: None,
        }],
    }
}

pub(super) fn bgp_zombies() -> VizMeta {
    VizMeta {
        columns: vec![
            col("time", ColumnType::Timestamptz, Some(ColumnSemantic::Time)),
            col("episode_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("status", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("prefix", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("origin_asn", ColumnType::Int, None),
            col(
                "divergence_pct",
                ColumnType::Float,
                Some(ColumnSemantic::Value),
            ),
            col("is_beacon", ColumnType::Bool, None),
            col("withdrawn_peers", ColumnType::Int, None),
            col("total_peers", ColumnType::Int, None),
            col("stuck_peer_asns", ColumnType::Jsonb, None),
            col(
                "first_seen_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col(
                "resolved_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col("raw_data", ColumnType::Jsonb, None),
        ],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Table,
            x: None,
            y: None,
            series: None,
        }],
    }
}

pub(super) fn path_hops() -> VizMeta {
    VizMeta {
        columns: vec![
            col("time", ColumnType::Timestamptz, Some(ColumnSemantic::Time)),
            col("round_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("target_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("pop_id", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("hop_ttl", ColumnType::Int, None),
            col("hop_ip", ColumnType::Text, None),
            col("router_alias_id", ColumnType::Text, None),
            col("alias_confidence", ColumnType::Float, None),
            col("asn", ColumnType::Int, None),
            col("as_org", ColumnType::Text, None),
            col("is_cloud", ColumnType::Bool, None),
            col("cloud_provider", ColumnType::Text, None),
            col("cloud_region", ColumnType::Text, None),
            col(
                "forwarding_loss_pct",
                ColumnType::Float,
                Some(ColumnSemantic::Value),
            ),
            col("avg_rtt_ms", ColumnType::Float, Some(ColumnSemantic::Value)),
            col("effective_path_mtu", ColumnType::Int, None),
            col("mtu_blackhole_detected", ColumnType::Bool, None),
            col("blackhole_hop_ttl", ColumnType::Int, None),
            col("raw_data", ColumnType::Jsonb, None),
        ],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Table,
            x: None,
            y: None,
            series: None,
        }],
    }
}
