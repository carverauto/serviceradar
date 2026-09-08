use super::spec::DeviceStatsSpec;
use crate::{
    error::Result,
    query::QueryPlan,
    schema::ocsf_devices::dsl::{
        deleted_at as col_deleted_at, last_seen_time as col_last_seen_time, ocsf_devices,
    },
    time::TimeRange,
};
use diesel::dsl::sql;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::sql_types::BigInt;

pub(in crate::query::devices) fn build_stats_query(
    plan: &QueryPlan,
    spec: &DeviceStatsSpec,
) -> Result<super::super::DeviceStatsQuery<'static>> {
    let mut query = ocsf_devices.into_boxed::<Pg>();

    if !plan.include_deleted && !super::super::filters::has_deleted_filter(&plan.filters) {
        query = query.filter(col_deleted_at.is_null());
    }

    if super::super::filters::should_apply_default_active_filter(&plan.filters)? {
        query = super::super::filters::apply_default_active_filter(query);
    }

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(
            col_last_seen_time
                .ge(*start)
                .and(col_last_seen_time.le(*end)),
        );
    }

    for filter in &plan.filters {
        query = super::super::filters::apply_filter(query, filter)?;
    }

    let select_sql = format!("coalesce(COUNT(*), 0) as {}", spec.alias);
    Ok(query.select(sql::<BigInt>(&select_sql)))
}
