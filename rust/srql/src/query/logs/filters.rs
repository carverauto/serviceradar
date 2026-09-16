use super::metadata::{apply_metadata_identity_filter, LOG_DEVICE_IDENTITY_KEYS};
use super::{enforce_list_limit, LogsQuery, RECOGNIZED_SEVERITY_TEXTS};
use crate::{
    error::{Result, ServiceError},
    parser::{Filter, FilterOp},
    query::BindParam,
    schema::logs::dsl::{
        body as col_body, event_name as col_event_name, id as col_id,
        ingest_agent_id as col_ingest_agent_id, ingest_identity as col_ingest_identity,
        ingest_partition as col_ingest_partition, scope_name as col_scope_name,
        scope_version as col_scope_version, service_instance as col_service_instance,
        service_name as col_service_name, service_version as col_service_version,
        severity_number as col_severity_number, severity_text as col_severity_text,
        source as col_source, source_ip as col_source_ip, span_id as col_span_id,
        trace_id as col_trace_id,
    },
};
use diesel::prelude::*;
use diesel::sql_types::{Nullable, Text};
use diesel::PgTextExpressionMethods;
use uuid::Uuid;

diesel::define_sql_function! {
    /// Postgres `lower()` used for case-insensitive severity comparisons, so
    /// Java-style `SEVERE`, OTel `ERROR`, and lowercase WAF severities all match.
    #[sql_name = "lower"]
    fn lower_text(value: Nullable<Text>) -> Nullable<Text>;
}

pub(super) fn apply_filter<'a>(mut query: LogsQuery<'a>, filter: &Filter) -> Result<LogsQuery<'a>> {
    match filter.field.as_str() {
        "id" => {
            let value = filter.value.as_scalar()?;
            let uuid = Uuid::parse_str(value)
                .map_err(|_| ServiceError::InvalidRequest("id must be a valid UUID".into()))?;
            query = match filter.op {
                FilterOp::Eq => query.filter(col_id.eq(uuid)),
                FilterOp::NotEq => query.filter(col_id.ne(uuid)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "id filter only supports equality comparisons".into(),
                    ));
                }
            };
        }
        "trace_id" => {
            query = apply_text_filter!(query, filter, col_trace_id)?;
        }
        "span_id" => {
            query = apply_text_filter!(query, filter, col_span_id)?;
        }
        "service_name" => {
            query = apply_text_filter!(query, filter, col_service_name)?;
        }
        "service_version" => {
            query = apply_text_filter!(query, filter, col_service_version)?;
        }
        "service_instance" => {
            query = apply_text_filter!(query, filter, col_service_instance)?;
        }
        "source" => {
            query = apply_text_filter!(query, filter, col_source)?;
        }
        "source_ip" => {
            query = apply_text_filter!(query, filter, col_source_ip)?;
        }
        "scope_name" => {
            query = apply_text_filter!(query, filter, col_scope_name)?;
        }
        "scope_version" => {
            query = apply_text_filter!(query, filter, col_scope_version)?;
        }
        "severity_text" | "severity" | "level" => {
            query = apply_severity_filter(query, filter)?;
        }
        "event_name" => {
            query = apply_text_filter!(query, filter, col_event_name)?;
        }
        "body" | "message" => {
            query = apply_text_filter!(query, filter, col_body)?;
        }
        "device_id" | "uid" | "source_device_uid" => {
            query = apply_metadata_identity_filter(query, filter, LOG_DEVICE_IDENTITY_KEYS)?;
        }
        // NOTE: `agent_id` below is already taken by the attributes-based
        // metadata identity filter, so the ingest column filters use their
        // exact `ingest_*` column names only — no `agent_id` alias.
        "ingest_identity" => {
            query = apply_text_filter!(query, filter, col_ingest_identity)?;
        }
        "ingest_agent_id" => {
            query = apply_text_filter!(query, filter, col_ingest_agent_id)?;
        }
        "ingest_partition" => {
            query = apply_text_filter!(query, filter, col_ingest_partition)?;
        }
        "gateway_id" => {
            query = apply_metadata_identity_filter(
                query,
                filter,
                &["serviceradar.gateway_id", "gateway_id"],
            )?;
        }
        "agent_id" => {
            query = apply_metadata_identity_filter(
                query,
                filter,
                &["serviceradar.agent_id", "agent_id"],
            )?;
        }
        "severity_number" => match filter.op {
            FilterOp::Eq | FilterOp::NotEq => {
                let value = filter.value.as_scalar()?.parse::<i32>().map_err(|_| {
                    ServiceError::InvalidRequest("severity_number must be an integer".into())
                })?;
                query = match filter.op {
                    FilterOp::Eq => query.filter(col_severity_number.eq(value)),
                    FilterOp::NotEq => query.filter(col_severity_number.ne(value)),
                    _ => unreachable!(),
                };
            }
            FilterOp::In | FilterOp::NotIn => {
                let values: Vec<i32> = filter
                    .value
                    .as_list()?
                    .iter()
                    .map(|v| v.parse::<i32>())
                    .collect::<std::result::Result<Vec<_>, _>>()
                    .map_err(|_| {
                        ServiceError::InvalidRequest("severity_number list must be integers".into())
                    })?;
                if values.is_empty() {
                    return Ok(query);
                }
                query = match filter.op {
                    FilterOp::In => query.filter(col_severity_number.eq_any(values)),
                    FilterOp::NotIn => query.filter(col_severity_number.ne_all(values)),
                    _ => unreachable!(),
                };
            }
            _ => {
                return Err(ServiceError::InvalidRequest(
                    "severity_number only supports equality and IN/NOT IN comparisons".into(),
                ));
            }
        },
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for logs: '{other}'"
            )));
        }
    }

    Ok(query)
}

