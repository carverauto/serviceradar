//! SRQL execution for the `device_sweep_overlap` diagnostic view (issue 4167,
//! task 4): for every sweep-group declaration and every observed coverage
//! row, this answers "which sweep groups were DECLARED to target this device
//! versus which actually PRODUCED results for it" -- `relationship =
//! 'declared_not_observed'` is the alert the view exists to surface.
//!
//! This follows the `addon_fleet` view-backed pattern, not the five earlier
//! sweep entities (which query real tables via Diesel's typed schema):
//! `platform.device_sweep_overlap` is a view, so it is deliberately absent
//! from `schema.rs` and is read with `diesel::sql_query` plus a
//! `QueryableByName` struct holding a single `Jsonb` payload column.

use super::{BindParam, QueryPlan, bind_sql_param};
use crate::{
    error::{Result, ServiceError},
    jsonb::DbJson,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
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
    // Execution goes through `to_sql_and_params`, not around it, so the SQL that
    // runs IS the SQL translate returns. Building it twice let the execute side
    // send the `?` form straight to Diesel, which does not translate `?` for
    // Postgres: `?` is a valid Postgres operator character (jsonb containment),
    // so a divergence here would surface as a syntax error at the NEXT token
    // rather than an obviously-wrong-placeholder error -- exactly the class of
    // bug that shipped in five entities before this one (see addon_fleet.rs).
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
    Uuid,
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    if !matches!(plan.entity, Entity::DeviceSweepOverlap) {
        return Err(ServiceError::InvalidRequest(
            "entity not supported by device_sweep_overlap query".into(),
        ));
    }

    // Overlap is a per-row diagnostic, not an aggregate; stats support is a
    // separate task (see addon_fleet's identical rejection).
    if plan.stats.is_some() {
        return Err(ServiceError::InvalidRequest(
            "device_sweep_overlap does not support stats queries".into(),
        ));
    }

    // REJECT rather than ignore, and reject rather than apply. A
    // `declared_not_observed` row has no `last_seen_at` -- that is what makes it
    // an alert -- so binding a window to that column would silently delete every
    // row the caller is most likely asking for. Ignoring the clause is no better:
    // `last:24h` would return all-time rows with nothing to say it had been
    // dropped. Until this entity has a column a window can honestly mean, say so.
    if plan.time_range.is_some() {
        return Err(ServiceError::InvalidRequest(
            "device_sweep_overlap does not support time-range filters: a \
             declared_not_observed row has no observation time to filter on"
                .into(),
        ));
    }

    Ok(())
}

fn build_sql(plan: &QueryPlan) -> Result<BuiltSql> {
    let mut where_parts = Vec::new();
    let mut binds = Vec::new();

    for filter in &plan.filters {
        where_parts.push(filter_condition(filter, &mut binds)?);
    }

    let where_sql = if where_parts.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", where_parts.join(" AND "))
    };

    // Limit/offset binds are pushed LAST, after every filter bind -- anything
    // pushed after them would bind against the wrong `$n`.
    binds.push(BindParam::Int(plan.limit));
    binds.push(BindParam::Int(plan.offset));

    Ok(BuiltSql {
        sql: format!(
            "SELECT to_jsonb(overlap) AS payload FROM platform.device_sweep_overlap AS overlap{where_sql}{} LIMIT ? OFFSET ?",
            order_sql(&plan.order)?
        ),
        binds,
    })
}

fn filter_condition(filter: &Filter, binds: &mut Vec<BindParam>) -> Result<String> {
    let (field_sql, kind) = field_spec(filter.field.as_str()).ok_or_else(|| {
        ServiceError::InvalidRequest(format!(
            "unsupported filter field for device_sweep_overlap: '{}'",
            filter.field
        ))
    })?;

    match kind {
        FieldKind::Text => text_condition(field_sql, filter, binds),
        FieldKind::Bool => bool_condition(field_sql, filter, binds),
        FieldKind::Uuid => uuid_condition(field_sql, filter, binds),
    }
}

fn field_spec(field: &str) -> Option<(&'static str, FieldKind)> {
    match field {
        "device_uid" => Some(("overlap.device_uid", FieldKind::Text)),
        "ip" => Some(("overlap.ip", FieldKind::Text)),
        "agent_id" => Some(("overlap.agent_id", FieldKind::Text)),
        "relationship" => Some(("overlap.relationship", FieldKind::Text)),
        "sweep_group_id" => Some(("overlap.sweep_group_id", FieldKind::Uuid)),
        "declared" => Some(("overlap.declared", FieldKind::Bool)),
        "observed" => Some(("overlap.observed", FieldKind::Bool)),
        _ => None,
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
            Ok(format!("{field_sql} <> ?"))
        }
        FilterOp::Like => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("{field_sql} ILIKE ?"))
        }
        FilterOp::NotLike => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("{field_sql} NOT ILIKE ?"))
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
                Ok(format!("NOT ({field_sql} = ANY(?))"))
            }
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for device_sweep_overlap text filter: {:?}",
            filter.op
        ))),
    }
}

