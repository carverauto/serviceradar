use super::QueryPlan;
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, FilterOp},
};
use diesel::prelude::*;
use diesel::sql_types::{Bool, Jsonb, Text};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;
    let params = extract_params(plan)?;

    let row = diesel::sql_query(DEVICE_GRAPH_QUERY)
        .bind::<Text, _>(params.device_id)
        .bind::<Bool, _>(params.collector_owned_only)
        .bind::<Bool, _>(params.include_topology)
        .get_result::<DeviceGraphRow>(conn)
        .await
        .optional()
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(row.map(|r| vec![r.result]).unwrap_or_default())
}

pub(super) fn to_debug_sql(plan: &QueryPlan) -> Result<String> {
    ensure_entity(plan)?;
    Ok(DEVICE_GRAPH_QUERY.trim().to_string())
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    match plan.entity {
        Entity::DeviceGraph => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by device_graph query".into(),
        )),
    }
}

struct DeviceGraphParams {
    device_id: String,
    collector_owned_only: bool,
    include_topology: bool,
}

fn extract_params(plan: &QueryPlan) -> Result<DeviceGraphParams> {
    let mut device_id: Option<String> = None;
    let mut collector_owned_only = false;
    let mut include_topology = true;

    for filter in &plan.filters {
        match filter.field.as_str() {
            "device_id" => {
                if !matches!(filter.op, FilterOp::Eq) {
                    return Err(ServiceError::InvalidRequest(
                        "device_id filter only supports equality".into(),
                    ));
                }
                let value = filter.value.as_scalar()?.trim();
                if value.is_empty() {
                    return Err(ServiceError::InvalidRequest(
                        "device_id filter cannot be empty".into(),
                    ));
                }
                device_id = Some(value.to_string());
            }
            "collector_owned" | "collector_owned_only" => {
                if !matches!(filter.op, FilterOp::Eq) {
                    return Err(ServiceError::InvalidRequest(
                        "collector_owned filter only supports equality".into(),
                    ));
                }
                let value = filter.value.as_scalar()?.trim().to_lowercase();
                collector_owned_only = parse_bool(&value, false).ok_or_else(|| {
                    ServiceError::InvalidRequest(
                        "collector_owned filter expects boolean true/false".into(),
                    )
                })?;
            }
            "include_topology" => {
                if !matches!(filter.op, FilterOp::Eq) {
                    return Err(ServiceError::InvalidRequest(
                        "include_topology filter only supports equality".into(),
                    ));
                }
                let value = filter.value.as_scalar()?.trim().to_lowercase();
                include_topology = parse_bool(&value, true).ok_or_else(|| {
                    ServiceError::InvalidRequest(
                        "include_topology filter expects boolean true/false".into(),
                    )
                })?;
            }
            other => {
                return Err(ServiceError::InvalidRequest(format!(
                    "unsupported filter field '{other}' for device_graph"
                )));
            }
        }
    }

    let device_id = device_id.ok_or_else(|| {
        ServiceError::InvalidRequest("device_id filter is required for device_graph queries".into())
    })?;

    Ok(DeviceGraphParams {
        device_id,
        collector_owned_only,
        include_topology,
    })
}

fn parse_bool(input: &str, default_value: bool) -> Option<bool> {
    if input.is_empty() {
        return Some(default_value);
    }
    input.parse::<bool>().ok()
}

#[derive(QueryableByName)]
struct DeviceGraphRow {
    #[diesel(sql_type = Jsonb)]
    result: Value,
}

const DEVICE_GRAPH_QUERY: &str = r#"
WITH _config AS (
    SELECT
        set_config('search_path', 'ag_catalog,"$user",public', false)
)
SELECT public.age_device_neighborhood($1::text, $2::boolean, $3::boolean) AS result;
"#;
