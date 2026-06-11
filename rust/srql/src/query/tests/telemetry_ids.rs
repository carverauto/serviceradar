use super::*;

const TRACE_ID_UPPER: &str = "6D88848D08854D6AD1561D510041D03C";
const TRACE_ID_LOWER: &str = "6d88848d08854d6ad1561d510041d03c";
const SPAN_ID_UPPER: &str = "AB54A98CEB1F0AD2";
const SPAN_ID_LOWER: &str = "ab54a98ceb1f0ad2";

fn request_for(query: &str) -> QueryRequest {
    QueryRequest {
        query: query.to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    }
}

fn translate(query: &str) -> TranslateResponse {
    translate_request(&test_config(), request_for(query)).expect("query should translate")
}

fn plan_error(query: &str) -> ServiceError {
    let config = test_config();
    let ast = parser::parse(query).expect("query should parse");
    match build_query_plan(&config, &request_for(query), ast) {
        Err(err) => err,
        Ok(_) => panic!("expected plan error for query: {query}"),
    }
}

fn scalar_value(plan: &QueryPlan, field: &str) -> String {
    plan.filters
        .iter()
        .find(|filter| filter.field == field)
        .and_then(|filter| match &filter.value {
            FilterValue::Scalar(value) => Some(value.clone()),
            FilterValue::List(_) => None,
        })
        .unwrap_or_else(|| panic!("expected scalar filter for {field}"))
}

fn order_by_clause(sql: &str) -> &str {
    let idx = sql
        .find("ORDER BY")
        .unwrap_or_else(|| panic!("expected ORDER BY in sql: {sql}"));
    &sql[idx..]
}

// ---------------------------------------------------------------------------
// Identifier case folding
// ---------------------------------------------------------------------------

