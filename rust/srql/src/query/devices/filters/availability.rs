use super::super::DeviceQuery;
use crate::{
    error::{Result, ServiceError},
    parser::{Filter, FilterOp},
    time::parse_time_value,
};
use chrono::{DateTime, Utc};
use diesel::{
    dsl::sql,
    prelude::*,
    sql_types::{Bool, Text, Timestamptz},
};

pub(super) fn apply_agent_availability_filter<'a>(
    query: DeviceQuery<'a>,
    filter: &Filter,
    available: bool,
) -> Result<DeviceQuery<'a>> {
    if !matches!(filter.op, FilterOp::Eq) {
        return Err(ServiceError::InvalidRequest(
            "per-agent availability filters only support equality".into(),
        ));
    }

    let agent_id = filter.value.as_scalar()?.to_string();
    let expr = sql::<Bool>(
        "EXISTS (SELECT 1 FROM device_agent_availability daa WHERE daa.device_uid = ocsf_devices.uid AND daa.agent_id = ",
    )
    .bind::<Text, _>(agent_id)
    .sql(" AND daa.is_available = ")
    .sql(if available { "true" } else { "false" })
    .sql(")");

    Ok(query.filter(expr))
}

pub(super) fn apply_availability_source_freshness_filter<'a>(
    query: DeviceQuery<'a>,
    filter: &Filter,
    fresh: bool,
) -> Result<DeviceQuery<'a>> {
    if !matches!(filter.op, FilterOp::Eq) {
        return Err(ServiceError::InvalidRequest(
            "availability source freshness filters only support equality".into(),
        ));
    }

    let threshold = freshness_threshold(filter)?;
    let fresh_expr = sql::<Bool>(
        r#"
        NULLIF(BTRIM(ocsf_devices.availability_source_agent_id), '') IS NOT NULL
        AND EXISTS (
          SELECT 1
          FROM device_agent_availability daa
          WHERE daa.device_uid = ocsf_devices.uid
            AND daa.agent_id = ocsf_devices.availability_source_agent_id
            AND daa.checked_at >=
        "#,
    )
    .bind::<Timestamptz, _>(threshold)
    .sql(")");

    let stale_expr = sql::<Bool>(
        r#"
        NULLIF(BTRIM(ocsf_devices.availability_source_agent_id), '') IS NOT NULL
        AND NOT EXISTS (
          SELECT 1
          FROM device_agent_availability daa
          WHERE daa.device_uid = ocsf_devices.uid
            AND daa.agent_id = ocsf_devices.availability_source_agent_id
            AND daa.checked_at >=
        "#,
    )
    .bind::<Timestamptz, _>(threshold)
    .sql(")");

    Ok(if fresh {
        query.filter(fresh_expr)
    } else {
        query.filter(stale_expr)
    })
}

pub(super) fn freshness_threshold(filter: &Filter) -> Result<DateTime<Utc>> {
    filter
        .value
        .as_scalar()
        .and_then(parse_time_value)?
        .resolve(Utc::now())
        .map(|range| range.start)
}
