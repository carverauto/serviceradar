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
    /// The head-acknowledged stitching seam B: on the analytics head, rows
    /// below it are served from Parquet and rows at/above it from the primary
    /// through postgres_fdw.
    ///
    /// B is NOT the routing decision. It trails `now()` by roughly the export
    /// lag (~48h), so routing on it would send an entirely-hot query (say
    /// `last_7d` against 30-day logs) to the cold head and break the
    /// byte-identical hot-path invariant. B only describes how the head
    /// stitches once a query is already going there.
    pub boundary: DateTime<Utc>,
    /// Absolute instant where the primary's retention actually ends for this
    /// table: data older than this only exists in the cold tier. This — not B
    /// — is what decides routing.
    pub hot_cutoff: DateTime<Utc>,
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

/// Everything about a query's shape that makes it ineligible for the cold
/// tier. One classifier so a new aggregate field cannot be forgotten in one
/// call site and silently cold-route a CAGG-reading query.
#[derive(Debug, Clone, Copy, Default)]
pub struct QueryShape {
    pub has_stats: bool,
    pub has_downsample: bool,
    /// `rollup_stats` reads a CAGG (e.g. `logs_severity_stats_5m`) that does
    /// NOT exist on the analytics head — cold-routing it would fail with a
    /// missing relation, and lifting its cap would promise history the CAGG
    /// cannot serve.
    pub has_rollup_stats: bool,
}

impl QueryShape {
    fn is_raw(&self) -> bool {
        !self.has_stats && !self.has_downsample && !self.has_rollup_stats
    }

    fn from_plan(plan: &QueryPlan) -> Self {
        Self {
            has_stats: plan.stats.is_some(),
            has_downsample: plan.downsample.is_some(),
            has_rollup_stats: plan.rollup_stats.is_some(),
        }
    }

    fn from_ast(ast: &QueryAst) -> Self {
        Self {
            has_stats: ast.stats.is_some(),
            has_downsample: ast.downsample.is_some(),
            has_rollup_stats: ast.rollup_stats.is_some(),
        }
    }
}

/// Whether this query *shape* may be served from the cold tier.
///
/// Raw shapes only: every aggregate shape stays on the CAGG path so the same
/// window keeps returning the same numbers regardless of tier.
fn is_cold_eligible_shape(entity: &Entity, shape: QueryShape) -> bool {
    cold_table_for_entity(entity).is_some() && shape.is_raw()
}

/// Whether the query should execute against the cold tier.
pub(crate) fn should_route_to_cold(
    config: &ColdTierConfig,
    entity: &Entity,
    time_range: Option<&TimeRange>,
    shape: QueryShape,
) -> bool {
    if config.is_empty() || !is_cold_eligible_shape(entity, shape) {
        return false;
    }

    let Some(cold) = config.lookup(entity) else {
        return false;
    };

    // No resolved window: hot only (an unbounded archive scan is never the
    // right answer, and there is nothing to compare against).
    let Some(time_range) = time_range else {
        return false;
    };

    // Route on the HOT CUTOFF, not the stitching seam B: only a window that
    // actually reaches data the primary no longer has needs the cold tier.
    // Anything at/above the cutoff is a hot query and must keep its
    // byte-identical primary plan.
    time_range.start < cold.hot_cutoff
}

pub(crate) fn should_route_plan_to_cold(config: &ColdTierConfig, plan: &QueryPlan) -> bool {
    should_route_to_cold(
        config,
        &plan.entity,
        plan.time_range.as_ref(),
        QueryShape::from_plan(plan),
    )
}

