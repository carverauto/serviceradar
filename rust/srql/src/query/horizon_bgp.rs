use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::HorizonBgpEventRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::horizon_bgp_events::dsl::{
        caida_leak_inference as col_caida_leak_inference, client_label as col_client_label,
        event_id as col_event_id, horizon_bgp_events, kind as col_kind, level as col_level,
        origin_asn as col_origin_asn, prefix as col_prefix, rpki_status as col_rpki_status,
        time as col_time, watchlist_id as col_watchlist_id,
    },
    time::TimeRange,
};
use diesel::PgTextExpressionMethods;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel_async::{AsyncPgConnection, RunQueryDsl};

type HorizonBgpTable = crate::schema::horizon_bgp_events::table;
type HorizonBgpFromClause = FromClause<HorizonBgpTable>;
type HorizonBgpQuery<'a> =
    BoxedSelectStatement<'a, <HorizonBgpTable as AsQuery>::SqlType, HorizonBgpFromClause, Pg>;

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;
    super::reject_stats(plan, "horizon_bgp")?;
    let query = build_query(plan)?;
    let rows: Vec<HorizonBgpEventRow> = query
        .select(HorizonBgpEventRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<HorizonBgpEventRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .map(HorizonBgpEventRow::into_json)
        .collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;
    super::reject_stats(plan, "horizon_bgp")?;
    let query = build_query(plan)?.limit(plan.limit).offset(plan.offset);
    let sql = super::diesel_sql(&query)?;

    let mut params = Vec::new();
    if let Some(TimeRange { start, end }) = &plan.time_range {
        params.push(BindParam::timestamptz(*start));
        params.push(BindParam::timestamptz(*end));
    }

    for filter in &plan.filters {
        collect_filter_params(&mut params, filter)?;
    }

    super::reconcile_limit_offset_binds(&sql, &mut params, plan.limit, plan.offset)?;

    #[cfg(any(test, debug_assertions))]
    {
        let bind_count = super::diesel_bind_count(&query)?;
        if bind_count != params.len() {
            return Err(ServiceError::Internal(anyhow::anyhow!(
                "bind count mismatch (diesel {bind_count} vs params {})",
                params.len()
            )));
        }
    }

    Ok((sql, params))
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    match plan.entity {
        Entity::HorizonBgp => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by horizon_bgp query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<HorizonBgpQuery<'static>> {
    let mut query = horizon_bgp_events.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_time.ge(*start).and(col_time.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    Ok(apply_ordering(query, &plan.order))
}

fn apply_filter<'a>(
    mut query: HorizonBgpQuery<'a>,
    filter: &Filter,
) -> Result<HorizonBgpQuery<'a>> {
    match filter.field.as_str() {
        "event_id" => query = apply_text_filter!(query, filter, col_event_id)?,
        "kind" => query = apply_text_filter!(query, filter, col_kind)?,
        "level" => query = apply_text_filter!(query, filter, col_level)?,
        "prefix" => query = apply_text_filter!(query, filter, col_prefix)?,
        "rpki_status" => query = apply_text_filter!(query, filter, col_rpki_status)?,
        "caida_leak_inference" => {
            query = apply_text_filter!(query, filter, col_caida_leak_inference)?;
        }
        "watchlist_id" => query = apply_text_filter!(query, filter, col_watchlist_id)?,
        "client_label" => query = apply_text_filter!(query, filter, col_client_label)?,
        "origin_asn" => {
            let value = parse_i64(filter.value.as_scalar()?)?;
            query = apply_ordered_filter!(query, filter, col_origin_asn, value)?;
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for horizon_bgp: '{other}'"
            )));
        }
    }

    Ok(query)
}

fn collect_text_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq | FilterOp::Like | FilterOp::NotLike => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if !values.is_empty() {
                params.push(BindParam::TextArray(values));
            }
            Ok(())
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for text filter: {:?}",
            filter.op
        ))),
    }
}

fn collect_filter_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.field.as_str() {
        "event_id"
        | "kind"
        | "level"
        | "prefix"
        | "rpki_status"
        | "caida_leak_inference"
        | "watchlist_id"
        | "client_label" => collect_text_params(params, filter),
        "origin_asn" => {
            params.push(BindParam::Int(parse_i64(filter.value.as_scalar()?)?));
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for horizon_bgp: '{other}'"
        ))),
    }
}

