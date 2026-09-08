use super::*;

pub(super) fn build_query(plan: &QueryPlan) -> Result<FlowsQuery<'static>> {
    let mut query = ocsf_network_activity.into_boxed::<Pg>();

    if matches!(plan.entity, Entity::AttributedFlows) {
        query = query.filter(sql::<Bool>(ATTRIBUTED_FLOW_EVENT_TYPE_EXPR));
    }

    // Apply time filter
    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(time.ge(start.naive_utc()).and(time.le(end.naive_utc())));
    }

    // Apply filters
    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    // Apply ordering
    query = apply_ordering(query, &plan.order);

    Ok(query)
}
