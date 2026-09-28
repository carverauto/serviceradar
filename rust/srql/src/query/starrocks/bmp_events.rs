//! `in:bmp_events` (also spelled `bmp_event` and `bmp_routing_events`) in the
//! StarRocks dialect.
//!
//! With the warehouse enabled EventWriter's AnalyticsSignals processor writes
//! BMP routing events only to `serviceradar.bmp_routing_events`
//! (`priv/starrocks/0022`), whose columns are those of the CNPG table plus the
//! same names. This module answers the queries the CNPG builder
//! (`query/bmp_events.rs`) answers, with the same rows:
//!
//! * A BMP query is always a row listing; `stats:` is refused on both backends
//!   (`reject_stats`). `rollup_stats:` is refused by the warehouse dialect but
//!   answered as a plain row listing by CNPG, and `bucket:` is refused by the
//!   warehouse dialect and by CNPG's downsample builder.
//! * Time bounds are the closed `[start, end]` CNPG binds, at microsecond
//!   precision.
//! * Text filters follow `apply_text_filter!`: equality and lists are exact,
//!   LIKE is ILIKE, and a negation keeps NULL rows. An empty list filters
//!   nothing, as on CNPG.
//! * `id` is a UUID compared exactly, `severity_id` is an i32 and
//!   `peer_asn`/`local_asn` are i64 with equality and ordered comparisons.
//! * Sort terms carry Postgres's NULL placement. Unknown sort fields are
//!   skipped, exactly as the CNPG builder skips them, and with no sort the
//!   newest rows come first (`time` DESC).

use super::super::bmp_events::refuse_unsupported_clauses;
use super::super::{PaginationMeta, QueryPlan, TranslateResponse, types::BindParam};
use super::{pg_order_sql, sql_literal, text_filter_sql};
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
};

/// Row projection of `in:bmp_events`: every column of
/// `schema::bmp_routing_events`, in that order, as the CNPG builder selects them.
const BMP_ROW_COLUMNS: &[&str] = &[
    "time",
    "id",
    "event_type",
    "severity_id",
    "router_id",
    "router_ip",
    "peer_ip",
    "peer_asn",
    "local_asn",
    "prefix",
    "message",
    "metadata",
    "raw_data",
    "created_at",
];

/// Text filter fields of `bmp_events` (`bmp_events::apply_filter`).
const TEXT_FIELDS: &[&str] = &[
    "event_type",
    "router_id",
    "router_ip",
    "peer_ip",
    "prefix",
    "message",
    "raw_data",
];

pub(super) fn translate(plan: &QueryPlan, database: &str) -> Result<TranslateResponse> {
    if plan.entity != Entity::BmpEvents {
        return Err(ServiceError::Internal(anyhow::anyhow!(
            "the StarRocks BMP dialect was handed {:?}",
            plan.entity
        )));
    }
    refuse_unsupported_clauses(plan)?;

    let from = format!("{database}.bmp_routing_events");
    let (mut predicates, params) = time_bounds(plan);
    for filter in &plan.filters {
        if let Some(predicate) = bmp_filter(filter)? {
            predicates.push(predicate);
        }
    }
    let where_sql = if predicates.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", predicates.join(" AND "))
    };

    let sql = rows_sql(plan, &from, &where_sql);

    Ok(TranslateResponse {
        sql,
        params,
        pagination: PaginationMeta {
            next_cursor: None,
            prev_cursor: None,
            limit: Some(plan.limit),
        },
        viz: None,
    })
}

fn quoted(column: &str) -> String {
    format!("`{column}`")
}

/// `[start, end]`, the bounds CNPG binds, as naive UTC `DATETIME` literals with
/// microseconds. No `time:` means no bound, as on CNPG.
fn time_bounds(plan: &QueryPlan) -> (Vec<String>, Vec<BindParam>) {
    let Some(range) = &plan.time_range else {
        return (Vec::new(), Vec::new());
    };
    let literal = |value: chrono::DateTime<chrono::Utc>| {
        format!("'{}'", value.format("%Y-%m-%d %H:%M:%S%.6f"))
    };
    (
        vec![
            format!("`time` >= {}", literal(range.start)),
            format!("`time` <= {}", literal(range.end)),
        ],
        vec![
            BindParam::timestamptz(range.start),
            BindParam::timestamptz(range.end),
        ],
    )
}