fn apply_ordering<'a>(
    mut query: HorizonBgpQuery<'a>,
    order: &[OrderClause],
) -> HorizonBgpQuery<'a> {
    let mut applied = false;
    for clause in order {
        let recognized = matches!(
            clause.field.as_str(),
            "time" | "timestamp" | "kind" | "level" | "origin_asn"
        );
        if !recognized {
            continue;
        }
        query = if !applied {
            applied = true;
            match (clause.field.as_str(), clause.direction) {
                ("time" | "timestamp", OrderDirection::Asc) => query.order(col_time.asc()),
                ("time" | "timestamp", OrderDirection::Desc) => query.order(col_time.desc()),
                ("kind", OrderDirection::Asc) => query.order(col_kind.asc()),
                ("kind", OrderDirection::Desc) => query.order(col_kind.desc()),
                ("level", OrderDirection::Asc) => query.order(col_level.asc()),
                ("level", OrderDirection::Desc) => query.order(col_level.desc()),
                ("origin_asn", OrderDirection::Asc) => query.order(col_origin_asn.asc()),
                ("origin_asn", OrderDirection::Desc) => query.order(col_origin_asn.desc()),
                _ => query,
            }
        } else {
            match (clause.field.as_str(), clause.direction) {
                ("time" | "timestamp", OrderDirection::Asc) => query.then_order_by(col_time.asc()),
                ("time" | "timestamp", OrderDirection::Desc) => {
                    query.then_order_by(col_time.desc())
                }
                ("kind", OrderDirection::Asc) => query.then_order_by(col_kind.asc()),
                ("kind", OrderDirection::Desc) => query.then_order_by(col_kind.desc()),
                ("level", OrderDirection::Asc) => query.then_order_by(col_level.asc()),
                ("level", OrderDirection::Desc) => query.then_order_by(col_level.desc()),
                ("origin_asn", OrderDirection::Asc) => query.then_order_by(col_origin_asn.asc()),
                ("origin_asn", OrderDirection::Desc) => query.then_order_by(col_origin_asn.desc()),
                _ => query,
            }
        };
    }

    if !applied {
        query = query.order(col_time.desc());
    }

    query
}

fn parse_i64(raw: &str) -> Result<i64> {
    raw.parse::<i64>()
        .map_err(|_| ServiceError::InvalidRequest(format!("invalid integer '{raw}'")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{parser::parse, query::build_query_plan};
    use std::sync::Arc;

    fn plan_for(query: &str) -> QueryPlan {
        let config = Arc::new(crate::config::AppConfig::embedded(
            "postgres://localhost/serviceradar".to_string(),
        ));
        let request = crate::query::QueryRequest {
            query: query.to_string(),
            limit: None,
            cursor: None,
            direction: crate::query::QueryDirection::Next,
            mode: None,
            permitted_signals: None,
        };
        let ast = parse(query).expect("query should parse");
        build_query_plan(config.as_ref(), &request, ast).expect("query plan should build")
    }

    #[test]
    fn horizon_bgp_sql_includes_filters_and_bind_parity() {
        let plan = plan_for(
            "in:horizon_bgp kind:hijack level:critical prefix:198.51.100.0/24 origin_asn:64512 rpki_status:invalid watchlist_id:wl-1 client_label:core-edge time:last_6h limit:50",
        );
        let (sql, params) = to_sql_and_params(&plan).expect("should build SQL");
        let lower = sql.to_lowercase();

        assert!(lower.contains("\"horizon_bgp_events\".\"kind\""));
        assert!(lower.contains("\"horizon_bgp_events\".\"level\""));
        assert!(lower.contains("\"horizon_bgp_events\".\"prefix\""));
        assert!(lower.contains("\"horizon_bgp_events\".\"origin_asn\""));
        assert!(lower.contains("\"horizon_bgp_events\".\"rpki_status\""));
        assert!(lower.contains("\"horizon_bgp_events\".\"watchlist_id\""));
        assert!(lower.contains("\"horizon_bgp_events\".\"client_label\""));
        assert!(params.iter().any(|p| matches!(p, BindParam::Int(64512))));
        assert!(
            params
                .iter()
                .any(|p| matches!(p, BindParam::Text(v) if v == "hijack"))
        );
    }

    #[test]
    fn horizon_bgp_supports_list_and_alias() {
        let plan = plan_for("in:horizon_bgp_events kind:(hijack,watchlist) sort:level:desc");
        let (sql, params) = to_sql_and_params(&plan).expect("should build SQL");
        assert!(sql.to_lowercase().contains("\"horizon_bgp_events\""));
        assert!(
            params
                .iter()
                .any(|p| matches!(p, BindParam::TextArray(vals) if vals.len() == 2))
        );
    }

    #[test]
    fn horizon_bgp_rejects_unknown_filter() {
        let plan = plan_for("in:horizon_bgp nope:123");
        let result = to_sql_and_params(&plan);
        assert!(matches!(result, Err(ServiceError::InvalidRequest(_))));
    }
}
