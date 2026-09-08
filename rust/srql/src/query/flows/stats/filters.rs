use super::*;

fn build_stats_text_filter(
    column: &str,
    filter: &Filter,
    binds: &mut Vec<FlowSqlBindValue>,
) -> Result<String> {
    match filter.op {
        FilterOp::Eq => {
            binds.push(FlowSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            Ok(format!("{column} = ?"))
        }
        FilterOp::NotEq => {
            binds.push(FlowSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            Ok(format!("({column} IS NULL OR {column} <> ?)"))
        }
        FilterOp::Like => {
            binds.push(FlowSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            Ok(format!("{column} ILIKE ?"))
        }
        FilterOp::NotLike => {
            binds.push(FlowSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            Ok(format!("({column} IS NULL OR {column} NOT ILIKE ?)"))
        }
        FilterOp::In => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok("1=1".to_string());
            }
            binds.push(FlowSqlBindValue::TextArray(values));
            Ok(format!("{column} = ANY(?)"))
        }
        FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok("1=1".to_string());
            }
            binds.push(FlowSqlBindValue::TextArray(values));
            Ok(format!("({column} IS NULL OR NOT ({column} = ANY(?)))"))
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for text filter: {:?}",
            filter.op
        ))),
    }
}

fn build_stats_bigint_filter(
    column_expr: &str,
    filter: &Filter,
    binds: &mut Vec<FlowSqlBindValue>,
    label: &str,
) -> Result<String> {
    match filter.op {
        FilterOp::Eq => {
            let value =
                filter.value.as_scalar()?.parse::<i64>().map_err(|_| {
                    ServiceError::InvalidRequest(format!("{label} must be an integer"))
                })?;
            binds.push(FlowSqlBindValue::Int(value));
            Ok(format!("{column_expr} = ?"))
        }
        FilterOp::NotEq => {
            let value =
                filter.value.as_scalar()?.parse::<i64>().map_err(|_| {
                    ServiceError::InvalidRequest(format!("{label} must be an integer"))
                })?;
            binds.push(FlowSqlBindValue::Int(value));
            Ok(format!("({column_expr} IS NULL OR {column_expr} <> ?)"))
        }
        FilterOp::In => {
            let values = filter.value.as_list()?;
            if values.is_empty() {
                return Ok("1=1".to_string());
            }
            let mut out: Vec<i64> = Vec::with_capacity(values.len());
            for v in values {
                out.push(v.parse::<i64>().map_err(|_| {
                    ServiceError::InvalidRequest(format!("{label} must be an integer"))
                })?);
            }
            binds.push(FlowSqlBindValue::IntArray(out));
            Ok(format!("{column_expr} = ANY(?)"))
        }
        FilterOp::NotIn => {
            let values = filter.value.as_list()?;
            if values.is_empty() {
                return Ok("1=1".to_string());
            }
            let mut out: Vec<i64> = Vec::with_capacity(values.len());
            for v in values {
                out.push(v.parse::<i64>().map_err(|_| {
                    ServiceError::InvalidRequest(format!("{label} must be an integer"))
                })?);
            }
            binds.push(FlowSqlBindValue::IntArray(out));
            Ok(format!(
                "({column_expr} IS NULL OR NOT ({column_expr} = ANY(?)))"
            ))
        }
        FilterOp::Like | FilterOp::NotLike => {
            // Numeric-like filters are supported via ::text matching in the row query; keep that here too.
            binds.push(FlowSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            let text_expr = format!("{column_expr}::text");
            Ok(match filter.op {
                FilterOp::Like => format!("{text_expr} ILIKE ?"),
                FilterOp::NotLike => format!("({column_expr} IS NULL OR {text_expr} NOT ILIKE ?)"),
                _ => unreachable!(),
            })
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "{label} filter does not support this operator"
        ))),
    }
}

