use super::{field_sql, flow_cidr_filter_sql, sql_literal, text_predicate_on};
use crate::{
    error::{Result, ServiceError},
    parser::{Filter, FilterOp},
    query::{QueryPlan, flows::literals::normalize_tag_literal},
};

/// Resolve flow aliases and JSON metadata without expanding the shared dataset dispatcher.
pub(super) fn row_field(field: &str, column: &impl Fn(&str) -> String) -> Option<String> {
    let alias = match field {
        "proto" => Some("protocol_num"),
        "in_if_index" => Some("input_snmp"),
        "out_if_index" => Some("output_snmp"),
        "process_pid" => Some("pid"),
        "process" | "process_name" => Some("comm"),
        "redacted_cmdline" => Some("cmdline"),
        _ => None,
    };
    if let Some(alias) = alias {
        return Some(column(alias));
    }
    match field {
        "flow_source" | "collector" => {
            return Some(format!("COALESCE({}, 'Unknown')", column("flow_source")));
        }
        "image" | "image_ref" => {
            return Some(format!(
                "COALESCE(get_json_string({0}, '$.image'), get_json_string({0}, '$.image_ref'))",
                column("workload_identity")
            ));
        }
        "attribution_status" | "status" => {
            return Some(format!(
                "CASE WHEN {} IS NULL THEN 'unmatched' ELSE 'attributed' END",
                column("pid")
            ));
        }
        _ => {}
    }
    let (document, key) = match field {
        "pod_name" | "pod_namespace" | "pod_uid" | "container_name" | "runtime_source" => {
            ("workload_identity", field)
        }
        "namespace" => ("workload_identity", "pod_namespace"),
        "service_name" | "public_endpoint_service" | "k8s_service" => {
            ("public_endpoint", "service_name")
        }
        "gateway_name" | "public_endpoint_gateway" => ("public_endpoint", "gateway_name"),
        "exposure_class" | "public_endpoint_class" => ("public_endpoint", "exposure_class"),
        "public_endpoint_namespace" => ("public_endpoint", "namespace"),
        "route_name" | "public_endpoint_route" => ("public_endpoint", "route_name"),
        _ => return None,
    };
    Some(format!("get_json_string({}, '$.{key}')", column(document)))
}

