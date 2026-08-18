use super::{
    DeviceGroupedStatsSql, bind::DeviceSqlBindValue, fields::DeviceGroupField,
    filters::build_grouped_stats_filter_clause, spec::DeviceStatsSpec,
};
use crate::{
    error::{Result, ServiceError},
    query::QueryPlan,
    time::TimeRange,
};

pub(in crate::query::devices) fn build_grouped_stats_query(
    plan: &QueryPlan,
    spec: &DeviceStatsSpec,
) -> Result<DeviceGroupedStatsSql> {
    if spec.group_fields.is_empty() {
        return Err(ServiceError::Internal(anyhow::anyhow!(
            "at least one group field is required"
        )));
    }

    let mut binds = Vec::new();
    let mut clauses = Vec::new();

    if !plan.include_deleted && !super::super::filters::has_deleted_filter(&plan.filters) {
        clauses.push("deleted_at IS NULL".to_string());
    }

    if super::super::filters::should_apply_default_active_filter(&plan.filters)? {
        clauses.push("COALESCE(is_active, true) = true".to_string());
    }

    if let Some(TimeRange { start, end }) = &plan.time_range {
        clauses.push("last_seen_time >= ?".to_string());
        binds.push(DeviceSqlBindValue::Timestamp(*start));
        clauses.push("last_seen_time <= ?".to_string());
        binds.push(DeviceSqlBindValue::Timestamp(*end));
    }

    for filter in &plan.filters {
        if let Some((clause, mut bind_values)) = build_grouped_stats_filter_clause(filter)? {
            clauses.push(clause);
            binds.append(&mut bind_values);
        }
    }

    let group_pairs = spec
        .group_fields
        .iter()
        .map(|field| format!("'{}', {}", field.response_key(), field.column()))
        .collect::<Vec<_>>()
        .join(", ");
    let group_columns = spec
        .group_fields
        .iter()
        .map(DeviceGroupField::column)
        .collect::<Vec<String>>();
    let group_by_sql = group_columns.join(", ");

    let mut sql = format!(
        "SELECT jsonb_build_object({}, '{}', COUNT(*)) AS payload",
        group_pairs, spec.alias
    );
    sql.push_str("\nFROM ocsf_devices");

    if !clauses.is_empty() {
        sql.push_str("\nWHERE ");
        sql.push_str(&clauses.join(" AND "));
    }

    sql.push_str(&format!("\nGROUP BY {group_by_sql}"));
    sql.push_str(&build_grouped_stats_order_clause(
        plan,
        &spec.alias,
        &spec.group_fields,
    ));

    // Planning applies the device-group default (20) and maximum (100). Keep
    // this defensive clamp so a directly constructed QueryPlan cannot bypass
    // the public contract.
    let limit = plan.limit.clamp(1, 100);
    sql.push_str(&format!("\nLIMIT {limit}"));

    if plan.offset > 0 {
        sql.push_str(&format!(" OFFSET {}", plan.offset));
    }

    Ok(DeviceGroupedStatsSql { sql, binds })
}

fn build_grouped_stats_order_clause(
    plan: &QueryPlan,
    alias: &str,
    group_fields: &[DeviceGroupField],
) -> String {
    if plan.order.is_empty() {
        return "\nORDER BY COUNT(*) DESC".to_string();
    }

    let mut parts = Vec::new();
    for clause in &plan.order {
        let expr = if clause.field.eq_ignore_ascii_case(alias) || clause.field == "count" {
            "COUNT(*)".to_string()
        } else if let Some(group_field) = group_fields
            .iter()
            .find(|field| field.matches_order_field(&clause.field))
        {
            group_field.column()
        } else {
            continue;
        };

        let dir = match clause.direction {
            crate::parser::OrderDirection::Asc => "ASC",
            crate::parser::OrderDirection::Desc => "DESC",
        };
        parts.push(format!("{expr} {dir}"));
    }

    if parts.is_empty() {
        "\nORDER BY COUNT(*) DESC".to_string()
    } else {
        format!("\nORDER BY {}", parts.join(", "))
    }
}

pub(in crate::query::devices) fn rewrite_placeholders(sql: &str) -> String {
    let mut result = String::with_capacity(sql.len());
    let mut index = 1;
    for ch in sql.chars() {
        if ch == '?' {
            result.push('$');
            result.push_str(&index.to_string());
            index += 1;
        } else {
            result.push(ch);
        }
    }
    result
}
