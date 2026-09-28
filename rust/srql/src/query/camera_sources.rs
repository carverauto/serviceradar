//! SRQL for camera inventory (`platform.camera_sources` + `platform.camera_stream_profiles`).
//!
//! Dashboards discover cameras here before opening a relay viewer session through
//! the host camera API. Each row carries the camera's owning device, availability
//! and the relay-eligible stream profiles a viewer can open.
//!
//! Source URLs, per-profile URL overrides and free-form metadata are never
//! selected: RTSP URLs routinely embed device credentials, and the relay opens
//! the upstream stream on the agent, so a viewer never needs them.

use super::{BindParam, QueryPlan, bind_sql_param};
use crate::{
    error::{Result, ServiceError},
    jsonb::DbJson,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    time::TimeRange,
};
use diesel::deserialize::QueryableByName;
use diesel::pg::Pg;
use diesel::query_builder::{BoxedSqlQuery, SqlQuery};
use diesel::sql_query;
use diesel::sql_types::Jsonb;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

#[derive(Debug, QueryableByName)]
#[diesel(check_for_backend(diesel::pg::Pg))]
struct JsonPayload {
    #[diesel(sql_type = Jsonb)]
    payload: DbJson,
}

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;
    // Execute exactly the SQL `to_sql_and_params` returns; see public_endpoints.rs
    // for why a second `?`-form build must never reach Diesel.
    let query = execution_query(plan)?;

    let rows: Vec<JsonPayload> = query
        .load::<JsonPayload>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .map(|row| serde_json::Value::from(row.payload))
        .collect())
}

pub(super) fn execution_query(plan: &QueryPlan) -> Result<BoxedSqlQuery<'static, Pg, SqlQuery>> {
    let (sql, binds) = to_sql_and_params(plan)?;
    let mut query = sql_query(sql).into_boxed::<Pg>();

    for bind in binds {
        query = bind_sql_param(query, bind)?;
    }

    Ok(query)
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;
    let built = build_sql(plan)?;
    Ok((rewrite_placeholders(&built.sql), built.binds))
}

struct BuiltSql {
    sql: String,
    binds: Vec<BindParam>,
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    if !matches!(plan.entity, Entity::CameraSources) {
        return Err(ServiceError::InvalidRequest(
            "entity not supported by camera_sources query".into(),
        ));
    }
    if plan.stats.is_some() {
        return Err(ServiceError::InvalidRequest(
            "camera_sources does not support stats queries".into(),
        ));
    }
    Ok(())
}

const PAYLOAD_SQL: &str = "jsonb_build_object(\
     'id', cs.id, \
     'device_uid', cs.device_uid, \
     'vendor', cs.vendor, \
     'vendor_camera_id', cs.vendor_camera_id, \
     'display_name', cs.display_name, \
     'assigned_agent_id', cs.assigned_agent_id, \
     'assigned_gateway_id', cs.assigned_gateway_id, \
     'availability_status', cs.availability_status, \
     'availability_reason', cs.availability_reason, \
     'last_activity_at', cs.last_activity_at, \
     'last_event_at', cs.last_event_at, \
     'last_event_type', cs.last_event_type, \
     'inserted_at', cs.inserted_at, \
     'updated_at', cs.updated_at, \
     'stream_profiles', COALESCE((\
         SELECT jsonb_agg(jsonb_build_object(\
             'id', sp.id, \
             'profile_name', sp.profile_name, \
             'vendor_profile_id', sp.vendor_profile_id, \
             'codec_hint', sp.codec_hint, \
             'container_hint', sp.container_hint, \
             'rtsp_transport', sp.rtsp_transport, \
             'last_seen_at', sp.last_seen_at\
         ) ORDER BY sp.profile_name) \
         FROM platform.camera_stream_profiles AS sp \
         WHERE sp.camera_source_id = cs.id AND sp.relay_eligible\
     ), '[]'::jsonb)\
 )";