/// One filter, as the CNPG builder writes it. The parser refuses an empty
/// `in:`/`!in:` list before either dialect runs, so no empty-list arm is needed.
fn bmp_filter(filter: &Filter) -> Result<Option<String>> {
    let field = filter.field.as_str();
    if TEXT_FIELDS.contains(&field) {
        return text_filter_sql(&quoted(field), filter, true).map(Some);
    }
    match field {
        "id" => {
            let uuid = parse_uuid(filter.value.as_scalar()?)?;
            let op = match filter.op {
                FilterOp::Eq => "=",
                FilterOp::NotEq => "<>",
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "id only supports equality comparisons".into(),
                    ));
                }
            };
            Ok(Some(format!(
                "`id` {op} {}",
                sql_literal(&uuid.to_string())
            )))
        }
        "severity_id" => numeric_filter(field, filter, parse_i32).map(Some),
        "peer_asn" | "local_asn" => numeric_filter(field, filter, parse_i64).map(Some),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for bmp_events: '{other}'"
        ))),
    }
}

/// Equality and ordered comparisons, as `bmp_events::apply_filter` writes them
/// for `severity_id`, `peer_asn` and `local_asn`.
fn numeric_filter(
    field: &str,
    filter: &Filter,
    parse: fn(&str) -> Result<String>,
) -> Result<String> {
    let value = parse(filter.value.as_scalar()?)?;
    let op = match filter.op {
        FilterOp::Eq => "=",
        FilterOp::NotEq => "<>",
        FilterOp::Gt => ">",
        FilterOp::Gte => ">=",
        FilterOp::Lt => "<",
        FilterOp::Lte => "<=",
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "{field} only supports scalar numeric operators"
            )));
        }
    };
    Ok(format!("`{field}` {op} {value}"))
}

fn parse_i32(raw: &str) -> Result<String> {
    raw.parse::<i32>()
        .map(|value| value.to_string())
        .map_err(|_| ServiceError::InvalidRequest(format!("invalid integer '{raw}'")))
}

fn parse_i64(raw: &str) -> Result<String> {
    raw.parse::<i64>()
        .map(|value| value.to_string())
        .map_err(|_| ServiceError::InvalidRequest(format!("invalid integer '{raw}'")))
}

fn parse_uuid(raw: &str) -> Result<uuid::Uuid> {
    uuid::Uuid::parse_str(raw)
        .map_err(|_| ServiceError::InvalidRequest(format!("invalid uuid '{raw}'")))
}

/// `bmp_events::apply_ordering`: the recognized terms in the order given, with
/// no sort defaulting to newest first (`time` DESC). Unknown fields are
/// skipped, exactly as the CNPG builder skips them.
fn rows_sql(plan: &QueryPlan, from: &str, where_sql: &str) -> String {
    let mut terms = Vec::new();
    for clause in &plan.order {
        if let Some(column) = sort_column(clause) {
            terms.push(format!(
                "{} {}",
                quoted(column),
                pg_order_sql(clause.direction)
            ));
        }
    }
    if plan.order.is_empty() {
        terms.push(format!("`time` {}", pg_order_sql(OrderDirection::Desc)));
    }
    let select = BMP_ROW_COLUMNS
        .iter()
        .map(|column| quoted(column))
        .collect::<Vec<_>>()
        .join(", ");
    let order = if terms.is_empty() {
        String::new()
    } else {
        format!(" ORDER BY {}", terms.join(", "))
    };
    format!(
        "SELECT {select} FROM {from}{where_sql}{order} LIMIT {} OFFSET {}",
        plan.limit, plan.offset
    )
}

