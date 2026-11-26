//! `in:rum` (also spelled `in:rum_beacons` and `in:rum_beacon`) in the
//! StarRocks dialect.
//!
//! Reads `serviceradar.rum_beacons` (`priv/starrocks/0043_rum_beacons.sql`)
//! using the exact filter, sort, and `stats:` vocabulary defined in
//! `query/rum_beacons.rs`.

use super::super::filters_common::NumericValue;
use super::super::mtr_hops::{StatsOrderKey, resolve_stats_order};
use super::super::rum_beacons::{
    ParsedRumAgg, RUM_GROUP_BY_FIELDS, RumAggKind, RumBoolColumn, RumGroupDim, RumSortColumn,
    RumTextColumn, numeric_comparison, parse_bool, parse_rum_stats, pg_rum_column,
    refuse_unsupported_clauses, unsupported_filter,
};
use super::super::{PaginationMeta, QueryPlan, TranslateResponse, types::BindParam};
use super::{pg_order_sql, text_filter_sql};
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, Filter, FilterOp, OrderDirection},
};

const TABLE: &str = "rum_beacons";
const SECONDS_PER_DAY: i64 = 86_400;

const ROW_COLUMNS: &[&str] = &[
    "web_property_id",
    "observed_at",
    "beacon_id",
    "canonical_origin",
    "environment",
    "url",
    "host",
    "path",
    "metric_path",
    "referrer",
    "page_group",
    "initiator",
    "trace_id",
    "span_id",
    "session_id",
    "user_agent",
    "device_type",
    "browser",
    "os",
    "lcp_ms",
    "inp_ms",
    "cls",
    "fcp_ms",
    "ttfb_ms",
    "page_load_ms",
    "dns_ms",
    "connect_ms",
    "tls_ms",
    "dom_ready_ms",
    "rage_clicks",
    "js_errors",
    "http_status",
    "has_error",
    "cdn_provider",
    "cdn_cache_status",
    "cdn_edge_rtt_ms",
    "cdn_origin_rtt_ms",
    "cdn_pop",
    "server_timing_raw",
    "client_ip",
    "client_ip_anonymized",
    "country",
    "region",
    "city",
    "asn",
    "as_org",
    "prefix_tag",
    "attributes",
    "created_at",
];

pub(super) fn translate(plan: &QueryPlan, database: &str) -> Result<TranslateResponse> {
    if plan.entity != Entity::RumBeacons {
        return Err(ServiceError::Internal(anyhow::anyhow!(
            "the StarRocks RUM dialect was handed {:?}",
            plan.entity
        )));
    }
    refuse_unsupported_clauses(plan)?;

    let from = format!("{database}.{TABLE}");
    let (mut predicates, params) = time_bounds(plan);
    let is_stats = plan.stats.is_some();
    for filter in &plan.filters {
        predicates.push(if is_stats {
            stats_filter_sql(filter)?
        } else {
            row_filter_sql(filter)?
        });
    }
    let where_sql = if predicates.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", predicates.join(" AND "))
    };

    let sql = match &plan.stats {
        Some(stats) => {
            let (parsed, dims) = parse_rum_stats(stats.as_raw())?;
            let aggs = parsed.iter().map(rum_agg).collect::<Result<Vec<_>>>()?;
            let dims = dims.iter().map(rum_dim).collect::<Result<Vec<_>>>()?;
            stats_sql(plan, &from, &where_sql, &aggs, &dims)?
        }
        None => rows_sql(plan, &from, &where_sql),
    };

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
        viz: super::super::viz::meta_for_plan(plan),
    })
}

fn quoted(column: &str) -> String {
    format!("`{column}`")
}

fn time_bounds(plan: &QueryPlan) -> (Vec<String>, Vec<BindParam>) {
    let Some(range) = &plan.time_range else {
        return (Vec::new(), Vec::new());
    };
    let literal = |value: chrono::DateTime<chrono::Utc>| {
        format!("'{}'", value.format("%Y-%m-%d %H:%M:%S%.6f"))
    };
    (
        vec![
            format!("`observed_at` >= {}", literal(range.start)),
            format!("`observed_at` < {}", literal(range.end)),
        ],
        vec![
            BindParam::timestamptz(range.start),
            BindParam::timestamptz(range.end),
        ],
    )
}

fn row_filter_sql(filter: &Filter) -> Result<String> {
    let field = filter.field.as_str();
    if let Some(bool_col) = RumBoolColumn::for_field(field) {
        return bool_filter_sql(bool_col, filter);
    }
    if let Some(text_col) = RumTextColumn::for_field(field) {
        return text_filter_sql(&quoted(text_col.name()), filter, true);
    }
    numeric_filter_sql(filter)
}

fn stats_filter_sql(filter: &Filter) -> Result<String> {
    let field = filter.field.as_str();
    if let Some(bool_col) = RumBoolColumn::for_field(field) {
        return bool_filter_sql(bool_col, filter);
    }
    if let Some(text_col) = RumTextColumn::for_field(field) {
        filter.value.as_scalar()?;
        if !matches!(
            filter.op,
            FilterOp::Eq | FilterOp::NotEq | FilterOp::Like | FilterOp::NotLike
        ) {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported operator for '{field}' in rum stats"
            )));
        }
        return text_filter_sql(&quoted(text_col.name()), filter, false);
    }
    numeric_filter_sql(filter)
}

