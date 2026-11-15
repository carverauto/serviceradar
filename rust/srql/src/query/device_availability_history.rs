//! `in:device_availability_history` (also spelled `device_availability_transitions`
//! and `availability_history`): the merged availability history of devices.
//!
//! Each row of `platform.device_availability_transitions` says the device was
//! `from_state` from `from_since` (NULL when there was no earlier decision) until
//! `changed_at`, when it became `to_state`. The device page reads one device over
//! a window, newest first:
//! `in:device_availability_history uid:"<uid>" time:[<start>,<end>] sort:changed_at:desc`.
//!
//! The entity is a row listing only. `stats:`, `rollup_stats:`, `bucket:` and
//! `other:true` are refused by name on both backends; the StarRocks dialect
//! (`starrocks/device_availability_history.rs`) shares the filter and sort
//! vocabulary below, so the two answer the same queries.

use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::DeviceAvailabilityTransitionRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::device_availability_transitions::dsl::{
        authority_class as col_authority_class, changed_at as col_changed_at,
        conflict as col_conflict, created_at as col_created_at, device_availability_transitions,
        device_uid as col_device_uid, from_state as col_from_state,
        reporter_agent_id as col_reporter_agent_id, rule as col_rule,
        source_kind as col_source_kind, to_state as col_to_state,
    },
    time::TimeRange,
};
use diesel::PgTextExpressionMethods;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel_async::{AsyncPgConnection, RunQueryDsl};

const ENTITY: &str = "device_availability_history";

type TransitionsTable = crate::schema::device_availability_transitions::table;
type TransitionsFromClause = FromClause<TransitionsTable>;
type TransitionsQuery<'a> =
    BoxedSelectStatement<'a, <TransitionsTable as AsQuery>::SqlType, TransitionsFromClause, Pg>;

/// A text column a filter reads. Both dialects resolve filter fields through
/// [`TextColumn::for_field`], so they accept the same vocabulary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum TextColumn {
    DeviceUid,
    FromState,
    ToState,
    SourceKind,
    AuthorityClass,
    ReporterAgentId,
    Rule,
}

impl TextColumn {
    /// `uid:` arrives here as `device_id`: the planner renames `uid` to
    /// `device_id` on every entity except devices and agents.
    pub(super) fn for_field(field: &str) -> Option<Self> {
        Some(match field {
            "device_uid" | "device_id" => Self::DeviceUid,
            "from_state" => Self::FromState,
            "to_state" => Self::ToState,
            "source_kind" => Self::SourceKind,
            "authority_class" => Self::AuthorityClass,
            "reporter_agent_id" => Self::ReporterAgentId,
            "rule" => Self::Rule,
            _ => return None,
        })
    }

    pub(super) fn name(self) -> &'static str {
        match self {
            Self::DeviceUid => "device_uid",
            Self::FromState => "from_state",
            Self::ToState => "to_state",
            Self::SourceKind => "source_kind",
            Self::AuthorityClass => "authority_class",
            Self::ReporterAgentId => "reporter_agent_id",
            Self::Rule => "rule",
        }
    }
}

/// The boolean filter field.
pub(super) const CONFLICT_FIELD: &str = "conflict";

/// A column the listing sorts by. Unknown sort fields are skipped, as
/// `bmp_events` skips them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum SortColumn {
    ChangedAt,
    CreatedAt,
    DeviceUid,
}

impl SortColumn {
    pub(super) fn for_field(field: &str) -> Option<Self> {
        Some(match field {
            "changed_at" | "time" | "timestamp" => Self::ChangedAt,
            "created_at" => Self::CreatedAt,
            "device_uid" | "device_id" => Self::DeviceUid,
            _ => return None,
        })
    }

    pub(super) fn name(self) -> &'static str {
        match self {
            Self::ChangedAt => "changed_at",
            Self::CreatedAt => "created_at",
            Self::DeviceUid => "device_uid",
        }
    }
}

pub(super) fn unsupported_filter(field: &str) -> ServiceError {
    ServiceError::InvalidRequest(format!("unsupported filter field for {ENTITY}: '{field}'"))
}

pub(super) fn parse_conflict(filter: &Filter) -> Result<bool> {
    super::mtr_traces::parse_bool(filter.value.as_scalar()?)
}

