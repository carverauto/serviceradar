//! Cold-tier routing for tiered telemetry offload.
//!
//! OpenSpec change: add-tiered-telemetry-offload (tasks 4.1/4.2; design D7).
//!
//! Mirrors `cagg.rs`: a small, pure decision layer that the plan builder asks
//! whether a query should execute against the cold tier (the analytics head's
//! stitched `platform.<table>` views) instead of the primary.
//!
//! The rules, and why:
//!
//! * **Raw shapes only.** Stats/downsample queries keep routing to the
//!   in-database continuous aggregates, which already retain 395 days. Cold
//!   routing exists for the raw-granularity history that CAGGs cannot answer.
//!   This also sidesteps a correctness trap: hot stats are computed from
//!   pre-aggregated buckets, so recomputing them from raw Parquet would return
//!   *different numbers for the same window* depending on which tier served it.
//! * **Only when the window actually reaches below the hot window.** A query
//!   inside the hot window must produce a byte-identical plan on the primary —
//!   no cold-tier deployment may regress hot-path performance.
//! * **No time filter ⇒ hot only.** Without a resolved window there is nothing
//!   to compare against the boundary, and routing cold would mean an
//!   unprunable scan of the entire archive. Callers that need archived point
//!   lookups (trace detail) supply an absolute time hint.
//! * **Absent config ⇒ every function here is inert**, so an OSS deployment
//!   behaves exactly as it does today.
//!
//! Landing note: this is the decision layer only. Nothing calls it until the
//! NIF translate contract carries `ColdTierConfig` (task 4.1) and the plan
//! builder consults it (task 4.2) — so the module is dead code today, and CI
//! runs `clippy -D warnings`. The allow below comes off in the same change
//! that wires it in; it is deliberately module-scoped so it cannot mask dead
//! code anywhere else.
#![allow(dead_code)]

