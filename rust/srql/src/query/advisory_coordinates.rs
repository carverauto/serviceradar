//! SRQL `in:advisory_coordinates` / `in:advisory_cpes` / `in:cpe_coordinates`.

use super::advisory::{
    bool_condition, execute_json, has_filter, is_selective_coordinate_query, numeric_condition,
    order_sql, parse_count_stats, reject_downsample_and_rollup, stats_order_sql, stats_select,
    text_condition, time_clause, to_sql_and_params as finish_sql, uuid_condition, BuiltSql,
};
use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, Filter},
};
use diesel_async::AsyncPgConnection;
use serde_json::Value;

const ENTITY: &str = "advisory_coordinates";
const JOINED: &str = "jsonb_build_object(\
'cve_id', a.cve_id, \
'title', a.title, \
'severity', a.severity, \
'cvss_score', a.cvss_score, \
'kev', a.kev, \
'current', a.current)";

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    execute_json(conn, build_sql(plan)?).await
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    Ok(finish_sql(build_sql(plan)?))
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    if !matches!(plan.entity, Entity::AdvisoryCoordinates) {
        return Err(ServiceError::InvalidRequest(
            "entity not supported by advisory_coordinates query".into(),
        ));
    }
    reject_downsample_and_rollup(plan, ENTITY)
}

fn build_sql(plan: &QueryPlan) -> Result<BuiltSql> {
    ensure_entity(plan)?;
    let stats = parse_count_stats(plan.stats.as_ref())?;
    if stats.is_some() && !is_selective_coordinate_query(&plan.filters) {
        return Err(ServiceError::InvalidRequest(
            "advisory_coordinates stats require a selective filter (cve, advisory_ref, cpe_vendor+cpe_product, or cpe/value)".into(),
        ));
    }

    let mut where_parts = Vec::new();
    let mut binds = Vec::new();

    if let Some(range) = &plan.time_range {
        where_parts.push(time_clause("c.inserted_at", range, &mut binds));
    }

    for filter in &plan.filters {
        where_parts.push(row_condition(filter, &mut binds)?);
    }

    if !has_filter(&plan.filters, &["current"]) {
        where_parts.push("a.current = TRUE".into());
    }

    let where_sql = if where_parts.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", where_parts.join(" AND "))
    };
    let from_sql =
        " FROM advisory_coordinates c JOIN vulnerability_advisories a ON a.id = c.advisory_ref";

    if let Some(stats) = stats {
        let groups = resolve_stats_groups(&stats.group_fields)?;
        let stats_order = stats_order_sql(&groups);
        let group_sql = if groups.is_empty() {
            String::new()
        } else {
            format!(
                " GROUP BY {}",
                groups
                    .iter()
                    .map(|(_, expr)| *expr)
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        };
        binds.push(BindParam::Int(plan.limit));
        binds.push(BindParam::Int(plan.offset));
        return Ok(BuiltSql {
            sql: format!(
                "{}{from_sql}{where_sql}{group_sql}{stats_order} LIMIT ? OFFSET ?",
                stats_select(&stats.alias, &groups)
            ),
            binds,
        });
    }

    let order = format!(
        "{}, c.id ASC",
        order_sql(
            &plan.order,
            "c.cpe_vendor ASC NULLS LAST, c.cpe_product ASC NULLS LAST, c.value ASC",
            order_column,
            ENTITY,
        )?
    );
    binds.push(BindParam::Int(plan.limit));
    binds.push(BindParam::Int(plan.offset));
    Ok(BuiltSql {
        sql: format!(
            "SELECT (to_jsonb(c) || {JOINED}) AS payload{from_sql}{where_sql}{order} LIMIT ? OFFSET ?"
        ),
        binds,
    })
}

fn row_condition(filter: &Filter, binds: &mut Vec<BindParam>) -> Result<String> {
    match filter.field.as_str() {
        "id" => uuid_condition("c.id", filter, binds),
        "advisory_ref" => uuid_condition("c.advisory_ref", filter, binds),
        "coordinate_type" => text_condition("c.coordinate_type", filter, binds, false),
        "value" | "cpe" | "cpes" => text_condition("c.value", filter, binds, false),
        "cpe_part" => text_condition("c.cpe_part", filter, binds, false),
        "cpe_vendor" => text_condition("c.cpe_vendor", filter, binds, false),
        "cpe_product" => text_condition("c.cpe_product", filter, binds, false),
        "cpe_version" => text_condition("c.cpe_version", filter, binds, false),
        "cve" | "cve_id" => text_condition("a.cve_id", filter, binds, true),
        "provider" => text_condition("c.provider", filter, binds, false),
        "feed_key" => text_condition("c.feed_key", filter, binds, false),
        "kev" => bool_condition("a.kev", filter, binds),
        "current" => bool_condition("a.current", filter, binds),
        "cvss_score" => numeric_condition("a.cvss_score", filter, binds),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for advisory_coordinates: '{other}'"
        ))),
    }
}

