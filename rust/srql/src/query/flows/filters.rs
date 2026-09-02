use super::*;

pub(super) fn apply_filter<'a>(
    mut query: FlowsQuery<'a>,
    filter: &Filter,
) -> Result<FlowsQuery<'a>> {
    match filter.field.as_str() {
        "device_id" => {
            let expr = flow_device_scope_expr(filter)?;
            query = query.filter(sql::<diesel::sql_types::Bool>(&expr));
        }
        "src_endpoint_ip" | "src_ip" => {
            query = apply_text_filter!(query, filter, src_endpoint_ip)?;
        }
        "dst_endpoint_ip" | "dst_ip" => {
            query = apply_text_filter!(query, filter, dst_endpoint_ip)?;
        }
        "ip" | "endpoint_ip" => {
            query = apply_bidirectional_ip_filter(query, filter)?;
        }
        // Every address that belongs to one device: its endpoint IPs and the
        // sampler addresses it exports from, matched as a single list.
        //
        // This exists so `device_id:` scoping can be expressed with *values*.
        // `device_id:` resolves the address set with correlated ARRAY(SELECT ...)
        // subqueries, and PostgreSQL cannot estimate selectivity through those
        // InitPlans -- it abandons the src/dst endpoint indexes and filters the
        // whole time window. Measured on one device over 24h: est. cost 89_347
        // for the InitPlan form against 19_546 once the values are present and
        // the planner can build a BitmapOr over the existing indexes.
        //
        // A sampler address is one of the device's own interface addresses, so
        // folding both into one list is the natural shape rather than a
        // widening: a flow to or from the router's WAN address does involve the
        // router.
        "device_addr" | "device_address" => {
            query = apply_device_addr_filter(query, filter)?;
        }
        // Bidirectional port: either side of the 5-tuple (same role as `ip:`).
        // Prefer this over unsupported `(dst_port:N OR src_port:N)` boolean OR.
        "port" | "endpoint_port" => {
            query = apply_bidirectional_port_filter(query, filter)?;
        }
        "protocol_name" => {
            query = apply_text_filter!(query, filter, protocol_name)?;
        }
        "sampler_address" => {
            query = apply_text_filter!(query, filter, sampler_address)?;
        }
        "exporter_name" => {
            let expr = sql::<Text>(FLOW_EXPORTER_NAME_GROUP_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "in_if_name" => {
            let expr = sql::<Text>(FLOW_IN_IF_NAME_GROUP_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "out_if_name" => {
            let expr = sql::<Text>(FLOW_OUT_IF_NAME_GROUP_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "input_snmp" | "in_if_index" => {
            query = apply_snmp_index_filter(query, filter, FLOW_INPUT_SNMP_EXPR, "input_snmp")?;
        }
        "output_snmp" | "out_if_index" => {
            query = apply_snmp_index_filter(query, filter, FLOW_OUTPUT_SNMP_EXPR, "output_snmp")?;
        }
        "in_if_speed_bps" => {
            let expr = sql::<Text>(FLOW_IN_IF_SPEED_BPS_GROUP_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "out_if_speed_bps" => {
            let expr = sql::<Text>(FLOW_OUT_IF_SPEED_BPS_GROUP_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "protocol_num" | "proto" => {
            let value = filter.value.as_scalar()?.parse::<i32>().map_err(|_| {
                ServiceError::InvalidRequest("protocol_num must be an integer".into())
            })?;
            query = apply_eq_filter!(
                query,
                filter,
                protocol_num,
                value,
                "protocol_num filter only supports equality"
            )?;
        }
        "src_port" | "src_endpoint_port" => match filter.op {
            FilterOp::Eq | FilterOp::NotEq => {
                let value = filter.value.as_scalar()?.parse::<i32>().map_err(|_| {
                    ServiceError::InvalidRequest("src_port must be an integer".into())
                })?;
                query = apply_eq_filter!(
                    query,
                    filter,
                    src_endpoint_port,
                    value,
                    "src_port filter only supports equality"
                )?;
            }
            FilterOp::Like | FilterOp::NotLike => {
                let value = filter.value.as_scalar()?.to_string();
                let text_column = sql::<Text>("src_endpoint_port::text");
                query = match filter.op {
                    FilterOp::Like => query.filter(text_column.ilike(value)),
                    FilterOp::NotLike => query.filter(text_column.not_ilike(value)),
                    _ => query,
                };
            }
            _ => {
                return Err(ServiceError::InvalidRequest(
                    "src_port filter only supports equality or wildcard matching".into(),
                ));
            }
        },
        "dst_port" | "dst_endpoint_port" => match filter.op {
            FilterOp::Eq | FilterOp::NotEq => {
                let value = filter.value.as_scalar()?.parse::<i32>().map_err(|_| {
                    ServiceError::InvalidRequest("dst_port must be an integer".into())
                })?;
                query = apply_eq_filter!(
                    query,
                    filter,
                    dst_endpoint_port,
                    value,
                    "dst_port filter only supports equality"
                )?;
            }
            FilterOp::Like | FilterOp::NotLike => {
                let value = filter.value.as_scalar()?.to_string();
                let text_column = sql::<Text>("dst_endpoint_port::text");
                query = match filter.op {
                    FilterOp::Like => query.filter(text_column.ilike(value)),
                    FilterOp::NotLike => query.filter(text_column.not_ilike(value)),
                    _ => query,
                };
            }
            _ => {
                return Err(ServiceError::InvalidRequest(
                    "dst_port filter only supports equality or wildcard matching".into(),
                ));
            }
        },
        "direction" => {
            // direction is computed from local CIDR configuration; support text-like operators.
            let expr = sql::<Text>(FLOW_DIRECTION_EXPR);
            match filter.op {
                FilterOp::Eq => {
                    let value = filter.value.as_scalar()?.to_string();
                    query = query.filter(expr.eq(value));
                }
                FilterOp::NotEq => {
                    let value = filter.value.as_scalar()?.to_string();
                    query = query.filter(expr.ne(value));
                }
                FilterOp::Like => {
                    let value = filter.value.as_scalar()?.to_string();
                    query = query.filter(expr.ilike(value));
                }
                FilterOp::NotLike => {
                    let value = filter.value.as_scalar()?.to_string();
                    query = query.filter(expr.not_ilike(value));
                }
                FilterOp::In => {
                    let values = filter.value.as_list()?.to_vec();
                    if !values.is_empty() {
                        query = query.filter(expr.eq_any(values));
                    }
                }
                FilterOp::NotIn => {
                    let values = filter.value.as_list()?.to_vec();
                    if !values.is_empty() {
                        query = query.filter(not(expr.eq_any(values)));
                    }
                }
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "direction filter only supports equality, wildcard, or list matching"
                            .into(),
                    ));
                }
            }
        }
        "flow_source" | "collector" => {
            let expr = sql::<Text>(FLOW_SOURCE_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "event_type" => {
            let expr = sql::<Text>("ocsf_payload ->> 'event_type'");
            query = apply_text_filter!(query, filter, expr)?;
        }
        "attribution_status" | "status" => {
            let expr = sql::<Text>(ATTRIBUTION_STATUS_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "pid" | "process_pid" => {
            let expr = sql::<Text>(ATTRIBUTION_PID_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "uid" => {
            let expr = sql::<Text>(ATTRIBUTION_UID_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "comm" | "process" | "process_name" => {
            let expr = sql::<Text>(ATTRIBUTION_COMM_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "cmdline" | "redacted_cmdline" => {
            let expr = sql::<Text>(ATTRIBUTION_CMDLINE_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "container_id" => {
            let expr = sql::<Text>(ATTRIBUTION_CONTAINER_ID_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "agent_id" => {
            let expr = sql::<Text>(ATTRIBUTION_AGENT_ID_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "pod_name" => {
            let expr = sql::<Text>(ATTRIBUTION_POD_NAME_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "pod_namespace" | "namespace" => {
            let expr = sql::<Text>(ATTRIBUTION_POD_NAMESPACE_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "pod_uid" => {
            let expr = sql::<Text>(ATTRIBUTION_POD_UID_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "container_name" => {
            let expr = sql::<Text>(ATTRIBUTION_CONTAINER_NAME_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "image" | "image_ref" => {
            let expr = sql::<Text>(ATTRIBUTION_IMAGE_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "runtime_source" => {
            let expr = sql::<Text>(ATTRIBUTION_RUNTIME_SOURCE_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "service_name" | "public_endpoint_service" | "k8s_service" => {
            let expr = sql::<Text>(ATTRIBUTION_PUBLIC_ENDPOINT_SERVICE_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "gateway_name" | "public_endpoint_gateway" => {
            let expr = sql::<Text>(ATTRIBUTION_PUBLIC_ENDPOINT_GATEWAY_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "exposure_class" | "public_endpoint_class" => {
            let expr = sql::<Text>(ATTRIBUTION_PUBLIC_ENDPOINT_EXPOSURE_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "public_endpoint_namespace" => {
            let expr = sql::<Text>(ATTRIBUTION_PUBLIC_ENDPOINT_NAMESPACE_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "route_name" | "public_endpoint_route" => {
            let expr = sql::<Text>(ATTRIBUTION_PUBLIC_ENDPOINT_ROUTE_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "protocol_group" | "proto_group" => {
            let expr = sql::<Text>(FLOW_PROTOCOL_GROUP_EXPR);
            match filter.op {
                FilterOp::Eq => {
                    let value = filter.value.as_scalar()?.to_string();
                    query = query.filter(expr.eq(value));
                }
                FilterOp::NotEq => {
                    let value = filter.value.as_scalar()?.to_string();
                    query = query.filter(expr.ne(value));
                }
                FilterOp::Like => {
                    let value = filter.value.as_scalar()?.to_string();
                    query = query.filter(expr.ilike(value));
                }
                FilterOp::NotLike => {
                    let value = filter.value.as_scalar()?.to_string();
                    query = query.filter(expr.not_ilike(value));
                }
                FilterOp::In => {
                    let values = filter.value.as_list()?.to_vec();
                    if !values.is_empty() {
                        query = query.filter(expr.eq_any(values));
                    }
                }
                FilterOp::NotIn => {
                    let values = filter.value.as_list()?.to_vec();
                    if !values.is_empty() {
                        query = query.filter(not(expr.eq_any(values)));
                    }
                }
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "protocol_group filter only supports equality, wildcard, or list matching"
                            .into(),
                    ));
                }
            }
        }
        "app" => {
            let expr = sql::<Text>(FLOW_APP_EXPR);
            match filter.op {
                FilterOp::Eq => {
                    let value = filter.value.as_scalar()?.to_string();
                    query = query.filter(expr.eq(value));
                }
                FilterOp::NotEq => {
                    let value = filter.value.as_scalar()?.to_string();
                    query = query.filter(expr.ne(value));
                }
                FilterOp::Like => {
                    let value = filter.value.as_scalar()?.to_string();
                    query = query.filter(expr.ilike(value));
                }
                FilterOp::NotLike => {
                    let value = filter.value.as_scalar()?.to_string();
                    query = query.filter(expr.not_ilike(value));
                }
                FilterOp::In => {
                    let values = filter.value.as_list()?.to_vec();
                    if !values.is_empty() {
                        query = query.filter(expr.eq_any(values));
                    }
                }
                FilterOp::NotIn => {
                    let values = filter.value.as_list()?.to_vec();
                    if !values.is_empty() {
                        query = query.filter(not(expr.eq_any(values)));
                    }
                }
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "app filter only supports equality, wildcard, or list matching".into(),
                    ));
                }
            }
        }
        "src_country_iso2" | "src_country" => {
            let cc = filter.value.as_scalar()?.to_string().to_uppercase();
            if cc.len() != 2 || !cc.chars().all(|c| c.is_ascii_alphabetic()) {
                return Err(ServiceError::InvalidRequest(
                    "src_country_iso2 must be a 2-letter ISO2 code".into(),
                ));
            }

            let exists = sql::<diesel::sql_types::Bool>(&format!(
                "EXISTS (SELECT 1 FROM ip_geo_enrichment_cache g WHERE g.ip = NULLIF(src_endpoint_ip, '') AND g.country_iso2 = '{cc}' AND (g.expires_at IS NULL OR g.expires_at > now()))"
            ));

            match filter.op {
                FilterOp::Eq => query = query.filter(exists),
                FilterOp::NotEq => query = query.filter(not(exists)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "src_country_iso2 filter only supports equality".into(),
                    ));
                }
            }
        }
        "dst_country_iso2" | "dst_country" => {
            let cc = filter.value.as_scalar()?.to_string().to_uppercase();
            if cc.len() != 2 || !cc.chars().all(|c| c.is_ascii_alphabetic()) {
                return Err(ServiceError::InvalidRequest(
                    "dst_country_iso2 must be a 2-letter ISO2 code".into(),
                ));
            }

            let exists = sql::<diesel::sql_types::Bool>(&format!(
                "EXISTS (SELECT 1 FROM ip_geo_enrichment_cache g WHERE g.ip = NULLIF(dst_endpoint_ip, '') AND g.country_iso2 = '{cc}' AND (g.expires_at IS NULL OR g.expires_at > now()))"
            ));

            match filter.op {
                FilterOp::Eq => query = query.filter(exists),
                FilterOp::NotEq => query = query.filter(not(exists)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "dst_country_iso2 filter only supports equality".into(),
                    ));
                }
            }
        }
        "src_cidr" => {
            let cidr = normalize_cidr_literal(filter.value.as_scalar()?)?;
            let within = sql::<diesel::sql_types::Bool>(&format!(
                "(try_inet(NULLIF(src_endpoint_ip, '')) <<= '{cidr}'::cidr)"
            ));

            match filter.op {
                FilterOp::Eq => query = query.filter(within),
                FilterOp::NotEq => query = query.filter(not(within)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "src_cidr filter only supports equality".into(),
                    ));
                }
            }
        }
        "dst_cidr" => {
            let cidr = normalize_cidr_literal(filter.value.as_scalar()?)?;
            let within = sql::<diesel::sql_types::Bool>(&format!(
                "(try_inet(NULLIF(dst_endpoint_ip, '')) <<= '{cidr}'::cidr)"
            ));

            match filter.op {
                FilterOp::Eq => query = query.filter(within),
                FilterOp::NotEq => query = query.filter(not(within)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "dst_cidr filter only supports equality".into(),
                    ));
                }
            }
        }
        "cidr" => {
            let cidr = normalize_cidr_literal(filter.value.as_scalar()?)?;
            let within = sql::<diesel::sql_types::Bool>(&format!(
                "(try_inet(NULLIF(src_endpoint_ip, '')) <<= '{cidr}'::cidr \
                 OR try_inet(NULLIF(dst_endpoint_ip, '')) <<= '{cidr}'::cidr)"
            ));

            match filter.op {
                FilterOp::Eq => query = query.filter(within),
                FilterOp::NotEq => query = query.filter(not(within)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "cidr filter only supports equality".into(),
                    ));
                }
            }
        }
        "tag" | "src_tag" | "dst_tag" => {
            query = apply_tag_filter(query, filter)?;
        }
        "near" | "src_near" | "dst_near" => {
            query = apply_near_filter(query, filter)?;
        }
        "threat_matched" | "threat_source" | "threat_indicator" | "threat_observed_ip"
        | "threat_severity" => {
            query = apply_threat_filter(query, filter)?;
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for flows: '{other}'"
            )));
        }
    }

    Ok(query)
}

fn apply_threat_filter<'a>(query: FlowsQuery<'a>, filter: &Filter) -> Result<FlowsQuery<'a>> {
    let live = "c.matched AND c.expires_at > NOW()";
    let endpoint = "(c.ip = src_endpoint_ip OR c.ip = dst_endpoint_ip)";
    match filter.field.as_str() {
        "threat_matched" => {
            if !matches!(filter.op, FilterOp::Eq) {
                return Err(ServiceError::InvalidRequest(
                    "threat_matched only supports equality".into(),
                ));
            }
            let wanted = match filter.value.as_scalar()?.to_ascii_lowercase().as_str() {
                "true" | "t" | "yes" | "1" => true,
                "false" | "f" | "no" | "0" => false,
                other => {
                    return Err(ServiceError::InvalidRequest(format!(
                        "threat_matched requires true or false, got '{other}'"
                    )));
                }
            };
            let exists = format!(
                "EXISTS (SELECT 1 FROM platform.ip_threat_intel_cache c WHERE {live} AND {endpoint})"
            );
            if wanted {
                Ok(query.filter(sql::<Bool>(&exists)))
            } else {
                Ok(query.filter(sql::<Bool>(&format!("NOT {exists}"))))
            }
        }
        "threat_source" => {
            if !matches!(filter.op, FilterOp::Eq | FilterOp::In) {
                return Err(ServiceError::InvalidRequest(
                    "threat_source only supports equality and membership".into(),
                ));
            }
            let values = match &filter.value {
                FilterValue::Scalar(value) => vec![value.clone()],
                FilterValue::List(values) => values.clone(),
            };
            if values.is_empty() {
                return Ok(query);
            }
            Ok(query.filter(
                sql::<Bool>(&format!(
                    "EXISTS (SELECT 1 FROM platform.ip_threat_intel_cache c \
                     WHERE {live} AND {endpoint} AND c.sources && "
                ))
                .bind::<diesel::sql_types::Array<Text>, _>(values)
                .sql(")"),
            ))
        }
        "threat_observed_ip" => {
            if !matches!(filter.op, FilterOp::Eq) {
                return Err(ServiceError::InvalidRequest(
                    "threat_observed_ip only supports equality".into(),
                ));
            }
            let ip = filter.value.as_scalar()?.to_string();
            ip.parse::<std::net::IpAddr>().map_err(|_| {
                ServiceError::InvalidRequest("threat_observed_ip must be an IP address".into())
            })?;
            Ok(query.filter(
                sql::<Bool>(&format!(
                    "EXISTS (SELECT 1 FROM platform.ip_threat_intel_cache c \
                     WHERE {live} AND {endpoint} AND c.ip = "
                ))
                .bind::<Text, _>(ip)
                .sql(")"),
            ))
        }
        "threat_indicator" => {
            if !matches!(filter.op, FilterOp::Eq) {
                return Err(ServiceError::InvalidRequest(
                    "threat_indicator only supports equality".into(),
                ));
            }
            let raw = filter.value.as_scalar()?;
            let (cast, value) = if raw.contains('/') {
                ("cidr", normalize_cidr_literal(raw)?)
            } else {
                let ip: std::net::IpAddr = raw.parse().map_err(|_| {
                    ServiceError::InvalidRequest("threat_indicator must be an IP or CIDR".into())
                })?;
                ("inet", ip.to_string())
            };
            let op = if cast == "cidr" {
                "i.indicator = "
            } else {
                "i.indicator >>= "
            };
            Ok(query.filter(
                sql::<Bool>(&format!(
                    "EXISTS (SELECT 1 FROM platform.ip_threat_intel_cache c \
                     JOIN platform.threat_intel_indicators i ON c.ip::inet <<= i.indicator \
                     WHERE {live} AND (i.expires_at IS NULL OR i.expires_at > NOW()) \
                     AND {endpoint} AND {op}"
                ))
                .bind::<Text, _>(value)
                .sql(&format!("::{cast})")),
            ))
        }
        "threat_severity" => {
            let operator = match filter.op {
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
            Ok(query.filter(
                sql::<Bool>(&format!(
                    "EXISTS (SELECT 1 FROM platform.ip_threat_intel_cache c \
                     WHERE {live} AND {endpoint} AND c.max_severity {operator} "
                ))
                .bind::<diesel::sql_types::Int4, _>(value)
                .sql(")"),
            ))
        }
        _ => unreachable!("threat filter field already matched"),
    }
}

/// `port:` matches either flow endpoint port, mirroring `ip:`.
///
/// Prefer `port:22` over unsupported boolean OR across fields
/// (`(dst_port:22 OR src_port:22)` is not SRQL).
fn apply_bidirectional_port_filter<'a>(
    mut query: FlowsQuery<'a>,
    filter: &Filter,
) -> Result<FlowsQuery<'a>> {
    match filter.op {
        FilterOp::Eq => {
            let value = filter
                .value
                .as_scalar()?
                .parse::<i32>()
                .map_err(|_| ServiceError::InvalidRequest("port must be an integer".into()))?;
            query = query.filter(src_endpoint_port.eq(value).or(dst_endpoint_port.eq(value)));
        }
        FilterOp::NotEq => {
            let value = filter
                .value
                .as_scalar()?
                .parse::<i32>()
                .map_err(|_| ServiceError::InvalidRequest("port must be an integer".into()))?;
            query = query.filter(
                src_endpoint_port
                    .is_null()
                    .or(src_endpoint_port.ne(value))
                    .and(dst_endpoint_port.is_null().or(dst_endpoint_port.ne(value))),
            );
        }
        FilterOp::In => {
            let values = filter
                .value
                .as_list()?
                .iter()
                .map(|item| {
                    item.parse::<i32>().map_err(|_| {
                        ServiceError::InvalidRequest("port list values must be integers".into())
                    })
                })
                .collect::<Result<Vec<_>>>()?;
            if values.is_empty() {
                return Ok(query);
            }
            query = query.filter(
                src_endpoint_port
                    .eq_any(values.clone())
                    .or(dst_endpoint_port.eq_any(values)),
            );
        }
        FilterOp::NotIn => {
            let values = filter
                .value
                .as_list()?
                .iter()
                .map(|item| {
                    item.parse::<i32>().map_err(|_| {
                        ServiceError::InvalidRequest("port list values must be integers".into())
                    })
                })
                .collect::<Result<Vec<_>>>()?;
            if values.is_empty() {
                return Ok(query);
            }
            query = query.filter(
                src_endpoint_port
                    .is_null()
                    .or(src_endpoint_port.ne_all(values.clone()))
                    .and(
                        dst_endpoint_port
                            .is_null()
                            .or(dst_endpoint_port.ne_all(values)),
                    ),
            );
        }
        _ => {
            return Err(ServiceError::InvalidRequest(
                "port filter only supports equality or list matching".into(),
            ));
        }
    }

    Ok(query)
}

/// `ip:` matches either flow endpoint, mirroring the bare `near:` form
/// (`NearSide::Either`, see `literals::near_exists_sql`).
///
/// A positive match means "either endpoint matches". A negative match means
/// "neither endpoint matches", which by De Morgan is the AND of the two per-side
/// negatives, not their OR -- ORing them would match every row where the two
/// endpoints differ. Both sides are nullable, so each negative is NULL-guarded
/// the same way `apply_text_filter!` guards a single column.
///
/// Every arm binds the value once per side; `collect_filter_params` pushes the
/// matching pair so the translate path's LIMIT/OFFSET binds do not shift.
/// Match any of a device's addresses against either endpoint or the sampler.
///
/// An empty list is rejected rather than dropped. The bare `ip:` list filter
/// drops an empty list, which silently widens the query to every flow in the
/// window -- for a device scope that would show one device another device's
/// traffic. Diesel also emits no placeholder for an empty `eq_any`, which
/// desyncs the bind arity this path asserts, so erroring is both the safe and
/// the correct answer. Callers resolve the address set first and are expected
/// not to ask for an empty scope.
fn apply_device_addr_filter<'a>(
    mut query: FlowsQuery<'a>,
    filter: &Filter,
) -> Result<FlowsQuery<'a>> {
    match filter.op {
        FilterOp::Eq => {
            let value = filter.value.as_scalar()?.to_string();
            query = query.filter(
                src_endpoint_ip
                    .eq(value.clone())
                    .or(dst_endpoint_ip.eq(value.clone()))
                    .or(sampler_address.eq(value)),
            );
        }
        FilterOp::In => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Err(ServiceError::InvalidRequest(
                    "device_addr filter requires at least one address".into(),
                ));
            }
            query = query.filter(
                src_endpoint_ip
                    .eq_any(values.clone())
                    .or(dst_endpoint_ip.eq_any(values.clone()))
                    .or(sampler_address.eq_any(values)),
            );
        }
        _ => {
            return Err(ServiceError::InvalidRequest(
                "device_addr filter supports equality and list matching".into(),
            ));
        }
    }

    Ok(query)
}

fn apply_bidirectional_ip_filter<'a>(
    mut query: FlowsQuery<'a>,
    filter: &Filter,
) -> Result<FlowsQuery<'a>> {
    match filter.op {
        FilterOp::Eq => {
            let value = filter.value.as_scalar()?.to_string();
            query = query.filter(
                src_endpoint_ip
                    .eq(value.clone())
                    .or(dst_endpoint_ip.eq(value)),
            );
        }
        FilterOp::NotEq => {
            let value = filter.value.as_scalar()?.to_string();
            query = query.filter(
                src_endpoint_ip
                    .is_null()
                    .or(src_endpoint_ip.ne(value.clone()))
                    .and(dst_endpoint_ip.is_null().or(dst_endpoint_ip.ne(value))),
            );
        }
        FilterOp::Like => {
            let value = filter.value.as_scalar()?.to_string();
            query = query.filter(
                src_endpoint_ip
                    .ilike(value.clone())
                    .or(dst_endpoint_ip.ilike(value)),
            );
        }
        FilterOp::NotLike => {
            let value = filter.value.as_scalar()?.to_string();
            query = query.filter(
                src_endpoint_ip
                    .is_null()
                    .or(src_endpoint_ip.not_ilike(value.clone()))
                    .and(
                        dst_endpoint_ip
                            .is_null()
                            .or(dst_endpoint_ip.not_ilike(value)),
                    ),
            );
        }
        FilterOp::In => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(query);
            }
            query = query.filter(
                src_endpoint_ip
                    .eq_any(values.clone())
                    .or(dst_endpoint_ip.eq_any(values)),
            );
        }
        FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(query);
            }
            query = query.filter(
                src_endpoint_ip
                    .is_null()
                    .or(src_endpoint_ip.ne_all(values.clone()))
                    .and(dst_endpoint_ip.is_null().or(dst_endpoint_ip.ne_all(values))),
            );
        }
        _ => {
            return Err(ServiceError::InvalidRequest(
                "ip filter supports equality, wildcard, and list matching".into(),
            ));
        }
    }

    Ok(query)
}

fn apply_near_filter<'a>(mut query: FlowsQuery<'a>, filter: &Filter) -> Result<FlowsQuery<'a>> {
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

    match filter.op {
        FilterOp::Eq => {
            let point = normalize_near_literal(filter.value.as_scalar()?)?;
            let expr = sql::<diesel::sql_types::Bool>(&near_exists_sql(point, side));
            query = query.filter(expr);
        }
        FilterOp::NotEq => {
            let point = normalize_near_literal(filter.value.as_scalar()?)?;
            let expr = sql::<diesel::sql_types::Bool>(&near_exists_sql(point, side));
            query = query.filter(not(expr));
        }
        _ => {
            return Err(ServiceError::InvalidRequest(
                "near filter only supports equality (e.g. near:30.27,-97.74,50km)".into(),
            ));
        }
    }

    Ok(query)
}

fn apply_tag_filter<'a>(mut query: FlowsQuery<'a>, filter: &Filter) -> Result<FlowsQuery<'a>> {
    use crate::query::flows::literals::tag_filter_sql;

    let expr_sql = tag_filter_sql(
        filter.field.as_str(),
        &filter.op,
        &filter.value,
        "src_prefix_tags",
        "dst_prefix_tags",
    )?;

    let pred = sql::<diesel::sql_types::Bool>(&expr_sql);
    query = match filter.op {
        FilterOp::Eq | FilterOp::In => query.filter(pred),
        FilterOp::NotEq | FilterOp::NotIn => query.filter(not(pred)),
        _ => query,
    };

    Ok(query)
}
