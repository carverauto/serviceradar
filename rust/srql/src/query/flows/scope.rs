use super::*;

pub(super) fn flow_device_scope_expr(filter: &Filter) -> Result<String> {
    let device_uid = normalize_device_uid_literal(filter.value.as_scalar()?)?;

    // Match flows for a device in two ways:
    // 1) exporter-owned flows (sampler -> exporter cache device_uid)
    // 2) endpoint flows (src/dst endpoint IP matches primary or active alias IPs)
    //
    // The device address/alias/exporter lookups do NOT depend on the outer flow
    // row, so we resolve them ONCE into scalar-array subqueries (InitPlans) and
    // filter the outer rows by set membership. This avoids correlated EXISTS
    // subqueries that the planner would otherwise re-run per scanned flow row
    // (which forces a full walk of the time index and produces wildly inflated
    // cost estimates). The set-membership form lets the planner reuse the
    // existing src/dst endpoint-IP indexes and estimate selectivity sanely.
    //
    // `device_ips` collects the device's primary IP plus any active `ip` aliases;
    // `device_samplers` collects exporter sampler addresses owned by the device.
    let device_ips = format!(
        concat!(
            "ARRAY(",
            "SELECT d.ip FROM ocsf_devices d ",
            "WHERE d.uid = '{uid}' AND d.ip IS NOT NULL AND d.ip <> '' ",
            "UNION ",
            "SELECT das.alias_value FROM device_alias_states das ",
            "WHERE das.device_id = '{uid}' ",
            "AND das.alias_type = 'ip' ",
            "AND das.state IN ('detected', 'confirmed', 'updated')",
            ")"
        ),
        uid = device_uid
    );
    let device_samplers = format!(
        concat!(
            "ARRAY(",
            "SELECT ec.sampler_address FROM netflow_exporter_cache ec ",
            "WHERE ec.device_uid = '{uid}'",
            ")"
        ),
        uid = device_uid
    );

    let base = format!(
        "(src_endpoint_ip = ANY({ips}) \
         OR dst_endpoint_ip = ANY({ips}) \
         OR sampler_address = ANY({samplers}))",
        ips = device_ips,
        samplers = device_samplers
    );

    match filter.op {
        FilterOp::Eq => Ok(base),
        FilterOp::NotEq => Ok(format!("NOT ({base})")),
        _ => Err(ServiceError::InvalidRequest(
            "device_id filter only supports equality".into(),
        )),
    }
}
