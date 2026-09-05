use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::AlertRow,
    parser::{Entity, Filter, OrderClause, OrderDirection},
    schema::alerts::dsl::{
        acknowledged_by as col_acknowledged_by, agent_uid as col_agent_uid, alerts,
        comparison as col_comparison, description as col_description, device_uid as col_device_uid,
        escalation_reason as col_escalation_reason, id as col_id, metric_name as col_metric_name,
        resolved_by as col_resolved_by, severity as col_severity, source_id as col_source_id,
        source_type as col_source_type, status as col_status, title as col_title,
        triggered_at as col_triggered_at,
    },
    time::TimeRange,
};
use diesel::PgTextExpressionMethods;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use uuid::Uuid;

type AlertsTable = crate::schema::alerts::table;
type AlertsFromClause = FromClause<AlertsTable>;
type AlertsQuery<'a> =
    BoxedSelectStatement<'a, <AlertsTable as AsQuery>::SqlType, AlertsFromClause, Pg>;

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;

    if let Some(stats) = &plan.stats {
        let spec = parse_stats_spec(stats.as_raw())?;
        let sql = build_stats_sql(plan, &spec)?;

        let mut query = diesel::sql_query(sql).into_boxed();
        for bind in stats_binds(plan)? {
            query = apply_bind(query, bind)?;
        }

        let rows: Vec<AlertStatsPayload> = query
            .load::<AlertStatsPayload>(conn)
            .await
            .map_err(|err| ServiceError::Internal(err.into()))?;

        return Ok(rows
            .into_iter()
            .filter_map(|row| row.payload.map(serde_json::Value::from))
            .collect());
    }

    let query = build_query(plan)?;
    let rows: Vec<AlertRow> = query
        .select(AlertRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<AlertRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(AlertRow::into_json).collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;

    if let Some(stats) = &plan.stats {
        let spec = parse_stats_spec(stats.as_raw())?;
        // No limit/offset reconciliation: the stats SQL interpolates its LIMIT
        // and has no OFFSET, so the binds are exactly the inner query's.
        return Ok((build_stats_sql(plan, &spec)?, stats_binds(plan)?));
    }

    let query = build_query(plan)?.limit(plan.limit).offset(plan.offset);
    let sql = super::diesel_sql(&query)?;

    let mut params = Vec::new();
    if let Some(TimeRange { start, end }) = &plan.time_range {
        params.push(BindParam::timestamptz(*start));
        params.push(BindParam::timestamptz(*end));
    }

    for filter in &plan.filters {
        collect_filter_params(&mut params, filter)?;
    }

    super::reconcile_limit_offset_binds(&sql, &mut params, plan.limit, plan.offset)?;

    #[cfg(any(test, debug_assertions))]
    {
        let bind_count = super::diesel_bind_count(&query)?;
        if bind_count != params.len() {
            return Err(ServiceError::Internal(anyhow::anyhow!(
                "bind count mismatch (diesel {bind_count} vs params {})",
                params.len()
            )));
        }
    }

    Ok((sql, params))
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    match plan.entity {
        Entity::Alerts => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by alerts query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<AlertsQuery<'static>> {
    let mut query = alerts.into_boxed::<Pg>();

    // Use triggered_at for time-based filtering (primary timestamp for alerts)
    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_triggered_at.ge(*start).and(col_triggered_at.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

fn apply_filter<'a>(mut query: AlertsQuery<'a>, filter: &Filter) -> Result<AlertsQuery<'a>> {
    match filter.field.as_str() {
        "id" => {
            let value = filter.value.as_scalar()?;
            let uuid = Uuid::parse_str(value)
                .map_err(|_| ServiceError::InvalidRequest("id must be a valid UUID".into()))?;
            query = match filter.op {
                crate::parser::FilterOp::Eq => query.filter(col_id.eq(uuid)),
                crate::parser::FilterOp::NotEq => query.filter(col_id.ne(uuid)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "id filter only supports equality comparisons".into(),
                    ));
                }
            };
        }
        "title" => {
            query = apply_text_filter!(query, filter, col_title)?;
        }
        "description" => {
            query = apply_text_filter!(query, filter, col_description)?;
        }
        "severity" => {
            query = apply_text_filter!(query, filter, col_severity)?;
        }
        "status" => {
            query = apply_text_filter!(query, filter, col_status)?;
        }
        "source_type" => {
            query = apply_text_filter!(query, filter, col_source_type)?;
        }
        "source_id" => {
            query = apply_text_filter!(query, filter, col_source_id)?;
        }
        "device_uid" => {
            query = apply_text_filter!(query, filter, col_device_uid)?;
        }
        "agent_uid" => {
            query = apply_text_filter!(query, filter, col_agent_uid)?;
        }
        "metric_name" => {
            query = apply_text_filter!(query, filter, col_metric_name)?;
        }
        "comparison" => {
            query = apply_text_filter!(query, filter, col_comparison)?;
        }
        "acknowledged_by" => {
            query = apply_text_filter!(query, filter, col_acknowledged_by)?;
        }
        "resolved_by" => {
            query = apply_text_filter!(query, filter, col_resolved_by)?;
        }
        "escalation_reason" => {
            query = apply_text_filter!(query, filter, col_escalation_reason)?;
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for alerts: '{other}'"
            )));
        }
    }

    Ok(query)
}