use super::QueryPlan;
use crate::{
    parser::{Entity, QueryAst},
    time::TimeRange,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// Deployment-supplied cold-tier facts, passed in per translate call.
///
/// The NIF is stateless and holds no tenant/retention state, so the caller
/// (which owns the runtime config) supplies the per-entity boundary and
/// windows. An empty `entities` list means the cold tier is off.
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct ColdTierConfig {
    #[serde(default)]
    pub entities: Vec<ColdEntity>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ColdEntity {
    /// Physical table name, matching the cold schema registry.
    pub table: String,
    /// The head-acknowledged query boundary B: rows below it are served from
    /// Parquet, rows at/above it from the primary through postgres_fdw.
    pub boundary: DateTime<Utc>,
    /// Oldest data the cold tier still holds, i.e. the lookback cap for this
    /// entity. Queries beyond it are rejected exactly like today's cap
    /// violations.
    pub cold_window_days: i64,
}

impl ColdTierConfig {
    pub fn is_empty(&self) -> bool {
        self.entities.is_empty()
    }

    fn lookup(&self, entity: &Entity) -> Option<&ColdEntity> {
        let table = cold_table_for_entity(entity)?;
        self.entities.iter().find(|e| e.table == table)
    }
}

/// The physical table a cold-eligible entity maps to. Entities not listed
/// here are never cold-routed (they are not in the offload registry).
pub(crate) fn cold_table_for_entity(entity: &Entity) -> Option<&'static str> {
    match entity {
        Entity::Logs => Some("logs"),
        Entity::Traces => Some("otel_traces"),
        Entity::OtelMetrics => Some("otel_metrics"),
        Entity::OtelMetricPoints => Some("otel_metric_points"),
        Entity::TimeseriesMetrics | Entity::SnmpMetrics | Entity::RperfMetrics => {
            Some("timeseries_metrics")
        }
        Entity::Flows => Some("ocsf_network_activity"),
        _ => None,
    }
}

/// Whether this query *shape* may be served from the cold tier.
///
/// Raw shapes only: a stats/downsample query stays on the CAGG path so the
/// same window keeps returning the same numbers regardless of tier.
fn is_cold_eligible_shape(entity: &Entity, has_stats: bool, has_downsample: bool) -> bool {
    cold_table_for_entity(entity).is_some() && !has_stats && !has_downsample
}

/// Whether the query should execute against the cold tier.
pub(crate) fn should_route_to_cold(
    config: &ColdTierConfig,
    entity: &Entity,
    time_range: Option<&TimeRange>,
    has_stats: bool,
    has_downsample: bool,
) -> bool {
    if config.is_empty() || !is_cold_eligible_shape(entity, has_stats, has_downsample) {
        return false;
    }

    let Some(cold) = config.lookup(entity) else {
        return false;
    };

    // No resolved window: hot only (an unbounded archive scan is never the
    // right answer, and there is nothing to compare against the boundary).
    let Some(time_range) = time_range else {
        return false;
    };

    // The window must actually reach below the boundary. Queries entirely at
    // or above it are hot-path queries and must stay byte-identical.
    time_range.start < cold.boundary
}

pub(crate) fn should_route_plan_to_cold(config: &ColdTierConfig, plan: &QueryPlan) -> bool {
    should_route_to_cold(
        config,
        &plan.entity,
        plan.time_range.as_ref(),
        plan.stats.is_some(),
        plan.downsample.is_some(),
    )
}

/// The lookback cap for a cold-eligible raw query, in days.
///
/// Cold-eligible raw shapes may look back to the entity's cold window instead
/// of the default raw cap; everything else keeps today's caps (which
/// `cagg::max_time_range_days_for_ast` still decides).
pub(crate) fn max_time_range_days_for_ast(
    config: &ColdTierConfig,
    ast: &QueryAst,
) -> Option<i64> {
    if config.is_empty() {
        return None;
    }

    if !is_cold_eligible_shape(&ast.entity, ast.stats.is_some(), ast.downsample.is_some()) {
        return None;
    }

    config.lookup(&ast.entity).map(|cold| cold.cold_window_days)
}

/// The boundary for an entity, when cold-configured.
pub(crate) fn boundary_for_entity(
    config: &ColdTierConfig,
    entity: &Entity,
) -> Option<DateTime<Utc>> {
    config.lookup(entity).map(|cold| cold.boundary)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn config() -> ColdTierConfig {
        ColdTierConfig {
            entities: vec![ColdEntity {
                table: "logs".to_string(),
                boundary: Utc.with_ymd_and_hms(2026, 7, 14, 0, 0, 0).unwrap(),
                cold_window_days: 365,
            }],
        }
    }

    fn range(start: (i32, u32, u32), end: (i32, u32, u32)) -> TimeRange {
        TimeRange {
            start: Utc
                .with_ymd_and_hms(start.0, start.1, start.2, 0, 0, 0)
                .unwrap(),
            end: Utc.with_ymd_and_hms(end.0, end.1, end.2, 0, 0, 0).unwrap(),
        }
    }

    #[test]
    fn absent_config_never_routes_cold() {
        let empty = ColdTierConfig::default();
        let r = range((2026, 1, 1), (2026, 7, 16));
        assert!(!should_route_to_cold(
            &empty,
            &Entity::Logs,
            Some(&r),
            false,
            false
        ));
    }

    #[test]
    fn window_below_boundary_routes_cold() {
        let r = range((2026, 7, 1), (2026, 7, 16));
        assert!(should_route_to_cold(
            &config(),
            &Entity::Logs,
            Some(&r),
            false,
            false
        ));
    }

    #[test]
    fn window_inside_hot_stays_hot() {
        let r = range((2026, 7, 15), (2026, 7, 16));
        assert!(!should_route_to_cold(
            &config(),
            &Entity::Logs,
            Some(&r),
            false,
            false
        ));
    }

    #[test]
    fn stats_and_downsample_stay_on_caggs() {
        let r = range((2026, 7, 1), (2026, 7, 16));
        assert!(!should_route_to_cold(
            &config(),
            &Entity::Logs,
            Some(&r),
            true,
            false
        ));
        assert!(!should_route_to_cold(
            &config(),
            &Entity::Logs,
            Some(&r),
            false,
            true
        ));
    }

    #[test]
    fn no_time_range_stays_hot() {
        assert!(!should_route_to_cold(
            &config(),
            &Entity::Logs,
            None,
            false,
            false
        ));
    }

    #[test]
    fn non_registry_entity_never_routes_cold() {
        let r = range((2026, 1, 1), (2026, 7, 16));
        assert!(!should_route_to_cold(
            &config(),
            &Entity::Devices,
            Some(&r),
            false,
            false
        ));
    }

    #[test]
    fn unconfigured_entity_never_routes_cold() {
        // Registry-eligible shape, but this deployment only configured logs.
        let r = range((2026, 1, 1), (2026, 7, 16));
        assert!(!should_route_to_cold(
            &config(),
            &Entity::Traces,
            Some(&r),
            false,
            false
        ));
    }
}
