use super::{devices, gateways, interfaces, *};
use crate::parser::{self, FilterOp, FilterValue, OrderDirection};
use std::time::Duration as StdDuration;

#[test]
fn devices_docs_example_available_true() {
    let query = "in:devices time:last_7d sort:last_seen:desc limit:20 is_available:true";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::Devices));
    assert_eq!(plan.limit, 20);
    assert_eq!(plan.offset, 0);
    assert!(plan.time_range.is_some());
    assert_eq!(plan.order.len(), 1);
    assert_eq!(plan.order[0].field, "last_seen");
    assert!(matches!(plan.order[0].direction, OrderDirection::Desc));
    assert!(has_availability_filter(&plan, true));

    let (sql, _) = devices::to_sql_and_params(&plan).expect("should build SQL for docs query");
    assert!(
        sql.to_lowercase()
            .contains("\"ocsf_devices\".\"is_available\" = $3"),
        "expected SQL to include availability predicate, got: {sql}"
    );
}

#[test]
fn devices_docs_example_available_false() {
    let query = "in:devices time:last_7d sort:last_seen:desc limit:20 is_available:false";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::Devices));
    assert_eq!(plan.limit, 20);
    assert!(plan.time_range.is_some());
    assert!(has_availability_filter(&plan, false));

    let (sql, _) = devices::to_sql_and_params(&plan).expect("should build SQL for docs query");
    assert!(
        sql.to_lowercase()
            .contains("\"ocsf_devices\".\"is_available\" = $3"),
        "expected SQL to include availability predicate, got: {sql}"
    );
}

#[test]
fn devices_docs_example_discovery_sources_contains_all() {
    let query = "in:devices discovery_sources:(sweep) discovery_sources:(armis) time:last_7d sort:last_seen:desc";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::Devices));
    assert_eq!(plan.order[0].field, "last_seen");
    let range = plan
        .time_range
        .expect("docs example includes explicit time window");
    let span = range.end.signed_duration_since(range.start);
    assert_eq!(span, ChronoDuration::days(7));

    let discovery_filters: Vec<_> = plan
        .filters
        .iter()
        .filter(|filter| filter.field == "discovery_sources")
        .collect();
    assert_eq!(
        discovery_filters.len(),
        2,
        "expected repeated discovery_sources filters"
    );
    let seen_values = discovery_filters
        .iter()
        .map(|filter| match &filter.value {
            FilterValue::List(items) => items.clone(),
            _ => panic!("discovery_sources filters should be list-valued"),
        })
        .collect::<Vec<_>>();
    assert!(seen_values
        .iter()
        .any(|values| values == &vec!["sweep".to_string()]));
    assert!(seen_values
        .iter()
        .any(|values| values == &vec!["armis".to_string()]));
}

#[test]
fn devices_discovery_sources_negation_builds_negative_array_filter() {
    let query = "in:devices !discovery_sources:(armis)";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::Devices));
    assert!(plan.filters.iter().any(|filter| {
            filter.field == "discovery_sources"
                && matches!(filter.op, FilterOp::NotIn)
                && matches!(&filter.value, FilterValue::List(values) if values == &vec!["armis".to_string()])
        }));

    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build devices SQL");
    assert!(
        sql.contains("NOT (coalesce(discovery_sources, ARRAY[]::text[]) @>"),
        "expected SQL to negate discovery_sources containment, got: {sql}"
    );
    assert!(
            params
                .iter()
                .any(|param| matches!(param, BindParam::TextArray(values) if values == &vec!["armis".to_string()])),
            "expected an armis text-array bind param, got: {params:?}"
        );
}

#[test]
fn devices_default_order_uses_safe_ip_cast() {
    let query = "in:devices";
    let plan = plan_for(query);

    let (sql, _) = devices::to_sql_and_params(&plan).expect("should build devices SQL");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("coalesce(\"ocsf_devices\".\"is_active\", true) = true"),
        "expected default active-device predicate, got: {sql}"
    );
    assert!(lower.contains("split_part(ip, ',', 1)"));
    assert!(lower.contains("pg_input_is_valid"));
    assert!(
        !lower.contains("try_inet(nullif(ip, ''))"),
        "expected default device ordering to tolerate malformed IP strings, got: {sql}"
    );
    assert!(
        !lower.contains("nullif(ip, '')::inet"),
        "default device ordering should not cast malformed IP strings directly, got: {sql}"
    );
}