fn build_sql(plan: &QueryPlan) -> Result<BuiltSql> {
    let mut where_parts = Vec::new();
    let mut binds = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        where_parts.push("cs.updated_at >= ? AND cs.updated_at <= ?".to_string());
        binds.push(BindParam::timestamptz(*start));
        binds.push(BindParam::timestamptz(*end));
    }

    for filter in &plan.filters {
        where_parts.push(filter_condition(filter, &mut binds)?);
    }

    let where_sql = if where_parts.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", where_parts.join(" AND "))
    };
    binds.push(BindParam::Int(plan.limit));
    binds.push(BindParam::Int(plan.offset));

    Ok(BuiltSql {
        sql: format!(
            "SELECT {PAYLOAD_SQL} AS payload \
             FROM platform.camera_sources AS cs\
             {where_sql}{} LIMIT ? OFFSET ?",
            order_sql(&plan.order)?
        ),
        binds,
    })
}

fn filter_condition(filter: &Filter, binds: &mut Vec<BindParam>) -> Result<String> {
    if matches!(
        filter.field.as_str(),
        "relay_eligible" | "viewable" | "has_viewable_profile"
    ) {
        return viewable_condition(filter);
    }

    let field_sql = field_column(filter.field.as_str()).ok_or_else(|| {
        ServiceError::InvalidRequest(format!(
            "unsupported filter field for camera_sources: '{}'",
            filter.field
        ))
    })?;

    text_condition(field_sql, filter, binds)
}

fn field_column(field: &str) -> Option<&'static str> {
    match field {
        "id" | "camera_source_id" => Some("cs.id::text"),
        "device_uid" | "device_id" | "uid" => Some("cs.device_uid"),
        "vendor" => Some("cs.vendor"),
        "vendor_camera_id" | "camera_id" => Some("cs.vendor_camera_id"),
        "display_name" | "name" => Some("cs.display_name"),
        "availability_status" | "availability" | "status" => Some("cs.availability_status"),
        "assigned_agent_id" | "agent_id" => Some("cs.assigned_agent_id"),
        "assigned_gateway_id" | "gateway_id" => Some("cs.assigned_gateway_id"),
        "last_event_type" => Some("cs.last_event_type"),
        _ => None,
    }
}

/// `viewable:true` keeps cameras with at least one relay-eligible profile;
/// `viewable:false` keeps cameras with none.
fn viewable_condition(filter: &Filter) -> Result<String> {
    let exists = "EXISTS (SELECT 1 FROM platform.camera_stream_profiles AS vp \
                  WHERE vp.camera_source_id = cs.id AND vp.relay_eligible)";
    let wanted = match filter.value.as_scalar()?.to_ascii_lowercase().as_str() {
        "true" | "1" | "yes" => true,
        "false" | "0" | "no" => false,
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "camera_sources '{}' expects true or false, got '{other}'",
                filter.field
            )));
        }
    };
    let wanted = match filter.op {
        FilterOp::Eq => wanted,
        FilterOp::NotEq => !wanted,
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported operator for camera_sources '{}' filter: {:?}",
                filter.field, filter.op
            )));
        }
    };
    Ok(if wanted {
        exists.to_string()
    } else {
        format!("NOT {exists}")
    })
}

fn text_condition(field_sql: &str, filter: &Filter, binds: &mut Vec<BindParam>) -> Result<String> {
    match filter.op {
        FilterOp::Eq => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("{field_sql} = ?"))
        }
        FilterOp::NotEq => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("{field_sql} IS DISTINCT FROM ?"))
        }
        FilterOp::Like => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("{field_sql} ILIKE ?"))
        }
        FilterOp::In => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                Ok("TRUE".into())
            } else {
                binds.push(BindParam::TextArray(values));
                Ok(format!("{field_sql} = ANY(?)"))
            }
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for camera_sources text filter: {:?}",
            filter.op
        ))),
    }
}

