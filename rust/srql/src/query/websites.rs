//! SRQL for L7 web property inventory (`platform.web_properties`).

use super::{BindParam, QueryPlan, bind_sql_param, reject_stats, rewrite_placeholders};
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

const PAYLOAD_SQL: &str = "jsonb_build_object(\
     'id', wp.id, \
     'name', wp.name, \
     'canonical_origin', wp.canonical_origin, \
     'allowed_origins', wp.allowed_origins, \
     'allowed_query_keys', wp.allowed_query_keys, \
     'trace_propagate_origins', wp.trace_propagate_origins, \
     'environment', wp.environment, \
     'tags', wp.tags, \
     'prefix_tags', wp.prefix_tags, \
     'rum_enabled', wp.rum_enabled, \
     'rum_site_key', wp.rum_site_key, \
     'rum_sample_rate', wp.rum_sample_rate, \
     'anonymize_client_ip', wp.anonymize_client_ip, \
     'edge_provider', wp.edge_provider, \
     'observed_vips', wp.observed_vips, \
     'observed_asns', wp.observed_asns, \
     'tls_not_after', wp.tls_not_after, \
     'tls_issuer', wp.tls_issuer, \
     'last_posture_checked_at', wp.last_posture_checked_at, \
     'created_at', wp.created_at, \
     'updated_at', wp.updated_at, \
     'binding_count', (SELECT count(*) FROM platform.web_property_bindings AS b WHERE b.web_property_id = wp.id)\
 )";

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;
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

#[derive(Clone, Copy)]
enum FieldKind {
    Text,
    Bool,
    TextArray,
    Timestamptz,
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    if !matches!(plan.entity, Entity::Websites) {
        return Err(ServiceError::InvalidRequest(
            "entity not supported by websites query".into(),
        ));
    }
    reject_stats(plan, "websites")?;
    Ok(())
}

fn build_sql(plan: &QueryPlan) -> Result<BuiltSql> {
    let mut where_parts = Vec::new();
    let mut binds = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        where_parts.push("wp.updated_at >= ? AND wp.updated_at <= ?".to_string());
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
             FROM platform.web_properties AS wp\
             {where_sql}{} LIMIT ? OFFSET ?",
            order_sql(&plan.order)?
        ),
        binds,
    })
}

fn filter_condition(filter: &Filter, binds: &mut Vec<BindParam>) -> Result<String> {
    if matches!(filter.field.as_str(), "tag" | "tags") {
        return tag_key_condition(filter, binds);
    }

    if let Some(tag_key) = filter.field.strip_prefix("tags.") {
        return tag_entry_condition(tag_key, filter, binds);
    }

    let (field_sql, kind) = field_spec(filter.field.as_str()).ok_or_else(|| {
        ServiceError::InvalidRequest(format!(
            "unsupported filter field for websites: '{}'",
            filter.field
        ))
    })?;

    match kind {
        FieldKind::Text => text_condition(field_sql, filter, binds),
        FieldKind::Bool => bool_condition(field_sql, filter, binds),
        FieldKind::TextArray => text_array_condition(field_sql, filter, binds),
        FieldKind::Timestamptz => timestamptz_condition(field_sql, filter, binds),
    }
}

