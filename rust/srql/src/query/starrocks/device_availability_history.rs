//! `in:device_availability_history` (also spelled `device_availability_transitions`
//! and `availability_history`) in the StarRocks dialect.
//!
//! With the warehouse enabled EventWriter's AvailabilityTransitions processor
//! writes the merged availability history only to
//! `serviceradar.device_availability_transitions` (`priv/starrocks/0042`), with
//! the CNPG table's column names. This module answers the queries the CNPG
//! builder (`query/device_availability_history.rs`) answers, with the same rows:
//!
//! * The entity is a row listing; `stats:`, `rollup_stats:`, `bucket:` and
//!   `other:true` are refused by both backends through the shared
//!   `refuse_unsupported_clauses`.
//! * Time bounds apply to `changed_at` and are the closed `[start, end]` CNPG
//!   binds, at microsecond precision.
//! * Filter fields and sort fields resolve through the CNPG builder's
//!   `TextColumn`/`SortColumn`, so both dialects accept the same vocabulary.
//!   Text filters follow `apply_text_filter!`: equality and lists are exact,
//!   LIKE is ILIKE, and a negation keeps NULL rows. `conflict` is a boolean
//!   with equality only.
//! * Sort terms carry Postgres's NULL placement. Unknown sort fields are
//!   skipped, as the CNPG builder skips them, and with no recognized sort the
//!   newest change comes first (`changed_at` DESC).

use super::super::device_availability_history::{
    CONFLICT_FIELD, SortColumn, TextColumn, conflict_op_error, parse_conflict,
    refuse_unsupported_clauses, unsupported_filter,
};
use super::super::{PaginationMeta, QueryPlan, TranslateResponse, types::BindParam};
use super::{pg_order_sql, text_filter_sql};
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, Filter, FilterOp, OrderDirection},
};

const TABLE: &str = "device_availability_transitions";

/// Row projection: every column of `schema::device_availability_transitions`,
/// in that order, as the CNPG builder selects them.
const ROW_COLUMNS: &[&str] = &[
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
];

pub(super) fn translate(plan: &QueryPlan, database: &str) -> Result<TranslateResponse> {
    if plan.entity != Entity::DeviceAvailabilityHistory {
        return Err(ServiceError::Internal(anyhow::anyhow!(
            "the StarRocks availability-history dialect was handed {:?}",
            plan.entity
        )));
    }
    refuse_unsupported_clauses(plan)?;

    let (mut predicates, params) = time_bounds(plan);
    for filter in &plan.filters {
        predicates.push(filter_sql(filter)?);
    }
    let where_sql = if predicates.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", predicates.join(" AND "))
    };

    let select = ROW_COLUMNS
        .iter()
        .map(|column| quoted(column))
        .collect::<Vec<_>>()
        .join(", ");
    let sql = format!(
        "SELECT {select} FROM {database}.{TABLE}{where_sql}{} LIMIT {} OFFSET {}",
        order_sql(plan),
        plan.limit,
        plan.offset
    );

    Ok(TranslateResponse {
        read_model: None,
        sql,
        params,
        pagination: PaginationMeta {
            next_cursor: None,
            prev_cursor: None,
            limit: Some(plan.limit),
            keyset: None,
        },
        viz: None,
    })
}

fn quoted(column: &str) -> String {
    format!("`{column}`")
}

/// `[start, end]` on `changed_at`, the bounds CNPG binds, as naive UTC
/// `DATETIME` literals with microseconds. No `time:` means no bound, as on CNPG.
fn time_bounds(plan: &QueryPlan) -> (Vec<String>, Vec<BindParam>) {
    let Some(range) = &plan.time_range else {
        return (Vec::new(), Vec::new());
    };
    let literal = |value: chrono::DateTime<chrono::Utc>| {
        format!("'{}'", value.format("%Y-%m-%d %H:%M:%S%.6f"))
    };
    (
        vec![
            format!("`changed_at` >= {}", literal(range.start)),
            format!("`changed_at` <= {}", literal(range.end)),
        ],
        vec![
            BindParam::timestamptz(range.start),
            BindParam::timestamptz(range.end),
        ],
    )
}

