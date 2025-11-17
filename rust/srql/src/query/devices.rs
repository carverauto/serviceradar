use super::QueryPlan;
use crate::{
    error::{Result, ServiceError},
    models::DeviceRow,
    parser::{Entity, Filter, FilterOp, FilterValue, OrderClause, OrderDirection},
    schema::unified_devices::dsl::{
        agent_id as col_agent_id, device_id as col_device_id, device_type as col_device_type,
        first_seen as col_first_seen, hostname as col_hostname, ip as col_ip,
        is_available as col_is_available, last_seen as col_last_seen, mac as col_mac,
        poller_id as col_poller_id, service_status as col_service_status,
        service_type as col_service_type, unified_devices, version_info as col_version_info,
    },
    time::TimeRange,
};
use diesel::dsl::sql;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel::sql_types::{Array, Bool, Text};
use diesel::PgTextExpressionMethods;
use diesel_async::{AsyncPgConnection, RunQueryDsl};

type UnifiedDevicesTable = crate::schema::unified_devices::table;
type DeviceFromClause = FromClause<UnifiedDevicesTable>;
type DeviceQuery<'a> =
    BoxedSelectStatement<'a, <UnifiedDevicesTable as AsQuery>::SqlType, DeviceFromClause, Pg>;

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    let rows: Vec<DeviceRow> = query
        .limit(plan.limit)
        .offset(plan.offset)
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(DeviceRow::into_json).collect())
}

pub(super) fn to_debug_sql(plan: &QueryPlan) -> Result<String> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    let sql =
        diesel::debug_query::<Pg, _>(&query.limit(plan.limit).offset(plan.offset)).to_string();
    Ok(sql)
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    match plan.entity {
        Entity::Devices => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by devices query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<DeviceQuery<'static>> {
    let mut query = unified_devices.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_last_seen.ge(*start).and(col_last_seen.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

fn apply_filter<'a>(mut query: DeviceQuery<'a>, filter: &Filter) -> Result<DeviceQuery<'a>> {
    match filter.field.as_str() {
        "device_id" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_device_id.eq(value)),
                FilterOp::NotEq => query.filter(col_device_id.ne(value)),
                FilterOp::Like => query.filter(col_device_id.ilike(value)),
                FilterOp::NotLike => query.filter(col_device_id.not_ilike(value)),
                FilterOp::In | FilterOp::NotIn => {
                    let values = filter.value.as_list()?.to_vec();
                    if values.is_empty() {
                        return Ok(query);
                    }
                    if matches!(filter.op, FilterOp::In) {
                        query.filter(col_device_id.eq_any(values))
                    } else {
                        query.filter(col_device_id.ne_all(values))
                    }
                }
            };
        }
        "hostname" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_hostname.eq(value)),
                FilterOp::NotEq => query.filter(col_hostname.ne(value)),
                FilterOp::Like => query.filter(col_hostname.ilike(value)),
                FilterOp::NotLike => query.filter(col_hostname.not_ilike(value)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "hostname filter does not support lists".into(),
                    ))
                }
            };
        }
        "ip" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_ip.eq(value)),
                FilterOp::NotEq => query.filter(col_ip.ne(value)),
                FilterOp::Like => query.filter(col_ip.ilike(value)),
                FilterOp::NotLike => query.filter(col_ip.not_ilike(value)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "ip filter does not support lists".into(),
                    ))
                }
            };
        }
        "mac" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_mac.eq(value)),
                FilterOp::NotEq => query.filter(col_mac.ne(value)),
                FilterOp::Like => query.filter(col_mac.ilike(value)),
                FilterOp::NotLike => query.filter(col_mac.not_ilike(value)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "mac filter does not support lists".into(),
                    ))
                }
            };
        }
        "poller_id" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_poller_id.eq(value)),
                FilterOp::NotEq => query.filter(col_poller_id.ne(value)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "poller filter only supports equality".into(),
                    ))
                }
            };
        }
        "agent_id" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_agent_id.eq(value)),
                FilterOp::NotEq => query.filter(col_agent_id.ne(value)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "agent filter only supports equality".into(),
                    ))
                }
            };
        }
        "is_available" => {
            let value = parse_bool(filter.value.as_scalar()?)?;
            query = match filter.op {
                FilterOp::Eq => query.filter(col_is_available.eq(value)),
                FilterOp::NotEq => query.filter(col_is_available.ne(value)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "is_available only supports equality".into(),
                    ))
                }
            };
        }
        "device_type" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_device_type.eq(value)),
                FilterOp::NotEq => query.filter(col_device_type.ne(value)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "device_type filter only supports equality".into(),
                    ))
                }
            };
        }
        "service_type" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_service_type.eq(value)),
                FilterOp::NotEq => query.filter(col_service_type.ne(value)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "service_type filter only supports equality".into(),
                    ))
                }
            };
        }
        "service_status" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_service_status.eq(value)),
                FilterOp::NotEq => query.filter(col_service_status.ne(value)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "service_status filter only supports equality".into(),
                    ))
                }
            };
        }
        "discovery_sources" => {
            let values = match &filter.value {
                FilterValue::Scalar(v) => vec![v.to_string()],
                FilterValue::List(list) => list.clone(),
            };
            if values.is_empty() {
                return Ok(query);
            }
            let expr = sql::<Bool>("coalesce(discovery_sources, ARRAY[]::text[]) @> ")
                .bind::<Array<Text>, _>(values);
            query = query.filter(expr);
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field '{other}'"
            )));
        }
    }

    Ok(query)
}

fn apply_ordering<'a>(mut query: DeviceQuery<'a>, order: &[OrderClause]) -> DeviceQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            match clause.field.as_str() {
                "device_id" => match clause.direction {
                    OrderDirection::Asc => query.order(col_device_id.asc()),
                    OrderDirection::Desc => query.order(col_device_id.desc()),
                },
                "first_seen" => match clause.direction {
                    OrderDirection::Asc => query.order(col_first_seen.asc()),
                    OrderDirection::Desc => query.order(col_first_seen.desc()),
                },
                "last_seen" => match clause.direction {
                    OrderDirection::Asc => query.order(col_last_seen.asc()),
                    OrderDirection::Desc => query.order(col_last_seen.desc()),
                },
                "version_info" => match clause.direction {
                    OrderDirection::Asc => query.order(col_version_info.asc()),
                    OrderDirection::Desc => query.order(col_version_info.desc()),
                },
                _ => query,
            }
        } else {
            match clause.field.as_str() {
                "device_id" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_device_id.asc()),
                    OrderDirection::Desc => query.then_order_by(col_device_id.desc()),
                },
                "first_seen" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_first_seen.asc()),
                    OrderDirection::Desc => query.then_order_by(col_first_seen.desc()),
                },
                "last_seen" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_last_seen.asc()),
                    OrderDirection::Desc => query.then_order_by(col_last_seen.desc()),
                },
                _ => query,
            }
        };
    }

    if !applied {
        query = query
            .order(col_last_seen.desc())
            .then_order_by(col_device_id.desc());
    }

    query
}

fn parse_bool(raw: &str) -> Result<bool> {
    match raw.to_lowercase().as_str() {
        "true" | "1" | "yes" => Ok(true),
        "false" | "0" | "no" => Ok(false),
        _ => Err(ServiceError::InvalidRequest(format!(
            "invalid boolean value '{raw}'"
        ))),
    }
}
