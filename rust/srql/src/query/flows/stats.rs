mod aggregation;
mod bind;
mod cagg;
mod filters;
mod group;
mod order;
mod parse;
mod query;
mod spec;

use super::*;
use diesel::QueryableByName;
use diesel::pg::Pg;
use diesel::query_builder::{BoxedSqlQuery, SqlQuery};
use diesel::sql_types::{Array, BigInt, Text, Timestamptz};

pub(super) use aggregation::{FlowAggField, FlowAggFunc};
pub(super) use bind::{
    FlowGroupedStatsSql, FlowSqlBindValue, FlowStatsPayload, bind_param_from_flow_stats,
    rewrite_placeholders,
};
pub(super) use cagg::should_route_flow_stats_to_cagg;
pub(super) use filters::build_stats_filter_clause;
pub(super) use group::{FlowGroupField, FlowGroupSpec};
pub(super) use order::{
    build_stats_order_sql, build_stats_rank_order_sql, validate_flow_other_rollup,
};
pub(super) use parse::parse_stats_expr;
pub(super) use spec::{FlowAggregationSpec, FlowStatsSpec};

pub(super) async fn execute_stats(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<Value>> {
    query::execute_stats(conn, plan).await
}

pub(super) fn to_sql_and_params_stats(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    query::to_sql_and_params_stats(plan)
}

#[cfg(test)]
pub(in crate::query) use query::execution_query;