pub(super) fn conflict_op_error() -> ServiceError {
    ServiceError::InvalidRequest("conflict only supports equality comparisons".into())
}

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;
    refuse_unsupported_clauses(plan)?;
    let query = build_query(plan)?;
    let rows: Vec<DeviceAvailabilityTransitionRow> = query
        .select(DeviceAvailabilityTransitionRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<DeviceAvailabilityTransitionRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .map(DeviceAvailabilityTransitionRow::into_json)
        .collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;
    refuse_unsupported_clauses(plan)?;
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
        Entity::DeviceAvailabilityHistory => Ok(()),
        _ => Err(ServiceError::InvalidRequest(format!(
            "entity not supported by {ENTITY} query"
        ))),
    }
}

/// The entity is a row listing on both backends: every aggregation clause is
/// refused by name rather than answered as a page of raw rows.
pub(super) fn refuse_unsupported_clauses(plan: &QueryPlan) -> Result<()> {
    super::reject_stats(plan, ENTITY)?;

    if let Some(kind) = plan
        .rollup_stats
        .as_deref()
        .map(str::trim)
        .filter(|kind| !kind.is_empty())
    {
        return Err(ServiceError::InvalidRequest(format!(
            "rollup_stats:{kind} is not supported for {ENTITY}"
        )));
    }

    if plan.downsample.is_some() {
        return Err(ServiceError::InvalidRequest(format!(
            "bucket: is not supported for {ENTITY}"
        )));
    }

    if plan.other {
        return Err(ServiceError::InvalidRequest(
            "other:true is currently supported only for flow or timeseries stats".into(),
        ));
    }

    Ok(())
}

fn build_query(plan: &QueryPlan) -> Result<TransitionsQuery<'static>> {
    let mut query = device_availability_transitions.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_changed_at.ge(*start).and(col_changed_at.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    Ok(apply_ordering(query, &plan.order))
}

fn apply_filter<'a>(
    mut query: TransitionsQuery<'a>,
    filter: &Filter,
) -> Result<TransitionsQuery<'a>> {
    let field = filter.field.as_str();
    if field == CONFLICT_FIELD {
        let value = parse_conflict(filter)?;
        return match filter.op {
            FilterOp::Eq => Ok(query.filter(col_conflict.eq(value))),
            FilterOp::NotEq => Ok(query.filter(col_conflict.ne(value))),
            _ => Err(conflict_op_error()),
        };
    }

    let column = TextColumn::for_field(field).ok_or_else(|| unsupported_filter(field))?;
    query = match column {
        TextColumn::DeviceUid => apply_text_filter!(query, filter, col_device_uid)?,
        TextColumn::FromState => apply_text_filter!(query, filter, col_from_state)?,
        TextColumn::ToState => apply_text_filter!(query, filter, col_to_state)?,
        TextColumn::SourceKind => apply_text_filter!(query, filter, col_source_kind)?,
        TextColumn::AuthorityClass => apply_text_filter!(query, filter, col_authority_class)?,
        TextColumn::ReporterAgentId => apply_text_filter!(query, filter, col_reporter_agent_id)?,
        TextColumn::Rule => apply_text_filter!(query, filter, col_rule)?,
    };

    Ok(query)
}

fn collect_filter_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    let field = filter.field.as_str();
    if field == CONFLICT_FIELD {
        params.push(BindParam::Bool(parse_conflict(filter)?));
        return Ok(());
    }
    if TextColumn::for_field(field).is_none() {
        return Err(unsupported_filter(field));
    }

    match filter.op {
        FilterOp::Eq | FilterOp::NotEq | FilterOp::Like | FilterOp::NotLike => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if !values.is_empty() {
                params.push(BindParam::TextArray(values));
            }
            Ok(())
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for text filter: {:?}",
            filter.op
        ))),
    }
}

