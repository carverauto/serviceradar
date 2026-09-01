#[macro_use]
mod filters_common;

mod cagg;
mod cold;
mod engine;
mod plan;
mod sql;
mod translate;
mod types;

mod addon_fleet;
mod addon_statuses;
mod agents;
mod alerts;
mod bmp_events;
mod capacity_forecasts;
mod composite_results;
mod cpu_metrics;
mod dashboard_service_views;
mod dashboards;
mod device_graph;
mod devices;
mod disk_metrics;
mod downsample;
mod endpoint_inventory_scans;
mod endpoint_package_catalog;
mod endpoint_packages;
mod events;
mod field_survey;
mod flows;
mod gateways;
mod graph_cypher;
mod interfaces;
mod logs;
mod memory_metrics;
mod mtr_traces;
mod otel_metric_points;
mod otel_metrics;
mod process_metrics;
mod public_endpoints;
mod services;
mod source_fact_disagreements;
mod timeseries_metrics;
mod trace_summaries;
mod traces;
mod virtualization;
mod viz;
mod wifi_map;

#[cfg(test)]
mod tests;

#[cfg(test)]
pub(crate) use cagg::should_route_to_hourly_cagg;
pub(crate) use cagg::{
    cagg_column_for_entity, cagg_table_for_entity, hourly_cagg_lower_bound_clause,
    hourly_cagg_upper_bound_clause, max_time_range_days_for_ast, should_route_plan_to_hourly_cagg,
};
pub use engine::QueryEngine;
pub(crate) use filters_common::{
    build_other_rollup_sql, is_negated_membership_op, normalize_mac_value,
};
pub(crate) use plan::build_query_plan;
pub(crate) use plan::is_full_profile_query;
#[cfg(any(test, debug_assertions))]
pub(crate) use sql::diesel_bind_count;
pub(crate) use sql::{
    bind_sql_param, diesel_sql, max_dollar_placeholder, reconcile_limit_offset_binds,
    shift_dollar_placeholders,
};
pub use translate::translate_request;
pub use types::{
    BindParam, PaginationMeta, QueryDirection, QueryPlan, QueryRequest, QueryResponse,
    TranslateRequest, TranslateResponse,
};

#[cfg(test)]
use crate::{
    config::AppConfig, error::ServiceError, pagination::encode_cursor, parser::Entity,
    time::TimeRange,
};
#[cfg(test)]
use chrono::Duration as ChronoDuration;
