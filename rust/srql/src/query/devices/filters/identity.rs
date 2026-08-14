use super::super::DeviceQuery;
use crate::{
    error::{Result, ServiceError},
    parser::{Filter, FilterOp},
    query::{normalize_mac_value, BindParam},
};
use diesel::{
    dsl::sql,
    prelude::*,
    sql_types::{Bool, Text},
};

pub(super) fn apply_device_type_filter<'a>(
    query: DeviceQuery<'a>,
    filter: &Filter,
) -> Result<DeviceQuery<'a>> {
    let value = filter.value.as_scalar()?.to_string();
    let expr = "COALESCE(NULLIF(trim(\"ocsf_devices\".\"type\"), ''), 'Unknown')";

    match filter.op {
        FilterOp::Eq => Ok(query.filter(sql::<Bool>(&format!("{expr} = ")).bind::<Text, _>(value))),
        FilterOp::NotEq => {
            Ok(query.filter(sql::<Bool>(&format!("{expr} <> ")).bind::<Text, _>(value)))
        }
        _ => Err(ServiceError::InvalidRequest(
            "device_type filter only supports equality".into(),
        )),
    }
}

pub(super) fn apply_mac_filter<'a>(
    query: DeviceQuery<'a>,
    filter: &Filter,
) -> Result<DeviceQuery<'a>> {
    let norm_col = "lower(regexp_replace(mac, '[^0-9a-fA-F]', '', 'g'))";

    match filter.op {
        FilterOp::Eq => {
            let normalized = normalize_mac_value(filter.value.as_scalar()?, false)?;
            Ok(query.filter(sql::<Bool>(&format!("{norm_col} = ")).bind::<Text, _>(normalized)))
        }
        FilterOp::NotEq => {
            let normalized = normalize_mac_value(filter.value.as_scalar()?, false)?;
            Ok(query.filter(
                sql::<Bool>(&format!("(mac IS NULL OR {norm_col} <> "))
                    .bind::<Text, _>(normalized)
                    .sql(")"),
            ))
        }
        FilterOp::Like => {
            let normalized = normalize_mac_value(filter.value.as_scalar()?, true)?;
            Ok(query.filter(sql::<Bool>(&format!("{norm_col} LIKE ")).bind::<Text, _>(normalized)))
        }
        FilterOp::NotLike => {
            let normalized = normalize_mac_value(filter.value.as_scalar()?, true)?;
            Ok(query.filter(
                sql::<Bool>(&format!("(mac IS NULL OR {norm_col} NOT LIKE "))
                    .bind::<Text, _>(normalized)
                    .sql(")"),
            ))
        }
        _ => Err(ServiceError::InvalidRequest(
            "mac filter only supports equality and LIKE operators".into(),
        )),
    }
}

/// Collects normalized MAC bind params for the count/non-grouped stats path.
pub(super) fn collect_mac_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            let normalized = normalize_mac_value(filter.value.as_scalar()?, false)?;
            params.push(BindParam::Text(normalized));
            Ok(())
        }
        FilterOp::Like | FilterOp::NotLike => {
            let normalized = normalize_mac_value(filter.value.as_scalar()?, true)?;
            params.push(BindParam::Text(normalized));
            Ok(())
        }
        _ => Err(ServiceError::InvalidRequest(
            "mac filter only supports equality and LIKE operators".into(),
        )),
    }
}