#[test]
fn devices_include_inactive_suppresses_default_active_filter() {
    let query = "in:devices include_inactive:true";
    let plan = plan_for(query);

    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build devices SQL");
    let lower = sql.to_lowercase();

    assert!(
        !lower.contains("coalesce(\"ocsf_devices\".\"is_active\", true) = true"),
        "include_inactive:true should not add default active predicate, got: {sql}"
    );
    assert!(
        params
            .iter()
            .all(|param| !matches!(param, BindParam::Bool(_))),
        "include_inactive is a control token and should not bind a bool param, got: {params:?}"
    );
}

#[test]
fn devices_ip_cidr_filter_generates_inet_clause() {
    let query = "in:devices ip:10.0.0.0/8";
    let plan = plan_for(query);

    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build devices SQL");
    let lower = sql.to_lowercase();

    assert!(lower.contains("split_part(ip, ',', 1)"));
    assert!(lower.contains("pg_input_is_valid"));
    assert!(
        lower.contains("<<="),
        "expected CIDR inet containment, got: {sql}"
    );

    assert!(params
        .iter()
        .any(|param| { matches!(param, BindParam::Text(value) if value == "10.0.0.0/8") }));
}

#[test]
fn devices_ip_range_filter_generates_range_clause() {
    let query = "in:devices ip:10.0.0.10-10.0.0.50";
    let plan = plan_for(query);

    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build devices SQL");
    let lower = sql.to_lowercase();

    assert!(lower.contains("split_part(ip, ',', 1)"));
    assert!(lower.contains("pg_input_is_valid"));
    assert!(
        lower.contains(">= $1::inet") && lower.contains("<= $2::inet"),
        "expected IP range inet comparison, got: {sql}"
    );

    assert!(params
        .iter()
        .any(|param| { matches!(param, BindParam::Text(value) if value == "10.0.0.10") }));
    assert!(params
        .iter()
        .any(|param| { matches!(param, BindParam::Text(value) if value == "10.0.0.50") }));
}

#[test]
fn devices_vendor_filter_default_order_uses_safe_ip_cast() {
    let query = r#"in:devices vendor_name:"Axis Communications""#;
    let plan = plan_for(query);

    let (sql, _) = devices::to_sql_and_params(&plan).expect("should build devices SQL");
    let lower = sql.to_lowercase();

    assert!(lower.contains("vendor_name"));
    assert!(lower.contains("split_part(ip, ',', 1)"));
    assert!(lower.contains("pg_input_is_valid"));
    assert!(
        !lower.contains("nullif(ip, '')::inet"),
        "default device ordering must not cast raw comma-separated ip values: {sql}"
    );
}

#[test]
fn services_docs_example_service_type_timeframe() {
    let query = r#"in:services service_type:(ssh,sftp) timeFrame:"14 Days" sort:timestamp:desc"#;
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::Services));
    let filter = plan
        .filters
        .iter()
        .find(|filter| filter.field == "service_type")
        .expect("query must contain service_type filter");
    assert!(matches!(filter.op, FilterOp::In));
    match &filter.value {
        FilterValue::List(values) => {
            assert_eq!(values, &vec!["ssh".to_string(), "sftp".to_string()]);
        }
        _ => panic!("service_type filter must be a list"),
    }

    let range = plan
        .time_range
        .expect("timeFrame should resolve to a time range");
    let span = range.end.signed_duration_since(range.start);
    assert_eq!(span, ChronoDuration::days(14));

    assert_eq!(plan.order[0].field, "timestamp");
    assert!(matches!(plan.order[0].direction, OrderDirection::Desc));
}

#[test]
fn interfaces_docs_example_ip_addresses_contains_any() {
    let query =
        "in:interfaces time:last_24h ip_addresses:(10.0.0.1,10.0.0.2) sort:timestamp:asc limit:5";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::Interfaces));
    assert_eq!(plan.limit, 5);
    let (sql, _) = interfaces::to_sql_and_params(&plan).expect("should build interfaces SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("discovered_interfaces") && lower.contains("ip_addresses"),
        "expected interface query against discovered_interfaces, got: {sql}"
    );
    assert!(lower.contains("order by timestamp asc"));
}

