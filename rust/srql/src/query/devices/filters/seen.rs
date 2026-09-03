use super::super::DeviceQuery;
use crate::{
    error::{Result, ServiceError},
    parser::{Filter, FilterOp},
    schema::ocsf_devices::dsl::first_seen_time as col_first_seen_time,
    time::{parse_time_value, TimeRange},
};
use chrono::Utc;
use diesel::prelude::*;

pub(in crate::query::devices) fn first_seen_range(filter: &Filter) -> Result<TimeRange> {
    filter
        .value
        .as_scalar()
        .and_then(parse_time_value)?
        .resolve(Utc::now())
}

pub(super) fn apply_first_seen_filter<'a>(
    query: DeviceQuery<'a>,
    filter: &Filter,
) -> Result<DeviceQuery<'a>> {
    let TimeRange { start, end } = first_seen_range(filter)?;

    match filter.op {
        FilterOp::Eq => Ok(query.filter(
            col_first_seen_time
                .ge(start)
                .and(col_first_seen_time.le(end)),
        )),
        FilterOp::NotEq => Ok(query.filter(
            col_first_seen_time
                .is_null()
                .or(col_first_seen_time.lt(start))
                .or(col_first_seen_time.gt(end)),
        )),
        _ => Err(ServiceError::InvalidRequest(
            "first_seen filter only supports equality (for example first_seen:last_7d)".into(),
        )),
    }
}