fn bool_condition(field_sql: &str, filter: &Filter, binds: &mut Vec<BindParam>) -> Result<String> {
    let value = parse_bool(filter.value.as_scalar()?)?;

    match filter.op {
        FilterOp::Eq => {
            binds.push(BindParam::Bool(value));
            Ok(format!("{field_sql} = ?"))
        }
        FilterOp::NotEq => {
            binds.push(BindParam::Bool(value));
            Ok(format!("{field_sql} <> ?"))
        }
        _ => Err(ServiceError::InvalidRequest(
            "device_sweep_overlap boolean filters only support equality".into(),
        )),
    }
}

fn uuid_condition(field_sql: &str, filter: &Filter, binds: &mut Vec<BindParam>) -> Result<String> {
    match filter.op {
        FilterOp::Eq => {
            binds.push(BindParam::Uuid(parse_uuid(filter.value.as_scalar()?)?));
            Ok(format!("{field_sql} = ?"))
        }
        FilterOp::NotEq => {
            binds.push(BindParam::Uuid(parse_uuid(filter.value.as_scalar()?)?));
            Ok(format!("{field_sql} <> ?"))
        }
        _ => Err(ServiceError::InvalidRequest(
            "device_sweep_overlap sweep_group_id filter only supports equality".into(),
        )),
    }
}

fn parse_uuid(raw: &str) -> Result<uuid::Uuid> {
    uuid::Uuid::parse_str(raw)
        .map_err(|_| ServiceError::InvalidRequest(format!("invalid uuid '{raw}'")))
}

fn parse_bool(raw: &str) -> Result<bool> {
    match raw.to_ascii_lowercase().as_str() {
        "true" | "1" | "yes" => Ok(true),
        "false" | "0" | "no" => Ok(false),
        _ => Err(ServiceError::InvalidRequest(format!(
            "expected boolean device_sweep_overlap filter value: {raw}"
        ))),
    }
}

fn order_sql(order: &[OrderClause]) -> Result<String> {
    let clauses = order
        .iter()
        .map(|clause| {
            let column = order_column(clause.field.as_str()).ok_or_else(|| {
                ServiceError::InvalidRequest(format!(
                    "unsupported sort field for device_sweep_overlap: '{}'",
                    clause.field
                ))
            })?;
            let direction = match clause.direction {
                OrderDirection::Asc => "ASC",
                OrderDirection::Desc => "DESC",
            };
            Ok(format!("{column} {direction} NULLS LAST"))
        })
        .collect::<Result<Vec<_>>>()?;

    if clauses.is_empty() {
        // `declared_not_observed` rows carry a NULL `last_seen_at` by construction
        // (they were never observed), so a bare `last_seen_at DESC NULLS LAST`
        // default sorts EVERY alert row after EVERY non-alert row -- and at the
        // scale this view targets the non-alert prefix exceeds `max_cursor_offset`,
        // so the alerts are not merely buried, they are unpageable. Surface them
        // first; recency still orders within each block. An explicit `sort:` from
        // the caller replaces this entirely.
        Ok(" ORDER BY (overlap.relationship = 'declared_not_observed') DESC, \
overlap.last_seen_at DESC NULLS LAST"
            .into())
    } else {
        Ok(format!(" ORDER BY {}", clauses.join(", ")))
    }
}

fn order_column(field: &str) -> Option<&'static str> {
    match field {
        "device_uid" => Some("overlap.device_uid"),
        "ip" => Some("overlap.ip"),
        "agent_id" => Some("overlap.agent_id"),
        "relationship" => Some("overlap.relationship"),
        "sweep_group_id" => Some("overlap.sweep_group_id"),
        "last_seen_at" | "time" | "timestamp" => Some("overlap.last_seen_at"),
        "config_delivered_at" => Some("overlap.config_delivered_at"),
        _ => None,
    }
}

