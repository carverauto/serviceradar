use super::super::DeviceQuery;
use super::jsonb::parse_bool;
use crate::{
    error::{Result, ServiceError},
    parser::{Filter, FilterOp},
    schema::ocsf_devices::dsl::source_retired_at as col_source_retired_at,
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

/// Whether to hide records marked `source_retired`: live records left holding only retired
/// source ids, which the grace pass soft-deletes. A query that asks for them sees them:
/// `include_retired:true`, a `source_retired:` filter, or `include_deleted:true`, which returns
/// every record.
pub(in crate::query::devices) fn should_apply_default_retired_filter(
    include_deleted: bool,
    filters: &[Filter],
) -> Result<bool> {
    if include_deleted
        || filters
            .iter()
            .any(|filter| filter.field.eq_ignore_ascii_case("source_retired"))
    {
        return Ok(false);
    }

    for filter in filters {
        if filter.field.eq_ignore_ascii_case("include_retired") {
            return Ok(!parse_include_retired(filter)?);
        }
    }

    Ok(true)
}

pub(in crate::query::devices) fn parse_include_retired(filter: &Filter) -> Result<bool> {
    if !matches!(filter.op, FilterOp::Eq) {
        return Err(ServiceError::InvalidRequest(
            "include_retired only supports equality".into(),
        ));
    }

    parse_bool(filter.value.as_scalar()?)
}

pub(in crate::query::devices) fn apply_default_retired_filter<'a>(
    query: DeviceQuery<'a>,
) -> DeviceQuery<'a> {
    query.filter(col_source_retired_at.is_null())
}

pub(super) fn apply_retired_filter<'a>(
    query: DeviceQuery<'a>,
    filter: &Filter,
) -> Result<DeviceQuery<'a>> {
    if retired_filter_matches_marked(filter)? {
        Ok(query.filter(col_source_retired_at.is_not_null()))
    } else {
        Ok(query.filter(col_source_retired_at.is_null()))
    }
}

/// Whether a `source_retired:` filter selects the marked records (`source_retired:true`,
/// `!source_retired:false`) rather than the unmarked ones.
pub(in crate::query::devices) fn retired_filter_matches_marked(filter: &Filter) -> Result<bool> {
    let value = parse_bool(filter.value.as_scalar()?)?;

    match filter.op {
        FilterOp::Eq => Ok(value),
        FilterOp::NotEq => Ok(!value),
        _ => Err(ServiceError::InvalidRequest(
            "source_retired only supports equality".into(),
        )),
    }
}
