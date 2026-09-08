use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    jsonb::DbJson,
    parser::{Entity, Filter, FilterOp, FilterValue, OrderClause, OrderDirection},
    time::TimeRange,
};
use diesel::deserialize::QueryableByName;
use diesel::pg::Pg;
use diesel::query_builder::{BoxedSqlQuery, SqlQuery};
use diesel::sql_query;
use diesel::sql_types::{Array, BigInt, Bool, Float8, Jsonb, Nullable, Text, Timestamptz};
use diesel_async::{AsyncPgConnection, RunQueryDsl};

#[derive(Debug, QueryableByName)]
#[diesel(check_for_backend(diesel::pg::Pg))]
struct JsonPayloadRow {
    #[diesel(sql_type = Nullable<Jsonb>)]
    payload: Option<DbJson>,
}

#[derive(Debug, Clone, Copy)]
struct EntitySpec {
    table: &'static str,
    joins: &'static str,
    payload_extra: &'static str,
    default_order: &'static str,
}

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;
    let (sql, params) = to_sql_and_params(plan)?;
    let mut query = sql_query(&sql).into_boxed::<Pg>();

    for param in params {
        query = bind_param(query, param)?;
    }

    let rows: Vec<JsonPayloadRow> = query
        .load::<JsonPayloadRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .filter_map(|row| row.payload.map(serde_json::Value::from))
        .collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;
    let spec = entity_spec(&plan.entity)?;
    let mut params = Vec::new();
    let mut predicates = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        let start_ref = push_param(&mut params, BindParam::timestamptz(*start));
        let end_ref = push_param(&mut params, BindParam::timestamptz(*end));
        predicates.push(format!(
            "t.observed_at >= {start_ref} AND t.observed_at <= {end_ref}"
        ));
    }

    for filter in &plan.filters {
        predicates.push(filter_predicate(&plan.entity, filter, &mut params)?);
    }

    let where_sql = if predicates.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", predicates.join(" AND "))
    };

    let order_sql = order_sql(&plan.entity, &plan.order, spec.default_order)?;
    let limit_ref = push_param(&mut params, BindParam::Int(plan.limit));
    let offset_ref = push_param(&mut params, BindParam::Int(plan.offset));

    let sql = format!(
        "SELECT to_jsonb(t) || {payload_extra} AS payload FROM {table} t {joins}{where_sql} {order_sql} LIMIT {limit_ref} OFFSET {offset_ref}",
        payload_extra = spec.payload_extra,
        table = spec.table,
        joins = spec.joins,
    );

    Ok((sql, params))
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    if is_virtualization_entity(&plan.entity) {
        Ok(())
    } else {
        Err(ServiceError::InvalidRequest(
            "entity not supported by virtualization query".into(),
        ))
    }
}

fn is_virtualization_entity(entity: &Entity) -> bool {
    matches!(
        entity,
        Entity::VirtualizationClusters
            | Entity::VirtualizationHosts
            | Entity::VirtualizationGuests
            | Entity::VirtualizationDatastores
            | Entity::VirtualizationHostDisks
            | Entity::VirtualizationNetworkInterfaces
            | Entity::VirtualizationStorageSystems
    )
}

