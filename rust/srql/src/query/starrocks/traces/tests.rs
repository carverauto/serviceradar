use super::*;
use crate::parser;
use crate::query::{QueryDirection, QueryRequest, build_query_plan};

const DB: &str = "serviceradar";
const TRACE: &str = "0123456789abcdef0123456789abcdef";

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

fn compile_raw(query: &str) -> String {
    super::super::translate_raw(&plan(query), DB)
        .unwrap_or_else(|err| panic!("{query} must compile for StarRocks raw: {err}"))
        .sql
}

fn refused(query: &str) -> ServiceError {
    match super::super::translate(&plan(query), DB) {
        Ok(compiled) => panic!("{query} must be refused, compiled to: {}", compiled.sql),
        Err(err) => err,
    }
}

/// The CNPG half of the same query, through the builders that serve it when
/// the warehouse is off.
fn cnpg(query: &str) -> Result<String> {
    let plan = plan(query);
    match plan.entity {
        Entity::Traces => traces::to_sql_and_params(&plan),
        Entity::TraceSummaries => trace_summaries::to_sql_and_params(&plan),
        _ => unreachable!("not a traces query: {query}"),
    }
    .map(|(sql, _)| sql)
}

/// The column names of a SELECT list, from either dialect's quoting.
fn select_columns(sql: &str) -> Vec<String> {
    let select = sql
        .trim_start()
        .strip_prefix("SELECT")
        .and_then(|rest| rest.split("FROM").next())
        .expect("select list");
    select
        .split(',')
        .map(|column| {
            column
                .trim()
                .rsplit('.')
                .next()
                .unwrap_or(column)
                .trim_matches(|c| c == '`' || c == '"')
                .to_string()
        })
        .filter(|column| !column.is_empty())
        .collect()
}

/// What the product sends: the dashboard and logs-page trace cards, the
/// metrics RED card, the traces tab (list, sorts, error filters, multi-span
/// toggle, service filter), its span fallback, the trace detail page and
/// onboarding.
const PRODUCT_QUERIES: &[&str] = &[
    "in:otel_traces time:last_24h rollup_stats:summary",
    "in:otel_traces time:last_24h service_name:(svc-a,svc-b) rollup_stats:summary",
    "in:otel_traces time:last_24h rollup_stats:red",
    "in:otel_traces time:last_24h service_name:svc-a rollup_stats:red",
    r#"in:otel_trace_summaries time:last_24h stats:"count() as total""#,
    r#"in:otel_trace_summaries time:last_24h error_count:>0 stats:"count() as total""#,
    r#"in:otel_trace_summaries time:last_24h service_name:"svc-a" stats:"count() as total""#,
    "in:otel_trace_summaries time:last_24h sort:timestamp:desc limit:100",
    "in:otel_trace_summaries time:last_24h span_count:>1 sort:duration_ms:desc limit:100",
    "in:otel_trace_summaries time:last_24h error_count:0 sort:span_count:asc limit:100",
    "in:otel_trace_summaries time:last_24h service_name:(svc-a,svc-b) sort:timestamp:desc limit:100",
    "in:otel_trace_summaries trace_id:\"0123456789abcdef0123456789abcdef\" limit:1",
    "in:traces time:last_24h sort:timestamp:desc limit:100",
    "in:traces trace_id:\"0123456789abcdef0123456789abcdef\" sort:start_time_unix_nano:asc limit:1000",
    "in:traces service_name:\"svc-a\" time:last_15m limit:1",
    "in:traces status_code:2 time:last_1h sort:timestamp:desc",
];

#[test]
fn every_product_query_compiles_on_both_backends() {
    for query in PRODUCT_QUERIES {
        let sql = compile(query);
        assert!(!sql.contains("::"), "no Postgres casts: {sql}");
        assert!(!sql.contains("jsonb"), "no Postgres payload: {sql}");
        assert!(!sql.contains("ILIKE"), "no Postgres ILIKE: {sql}");
        assert!(
            !sql.contains("@>") && !sql.contains("&&"),
            "no array operators: {sql}"
        );
        cnpg(query).unwrap_or_else(|err| panic!("{query} must compile for CNPG: {err}"));
    }
}

#[test]
fn listings_project_exactly_the_columns_cnpg_selects() {
    for query in ["in:traces limit:5", "in:otel_trace_summaries limit:5"] {
        let warehouse = select_columns(&compile(query));
        let relational = select_columns(&cnpg(query).expect("cnpg"));
        assert_eq!(warehouse, relational, "{query}");
    }
}