/// The recognized sort terms in the order given. Unknown fields are skipped, as
/// `bmp_events` skips them; with no recognized term, newest first
/// (`changed_at` DESC).
fn apply_ordering<'a>(
    mut query: TransitionsQuery<'a>,
    order: &[OrderClause],
) -> TransitionsQuery<'a> {
    let mut applied = false;
    for clause in order {
        let Some(column) = SortColumn::for_field(clause.field.as_str()) else {
            continue;
        };
        // `order` replaces any earlier ordering, so the first recognized term
        // starts the ORDER BY and every later one extends it.
        macro_rules! by {
            ($column:expr) => {
                match (clause.direction, applied) {
                    (OrderDirection::Asc, false) => query.order($column.asc()),
                    (OrderDirection::Desc, false) => query.order($column.desc()),
                    (OrderDirection::Asc, true) => query.then_order_by($column.asc()),
                    (OrderDirection::Desc, true) => query.then_order_by($column.desc()),
                }
            };
        }
        query = match column {
            SortColumn::ChangedAt => by!(col_changed_at),
            SortColumn::CreatedAt => by!(col_created_at),
            SortColumn::DeviceUid => by!(col_device_uid),
        };
        applied = true;
    }

    if !applied {
        query = query.order(col_changed_at.desc());
    }

    query
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{parser::parse, query::build_query_plan};

    const DEVICE_A: &str = "sr:00000000-0000-4000-8000-000000000001";
    const DEVICE_B: &str = "sr:00000000-0000-4000-8000-000000000002";

    fn plan_for(query: &str) -> QueryPlan {
        let config =
            crate::config::AppConfig::embedded("postgres://localhost/serviceradar".to_string());
        let request = crate::query::QueryRequest {
            query: query.to_string(),
            limit: None,
            cursor: None,
            direction: crate::query::QueryDirection::Next,
            mode: None,
            permitted_signals: None,
        };
        let ast = parse(query).expect("query should parse");
        build_query_plan(&config, &request, ast).expect("query plan should build")
    }

    fn sql_for(query: &str) -> (String, Vec<BindParam>) {
        to_sql_and_params(&plan_for(query))
            .unwrap_or_else(|err| panic!("{query} must compile: {err}"))
    }

    fn refused(query: &str) -> ServiceError {
        match to_sql_and_params(&plan_for(query)) {
            Ok((sql, _)) => panic!("{query} must be refused, compiled to: {sql}"),
            Err(err) => err,
        }
    }

    fn text_params(params: &[BindParam]) -> Vec<&str> {
        params
            .iter()
            .filter_map(|param| match param {
                BindParam::Text(value) => Some(value.as_str()),
                _ => None,
            })
            .collect()
    }

    /// The device page's query: one device, a closed window, newest first.
    #[test]
    fn the_device_page_query_binds_uid_window_and_page() {
        let (sql, params) = sql_for(&format!(
            r#"in:device_availability_history uid:"{DEVICE_A}" time:[2026-01-01T00:00:00Z,2026-01-02T00:00:00Z] sort:changed_at:desc limit:200"#
        ));

        assert!(
            sql.contains(r#"FROM "device_availability_transitions""#),
            "{sql}"
        );
        assert!(
            sql.contains(r#""device_availability_transitions"."changed_at" >= $1"#),
            "{sql}"
        );
        assert!(
            sql.contains(r#""device_availability_transitions"."changed_at" <= $2"#),
            "{sql}"
        );
        assert!(
            sql.contains(r#""device_availability_transitions"."device_uid" = $3"#),
            "{sql}"
        );
        assert!(
            sql.contains(r#"ORDER BY "device_availability_transitions"."changed_at" DESC"#),
            "{sql}"
        );
        assert!(sql.ends_with("LIMIT $4 OFFSET $5"), "{sql}");

        assert_eq!(params.len(), 5, "{params:?}");
        assert!(
            matches!(&params[0], BindParam::Timestamptz(v) if v.starts_with("2026-01-01T00:00:00"))
        );
        assert!(
            matches!(&params[1], BindParam::Timestamptz(v) if v.starts_with("2026-01-02T00:00:00"))
        );
        assert!(matches!(&params[2], BindParam::Text(v) if v == DEVICE_A));
        assert!(matches!(params[3], BindParam::Int(200)));
        assert!(matches!(params[4], BindParam::Int(0)));
    }

    #[test]
    fn listings_select_every_column_in_table_order() {
        let (sql, _) = sql_for("in:device_availability_history limit:5");
        let select = sql
            .strip_prefix("SELECT ")
            .and_then(|rest| rest.split(" FROM ").next())
            .expect("select list");
        let columns: Vec<&str> = select
            .split(", ")
            .map(|column| column.rsplit('.').next().unwrap().trim_matches('"'))
            .collect();
        assert_eq!(
            columns,
            [
                "device_uid",
                "changed_at",
                "to_state",
                "from_state",
                "from_since",
                "authority_class",
                "source_kind",
                "reporter_agent_id",
                "rule",
                "conflict",
                "created_at",
            ]
        );
    }

    #[test]
    fn every_entity_spelling_and_uid_alias_reads_device_uid() {
        for query in [
            format!("in:device_availability_history uid:{DEVICE_A}"),
            format!("in:device_availability_transitions device_uid:{DEVICE_A}"),
            format!("in:availability_history device_id:{DEVICE_A}"),
        ] {
            let (sql, params) = sql_for(&query);
            assert!(
                sql.contains(r#""device_availability_transitions"."device_uid" = $1"#),
                "{query}: {sql}"
            );
            assert_eq!(text_params(&params), [DEVICE_A], "{query}");
        }
    }

    #[test]
    fn a_uid_list_is_one_array_bind_and_a_negation_is_a_not_equal() {
        let (sql, params) = sql_for(&format!(
            "in:device_availability_history uid:({DEVICE_A},{DEVICE_B})"
        ));
        assert!(
            sql.contains(r#""device_availability_transitions"."device_uid" = ANY($1)"#),
            "{sql}"
        );
        assert!(
            matches!(&params[0], BindParam::TextArray(values) if values == &[DEVICE_A, DEVICE_B]),
            "{params:?}"
        );

        let (sql, params) = sql_for(&format!("in:device_availability_history !uid:{DEVICE_A}"));
        assert!(
            sql.contains(r#""device_availability_transitions"."device_uid" != $1"#),
            "{sql}"
        );
        assert_eq!(text_params(&params), [DEVICE_A]);
    }

    #[test]
    fn state_and_source_filters_bind_in_query_order() {
        let (sql, params) = sql_for(
            "in:device_availability_history from_state:available to_state:unavailable \
             source_kind:sweep authority_class:direct reporter_agent_id:agent-01 limit:5",
        );
        for column in [
            "from_state",
            "to_state",
            "source_kind",
            "authority_class",
            "reporter_agent_id",
        ] {
            assert!(
                sql.contains(&format!(
                    r#""device_availability_transitions"."{column}" = $"#
                )),
                "{column}: {sql}"
            );
        }
        assert_eq!(
            text_params(&params),
            ["available", "unavailable", "sweep", "direct", "agent-01"]
        );
        assert_eq!(params.len(), 7, "five filters plus limit and offset");
    }

    #[test]
    fn conflict_is_a_bound_boolean_with_equality_only() {
        let (sql, params) = sql_for("in:device_availability_history conflict:true limit:5");
        assert!(
            sql.contains(r#""device_availability_transitions"."conflict" = $1"#),
            "{sql}"
        );
        assert!(matches!(params[0], BindParam::Bool(true)), "{params:?}");

        let (sql, params) = sql_for("in:device_availability_history !conflict:false limit:5");
        assert!(
            sql.contains(r#""device_availability_transitions"."conflict" != $1"#),
            "{sql}"
        );
        assert!(matches!(params[0], BindParam::Bool(false)), "{params:?}");

        assert!(matches!(
            refused("in:device_availability_history conflict:maybe"),
            ServiceError::InvalidRequest(_)
        ));
        assert!(matches!(
            refused("in:device_availability_history conflict:(true,false)"),
            ServiceError::InvalidRequest(_)
        ));
    }

    #[test]
    fn with_no_sort_the_newest_change_comes_first() {
        let (sql, _) = sql_for("in:device_availability_history limit:5");
        assert!(
            sql.contains(r#"ORDER BY "device_availability_transitions"."changed_at" DESC"#),
            "{sql}"
        );
    }

    #[test]
    fn sort_terms_apply_in_order_and_unknown_ones_are_skipped() {
        let (sql, _) = sql_for(
            "in:device_availability_history sort:unknown:asc sort:changed_at:desc \
             sort:created_at:asc limit:5",
        );
        assert!(
            sql.contains(
                r#"ORDER BY "device_availability_transitions"."changed_at" DESC, "device_availability_transitions"."created_at" ASC"#
            ),
            "{sql}"
        );

        let (sql, _) = sql_for("in:device_availability_history sort:unknown:asc limit:5");
        assert!(
            sql.contains(r#"ORDER BY "device_availability_transitions"."changed_at" DESC"#),
            "{sql}"
        );
    }

    #[test]
    fn unknown_filter_fields_are_refused() {
        let err = refused("in:device_availability_history router_ip:192.0.2.1");
        assert!(
            matches!(&err, ServiceError::InvalidRequest(message) if message.contains("router_ip")),
            "{err:?}"
        );
    }

    #[test]
    fn aggregation_clauses_are_refused_by_name() {
        for (query, needle) in [
            (
                "in:device_availability_history stats:count() as n",
                "stats:",
            ),
            (
                "in:device_availability_history rollup_stats:availability",
                "rollup_stats:availability",
            ),
            ("in:device_availability_history bucket:5m", "bucket:"),
        ] {
            let err = refused(query);
            assert!(
                matches!(&err, ServiceError::InvalidRequest(message) if message.contains(needle)),
                "{query}: {err:?}"
            );
        }
    }
}