fn entity_spec(entity: &Entity) -> Result<EntitySpec> {
    match entity {
        Entity::VirtualizationClusters => Ok(EntitySpec {
            table: "virtualization_clusters",
            joins: "",
            payload_extra: "jsonb_build_object('cluster_name', t.name)",
            default_order: "t.observed_at DESC NULLS LAST, t.name ASC",
        }),
        Entity::VirtualizationHosts => Ok(EntitySpec {
            table: "virtualization_hosts",
            joins: "LEFT JOIN virtualization_clusters c ON c.id = t.cluster_id",
            payload_extra: "jsonb_build_object('cluster_name', c.name, 'node', t.name)",
            default_order: "t.observed_at DESC NULLS LAST, t.name ASC",
        }),
        Entity::VirtualizationGuests => Ok(EntitySpec {
            table: "virtualization_guests",
            joins: "LEFT JOIN virtualization_hosts h ON h.id = t.host_id LEFT JOIN virtualization_clusters c ON c.id = h.cluster_id",
            payload_extra: "jsonb_build_object('host_name', h.name, 'node', h.name, 'cluster_name', c.name)",
            default_order: "t.observed_at DESC NULLS LAST, t.name ASC",
        }),
        Entity::VirtualizationDatastores => Ok(EntitySpec {
            table: "virtualization_datastores",
            joins: "LEFT JOIN virtualization_hosts h ON h.id = t.host_id LEFT JOIN virtualization_clusters c ON c.id = COALESCE(t.cluster_id, h.cluster_id)",
            payload_extra: "jsonb_build_object('host_name', h.name, 'node', h.name, 'cluster_name', c.name, 'storage', t.name)",
            default_order: "t.observed_at DESC NULLS LAST, t.name ASC",
        }),
        Entity::VirtualizationHostDisks => Ok(EntitySpec {
            table: "virtualization_host_disks",
            joins: "LEFT JOIN virtualization_hosts h ON h.id = t.host_id LEFT JOIN virtualization_clusters c ON c.id = h.cluster_id",
            payload_extra: "jsonb_build_object('host_name', h.name, 'node', h.name, 'cluster_name', c.name)",
            default_order: "t.observed_at DESC NULLS LAST, t.path ASC NULLS LAST",
        }),
        Entity::VirtualizationNetworkInterfaces => Ok(EntitySpec {
            table: "virtualization_network_interfaces",
            joins: "LEFT JOIN virtualization_hosts h ON h.id = t.host_id LEFT JOIN virtualization_clusters c ON c.id = h.cluster_id LEFT JOIN virtualization_guests g ON g.id = t.guest_id",
            payload_extra: "jsonb_build_object('host_name', h.name, 'node', h.name, 'cluster_name', c.name, 'guest_name', g.name, 'guest_type', g.guest_type)",
            default_order: "t.observed_at DESC NULLS LAST, t.name ASC",
        }),
        Entity::VirtualizationStorageSystems => Ok(EntitySpec {
            table: "virtualization_storage_systems",
            joins: "LEFT JOIN virtualization_hosts h ON h.id = t.host_id LEFT JOIN virtualization_clusters c ON c.id = COALESCE(t.cluster_id, h.cluster_id)",
            payload_extra: "jsonb_build_object('host_name', h.name, 'node', h.name, 'cluster_name', c.name, 'ceph_health', t.health)",
            default_order: "t.observed_at DESC NULLS LAST, t.name ASC",
        }),
        _ => Err(ServiceError::InvalidRequest(
            "unsupported virtualization entity".into(),
        )),
    }
}