/// `ip:` across both flow endpoints for the stats path.
///
/// A positive match is "either endpoint matches"; a negative match is "neither
/// endpoint matches", which by De Morgan is the AND of the two per-side negatives,
/// not their OR. `build_stats_text_filter` already emits NULL-safe negative clauses
/// per column, so joining them with AND is the whole difference.
///
/// The two calls push one bind each, in src-then-dst order, matching the clause.
fn build_stats_bidirectional_ip_filter(
    filter: &Filter,
    binds: &mut Vec<FlowSqlBindValue>,
) -> Result<String> {
    let joiner = match filter.op {
        FilterOp::NotEq | FilterOp::NotLike | FilterOp::NotIn => " AND ",
        _ => " OR ",
    };

    let src = build_stats_text_filter("f.src_endpoint_ip", filter, binds)?;
    let dst = build_stats_text_filter("f.dst_endpoint_ip", filter, binds)?;

    Ok(format!("({src}{joiner}{dst})"))
}

/// Every address belonging to one device -- either endpoint, or the sampler it
/// exports from -- as a single list (stats path). See flows/filters.rs for why
/// this exists instead of scoping by `device_id:`.
fn build_stats_device_addr_filter(
    filter: &Filter,
    binds: &mut Vec<FlowSqlBindValue>,
) -> Result<String> {
    if !matches!(filter.op, FilterOp::Eq | FilterOp::In) {
        return Err(ServiceError::InvalidRequest(
            "device_addr filter supports equality and list matching".into(),
        ));
    }

    // Rejected, not delegated. `build_stats_text_filter` renders an empty `In`
    // as `1=1`, so an empty address set would widen this to every flow in the
    // window -- a device's stat cards would total the whole fleet's traffic.
    // The row path rejects it too (for a different reason: diesel emits no
    // placeholder, which desyncs bind arity), so all three paths agree.
    if matches!(filter.op, FilterOp::In) && filter.value.as_list()?.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "device_addr filter requires at least one address".into(),
        ));
    }

    let src = build_stats_text_filter("f.src_endpoint_ip", filter, binds)?;
    let dst = build_stats_text_filter("f.dst_endpoint_ip", filter, binds)?;
    let sampler = build_stats_text_filter("f.sampler_address", filter, binds)?;

    Ok(format!("({src} OR {dst} OR {sampler})"))
}

/// `port:` across both flow endpoint ports (stats path).
fn build_stats_bidirectional_port_filter(
    filter: &Filter,
    binds: &mut Vec<FlowSqlBindValue>,
) -> Result<String> {
    let joiner = match filter.op {
        FilterOp::NotEq | FilterOp::NotIn => " AND ",
        _ => " OR ",
    };

    let src = build_stats_bigint_filter("f.src_endpoint_port::bigint", filter, binds, "port")?;
    let dst = build_stats_bigint_filter("f.dst_endpoint_port::bigint", filter, binds, "port")?;

    Ok(format!("({src}{joiner}{dst})"))
}