fn collect_text_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.op {
        crate::parser::FilterOp::Eq
        | crate::parser::FilterOp::NotEq
        | crate::parser::FilterOp::Like
        | crate::parser::FilterOp::NotLike => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        crate::parser::FilterOp::In | crate::parser::FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(());
            }
            params.push(BindParam::TextArray(values));
            Ok(())
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for text filter: {:?}",
            filter.op
        ))),
    }
}

fn collect_filter_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.field.as_str() {
        "id" => {
            let value = filter.value.as_scalar()?;
            let uuid = Uuid::parse_str(value)
                .map_err(|_| ServiceError::InvalidRequest("id must be a valid UUID".into()))?;
            params.push(BindParam::Uuid(uuid));
            Ok(())
        }
        "title" | "description" | "severity" | "status" | "source_type" | "source_id"
        | "device_uid" | "agent_uid" | "metric_name" | "comparison" | "acknowledged_by"
        | "resolved_by" | "escalation_reason" => collect_text_params(params, filter),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for alerts: '{other}'"
        ))),
    }
}

fn apply_ordering<'a>(mut query: AlertsQuery<'a>, order: &[OrderClause]) -> AlertsQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            match clause.field.as_str() {
                "triggered_at" | "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.order(col_triggered_at.asc()),
                    OrderDirection::Desc => query.order(col_triggered_at.desc()),
                },
                "severity" => match clause.direction {
                    OrderDirection::Asc => query.order(col_severity.asc()),
                    OrderDirection::Desc => query.order(col_severity.desc()),
                },
                "status" => match clause.direction {
                    OrderDirection::Asc => query.order(col_status.asc()),
                    OrderDirection::Desc => query.order(col_status.desc()),
                },
                "title" => match clause.direction {
                    OrderDirection::Asc => query.order(col_title.asc()),
                    OrderDirection::Desc => query.order(col_title.desc()),
                },
                _ => query,
            }
        } else {
            match clause.field.as_str() {
                "triggered_at" | "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_triggered_at.asc()),
                    OrderDirection::Desc => query.then_order_by(col_triggered_at.desc()),
                },
                "severity" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_severity.asc()),
                    OrderDirection::Desc => query.then_order_by(col_severity.desc()),
                },
                "status" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_status.asc()),
                    OrderDirection::Desc => query.then_order_by(col_status.desc()),
                },
                "title" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_title.asc()),
                    OrderDirection::Desc => query.then_order_by(col_title.desc()),
                },
                _ => query,
            }
        };
    }

    // Default ordering: newest alerts first
    if !applied {
        query = query.order(col_triggered_at.desc());
    }

    query
}


/// A grouped `stats:` request against the alerts entity.
///
/// Only `count()` is supported. Alerts have no numeric measure worth averaging
/// or summing -- `metric_value` is the value that tripped a threshold, and its
/// mean across unrelated rules is meaningless -- so a request for one is
/// rejected rather than answered with a number nobody should act on.
#[derive(Debug, Clone)]
struct AlertStatsSpec {
    alias: String,
    group_fields: Vec<&'static str>,
}

/// Columns an alert may be grouped by.
///
/// Deliberately narrow: these are the dimensions an operator triages along.
/// Free-text columns (`title`, `description`) are excluded because grouping by
/// them produces one group per alert, which is a row listing wearing an
/// aggregate's clothes.
fn alert_group_column(field: &str) -> Option<&'static str> {
    match field {
        "severity" => Some("severity"),
        "status" => Some("status"),
        "source_type" => Some("source_type"),
        "device_uid" => Some("device_uid"),
        "agent_uid" => Some("agent_uid"),
        "metric_name" => Some("metric_name"),
        "escalation_level" => Some("escalation_level"),
        _ => None,
    }
}

fn parse_stats_spec(raw: &str) -> Result<AlertStatsSpec> {
    let trimmed = raw.trim();

    let (agg_part, group_part) = match trimmed.split_once(" by ") {
        Some((agg, group)) => (agg.trim(), group.trim()),
        None => {
            return Err(ServiceError::InvalidRequest(
                "alerts stats requires a group: use `stats:count() as <alias> by <field>`".into(),
            ));
        }
    };

    let (func_part, alias) = match agg_part.split_once(" as ") {
        Some((func, alias)) => (func.trim(), alias.trim()),
        None => (agg_part, "count"),
    };

    let normalized = func_part.replace(char::is_whitespace, "").to_lowercase();
    if normalized != "count()" && normalized != "count(*)" {
        return Err(ServiceError::InvalidRequest(format!(
            "unsupported alerts aggregation '{func_part}'; only count() is supported"
        )));
    }

    let alias = sanitize_stats_alias(alias)?;

    let mut group_fields = Vec::new();
    for candidate in group_part.split(',') {
        let field = candidate
            .trim()
            .trim_matches('"')
            .trim_matches('\'')
            .to_lowercase();

        match alert_group_column(&field) {
            Some(column) => {
                if !group_fields.contains(&column) {
                    group_fields.push(column);
                }
            }
            None => {
                return Err(ServiceError::InvalidRequest(format!(
                    "unsupported alerts stats group field '{field}'"
                )));
            }
        }
    }

    if group_fields.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "alerts stats requires at least one group field".into(),
        ));
    }

    Ok(AlertStatsSpec { alias, group_fields })
}

