use super::*;

pub(in crate::query::flows) fn validate_flow_other_rollup(spec: &FlowStatsSpec) -> Result<()> {
    if spec.group_by.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "other:true requires grouped flow stats".into(),
        ));
    }

    for agg in &spec.aggregations {
        if !matches!(agg.agg_func, FlowAggFunc::Sum | FlowAggFunc::Count) {
            return Err(ServiceError::InvalidRequest(
                "other:true currently supports only sum(...) and count(...) aggregations".into(),
            ));
        }
    }

    Ok(())
}

pub(in crate::query::flows) fn build_stats_order_sql(
    plan: &QueryPlan,
    group_keys: &[&str],
    agg_aliases: &[&str],
) -> Result<String> {
    let parts = build_stats_order_parts(plan, group_keys, agg_aliases)?;
    Ok(if parts.is_empty() {
        String::new()
    } else {
        format!(" ORDER BY {}", parts.join(", "))
    })
}

pub(in crate::query::flows) fn build_stats_rank_order_sql(
    plan: &QueryPlan,
    group_keys: &[&str],
    agg_aliases: &[&str],
) -> Result<String> {
    let mut parts = build_stats_order_parts(plan, group_keys, agg_aliases)?;
    for idx in 0..group_keys.len() {
        let group_expr = format!("group_value_{idx}");
        if !parts.iter().any(|part| part.starts_with(&group_expr)) {
            parts.push(format!("{group_expr} ASC"));
        }
    }

    Ok(format!("ORDER BY {}", parts.join(", ")))
}

fn build_stats_order_parts(
    plan: &QueryPlan,
    group_keys: &[&str],
    agg_aliases: &[&str],
) -> Result<Vec<String>> {
    if plan.order.is_empty() {
        // Default ordering for grouped stats: highest first.
        return Ok(if !group_keys.is_empty() {
            vec!["agg_value_0 DESC".to_string()]
        } else {
            Vec::new()
        });
    }

    let mut parts: Vec<String> = Vec::new();
    for clause in &plan.order {
        let expr = if let Some(idx) = agg_aliases.iter().position(|a| clause.field == *a) {
            format!("agg_value_{idx}")
        } else if let Some(idx) = group_keys.iter().position(|k| *k == clause.field) {
            format!("group_value_{idx}")
        } else {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported order field for flows stats: '{}'",
                clause.field
            )));
        };

        let dir = if matches!(clause.direction, OrderDirection::Asc) {
            "ASC"
        } else {
            "DESC"
        };
        parts.push(format!("{expr} {dir}"));
    }

    Ok(parts)
}