#[test]
fn gateways_docs_example_health_and_status() {
    let query = "in:gateways is_healthy:true status:ready sort:agent_count:desc limit:10";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::Gateways));
    assert_eq!(plan.limit, 10);
    assert_eq!(plan.order[0].field, "agent_count");
    let (sql, _) = gateways::to_sql_and_params(&plan).expect("should build gateways SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("\"gateways\".\"is_healthy\" =")
            && lower.contains("\"gateways\".\"status\" ="),
        "expected bool + status filters in SQL, got: {sql}"
    );
}

fn plan_for(query: &str) -> QueryPlan {
    let config = test_config();
    let ast = parser::parse(query).expect("docs query should parse");
    let request = QueryRequest {
        query: query.to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };
    build_query_plan(&config, &request, ast).expect("should build plan for docs query")
}

fn has_availability_filter(plan: &QueryPlan, expected: bool) -> bool {
    plan.filters.iter().any(|filter| {
        filter.field == "is_available"
            && matches!(
                &filter.value,
                FilterValue::Scalar(value) if value.eq_ignore_ascii_case(
                    if expected { "true" } else { "false" }
                )
            )
    })
}

fn test_config() -> AppConfig {
    AppConfig {
        listen_addr: "127.0.0.1:0".parse().unwrap(),
        database_url: "postgres://example/db".to_string(),
        age_graph_name: "platform_graph".to_string(),
        max_pool_size: 1,
        pg_ssl_root_cert: None,
        pg_ssl_cert: None,
        pg_ssl_key: None,
        api_key: None,
        api_key_kv_key: None,
        allowed_origins: None,
        default_limit: 100,
        max_limit: 500,
        request_timeout: StdDuration::from_secs(30),
        rate_limit_max_requests: 120,
        rate_limit_window: StdDuration::from_secs(60),
    }
}

#[test]
fn translate_param_arity_matches_sql_placeholders() {
    let config = test_config();

    let cursor = encode_cursor(250);

    let cases = [
            QueryRequest {
                query: "in:devices stats:count() as total".to_string(),
                limit: None,
                cursor: None,
                direction: QueryDirection::Next,
                mode: None,
            },
            QueryRequest {
                query: "in:services available:false time:last_24h stats:count() as failing"
                    .to_string(),
                limit: None,
                cursor: None,
                direction: QueryDirection::Next,
                mode: None,
            },
            QueryRequest {
                query: "in:gateways is_healthy:true status:ready sort:agent_count:desc".to_string(),
                limit: Some(10),
                cursor: None,
                direction: QueryDirection::Next,
                mode: None,
            },
            QueryRequest {
                query:
                    "in:dashboards status:active srql_query:%cpu_metrics% sort:updated_at:desc"
                        .to_string(),
                limit: Some(25),
                cursor: None,
                direction: QueryDirection::Next,
                mode: None,
            },
            QueryRequest {
                query: "in:devices time:last_7d sort:last_seen:desc is_available:true discovery_sources:(sweep,armis)".to_string(),
                limit: Some(20),
                cursor: Some(cursor.clone()),
                direction: QueryDirection::Next,
                mode: None,
            },
            QueryRequest {
                query: "in:interfaces time:last_24h ip_addresses:(10.0.0.1,10.0.0.2) sort:timestamp:asc".to_string(),
                limit: Some(5),
                cursor: None,
                direction: QueryDirection::Next,
                mode: None,
            },
            QueryRequest {
                query: "in:traces time:last_24h status_code:(1,2) kind:(1,2,3) sort:timestamp:desc".to_string(),
                limit: Some(25),
                cursor: None,
                direction: QueryDirection::Next,
                mode: None,
            },
            QueryRequest {
                query: "in:device_graph device_id:dev-1 collector_owned_only:true include_topology:false".to_string(),
                limit: None,
                cursor: None,
                direction: QueryDirection::Next,
                mode: None,
            },
        ];

    for request in cases {
        let response = match translate_request(&config, request.clone()) {
            Ok(response) => response,
            Err(err) => {
                panic!("translation failed for query '{}': {err:?}", request.query)
            }
        };
        let max_placeholder = super::max_dollar_placeholder(&response.sql);
        assert_eq!(
            max_placeholder,
            response.params.len(),
            "sql placeholders must match params length\nsql: {}\nparams: {:?}",
            response.sql,
            response.params
        );
    }
}

