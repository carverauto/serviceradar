use super::{
    filters::{build_filter_clause, extract_latest_filter, filters_need_interface_settings},
    sql::{SqlBuildResult, interface_settings_join},
};
use crate::{
    error::{Result, ServiceError},
    query::{BindParam, QueryPlan},
    time::TimeRange,
};

pub(super) fn build_stats_sql(plan: &QueryPlan, spec: &CountStatsSpec) -> Result<SqlBuildResult> {
    let (latest_only, filters) = extract_latest_filter(&plan.filters)?;
    let mut binds = Vec::new();
    let mut clauses = Vec::new();
    let mut bind_idx = 1;

    if let Some(TimeRange { start, end }) = &plan.time_range {
        clauses.push(format!(
            "di.timestamp >= ${} AND di.timestamp <= ${}",
            bind_idx,
            bind_idx + 1
        ));
        binds.push(BindParam::timestamptz(*start));
        binds.push(BindParam::timestamptz(*end));
        bind_idx += 2;
    }

    for filter in &filters {
        if let Some(clause) = build_filter_clause(filter, &mut binds, &mut bind_idx)? {
            clauses.push(clause);
        }
    }

    let mut base =
        String::from("SELECT di.device_id, di.interface_uid FROM discovered_interfaces di");
    if filters_need_interface_settings(&filters) {
        base.push_str(&interface_settings_join("di"));
    }
    if !clauses.is_empty() {
        base.push_str(" WHERE ");
        base.push_str(&clauses.join(" AND "));
    }

    let sql = if latest_only {
        format!(
            "SELECT jsonb_build_object('{}', COALESCE(COUNT(*), 0)::bigint) AS payload FROM (SELECT DISTINCT ON (di.device_id, di.interface_uid) {} ORDER BY di.device_id, di.interface_uid, di.timestamp DESC, di.created_at DESC) AS latest",
            spec.alias, base
        )
    } else {
        format!(
            "SELECT jsonb_build_object('{}', COALESCE(COUNT(*), 0)::bigint) AS payload FROM {}",
            spec.alias, base
        )
    };

    Ok(SqlBuildResult { sql, binds })
}

#[derive(Debug, Clone)]
pub(super) struct CountStatsSpec {
    pub(super) alias: String,
}

pub(super) fn parse_stats_spec(raw: Option<&str>) -> Result<Option<CountStatsSpec>> {
    let value = match raw {
        Some(value) if !value.trim().is_empty() => value.trim(),
        _ => return Ok(None),
    };

    let lower = value.to_lowercase();
    if lower.contains(" by ") {
        return Err(ServiceError::InvalidRequest(
            "interfaces stats queries do not support grouping yet".into(),
        ));
    }

    let alias_pos = lower.rfind(" as ").ok_or_else(|| {
        ServiceError::InvalidRequest("stats expressions must include an alias".into())
    })?;
    let alias = value[alias_pos + 4..].trim();
    if alias.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "stats alias cannot be empty".into(),
        ));
    }
    if !alias
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || ch == '_')
    {
        return Err(ServiceError::InvalidRequest(
            "stats alias must be alphanumeric".into(),
        ));
    }

    let expr = value[..alias_pos].trim().replace(' ', "").to_lowercase();
    if expr != "count()" && expr != "count(*)" {
        return Err(ServiceError::InvalidRequest(
            "interfaces stats queries only support count()".into(),
        ));
    }

    Ok(Some(CountStatsSpec {
        alias: alias.to_string(),
    }))
}
