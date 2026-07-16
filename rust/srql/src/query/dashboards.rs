use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    jsonb::DbJson,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    time::TimeRange,
};
use chrono::{DateTime, Utc};
use diesel::deserialize::QueryableByName;
use diesel::pg::Pg;
use diesel::query_builder::{BoxedSqlQuery, SqlQuery};
use diesel::sql_query;
use diesel::sql_types::{Array, BigInt, Jsonb, Text, Timestamptz, Uuid};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;
use uuid::Uuid as UuidValue;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;
    let dashboard_query = build_dashboard_query(plan)?;
    let query = dashboard_query.to_boxed_query();

    let rows: Vec<DashboardPayload> = query
        .load::<DashboardPayload>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(|row| row.payload.into()).collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;
    let dashboard_query = build_dashboard_query(plan)?;

    Ok((
        rewrite_placeholders(&dashboard_query.sql),
        dashboard_query
            .binds
            .into_iter()
            .map(BindValue::into_bind_param)
            .collect(),
    ))
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    match plan.entity {
        Entity::Dashboards => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by dashboards query".into(),
        )),
    }
}

#[derive(Debug, Clone)]
struct DashboardSql {
    sql: String,
    binds: Vec<BindValue>,
}

impl DashboardSql {
    fn to_boxed_query(&self) -> BoxedSqlQuery<'_, Pg, SqlQuery> {
        let mut query = sql_query(rewrite_placeholders(&self.sql)).into_boxed::<Pg>();

        for bind in &self.binds {
            query = bind.bind(query);
        }

        query
    }
}

#[derive(Debug, Clone)]
enum BindValue {
    Text(String),
    TextArray(Vec<String>),
    Int(i64),
    Timestamp(DateTime<Utc>),
    Uuid(UuidValue),
}

impl BindValue {
    fn bind<'a>(&self, query: BoxedSqlQuery<'a, Pg, SqlQuery>) -> BoxedSqlQuery<'a, Pg, SqlQuery> {
        match self {
            Self::Text(value) => query.bind::<Text, _>(value.clone()),
            Self::TextArray(values) => query.bind::<Array<Text>, _>(values.clone()),
            Self::Int(value) => query.bind::<BigInt, _>(*value),
            Self::Timestamp(value) => query.bind::<Timestamptz, _>(*value),
            Self::Uuid(value) => query.bind::<Uuid, _>(*value),
        }
    }

    fn into_bind_param(self) -> BindParam {
        match self {
            Self::Text(value) => BindParam::Text(value),
            Self::TextArray(values) => BindParam::TextArray(values),
            Self::Int(value) => BindParam::Int(value),
            Self::Timestamp(value) => BindParam::timestamptz(value),
            Self::Uuid(value) => BindParam::Uuid(value),
        }
    }
}

#[derive(Debug, QueryableByName)]
#[diesel(check_for_backend(diesel::pg::Pg))]
struct DashboardPayload {
    #[diesel(sql_type = Jsonb)]
    payload: DbJson,
}

fn build_dashboard_query(plan: &QueryPlan) -> Result<DashboardSql> {
    let mut sql = String::from(
        r#"SELECT jsonb_build_object(
    'id', d.id::text,
    'title', d.title,
    'description', d.description,
    'slug', d.slug,
    'owner_id', d.owner_id::text,
    'visibility', d.visibility,
    'status', d.status,
    'default_time_range', d.default_time_range,
    'layout', d.layout,
    'variables', d.variables,
    'metadata', d.metadata,
    'panel_count', (
        SELECT count(*)::bigint
        FROM platform.authored_dashboard_panels p
        WHERE p.dashboard_id = d.id
    ),
    'report_schedule_count', (
        SELECT count(*)::bigint
        FROM platform.dashboard_report_schedules s
        WHERE s.dashboard_id = d.id
    ),
    'archived_at', d.archived_at,
    'inserted_at', d.inserted_at,
    'updated_at', d.updated_at
) AS payload
FROM platform.authored_dashboards d"#,
    );

    let mut binds = Vec::new();
    let mut where_clauses = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        where_clauses.push("d.updated_at >= ?".to_string());
        binds.push(BindValue::Timestamp(*start));
        where_clauses.push("d.updated_at <= ?".to_string());
        binds.push(BindValue::Timestamp(*end));
    }

    for filter in &plan.filters {
        let (clause, mut filter_binds) = filter_clause(filter)?;
        where_clauses.push(clause);
        binds.append(&mut filter_binds);
    }

    if !where_clauses.is_empty() {
        sql.push_str("\nWHERE ");
        sql.push_str(&where_clauses.join(" AND "));
    }

    sql.push('\n');
    sql.push_str(&order_clause(&plan.order));
    sql.push_str("\nLIMIT ? OFFSET ?");
    binds.push(BindValue::Int(plan.limit));
    binds.push(BindValue::Int(plan.offset));

    Ok(DashboardSql { sql, binds })
}