#[test]
fn translate_includes_visualization_metadata() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:timeseries_metrics time:last_7d limit:10".to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");
    let viz = response.viz.expect("viz metadata should be present");

    assert!(
        viz.columns.iter().any(|col| {
            col.name == "timestamp" && matches!(col.col_type, viz::ColumnType::Timestamptz)
        }),
        "expected timestamp column meta, got: {:?}",
        viz.columns
    );

    assert!(
        viz.suggestions
            .iter()
            .any(|s| matches!(s.kind, viz::VizKind::Timeseries)),
        "expected timeseries suggestion, got: {:?}",
        viz.suggestions
    );
}

#[test]
fn translate_downsample_emits_time_bucket_query() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:timeseries_metrics time:last_7d bucket:5m agg:avg series:metric_name limit:25"
            .to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");

    assert!(
        response.sql.to_lowercase().contains("to_timestamp(floor("),
        "expected floor-based time bucketing in SQL, got: {}",
        response.sql
    );
    assert!(
        response.sql.to_lowercase().contains("group by 1, 2"),
        "expected group by bucket+series, got: {}",
        response.sql
    );

    let viz = response.viz.expect("viz metadata should be present");
    assert_eq!(viz.columns.len(), 3);
    assert!(
        viz.suggestions
            .iter()
            .any(|s| matches!(s.kind, viz::VizKind::Timeseries)),
        "expected timeseries suggestion, got: {:?}",
        viz.suggestions
    );

    assert!(
        response.params.len() >= 4,
        "expected time range + limit/offset params, got: {:?}",
        response.params
    );
}

#[test]
fn translate_downsample_respects_value_field() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:memory_metrics time:last_7d bucket:5m agg:avg value_field:used_bytes limit:10"
            .to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");
    let sql = response.sql.to_lowercase();

    assert!(
        sql.contains("avg(used_bytes)") || sql.contains("avg(avg_used_bytes)"),
        "expected downsample to use used_bytes or avg_used_bytes, got: {}",
        response.sql
    );
}

#[test]
fn translate_flows_downsample_emits_time_bucket_query() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:flows time:last_1h bucket:5m agg:sum value_field:bytes_total limit:25"
            .to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");
    let sql = response.sql.to_lowercase();

    assert!(
        sql.contains("from ocsf_network_activity"),
        "expected flows downsample to query ocsf_network_activity, got: {}",
        response.sql
    );
    assert!(
        sql.contains("to_timestamp(floor("),
        "expected floor-based time bucketing in SQL, got: {}",
        response.sql
    );
    assert!(
        sql.contains("sum(bytes_total)"),
        "expected sum(bytes_total), got: {}",
        response.sql
    );
    assert!(
        sql.contains("group by 1, 2"),
        "expected group by bucket+series, got: {}",
        response.sql
    );

    let viz = response.viz.expect("viz metadata should be present");
    assert_eq!(viz.columns.len(), 3);
    assert!(
        viz.suggestions
            .iter()
            .any(|s| matches!(s.kind, viz::VizKind::Timeseries)),
        "expected timeseries suggestion, got: {:?}",
        viz.suggestions
    );
}

#[test]
fn translate_graph_cypher_rejects_mutations() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:graph_cypher cypher:\"CREATE (n:Device {id:'x'}) RETURN 1 as result\""
            .to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let err = translate_request(&config, request).expect_err("should reject write cypher");
    assert!(
        err.to_string().to_lowercase().contains("read-only"),
        "expected read-only error, got: {err}"
    );
}