fn filter_predicate(
    entity: &Entity,
    filter: &Filter,
    params: &mut Vec<BindParam>,
) -> Result<String> {
    let field = filter.field.trim().to_ascii_lowercase();

    match field.as_str() {
        "id" => text_filter(filter, "t.id::text", params),
        "cluster_id" => match entity {
            Entity::VirtualizationHosts
            | Entity::VirtualizationDatastores
            | Entity::VirtualizationStorageSystems => {
                text_filter(filter, "t.cluster_id::text", params)
            }
            _ => unsupported_field(entity, &field),
        },
        "host_id" => match entity {
            Entity::VirtualizationGuests
            | Entity::VirtualizationDatastores
            | Entity::VirtualizationHostDisks
            | Entity::VirtualizationNetworkInterfaces
            | Entity::VirtualizationStorageSystems => {
                text_filter(filter, "t.host_id::text", params)
            }
            _ => unsupported_field(entity, &field),
        },
        "guest_id" => match entity {
            Entity::VirtualizationNetworkInterfaces => {
                text_filter(filter, "t.guest_id::text", params)
            }
            _ => unsupported_field(entity, &field),
        },
        "provider" => text_filter(filter, "t.provider", params),
        "provider_ref" => text_filter(filter, "t.provider_ref", params),
        "guest_provider_ref" => match entity {
            Entity::VirtualizationNetworkInterfaces => {
                text_filter(filter, "t.guest_provider_ref", params)
            }
            _ => unsupported_field(entity, &field),
        },
        "name" => text_filter(filter, "t.name", params),
        "status" => text_filter(filter, "t.status", params),
        "device_uid" | "device_id" | "uid" => text_filter(filter, "t.device_uid", params),
        "observed_at" | "freshness" | "last_enriched" | "enrichment_freshness" => {
            timestamp_filter(filter, "t.observed_at", params)
        }
        "cluster" | "cluster_name" => match entity {
            Entity::VirtualizationClusters => text_filter(filter, "t.name", params),
            _ => text_filter(filter, "c.name", params),
        },
        "node" | "host" | "host_name" => match entity {
            Entity::VirtualizationHosts => text_filter(filter, "t.name", params),
            Entity::VirtualizationClusters => unsupported_field(entity, &field),
            _ => text_filter(filter, "h.name", params),
        },
        "guest" | "guest_name" => match entity {
            Entity::VirtualizationNetworkInterfaces => text_filter(filter, "g.name", params),
            _ => unsupported_field(entity, &field),
        },
        "version" => match entity {
            Entity::VirtualizationClusters | Entity::VirtualizationHosts => {
                text_filter(filter, "t.version", params)
            }
            _ => unsupported_field(entity, &field),
        },
        "guest_type" => match entity {
            Entity::VirtualizationGuests => text_filter(filter, "t.guest_type", params),
            _ => unsupported_field(entity, &field),
        },
        "vmid" => match entity {
            Entity::VirtualizationGuests => int_filter(filter, "t.vmid", params),
            _ => unsupported_field(entity, &field),
        },
        "storage" | "datastore" | "storage_name" => match entity {
            Entity::VirtualizationDatastores => text_filter(filter, "t.name", params),
            _ => unsupported_field(entity, &field),
        },
        "storage_type" => match entity {
            Entity::VirtualizationDatastores => text_filter(filter, "t.storage_type", params),
            _ => unsupported_field(entity, &field),
        },
        "storage_system_type" => match entity {
            Entity::VirtualizationStorageSystems => {
                text_filter(filter, "t.storage_system_type", params)
            }
            _ => unsupported_field(entity, &field),
        },
        "ceph_health" | "health" => match entity {
            Entity::VirtualizationStorageSystems => text_filter(filter, "t.health", params),
            Entity::VirtualizationHostDisks => text_filter(filter, "t.health", params),
            _ => unsupported_field(entity, &field),
        },
        "path" => match entity {
            Entity::VirtualizationHostDisks => text_filter(filter, "t.path", params),
            _ => unsupported_field(entity, &field),
        },
        "interface" | "iface" => match entity {
            Entity::VirtualizationNetworkInterfaces => text_filter(filter, "t.name", params),
            _ => unsupported_field(entity, &field),
        },
        "interface_type" => match entity {
            Entity::VirtualizationNetworkInterfaces => {
                text_filter(filter, "t.interface_type", params)
            }
            _ => unsupported_field(entity, &field),
        },
        "mac" | "mac_address" => match entity {
            Entity::VirtualizationNetworkInterfaces => text_filter(filter, "t.mac_address", params),
            _ => unsupported_field(entity, &field),
        },
        "ip" | "ip_address" => match entity {
            Entity::VirtualizationNetworkInterfaces => ip_addresses_filter(filter, params),
            _ => unsupported_field(entity, &field),
        },
        "source" => match entity {
            Entity::VirtualizationNetworkInterfaces => text_filter(filter, "t.source", params),
            _ => unsupported_field(entity, &field),
        },
        "active" => match entity {
            Entity::VirtualizationDatastores | Entity::VirtualizationNetworkInterfaces => {
                bool_filter(filter, "t.active", params)
            }
            _ => unsupported_field(entity, &field),
        },
        "enabled" | "shared" => match entity {
            Entity::VirtualizationDatastores => bool_filter(filter, &format!("t.{field}"), params),
            _ => unsupported_field(entity, &field),
        },
        "exists" => match entity {
            Entity::VirtualizationNetworkInterfaces => bool_filter(filter, "t.exists", params),
            _ => unsupported_field(entity, &field),
        },
        "used_bytes" | "available_bytes" | "total_bytes" => match entity {
            Entity::VirtualizationDatastores => int_filter(filter, &format!("t.{field}"), params),
            _ => unsupported_field(entity, &field),
        },
        "size_bytes" | "wearout" => match entity {
            Entity::VirtualizationHostDisks => int_filter(filter, &format!("t.{field}"), params),
            _ => unsupported_field(entity, &field),
        },
        "uptime_seconds" | "memory_used_bytes" | "memory_total_bytes" | "disk_used_bytes"
        | "disk_total_bytes" => match entity {
            Entity::VirtualizationGuests => int_filter(filter, &format!("t.{field}"), params),
            _ => unsupported_field(entity, &field),
        },
        other => unsupported_field(entity, other),
    }
}

