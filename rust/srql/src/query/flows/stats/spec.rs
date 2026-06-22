use super::*;

#[derive(Debug, Clone)]
pub(in crate::query::flows) struct FlowStatsSpec {
    pub(in crate::query::flows) aggregations: Vec<FlowAggregationSpec>,
    pub(in crate::query::flows) group_by: Vec<FlowGroupSpec>,
}

#[derive(Debug, Clone)]
pub(in crate::query::flows) struct FlowAggregationSpec {
    pub(in crate::query::flows) agg_func: FlowAggFunc,
    pub(in crate::query::flows) agg_field: FlowAggField,
    pub(in crate::query::flows) alias: String,
}
