use super::QueryPlan;
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, FilterOp},
};
use diesel::prelude::*;
use diesel::sql_types::{Jsonb, Text};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;
    let device_id = extract_device_id(plan)?;

    let row = diesel::sql_query(DEVICE_GRAPH_QUERY)
        .bind::<Text, _>(device_id)
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

fn extract_device_id(plan: &QueryPlan) -> Result<String> {
    let mut device_id: Option<String> = None;

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
            other => {
                return Err(ServiceError::InvalidRequest(format!(
                    "unsupported filter field '{other}' for device_graph"
                )));
            }
        }
    }

    device_id.ok_or_else(|| {
        ServiceError::InvalidRequest("device_id filter is required for device_graph queries".into())
    })
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
SELECT result::jsonb AS result
FROM ag_catalog.cypher(
    'serviceradar',
    format($$ 
        MATCH (d:Device {id: %L})
        OPTIONAL MATCH (d)-[:REPORTED_BY]->(col:Collector)
        OPTIONAL MATCH (col)-[:HOSTS_SERVICE]->(svc:Service)
        OPTIONAL MATCH (svc)-[:TARGETS]->(t:Device)
        OPTIONAL MATCH (d)-[:HAS_INTERFACE]->(iface:Interface)
        OPTIONAL MATCH (d)-[:PROVIDES_CAPABILITY]->(dcap:Capability)
        OPTIONAL MATCH (svc)-[:PROVIDES_CAPABILITY]->(svcCap:Capability)
        RETURN jsonb_build_object(
            'device', d,
            'collectors', [c IN collect(DISTINCT col) WHERE c IS NOT NULL],
            'services', [s IN collect(DISTINCT CASE WHEN svc IS NULL THEN NULL ELSE jsonb_build_object(
                'service', svc,
                'collector_id', col.id,
                'collector_owned', col IS NOT NULL
            ) END) WHERE s IS NOT NULL],
            'targets', [target IN collect(DISTINCT t) WHERE target IS NOT NULL],
            'interfaces', [i IN collect(DISTINCT iface) WHERE i IS NOT NULL],
            'device_capabilities', [cap IN collect(DISTINCT dcap) WHERE cap IS NOT NULL],
            'service_capabilities', [cap IN collect(DISTINCT svcCap) WHERE cap IS NOT NULL]
        ) AS result
    $$, $1)
) AS (result agtype);
"#;