/// Case-insensitive severity_text filter: equality compiles to
/// `lower(severity_text) = lower($n)` and IN-lists compare `lower(severity_text)`
/// against Rust-lowercased values, so `SEVERE`/`Error`/`error` all match.
/// LIKE already compiles to ILIKE (case-insensitive) via the shared text path.
fn apply_severity_filter<'a>(query: LogsQuery<'a>, filter: &Filter) -> Result<LogsQuery<'a>> {
    let next = match filter.op {
        FilterOp::Eq => {
            let value = filter.value.as_scalar()?.to_string();
            query.filter(lower_text(col_severity_text).eq(lower_text(value)))
        }
        FilterOp::NotEq => {
            let value = filter.value.as_scalar()?.to_string();
            query.filter(lower_text(col_severity_text).ne(lower_text(value)))
        }
        FilterOp::Like => {
            let value = filter.value.as_scalar()?.to_string();
            query.filter(col_severity_text.ilike(value))
        }
        FilterOp::NotLike => {
            let value = filter.value.as_scalar()?.to_string();
            query.filter(col_severity_text.not_ilike(value))
        }
        FilterOp::In | FilterOp::NotIn => {
            let values: Vec<String> = filter
                .value
                .as_list()?
                .iter()
                .map(|value| value.to_lowercase())
                .collect();
            if values.is_empty() {
                return Ok(query);
            }
            enforce_list_limit(&filter.field, values.len())?;
            if matches!(filter.op, FilterOp::In) {
                query.filter(lower_text(col_severity_text).eq_any(values))
            } else {
                query.filter(lower_text(col_severity_text).ne_all(values))
            }
        }
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported operator for text filter: {:?}",
                filter.op
            )));
        }
    };
    Ok(next)
}