fn field_spec(field: &str) -> Option<(&'static str, FieldKind)> {
    match field {
        "id" => Some(("wp.id::text", FieldKind::Text)),
        "name" => Some(("wp.name", FieldKind::Text)),
        "canonical_origin" | "origin" => Some(("wp.canonical_origin", FieldKind::Text)),
        "environment" | "env" => Some(("wp.environment", FieldKind::Text)),
        "edge_provider" | "provider" => Some(("wp.edge_provider", FieldKind::Text)),
        "tls_issuer" => Some(("wp.tls_issuer", FieldKind::Text)),
        "rum_enabled" => Some(("wp.rum_enabled", FieldKind::Bool)),
        "anonymize_client_ip" => Some(("wp.anonymize_client_ip", FieldKind::Bool)),
        "allowed_origins" | "allowed_origin" => Some(("wp.allowed_origins", FieldKind::TextArray)),
        "observed_vips" | "vip" => Some(("wp.observed_vips", FieldKind::TextArray)),
        "tls_not_after" => Some(("wp.tls_not_after", FieldKind::Timestamptz)),
        "last_posture_checked_at" => Some(("wp.last_posture_checked_at", FieldKind::Timestamptz)),
        "created_at" => Some(("wp.created_at", FieldKind::Timestamptz)),
        "updated_at" | "time" => Some(("wp.updated_at", FieldKind::Timestamptz)),
        _ => None,
    }
}

fn tag_key_condition(filter: &Filter, binds: &mut Vec<BindParam>) -> Result<String> {
    match filter.op {
        FilterOp::Eq => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok("jsonb_exists(wp.tags, ?)".to_string())
        }
        FilterOp::NotEq => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok("NOT jsonb_exists(wp.tags, ?)".to_string())
        }
        FilterOp::In => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                Ok("TRUE".into())
            } else {
                binds.push(BindParam::TextArray(values));
                Ok("jsonb_exists_any(wp.tags, ?)".to_string())
            }
        }
        FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                Ok("TRUE".into())
            } else {
                binds.push(BindParam::TextArray(values));
                Ok("NOT jsonb_exists_any(wp.tags, ?)".to_string())
            }
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for websites tag filter: {:?}",
            filter.op
        ))),
    }
}

fn tag_entry_condition(
    tag_key: &str,
    filter: &Filter,
    binds: &mut Vec<BindParam>,
) -> Result<String> {
    if tag_key.trim().is_empty() {
        return Err(ServiceError::InvalidRequest(
            "websites tag key cannot be empty".into(),
        ));
    }

    match filter.op {
        FilterOp::Eq => {
            binds.push(BindParam::Text(tag_key.to_string()));
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok("wp.tags ->> ? = ?".to_string())
        }
        FilterOp::NotEq => {
            binds.push(BindParam::Text(tag_key.to_string()));
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok("(wp.tags ->> ?) IS DISTINCT FROM ?".to_string())
        }
        FilterOp::Like => {
            binds.push(BindParam::Text(tag_key.to_string()));
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok("wp.tags ->> ? ILIKE ?".to_string())
        }
        FilterOp::NotLike => {
            binds.push(BindParam::Text(tag_key.to_string()));
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok("COALESCE(wp.tags ->> ?, '') NOT ILIKE ?".to_string())
        }
        FilterOp::In => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                Ok("TRUE".into())
            } else {
                binds.push(BindParam::Text(tag_key.to_string()));
                binds.push(BindParam::TextArray(values));
                Ok("wp.tags ->> ? = ANY(?)".to_string())
            }
        }
        FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                Ok("TRUE".into())
            } else {
                binds.push(BindParam::Text(tag_key.to_string()));
                binds.push(BindParam::TextArray(values));
                Ok("NOT (COALESCE(wp.tags ->> ?, '') = ANY(?))".to_string())
            }
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for websites tags.{} filter: {:?}",
            tag_key, filter.op
        ))),
    }
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
        FilterOp::NotLike => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("COALESCE({field_sql}, '') NOT ILIKE ?"))
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
        FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                Ok("TRUE".into())
            } else {
                binds.push(BindParam::TextArray(values));
                Ok(format!("NOT (COALESCE({field_sql}, '') = ANY(?))"))
            }
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for websites text filter: {:?}",
            filter.op
        ))),
    }
}

