use crate::{
    error::{Result, ServiceError},
    jsonb::DbJson,
    query::{BindParam, QueryPlan},
    time::TimeRange,
};
use chrono::{DateTime, Utc};
use diesel::{
    deserialize::QueryableByName,
    pg::Pg,
    query_builder::{BoxedSqlQuery, SqlQuery},
    sql_query,
    sql_types::{Jsonb, Nullable, Timestamptz},
};

#[derive(Debug, Clone)]
pub(super) struct EventsRollupSql {
    pub(super) sql: String,
    pub(super) binds: Vec<EventsRollupBind>,
}

impl EventsRollupSql {
    pub(super) fn to_boxed_query(&self) -> BoxedSqlQuery<'_, Pg, SqlQuery> {
        let mut query = sql_query(rewrite_placeholders(&self.sql)).into_boxed::<Pg>();

        for bind in &self.binds {
            query = bind.apply(query);
        }

        query
    }
}

#[derive(Debug, QueryableByName)]
#[diesel(check_for_backend(diesel::pg::Pg))]
pub(super) struct EventsRollupPayload {
    #[diesel(sql_type = Nullable<Jsonb>)]
    pub(super) payload: Option<DbJson>,
}

#[derive(Debug, Clone)]
pub(super) enum EventsRollupBind {
    Timestamp(DateTime<Utc>),
}

impl EventsRollupBind {
    fn apply<'a>(&self, query: BoxedSqlQuery<'a, Pg, SqlQuery>) -> BoxedSqlQuery<'a, Pg, SqlQuery> {
        match self {
            EventsRollupBind::Timestamp(value) => query.bind::<Timestamptz, _>(*value),
        }
    }
}

pub(super) fn bind_param_from_rollup(value: EventsRollupBind) -> BindParam {
    match value {
        EventsRollupBind::Timestamp(value) => BindParam::timestamptz(value),
    }
}

pub(super) fn build_rollup_stats_query(plan: &QueryPlan) -> Result<Option<EventsRollupSql>> {
    let stat_type = match plan.rollup_stats.as_ref() {
        Some(stat_type) if !stat_type.trim().is_empty() => stat_type.trim(),
        _ => return Ok(None),
    };

    match stat_type {
        "anomaly_findings" => build_anomaly_findings_rollup_stats(plan),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported rollup_stats type for events: '{other}' (supported: anomaly_findings)"
        ))),
    }
}