pub(super) fn apply_severity_any_filter<'a>(
    query: LogsQuery<'a>,
    text_filter: Option<&Filter>,
    number_filter: Option<&Filter>,
) -> Result<LogsQuery<'a>> {
    let (Some(text_filter), Some(number_filter)) = (text_filter, number_filter) else {
        return Err(ServiceError::InvalidRequest(
            "severity_match:any requires severity and severity_number filters".into(),
        ));
    };

    if !matches!(text_filter.op, FilterOp::In) || !matches!(number_filter.op, FilterOp::In) {
        return Err(ServiceError::InvalidRequest(
            "severity_match:any requires IN-list filters".into(),
        ));
    }

    let text_values: Vec<String> = text_filter
        .value
        .as_list()?
        .iter()
        .map(|value| value.to_lowercase())
        .collect();
    if text_values.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "severity_match:any requires non-empty IN-list filters".into(),
        ));
    }
    enforce_list_limit(&text_filter.field, text_values.len())?;

    let number_values: Vec<i32> = number_filter
        .value
        .as_list()?
        .iter()
        .map(|value| value.parse::<i32>())
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(|_| {
            ServiceError::InvalidRequest("severity_number list must be integers".into())
        })?;
    if number_values.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "severity_match:any requires non-empty IN-list filters".into(),
        ));
    }
    enforce_list_limit(&number_filter.field, number_values.len())?;

    let recognized_text_values = RECOGNIZED_SEVERITY_TEXTS
        .iter()
        .map(|value| (*value).to_string())
        .collect::<Vec<_>>();
    let text_is_missing_or_unknown = col_severity_text
        .is_null()
        .or(lower_text(col_severity_text).ne_all(recognized_text_values));

    Ok(query.filter(
        lower_text(col_severity_text)
            .eq_any(text_values)
            .or(text_is_missing_or_unknown.and(col_severity_number.eq_any(number_values))),
    ))
}

/// Restrict a numeric-severity top-N branch to rows where the text cannot
/// classify the record. This keeps the branch disjoint from every scalar text
/// branch and preserves the card contract that recognized text is
/// authoritative over a conflicting numeric severity.
pub(super) fn apply_numeric_severity_fallback_guard<'a>(query: LogsQuery<'a>) -> LogsQuery<'a> {
    let recognized_text_values = RECOGNIZED_SEVERITY_TEXTS
        .iter()
        .map(|value| (*value).to_string())
        .collect::<Vec<_>>();

    query.filter(
        col_severity_text
            .is_null()
            .or(lower_text(col_severity_text).ne_all(recognized_text_values)),
    )
}