fn order_sql(order: &[OrderClause]) -> Result<String> {
    if order.is_empty() {
        return Ok(" ORDER BY cs.display_name ASC NULLS LAST, cs.id ASC".into());
    }
    let clauses = order
        .iter()
        .map(|clause| {
            let column = order_column(clause.field.as_str()).ok_or_else(|| {
                ServiceError::InvalidRequest(format!(
                    "unsupported sort field for camera_sources: '{}'",
                    clause.field
                ))
            })?;
            let dir = match clause.direction {
                OrderDirection::Asc => "ASC",
                OrderDirection::Desc => "DESC",
            };
            Ok(format!("{column} {dir}"))
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(format!(" ORDER BY {}", clauses.join(", ")))
}

fn order_column(field: &str) -> Option<&'static str> {
    match field {
        "display_name" | "name" => Some("cs.display_name"),
        "vendor" => Some("cs.vendor"),
        "device_uid" => Some("cs.device_uid"),
        "availability_status" | "availability" | "status" => Some("cs.availability_status"),
        "last_activity_at" => Some("cs.last_activity_at"),
        "last_event_at" => Some("cs.last_event_at"),
        "updated_at" | "time" => Some("cs.updated_at"),
        "inserted_at" => Some("cs.inserted_at"),
        _ => None,
    }
}

fn rewrite_placeholders(sql: &str) -> String {
    let mut out = String::with_capacity(sql.len() + 8);
    let mut idx = 1u32;
    for ch in sql.chars() {
        if ch == '?' {
            out.push('$');
            out.push_str(&idx.to_string());
            idx += 1;
        } else {
            out.push(ch);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        config::AppConfig,
        parser,
        query::{QueryRequest, build_query_plan},
    };

    fn plan(query: &str) -> QueryPlan {
        let request = QueryRequest {
            query: query.to_string(),
            limit: Some(25),
            cursor: None,
            direction: Default::default(),
            mode: None,
            permitted_signals: None,
        };
        let ast = parser::parse(query).expect("parse camera_sources query");
        build_query_plan(
            &AppConfig::embedded("postgres://srql-test".to_string()),
            &request,
            ast,
        )
        .expect("build camera_sources plan")
    }

    #[test]
    fn never_selects_source_urls_or_metadata() {
        let (sql, _) = to_sql_and_params(&plan("in:camera_sources limit:10")).expect("sql");
        assert!(sql.contains("platform.camera_sources"));
        assert!(!sql.contains("source_url"), "{sql}");
        assert!(!sql.contains("metadata"), "{sql}");
        assert!(!sql.contains("to_jsonb(cs)"), "{sql}");
    }

    #[test]
    fn lists_only_relay_eligible_profiles() {
        let (sql, _) = to_sql_and_params(&plan("in:camera_sources limit:10")).expect("sql");
        assert!(
            sql.contains("sp.camera_source_id = cs.id AND sp.relay_eligible"),
            "{sql}"
        );
    }

    #[test]
    fn filters_bind_positionally() {
        let (sql, binds) = to_sql_and_params(&plan(
            "in:camera_sources vendor:ubiquiti availability:available device_uid:(dev-a,dev-b) limit:5",
        ))
        .expect("sql");
        assert!(sql.contains("cs.vendor = $1"), "{sql}");
        assert!(sql.contains("cs.availability_status = $2"), "{sql}");
        assert!(sql.contains("cs.device_uid = ANY($3)"), "{sql}");
        assert!(sql.contains("LIMIT $4 OFFSET $5"), "{sql}");
        assert!(!sql.contains('?'), "{sql}");
        assert_eq!(binds.len(), 5);
    }

    #[test]
    fn viewable_filter_uses_relay_eligible_profiles() {
        let (sql, _) =
            to_sql_and_params(&plan("in:camera_sources viewable:true limit:5")).expect("sql");
        assert!(sql.contains("EXISTS (SELECT 1"), "{sql}");
        let (sql, _) =
            to_sql_and_params(&plan("in:camera_sources viewable:false limit:5")).expect("sql");
        assert!(sql.contains("NOT EXISTS (SELECT 1"), "{sql}");
    }

    #[test]
    fn rejects_unknown_fields_and_stats() {
        assert!(to_sql_and_params(&plan("in:camera_sources source_url:x limit:5")).is_err());
        assert!(to_sql_and_params(&plan("in:camera_sources metadata:x limit:5")).is_err());
    }
}