#[test]
fn translate_graph_cypher_wraps_rows_as_topology_payload() {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".to_string());
    let request = QueryRequest {
        query: "in:graph_cypher cypher:\"MATCH (n) RETURN n\" limit:10".to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response = translate_request(&config, request).expect("translation should succeed");
    let sql = response.sql.to_lowercase();

    assert!(
        sql.contains("jsonb_build_object('nodes'"),
        "expected topology wrapper in SQL, got: {}",
        response.sql
    );
    assert!(
        sql.contains("jsonb_build_array"),
        "expected jsonb_build_array in SQL, got: {}",
        response.sql
    );
    assert_eq!(
        response.params.len(),
        2,
        "expected limit + offset binds, got: {:?}",
        response.params
    );
}

#[test]
fn devices_stats_group_by_type() {
    let query = "in:devices stats:count() as count by type";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::Devices));
    assert!(plan.stats.is_some());

    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build grouped stats SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("group by"),
        "expected GROUP BY in SQL, got: {sql}"
    );
    assert!(
        lower.contains("jsonb_build_object"),
        "expected jsonb_build_object in SQL, got: {sql}"
    );
    assert!(
        lower.contains("device_type") || lower.contains("type"),
        "expected type column in SQL, got: {sql}"
    );
    assert!(
        lower.contains("count(*)"),
        "expected COUNT(*) in SQL, got: {sql}"
    );
    assert!(
        params.is_empty(),
        "grouped stats without filters should have no params"
    );
}

#[test]
fn devices_inventory_summary_rollup_returns_all_type_and_vendor_buckets() {
    let query = "in:devices rollup_stats:inventory_summary";
    let plan = plan_for(query);

    let (sql, params) =
        devices::to_sql_and_params(&plan).expect("should build inventory summary SQL");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("device_inventory_type_counts"),
        "expected type rollup table in SQL, got: {sql}"
    );
    assert!(
        lower.contains("device_inventory_vendor_counts"),
        "expected vendor rollup table in SQL, got: {sql}"
    );
    assert!(
        !lower.contains("limit 10"),
        "inventory summary should not truncate facet buckets, got: {sql}"
    );
    assert!(params.is_empty(), "rollup summary should not bind params");
}

#[test]
fn devices_type_unknown_filter_matches_normalized_type_bucket() {
    let query = r#"in:devices type:"Unknown""#;
    let plan = plan_for(query);

    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build devices SQL");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("coalesce(nullif(trim(\"ocsf_devices\".\"type\"), ''), 'unknown')"),
        "expected normalized type expression in SQL, got: {sql}"
    );
    assert_eq!(params.len(), 3, "expected type, limit, and offset params");
    assert!(
        matches!(params.first(), Some(BindParam::Text(value)) if value == "Unknown"),
        "expected Unknown type bind, got: {params:?}"
    );
}

#[test]
fn devices_stats_type_filter_uses_normalized_type_column() {
    let query = r#"in:devices type:"Unknown" stats:"count() as count by type""#;
    let plan = plan_for(query);

    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build grouped stats SQL");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("coalesce(nullif(trim(type), ''), 'unknown') = $1"),
        "expected normalized type filter in grouped SQL, got: {sql}"
    );
    assert!(
        lower.contains("group by coalesce(nullif(trim(type), ''), 'unknown')"),
        "expected grouped stats to use normalized type bucket, got: {sql}"
    );
    assert_eq!(params.len(), 1, "expected one type filter param");
    assert!(
        matches!(params.first(), Some(BindParam::Text(value)) if value == "Unknown"),
        "expected Unknown type bind, got: {params:?}"
    );
}

#[test]
fn devices_stats_supports_metadata_like_filter() {
    let query =
        r#"in:devices metadata.armis_tags:%development% stats:"count() as count by is_available""#;
    let plan = plan_for(query);

    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build grouped stats SQL");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("metadata->>'armis_tags' ilike $1"),
        "expected metadata JSONB filter in grouped SQL, got: {sql}"
    );
    assert!(
        lower.contains("group by coalesce(is_available, false)"),
        "expected availability grouping, got: {sql}"
    );
    assert_eq!(params.len(), 1, "expected one metadata filter param");
    assert!(
        matches!(params.first(), Some(BindParam::Text(value)) if value == "%development%"),
        "expected development LIKE bind, got: {params:?}"
    );
}

