mod bind;
mod clauses;
mod fields;
mod filters;
mod grouped;
mod query;
mod rollup;
mod spec;

pub(super) use bind::{DeviceSqlBindValue, bind_param_from_device_stats};
pub(super) use grouped::{build_grouped_stats_query, rewrite_placeholders};
pub(super) use query::build_stats_query;
pub(super) use rollup::build_rollup_stats_query;
pub(super) use spec::parse_stats_spec;

use crate::jsonb::DbJson;
use diesel::QueryableByName;
use diesel::sql_types::{Jsonb, Nullable};

#[derive(Debug, QueryableByName)]
#[diesel(check_for_backend(diesel::pg::Pg))]
pub(super) struct DeviceStatsPayload {
    #[diesel(sql_type = Nullable<Jsonb>)]
    pub(super) payload: Option<DbJson>,
}

pub(super) struct DeviceGroupedStatsSql {
    pub(super) sql: String,
    pub(super) binds: Vec<DeviceSqlBindValue>,
}

pub(super) struct DeviceRollupStatsSql {
    pub(super) sql: String,
}
