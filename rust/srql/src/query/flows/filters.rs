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
        "tag" | "src_tag" | "dst_tag" => {
            query = apply_tag_filter(query, filter)?;
        }
        "near" | "src_near" | "dst_near" => {
            query = apply_near_filter(query, filter)?;
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for flows: '{other}'"
            )));
        }
    }

    Ok(query)
}

fn apply_near_filter<'a>(
    mut query: FlowsQuery<'a>,
    filter: &Filter,
) -> Result<FlowsQuery<'a>> {
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