fn filter_clause(filter: &Filter) -> Result<(String, Vec<BindValue>)> {
    match filter.field.as_str() {
        "id" | "dashboard_id" => uuid_filter("d.id", filter),
        "owner_id" => uuid_filter("d.owner_id", filter),
        "title" => text_filter("d.title", filter),
        "description" => text_filter("COALESCE(d.description, '')", filter),
        "slug" => text_filter("COALESCE(d.slug, '')", filter),
        "visibility" => text_filter("d.visibility", filter),
        "status" => text_filter("d.status", filter),
        "default_time_range" | "time_range" => text_filter("d.default_time_range", filter),
        "q" | "search" => search_filter(filter),
        "srql_query" | "query" | "panel_query" => panel_query_filter(filter),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for dashboards: '{other}'"
        ))),
    }
}

fn text_filter(column: &str, filter: &Filter) -> Result<(String, Vec<BindValue>)> {
    match filter.op {
        FilterOp::Eq => Ok((format!("{column} = ?"), vec![text_scalar(filter)?])),
        FilterOp::NotEq => Ok((format!("{column} <> ?"), vec![text_scalar(filter)?])),
        FilterOp::Like => Ok((format!("{column} ILIKE ?"), vec![text_scalar(filter)?])),
        FilterOp::NotLike => Ok((format!("{column} NOT ILIKE ?"), vec![text_scalar(filter)?])),
        FilterOp::In => Ok((format!("{column} = ANY(?)"), vec![text_array(filter)?])),
        FilterOp::NotIn => Ok((format!("{column} <> ALL(?)"), vec![text_array(filter)?])),
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for dashboard text filter: {:?}",
            filter.op
        ))),
    }
}

fn uuid_filter(column: &str, filter: &Filter) -> Result<(String, Vec<BindValue>)> {
    let value = filter.value.as_scalar()?;
    let uuid = UuidValue::parse_str(value).map_err(|_| {
        ServiceError::InvalidRequest(format!("{} must be a valid UUID", filter.field))
    })?;

    match filter.op {
        FilterOp::Eq => Ok((format!("{column} = ?"), vec![BindValue::Uuid(uuid)])),
        FilterOp::NotEq => Ok((format!("{column} <> ?"), vec![BindValue::Uuid(uuid)])),
        _ => Err(ServiceError::InvalidRequest(format!(
            "{} filter only supports equality comparisons",
            filter.field
        ))),
    }
}

fn search_filter(filter: &Filter) -> Result<(String, Vec<BindValue>)> {
    match filter.op {
        FilterOp::Eq | FilterOp::Like => {
            let value = text_scalar(filter)?;
            Ok((
                "(d.title ILIKE ? OR COALESCE(d.description, '') ILIKE ? OR COALESCE(d.slug, '') ILIKE ? OR EXISTS (SELECT 1 FROM platform.authored_dashboard_panels p WHERE p.dashboard_id = d.id AND p.srql_query ILIKE ?))".to_string(),
                vec![value.clone(), value.clone(), value.clone(), value],
            ))
        }
        FilterOp::NotEq | FilterOp::NotLike => {
            let value = text_scalar(filter)?;
            Ok((
                "(d.title NOT ILIKE ? AND COALESCE(d.description, '') NOT ILIKE ? AND COALESCE(d.slug, '') NOT ILIKE ? AND NOT EXISTS (SELECT 1 FROM platform.authored_dashboard_panels p WHERE p.dashboard_id = d.id AND p.srql_query ILIKE ?))".to_string(),
                vec![value.clone(), value.clone(), value.clone(), value],
            ))
        }
        _ => Err(ServiceError::InvalidRequest(
            "dashboard search filter supports equality or like comparisons".into(),
        )),
    }
}

