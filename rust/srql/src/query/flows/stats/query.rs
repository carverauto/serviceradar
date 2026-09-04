use super::*;
use crate::query::build_other_rollup_sql;

pub(in crate::query::flows::stats) async fn execute_stats(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<Value>> {
    let query = execution_query(plan)?;

    let rows: Vec<FlowStatsPayload> = query
        .load::<FlowStatsPayload>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .filter_map(|row| row.result.map(serde_json::Value::from))
        .collect())
}

/// The Diesel query `execute_stats` loads, built from the same rewrite the translate
/// path uses.
///
/// `build_grouped_stats_query` emits `?` placeholders -- the time-range clause is
/// literally `f.time >= ?::timestamptz`. Diesel does NOT translate `?` for Postgres:
/// `SqlQuery::walk_ast` pushes the text verbatim and each bind then appends its own
/// `$n`. `?` is also the jsonb-exists operator, so the failure is a syntax error at the
/// NEXT token, naming neither the placeholder nor the column. This path used to build
/// the SQL a second time and skip the rewrite, which no test calling
/// `to_sql_and_params_stats` could see -- that path was never broken.
pub(in crate::query) fn execution_query(
    plan: &QueryPlan,
) -> Result<BoxedSqlQuery<'static, Pg, SqlQuery>> {
    let spec = parse_stats_expr(
        plan.stats
            .as_ref()
            .ok_or_else(|| {
                ServiceError::InvalidRequest("stats expression required for aggregation".into())
            })?
            .as_raw(),
    )?;
    let grouped = build_grouped_stats_query(plan, &spec)?;
    let mut query = diesel::sql_query(rewrite_placeholders(&grouped.sql)).into_boxed();
    for bind in &grouped.binds {
        query = bind.apply(query);
    }
    Ok(query)
}

pub(in crate::query::flows::stats) fn to_sql_and_params_stats(
    plan: &QueryPlan,
) -> Result<(String, Vec<BindParam>)> {
    let spec = parse_stats_expr(
        plan.stats
            .as_ref()
            .ok_or_else(|| {
                ServiceError::InvalidRequest("stats expression required for aggregation".into())
            })?
            .as_raw(),
    )?;

    let grouped = build_grouped_stats_query(plan, &spec)?;
    let sql = rewrite_placeholders(&grouped.sql);
    let params: Vec<BindParam> = grouped
        .binds
        .into_iter()
        .map(bind_param_from_flow_stats)
        .collect();
    Ok((sql, params))
}