/// One filter, as the CNPG builder writes it. The parser refuses an empty
/// `in:`/`!in:` list before either dialect runs.
fn filter_sql(filter: &Filter) -> Result<String> {
    let field = filter.field.as_str();
    if field == CONFLICT_FIELD {
        let value = parse_conflict(filter)?;
        let op = match filter.op {
            FilterOp::Eq => "=",
            FilterOp::NotEq => "<>",
            _ => return Err(conflict_op_error()),
        };
        return Ok(format!(
            "`conflict` {op} {}",
            if value { "TRUE" } else { "FALSE" }
        ));
    }
    let column = TextColumn::for_field(field).ok_or_else(|| unsupported_filter(field))?;
    text_filter_sql(&quoted(column.name()), filter, true)
}

/// The recognized sort terms in the order given; with no recognized term,
/// newest first, as the CNPG builder orders it.
fn order_sql(plan: &QueryPlan) -> String {
    let mut terms: Vec<String> = plan
        .order
        .iter()
        .filter_map(|clause| {
            SortColumn::for_field(clause.field.as_str()).map(|column| {
                format!(
                    "{} {}",
                    quoted(column.name()),
                    pg_order_sql(clause.direction)
                )
            })
        })
        .collect();
    if terms.is_empty() {
        terms.push(format!(
            "`changed_at` {}",
            pg_order_sql(OrderDirection::Desc)
        ));
    }
    format!(" ORDER BY {}", terms.join(", "))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser;
    use crate::query::{QueryDirection, QueryRequest, build_query_plan};

    const DB: &str = "serviceradar";
    const DEVICE_A: &str = "sr:00000000-0000-4000-8000-000000000001";
    const DEVICE_B: &str = "sr:00000000-0000-4000-8000-000000000002";

    fn plan(query: &str) -> QueryPlan {
        let config = crate::config::AppConfig::embedded("postgres://example/db".to_string());
        let request = QueryRequest {
            query: query.to_string(),
            limit: None,
            cursor: None,
            direction: QueryDirection::Next,
            mode: Some("starrocks".into()),
            permitted_signals: None,
        };
        build_query_plan(&config, &request, parser::parse(query).expect("parse")).expect("plan")
    }

    fn compile(query: &str) -> TranslateResponse {
        super::super::translate(&plan(query), DB)
            .unwrap_or_else(|err| panic!("{query} must compile for StarRocks: {err}"))
    }

    fn refused(query: &str) -> ServiceError {
        match super::super::translate(&plan(query), DB) {
            Ok(compiled) => panic!("{query} must be refused, compiled to: {}", compiled.sql),
            Err(err) => err,
        }
    }

    fn cnpg(query: &str) -> Result<String> {
        super::super::super::device_availability_history::to_sql_and_params(&plan(query))
            .map(|(sql, _)| sql)
    }

    /// The device page's query reaches the warehouse table through the
    /// StarRocks entry point, with the window, the device and the page inline.
    #[test]
    fn the_device_page_query_compiles_to_the_warehouse_table() {
        let compiled = compile(&format!(
            r#"in:device_availability_history uid:"{DEVICE_A}" time:[2026-01-01T00:00:00Z,2026-01-02T00:00:00Z] sort:changed_at:desc limit:200"#
        ));
        assert_eq!(
            compiled.sql,
            format!(
                "SELECT `device_uid`, `changed_at`, `to_state`, `from_state`, `from_since`, \
                 `authority_class`, `source_kind`, `reporter_agent_id`, `rule`, `conflict`, \
                 `created_at` FROM serviceradar.device_availability_transitions \
                 WHERE `changed_at` >= '2026-01-01 00:00:00.000000' \
                 AND `changed_at` <= '2026-01-02 00:00:00.000000' \
                 AND `device_uid` = '{DEVICE_A}' \
                 ORDER BY `changed_at` DESC NULLS FIRST LIMIT 200 OFFSET 0"
            )
        );
        assert_eq!(compiled.params.len(), 2, "{:?}", compiled.params);
        assert!(
            matches!(&compiled.params[0], BindParam::Timestamptz(v) if v.starts_with("2026-01-01T00:00:00"))
        );
    }

    #[test]
    fn a_listing_with_no_sort_is_newest_first() {
        let sql = compile("in:availability_history limit:5").sql;
        assert!(
            sql.ends_with(" ORDER BY `changed_at` DESC NULLS FIRST LIMIT 5 OFFSET 0"),
            "{sql}"
        );
        assert!(!sql.contains(" WHERE "), "{sql}");
    }

    #[test]
    fn uid_lists_negations_and_text_filters_match_cnpg_semantics() {
        let sql = compile(&format!(
            "in:device_availability_transitions uid:({DEVICE_A},{DEVICE_B}) limit:5"
        ))
        .sql;
        assert!(
            sql.contains(&format!("`device_uid` IN ('{DEVICE_A}', '{DEVICE_B}')")),
            "{sql}"
        );

        let sql = compile(&format!(
            "in:device_availability_history !device_uid:{DEVICE_A} limit:5"
        ))
        .sql;
        assert!(
            sql.contains(&format!(
                "(`device_uid` IS NULL OR `device_uid` != '{DEVICE_A}')"
            )),
            "{sql}"
        );

        let sql = compile(
            "in:device_availability_history from_state:available to_state:unavailable \
             source_kind:sweep authority_class:direct reporter_agent_id:agent-01 limit:5",
        )
        .sql;
        for predicate in [
            "`from_state` = 'available'",
            "`to_state` = 'unavailable'",
            "`source_kind` = 'sweep'",
            "`authority_class` = 'direct'",
            "`reporter_agent_id` = 'agent-01'",
        ] {
            assert!(sql.contains(predicate), "{predicate}: {sql}");
        }
    }

    #[test]
    fn conflict_is_a_boolean_literal() {
        let sql = compile("in:device_availability_history conflict:true limit:5").sql;
        assert!(sql.contains("`conflict` = TRUE"), "{sql}");
        let sql = compile("in:device_availability_history !conflict:true limit:5").sql;
        assert!(sql.contains("`conflict` <> TRUE"), "{sql}");
    }

    #[test]
    fn sort_terms_carry_postgres_null_placement_and_unknown_ones_are_skipped() {
        let sql = compile(
            "in:device_availability_history sort:unknown:asc sort:changed_at:desc \
             sort:created_at:asc limit:5",
        )
        .sql;
        assert!(
            sql.ends_with(
                " ORDER BY `changed_at` DESC NULLS FIRST, `created_at` ASC NULLS LAST LIMIT 5 OFFSET 0"
            ),
            "{sql}"
        );
        let sql = compile("in:device_availability_history sort:unknown:asc limit:5").sql;
        assert!(
            sql.ends_with(" ORDER BY `changed_at` DESC NULLS FIRST LIMIT 5 OFFSET 0"),
            "{sql}"
        );
    }

    #[test]
    fn aggregation_clauses_are_refused() {
        for query in [
            "in:device_availability_history stats:count() as n",
            "in:device_availability_history rollup_stats:availability",
            "in:device_availability_history bucket:5m",
        ] {
            assert!(
                matches!(refused(query), ServiceError::InvalidRequest(_)),
                "{query}"
            );
        }
    }

    /// Both backends accept and refuse the same queries.
    #[test]
    fn both_backends_accept_the_same_queries() {
        let mut corpus: Vec<String> = Vec::new();
        for field in [
            "uid",
            "device_uid",
            "from_state",
            "to_state",
            "source_kind",
            "authority_class",
            "reporter_agent_id",
            "rule",
        ] {
            for value in ["available", "%avail%", "(available,unknown)"] {
                corpus.push(format!(
                    "in:device_availability_history {field}:{value} limit:5"
                ));
                corpus.push(format!(
                    "in:device_availability_history !{field}:{value} limit:5"
                ));
            }
        }
        for value in ["true", "false", "maybe", "(true,false)"] {
            corpus.push(format!(
                "in:device_availability_history conflict:{value} limit:5"
            ));
        }
        for sort in ["changed_at", "time", "created_at", "uid", "unknown"] {
            corpus.push(format!(
                "in:device_availability_history sort:{sort}:asc limit:5"
            ));
        }
        corpus.extend(
            [
                "in:device_availability_history time:last_24h limit:5",
                "in:device_availability_history router_ip:192.0.2.1 limit:5",
                "in:device_availability_history stats:count() as n",
                "in:device_availability_history rollup_stats:availability",
                "in:device_availability_history bucket:5m",
            ]
            .map(String::from),
        );

        let mut mismatches = Vec::new();
        for query in &corpus {
            let warehouse = super::super::translate(&plan(query), DB);
            let relational = cnpg(query);
            if warehouse.is_ok() != relational.is_ok() {
                mismatches.push(format!(
                    "{query}\n  starrocks: {:?}\n  cnpg: {:?}",
                    warehouse.map(|c| c.sql),
                    relational
                ));
            }
        }
        assert!(mismatches.is_empty(), "{}", mismatches.join("\n"));
    }
}
