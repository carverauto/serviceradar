//! StarRocks-only SRQL dialect for Horizon telemetry entities:
//! `in:horizon_outages`, `in:horizon_bgp`, `in:horizon_zombies`, and
//! `in:horizon_paths` (`priv/starrocks/0044_horizon_tables.sql`).

use super::super::{PaginationMeta, QueryPlan, TranslateResponse, types::BindParam};
use super::{pg_order_sql, text_filter_sql};
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
};

struct HorizonSpec {
    entity_name: &'static str,
    table: &'static str,
    columns: &'static [&'static str],
    text_fields: &'static [&'static str],
    i32_fields: &'static [&'static str],
    i64_fields: &'static [&'static str],
    f64_fields: &'static [&'static str],
    bool_fields: &'static [&'static str],
    sort_fields: &'static [&'static str],
}

const OUTAGES_SPEC: HorizonSpec = HorizonSpec {
    entity_name: "horizon_outages",
    table: "horizon_outages",
    columns: &[
        "time",
        "outage_id",
        "status",
        "severity",
        "entity_type",
        "entity_key",
        "region",
        "covering_prefix",
        "origin_asn",
        "corroborating_pop_count",
        "avg_forwarding_loss_pct",
        "avg_synthetic_failure_pct",
        "window_start_ms",
        "window_end_ms",
        "correlated_bgp_event_ids",
        "raw_data",
    ],
    text_fields: &[
        "outage_id",
        "status",
        "severity",
        "entity_type",
        "entity_key",
        "region",
        "covering_prefix",
    ],
    i32_fields: &["corroborating_pop_count"],
    i64_fields: &["origin_asn"],
    f64_fields: &["avg_forwarding_loss_pct", "avg_synthetic_failure_pct"],
    bool_fields: &[],
    sort_fields: &[
        "time",
        "severity",
        "status",
        "corroborating_pop_count",
        "avg_forwarding_loss_pct",
    ],
};

const BGP_SPEC: HorizonSpec = HorizonSpec {
    entity_name: "horizon_bgp",
    table: "horizon_bgp_events",
    columns: &[
        "time",
        "event_id",
        "kind",
        "level",
        "prefix",
        "origin_asn",
        "as_path",
        "rpki_status",
        "caida_leak_inference",
        "watchlist_id",
        "client_label",
        "raw_data",
    ],
    text_fields: &[
        "event_id",
        "kind",
        "level",
        "prefix",
        "rpki_status",
        "caida_leak_inference",
        "watchlist_id",
        "client_label",
    ],
    i32_fields: &[],
    i64_fields: &["origin_asn"],
    f64_fields: &[],
    bool_fields: &[],
    sort_fields: &["time", "kind", "level", "origin_asn"],
};

const ZOMBIES_SPEC: HorizonSpec = HorizonSpec {
    entity_name: "horizon_zombies",
    table: "horizon_bgp_zombies",
    columns: &[
        "time",
        "episode_id",
        "status",
        "prefix",
        "origin_asn",
        "divergence_pct",
        "is_beacon",
        "withdrawn_peers",
        "total_peers",
        "stuck_peer_asns",
        "first_seen_at",
        "resolved_at",
        "raw_data",
    ],
    text_fields: &["episode_id", "status", "prefix"],
    i32_fields: &[],
    i64_fields: &["origin_asn"],
    f64_fields: &["divergence_pct"],
    bool_fields: &["is_beacon"],
    sort_fields: &["time", "status", "divergence_pct", "first_seen_at"],
};