pub(in crate::query::flows) fn build_stats_filter_clause(
    filter: &Filter,
    binds: &mut Vec<FlowSqlBindValue>,
) -> Result<String> {
    match filter.field.as_str() {
        "device_id" => flow_device_scope_expr(filter),
        "src_endpoint_ip" | "src_ip" => build_stats_text_filter("f.src_endpoint_ip", filter, binds),
        "dst_endpoint_ip" | "dst_ip" => build_stats_text_filter("f.dst_endpoint_ip", filter, binds),
        "ip" | "endpoint_ip" => build_stats_bidirectional_ip_filter(filter, binds),
        "device_addr" | "device_address" => build_stats_device_addr_filter(filter, binds),
        "port" | "endpoint_port" => build_stats_bidirectional_port_filter(filter, binds),
        "protocol_name" => build_stats_text_filter("f.protocol_name", filter, binds),
        "sampler_address" => build_stats_text_filter("f.sampler_address", filter, binds),
        "flow_source" | "collector" => build_stats_text_filter(FLOW_SOURCE_EXPR, filter, binds),
        "event_type" => build_stats_text_filter("f.ocsf_payload ->> 'event_type'", filter, binds),
        "attribution_status" | "status" => {
            build_stats_text_filter(ATTRIBUTION_STATUS_EXPR_ALIASED, filter, binds)
        }
        "pid" | "process_pid" => {
            build_stats_text_filter(ATTRIBUTION_PID_EXPR_ALIASED, filter, binds)
        }
        "uid" => build_stats_text_filter(ATTRIBUTION_UID_EXPR_ALIASED, filter, binds),
        "comm" | "process" | "process_name" => {
            build_stats_text_filter(ATTRIBUTION_COMM_EXPR_ALIASED, filter, binds)
        }
        "cmdline" | "redacted_cmdline" => {
            build_stats_text_filter(ATTRIBUTION_CMDLINE_EXPR_ALIASED, filter, binds)
        }
        "container_id" => {
            build_stats_text_filter(ATTRIBUTION_CONTAINER_ID_EXPR_ALIASED, filter, binds)
        }
        "agent_id" => build_stats_text_filter(ATTRIBUTION_AGENT_ID_EXPR_ALIASED, filter, binds),
        "pod_name" => build_stats_text_filter(ATTRIBUTION_POD_NAME_EXPR_ALIASED, filter, binds),
        "pod_namespace" | "namespace" => {
            build_stats_text_filter(ATTRIBUTION_POD_NAMESPACE_EXPR_ALIASED, filter, binds)
        }
        "pod_uid" => build_stats_text_filter(ATTRIBUTION_POD_UID_EXPR_ALIASED, filter, binds),
        "container_name" => {
            build_stats_text_filter(ATTRIBUTION_CONTAINER_NAME_EXPR_ALIASED, filter, binds)
        }
        "image" | "image_ref" => {
            build_stats_text_filter(ATTRIBUTION_IMAGE_EXPR_ALIASED, filter, binds)
        }
        "runtime_source" => {
            build_stats_text_filter(ATTRIBUTION_RUNTIME_SOURCE_EXPR_ALIASED, filter, binds)
        }
        "service_name" | "public_endpoint_service" | "k8s_service" => build_stats_text_filter(
            ATTRIBUTION_PUBLIC_ENDPOINT_SERVICE_EXPR_ALIASED,
            filter,
            binds,
        ),
        "gateway_name" | "public_endpoint_gateway" => build_stats_text_filter(
            ATTRIBUTION_PUBLIC_ENDPOINT_GATEWAY_EXPR_ALIASED,
            filter,
            binds,
        ),
        "exposure_class" | "public_endpoint_class" => build_stats_text_filter(
            ATTRIBUTION_PUBLIC_ENDPOINT_EXPOSURE_EXPR_ALIASED,
            filter,
            binds,
        ),
        "public_endpoint_namespace" => build_stats_text_filter(
            ATTRIBUTION_PUBLIC_ENDPOINT_NAMESPACE_EXPR_ALIASED,
            filter,
            binds,
        ),
        "route_name" | "public_endpoint_route" => build_stats_text_filter(
            ATTRIBUTION_PUBLIC_ENDPOINT_ROUTE_EXPR_ALIASED,
            filter,
            binds,
        ),
        "exporter_name" => build_stats_text_filter(FLOW_EXPORTER_NAME_GROUP_EXPR, filter, binds),
        "input_snmp" | "in_if_index" => {
            build_stats_bigint_filter(FLOW_INPUT_SNMP_EXPR, filter, binds, "input_snmp")
        }
        "output_snmp" | "out_if_index" => {
            build_stats_bigint_filter(FLOW_OUTPUT_SNMP_EXPR, filter, binds, "output_snmp")
        }
        "in_if_name" => build_stats_text_filter(FLOW_IN_IF_NAME_GROUP_EXPR, filter, binds),
        "out_if_name" => build_stats_text_filter(FLOW_OUT_IF_NAME_GROUP_EXPR, filter, binds),
        "in_if_speed_bps" => {
            build_stats_text_filter(FLOW_IN_IF_SPEED_BPS_GROUP_EXPR, filter, binds)
        }
        "out_if_speed_bps" => {
            build_stats_text_filter(FLOW_OUT_IF_SPEED_BPS_GROUP_EXPR, filter, binds)
        }
        "protocol_group" | "proto_group" => {
            build_stats_text_filter(FLOW_PROTOCOL_GROUP_EXPR, filter, binds)
        }
        "protocol_num" | "proto" => {
            // protocol_num is int4; cast to bigint to keep bind typing consistent.
            build_stats_bigint_filter("f.protocol_num::bigint", filter, binds, "protocol_num")
        }
        "src_port" | "src_endpoint_port" => {
            build_stats_bigint_filter("f.src_endpoint_port::bigint", filter, binds, "src_port")
        }
        "dst_port" | "dst_endpoint_port" => {
            build_stats_bigint_filter("f.dst_endpoint_port::bigint", filter, binds, "dst_port")
        }
        "src_cidr" => {
            match filter.op {
                FilterOp::Eq | FilterOp::NotEq => {
                    let value = filter.value.as_scalar()?.to_string();
                    let cidr = normalize_cidr_literal(&value)?;
                    // Use binds in the stats query path (safe for user-supplied filters).
                    binds.push(FlowSqlBindValue::Text(cidr));
                    match filter.op {
                        FilterOp::Eq => {
                            Ok("(try_inet(NULLIF(f.src_endpoint_ip, '')) <<= ?::cidr)".to_string())
                        }
                        FilterOp::NotEq => Ok(
                            "(try_inet(NULLIF(f.src_endpoint_ip, '')) IS NULL OR NOT (try_inet(NULLIF(f.src_endpoint_ip, '')) <<= ?::cidr))"
                                .to_string(),
                        ),
                        _ => unreachable!(),
                    }
                }
                FilterOp::In | FilterOp::NotIn => {
                    let values = filter.value.as_list()?;
                    if values.is_empty() {
                        return Ok("1=1".to_string());
                    }
                    let mut out: Vec<String> = Vec::with_capacity(values.len());
                    for v in values {
                        out.push(normalize_cidr_literal(v)?);
                    }
                    binds.push(FlowSqlBindValue::TextArray(out));
                    match filter.op {
                        FilterOp::In => Ok(
                            "(try_inet(NULLIF(f.src_endpoint_ip, '')) <<= ANY(?::cidr[]))"
                                .to_string(),
                        ),
                        FilterOp::NotIn => Ok(
                            "(try_inet(NULLIF(f.src_endpoint_ip, '')) IS NULL OR NOT (try_inet(NULLIF(f.src_endpoint_ip, '')) <<= ANY(?::cidr[])))"
                                .to_string(),
                        ),
                        _ => unreachable!(),
                    }
                }
                _ => Err(ServiceError::InvalidRequest(
                    "src_cidr filter only supports equality or list matching".into(),
                )),
            }
        }
        "dst_cidr" => match filter.op {
            FilterOp::Eq | FilterOp::NotEq => {
                let value = filter.value.as_scalar()?.to_string();
                let cidr = normalize_cidr_literal(&value)?;
                binds.push(FlowSqlBindValue::Text(cidr));
                match filter.op {
                        FilterOp::Eq => Ok(
                            "(try_inet(NULLIF(f.dst_endpoint_ip, '')) <<= ?::cidr)".to_string(),
                        ),
                        FilterOp::NotEq => Ok(
                            "(try_inet(NULLIF(f.dst_endpoint_ip, '')) IS NULL OR NOT (try_inet(NULLIF(f.dst_endpoint_ip, '')) <<= ?::cidr))"
                                .to_string(),
                        ),
                        _ => unreachable!(),
                    }
            }
            FilterOp::In | FilterOp::NotIn => {
                let values = filter.value.as_list()?;
                if values.is_empty() {
                    return Ok("1=1".to_string());
                }
                let mut out: Vec<String> = Vec::with_capacity(values.len());
                for v in values {
                    out.push(normalize_cidr_literal(v)?);
                }
                binds.push(FlowSqlBindValue::TextArray(out));
                match filter.op {
                        FilterOp::In => Ok(
                            "(try_inet(NULLIF(f.dst_endpoint_ip, '')) <<= ANY(?::cidr[]))"
                                .to_string(),
                        ),
                        FilterOp::NotIn => Ok(
                            "(try_inet(NULLIF(f.dst_endpoint_ip, '')) IS NULL OR NOT (try_inet(NULLIF(f.dst_endpoint_ip, '')) <<= ANY(?::cidr[])))"
                                .to_string(),
                        ),
                        _ => unreachable!(),
                    }
            }
            _ => Err(ServiceError::InvalidRequest(
                "dst_cidr filter only supports equality or list matching".into(),
            )),
        },
        // Bare `cidr:` mirrors `near:` -- containment on either endpoint. Only equality is
        // supported, matching `src_cidr` / `dst_cidr`.
        "cidr" => match filter.op {
            FilterOp::Eq | FilterOp::NotEq => {
                let cidr = normalize_cidr_literal(filter.value.as_scalar()?)?;
                // One bind per side, in src-then-dst order, matching the clause below.
                binds.push(FlowSqlBindValue::Text(cidr.clone()));
                binds.push(FlowSqlBindValue::Text(cidr));

                match filter.op {
                    FilterOp::Eq => Ok("(try_inet(NULLIF(f.src_endpoint_ip, '')) <<= ?::cidr \
                         OR try_inet(NULLIF(f.dst_endpoint_ip, '')) <<= ?::cidr)"
                        .to_string()),
                    // "Neither endpoint is inside the block": the AND of the two NULL-safe
                    // per-side negatives, not their OR.
                    FilterOp::NotEq => Ok(
                        "((try_inet(NULLIF(f.src_endpoint_ip, '')) IS NULL OR NOT (try_inet(NULLIF(f.src_endpoint_ip, '')) <<= ?::cidr)) \
                         AND (try_inet(NULLIF(f.dst_endpoint_ip, '')) IS NULL OR NOT (try_inet(NULLIF(f.dst_endpoint_ip, '')) <<= ?::cidr)))"
                            .to_string(),
                    ),
                    _ => unreachable!(),
                }
            }
            _ => Err(ServiceError::InvalidRequest(
                "cidr filter only supports equality".into(),
            )),
        },
        "direction" => {
            let expr = format!("({})", FLOW_DIRECTION_EXPR);
            build_stats_text_filter(&expr, filter, binds)
        }
        "app" => {
            let expr = format!("({})", FLOW_APP_EXPR);
            build_stats_text_filter(&expr, filter, binds)
        }
        "src_country_iso2" | "src_country" => {
            build_stats_text_filter("COALESCE(src_geo.country_iso2, 'Unknown')", filter, binds)
        }
        "dst_country_iso2" | "dst_country" => {
            build_stats_text_filter("COALESCE(dst_geo.country_iso2, 'Unknown')", filter, binds)
        }
        "tag" | "src_tag" | "dst_tag" => build_stats_tag_filter(filter),
        "near" | "src_near" | "dst_near" => build_stats_near_filter(filter),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for flows stats: '{other}'"
        ))),
    }
}