#[test]
fn a_trace_is_listed_in_waterfall_order_and_a_window_newest_first() {
    let by_id = compile(&format!("in:traces trace_id:\"{TRACE}\" limit:1000"));
    assert!(
        by_id.contains(&format!("`trace_id` = '{TRACE}'")),
        "{by_id}"
    );
    assert!(
        by_id.contains("ORDER BY `start_time_unix_nano` ASC NULLS LAST, `trace_id` ASC NULLS LAST, `span_id` ASC NULLS LAST, `timestamp` ASC NULLS LAST"),
        "{by_id}"
    );
    let window = compile("in:traces time:last_1h limit:5");
    assert!(
        window.contains("ORDER BY `timestamp` DESC NULLS FIRST, `trace_id` DESC NULLS FIRST, `span_id` DESC NULLS FIRST LIMIT 5"),
        "{window}"
    );
}

#[test]
fn span_negations_keep_null_rows_and_summary_negations_drop_them() {
    assert!(
        compile("in:traces !span_name:checkout limit:5")
            .contains("(`name` IS NULL OR `name` <> 'checkout')")
    );
    assert!(
        compile("in:otel_trace_summaries !root_span_name:checkout limit:5")
            .contains("WHERE `root_span_name` <> 'checkout'")
    );
    // Diesel's `<>` on an integer drops NULL rows too.
    assert!(compile("in:traces !status_code:2 limit:5").contains("WHERE `status_code` <> 2"));
}

#[test]
fn summary_service_filters_are_membership_in_the_service_set() {
    let eq = compile("in:otel_trace_summaries service_name:svc-a limit:5");
    assert!(
        eq.contains("array_contains(`service_set`, 'svc-a')"),
        "{eq}"
    );
    let not_eq = compile("in:otel_trace_summaries !service_name:svc-a limit:5");
    assert!(
        not_eq.contains("NOT COALESCE(array_contains(`service_set`, 'svc-a'), FALSE)"),
        "{not_eq}"
    );
    let any = compile("in:otel_trace_summaries service_name:(svc-a,svc-b) limit:5");
    assert!(
        any.contains("arrays_overlap(`service_set`, ['svc-a', 'svc-b'])"),
        "{any}"
    );
    assert!(matches!(
        refused("in:otel_trace_summaries service_name:%svc% limit:5"),
        ServiceError::InvalidRequest(_)
    ));
}

#[test]
fn rollups_read_the_views_and_fall_back_to_the_same_buckets_from_spans() {
    let summary = compile("in:otel_traces time:last_24h rollup_stats:summary");
    assert!(
        summary.contains(" FROM serviceradar.traces_stats_5m WHERE `bucket` >= '"),
        "{summary}"
    );
    assert!(summary.contains(" AND `bucket` < '"), "{summary}");
    assert!(
        summary.contains("percentile_cont(p95_duration_ms, 0.95)"),
        "{summary}"
    );

    let raw = compile_raw("in:otel_traces time:last_24h rollup_stats:summary");
    assert!(
        raw.contains(" FROM serviceradar.otel_traces WHERE `parent_span_id` IS NULL"),
        "{raw}"
    );
    assert!(
        raw.contains("time_slice(`timestamp`, INTERVAL 5 MINUTE) >= '"),
        "{raw}"
    );
    assert!(!raw.contains("traces_stats_5m"), "{raw}");

    let red = compile("in:otel_traces time:last_24h service_name:svc-a rollup_stats:red");
    assert!(
        red.contains(" FROM serviceradar.spans_red_1h WHERE "),
        "{red}"
    );
    assert!(red.contains("`service_name` = 'svc-a'"), "{red}");
    let red_raw = compile_raw("in:otel_traces time:last_24h service_name:svc-a rollup_stats:red");
    // The view groups COALESCE(service_name, ''), so the raw path filters that.
    assert!(
        red_raw.contains("COALESCE(`service_name`, '') = 'svc-a'"),
        "{red_raw}"
    );
    assert!(
        red_raw.contains("GROUP BY date_trunc('hour', `timestamp`)"),
        "{red_raw}"
    );
}