fn ip_addresses_filter(filter: &Filter, params: &mut Vec<BindParam>) -> Result<String> {
    match filter.op {
        FilterOp::Eq => {
            let placeholder = push_param(params, BindParam::Text(filter.value.as_scalar()?.into()));
            Ok(format!("{placeholder} = ANY(t.ip_addresses)"))
        }
        FilterOp::NotEq => {
            let placeholder = push_param(params, BindParam::Text(filter.value.as_scalar()?.into()));
            Ok(format!("NOT ({placeholder} = ANY(t.ip_addresses))"))
        }
        FilterOp::Like => {
            let placeholder = push_param(params, BindParam::Text(filter.value.as_scalar()?.into()));
            Ok(format!(
                "EXISTS (SELECT 1 FROM unnest(t.ip_addresses) AS ip_address WHERE ip_address ILIKE {placeholder})"
            ))
        }
        FilterOp::NotLike => {
            let placeholder = push_param(params, BindParam::Text(filter.value.as_scalar()?.into()));
            Ok(format!(
                "NOT EXISTS (SELECT 1 FROM unnest(t.ip_addresses) AS ip_address WHERE ip_address ILIKE {placeholder})"
            ))
        }
        FilterOp::In => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                Ok("TRUE".into())
            } else {
                let placeholder = push_param(params, BindParam::TextArray(values));
                Ok(format!("t.ip_addresses && {placeholder}"))
            }
        }
        FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                Ok("TRUE".into())
            } else {
                let placeholder = push_param(params, BindParam::TextArray(values));
                Ok(format!("NOT (t.ip_addresses && {placeholder})"))
            }
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for ip address filter: {:?}",
            filter.op
        ))),
    }
}

fn text_filter(filter: &Filter, column: &str, params: &mut Vec<BindParam>) -> Result<String> {
    match filter.op {
        FilterOp::Eq => {
            let placeholder = push_param(params, BindParam::Text(filter.value.as_scalar()?.into()));
            Ok(format!("{column} = {placeholder}"))
        }
        FilterOp::NotEq => {
            let placeholder = push_param(params, BindParam::Text(filter.value.as_scalar()?.into()));
            Ok(format!("{column} <> {placeholder}"))
        }
        FilterOp::Like => {
            let placeholder = push_param(params, BindParam::Text(filter.value.as_scalar()?.into()));
            Ok(format!("{column} ILIKE {placeholder}"))
        }
        FilterOp::NotLike => {
            let placeholder = push_param(params, BindParam::Text(filter.value.as_scalar()?.into()));
            Ok(format!("{column} NOT ILIKE {placeholder}"))
        }
        FilterOp::In => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                Ok("TRUE".into())
            } else {
                let placeholder = push_param(params, BindParam::TextArray(values));
                Ok(format!("{column} = ANY({placeholder})"))
            }
        }
        FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                Ok("TRUE".into())
            } else {
                let placeholder = push_param(params, BindParam::TextArray(values));
                Ok(format!("{column} <> ALL({placeholder})"))
            }
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for text filter: {:?}",
            filter.op
        ))),
    }
}

fn int_filter(filter: &Filter, column: &str, params: &mut Vec<BindParam>) -> Result<String> {
    match filter.op {
        FilterOp::Eq
        | FilterOp::NotEq
        | FilterOp::Gt
        | FilterOp::Gte
        | FilterOp::Lt
        | FilterOp::Lte => {
            let value = parse_i64(filter.value.as_scalar()?)?;
            let placeholder = push_param(params, BindParam::Int(value));
            Ok(format!(
                "{column} {} {placeholder}",
                numeric_operator(filter.op.clone())?
            ))
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = parse_i64_list(&filter.value)?;
            if values.is_empty() {
                Ok("TRUE".into())
            } else {
                let placeholder = push_param(params, BindParam::IntArray(values));
                let op = if matches!(filter.op, FilterOp::In) {
                    "= ANY"
                } else {
                    "<> ALL"
                };
                Ok(format!("{column} {op}({placeholder})"))
            }
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for integer filter: {:?}",
            filter.op
        ))),
    }
}

