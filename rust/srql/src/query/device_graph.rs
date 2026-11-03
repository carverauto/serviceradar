//! `in:device_graph`: one device's neighbourhood from the Dgraph topology graph.

use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, FilterOp},
};
use dgraph_topology::TopologyClient;
use serde_json::Value;

pub(super) async fn execute(plan: &QueryPlan, dgraph_url: Option<&str>) -> Result<Vec<Value>> {
    ensure_entity(plan)?;
    let params = extract_params(plan)?;
    let url = dgraph_url
        .filter(|value| !value.is_empty())
        .ok_or_else(|| ServiceError::InvalidRequest("device_graph requires DGRAPH_URL".into()))?;

    let client = TopologyClient::connect(url)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;
    let neighborhood = client
        .query_device_neighborhood(&params.device_id, params.include_topology)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;
    Ok(neighborhood.into_iter().collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;
    let _ = extract_params(plan)?;
    Err(ServiceError::InvalidRequest(
        "device_graph is not SQL; execute it against Dgraph".into(),
    ))
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    match plan.entity {
        Entity::DeviceGraph => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by device_graph query".into(),
        )),
    }
}

#[derive(Debug)]
struct DeviceGraphParams {
    device_id: String,
    include_topology: bool,
}

fn extract_params(plan: &QueryPlan) -> Result<DeviceGraphParams> {
    let mut device_id: Option<String> = None;
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
                validate_device_id(value)?;
                device_id = Some(value.to_string());
            }
            "collector_owned" | "collector_owned_only" => {
                if !matches!(filter.op, FilterOp::Eq) {
                    return Err(ServiceError::InvalidRequest(
                        "collector_owned filter only supports equality".into(),
                    ));
                }
                let value = filter.value.as_scalar()?.trim().to_lowercase();
                let collector_owned_only = parse_bool(&value, false).ok_or_else(|| {
                    ServiceError::InvalidRequest(
                        "collector_owned filter expects boolean true/false".into(),
                    )
                })?;
                // The topology graph carries no collector vertices, so no
                // device could satisfy this; refuse rather than return nothing.
                if collector_owned_only {
                    return Err(ServiceError::InvalidRequest(
                        "collector_owned:true is not supported: collector ownership is not \
                         part of the topology graph"
                            .into(),
                    ));
                }
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
        include_topology,
    })
}

fn parse_bool(input: &str, default_value: bool) -> Option<bool> {
    if input.is_empty() {
        return Some(default_value);
    }
    input.parse::<bool>().ok()
}

/// The id becomes a DQL string literal, which cannot carry a quote or a
/// backslash; control characters are never part of a device id.
fn validate_device_id(value: &str) -> Result<()> {
    if value.contains('"') || value.contains('\\') {
        return Err(ServiceError::InvalidRequest(
            "device_id cannot contain quotes or backslashes".into(),
        ));
    }

    if value.chars().any(|ch| ch.is_ascii_control()) {
        return Err(ServiceError::InvalidRequest(
            "device_id contains invalid control characters".into(),
        ));
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::{Entity, Filter, FilterOp, FilterValue};

    fn plan(filters: &[(&str, &str)]) -> QueryPlan {
        QueryPlan {
            entity: Entity::DeviceGraph,
            filters: filters
                .iter()
                .map(|(field, value)| Filter {
                    field: (*field).into(),
                    op: FilterOp::Eq,
                    value: FilterValue::Scalar((*value).into()),
                })
                .collect(),
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: None,
            stats: None,
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
            exhaustive_window: false,
        }
    }

    #[test]
    fn rejects_device_ids_that_cannot_be_dql_literals() {
        for id in [r#"sr:host01"x"#, r"sr:host01\x", "sr:host01\nx"] {
            let err = extract_params(&plan(&[("device_id", id)]))
                .expect_err("a device_id that breaks a DQL literal must be rejected");
            assert!(
                matches!(err, ServiceError::InvalidRequest(_)),
                "{id:?} must be a client error, got {err}"
            );
        }
    }

    #[test]
    fn accepts_standard_device_ids_and_topology_toggle() {
        let params = extract_params(&plan(&[
            ("device_id", "sr:host01.example.com"),
            ("include_topology", "false"),
            ("collector_owned", "false"),
        ]))
        .expect("standard device_id should be accepted");
        assert_eq!(params.device_id, "sr:host01.example.com");
        assert!(!params.include_topology);
    }

    #[test]
    fn refuses_collector_owned_true() {
        let err = extract_params(&plan(&[
            ("device_id", "sr:host01.example.com"),
            ("collector_owned", "true"),
        ]))
        .expect_err("collector ownership is not in the topology graph");
        assert!(err.to_string().contains("collector_owned:true"), "{err}");
    }
}
