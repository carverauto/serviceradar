use super::{fields::series_expr, filters::filter_clause};
use crate::{
    error::Result,
    parser::{DownsampleAgg, Entity},
    query::{QueryPlan, flows::activity},
};

pub(super) fn route(plan: &QueryPlan) -> bool {
    matches!(plan.entity, Entity::Flows)
        && super::super::should_route_plan_to_hourly_cagg(plan)
        && activity::supports_filters(plan)
        && plan.downsample.as_ref().is_some_and(|spec| {
            spec.series.as_deref() == Some("app")
                && spec.bucket_seconds >= 3600
                && spec.bucket_seconds % 3600 == 0
                && matches!(spec.agg, DownsampleAgg::Sum)
                && matches!(
                    spec.value_field.as_deref(),
                    None | Some("bytes_total") | Some("packets_total")
                )
        })
}

pub(super) fn build_body(plan: &QueryPlan) -> Result<String> {
    let spec = plan.downsample.as_ref().expect("route requires downsample");
    let bucket = spec.bucket_seconds;
    let value = spec.value_field.as_deref().unwrap_or("bytes_total");
    let series = series_expr(plan, "f")?;
    let source = activity::source_sql(true);
    let filters = plan
        .filters
        .iter()
        .map(|filter| filter_clause(&Entity::Flows, "f", filter).map(|(sql, _)| sql))
        .collect::<Result<Vec<_>>>()?;
    let predicate = if filters.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", filters.join(" AND "))
    };
    Ok(format!(
        "SELECT to_timestamp(floor(extract(epoch from time) / {bucket}) * {bucket}) AT TIME ZONE 'UTC' AS timestamp, {series} AS series, SUM({value}) AS value\nFROM {source} f{predicate}\nGROUP BY 1, 2"
    ))
}