fn panel_query_filter(filter: &Filter) -> Result<(String, Vec<BindValue>)> {
    let (operator, value) = match filter.op {
        FilterOp::Eq | FilterOp::Like => ("ILIKE", text_scalar(filter)?),
        FilterOp::NotEq | FilterOp::NotLike => ("NOT ILIKE", text_scalar(filter)?),
        _ => {
            return Err(ServiceError::InvalidRequest(
                "dashboard srql_query filter supports equality or like comparisons".into(),
            ));
        }
    };

    if operator == "ILIKE" {
        Ok((
            "EXISTS (SELECT 1 FROM platform.authored_dashboard_panels p WHERE p.dashboard_id = d.id AND p.srql_query ILIKE ?)".to_string(),
            vec![value],
        ))
    } else {
        Ok((
            "NOT EXISTS (SELECT 1 FROM platform.authored_dashboard_panels p WHERE p.dashboard_id = d.id AND p.srql_query ILIKE ?)".to_string(),
            vec![value],
        ))
    }
}

fn text_scalar(filter: &Filter) -> Result<BindValue> {
    Ok(BindValue::Text(filter.value.as_scalar()?.to_string()))
}

fn text_array(filter: &Filter) -> Result<BindValue> {
    Ok(BindValue::TextArray(filter.value.as_list()?.to_vec()))
}

fn order_clause(order: &[OrderClause]) -> String {
    if order.is_empty() {
        return "ORDER BY d.updated_at DESC, d.id ASC".to_string();
    }

    let clauses: Vec<String> = order
        .iter()
        .filter_map(|clause| {
            order_column(&clause.field).map(|column| {
                let direction = match clause.direction {
                    OrderDirection::Asc => "ASC",
                    OrderDirection::Desc => "DESC",
                };

                format!("{column} {direction}")
            })
        })
        .collect();

    if clauses.is_empty() {
        "ORDER BY d.updated_at DESC, d.id ASC".to_string()
    } else {
        format!("ORDER BY {}, d.id ASC", clauses.join(", "))
    }
}

fn order_column(field: &str) -> Option<&'static str> {
    match field {
        "title" => Some("d.title"),
        "status" => Some("d.status"),
        "visibility" => Some("d.visibility"),
        "slug" => Some("d.slug"),
        "inserted_at" | "created_at" => Some("d.inserted_at"),
        "updated_at" | "modified_at" => Some("d.updated_at"),
        "archived_at" => Some("d.archived_at"),
        _ => None,
    }
}

fn rewrite_placeholders(sql: &str) -> String {
    let mut idx = 0usize;
    let mut out = String::with_capacity(sql.len() + 8);

    for ch in sql.chars() {
        if ch == '?' {
            idx += 1;
            out.push('$');
            out.push_str(&idx.to_string());
        } else {
            out.push(ch);
        }
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{parser::FilterValue, query::QueryPlan};

    fn plan(filters: Vec<Filter>, order: Vec<OrderClause>) -> QueryPlan {
        QueryPlan {
            entity: Entity::Dashboards,
            filters,
            order,
            limit: 25,
            offset: 0,
            time_range: None,
            stats: None,
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
        }
    }

    #[test]
    fn translates_dashboard_search_query() {
        let ast = crate::parser::parse(
            "in:dashboards title:%health% status:active srql_query:%cpu_metrics% sort:updated_at:desc limit:25",
        )
        .expect("dashboard query should parse");

        let plan = QueryPlan {
            entity: ast.entity,
            filters: ast.filters,
            order: ast.order,
            limit: ast.limit.unwrap_or(25),
            offset: 0,
            time_range: None,
            stats: ast.stats,
            downsample: ast.downsample,
            rollup_stats: ast.rollup_stats,
            other: false,
            include_deleted: false,
        };

        let (sql, params) = to_sql_and_params(&plan).expect("dashboard SQL should translate");

        assert!(sql.contains("FROM platform.authored_dashboards d"), "{sql}");
        assert!(
            sql.contains("platform.authored_dashboard_panels p"),
            "{sql}"
        );
        assert!(sql.contains("d.title ILIKE"), "{sql}");
        assert!(sql.contains("d.status ="), "{sql}");
        assert!(sql.contains("ORDER BY d.updated_at DESC"), "{sql}");
        assert_eq!(params.len(), 5);
    }

    #[test]
    fn rejects_unknown_dashboard_filter() {
        let result = filter_clause(&Filter {
            field: "unknown".to_string(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("value".to_string()),
        });

        assert!(result.is_err());
    }

    #[test]
    fn defaults_dashboard_ordering() {
        let (sql, _) = to_sql_and_params(&plan(Vec::new(), Vec::new())).unwrap();
        assert!(
            sql.contains("ORDER BY d.updated_at DESC, d.id ASC"),
            "{sql}"
        );
    }
}