fn bool_condition(field_sql: &str, filter: &Filter, binds: &mut Vec<BindParam>) -> Result<String> {
    let raw = filter.value.as_scalar()?.to_ascii_lowercase();
    let parsed = match raw.as_str() {
        "true" | "1" | "yes" => true,
        "false" | "0" | "no" => false,
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "websites '{}' expects true or false, got '{other}'",
                filter.field
            )));
        }
    };

    let op = match filter.op {
        FilterOp::Eq => "=",
        FilterOp::NotEq => "<>",
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported operator for websites boolean filter: {:?}",
                filter.op
            )));
        }
    };

    binds.push(BindParam::Bool(parsed));
    Ok(format!("{field_sql} {op} ?"))
}

fn text_array_condition(
    field_sql: &str,
    filter: &Filter,
    binds: &mut Vec<BindParam>,
) -> Result<String> {
    match filter.op {
        FilterOp::Eq => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("? = ANY({field_sql})"))
        }
        FilterOp::NotEq => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("NOT (? = ANY({field_sql}))"))
        }
        FilterOp::Like => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!(
                "EXISTS (SELECT 1 FROM unnest({field_sql}) AS item WHERE item ILIKE ?)"
            ))
        }
        FilterOp::NotLike => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!(
                "NOT EXISTS (SELECT 1 FROM unnest({field_sql}) AS item WHERE item ILIKE ?)"
            ))
        }
        FilterOp::In => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                Ok("TRUE".into())
            } else {
                binds.push(BindParam::TextArray(values));
                Ok(format!("{field_sql} && ?"))
            }
        }
        FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                Ok("TRUE".into())
            } else {
                binds.push(BindParam::TextArray(values));
                Ok(format!("NOT ({field_sql} && ?)"))
            }
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for websites array filter: {:?}",
            filter.op
        ))),
    }
}

fn timestamptz_condition(
    field_sql: &str,
    filter: &Filter,
    binds: &mut Vec<BindParam>,
) -> Result<String> {
    let operator = match filter.op {
        FilterOp::Eq => "=",
        FilterOp::NotEq => "<>",
        FilterOp::Gt => ">",
        FilterOp::Gte => ">=",
        FilterOp::Lt => "<",
        FilterOp::Lte => "<=",
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported operator for websites timestamp filter: {:?}",
                filter.op
            )));
        }
    };

    let raw = filter.value.as_scalar()?;
    let dt = chrono::DateTime::parse_from_rfc3339(raw)
        .map(|parsed| parsed.with_timezone(&chrono::Utc))
        .map_err(|_| {
            ServiceError::InvalidRequest(format!(
                "websites '{}' expects RFC3339 timestamp, got '{raw}'",
                filter.field
            ))
        })?;

    binds.push(BindParam::timestamptz(dt));
    Ok(format!("{field_sql} {operator} ?"))
}

