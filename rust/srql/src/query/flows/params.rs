use super::*;

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

pub(super) fn collect_filter_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.field.as_str() {
        // device_id scope is expressed with validated SQL literals in `flow_device_scope_expr`.
        "device_id" => Ok(()),
        "src_endpoint_ip"
        | "src_ip"
        | "dst_endpoint_ip"
        | "dst_ip"
        | "protocol_name"
        | "app"
        | "sampler_address"
        | "direction"
        | "flow_source"
        | "collector"
        | "exporter_name"
        | "in_if_name"
        | "out_if_name"
        | "in_if_speed_bps"
        | "out_if_speed_bps"
        | "event_type"
        | "attribution_status"
        | "status"
        | "pid"
        | "process_pid"
        | "uid"
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
        | "public_endpoint_route" => collect_text_params(params, filter),
        // `ip:` matches either endpoint, so `apply_bidirectional_ip_filter` binds the value
        // once per side. Collect the same pair or the LIMIT/OFFSET binds shift.
        "ip" | "endpoint_ip" => {
            collect_text_params(params, filter)?;
            collect_text_params(params, filter)
        }
        // `device_addr:` binds three times -- src, dst, sampler -- matching the
        // three-way OR built in flows/filters.rs. The counts must agree or the
        // translate path's LIMIT/OFFSET binds shift.
        "device_addr" | "device_address" => {
            collect_text_params(params, filter)?;
            collect_text_params(params, filter)?;
            collect_text_params(params, filter)
        }
        // `port:` matches either endpoint port (same double-bind pattern as `ip:`).
        "port" | "endpoint_port" => {
            collect_port_params(params, filter, "port")?;
            collect_port_params(params, filter, "port")
        }
        // These filters are implemented using inline SQL literals in `apply_filter` (no binds),
        // so we must not collect bind params for them or we'll shift LIMIT/OFFSET binds.
        "input_snmp" | "in_if_index" | "output_snmp" | "out_if_index" => Ok(()),
        "src_country_iso2" | "src_country" | "dst_country_iso2" | "dst_country" => Ok(()),
        "src_cidr" | "dst_cidr" | "cidr" => Ok(()),
        // Tag filters inline validated JSONB literals (no binds).
        "tag" | "src_tag" | "dst_tag" => Ok(()),
        // Proximity filters inline validated lat/lng/radius (no binds).
        "near" | "src_near" | "dst_near" => Ok(()),
        "threat_matched" => Ok(()),
        "threat_source" => match filter.op {
            FilterOp::Eq => {
                params.push(BindParam::TextArray(vec![filter
                    .value
                    .as_scalar()?
                    .to_string()]));
                Ok(())
            }
            FilterOp::In => {
                let values = filter.value.as_list()?.to_vec();
                if values.is_empty() {
                    return Ok(());
                }
                params.push(BindParam::TextArray(values));
                Ok(())
            }
            _ => Err(ServiceError::InvalidRequest(
                "threat_source only supports equality and membership".into(),
            )),
        },
        "threat_observed_ip" | "threat_indicator" => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        "threat_severity" => {
            let value = filter.value.as_scalar()?.parse::<i64>().map_err(|_| {
                ServiceError::InvalidRequest("threat_severity must be an integer".into())
            })?;
            params.push(BindParam::Int(value));
            Ok(())
        }
        "protocol_num" | "proto" => {
            let value = filter.value.as_scalar()?.parse::<i32>().map_err(|_| {
                ServiceError::InvalidRequest(format!("{} must be an integer", filter.field))
            })?;
            params.push(BindParam::Int(value as i64));
            Ok(())
        }
        "src_port" | "src_endpoint_port" => collect_port_params(params, filter, "src_port"),
        "dst_port" | "dst_endpoint_port" => collect_port_params(params, filter, "dst_port"),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field '{other}'"
        ))),
    }
}

fn collect_port_params(params: &mut Vec<BindParam>, filter: &Filter, label: &str) -> Result<()> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            let value =
                filter.value.as_scalar()?.parse::<i32>().map_err(|_| {
                    ServiceError::InvalidRequest(format!("{label} must be an integer"))
                })?;
            params.push(BindParam::Int(value as i64));
            Ok(())
        }
        FilterOp::Like | FilterOp::NotLike => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = filter
                .value
                .as_list()?
                .iter()
                .map(|item| {
                    item.parse::<i32>().map_err(|_| {
                        ServiceError::InvalidRequest(format!(
                            "{label} list values must be integers"
                        ))
                    })
                })
                .collect::<Result<Vec<_>>>()?;
            if values.is_empty() {
                return Ok(());
            }
            params.push(BindParam::IntArray(
                values.into_iter().map(|v| v as i64).collect(),
            ));
            Ok(())
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "{label} filter does not support this operator"
        ))),
    }
}