fn collect_text_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq | FilterOp::Like | FilterOp::NotLike => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        FilterOp::In | FilterOp::NotIn => {
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

/// Mirrors `apply_severity_filter` bind values: scalar operators bind the raw
/// value (the SQL lowers both sides), while IN/NOT IN lists are lowercased in
/// Rust to match the `lower(severity_text) = ANY(...)` comparison.
fn collect_severity_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq | FilterOp::Like | FilterOp::NotLike => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        FilterOp::In | FilterOp::NotIn => {
            let values: Vec<String> = filter
                .value
                .as_list()?
                .iter()
                .map(|value| value.to_lowercase())
                .collect();
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

pub(super) fn collect_filter_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.field.as_str() {
        "id" => {
            let value = filter.value.as_scalar()?;
            let uuid = Uuid::parse_str(value)
                .map_err(|_| ServiceError::InvalidRequest("id must be a valid UUID".into()))?;
            params.push(BindParam::Uuid(uuid));
            Ok(())
        }
        "trace_id" | "span_id" | "service_name" | "service_version" | "service_instance"
        | "source" | "source_ip" | "scope_name" | "scope_version" | "event_name" | "body"
        | "message" | "ingest_identity" | "ingest_agent_id" | "ingest_partition" => {
            collect_text_params(params, filter)
        }
        "severity_text" | "severity" | "level" => collect_severity_params(params, filter),
        "severity_match" => Ok(()),
        "device_id" | "uid" | "source_device_uid" | "gateway_id" | "agent_id" => Ok(()),
        "severity_number" => match filter.op {
            FilterOp::Eq | FilterOp::NotEq => {
                let value = filter.value.as_scalar()?.parse::<i32>().map_err(|_| {
                    ServiceError::InvalidRequest("severity_number must be an integer".into())
                })?;
                params.push(BindParam::Int(i64::from(value)));
                Ok(())
            }
            FilterOp::In | FilterOp::NotIn => {
                let values: Vec<i32> = filter
                    .value
                    .as_list()?
                    .iter()
                    .map(|v| v.parse::<i32>())
                    .collect::<std::result::Result<Vec<_>, _>>()
                    .map_err(|_| {
                        ServiceError::InvalidRequest("severity_number list must be integers".into())
                    })?;
                if values.is_empty() {
                    return Ok(());
                }
                params.push(BindParam::IntArray(
                    values.into_iter().map(i64::from).collect(),
                ));
                Ok(())
            }
            _ => Err(ServiceError::InvalidRequest(
                "severity_number filter does not support this operator".into(),
            )),
        },
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for logs: '{other}'"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::super::test_support::{data_plan, scalar_filter};
    use super::super::{build_query, to_sql_and_params};
    use crate::parser::{Entity, Filter, FilterOp, FilterValue};
    use crate::query::{BindParam, QueryPlan};
    use crate::time::TimeRange;
    use chrono::{Duration as ChronoDuration, TimeZone, Utc};

    #[test]
    fn event_name_eq_filter_generates_sql() {
        let plan = data_plan(vec![scalar_filter(
            "event_name",
            FilterOp::Eq,
            "device.reboot",
        )]);

        let (sql, params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(sql.contains("\"logs\".\"event_name\" = $3"), "{sql}");
        assert!(
            matches!(&params[2], BindParam::Text(value) if value == "device.reboot"),
            "params: {params:?}"
        );
    }

    #[test]
    fn event_name_like_filter_uses_ilike() {
        let plan = data_plan(vec![scalar_filter(
            "event_name",
            FilterOp::Like,
            "%reboot%",
        )]);

        let (sql, params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(sql.contains("\"logs\".\"event_name\" ILIKE $3"), "{sql}");
        assert!(
            matches!(&params[2], BindParam::Text(value) if value == "%reboot%"),
            "params: {params:?}"
        );
    }

    #[test]
    fn event_name_in_filter_generates_any_clause() {
        let plan = data_plan(vec![Filter {
            field: "event_name".into(),
            op: FilterOp::In,
            value: FilterValue::List(vec!["device.reboot".into(), "device.shutdown".into()]),
        }]);

        let (sql, params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(sql.contains("\"logs\".\"event_name\" = ANY($3)"), "{sql}");
        assert!(
            matches!(&params[2], BindParam::TextArray(values)
                if values == &vec!["device.reboot".to_string(), "device.shutdown".to_string()]),
            "params: {params:?}"
        );
    }

    #[test]
    fn source_ip_eq_filter_targets_source_ip_column() {
        let plan = data_plan(vec![scalar_filter(
            "source_ip",
            FilterOp::Eq,
            "10.208.254.4",
        )]);

        let (sql, params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(sql.contains("\"logs\".\"source_ip\" = $3"), "{sql}");
        assert!(
            matches!(&params[2], BindParam::Text(value) if value == "10.208.254.4"),
            "params: {params:?}"
        );
    }

    #[test]
    fn ingest_identity_eq_filter_targets_column() {
        let plan = data_plan(vec![scalar_filter(
            "ingest_identity",
            FilterOp::Eq,
            "spiffe://sr/agent/edge-1",
        )]);

        let (sql, params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(sql.contains("\"logs\".\"ingest_identity\" = $3"), "{sql}");
        assert!(
            matches!(&params[2], BindParam::Text(value) if value == "spiffe://sr/agent/edge-1"),
            "params: {params:?}"
        );
    }

    #[test]
    fn ingest_agent_id_eq_filter_targets_column_not_attributes() {
        let plan = data_plan(vec![scalar_filter(
            "ingest_agent_id",
            FilterOp::Eq,
            "edge-1",
        )]);

        let (sql, params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(sql.contains("\"logs\".\"ingest_agent_id\" = $3"), "{sql}");
        assert!(!sql.contains("ILIKE"), "{sql}");
        assert!(
            matches!(&params[2], BindParam::Text(value) if value == "edge-1"),
            "params: {params:?}"
        );
    }

    #[test]
    fn agent_id_filter_still_routes_to_attributes_metadata() {
        // Guard: the pre-existing `agent_id` filter is attributes-based and
        // must not be shadowed by the new `ingest_agent_id` column filter.
        let plan = data_plan(vec![scalar_filter("agent_id", FilterOp::Eq, "edge-1")]);

        let (sql, _params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(!sql.contains("\"logs\".\"agent_id\""), "{sql}");
        assert!(sql.contains("attributes"), "{sql}");
    }

    #[test]
    fn device_id_filter_matches_inventory_ip_on_source_ip_column() {
        let plan = data_plan(vec![scalar_filter(
            "device_id",
            FilterOp::Eq,
            "sr:f3f0e473-222f-45ca-bbc7-ceac009a7881",
        )]);

        let (sql, _params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(
            sql.contains("logs.source_ip IN ("),
            "device_id must join inventory IPs to logs.source_ip, got: {sql}"
        );
        assert!(
            sql.contains("platform.ocsf_devices"),
            "device_id should resolve aliases from inventory, got: {sql}"
        );
        assert!(
            sql.contains("platform.device_identifiers"),
            "device_id should also match registered IP/hostname identifiers, got: {sql}"
        );
        assert!(
            sql.contains("logs.source IN ("),
            "device_id should match syslog source hostname, got: {sql}"
        );
        assert!(
            sql.contains("platform.discovered_interfaces"),
            "device_id should match discovered interface IPs, got: {sql}"
        );
        assert!(
            !sql.contains("ILIKE"),
            "device_id must not scan log attributes with ILIKE, got: {sql}"
        );
        assert!(
            !sql.contains("EXISTS ("),
            "device_id identity must stay uncorrelated so the window scan stays bounded, got: {sql}"
        );
        assert!(
            !sql.contains("CROSS JOIN LATERAL"),
            "device_id must not unnest interfaces per log row, got: {sql}"
        );
    }

    #[test]
    fn ingest_partition_in_filter_generates_any_clause() {
        let plan = data_plan(vec![Filter {
            field: "ingest_partition".into(),
            op: FilterOp::In,
            value: FilterValue::List(vec!["default".into(), "tenant-a".into()]),
        }]);

        let (sql, params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(
            sql.contains("\"logs\".\"ingest_partition\" = ANY($3)"),
            "{sql}"
        );
        assert!(
            matches!(&params[2], BindParam::TextArray(values)
                if values == &vec!["default".to_string(), "tenant-a".to_string()]),
            "params: {params:?}"
        );
    }

    #[test]
    fn source_eq_filter_compares_raw_column() {
        // The `idx_logs_source_effective_ts` composite index
        // (migration 20260707120000) is on the RAW `source` column, so the
        // Observability > Logs source filter MUST keep compiling to a raw
        // `source = $n` predicate (NOT `lower(source)`). Guard that here.
        let plan = data_plan(vec![scalar_filter("source", FilterOp::Eq, "internal")]);

        let (sql, params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(sql.contains("\"logs\".\"source\" = $3"), "{sql}");
        assert!(!sql.contains("lower(\"logs\".\"source\")"), "{sql}");
        assert!(
            matches!(&params[2], BindParam::Text(value) if value == "internal"),
            "params: {params:?}"
        );
    }

    #[test]
    fn source_in_filter_generates_any_clause() {
        // Multi-source drill-downs compile to `source = ANY($n)` on the raw
        // column, which the `(source, effective_ts DESC)` index also serves.
        let plan = data_plan(vec![Filter {
            field: "source".into(),
            op: FilterOp::In,
            value: FilterValue::List(vec!["internal".into(), "otel".into()]),
        }]);

        let (sql, params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(sql.contains("\"logs\".\"source\" = ANY($3)"), "{sql}");
        assert!(!sql.contains("lower(\"logs\".\"source\")"), "{sql}");
        assert!(
            matches!(&params[2], BindParam::TextArray(values)
                if values == &vec!["internal".to_string(), "otel".to_string()]),
            "params: {params:?}"
        );
    }

    #[test]
    fn severity_eq_filter_is_case_insensitive() {
        let plan = data_plan(vec![scalar_filter("severity_text", FilterOp::Eq, "SEVERE")]);

        let (sql, params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(
            sql.contains("lower(\"logs\".\"severity_text\") = lower($3)"),
            "{sql}"
        );
        assert!(
            matches!(&params[2], BindParam::Text(value) if value == "SEVERE"),
            "params: {params:?}"
        );
    }

    #[test]
    fn severity_alias_eq_filter_is_case_insensitive() {
        let plan = data_plan(vec![scalar_filter("severity", FilterOp::Eq, "Error")]);

        let (sql, _) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(
            sql.contains("lower(\"logs\".\"severity_text\") = lower($3)"),
            "{sql}"
        );
    }

    #[test]
    fn severity_in_filter_lowers_column_and_values() {
        let plan = data_plan(vec![Filter {
            field: "severity_text".into(),
            op: FilterOp::In,
            value: FilterValue::List(vec!["SEVERE".into(), "Error".into(), "warning".into()]),
        }]);

        let (sql, params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(
            sql.contains("lower(\"logs\".\"severity_text\") = ANY($3)"),
            "{sql}"
        );
        assert!(
            matches!(&params[2], BindParam::TextArray(values)
                if values == &vec!["severe".to_string(), "error".to_string(), "warning".to_string()]),
            "params: {params:?}"
        );
    }

    #[test]
    fn severity_match_any_defers_both_severity_binds_after_service_filter() {
        let plan = data_plan(vec![
            Filter {
                field: "severity".into(),
                op: FilterOp::In,
                value: FilterValue::List(vec!["error".into(), "severity_number_error".into()]),
            },
            Filter {
                field: "severity_number".into(),
                op: FilterOp::In,
                value: FilterValue::List(vec!["17".into(), "18".into(), "19".into(), "20".into()]),
            },
            Filter {
                field: "severity_match".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("any".into()),
            },
            Filter {
                field: "service_name".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("serviceradar-core".into()),
            },
        ]);

        let (sql, params) = to_sql_and_params(&plan).expect("SQL should generate");

        assert!(
            sql.contains("\"logs\".\"service_name\" = $3"),
            "service filter must bind before the deferred severity predicate: {sql}"
        );
        assert!(
            sql.contains(
                "(lower(\"logs\".\"severity_text\") = ANY($4)) OR (((\"logs\".\"severity_text\" IS NULL) OR (lower(\"logs\".\"severity_text\") != ALL($5))) AND (\"logs\".\"severity_number\" = ANY($6)))"
            ),
            "{sql}"
        );
        assert_eq!(
            params.len(),
            8,
            "time, service, selected/recognized/numeric severity arrays, limit, offset"
        );
        assert!(matches!(&params[2], BindParam::Text(value) if value == "serviceradar-core"));
        assert!(matches!(&params[3], BindParam::TextArray(values) if values[0] == "error"));
        assert!(matches!(&params[4], BindParam::TextArray(values)
                if values.len() == 38
                    && values.contains(&"fatal".to_string())
                    && values.contains(&"severity_number_trace4".to_string())));
        assert!(
            matches!(&params[5], BindParam::IntArray(values) if values == &vec![17, 18, 19, 20])
        );
    }

    #[test]
    fn unknown_filter_field_returns_error() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(24);
        let plan = QueryPlan {
            entity: Entity::Logs,
            filters: vec![Filter {
                field: "unknown_field".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("test".to_string()),
            }],
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: None,
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
        };

        let result = build_query(&plan);
        match result {
            Err(err) => {
                assert!(
                    err.to_string().contains("unsupported filter field"),
                    "error should mention unsupported filter field: {}",
                    err
                );
            }
            Ok(_) => panic!("expected error for unknown filter field"),
        }
    }

    #[test]
    fn message_filter_is_supported() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(24);
        let plan = QueryPlan {
            entity: Entity::Logs,
            filters: vec![Filter {
                field: "message".into(),
                op: FilterOp::Like,
                value: FilterValue::Scalar("%earlyoom%".to_string()),
            }],
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: None,
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
        };

        let result = build_query(&plan);
        assert!(result.is_ok(), "message filter should be supported");
    }
}