fn order_sql(order: &[OrderClause]) -> Result<String> {
    if order.is_empty() {
        return Ok(" ORDER BY wp.name ASC NULLS LAST, wp.id ASC".into());
    }
    let clauses = order
        .iter()
        .map(|clause| {
            let column = order_column(clause.field.as_str()).ok_or_else(|| {
                ServiceError::InvalidRequest(format!(
                    "unsupported sort field for websites: '{}'",
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
        "name" => Some("wp.name"),
        "canonical_origin" | "origin" => Some("wp.canonical_origin"),
        "environment" | "env" => Some("wp.environment"),
        "edge_provider" | "provider" => Some("wp.edge_provider"),
        "rum_enabled" => Some("wp.rum_enabled"),
        "tls_not_after" => Some("wp.tls_not_after"),
        "last_posture_checked_at" => Some("wp.last_posture_checked_at"),
        "created_at" => Some("wp.created_at"),
        "updated_at" | "time" => Some("wp.updated_at"),
        _ => None,
    }
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
        let ast = parser::parse(query).expect("parse websites query");
        build_query_plan(
            &AppConfig::embedded("postgres://srql-test".to_string()),
            &request,
            ast,
        )
        .expect("build websites plan")
    }

    #[test]
    fn translates_websites_and_web_properties_aliases() {
        for entity in ["websites", "website", "web_properties", "web_property"] {
            let (sql, binds) = to_sql_and_params(&plan(&format!(
                "in:{entity} environment:production rum_enabled:true limit:10"
            )))
            .expect("sql");
            assert!(sql.contains("platform.web_properties AS wp"), "{sql}");
            assert!(sql.contains("wp.environment = $1"), "{sql}");
            assert!(sql.contains("wp.rum_enabled = $2"), "{sql}");
            assert!(sql.contains("LIMIT $3 OFFSET $4"), "{sql}");
            assert!(!sql.contains('?'), "{sql}");
            assert_eq!(binds.len(), 4);
        }
    }

    #[test]
    fn projects_all_expected_columns() {
        let (sql, _) = to_sql_and_params(&plan("in:websites limit:5")).expect("sql");
        for col in [
            "'id', wp.id",
            "'name', wp.name",
            "'canonical_origin', wp.canonical_origin",
            "'allowed_origins', wp.allowed_origins",
            "'allowed_query_keys', wp.allowed_query_keys",
            "'trace_propagate_origins', wp.trace_propagate_origins",
            "'environment', wp.environment",
            "'tags', wp.tags",
            "'prefix_tags', wp.prefix_tags",
            "'rum_enabled', wp.rum_enabled",
            "'rum_site_key', wp.rum_site_key",
            "'rum_sample_rate', wp.rum_sample_rate",
            "'anonymize_client_ip', wp.anonymize_client_ip",
            "'edge_provider', wp.edge_provider",
            "'observed_vips', wp.observed_vips",
            "'observed_asns', wp.observed_asns",
            "'tls_not_after', wp.tls_not_after",
            "'tls_issuer', wp.tls_issuer",
            "'last_posture_checked_at', wp.last_posture_checked_at",
            "'created_at', wp.created_at",
            "'updated_at', wp.updated_at",
            "'binding_count'",
        ] {
            assert!(sql.contains(col), "missing {col} in {sql}");
        }
    }

    #[test]
    fn supports_tags_and_implicit_like_without_bare_question_marks() {
        let (sql, binds) = to_sql_and_params(&plan(
            "in:websites canonical_origin:%example.com% tag:tier tags.team:edge observed_vips:203.0.113.10 limit:5",
        ))
        .expect("sql");
        assert!(sql.contains("wp.canonical_origin ILIKE $1"), "{sql}");
        assert!(sql.contains("jsonb_exists(wp.tags, $2)"), "{sql}");
        assert!(sql.contains("wp.tags ->> $3 = $4"), "{sql}");
        assert!(sql.contains("$5 = ANY(wp.observed_vips)"), "{sql}");
        assert!(!sql.contains('?'), "{sql}");
        assert_eq!(binds.len(), 7);
    }

    #[test]
    fn supports_like_and_not_like_on_allowed_origins_array() {
        let (sql, binds) = to_sql_and_params(&plan(
            "in:websites allowed_origins:%example.com% !allowed_origins:%internal.test% limit:5",
        ))
        .expect("sql");
        assert!(
            sql.contains(
                "EXISTS (SELECT 1 FROM unnest(wp.allowed_origins) AS item WHERE item ILIKE $1)"
            ),
            "{sql}"
        );
        assert!(
            sql.contains(
                "NOT EXISTS (SELECT 1 FROM unnest(wp.allowed_origins) AS item WHERE item ILIKE $2)"
            ),
            "{sql}"
        );
        assert!(sql.contains("LIMIT $3 OFFSET $4"), "{sql}");
        assert!(!sql.contains('?'), "{sql}");
        assert_eq!(binds.len(), 4);
    }

    #[test]
    fn rejects_unknown_fields_and_stats() {
        assert!(to_sql_and_params(&plan("in:websites bogus_field:x limit:5")).is_err());
        assert!(to_sql_and_params(&plan("in:websites stats:count() limit:5")).is_err());
    }
}