fn build_anomaly_findings_rollup_stats(plan: &QueryPlan) -> Result<Option<EventsRollupSql>> {
    if !plan.filters.is_empty() {
        let fields = plan
            .filters
            .iter()
            .map(|filter| filter.field.as_str())
            .collect::<Vec<_>>()
            .join(", ");

        return Err(ServiceError::InvalidRequest(format!(
            "rollup_stats:anomaly_findings does not support filters, got: '{fields}'"
        )));
    }

    // Both anomaly-detection verdicts and capacity-forecast verdicts are written
    // by build_anomaly_detection_finding_row as OCSF Detection Findings, i.e. every
    // row this rollup can match satisfies class_uid = 2004 AND category_uid = 2.
    // Hoisting that pair to a leading top-level AND lets the planner range-scan
    // idx_ocsf_events_class_category_time (class_uid, category_uid, time DESC)
    // instead of seq-scanning the whole chunk: previously the
    // (anomaly_clause OR capacity_clause) blob put a JSONB-source predicate at the
    // top of the OR, defeating every index. The source-discriminating JSONB OR is
    // now evaluated only over the already-narrowed 2004/2 partition, so the counts
    // are identical, just index-served. (See verdict_emitter.ex class_uid => 2004
    // and build_anomaly_detection_finding_row category_uid => 2.)
    //
    // Verified invariant (live demo CNPG, 2026-06-17): of 34,937 rows matching the
    // capacity-forecast source predicate (and of the 166 matching the full
    // capacity_clause), ZERO carry class_uid <> 2004 or category_uid <> 2; the same
    // holds for every anomaly-source row. The latent risk the hoist guards against
    // is a capacity verdict that falls through to build_causal_signal_event_row
    // (class_uid 1008) while still carrying unmapped event_type = capacity_forecast;
    // no such row exists today, so the hoist drops nothing. If that path ever starts
    // emitting non-2004/2 capacity rows, restructure to keep the capacity arm an
    // independent OR (WHERE (class_uid=2004 AND category_uid=2 AND source) OR
    // capacity_clause) so the anomaly arm still leads with the indexable predicate.
    let anomaly_clause = anomaly_detection_rollup_source_clause();
    let capacity_event_clause = capacity_forecast_rollup_source_clause();
    let capacity_clause = capacity_forecast_at_risk_rollup_clause();
    let anomaly_count_clause = format!("({anomaly_clause}) AND NOT ({capacity_event_clause})");
    let mut binds = Vec::new();
    let mut clauses = vec![
        "\"class_uid\" = 2004".to_string(),
        "\"category_uid\" = 2".to_string(),
        format!("(({anomaly_count_clause}) OR ({capacity_clause}))"),
    ];

    if let Some(TimeRange { start, end }) = &plan.time_range {
        clauses.push("\"time\" >= ?".to_string());
        binds.push(EventsRollupBind::Timestamp(*start));
        clauses.push("\"time\" < ?".to_string());
        binds.push(EventsRollupBind::Timestamp(*end));
    }

    let sql = format!(
        r#"SELECT jsonb_build_object(
    'total', COALESCE(COUNT(*), 0)::bigint,
    'anomalies', COALESCE(COUNT(*) FILTER (WHERE {anomaly_count_clause}), 0)::bigint,
    'at_risk', COALESCE(COUNT(*) FILTER (WHERE {capacity_clause}), 0)::bigint,
    'critical', COALESCE(COUNT(*) FILTER (WHERE ({anomaly_count_clause}) AND COALESCE(severity_id, 0) >= 5), 0)::bigint,
    'high', COALESCE(COUNT(*) FILTER (WHERE ({anomaly_count_clause}) AND COALESCE(severity_id, 0) = 4), 0)::bigint
) AS payload
FROM ocsf_events
WHERE {}"#,
        clauses.join(" AND ")
    );

    Ok(Some(EventsRollupSql { sql, binds }))
}

// Source-discrimination only: the class_uid/category_uid gate is now hoisted to a
// top-level AND in build_anomaly_findings_rollup_stats so the planner can use
// idx_ocsf_events_class_category_time. Keep this predicate scoped to explicit
// anomaly markers only; generic OCSF detection_finding metadata is also used by
// capacity forecast verdicts and would inflate the anomaly count.
pub(super) fn anomaly_detection_rollup_source_clause() -> &'static str {
    r#"(
  metadata #>> '{service_radar,source_type}' = 'anomaly_detection'
  OR metadata #>> '{service_radar,addon_id}' = 'anomaly-detection'
  OR metadata #>> '{detection_finding,type}' = 'anomaly'
  OR metadata #>> '{security_signal,source}' = 'anomaly_detection'
  OR log_provider = 'anomaly_detection'
  OR unmapped ->> 'event_type' IN ('anomaly', 'anomaly_detection')
)"#
}

pub(super) fn capacity_forecast_at_risk_rollup_clause() -> &'static str {
    r#"(metadata ->> 'event_type' = 'capacity_forecast'
  OR unmapped ->> 'event_type' = 'capacity_forecast'
  OR log_provider = 'capacity_forecasting')
AND (
  COALESCE(severity_id, 0) >= 3
  OR unmapped #>> '{capacity_forecast,status}' IN ('projected', 'at_risk', 'exhaustion_projected')
  OR NULLIF(unmapped #>> '{capacity_forecast,projected_exhaustion_at}', '') IS NOT NULL
)"#
}

pub(super) fn capacity_forecast_rollup_source_clause() -> &'static str {
    r#"(metadata ->> 'event_type' = 'capacity_forecast'
  OR unmapped ->> 'event_type' = 'capacity_forecast'
  OR log_provider = 'capacity_forecasting')"#
}

pub(super) fn rewrite_placeholders(sql: &str) -> String {
    let mut rewritten = String::with_capacity(sql.len());
    let mut index = 1;

    for ch in sql.chars() {
        if ch == '?' {
            rewritten.push('$');
            rewritten.push_str(&index.to_string());
            index += 1;
        } else {
            rewritten.push(ch);
        }
    }

    rewritten
}