/// The alias becomes a JSON key and is interpolated into SQL, so it is
/// restricted to identifier characters.
fn sanitize_stats_alias(raw: &str) -> Result<String> {
    let alias = raw.trim().trim_matches('"').trim_matches('\'').to_lowercase();

    if alias.is_empty()
        || alias.len() > 64
        || !alias
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == '_')
    {
        return Err(ServiceError::InvalidRequest(format!(
            "invalid alerts stats alias '{raw}'"
        )));
    }

    Ok(alias)
}

/// Build the grouped-stats SQL by WRAPPING the row query rather than rebuilding
/// its WHERE clause.
///
/// The row path already knows how to filter alerts, and duplicating that in raw
/// SQL is how the two drift: a filter honoured when listing rows but ignored
/// when counting them is precisely the silent-wrong-number failure this entity
/// already had. Wrapping means there is exactly one filter implementation, and
/// an unsupported filter still errors from the same place it always did.
///
/// LIMIT is interpolated rather than bound because the inner query owns the
/// placeholder numbering; appending a bind would renumber nothing and be read
/// as one of the inner query's own.
fn build_stats_sql(plan: &QueryPlan, spec: &AlertStatsSpec) -> Result<String> {
    let inner = super::diesel_sql(&build_query(plan)?)?;

    let projection = spec
        .group_fields
        .iter()
        .map(|column| format!("'{column}', src.{column}"))
        .collect::<Vec<_>>()
        .join(", ");

    let group_by = spec
        .group_fields
        .iter()
        .map(|column| format!("src.{column}"))
        .collect::<Vec<_>>()
        .join(", ");

    let limit = plan.limit.clamp(1, 1000);

    Ok([
        format!("SELECT jsonb_build_object({projection}, '{}', COUNT(*)) AS payload", spec.alias),
        format!("FROM ({inner}) src"),
        format!("GROUP BY {group_by}"),
        // Largest groups first: a truncated result then keeps the ones an
        // operator is triaging, rather than an arbitrary slice.
        "ORDER BY COUNT(*) DESC".to_string(),
        format!("LIMIT {limit}"),
    ]
    .join("\n"))
}


#[derive(diesel::QueryableByName)]
struct AlertStatsPayload {
    #[diesel(sql_type = diesel::sql_types::Nullable<diesel::sql_types::Jsonb>)]
    payload: Option<crate::jsonb::DbJson>,
}

/// Binds for the stats SQL, in the order the inner query's placeholders expect.
///
/// Deliberately the same construction the row path uses -- time range first,
/// then filters in plan order -- because the inner SQL *is* the row query. If
/// these two ever disagree the placeholders silently bind the wrong values,
/// which is why there is one function rather than two.
fn stats_binds(plan: &QueryPlan) -> Result<Vec<BindParam>> {
    let mut params = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        params.push(BindParam::timestamptz(*start));
        params.push(BindParam::timestamptz(*end));
    }

    for filter in &plan.filters {
        collect_filter_params(&mut params, filter)?;
    }

    Ok(params)
}

fn apply_bind<'a>(
    query: diesel::query_builder::BoxedSqlQuery<'a, Pg, diesel::query_builder::SqlQuery>,
    bind: BindParam,
) -> Result<diesel::query_builder::BoxedSqlQuery<'a, Pg, diesel::query_builder::SqlQuery>> {
    use diesel::sql_types::{Array, BigInt, Bool, Double, Text, Timestamptz, Uuid as SqlUuid};

    let bound = match bind {
        BindParam::Text(value) => query.bind::<Text, _>(value),
        BindParam::TextArray(values) => query.bind::<Array<Text>, _>(values),
        BindParam::IntArray(values) => query.bind::<Array<BigInt>, _>(values),
        BindParam::Bool(value) => query.bind::<Bool, _>(value),
        BindParam::Int(value) => query.bind::<BigInt, _>(value),
        BindParam::Float(value) => query.bind::<Double, _>(value),
        // Bound as a real timestamptz, not as text. The inner query compares
        // against `triggered_at`, and handing Postgres a string there is a type
        // error at execution -- which translation-only tests would never catch,
        // because they never bind anything.
        BindParam::Timestamptz(value) => {
            let parsed = chrono::DateTime::parse_from_rfc3339(&value)
                .map_err(|err| ServiceError::Internal(err.into()))?
                .with_timezone(&chrono::Utc);

            query.bind::<Timestamptz, _>(parsed)
        }
        BindParam::Uuid(value) => query.bind::<SqlUuid, _>(value),
        BindParam::Date(_) => {
            return Err(ServiceError::InvalidRequest(
                "unsupported bind type for alerts".into(),
            ));
        }
    };

    Ok(bound)
}