fn bool_filter_sql(col: RumBoolColumn, filter: &Filter) -> Result<String> {
    let value = parse_bool(filter.value.as_scalar()?)?;
    let op = match filter.op {
        FilterOp::Eq => "=",
        FilterOp::NotEq => "<>",
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "{} only supports equality comparisons",
                col.name()
            )));
        }
    };
    Ok(format!(
        "{} {op} {}",
        quoted(col.name()),
        if value { "TRUE" } else { "FALSE" }
    ))
}

fn numeric_filter_sql(filter: &Filter) -> Result<String> {
    let Some((col, cmp)) = numeric_comparison(filter)? else {
        return Err(unsupported_filter(&filter.field));
    };
    let literal = match cmp.value {
        NumericValue::Int4(v) => v.to_string(),
        NumericValue::Int8(v) => v.to_string(),
        NumericValue::Float8(v) => v.to_string(),
    };
    Ok(format!("{} {} {}", quoted(col), cmp.op_sql, literal))
}

fn rows_sql(plan: &QueryPlan, from: &str, where_sql: &str) -> String {
    let mut terms: Vec<String> = plan
        .order
        .iter()
        .filter_map(|clause| {
            RumSortColumn::for_field(clause.field.as_str())
                .map(|col| format!("{} {}", quoted(col.name()), pg_order_sql(clause.direction)))
        })
        .collect();

    if terms.is_empty() {
        terms.push(format!(
            "`observed_at` {}",
            pg_order_sql(OrderDirection::Desc)
        ));
        terms.push(format!(
            "`beacon_id` {}",
            pg_order_sql(OrderDirection::Desc)
        ));
    } else {
        let tie = plan
            .order
            .iter()
            .find(|c| RumSortColumn::for_field(&c.field) == Some(RumSortColumn::ObservedAt))
            .map_or(plan.order[0].direction, |c| c.direction);
        if !plan
            .order
            .iter()
            .any(|c| RumSortColumn::for_field(&c.field) == Some(RumSortColumn::ObservedAt))
        {
            terms.push(format!("`observed_at` {}", pg_order_sql(tie)));
        }
        terms.push(format!("`beacon_id` {}", pg_order_sql(tie)));
    }

    let select = ROW_COLUMNS
        .iter()
        .map(|c| quoted(c))
        .collect::<Vec<_>>()
        .join(", ");
    format!(
        "SELECT {select} FROM {from}{where_sql} ORDER BY {} LIMIT {} OFFSET {}",
        terms.join(", "),
        plan.limit,
        plan.offset
    )
}

struct Agg {
    expr: String,
    alias: String,
}

struct Dim {
    expr: String,
    alias: String,
    column: Option<&'static str>,
}

fn rum_agg(agg: &ParsedRumAgg) -> Result<Agg> {
    let expr = match agg.kind {
        RumAggKind::CountRows => "COUNT(*)".to_string(),
        RumAggKind::Column { function, column } => {
            let value = if pg_rum_column(column) == column {
                quoted(column)
            } else if column == "has_error" {
                "CAST(`has_error` AS INT)".to_string()
            } else {
                return Err(ServiceError::NotImplemented(format!(
                    "starrocks_unsupported_stats: no StarRocks rendering for rum column {column}"
                )));
            };
            format!("{function}({value})")
        }
        RumAggKind::Percentile75 { column } => {
            let value = if pg_rum_column(column) == column {
                quoted(column)
            } else if column == "has_error" {
                "CAST(`has_error` AS DOUBLE)".to_string()
            } else {
                return Err(ServiceError::NotImplemented(format!(
                    "starrocks_unsupported_stats: no StarRocks rendering for rum column {column}"
                )));
            };
            format!("percentile_cont({value}, 0.75)")
        }
    };
    Ok(Agg {
        expr,
        alias: agg.alias.clone(),
    })
}

fn time_bucket_sql(seconds: i64) -> Result<String> {
    if seconds <= 0 || SECONDS_PER_DAY % seconds != 0 {
        return Err(ServiceError::InvalidRequest(format!(
            "StarRocks RUM time buckets must divide a day evenly; {seconds}s would cut different bucket edges than CNPG"
        )));
    }
    Ok(format!(
        "time_slice(`observed_at`, INTERVAL {seconds} SECOND)"
    ))
}

fn rum_dim(dim: &RumGroupDim) -> Result<Dim> {
    Ok(match dim {
        RumGroupDim::Column(column) => Dim {
            expr: quoted(column),
            alias: (*column).to_string(),
            column: Some(column),
        },
        RumGroupDim::TimeBucket { seconds } => Dim {
            expr: time_bucket_sql(*seconds)?,
            alias: dim.alias().to_string(),
            column: None,
        },
    })
}

