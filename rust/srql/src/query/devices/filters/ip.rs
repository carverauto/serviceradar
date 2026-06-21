use super::{super::DeviceQuery, text::collect_text_params};
use crate::{
    error::{Result, ServiceError},
    parser::{Filter, FilterOp},
    query::BindParam,
    schema::ocsf_devices::dsl::ip as col_ip,
};
use diesel::{
    dsl::sql,
    prelude::*,
    sql_types::{Bool, Text},
};
use std::net::IpAddr;

pub(super) fn apply_ip_filter<'a>(
    query: DeviceQuery<'a>,
    filter: &Filter,
) -> Result<DeviceQuery<'a>> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            let value = filter.value.as_scalar()?.to_string();
            if let Some(cidr) = parse_cidr(&value)? {
                let ip_expr = safe_device_ip_inet_sql();
                let expr = if matches!(filter.op, FilterOp::NotEq) {
                    sql::<Bool>(&format!("({ip_expr} IS NOT NULL AND NOT ({ip_expr} <<= "))
                        .bind::<Text, _>(cidr)
                        .sql("::cidr))")
                } else {
                    sql::<Bool>(&format!("({ip_expr} IS NOT NULL AND {ip_expr} <<= "))
                        .bind::<Text, _>(cidr)
                        .sql("::cidr)")
                };
                return Ok(query.filter(expr));
            }

            if let Some((start, end)) = parse_ip_range(&value)? {
                let ip_expr = safe_device_ip_inet_sql();
                let expr = if matches!(filter.op, FilterOp::NotEq) {
                    sql::<Bool>(&format!("({ip_expr} IS NOT NULL AND NOT ({ip_expr} >= "))
                        .bind::<Text, _>(start)
                        .sql(&format!("::inet AND {ip_expr} <= "))
                        .bind::<Text, _>(end)
                        .sql("::inet))")
                } else {
                    sql::<Bool>(&format!("({ip_expr} IS NOT NULL AND {ip_expr} >= "))
                        .bind::<Text, _>(start)
                        .sql(&format!("::inet AND {ip_expr} <= "))
                        .bind::<Text, _>(end)
                        .sql("::inet)")
                };
                return Ok(query.filter(expr));
            }
        }
        _ => {}
    }

    apply_text_filter_no_lists!(query, filter, col_ip, "ip filter does not support lists")
}

pub(super) fn collect_ip_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            let value = filter.value.as_scalar()?.to_string();

            if let Some(cidr) = parse_cidr(&value)? {
                params.push(BindParam::Text(cidr));
                return Ok(());
            }

            if let Some((start, end)) = parse_ip_range(&value)? {
                params.push(BindParam::Text(start));
                params.push(BindParam::Text(end));
                return Ok(());
            }

            params.push(BindParam::Text(value));
            Ok(())
        }
        _ => collect_text_params(params, filter, false),
    }
}

fn parse_cidr(value: &str) -> Result<Option<String>> {
    if !value.contains('/') {
        return Ok(None);
    }

    let (ip_part, prefix_part) = value
        .split_once('/')
        .ok_or_else(|| ServiceError::InvalidRequest("invalid CIDR for ip filter".into()))?;
    let ip_part = ip_part.trim();
    let prefix_part = prefix_part.trim();

    if ip_part.is_empty() || prefix_part.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "invalid CIDR for ip filter".into(),
        ));
    }

    let ip: IpAddr = ip_part
        .parse()
        .map_err(|_| ServiceError::InvalidRequest("invalid CIDR for ip filter".into()))?;
    let prefix: u8 = prefix_part
        .parse()
        .map_err(|_| ServiceError::InvalidRequest("invalid CIDR for ip filter".into()))?;

    let max_prefix = match ip {
        IpAddr::V4(_) => 32,
        IpAddr::V6(_) => 128,
    };

    if prefix > max_prefix {
        return Err(ServiceError::InvalidRequest(
            "invalid CIDR for ip filter".into(),
        ));
    }

    Ok(Some(format!("{}/{}", ip, prefix)))
}

fn parse_ip_range(value: &str) -> Result<Option<(String, String)>> {
    if !value.contains('-') {
        return Ok(None);
    }

    let (start_part, end_part) = value
        .split_once('-')
        .ok_or_else(|| ServiceError::InvalidRequest("invalid ip range for ip filter".into()))?;

    let start_part = start_part.trim();
    let end_part = end_part.trim();

    if start_part.is_empty() || end_part.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "invalid ip range for ip filter".into(),
        ));
    }

    let start_ip: IpAddr = start_part
        .parse()
        .map_err(|_| ServiceError::InvalidRequest("invalid ip range for ip filter".into()))?;
    let end_ip: IpAddr = end_part
        .parse()
        .map_err(|_| ServiceError::InvalidRequest("invalid ip range for ip filter".into()))?;

    if std::mem::discriminant(&start_ip) != std::mem::discriminant(&end_ip) {
        return Err(ServiceError::InvalidRequest(
            "invalid ip range for ip filter".into(),
        ));
    }

    Ok(Some((start_ip.to_string(), end_ip.to_string())))
}

pub(in crate::query::devices) fn safe_device_ip_inet_sql() -> &'static str {
    "(CASE WHEN pg_input_is_valid(NULLIF(btrim(split_part(ip, ',', 1)), ''), 'inet') THEN NULLIF(btrim(split_part(ip, ',', 1)), '')::inet ELSE NULL END)"
}