const PATHS_SPEC: HorizonSpec = HorizonSpec {
    entity_name: "horizon_paths",
    table: "horizon_path_hops",
    columns: &[
        "time",
        "round_id",
        "target_id",
        "pop_id",
        "hop_ttl",
        "hop_ip",
        "router_alias_id",
        "alias_confidence",
        "asn",
        "as_org",
        "is_cloud",
        "cloud_provider",
        "cloud_region",
        "forwarding_loss_pct",
        "avg_rtt_ms",
        "effective_path_mtu",
        "mtu_blackhole_detected",
        "blackhole_hop_ttl",
        "raw_data",
    ],
    text_fields: &[
        "round_id",
        "target_id",
        "pop_id",
        "hop_ip",
        "router_alias_id",
        "as_org",
        "cloud_provider",
        "cloud_region",
    ],
    i32_fields: &["hop_ttl"],
    i64_fields: &["asn"],
    f64_fields: &["forwarding_loss_pct", "avg_rtt_ms"],
    bool_fields: &["is_cloud", "mtu_blackhole_detected"],
    sort_fields: &["time", "hop_ttl", "forwarding_loss_pct", "avg_rtt_ms"],
};

pub(super) fn translate(plan: &QueryPlan, database: &str) -> Result<TranslateResponse> {
    let spec = spec_for(&plan.entity)?;
    refuse_unsupported_clauses(plan, spec.entity_name)?;

    let from = format!("{database}.{}", spec.table);
    let (mut predicates, params) = time_bounds(plan);
    for filter in &plan.filters {
        predicates.push(filter_sql(spec, filter)?);
    }

    let where_sql = if predicates.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", predicates.join(" AND "))
    };

    let select_list = spec
        .columns
        .iter()
        .map(|col| quoted(col))
        .collect::<Vec<_>>()
        .join(", ");
    let order_sql = order_clause(spec, &plan.order);
    let sql = format!(
        "SELECT {select_list} FROM {from}{where_sql} ORDER BY {order_sql} LIMIT {} OFFSET {}",
        plan.limit, plan.offset
    );

    Ok(TranslateResponse {
        read_model: None,
        sql,
        params,
        pagination: PaginationMeta {
            next_cursor: None,
            prev_cursor: None,
            limit: Some(plan.limit),
        },
        viz: super::super::viz::meta_for_plan(plan),
    })
}

fn spec_for(entity: &Entity) -> Result<&'static HorizonSpec> {
    match entity {
        Entity::HorizonOutages => Ok(&OUTAGES_SPEC),
        Entity::HorizonBgp => Ok(&BGP_SPEC),
        Entity::HorizonZombies => Ok(&ZOMBIES_SPEC),
        Entity::HorizonPaths => Ok(&PATHS_SPEC),
        other => Err(ServiceError::Internal(anyhow::anyhow!(
            "the StarRocks Horizon dialect was handed {other:?}"
        ))),
    }
}

fn refuse_unsupported_clauses(plan: &QueryPlan, entity_name: &str) -> Result<()> {
    super::super::reject_stats(plan, entity_name)?;

    if let Some(kind) = plan
        .rollup_stats
        .as_deref()
        .map(str::trim)
        .filter(|kind| !kind.is_empty())
    {
        return Err(ServiceError::InvalidRequest(format!(
            "rollup_stats:{kind} is not supported for {entity_name}"
        )));
    }

    if plan.downsample.is_some() {
        return Err(ServiceError::InvalidRequest(format!(
            "bucket: is not supported for {entity_name}"
        )));
    }

    if plan.other {
        return Err(ServiceError::InvalidRequest(
            "other:true is currently supported only for flow or timeseries stats".into(),
        ));
    }

    Ok(())
}

fn quoted(column: &str) -> String {
    format!("`{column}`")
}

fn time_bounds(plan: &QueryPlan) -> (Vec<String>, Vec<BindParam>) {
    let Some(range) = &plan.time_range else {
        return (Vec::new(), Vec::new());
    };
    let literal = |value: chrono::DateTime<chrono::Utc>| {
        format!("'{}'", value.format("%Y-%m-%d %H:%M:%S%.6f"))
    };
    (
        vec![
            format!("`time` >= {}", literal(range.start)),
            format!("`time` <= {}", literal(range.end)),
        ],
        vec![
            BindParam::timestamptz(range.start),
            BindParam::timestamptz(range.end),
        ],
    )
}

