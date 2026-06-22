use super::*;

pub(super) fn flow_device_scope_expr(filter: &Filter) -> Result<String> {
    let device_uid = normalize_device_uid_literal(filter.value.as_scalar()?)?;

    // Match flows for a device in two ways:
    // 1) exporter-owned flows (sampler -> exporter cache device_uid)
    // 2) endpoint flows (src/dst endpoint IP matches primary or active alias IPs)
    let base = format!(
        concat!(
            "(",
            "EXISTS (",
            "SELECT 1 FROM netflow_exporter_cache ec ",
            "WHERE ec.sampler_address = sampler_address ",
            "AND ec.device_uid = '{uid}'",
            ") ",
            "OR EXISTS (",
            "SELECT 1 FROM ocsf_devices d ",
            "WHERE d.uid = '{uid}' ",
            "AND d.ip IS NOT NULL AND d.ip <> '' ",
            "AND (src_endpoint_ip = d.ip OR dst_endpoint_ip = d.ip)",
            ") ",
            "OR EXISTS (",
            "SELECT 1 FROM device_alias_states das ",
            "WHERE das.device_id = '{uid}' ",
            "AND das.alias_type = 'ip' ",
            "AND das.state IN ('detected', 'confirmed', 'updated') ",
            "AND (src_endpoint_ip = das.alias_value OR dst_endpoint_ip = das.alias_value)",
            ")",
            ")"
        ),
        uid = device_uid
    );

    match filter.op {
        FilterOp::Eq => Ok(base),
        FilterOp::NotEq => Ok(format!("NOT ({base})")),
        _ => Err(ServiceError::InvalidRequest(
            "device_id filter only supports equality".into(),
        )),
    }
}
