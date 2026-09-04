use super::{
    addon_fleet, composite_results, devices, endpoint_inventory_scans, endpoint_package_catalog,
    endpoint_packages, gateways, interfaces, *,
};
use crate::parser::{self, FilterOp, FilterValue, OrderDirection};
use std::time::Duration as StdDuration;

mod device_queries;
mod entity_examples;
mod metric_caggs;
mod placeholders;
mod telemetry_ids;
mod translation;

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

#[test]
fn other_rollup_rejects_non_flow_stats_entities() {
    let config = test_config();
    let query = "in:devices stats:count() as total by type sort:total:desc limit:10 other:true";
    let ast = parser::parse(query).expect("query should parse");
    let request = QueryRequest {
        query: query.to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    };

    let err = build_query_plan(&config, &request, ast)
        .expect_err("non-flow other rollup should fail during planning");

    assert!(
        err.to_string()
            .contains("other:true is currently supported only for flow or timeseries stats"),
        "unexpected error: {err}"
    );
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
        database_ca_pem: None,
        database_client_cert_pem: None,
        database_client_key_pem: None,
        database_tls_server_name: None,
        api_key: None,
        api_key_kv_key: None,
        allowed_origins: None,
        cursor_secret: "test-cursor-secret".to_string(),
        max_cursor_offset: 100_000,
        default_limit: 100,
        max_limit: 500,
        request_timeout: StdDuration::from_secs(30),
        db_statement_timeout: StdDuration::from_secs(30),
        rate_limit_max_requests: 120,
        rate_limit_window: StdDuration::from_secs(60),
    }
}