fn build_stats_near_filter(filter: &Filter) -> Result<String> {
    use crate::query::flows::literals::{NearSide, near_exists_sql, normalize_near_literal};

    let side = match filter.field.as_str() {
        "src_near" => NearSide::Src,
        "dst_near" => NearSide::Dst,
        "near" => NearSide::Either,
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported near filter field: '{other}'"
            )));
        }
    };

    // Stats SQL aliases the flows table as `f`.
    let rewrite_ip = |sql: String| {
        sql.replace("src_endpoint_ip", "f.src_endpoint_ip")
            .replace("dst_endpoint_ip", "f.dst_endpoint_ip")
    };

    match filter.op {
        FilterOp::Eq => {
            let point = normalize_near_literal(filter.value.as_scalar()?)?;
            Ok(rewrite_ip(near_exists_sql(point, side)))
        }
        FilterOp::NotEq => {
            let point = normalize_near_literal(filter.value.as_scalar()?)?;
            Ok(format!(
                "(NOT {})",
                rewrite_ip(near_exists_sql(point, side))
            ))
        }
        _ => Err(ServiceError::InvalidRequest(
            "near filter only supports equality (e.g. near:30.27,-97.74,50km)".into(),
        )),
    }
}

fn build_stats_tag_filter(filter: &Filter) -> Result<String> {
    use crate::query::flows::literals::tag_filter_sql;

    let expr = tag_filter_sql(
        filter.field.as_str(),
        &filter.op,
        &filter.value,
        "f.src_prefix_tags",
        "f.dst_prefix_tags",
    )?;

    match filter.op {
        FilterOp::Eq | FilterOp::In => Ok(expr),
        FilterOp::NotEq | FilterOp::NotIn => Ok(format!("(NOT {expr})")),
        _ => Err(ServiceError::InvalidRequest(
            "tag filter only supports equality or list matching".into(),
        )),
    }
}