fn resolve_stats_groups(fields: &[String]) -> Result<Vec<(&'static str, &'static str)>> {
    fields
        .iter()
        .map(|field| match field.as_str() {
            "cve_id" | "cve" => Ok(("cve_id", "a.cve_id")),
            "cpe_vendor" => Ok(("cpe_vendor", "c.cpe_vendor")),
            "cpe_product" => Ok(("cpe_product", "c.cpe_product")),
            "coordinate_type" => Ok(("coordinate_type", "c.coordinate_type")),
            "kev" => Ok(("kev", "a.kev")),
            "provider" => Ok(("provider", "c.provider")),
            other => Err(ServiceError::InvalidRequest(format!(
                "unsupported stats group field '{other}' for advisory_coordinates"
            ))),
        })
        .collect()
}

fn order_column(field: &str) -> Option<&'static str> {
    match field {
        "cpe_vendor" => Some("c.cpe_vendor"),
        "cpe_product" => Some("c.cpe_product"),
        "value" | "cpe" => Some("c.value"),
        "cve" | "cve_id" => Some("a.cve_id"),
        "inserted_at" | "time" => Some("c.inserted_at"),
        "kev" => Some("a.kev"),
        "cvss_score" => Some("a.cvss_score"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::query::advisory::plan_for_query;

    #[test]
    fn lists_cpes_for_a_cve_via_current_join() {
        let plan = plan_for_query("in:advisory_coordinates cve:CVE-2024-1234 coordinate_type:cpe");
        let (sql, binds) = to_sql_and_params(&plan).expect("sql");
        assert!(sql.contains("advisory_coordinates"));
        assert!(sql.contains("JOIN vulnerability_advisories"));
        assert!(sql.contains("a.current = TRUE"));
        assert!(sql.contains("a.cve_id = $"));
        assert!(sql.contains("c.coordinate_type = $"));
        assert!(sql.contains("version_start") || sql.contains("to_jsonb(c)"));
        assert!(binds
            .iter()
            .any(|bind| matches!(bind, BindParam::Text(value) if value == "CVE-2024-1234")));
    }

    #[test]
    fn wildcard_cpe_uses_ilike() {
        let plan = plan_for_query("in:advisory_cpes cpe:cpe:2.3:a:nginx:nginx:%");
        let (sql, _) = to_sql_and_params(&plan).expect("sql");
        assert!(sql.contains("c.value ILIKE $"));
    }

    #[test]
    fn unfiltered_browse_still_limits_and_joins_current() {
        let plan = plan_for_query("in:advisory_coordinates limit:100");
        let (sql, _) = to_sql_and_params(&plan).expect("sql");
        assert!(sql.contains("LIMIT $"));
        assert!(sql.contains("a.current = TRUE"));
        assert!(sql.contains("JOIN vulnerability_advisories"));
    }

    #[test]
    fn row_orders_end_with_coordinate_id_for_stable_pagination() {
        let (default_sql, _) =
            to_sql_and_params(&plan_for_query("in:advisory_coordinates")).expect("sql");
        assert!(default_sql.contains(
            "ORDER BY c.cpe_vendor ASC NULLS LAST, c.cpe_product ASC NULLS LAST, c.value ASC, c.id ASC LIMIT"
        ));

        let (explicit_sql, _) = to_sql_and_params(&plan_for_query(
            "in:advisory_coordinates sort:cvss_score:desc",
        ))
        .expect("sql");
        assert!(explicit_sql.contains("ORDER BY a.cvss_score DESC NULLS LAST, c.id ASC LIMIT"));
    }

    #[test]
    fn unbounded_stats_are_rejected() {
        let plan = plan_for_query("in:advisory_coordinates stats:count() as n by cpe_vendor");
        let err = to_sql_and_params(&plan).unwrap_err();
        assert!(
            err.to_string().contains("selective filter"),
            "expected selective-filter error, got {err}"
        );
    }

    #[test]
    fn selective_stats_are_allowed() {
        let plan = plan_for_query(
            "in:advisory_coordinates cpe_vendor:nginx cpe_product:nginx stats:count() as n by cpe_vendor,cpe_product",
        );
        let (sql, _) = to_sql_and_params(&plan).expect("sql");
        assert!(sql.contains("GROUP BY c.cpe_vendor, c.cpe_product"));
        assert!(sql.contains(
            "ORDER BY COUNT(*) DESC, c.cpe_vendor ASC NULLS LAST, c.cpe_product ASC NULLS LAST LIMIT"
        ));
        assert!(sql.contains("c.cpe_vendor = $"));
        assert!(sql.contains("c.cpe_product = $"));
    }
}