fn build_grouped_stats_query(
    plan: &QueryPlan,
    spec: &FlowStatsSpec,
) -> Result<FlowGroupedStatsSql> {
    let mut binds: Vec<FlowSqlBindValue> = Vec::new();
    let mut where_parts: Vec<String> = Vec::new();

    if plan.other {
        validate_flow_other_rollup(spec)?;
    }

    // Guardrails: multi-dimension group-by can be expensive. Require explicit time window and cap limit.
    if spec.group_by.len() > 1 {
        if plan.time_range.is_none() {
            return Err(ServiceError::InvalidRequest(
                "multi-dimension flow stats queries require an explicit time window".into(),
            ));
        }
        if plan.limit > 500 {
            return Err(ServiceError::InvalidRequest(
                "multi-dimension flow stats queries require limit <= 500".into(),
            ));
        }
    }

    if let Some(TimeRange { start, end }) = &plan.time_range {
        // ocsf_network_activity.time is a timestamp without timezone storing UTC; normalize the bind.
        where_parts.push("f.time >= ?::timestamptz AND f.time < ?::timestamptz".to_string());
        binds.push(FlowSqlBindValue::Timestamp(*start));
        binds.push(FlowSqlBindValue::Timestamp(*end));
    }

    if matches!(plan.entity, Entity::AttributedFlows) {
        where_parts.push(ATTRIBUTED_FLOW_EVENT_TYPE_EXPR_ALIASED.to_string());
    }

    // Geo joins are only included if a requested group-by or filter needs them.
    let mut needs_src_geo = false;
    let mut needs_dst_geo = false;

    for group in &spec.group_by {
        if let FlowGroupSpec::Field(f) = group {
            match f {
                FlowGroupField::SrcCountryIso2 => needs_src_geo = true,
                FlowGroupField::DstCountryIso2 => needs_dst_geo = true,
                _ => {}
            }
        }
    }

    for filter in &plan.filters {
        match filter.field.as_str() {
            "src_country_iso2" | "src_country" => needs_src_geo = true,
            "dst_country_iso2" | "dst_country" => needs_dst_geo = true,
            _ => {}
        }
    }

    for filter in &plan.filters {
        where_parts.push(build_stats_filter_clause(filter, &mut binds)?);
    }

    let mut where_sql = if where_parts.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", where_parts.join(" AND "))
    };

    let mut join_sql = String::new();
    if needs_src_geo {
        join_sql.push_str(
            " LEFT JOIN ip_geo_enrichment_cache src_geo ON src_geo.ip = NULLIF(f.src_endpoint_ip, '') AND (src_geo.expires_at IS NULL OR src_geo.expires_at > now())",
        );
    }
    if needs_dst_geo {
        join_sql.push_str(
            " LEFT JOIN ip_geo_enrichment_cache dst_geo ON dst_geo.ip = NULLIF(f.dst_endpoint_ip, '') AND (dst_geo.expires_at IS NULL OR dst_geo.expires_at > now())",
        );
    }

    // Check if this query can be served from a CAGG
    let cagg_route = should_route_flow_stats_to_cagg(plan, spec);

    let (from_table, time_col) = if let Some((cagg_table, ts_col)) = cagg_route {
        (cagg_table, ts_col)
    } else {
        ("ocsf_network_activity", "time")
    };

    // For CAGG-routed queries, rewrite time predicates to use the bucket column
    // and re-add only the dimension-safe filters validated by should_route_flow_stats_to_cagg.
    if cagg_route.is_some() {
        where_parts.clear();
        binds.clear();
        if let Some(TimeRange { start, end }) = &plan.time_range {
            where_parts.push(format!(
                "f.{time_col} >= ?::timestamptz AND f.{time_col} < ?::timestamptz"
            ));
            binds.push(FlowSqlBindValue::Timestamp(*start));
            binds.push(FlowSqlBindValue::Timestamp(*end));
        }
        // Re-add dimension filters (safe columns validated by cagg_filter_fields)
        for filter in &plan.filters {
            where_parts.push(build_stats_filter_clause(filter, &mut binds)?);
        }
        where_sql = if where_parts.is_empty() {
            String::new()
        } else {
            format!(" WHERE {}", where_parts.join(" AND "))
        };
        // No geo joins for CAGG queries
        join_sql = String::new();
    }

    let agg_sqls: Vec<String> = spec
        .aggregations
        .iter()
        .map(|agg| {
            if cagg_route.is_some()
                && matches!(agg.agg_func, FlowAggFunc::Count)
                && matches!(agg.agg_field, FlowAggField::Star)
            {
                Ok("SUM(flow_count)".to_string())
            } else if matches!(agg.agg_func, FlowAggFunc::CountDistinct) {
                if matches!(agg.agg_field, FlowAggField::Star) {
                    return Err(ServiceError::InvalidRequest(
                        "count_distinct(*) is not supported".into(),
                    ));
                }
                Ok(format!("COUNT(DISTINCT {})", agg.agg_field.sql()))
            } else {
                let field_sql = if cagg_route.is_none() {
                    agg.agg_field
                        .sampled_volume_sql("f")
                        .unwrap_or_else(|| agg.agg_field.sql().to_string())
                } else {
                    agg.agg_field.sql().to_string()
                };

                Ok(format!("{}({field_sql})", agg.agg_func.sql()))
            }
        })
        .collect::<Result<Vec<_>>>()?;

    let outer_sql = if !spec.group_by.is_empty() {
        let mut seen: std::collections::HashSet<&'static str> = std::collections::HashSet::new();
        let mut group_keys: Vec<&'static str> = Vec::with_capacity(spec.group_by.len());
        let mut group_exprs: Vec<String> = Vec::with_capacity(spec.group_by.len());

        for g in &spec.group_by {
            let key = g.response_key();
            if !seen.insert(key) {
                return Err(ServiceError::InvalidRequest(format!(
                    "duplicate group-by key for flows stats: '{key}'"
                )));
            }
            group_keys.push(key);
            group_exprs.push(g.group_expr());
        }

        let select_groups = group_exprs
            .iter()
            .enumerate()
            .map(|(idx, expr)| format!("{expr} AS group_value_{idx}"))
            .collect::<Vec<_>>()
            .join(", ");

        let group_by_sql = group_exprs.join(", ");
        let select_aggs = agg_sqls
            .iter()
            .enumerate()
            .map(|(idx, expr)| format!("{expr} AS agg_value_{idx}"))
            .collect::<Vec<_>>()
            .join(", ");

        let inner = format!(
            "SELECT {select_groups}, {select_aggs} FROM {from_table} f{join_sql}{where_sql} GROUP BY {group_by_sql}"
        );

        let agg_aliases: Vec<&str> = spec
            .aggregations
            .iter()
            .map(|aggregation| aggregation.alias.as_str())
            .collect();
        let order_sql = build_stats_order_sql(plan, &group_keys, &agg_aliases)?;

        let mut json_parts: Vec<String> =
            Vec::with_capacity(group_keys.len() * 2 + spec.aggregations.len() * 2);
        for (idx, key) in group_keys.iter().enumerate() {
            json_parts.push(format!("'{key}'"));
            json_parts.push(format!("group_value_{idx}"));
        }
        for (idx, agg) in spec.aggregations.iter().enumerate() {
            json_parts.push(format!("'{}'", agg.alias));
            json_parts.push(format!("agg_value_{idx}"));
        }

        if plan.other {
            let rank_order_sql = build_stats_rank_order_sql(plan, &group_keys, &agg_aliases)?;
            let mut top_json_parts = json_parts.clone();
            top_json_parts.push("'__other__'".to_string());
            top_json_parts.push("false".to_string());

            let mut other_json_parts: Vec<String> =
                Vec::with_capacity(group_keys.len() * 2 + spec.aggregations.len() * 2 + 2);
            for key in &group_keys {
                other_json_parts.push(format!("'{key}'"));
                other_json_parts.push("NULL".to_string());
            }
            for (idx, agg) in spec.aggregations.iter().enumerate() {
                other_json_parts.push(format!("'{}'", agg.alias));
                other_json_parts.push(format!("COALESCE(SUM(agg_value_{idx}), 0)"));
            }
            other_json_parts.push("'__other__'".to_string());
            other_json_parts.push("true".to_string());

            build_other_rollup_sql(
                &inner,
                &rank_order_sql,
                &top_json_parts,
                &other_json_parts,
                "result",
                plan.limit,
            )
        } else {
            format!(
                "SELECT jsonb_build_object({json_args}) AS result FROM ({inner}) t{order_sql} LIMIT {limit} OFFSET {offset}",
                json_args = json_parts.join(", "),
                inner = inner,
                order_sql = order_sql,
                limit = plan.limit,
                offset = plan.offset
            )
        }
    } else {
        let select_aggs = agg_sqls
            .iter()
            .enumerate()
            .map(|(idx, expr)| format!("{expr} AS agg_value_{idx}"))
            .collect::<Vec<_>>()
            .join(", ");
        let inner = format!("SELECT {select_aggs} FROM {from_table} f{join_sql}{where_sql}");
        let json_parts = spec
            .aggregations
            .iter()
            .enumerate()
            .flat_map(|(idx, agg)| [format!("'{}'", agg.alias), format!("agg_value_{idx}")])
            .collect::<Vec<_>>()
            .join(", ");
        format!(
            "SELECT jsonb_build_object({json_parts}) AS result FROM ({inner}) t LIMIT 1",
            json_parts = json_parts,
            inner = inner
        )
    };

    Ok(FlowGroupedStatsSql {
        sql: outer_sql,
        binds,
    })
}