fn sort_column(clause: &OrderClause) -> Option<&'static str> {
    Some(match clause.field.as_str() {
        "time" | "event_timestamp" | "timestamp" => "time",
        "created_at" => "created_at",
        "severity_id" => "severity_id",
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser;
    use crate::query::{QueryDirection, QueryRequest, build_query_plan};

    const DB: &str = "serviceradar";

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

    fn compile(query: &str) -> String {
        super::super::translate(&plan(query), DB)
            .unwrap_or_else(|err| panic!("{query} must compile for StarRocks: {err}"))
            .sql
    }

    fn refused(query: &str) -> ServiceError {
        match super::super::translate(&plan(query), DB) {
            Ok(compiled) => panic!("{query} must be refused, compiled to: {}", compiled.sql),
            Err(err) => err,
        }
    }

    /// The CNPG half of the same query. A listing reaches the `bmp_events`
    /// entity builder; a `bucket:` query is routed to the downsample builder,
    /// which refuses BMP, exactly as `translate_request` routes it.
    fn cnpg(query: &str) -> Result<String> {
        let plan = plan(query);
        if plan.downsample.is_some() {
            return super::super::super::downsample::to_sql_and_params(&plan).map(|(sql, _)| sql);
        }
        super::super::super::bmp_events::to_sql_and_params(&plan).map(|(sql, _)| sql)
    }

    /// The queries the BMP page issues, through its generic SRQL list loader.
    const PRODUCT_QUERIES: &[&str] = &[
        "in:bmp_events time:last_1h",
        "in:bmp_events time:last_24h sort:time:desc limit:50",
        "in:bmp_events router_ip:192.0.2.10 time:last_1h",
        "in:bmp_events event_type:route_update time:last_1h sort:time:desc",
    ];

    #[test]
    fn every_product_query_compiles_on_both_backends() {
        for query in PRODUCT_QUERIES {
            let sql = compile(query);
            assert!(
                sql.contains(" FROM serviceradar.bmp_routing_events"),
                "{query}: {sql}"
            );
            assert!(!sql.contains("::"), "no Postgres casts: {sql}");
            assert!(!sql.contains("jsonb"), "no Postgres payload: {sql}");
            assert!(!sql.contains("ILIKE"), "no Postgres ILIKE: {sql}");
            cnpg(query).unwrap_or_else(|err| panic!("{query} must compile for CNPG: {err}"));
        }
    }

    #[test]
    fn listings_project_exactly_the_columns_cnpg_selects() {
        let warehouse = select_columns(&compile("in:bmp_events time:last_1h limit:5"));
        let relational = select_columns(&cnpg("in:bmp_events time:last_1h limit:5").expect("cnpg"));
        assert_eq!(warehouse, relational);
        assert_eq!(
            warehouse,
            BMP_ROW_COLUMNS
                .iter()
                .map(|c| c.to_string())
                .collect::<Vec<_>>()
        );
    }

    /// The column names of a SELECT list, from either dialect's quoting.
    fn select_columns(sql: &str) -> Vec<String> {
        let select = sql
            .strip_prefix("SELECT ")
            .and_then(|rest| rest.split(" FROM ").next())
            .expect("select list");
        select
            .split(", ")
            .map(|column| {
                column
                    .rsplit('.')
                    .next()
                    .unwrap_or(column)
                    .trim_matches(|c| c == '`' || c == '"')
                    .to_string()
            })
            .collect()
    }

    #[test]
    fn a_listing_with_no_sort_is_newest_first() {
        let sql = compile("in:bmp_events time:last_1h limit:5");
        assert!(
            sql.ends_with(" ORDER BY `time` DESC NULLS FIRST LIMIT 5 OFFSET 0"),
            "{sql}"
        );
        assert!(
            sql.starts_with(
                "SELECT `time`, `id`, `event_type`, `severity_id`, `router_id`, `router_ip`, `peer_ip`, `peer_asn`, `local_asn`, `prefix`, `message`, `metadata`, `raw_data`, `created_at` FROM serviceradar.bmp_routing_events"
            ),
            "{sql}"
        );
    }

    #[test]
    fn time_bounds_are_closed_as_on_cnpg() {
        let sql = compile("in:bmp_events time:last_1h limit:5");
        assert!(sql.contains("`time` >= '"), "{sql}");
        assert!(sql.contains("`time` <= '"), "{sql}");
    }

    #[test]
    fn a_text_negation_keeps_null_rows() {
        let sql = compile("in:bmp_events !router_ip:192.0.2.10 limit:5");
        assert!(
            sql.contains("(`router_ip` IS NULL OR `router_ip` != '192.0.2.10')"),
            "{sql}"
        );
    }

    #[test]
    fn like_is_case_insensitive_and_values_are_escaped() {
        // `message` is an implicit-ILIKE field, so a `%` value is a LIKE filter.
        let sql = compile("in:bmp_events message:%Routing% limit:5");
        assert!(sql.contains("LOWER(`message`) LIKE '%routing%'"), "{sql}");
        let sql = compile(r#"in:bmp_events prefix:"198.51.100.0/24" limit:5"#);
        assert!(sql.contains("`prefix` = '198.51.100.0/24'"), "{sql}");
    }

    #[test]
    fn id_is_matched_as_cnpg_matches_it() {
        let upper = "8E1C1F3A-0000-4000-8000-000000000001";
        let sql = compile(&format!("in:bmp_events id:{upper} limit:5"));
        assert!(
            sql.contains("`id` = '8e1c1f3a-0000-4000-8000-000000000001'"),
            "{sql}"
        );
        assert!(matches!(
            refused("in:bmp_events id:not-a-uuid limit:5"),
            ServiceError::InvalidRequest(_)
        ));
        assert!(matches!(
            refused("in:bmp_events id:>x limit:5"),
            ServiceError::InvalidRequest(_)
        ));
    }

    #[test]
    fn numeric_filters_compare_typed_literals() {
        let sql = compile("in:bmp_events severity_id:>=4 peer_asn:64512 local_asn:<100 limit:5");
        assert!(sql.contains("`severity_id` >= 4"), "{sql}");
        assert!(sql.contains("`peer_asn` = 64512"), "{sql}");
        assert!(sql.contains("`local_asn` < 100"), "{sql}");
    }

    #[test]
    fn stats_and_bucket_are_refused_on_both_backends() {
        for query in [
            "in:bmp_events stats:count() as n",
            "in:bmp_events bucket:5m",
        ] {
            assert!(
                matches!(refused(query), ServiceError::InvalidRequest(_)),
                "{query}"
            );
            assert!(cnpg(query).is_err(), "{query} must be refused by CNPG too");
        }
    }

    #[test]
    fn rollup_stats_is_a_warehouse_only_refusal() {
        let query = "in:bmp_events rollup_stats:severity";
        assert!(
            matches!(refused(query), ServiceError::InvalidRequest(_)),
            "{query} must be refused by the warehouse dialect"
        );
        cnpg(query).unwrap_or_else(|err| panic!("{query} must list rows on CNPG: {err}"));
    }

    #[test]
    fn unknown_sort_fields_are_skipped_as_cnpg_skips_them() {
        let sql = compile("in:bmp_events sort:unknown:asc limit:5");
        assert!(!sql.contains("ORDER BY"), "{sql}");
        let sql = compile("in:bmp_events sort:unknown:asc sort:time:desc limit:5");
        assert!(
            sql.ends_with(" ORDER BY `time` DESC NULLS FIRST LIMIT 5 OFFSET 0"),
            "{sql}"
        );
    }

    #[test]
    fn sort_fields_carry_postgres_null_placement() {
        let sql = compile("in:bmp_events sort:severity_id:asc limit:5");
        assert!(
            sql.ends_with(" ORDER BY `severity_id` ASC NULLS LAST LIMIT 5 OFFSET 0"),
            "{sql}"
        );
        let sql = compile("in:bmp_events sort:time:desc sort:severity_id:asc limit:5");
        assert!(
            sql.ends_with(
                " ORDER BY `time` DESC NULLS FIRST, `severity_id` ASC NULLS LAST LIMIT 5 OFFSET 0"
            ),
            "{sql}"
        );
    }

    /// Both backends accept and refuse the same BMP queries, except that
    /// `rollup_stats:` is a warehouse-only refusal: CNPG answers it as a plain
    /// row listing.
    #[test]
    fn both_backends_accept_the_same_queries() {
        let mut corpus: Vec<String> = PRODUCT_QUERIES.iter().map(|q| q.to_string()).collect();
        for field in TEXT_FIELDS {
            for value in ["edge-a", "%edge%", "(edge-a,edge-b)"] {
                corpus.push(format!("in:bmp_events {field}:{value} limit:5"));
                corpus.push(format!("in:bmp_events !{field}:{value} limit:5"));
            }
        }
        for field in ["severity_id", "peer_asn", "local_asn"] {
            for value in ["1", ">1", "<=5", "=3"] {
                corpus.push(format!("in:bmp_events {field}:{value} limit:5"));
            }
            corpus.push(format!("in:bmp_events {field}:not-a-number limit:5"));
        }
        for sort in ["time", "timestamp", "created_at", "severity_id", "unknown"] {
            corpus.push(format!("in:bmp_events sort:{sort}:desc limit:5"));
        }
        corpus.extend(
            [
                "in:bmp_events id:8e1c1f3a-0000-4000-8000-000000000001 limit:5",
                "in:bmp_events id:not-a-uuid limit:5",
                "in:bmp_events unknown_field:x limit:5",
                "in:bmp_events stats:count() as n",
                "in:bmp_events rollup_stats:severity",
                "in:bmp_events bucket:5m",
                "in:bmp_events event_type:(route_update,peer_down) limit:5",
                "in:bmp_events message:%routing% limit:5",
                "in:bmp_events !message:%routing% limit:5",
            ]
            .map(String::from),
        );

        let warehouse_only_refusals = ["in:bmp_events rollup_stats:severity"];

        let mut mismatches = Vec::new();
        for query in &corpus {
            let warehouse = super::super::translate(&plan(query), DB);
            let relational = cnpg(query);
            if warehouse_only_refusals.contains(&query.as_str()) {
                assert!(
                    matches!(&warehouse, Err(ServiceError::InvalidRequest(_))),
                    "{query} must be refused by the warehouse dialect"
                );
                assert!(relational.is_ok(), "{query} must list rows on CNPG");
                continue;
            }
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