fn filter_sql(spec: &HorizonSpec, filter: &Filter) -> Result<String> {
    let field = filter.field.as_str();
    if spec.text_fields.contains(&field) {
        return text_filter_sql(&quoted(field), filter, true);
    }
    if spec.i32_fields.contains(&field) {
        let value = parse_i32(filter.value.as_scalar()?)?;
        return numeric_sql(field, filter.op.clone(), &value.to_string());
    }
    if spec.i64_fields.contains(&field) {
        let value = parse_i64(filter.value.as_scalar()?)?;
        return numeric_sql(field, filter.op.clone(), &value.to_string());
    }
    if spec.f64_fields.contains(&field) {
        let value = parse_f64(filter.value.as_scalar()?)?;
        return numeric_sql(field, filter.op.clone(), &value.to_string());
    }
    if spec.bool_fields.contains(&field) {
        let value = parse_bool(filter.value.as_scalar()?)?;
        let op = match filter.op {
            FilterOp::Eq => "=",
            FilterOp::NotEq => "<>",
            _ => {
                return Err(ServiceError::InvalidRequest(format!(
                    "{field} only supports equality comparisons"
                )));
            }
        };
        let literal = if value { "TRUE" } else { "FALSE" };
        return Ok(format!("{} {op} {literal}", quoted(field)));
    }

    Err(ServiceError::InvalidRequest(format!(
        "unsupported filter field for {}: '{field}'",
        spec.entity_name
    )))
}

fn numeric_sql(field: &str, op: FilterOp, literal: &str) -> Result<String> {
    let sql_op = match op {
        FilterOp::Eq => "=",
        FilterOp::NotEq => "<>",
        FilterOp::Gt => ">",
        FilterOp::Gte => ">=",
        FilterOp::Lt => "<",
        FilterOp::Lte => "<=",
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "{field} supports equality and ordered comparisons"
            )));
        }
    };
    Ok(format!("{} {sql_op} {literal}", quoted(field)))
}

fn order_clause(spec: &HorizonSpec, order: &[OrderClause]) -> String {
    let terms: Vec<String> = order
        .iter()
        .filter(|clause| spec.sort_fields.contains(&clause.field.as_str()))
        .map(|clause| {
            format!(
                "{} {}",
                quoted(&clause.field),
                pg_order_sql(clause.direction)
            )
        })
        .collect();

    if terms.is_empty() {
        format!("{} {}", quoted("time"), pg_order_sql(OrderDirection::Desc))
    } else {
        terms.join(", ")
    }
}

fn parse_i32(raw: &str) -> Result<i32> {
    raw.parse::<i32>()
        .map_err(|_| ServiceError::InvalidRequest(format!("invalid integer '{raw}'")))
}

fn parse_i64(raw: &str) -> Result<i64> {
    raw.parse::<i64>()
        .map_err(|_| ServiceError::InvalidRequest(format!("invalid integer '{raw}'")))
}

fn parse_f64(raw: &str) -> Result<f64> {
    raw.parse::<f64>()
        .map_err(|_| ServiceError::InvalidRequest(format!("invalid float '{raw}'")))
}

