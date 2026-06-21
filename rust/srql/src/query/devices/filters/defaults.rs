use super::super::DeviceQuery;
use super::jsonb::parse_bool;
use crate::{
    error::{Result, ServiceError},
    parser::{Filter, FilterOp},
};
use diesel::{dsl::sql, prelude::*, sql_types::Bool};

pub(in crate::query::devices) fn has_deleted_filter(filters: &[Filter]) -> bool {
    filters
        .iter()
        .any(|filter| filter.field.eq_ignore_ascii_case("deleted"))
}

fn has_active_filter(filters: &[Filter]) -> bool {
    filters
        .iter()
        .any(|filter| filter.field.eq_ignore_ascii_case("is_active"))
}

pub(in crate::query::devices) fn should_apply_default_active_filter(
    filters: &[Filter],
) -> Result<bool> {
    if has_active_filter(filters) {
        return Ok(false);
    }

    for filter in filters {
        if filter.field.eq_ignore_ascii_case("include_inactive") {
            return Ok(!parse_bool(filter.value.as_scalar()?)?);
        }
    }

    Ok(true)
}

pub(in crate::query::devices) fn apply_default_active_filter<'a>(
    query: DeviceQuery<'a>,
) -> DeviceQuery<'a> {
    query.filter(sql::<Bool>(
        "COALESCE(\"ocsf_devices\".\"is_active\", true) = true",
    ))
}

pub(super) fn apply_active_filter<'a>(
    query: DeviceQuery<'a>,
    filter: &Filter,
) -> Result<DeviceQuery<'a>> {
    let value = parse_bool(filter.value.as_scalar()?)?;

    match filter.op {
        FilterOp::Eq => Ok(query.filter(
            sql::<Bool>("COALESCE(\"ocsf_devices\".\"is_active\", true) = ").bind::<Bool, _>(value),
        )),
        FilterOp::NotEq => Ok(query.filter(
            sql::<Bool>("COALESCE(\"ocsf_devices\".\"is_active\", true) <> ")
                .bind::<Bool, _>(value),
        )),
        _ => Err(ServiceError::InvalidRequest(
            "is_active only supports equality".into(),
        )),
    }
}