#[test]
fn devices_stats_supports_type_list_filter() {
    let query = r#"in:devices type:(Router,Switch) stats:"count() as count by is_available""#;
    let plan = plan_for(query);

    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build grouped stats SQL");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("coalesce(nullif(trim(type), ''), 'unknown') = any($1)"),
        "expected normalized type list filter in grouped SQL, got: {sql}"
    );
    assert_eq!(params.len(), 1, "expected one type-list param");
    assert!(
        matches!(params.first(), Some(BindParam::TextArray(values)) if values == &vec!["Router".to_string(), "Switch".to_string()]),
        "expected Router/Switch bind, got: {params:?}"
    );
}

#[test]
fn devices_stats_group_by_vendor() {
    let query = "in:devices stats:count() as count by vendor_name";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::Devices));
    let (sql, _) = devices::to_sql_and_params(&plan).expect("should build grouped stats SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("vendor_name"),
        "expected vendor_name column in SQL, got: {sql}"
    );
    assert!(
        lower.contains("order by count(*) desc"),
        "expected ORDER BY COUNT(*) DESC in SQL, got: {sql}"
    );
}

#[test]
fn devices_stats_group_by_vendor_and_type_for_pivot_tables() {
    let query = "in:devices stats:count() as count by vendor_name,type";
    let plan = plan_for(query);

    let (sql, _) = devices::to_sql_and_params(&plan).expect("should build grouped stats SQL");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("'vendor_name'") && lower.contains("'type'"),
        "expected both pivot dimensions in payload, got: {sql}"
    );
    assert!(
        lower.contains("group by")
            && lower.contains("coalesce(vendor_name, 'unknown')")
            && lower.contains("coalesce(nullif(trim(type), ''), 'unknown')"),
        "expected GROUP BY for both pivot dimensions, got: {sql}"
    );
    assert!(
        lower.contains("count(*)"),
        "expected COUNT(*) measure in pivot stats SQL, got: {sql}"
    );
}

#[test]
fn devices_stats_group_by_availability() {
    let query = "in:devices stats:count() as count by is_available";
    let plan = plan_for(query);

    let (sql, _) = devices::to_sql_and_params(&plan).expect("should build grouped stats SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("is_available"),
        "expected is_available column in SQL, got: {sql}"
    );
}

#[test]
fn devices_docs_example_active_false() {
    let query = "in:devices is_active:false";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::Devices));

    let (sql, params) =
        devices::to_sql_and_params(&plan).expect("should build SQL for active state query");
    assert!(
        sql.to_lowercase()
            .contains("coalesce(\"ocsf_devices\".\"is_active\", true) = $1"),
        "expected SQL to include active lifecycle predicate, got: {sql}"
    );
    assert!(
        params
            .iter()
            .any(|param| matches!(param, BindParam::Bool(false))),
        "expected false active-state bind param, got: {params:?}"
    );
}

#[test]
fn devices_stats_group_by_active_state() {
    let query = "in:devices stats:count() as count by is_active";
    let plan = plan_for(query);

    let (sql, _) = devices::to_sql_and_params(&plan).expect("should build grouped stats SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("coalesce(is_active, true)"),
        "expected active lifecycle column in SQL, got: {sql}"
    );
}

#[test]
fn devices_stats_group_by_with_filter() {
    let query = "in:devices vendor_name:Cisco stats:count() as count by type";
    let plan = plan_for(query);

    let (sql, params) =
        devices::to_sql_and_params(&plan).expect("should build filtered grouped stats SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("where") && lower.contains("vendor_name"),
        "expected WHERE clause with vendor_name filter in SQL, got: {sql}"
    );
    assert!(
        lower.contains("group by") && lower.contains("coalesce(nullif(trim(type)"),
        "expected GROUP BY with type column in SQL, got: {sql}"
    );
    assert_eq!(
        params.len(),
        1,
        "should have one param for vendor_name filter"
    );
}

#[test]
fn devices_stats_group_by_unsupported_field_returns_error() {
    let query = "in:devices stats:count() as count by hostname";
    let plan = plan_for(query);

    let result = devices::to_sql_and_params(&plan);
    assert!(result.is_err(), "grouping by hostname should fail");
    let err = result.unwrap_err();
    assert!(
        err.to_string().contains("unsupported"),
        "error should mention unsupported field, got: {err}"
    );
}

