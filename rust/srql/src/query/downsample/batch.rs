use super::{
    fields::{is_rate_agg, series_expr},
    filters::filter_clause,
    sql::rewrite_placeholders,
};
use crate::{
    error::{Result, ServiceError},
    parser::{DownsampleAgg, Entity, OrderDirection},
    query::{BindParam, QueryPlan, dialect, shift_dollar_placeholders},
};

/// Return None for shapes that must retain their ordinary execution route.
pub(in crate::query) fn build_batch(
    plans: &[QueryPlan],
) -> Result<Option<(String, Vec<BindParam>)>> {
    if plans.iter().all(|plan| plan.dialect.is_postgres()) {
        return Ok(None);
    }
    let invalid = || {
        ServiceError::InvalidRequest(
        "archive batch requires the same metric table, time window and bucket with non-rate aggregations".into()
    )
    };
    let first = &plans[0];
    let spec = first.downsample.as_ref().ok_or_else(invalid)?;
    let window = first.time_range.as_ref().ok_or_else(invalid)?;
    if !plans
        .iter()
        .all(|plan| eligible(plan, first, spec.bucket_seconds))
    {
        return Err(invalid());
    }
    let mut params = vec![
        BindParam::timestamptz(window.start),
        BindParam::timestamptz(window.end),
    ];
    let mut predicates = Vec::new();
    let mut projections = Vec::new();
    for (i, plan) in plans.iter().enumerate() {
        let mut clauses = Vec::new();
        for filter in &plan.filters {
            let (sql, binds) = filter_clause(&plan.entity, "timeseries_metrics", filter)?;
            clauses.push(shift_dollar_placeholders(
                &rewrite_placeholders(&sql),
                params.len(),
            ));
            params.extend(binds.into_iter().map(|b| b.into_bind_param()));
        }
        let predicate = if clauses.is_empty() {
            "TRUE".into()
        } else {
            clauses.join(" AND ")
        };
        let series = series_expr(plan, "timeseries_metrics")?;
        projections.push(format!("CASE WHEN {predicate} THEN {series} ELSE NULL END AS series_{i}, ({predicate}) AS include_{i}"));
        predicates.push(format!("({predicate})"));
    }
    let branch = |values: Vec<String>| format!("CASE {} END", values.join(" "));
    let lane = branch(
        (0..plans.len())
            .map(|i| format!("WHEN GROUPING(series_{i})=0 THEN {i}"))
            .collect(),
    );
    let series = branch(
        (0..plans.len())
            .map(|i| format!("WHEN GROUPING(series_{i})=0 THEN series_{i}"))
            .collect(),
    );
    let aggregate = branch(plans.iter().enumerate().map(|(i,p)| {
        let (function, value) = match p.downsample.as_ref().unwrap().agg {
            DownsampleAgg::Avg => ("AVG", "value"), DownsampleAgg::Min => ("MIN", "value"),
            DownsampleAgg::Max => ("MAX", "value"), DownsampleAgg::Sum => ("SUM", "value"),
            DownsampleAgg::Count => ("COUNT", "1"), _ => unreachable!("rates are ineligible"),
        };
        format!("WHEN GROUPING(series_{i})=0 THEN {function}(CASE WHEN include_{i} THEN {value} END)::float8")
    }).collect());
    let having = branch(
        (0..plans.len())
            .map(|i| format!("WHEN GROUPING(series_{i})=0 THEN bool_or(include_{i})"))
            .collect(),
    );
    let groups = (0..plans.len())
        .map(|i| format!("(timestamp,series_{i})"))
        .collect::<Vec<_>>()
        .join(",");
    let limits = plans
        .iter()
        .enumerate()
        .map(|(i, p)| format!("WHEN {i} THEN {}", p.limit))
        .collect::<Vec<_>>()
        .join(" ");
    let newest = plans
        .iter()
        .enumerate()
        .filter_map(|(i, p)| {
            p.order
                .first()
                .is_some_and(|o| matches!(o.direction, OrderDirection::Desc))
                .then_some(i.to_string())
        })
        .collect::<Vec<_>>();
    let desc = if newest.is_empty() {
        "FALSE".into()
    } else {
        format!("batch_index IN ({})", newest.join(","))
    };
    let sql = format!(
        "WITH batch_source AS (\nSELECT to_timestamp(floor(extract(epoch from timestamp)/{bucket})*{bucket}) AT TIME ZONE 'UTC' AS timestamp, value, {projections}\nFROM timeseries_metrics\nWHERE timestamp >= $1 AND timestamp <= $2 AND ({predicates})\n), batch_groups AS (\nSELECT timestamp, {lane} AS batch_index, {series} AS series, {aggregate} AS value\nFROM batch_source\nGROUP BY GROUPING SETS ({groups})\nHAVING {having}\n), batch_ranked AS (\nSELECT *, row_number() OVER (PARTITION BY batch_index ORDER BY CASE WHEN {desc} THEN timestamp END DESC, CASE WHEN NOT ({desc}) THEN timestamp END ASC, series ASC NULLS FIRST) AS batch_rank\nFROM batch_groups\n)\nSELECT timestamp,series,value,batch_index FROM batch_ranked\nWHERE batch_rank <= CASE batch_index {limits} END\nORDER BY batch_index,timestamp ASC,series ASC NULLS FIRST",
        bucket = spec.bucket_seconds,
        projections = projections.join(",\n"),
        predicates = predicates.join(" OR ")
    );
    Ok(Some((dialect::apply_sql(first, sql)?, params)))
}

fn eligible(plan: &QueryPlan, first: &QueryPlan, bucket: i64) -> bool {
    plan.dialect.is_duckdb()
        && matches!(plan.entity, Entity::TimeseriesMetrics)
        && plan.stats.is_none()
        && plan.rollup_stats.is_none()
        && !plan.other
        && plan.offset == 0
        && plan
            .time_range
            .as_ref()
            .zip(first.time_range.as_ref())
            .is_some_and(|(a, b)| a.start == b.start && a.end == b.end)
        && plan.downsample.as_ref().is_some_and(|d| {
            d.bucket_seconds == bucket && !is_rate_agg(d.agg) && d.value_field.is_none()
        })
}