fn stats_sql(
    plan: &QueryPlan,
    from: &str,
    where_sql: &str,
    aggs: &[Agg],
    dims: &[Dim],
) -> Result<String> {
    let select = aggs
        .iter()
        .map(|agg| format!("{} AS {}", agg.expr, quoted(&agg.alias)))
        .chain(
            dims.iter()
                .map(|dim| format!("{} AS {}", dim.expr, quoted(&dim.alias))),
        )
        .collect::<Vec<_>>()
        .join(", ");
    let group_sql = if dims.is_empty() {
        String::new()
    } else {
        let group = dims
            .iter()
            .map(|dim| dim.expr.as_str())
            .collect::<Vec<_>>()
            .join(", ");
        format!(" GROUP BY {group}")
    };
    let grouped = format!("SELECT {select} FROM {from}{where_sql}{group_sql}");
    let page = format!("LIMIT {} OFFSET {}", plan.limit, plan.offset);

    if let Some(bucket) = dims.iter().find(|dim| dim.column.is_none()) {
        return Ok(format!(
            "SELECT * FROM ({grouped} ORDER BY {} DESC {page}) bucketed ORDER BY {} ASC",
            bucket.expr,
            quoted(&bucket.alias)
        ));
    }

    if dims.is_empty() {
        return Ok(format!("{grouped} {page}"));
    }

    let aliases = aggs
        .iter()
        .map(|agg| agg.alias.as_str())
        .collect::<Vec<_>>();
    let mut terms = Vec::new();
    for (key, direction) in resolve_stats_order(&plan.order, &aliases, RUM_GROUP_BY_FIELDS) {
        let expr = match key {
            StatsOrderKey::Agg(index) => aggs[index].expr.clone(),
            StatsOrderKey::Group(field) => dims
                .iter()
                .find(|dim| dim.column == Some(field))
                .map(|dim| dim.expr.clone())
                .ok_or_else(|| {
                    ServiceError::InvalidRequest(format!(
                        "stats ordering by '{field}' requires grouping by it"
                    ))
                })?,
        };
        terms.push(format!("{expr} {}", pg_order_sql(direction)));
    }
    let order = if terms.is_empty() {
        String::new()
    } else {
        format!(" ORDER BY {}", terms.join(", "))
    };
    Ok(format!("{grouped}{order} {page}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser;
    use crate::query::{QueryDirection, QueryRequest, build_query_plan};

    const DB: &str = "serviceradar";

    fn compile(query: &str) -> TranslateResponse {
        let config = crate::config::AppConfig::embedded("postgres://example/db".to_string());
        let request = QueryRequest {
            query: query.to_string(),
            limit: None,
            cursor: None,
            direction: QueryDirection::Next,
            mode: Some("starrocks".into()),
            permitted_signals: None,
        };
        let plan = build_query_plan(&config, &request, parser::parse(query).unwrap()).unwrap();
        super::super::translate(&plan, DB).unwrap()
    }

    #[test]
    fn rum_starrocks_compiles_rows_and_stats() {
        let rows = compile(
            "in:rum web_property_id:01JWEBPROP0000000000000001 has_error:false time:[2026-10-01T00:00:00Z,2026-10-01T01:00:00Z] sort:observed_at:desc limit:50",
        );
        assert!(rows.sql.contains("FROM serviceradar.rum_beacons"));
        assert!(rows.sql.contains("`has_error` = FALSE"));
        assert!(rows.sql.contains("ORDER BY `observed_at` DESC NULLS FIRST"));

        let stats = compile(
            "in:rum_beacons time:last_24h stats:\"count() as beacons, avg(lcp_ms) as avg_lcp by metric_path, time:1h\" limit:24",
        );
        assert!(
            stats
                .sql
                .contains("time_slice(`observed_at`, INTERVAL 3600 SECOND)")
        );
        assert!(stats.sql.contains("COUNT(*) AS `beacons`"));
    }

    #[test]
    fn rum_starrocks_compiles_p75_stats_and_grouped_queries() {
        let summary = compile(
            "in:rum time:last_24h stats:\"count() as beacons, p75(lcp_ms) as p75_lcp_ms, p75(inp_ms) as p75_inp_ms, p75(cls) as p75_cls, p75(cdn_edge_rtt_ms) as p75_edge_rtt_ms, sum(has_error) as error_beacons\" limit:1",
        );
        assert!(
            summary
                .sql
                .contains("percentile_cont(`lcp_ms`, 0.75) AS `p75_lcp_ms`")
        );
        assert!(
            summary
                .sql
                .contains("percentile_cont(`inp_ms`, 0.75) AS `p75_inp_ms`")
        );
        assert!(
            summary
                .sql
                .contains("SUM(CAST(`has_error` AS INT)) AS `error_beacons`")
        );

        let grouped = compile(
            "in:rum time:last_24h stats:\"count() as beacons, p75(cdn_edge_rtt_ms) as p75_edge_rtt_ms, p75(cdn_origin_rtt_ms) as p75_origin_rtt_ms by prefix_tag, asn, as_org\" sort:beacons:desc limit:100",
        );
        assert!(
            grouped
                .sql
                .contains("GROUP BY `prefix_tag`, `asn`, `as_org`")
        );
        assert!(grouped.sql.contains("ORDER BY COUNT(*) DESC"));
    }
}