fn bool_filter(filter: &Filter, column: &str, params: &mut Vec<BindParam>) -> Result<String> {
    let value = parse_bool(filter.value.as_scalar()?)?;
    let placeholder = push_param(params, BindParam::Bool(value));

    match filter.op {
        FilterOp::Eq => Ok(format!("{column} = {placeholder}")),
        FilterOp::NotEq => Ok(format!("{column} <> {placeholder}")),
        _ => Err(ServiceError::InvalidRequest(
            "boolean filters only support equality".into(),
        )),
    }
}

fn timestamp_filter(filter: &Filter, column: &str, params: &mut Vec<BindParam>) -> Result<String> {
    let value = filter.value.as_scalar()?.to_string();
    let placeholder = push_param(params, BindParam::Timestamptz(value));

    match filter.op {
        FilterOp::Eq
        | FilterOp::NotEq
        | FilterOp::Gt
        | FilterOp::Gte
        | FilterOp::Lt
        | FilterOp::Lte => Ok(format!(
            "{column} {} {placeholder}",
            numeric_operator(filter.op.clone())?
        )),
        _ => Err(ServiceError::InvalidRequest(
            "timestamp filters only support scalar comparison".into(),
        )),
    }
}

fn numeric_operator(op: FilterOp) -> Result<&'static str> {
    match op {
        FilterOp::Eq => Ok("="),
        FilterOp::NotEq => Ok("<>"),
        FilterOp::Gt => Ok(">"),
        FilterOp::Gte => Ok(">="),
        FilterOp::Lt => Ok("<"),
        FilterOp::Lte => Ok("<="),
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported comparison operator: {op:?}"
        ))),
    }
}

fn order_sql(entity: &Entity, order: &[OrderClause], fallback: &str) -> Result<String> {
    if order.is_empty() {
        return Ok(format!("ORDER BY {fallback}"));
    }

    let mut parts = Vec::with_capacity(order.len());
    for clause in order {
        let column = order_column(entity, &clause.field)?;
        let direction = match clause.direction {
            OrderDirection::Asc => "ASC",
            OrderDirection::Desc => "DESC",
        };
        parts.push(format!("{column} {direction} NULLS LAST"));
    }

    Ok(format!("ORDER BY {}", parts.join(", ")))
}

fn order_column(entity: &Entity, field: &str) -> Result<&'static str> {
    let normalized = field.trim().to_ascii_lowercase();

    match normalized.as_str() {
        "provider" => Ok("t.provider"),
        "provider_ref" => Ok("t.provider_ref"),
        "name" => Ok("t.name"),
        "status" => Ok("t.status"),
        "observed_at" | "freshness" | "last_enriched" | "enrichment_freshness" => {
            Ok("t.observed_at")
        }
        "cluster" | "cluster_name" => match entity {
            Entity::VirtualizationClusters => Ok("t.name"),
            _ => Ok("c.name"),
        },
        "node" | "host" | "host_name" => match entity {
            Entity::VirtualizationHosts => Ok("t.name"),
            Entity::VirtualizationClusters => unsupported_order_field(entity, &normalized),
            _ => Ok("h.name"),
        },
        "vmid" => match entity {
            Entity::VirtualizationGuests => Ok("t.vmid"),
            _ => unsupported_order_field(entity, &normalized),
        },
        "guest_type" => match entity {
            Entity::VirtualizationGuests => Ok("t.guest_type"),
            _ => unsupported_order_field(entity, &normalized),
        },
        "storage" | "datastore" | "storage_name" => match entity {
            Entity::VirtualizationDatastores => Ok("t.name"),
            _ => unsupported_order_field(entity, &normalized),
        },
        "health" | "ceph_health" => match entity {
            Entity::VirtualizationStorageSystems | Entity::VirtualizationHostDisks => {
                Ok("t.health")
            }
            _ => unsupported_order_field(entity, &normalized),
        },
        "used_bytes" | "total_bytes" => match entity {
            Entity::VirtualizationDatastores => Ok(match normalized.as_str() {
                "used_bytes" => "t.used_bytes",
                _ => "t.total_bytes",
            }),
            _ => unsupported_order_field(entity, &normalized),
        },
        "size_bytes" => match entity {
            Entity::VirtualizationHostDisks => Ok("t.size_bytes"),
            _ => unsupported_order_field(entity, &normalized),
        },
        "path" => match entity {
            Entity::VirtualizationHostDisks => Ok("t.path"),
            _ => unsupported_order_field(entity, &normalized),
        },
        other => unsupported_order_field(entity, other),
    }
}