/// The lookback cap for a cold-eligible raw query, in days.
///
/// Cold-eligible raw shapes may look back to the entity's cold window instead
/// of the default raw cap; everything else keeps today's caps (which
/// `cagg::max_time_range_days_for_ast` still decides).
pub(crate) fn max_time_range_days_for_ast(config: &ColdTierConfig, ast: &QueryAst) -> Option<i64> {
    if config.is_empty() {
        return None;
    }

    if !is_cold_eligible_shape(&ast.entity, QueryShape::from_ast(ast)) {
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

    fn ts(y: i32, m: u32, d: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(y, m, d, 0, 0, 0).unwrap()
    }

    /// Deliberately models the real relationship: B trails now by the export
    /// lag (2026-07-14) while the hot cutoff is 30 days back (2026-06-16).
    /// Routing must use the cutoff, never B.
    fn config() -> ColdTierConfig {
        ColdTierConfig {
            entities: vec![ColdEntity {
                table: "logs".to_string(),
                boundary: ts(2026, 7, 14),
                hot_cutoff: ts(2026, 6, 16),
                cold_window_days: 365,
            }],
        }
    }

    fn range(start: DateTime<Utc>, end: DateTime<Utc>) -> TimeRange {
        TimeRange { start, end }
    }

    fn raw() -> QueryShape {
        QueryShape::default()
    }

    #[test]
    fn absent_config_never_routes_cold() {
        let r = range(ts(2026, 1, 1), ts(2026, 7, 16));
        assert!(!should_route_to_cold(
            &ColdTierConfig::default(),
            &Entity::Logs,
            Some(&r),
            raw()
        ));
    }

    #[test]
    fn window_below_hot_cutoff_routes_cold() {
        let r = range(ts(2026, 6, 1), ts(2026, 7, 16));
        assert!(should_route_to_cold(
            &config(),
            &Entity::Logs,
            Some(&r),
            raw()
        ));
    }

    #[test]
    fn window_inside_hot_stays_hot_even_though_it_predates_b() {
        // The regression F27 describes: last-7d style window starts well
        // below B (2026-07-14) but is entirely inside the 30-day hot window,
        // so the primary can answer it and MUST.
        let r = range(ts(2026, 7, 9), ts(2026, 7, 16));
        assert!(!should_route_to_cold(
            &config(),
            &Entity::Logs,
            Some(&r),
            raw()
        ));
    }

    #[test]
    fn window_exactly_at_hot_cutoff_stays_hot() {
        let r = range(ts(2026, 6, 16), ts(2026, 7, 16));
        assert!(!should_route_to_cold(
            &config(),
            &Entity::Logs,
            Some(&r),
            raw()
        ));
    }

    #[test]
    fn aggregate_shapes_stay_on_caggs() {
        let r = range(ts(2026, 1, 1), ts(2026, 7, 16));

        for shape in [
            QueryShape {
                has_stats: true,
                ..Default::default()
            },
            QueryShape {
                has_downsample: true,
                ..Default::default()
            },
            // rollup_stats reads a CAGG that does not exist on the head.
            QueryShape {
                has_rollup_stats: true,
                ..Default::default()
            },
        ] {
            assert!(!should_route_to_cold(
                &config(),
                &Entity::Logs,
                Some(&r),
                shape
            ));
        }
    }

    #[test]
    fn no_time_range_stays_hot() {
        assert!(!should_route_to_cold(&config(), &Entity::Logs, None, raw()));
    }

    #[test]
    fn non_registry_entity_never_routes_cold() {
        let r = range(ts(2026, 1, 1), ts(2026, 7, 16));
        assert!(!should_route_to_cold(
            &config(),
            &Entity::Devices,
            Some(&r),
            raw()
        ));
    }

    #[test]
    fn unconfigured_entity_never_routes_cold() {
        let r = range(ts(2026, 1, 1), ts(2026, 7, 16));
        assert!(!should_route_to_cold(
            &config(),
            &Entity::Traces,
            Some(&r),
            raw()
        ));
    }

    #[test]
    fn cap_lift_only_applies_to_raw_cold_eligible_shapes() {
        assert!(!is_cold_eligible_shape(
            &Entity::Logs,
            QueryShape {
                has_rollup_stats: true,
                ..Default::default()
            }
        ));
        assert!(is_cold_eligible_shape(&Entity::Logs, raw()));
    }
}