#[test]
fn summary_stats_are_one_row_of_the_aliased_values() {
    let sql = compile(
        r#"in:otel_trace_summaries time:last_1h stats:"count() as total, sum(if(status_code!=0,1,0)) as failed, sum(if(duration_ms>=250,1,0)) as slow""#,
    );
    assert!(sql.starts_with("SELECT COUNT(*) AS `total`, "), "{sql}");
    assert!(
        sql.contains("COALESCE(SUM(CASE WHEN COALESCE(`status_code`, 0) <> 0 THEN 1 ELSE 0 END), 0) AS `failed`"),
        "{sql}"
    );
    // `>=` used to compile as `>` on CNPG.
    assert!(
        sql.contains("COALESCE(`duration_ms`, 0) >= 250.0 THEN 1"),
        "{sql}"
    );
    let relational =
        cnpg(r#"in:otel_trace_summaries stats:"sum(if(duration_ms>=250,1,0)) as slow""#)
            .expect("cnpg");
    assert!(
        relational.contains("coalesce(duration_ms, 0) >= $1"),
        "{relational}"
    );
}

#[test]
fn clauses_without_a_trace_translation_are_refused_on_both_backends() {
    for query in [
        r#"in:traces stats:"count() as n""#,
        "in:otel_trace_summaries rollup_stats:summary",
        "in:traces time:last_24h rollup_stats:summary sort:timestamp:desc",
        "in:traces time:last_24h rollup_stats:latency",
        "in:traces sort:name:asc limit:5",
        "in:otel_trace_summaries sort:trace_id:asc limit:5",
        r#"in:otel_trace_summaries stats:",""#,
    ] {
        assert!(
            matches!(refused(query), ServiceError::InvalidRequest(_)),
            "{query}"
        );
    }
}

/// Both backends accept and refuse the same trace queries.
#[test]
fn both_backends_accept_the_same_queries() {
    let mut corpus: Vec<String> = PRODUCT_QUERIES.iter().map(|q| q.to_string()).collect();
    let values = |field: &str| match field {
        "trace_id" => [
            TRACE.to_string(),
            "%abc%".to_string(),
            format!("({TRACE},fedcba9876543210fedcba9876543210)"),
        ],
        "span_id" | "parent_span_id" | "root_span_id" => [
            "0123456789abcdef".to_string(),
            "%abc%".to_string(),
            "(0123456789abcdef,fedcba9876543210)".to_string(),
        ],
        _ => [
            "edge-a".to_string(),
            "%edge%".to_string(),
            "(edge-a,edge-b)".to_string(),
        ],
    };
    for (field, _) in SPAN_TEXT_FIELDS {
        for value in values(field) {
            corpus.push(format!("in:traces {field}:{value} limit:5"));
            corpus.push(format!("in:traces !{field}:{value} limit:5"));
        }
    }
    for (field, _) in SUMMARY_TEXT_FIELDS {
        for value in values(field) {
            corpus.push(format!("in:otel_trace_summaries {field}:{value} limit:5"));
            corpus.push(format!(
                "in:otel_trace_summaries !{field}:{value} stats:\"count() as n\""
            ));
        }
    }
    for field in [
        "service_name",
        "service_namespace",
        "deployment_environment",
        "span_name",
    ] {
        for kind in ["summary", "red"] {
            corpus.push(format!(
                "in:traces time:last_1h {field}:(edge-a,edge-b) rollup_stats:{kind}"
            ));
            corpus.push(format!(
                "in:traces time:last_1h !{field}:%edge% rollup_stats:{kind}"
            ));
        }
    }
    for sort in traces::ROW_SORT_FIELDS
        .iter()
        .chain(&["name", "kind", "duration_ms"])
    {
        corpus.push(format!("in:traces sort:{sort}:desc limit:5"));
    }
    for sort in trace_summaries::ROW_SORT_FIELDS
        .iter()
        .chain(&["trace_id", "service_name"])
    {
        corpus.push(format!("in:otel_trace_summaries sort:{sort}:asc limit:5"));
    }
    corpus.extend(
        [
            "in:traces status_code:(1,2) limit:5",
            "in:traces !status_code:(1,2) limit:5",
            "in:traces status_code:x limit:5",
            "in:traces status_code:>1 limit:5",
            "in:traces kind:2 limit:5",
            "in:traces span_kind:(2,3) limit:5",
            "in:traces kind:>1 limit:5",
            "in:traces duration_ms:>5 limit:5",
            "in:traces bucket:5m limit:5",
            "in:otel_trace_summaries status_code:2 limit:5",
            "in:otel_trace_summaries status_code:>1 limit:5",
            "in:otel_trace_summaries root_span_kind:2 limit:5",
            "in:otel_trace_summaries span_count:>=3 limit:5",
            "in:otel_trace_summaries error_count:x limit:5",
            "in:otel_trace_summaries duration_ms:<12.5 limit:5",
            "in:otel_trace_summaries duration_ms:>inf limit:5",
            "in:otel_trace_summaries service_name:(edge-a,edge-b) stats:\"count() as n\"",
            "in:otel_trace_summaries !service_name:edge-a limit:5",
            "in:otel_trace_summaries unknown:x limit:5",
            "in:otel_trace_summaries stats:\"count() as n, sum(if(status_code=2,1,0)) as e\"",
            "in:otel_trace_summaries stats:\"sum(if(status_code>2,1,0)) as e\"",
            "in:otel_trace_summaries stats:\"sum(if(duration_ms<5,1,0)) as e\"",
            "in:otel_trace_summaries stats:\"avg(duration_ms) as e\"",
            "in:otel_trace_summaries stats:\"count()\"",
            "in:otel_trace_summaries stats:\"count() as a-b\"",
            "in:otel_trace_summaries bucket:5m limit:5",
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