/// Flow row filters use the CNPG field and operator contract, independently
/// of the physical warehouse columns also available to stats and sorting.
pub(super) fn predicate(plan: &QueryPlan, filter: &Filter) -> Result<Option<String>> {
    let sql = match filter.field.as_str() {
        "device_id" => super::device_scope_sql(plan, filter)?,
        "src_cidr" => flow_cidr_filter_sql(filter, "src")?,
        "dst_cidr" => flow_cidr_filter_sql(filter, "dst")?,
        "device_addr" | "device_address" => device_addresses(plan, filter)?,
        "ip" | "endpoint_ip" => bidirectional_text(plan, filter)?,
        "port" | "endpoint_port" => bidirectional_port(plan, filter)?,
        "cidr" => {
            let src = flow_cidr_filter_sql(filter, "src")?;
            let dst = flow_cidr_filter_sql(filter, "dst")?;
            let join = if negative(&filter.op) { "AND" } else { "OR" };
            format!("({src} {join} {dst})")
        }
        "tag" | "src_tag" | "dst_tag" => tags(plan, filter)?,
        "near" | "src_near" | "dst_near" => {
            return Err(unreadable_catalog_filter(
                &filter.field,
                "geography distance (ip_geo_enrichment_cache.location)",
            ));
        }
        "threat_source" => {
            return Err(unreadable_catalog_filter(
                &filter.field,
                "text[] source list (ip_threat_intel_cache.sources)",
            ));
        }
        "threat_indicator" => {
            return Err(unreadable_catalog_filter(
                &filter.field,
                "cidr containment (threat_intel_indicators.indicator)",
            ));
        }
        "threat_matched" | "threat_observed_ip" | "threat_severity" => threat(plan, filter)?,
        "protocol_num" | "proto" => {
            require_op(filter, &[FilterOp::Eq, FilterOp::NotEq])?;
            integer_predicate(&field_sql(plan, &filter.field)?, filter, false)?
        }
        "src_port" | "src_endpoint_port" | "dst_port" | "dst_endpoint_port" => {
            let column = field_sql(plan, &filter.field)?;
            if matches!(filter.op, FilterOp::Like | FilterOp::NotLike) {
                text_predicate_on(&format!("CAST({column} AS STRING)"), filter, false)?
                    .unwrap_or_else(|| "TRUE".into())
            } else {
                require_op(
                    filter,
                    &[FilterOp::Eq, FilterOp::NotEq, FilterOp::In, FilterOp::NotIn],
                )?;
                integer_predicate(&column, filter, false)?
            }
        }
        "input_snmp" | "in_if_index" | "output_snmp" | "out_if_index" => {
            require_op(
                filter,
                &[FilterOp::Eq, FilterOp::NotEq, FilterOp::In, FilterOp::NotIn],
            )?;
            integer_predicate(&field_sql(plan, &filter.field)?, filter, true)?
        }
        "src_country_iso2" | "src_country" | "dst_country_iso2" | "dst_country" => {
            require_op(filter, &[FilterOp::Eq, FilterOp::NotEq])?;
            let value = filter.value.as_scalar()?.trim().to_ascii_uppercase();
            if value.len() != 2 || !value.bytes().all(|c| c.is_ascii_alphabetic()) {
                return Err(ServiceError::InvalidRequest(
                    "country must be a two-letter ISO code".into(),
                ));
            }
            let column = field_sql(plan, &filter.field)?;
            let eq = format!("COALESCE({column} = {}, FALSE)", sql_literal(&value));
            if negative(&filter.op) {
                format!("NOT ({eq})")
            } else {
                eq
            }
        }
        "pid" | "process_pid" | "uid" | "in_if_speed_bps" | "out_if_speed_bps" => {
            let column = format!("CAST({} AS STRING)", field_sql(plan, &filter.field)?);
            text_predicate_on(&column, filter, plan.stats.is_none())?
                .unwrap_or_else(|| "TRUE".into())
        }
        "src_ip"
        | "src_endpoint_ip"
        | "dst_ip"
        | "dst_endpoint_ip"
        | "protocol_name"
        | "protocol_group"
        | "proto_group"
        | "direction_label"
        | "dst_service_label"
        | "sampler_address"
        | "exporter_name"
        | "in_if_name"
        | "out_if_name"
        | "flow_source"
        | "collector"
        | "event_type"
        | "attribution_status"
        | "status"
        | "comm"
        | "process"
        | "process_name"
        | "cmdline"
        | "redacted_cmdline"
        | "container_id"
        | "agent_id"
        | "pod_name"
        | "pod_namespace"
        | "namespace"
        | "pod_uid"
        | "container_name"
        | "image"
        | "image_ref"
        | "runtime_source"
        | "service_name"
        | "public_endpoint_service"
        | "k8s_service"
        | "gateway_name"
        | "public_endpoint_gateway"
        | "exposure_class"
        | "public_endpoint_class"
        | "public_endpoint_namespace"
        | "route_name"
        | "public_endpoint_route"
        | "app" => text_predicate_on(
            &field_sql(plan, &filter.field)?,
            filter,
            plan.stats.is_none(),
        )?
        .unwrap_or_else(|| "TRUE".into()),
        _ => return Ok(None),
    };
    Ok(Some(sql))
}