#[test]
fn uppercase_trace_id_is_folded_to_lowercase_for_traces() {
    let plan = plan_for(&format!(r#"in:traces trace_id:"{TRACE_ID_UPPER}""#));
    assert_eq!(scalar_value(&plan, "trace_id"), TRACE_ID_LOWER);

    let response = translate(&format!(r#"in:traces trace_id:"{TRACE_ID_UPPER}""#));
    assert!(
        response
            .params
            .iter()
            .any(|param| matches!(param, BindParam::Text(value) if value == TRACE_ID_LOWER)),
        "expected lowercase trace_id bind, got: {:?}",
        response.params
    );
}

#[test]
fn uppercase_trace_id_is_folded_to_lowercase_for_logs() {
    let plan = plan_for(&format!(r#"in:logs trace_id:"{TRACE_ID_UPPER}""#));
    assert_eq!(scalar_value(&plan, "trace_id"), TRACE_ID_LOWER);
}

#[test]
fn uppercase_span_id_is_folded_for_otel_metrics() {
    let plan = plan_for(&format!(r#"in:otel_metrics span_id:"{SPAN_ID_UPPER}""#));
    assert_eq!(scalar_value(&plan, "span_id"), SPAN_ID_LOWER);
}

#[test]
fn uppercase_trace_id_list_is_folded_for_trace_summaries() {
    let plan = plan_for(&format!(
        "in:otel_trace_summaries trace_id:({TRACE_ID_UPPER},{TRACE_ID_LOWER})"
    ));
    let filter = plan
        .filters
        .iter()
        .find(|filter| filter.field == "trace_id")
        .expect("trace_id filter present");
    match &filter.value {
        FilterValue::List(values) => {
            assert_eq!(values, &vec![TRACE_ID_LOWER.to_string(); 2]);
        }
        other => panic!("expected list filter, got {other:?}"),
    }
}

#[test]
fn uppercase_parent_span_id_is_folded_for_traces() {
    let plan = plan_for(&format!(r#"in:traces parent_span_id:"{SPAN_ID_UPPER}""#));
    assert_eq!(scalar_value(&plan, "parent_span_id"), SPAN_ID_LOWER);
}

// ---------------------------------------------------------------------------
// Identifier validation errors
// ---------------------------------------------------------------------------

#[test]
fn malformed_trace_id_is_a_validation_error() {
    let err = plan_error(r#"in:logs trace_id:"not-a-trace-id""#);
    let message = err.to_string();
    assert!(
        message.contains("trace_id") && message.contains("32-character hex"),
        "error should name the field and expected format: {message}"
    );
}

#[test]
fn empty_trace_id_is_a_validation_error() {
    let err = plan_error(r#"in:logs trace_id:"""#);
    let message = err.to_string();
    assert!(
        message.contains("trace_id") && message.contains("must not be empty"),
        "error should reject empty id values: {message}"
    );
}

#[test]
fn wrong_length_span_id_is_a_validation_error() {
    let err = plan_error(r#"in:traces span_id:"abcd""#);
    let message = err.to_string();
    assert!(
        message.contains("span_id") && message.contains("16-character hex"),
        "error should name the field and expected format: {message}"
    );
}

#[test]
fn non_hex_trace_id_in_list_is_a_validation_error() {
    let err = plan_error(&format!(
        "in:otel_trace_summaries trace_id:({TRACE_ID_LOWER},zz88848d08854d6ad1561d510041d03c)"
    ));
    assert!(
        err.to_string().contains("trace_id"),
        "error should name the field: {err}"
    );
}

// ---------------------------------------------------------------------------
// Trace summaries numeric comparisons (rollup drill-down)
// ---------------------------------------------------------------------------

#[test]
fn error_count_greater_than_translates_for_trace_summaries() {
    let response = translate("in:otel_trace_summaries error_count:>0 time:last_24h");
    assert!(
        response.sql.contains("error_count > $3"),
        "expected error_count comparison in sql: {}",
        response.sql
    );
    assert!(
        response
            .params
            .iter()
            .any(|param| matches!(param, BindParam::Int(0))),
        "expected bound zero threshold, got: {:?}",
        response.params
    );
}

#[test]
fn duration_ms_range_translates_for_trace_summaries() {
    let response = translate("in:otel_trace_summaries duration_ms:>=250 time:last_24h");
    assert!(
        response.sql.contains("duration_ms >= $3"),
        "expected duration_ms comparison in sql: {}",
        response.sql
    );
}

// ---------------------------------------------------------------------------
// Service namespace / deployment environment correlation columns
// ---------------------------------------------------------------------------

#[test]
fn traces_select_includes_correlation_columns() {
    let response = translate("in:traces time:last_24h");
    for column in [
        "trace_state",
        "scope_attributes",
        "service_namespace",
        "deployment_environment",
        "dropped_attributes_count",
        "dropped_events_count",
        "dropped_links_count",
    ] {
        assert!(
            response.sql.contains(column),
            "expected {column} in traces selection: {}",
            response.sql
        );
    }
}

#[test]
fn trace_summaries_select_includes_namespace_and_environment_columns() {
    let response = translate("in:otel_trace_summaries time:last_24h");
    for column in ["root_service_namespace", "deployment_environment"] {
        assert!(
            response.sql.contains(column),
            "expected {column} in trace summaries selection: {}",
            response.sql
        );
    }
}

#[test]
fn namespace_and_environment_filters_translate_for_traces() {
    let response =
        translate("in:traces service_namespace:payments deployment_environment:prod time:last_24h");
    assert!(
        response.sql.contains(r#""service_namespace" = $3"#),
        "expected service_namespace equality filter: {}",
        response.sql
    );
    assert!(
        response.sql.contains(r#""deployment_environment" = $4"#),
        "expected deployment_environment equality filter: {}",
        response.sql
    );
    for value in ["payments", "prod"] {
        assert!(
            response
                .params
                .iter()
                .any(|param| matches!(param, BindParam::Text(text) if text == value)),
            "expected {value} bind, got: {:?}",
            response.params
        );
    }
}

#[test]
fn namespace_like_and_environment_list_filters_translate_for_traces() {
    let response = translate(
        "in:traces service_namespace:pay% deployment_environment:(prod,staging) time:last_24h",
    );
    assert!(
        response.sql.contains(r#""service_namespace" ILIKE $3"#),
        "expected service_namespace ILIKE filter: {}",
        response.sql
    );
    assert!(
        response
            .sql
            .contains(r#""deployment_environment" = ANY($4)"#),
        "expected deployment_environment list filter: {}",
        response.sql
    );
    assert!(
        response.params.iter().any(|param| matches!(
            param,
            BindParam::TextArray(values) if values == &["prod".to_string(), "staging".to_string()]
        )),
        "expected environment list bind, got: {:?}",
        response.params
    );
}

#[test]
fn namespace_and_environment_filters_translate_for_trace_summaries() {
    let response = translate(
        "in:otel_trace_summaries root_service_namespace:payments deployment_environment:prod time:last_24h",
    );
    assert!(
        response.sql.contains("root_service_namespace = $3"),
        "expected root_service_namespace filter: {}",
        response.sql
    );
    assert!(
        response.sql.contains("deployment_environment = $4"),
        "expected deployment_environment filter: {}",
        response.sql
    );
    for value in ["payments", "prod"] {
        assert!(
            response
                .params
                .iter()
                .any(|param| matches!(param, BindParam::Text(text) if text == value)),
            "expected {value} bind, got: {:?}",
            response.params
        );
    }
}

// ---------------------------------------------------------------------------
// rollup_stats:red for traces
// ---------------------------------------------------------------------------

#[test]
fn rollup_stats_red_reads_spans_red_1h() {
    let response = translate("in:traces service_name:web rollup_stats:red time:last_24h");

    assert!(
        response.sql.contains("FROM spans_red_1h"),
        "expected spans_red_1h source: {}",
        response.sql
    );
    for key in [
        "'total'",
        "'errors'",
        "'slow'",
        "'error_rate'",
        "'avg_duration_ms'",
        "'p50_duration_ms'",
        "'p95_duration_ms'",
        "'max_duration_ms'",
    ] {
        assert!(
            response.sql.contains(key),
            "expected {key} in payload: {}",
            response.sql
        );
    }
    assert!(
        response.sql.contains("bucket >= $1") && response.sql.contains("bucket < $2"),
        "expected bucket window binds: {}",
        response.sql
    );
    assert!(
        response.sql.contains("service_name = $3"),
        "expected service_name filter: {}",
        response.sql
    );
    assert!(
        response
            .params
            .iter()
            .any(|param| matches!(param, BindParam::Text(value) if value == "web")),
        "expected service bind, got: {:?}",
        response.params
    );
}

#[test]
fn rollup_stats_red_supports_namespace_and_environment_filters() {
    let response = translate(
        "in:traces service_name:web service_namespace:payments deployment_environment:prod rollup_stats:red time:last_24h",
    );

    assert!(
        response.sql.contains("FROM spans_red_1h"),
        "expected spans_red_1h source: {}",
        response.sql
    );
    assert!(
        response.sql.contains("service_name = $3"),
        "expected service_name filter: {}",
        response.sql
    );
    assert!(
        response.sql.contains("service_namespace = $4"),
        "expected service_namespace filter: {}",
        response.sql
    );
    assert!(
        response.sql.contains("deployment_environment = $5"),
        "expected deployment_environment filter: {}",
        response.sql
    );
    for value in ["web", "payments", "prod"] {
        assert!(
            response
                .params
                .iter()
                .any(|param| matches!(param, BindParam::Text(text) if text == value)),
            "expected {value} bind, got: {:?}",
            response.params
        );
    }
}

#[test]
fn rollup_stats_red_rejects_unsupported_filters() {
    let config = test_config();
    let request = request_for("in:traces status_code:2 rollup_stats:red time:last_24h");
    let err = translate_request(&config, request).expect_err("unsupported filter should error");
    assert!(
        err.to_string().contains("rollup_stats:red"),
        "error should name the rollup handler: {err}"
    );
}

// ---------------------------------------------------------------------------
// Span retrieval ordering (waterfall)
// ---------------------------------------------------------------------------

#[test]
fn explicit_start_time_sort_is_honored_for_traces() {
    let response = translate(&format!(
        r#"in:traces trace_id:"{TRACE_ID_LOWER}" sort:start_time_unix_nano:asc"#
    ));
    let order = order_by_clause(&response.sql);
    assert!(
        order.contains("start_time_unix_nano") && order.contains("ASC"),
        "expected start time ascending order: {order}"
    );
}

#[test]
fn trace_id_filter_defaults_to_waterfall_order() {
    let response = translate(&format!(r#"in:traces trace_id:"{TRACE_ID_LOWER}""#));
    let order = order_by_clause(&response.sql);
    assert!(
        order.contains("start_time_unix_nano") && order.contains("ASC"),
        "expected default waterfall order for trace_id query: {order}"
    );
}

#[test]
fn trace_id_filter_with_explicit_sort_keeps_explicit_sort() {
    let response = translate(&format!(
        r#"in:traces trace_id:"{TRACE_ID_LOWER}" sort:timestamp:desc"#
    ));
    let order = order_by_clause(&response.sql);
    assert!(
        order.contains("timestamp") && order.contains("DESC"),
        "expected explicit timestamp sort: {order}"
    );
    assert!(
        !order.contains("start_time_unix_nano"),
        "waterfall default must not override explicit sort: {order}"
    );
}

#[test]
fn traces_without_trace_id_keep_timestamp_desc_default() {
    let response = translate("in:traces time:last_24h");
    let order = order_by_clause(&response.sql);
    assert!(
        order.contains("timestamp") && order.contains("DESC"),
        "expected newest-first default: {order}"
    );
    assert!(
        !order.contains("start_time_unix_nano"),
        "waterfall order should require a trace_id filter: {order}"
    );
}