#[test]
fn cagg_routing_threshold_boundary() {
    let now = chrono::Utc::now();
    let under = TimeRange {
        start: now - ChronoDuration::hours(5) - ChronoDuration::minutes(59),
        end: now,
    };
    let at = TimeRange {
        start: now - ChronoDuration::hours(6),
        end: now,
    };

    assert!(!should_route_to_hourly_cagg(
        &Entity::CpuMetrics,
        Some(&under),
        true,
        false
    ));
    assert!(should_route_to_hourly_cagg(
        &Entity::CpuMetrics,
        Some(&at),
        true,
        false
    ));
}

#[test]
fn aggregate_metric_query_allows_one_year_timeframe() {
    let config = test_config();
    let query = "in:cpu_metrics time:last_1y stats:avg(usage_percent) as avg_usage";
    let ast = parser::parse(query).expect("query should parse");
    let request = QueryRequest {
        query: query.to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let plan = build_query_plan(&config, &request, ast)
        .expect("stats metric query should allow extended range");
    let range = plan.time_range.expect("time range should exist");
    assert!(
        range.end.signed_duration_since(range.start) >= ChronoDuration::days(365),
        "expected ~1 year range, got: {:?}",
        range.end.signed_duration_since(range.start)
    );
}

#[test]
fn plain_metric_query_still_rejects_one_year_timeframe() {
    let config = test_config();
    let query = "in:cpu_metrics time:last_1y";
    let ast = parser::parse(query).expect("query should parse");
    let request = QueryRequest {
        query: query.to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let err = build_query_plan(&config, &request, ast)
        .expect_err("plain query should still enforce 90 day limit");
    assert!(
        err.to_string().contains("cannot exceed 90 days"),
        "unexpected error: {err}"
    );
}

#[test]
fn cagg_column_mappings_cover_metric_entities() {
    assert_eq!(
        cagg_column_for_entity(&Entity::CpuMetrics, "avg", "usage_percent"),
        Some("avg_usage_percent")
    );
    assert_eq!(
        cagg_column_for_entity(&Entity::MemoryMetrics, "avg", "used_bytes"),
        Some("avg_used_bytes")
    );
    assert_eq!(
        cagg_column_for_entity(&Entity::DiskMetrics, "max", "usage_percent"),
        Some("max_usage_percent")
    );
    assert_eq!(
        cagg_column_for_entity(&Entity::ProcessMetrics, "avg", "cpu_usage"),
        Some("avg_cpu_usage")
    );
    assert_eq!(
        cagg_column_for_entity(&Entity::TimeseriesMetrics, "min", "value"),
        Some("min_value")
    );
    assert_eq!(
        cagg_column_for_entity(&Entity::TimeseriesMetrics, "sum", "value"),
        None
    );
}

#[test]
fn cpu_stats_without_group_by_translates_and_routes_to_cagg() {
    let config = test_config();
    let request = QueryRequest {
        query: "in:cpu_metrics time:last_7d stats:avg(usage_percent) as avg_usage".into(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response =
        translate_request(&config, request).expect("ungrouped cpu stats should translate");
    let sql = response.sql.to_lowercase();
    assert!(
        sql.contains("from cpu_metrics_hourly"),
        "expected CAGG source for large-window stats query, got: {}",
        response.sql
    );
    assert!(
        !sql.contains("group by device_id"),
        "ungrouped query should not force device grouping, got: {}",
        response.sql
    );
}

#[test]
fn cpu_stats_without_alias_translates_and_routes_to_cagg() {
    let config = test_config();
    let request = QueryRequest {
        query: "in:cpu_metrics time:last_7d stats:avg(usage_percent)".into(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let response =
        translate_request(&config, request).expect("alias-less cpu stats should translate");
    let sql = response.sql.to_lowercase();
    assert!(
        sql.contains("from cpu_metrics_hourly"),
        "expected CAGG source for large-window stats query, got: {}",
        response.sql
    );
    assert!(
        !sql.contains("group by device_id"),
        "ungrouped query should not force device grouping, got: {}",
        response.sql
    );
}