fn parse_bool(raw: &str) -> Result<bool> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "true" | "1" | "yes" => Ok(true),
        "false" | "0" | "no" => Ok(false),
        _ => Err(ServiceError::InvalidRequest(format!(
            "invalid boolean '{raw}'"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use crate::{
        config::AppConfig,
        error::ServiceError,
        parser::parse,
        query::{QueryDirection, QueryRequest, translate_request},
    };

    fn translate_starrocks(query: &str) -> crate::error::Result<crate::query::TranslateResponse> {
        let config = AppConfig::embedded("postgres://localhost/serviceradar".to_string());
        let request = QueryRequest {
            query: query.to_string(),
            limit: None,
            cursor: None,
            direction: QueryDirection::Next,
            mode: Some("starrocks".to_string()),
            permitted_signals: None,
        };
        translate_request(&config, request)
    }

    #[test]
    fn translates_horizon_outages_with_filters_and_time_bounds() {
        let resp = translate_starrocks(
            "in:horizon_outages status:active severity:major entity_type:asn entity_key:AS13335 region:us-east covering_prefix:1.1.1.0/24 origin_asn:13335 outage_id:out-1 time:last_24h limit:25",
        )
        .expect("should translate horizon_outages");

        assert!(resp.sql.contains("FROM serviceradar.horizon_outages"));
        assert!(resp.sql.contains("`status` = 'active'"));
        assert!(resp.sql.contains("`covering_prefix` = '1.1.1.0/24'"));
        assert!(resp.sql.contains("`origin_asn` = 13335"));
        assert!(resp.sql.contains("`time` >="));
        assert!(resp.sql.contains("LIMIT 25 OFFSET 0"));
        assert!(resp.viz.is_some());
    }

    #[test]
    fn translates_horizon_bgp_zombies_and_paths() {
        let bgp = translate_starrocks(
            "in:horizon_bgp kind:(hijack,watchlist) level:critical prefix:198.51.100.0/24 origin_asn:64512 rpki_status:invalid watchlist_id:wl-1 client_label:core-edge",
        )
        .expect("should translate horizon_bgp");
        assert!(bgp.sql.contains("FROM serviceradar.horizon_bgp_events"));
        assert!(bgp.sql.contains("`kind` IN ('hijack', 'watchlist')"));
        assert!(bgp.sql.contains("`origin_asn` = 64512"));

        let zombies = translate_starrocks(
            "in:horizon_zombies status:active prefix:203.0.113.0/24 origin_asn:64513 episode_id:ep-42 is_beacon:true divergence_pct:>=25.5",
        )
        .expect("should translate horizon_zombies");
        assert!(
            zombies
                .sql
                .contains("FROM serviceradar.horizon_bgp_zombies")
        );
        assert!(zombies.sql.contains("`is_beacon` = TRUE"));
        assert!(zombies.sql.contains("`divergence_pct` >= 25.5"));

        let paths = translate_starrocks(
            "in:horizon_paths target_id:tgt-1 pop_id:iad-1 hop_ip:198.51.100.1 router_alias_id:rtr-9 asn:15169 is_cloud:true cloud_provider:gcp mtu_blackhole_detected:false sort:hop_ttl:asc",
        )
        .expect("should translate horizon_paths");
        assert!(paths.sql.contains("FROM serviceradar.horizon_path_hops"));
        assert!(paths.sql.contains("`is_cloud` = TRUE"));
        assert!(paths.sql.contains("`mtu_blackhole_detected` = FALSE"));
        assert!(paths.sql.contains("`hop_ttl` ASC"));
    }

    #[test]
    fn rejects_non_starrocks_mode_and_removed_aliases() {
        let config = AppConfig::embedded("postgres://localhost/serviceradar".to_string());
        for entity in [
            "horizon_outages",
            "horizon_bgp",
            "horizon_zombies",
            "horizon_paths",
        ] {
            let request = QueryRequest {
                query: format!("in:{entity} limit:10"),
                limit: None,
                cursor: None,
                direction: QueryDirection::Next,
                mode: None,
                permitted_signals: None,
            };
            assert!(matches!(
                translate_request(&config, request),
                Err(ServiceError::InvalidRequest(_))
            ));
        }

        for removed_alias in [
            "horizon_outage",
            "horizon_bgp_events",
            "horizon_bgp_event",
            "horizon_bgp_zombies",
            "horizon_bgp_zombie",
            "horizon_path_hops",
            "horizon_path_hop",
        ] {
            assert!(
                parse(&format!("in:{removed_alias}")).is_err(),
                "expected removed alias '{removed_alias}' to be rejected"
            );
        }
    }

    #[test]
    fn rejects_unknown_filters_and_unsupported_clauses() {
        assert!(matches!(
            translate_starrocks("in:horizon_outages prefix:1.1.1.0/24"),
            Err(ServiceError::InvalidRequest(_))
        ));
        assert!(matches!(
            translate_starrocks("in:horizon_bgp unknown:val"),
            Err(ServiceError::InvalidRequest(_))
        ));
        assert!(matches!(
            translate_starrocks("in:horizon_zombies stats:count() as n"),
            Err(ServiceError::InvalidRequest(_))
        ));
        assert!(matches!(
            translate_starrocks("in:horizon_paths bucket:5m"),
            Err(ServiceError::InvalidRequest(_))
        ));
    }
}