fn unsupported_field<T>(entity: &Entity, field: &str) -> Result<T> {
    Err(ServiceError::InvalidRequest(format!(
        "unsupported filter field for {}: '{field}'",
        entity_name(entity)
    )))
}

fn unsupported_order_field<T>(entity: &Entity, field: &str) -> Result<T> {
    Err(ServiceError::InvalidRequest(format!(
        "unsupported sort field for {}: '{field}'",
        entity_name(entity)
    )))
}

fn entity_name(entity: &Entity) -> &'static str {
    match entity {
        Entity::VirtualizationClusters => "virtualization_clusters",
        Entity::VirtualizationHosts => "virtualization_hosts",
        Entity::VirtualizationGuests => "virtualization_guests",
        Entity::VirtualizationDatastores => "virtualization_datastores",
        Entity::VirtualizationHostDisks => "virtualization_host_disks",
        Entity::VirtualizationNetworkInterfaces => "virtualization_network_interfaces",
        Entity::VirtualizationStorageSystems => "virtualization_storage_systems",
        _ => "virtualization",
    }
}

fn push_param(params: &mut Vec<BindParam>, param: BindParam) -> String {
    params.push(param);
    format!("${}", params.len())
}

fn parse_i64(raw: &str) -> Result<i64> {
    raw.parse::<i64>()
        .map_err(|_| ServiceError::InvalidRequest(format!("expected integer value, got '{raw}'")))
}

fn parse_i64_list(value: &FilterValue) -> Result<Vec<i64>> {
    value
        .as_list()?
        .iter()
        .map(|item| parse_i64(item))
        .collect()
}

fn parse_bool(raw: &str) -> Result<bool> {
    match raw.to_ascii_lowercase().as_str() {
        "true" | "1" | "yes" | "y" => Ok(true),
        "false" | "0" | "no" | "n" => Ok(false),
        _ => Err(ServiceError::InvalidRequest(format!(
            "invalid boolean value '{raw}'"
        ))),
    }
}

fn bind_param<'a>(
    query: BoxedSqlQuery<'a, Pg, SqlQuery>,
    param: BindParam,
) -> Result<BoxedSqlQuery<'a, Pg, SqlQuery>> {
    match param {
        BindParam::Text(value) => Ok(query.bind::<Text, _>(value)),
        BindParam::TextArray(values) => Ok(query.bind::<Array<Text>, _>(values)),
        BindParam::IntArray(values) => Ok(query.bind::<Array<BigInt>, _>(values)),
        BindParam::Bool(value) => Ok(query.bind::<Bool, _>(value)),
        BindParam::Int(value) => Ok(query.bind::<BigInt, _>(value)),
        BindParam::Float(value) => Ok(query.bind::<Float8, _>(value)),
        BindParam::Timestamptz(value) => {
            let timestamp = chrono::DateTime::parse_from_rfc3339(&value)
                .map(|dt| dt.with_timezone(&chrono::Utc))
                .map_err(|err| {
                    ServiceError::InvalidRequest(format!(
                        "invalid timestamp filter value {value:?}: {err}"
                    ))
                })?;
            Ok(query.bind::<Timestamptz, _>(timestamp))
        }
        BindParam::Uuid(value) => Ok(query.bind::<diesel::sql_types::Uuid, _>(value)),
        BindParam::Date(_) => Err(ServiceError::InvalidRequest(
            "unsupported bind type for virtualization".into(),
        )),
    }
}