fn device_addresses(plan: &QueryPlan, filter: &Filter) -> Result<String> {
    require_op(filter, &[FilterOp::Eq, FilterOp::In])?;
    if matches!(filter.op, FilterOp::In) && filter.value.as_list()?.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "device_addr requires a non-empty address list".into(),
        ));
    }
    let predicates = ["src_endpoint_ip", "dst_endpoint_ip", "sampler_address"]
        .iter()
        .map(|field| {
            super::filter_sql(
                plan,
                &Filter {
                    field: (*field).into(),
                    ..filter.clone()
                },
            )
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(format!("({})", predicates.join(" OR ")))
}

fn negative(op: &FilterOp) -> bool {
    matches!(op, FilterOp::NotEq | FilterOp::NotIn | FilterOp::NotLike)
}

fn require_op(filter: &Filter, allowed: &[FilterOp]) -> Result<()> {
    if allowed
        .iter()
        .any(|op| std::mem::discriminant(op) == std::mem::discriminant(&filter.op))
    {
        Ok(())
    } else {
        Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for {}: {:?}",
            filter.field, filter.op
        )))
    }
}

fn integer_predicate(column: &str, filter: &Filter, snmp: bool) -> Result<String> {
    let parse = |value: &str| -> Result<String> {
        let value = value.parse::<i64>().map_err(|_| {
            ServiceError::InvalidRequest(format!("{} must be an integer", filter.field))
        })?;
        if (snmp && value < 0) || (!snmp && i32::try_from(value).is_err()) {
            return Err(ServiceError::InvalidRequest(format!(
                "{} integer is out of range",
                filter.field
            )));
        }
        Ok(value.to_string())
    };
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            let value = parse(filter.value.as_scalar()?)?;
            let op = if negative(&filter.op) { "<>" } else { "=" };
            Ok(format!("{column} {op} {}", sql_literal(&value)))
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = filter
                .value
                .as_list()?
                .iter()
                .map(|v| parse(v))
                .collect::<Result<Vec<_>>>()?;
            if values.is_empty() {
                return Ok("TRUE".into());
            }
            let op = if negative(&filter.op) { "NOT IN" } else { "IN" };
            Ok(format!("{column} {op} ({})", values.join(", ")))
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported integer operator for {}",
            filter.field
        ))),
    }
}

fn bidirectional_text(plan: &QueryPlan, filter: &Filter) -> Result<String> {
    let predicates = ["src_endpoint_ip", "dst_endpoint_ip"]
        .iter()
        .map(|field| {
            text_predicate_on(&field_sql(plan, field)?, filter, true)
                .map(|sql| sql.unwrap_or_else(|| "TRUE".into()))
        })
        .collect::<Result<Vec<_>>>()?;
    let join = if negative(&filter.op) {
        " AND "
    } else {
        " OR "
    };
    Ok(format!("({})", predicates.join(join)))
}

fn bidirectional_port(plan: &QueryPlan, filter: &Filter) -> Result<String> {
    require_op(
        filter,
        &[FilterOp::Eq, FilterOp::NotEq, FilterOp::In, FilterOp::NotIn],
    )?;
    let predicates = ["src_endpoint_port", "dst_endpoint_port"]
        .iter()
        .map(|field| {
            let column = field_sql(plan, field)?;
            let sql = integer_predicate(&column, filter, false)?;
            Ok(if negative(&filter.op) {
                format!("({column} IS NULL OR {sql})")
            } else {
                sql
            })
        })
        .collect::<Result<Vec<_>>>()?;
    let join = if negative(&filter.op) {
        " AND "
    } else {
        " OR "
    };
    Ok(format!("({})", predicates.join(join)))
}

fn tags(plan: &QueryPlan, filter: &Filter) -> Result<String> {
    require_op(
        filter,
        &[FilterOp::Eq, FilterOp::NotEq, FilterOp::In, FilterOp::NotIn],
    )?;
    let raw = if matches!(filter.op, FilterOp::In | FilterOp::NotIn) {
        filter
            .value
            .as_list()?
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>()
    } else {
        vec![filter.value.as_scalar()?]
    };
    let values = raw
        .into_iter()
        .map(normalize_tag_literal)
        .collect::<Result<Vec<_>>>()?;
    let fields: &[&str] = match filter.field.as_str() {
        "src_tag" => &["src_prefix_tags"],
        "dst_tag" => &["dst_prefix_tags"],
        _ => &["src_prefix_tags", "dst_prefix_tags"],
    };
    let mut predicates = Vec::new();
    for field in fields {
        let column = field_sql(plan, field)?;
        for value in &values {
            predicates.push(format!("COALESCE(ARRAY_CONTAINS(CAST(PARSE_JSON({column}) AS ARRAY<VARCHAR(65533)>), {}), FALSE)", sql_literal(value)));
        }
    }
    let sql = if predicates.is_empty() {
        "FALSE".into()
    } else {
        format!("({})", predicates.join(" OR "))
    };
    Ok(if negative(&filter.op) {
        format!("NOT ({sql})")
    } else {
        sql
    })
}