fn rewrite_placeholders(sql: &str) -> String {
    let mut output = String::with_capacity(sql.len());
    let mut index = 1;

    for character in sql.chars() {
        if character == '?' {
            output.push('$');
            output.push_str(&index.to_string());
            index += 1;
        } else {
            output.push(character);
        }
    }

    output
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::{Filter, FilterOp, FilterValue};
    use crate::time::TimeRange;

    fn plan_with(filters: Vec<Filter>) -> QueryPlan {
        QueryPlan {
            entity: Entity::DeviceSweepOverlap,
            filters,
            order: Vec::new(),
            limit: 100,
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
    fn rejects_wrong_entity() {
        let mut plan = plan_with(vec![]);
        plan.entity = Entity::SweepCoverage;
        let err = to_sql_and_params(&plan).unwrap_err();
        assert!(err.to_string().contains("not supported"));
    }

    #[test]
    fn rejects_stats() {
        let mut plan = plan_with(vec![]);
        plan.stats = Some(crate::parser::StatsSpec {
            raw: "count".into(),
            aggregations: Vec::new(),
        });
        let err = to_sql_and_params(&plan).unwrap_err();
        assert!(err.to_string().contains("does not support stats"));
    }

    #[test]
    fn default_order_surfaces_declared_not_observed_before_recency() {
        let plan = plan_with(vec![]);
        let (sql, _) = to_sql_and_params(&plan).expect("should build sql");

        // The alert rows have a NULL last_seen_at by construction, so a bare
        // `last_seen_at DESC NULLS LAST` default puts every one of them behind
        // every ordinary row -- past `max_cursor_offset` on a real estate.
        let order = sql
            .split_once(" ORDER BY ")
            .expect("expected an ORDER BY")
            .1;
        let alert_first = order
            .find("(overlap.relationship = 'declared_not_observed') DESC")
            .expect("alert rows must be sorted first by default");
        let recency = order
            .find("overlap.last_seen_at DESC NULLS LAST")
            .expect("recency must still order within each block");
        assert!(
            alert_first < recency,
            "declared_not_observed must precede recency in the default sort: {order}"
        );
    }

    #[test]
    fn explicit_sort_replaces_the_alert_first_default() {
        let mut plan = plan_with(vec![]);
        plan.order = vec![OrderClause {
            field: "device_uid".into(),
            direction: OrderDirection::Asc,
        }];
        let (sql, _) = to_sql_and_params(&plan).expect("should build sql");
        assert!(
            sql.contains("ORDER BY overlap.device_uid ASC NULLS LAST"),
            "an explicit sort must replace the default, got: {sql}"
        );
        assert!(
            !sql.contains("declared_not_observed') DESC"),
            "the default must not be prepended to an explicit sort: {sql}"
        );
    }

    #[test]
    fn rejects_time_range_rather_than_ignoring_it() {
        // Applying a window would delete every declared_not_observed row (they have
        // no last_seen_at); ignoring it would answer a different question in silence.
        let mut plan = plan_with(vec![]);
        let now = chrono::Utc::now();
        plan.time_range = Some(TimeRange {
            start: now - chrono::Duration::hours(24),
            end: now,
        });
        let err = to_sql_and_params(&plan).expect_err("a time range must be refused");
        assert!(
            format!("{err}").contains("does not support time-range filters"),
            "expected an explicit refusal, got: {err}"
        );
    }

    #[test]
    fn builds_query_with_text_filters() {
        for field in ["device_uid", "ip", "agent_id", "relationship"] {
            let plan = plan_with(vec![Filter {
                field: field.into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("x".to_string()),
            }]);
            assert!(
                to_sql_and_params(&plan).is_ok(),
                "should build query with {field} filter"
            );
        }
    }

    #[test]
    fn builds_query_with_bool_filters() {
        for field in ["declared", "observed"] {
            let plan = plan_with(vec![Filter {
                field: field.into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("true".to_string()),
            }]);
            assert!(
                to_sql_and_params(&plan).is_ok(),
                "should build query with {field} filter"
            );
        }
    }

    #[test]
    fn builds_query_with_sweep_group_id_filter() {
        let plan = plan_with(vec![Filter {
            field: "sweep_group_id".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar(uuid::Uuid::nil().to_string()),
        }]);
        assert!(
            to_sql_and_params(&plan).is_ok(),
            "should build query with sweep_group_id filter"
        );
    }

    #[test]
    fn rejects_invalid_sweep_group_id() {
        let plan = plan_with(vec![Filter {
            field: "sweep_group_id".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("not-a-uuid".to_string()),
        }]);
        assert!(to_sql_and_params(&plan).is_err());
    }

    #[test]
    fn unknown_filter_field_returns_error() {
        let plan = plan_with(vec![Filter {
            field: "execution_count".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("1".to_string()),
        }]);
        let err = to_sql_and_params(&plan).unwrap_err();
        assert!(err.to_string().contains("unsupported filter field"));
    }

    #[test]
    fn translate_preview_uses_dollar_placeholders_never_literal_question_marks() {
        let plan = plan_with(vec![Filter {
            field: "device_uid".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("dev-1".to_string()),
        }]);
        let (sql, binds) = to_sql_and_params(&plan).expect("should build sql");
        assert!(
            !sql.contains('?'),
            "sql should not contain literal '?': {sql}"
        );
        assert!(sql.contains("$1"), "expected $1 placeholder: {sql}");
        // device_uid filter, then LIMIT, then OFFSET.
        assert_eq!(binds.len(), 3);
    }
}