/// StarRocks reads the threat cache through the plain `cnpg_platform` JDBC
/// catalog. StarRocks 4.1 has no JDBC pass-through table function
/// (`native_query` first ships in 4.2) and its JDBC catalog cannot read
/// PostgreSQL `text[]`, `inet`/`cidr` or `geography` columns, so every
/// predicate here is on a scalar cache column. StarRocks pushes these
/// predicates into the remote PostgreSQL query, so only matching rows cross
/// the catalog; flow telemetry itself stays in the warehouse.
fn threat_cache_membership(plan: &QueryPlan, condition: Option<&str>) -> Result<String> {
    let mut source = String::from(
        "SELECT c.ip FROM cnpg_platform.platform.ip_threat_intel_cache c \
         WHERE c.matched AND c.expires_at > UTC_TIMESTAMP()",
    );
    if let Some(condition) = condition {
        source.push_str(" AND ");
        source.push_str(condition);
    }
    let predicates = ["src_endpoint_ip", "dst_endpoint_ip"]
        .iter()
        .map(|field| {
            let endpoint = field_sql(plan, field)?;
            Ok(format!("COALESCE({endpoint} IN ({source}), FALSE)"))
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(format!("({})", predicates.join(" OR ")))
}

/// A filter whose exact semantics live in a column the StarRocks 4.1 JDBC
/// catalog cannot read. Refusing beats returning rows that differ from the
/// documented PostgreSQL meaning.
fn unreadable_catalog_filter(field: &str, column: &str) -> ServiceError {
    ServiceError::NotImplemented(format!(
        "starrocks_unsupported_filter: {field} needs the PostgreSQL {column}, \
         which the StarRocks JDBC catalog cannot read"
    ))
}

fn threat(plan: &QueryPlan, filter: &Filter) -> Result<String> {
    let mut invert = false;
    let condition = match filter.field.as_str() {
        "threat_matched" => {
            require_op(filter, &[FilterOp::Eq])?;
            invert = match filter.value.as_scalar()?.to_ascii_lowercase().as_str() {
                "true" | "t" | "yes" | "1" => false,
                "false" | "f" | "no" | "0" => true,
                other => {
                    return Err(ServiceError::InvalidRequest(format!(
                        "threat_matched requires true or false, got '{other}'"
                    )));
                }
            };
            None
        }
        "threat_observed_ip" => {
            require_op(filter, &[FilterOp::Eq])?;
            let value = filter.value.as_scalar()?;
            value.parse::<std::net::IpAddr>().map_err(|_| {
                ServiceError::InvalidRequest("threat_observed_ip must be an IP address".into())
            })?;
            Some(format!("c.ip = {}", sql_literal(value)))
        }
        "threat_severity" => {
            let op = match filter.op {
                FilterOp::Eq => "=",
                FilterOp::NotEq => "<>",
                FilterOp::Gt => ">",
                FilterOp::Gte => ">=",
                FilterOp::Lt => "<",
                FilterOp::Lte => "<=",
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "threat_severity requires a scalar comparison".into(),
                    ));
                }
            };
            let value = filter.value.as_scalar()?.parse::<i32>().map_err(|_| {
                ServiceError::InvalidRequest("threat_severity must be an integer".into())
            })?;
            Some(format!("c.max_severity {op} {value}"))
        }
        _ => unreachable!("threat field checked by predicate"),
    };
    let predicate = threat_cache_membership(plan, condition.as_deref())?;
    Ok(if invert {
        format!("NOT ({predicate})")
    } else {
        predicate
    })
}
