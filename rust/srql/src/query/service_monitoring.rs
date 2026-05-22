use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    jsonb::DbJson,
    parser::{Entity, Filter, FilterOp, FilterValue, OrderClause, OrderDirection},
    time::TimeRange,
};
use diesel::deserialize::QueryableByName;
use diesel::pg::Pg;
use diesel::query_builder::{BoxedSqlQuery, SqlQuery};
use diesel::sql_query;
use diesel::sql_types::{Array, BigInt, Bool, Float8, Jsonb, Text, Timestamptz};
use diesel_async::{AsyncPgConnection, RunQueryDsl};

#[derive(Debug, QueryableByName)]
#[diesel(check_for_backend(diesel::pg::Pg))]
struct JsonPayloadRow {
    #[diesel(sql_type = Jsonb)]
    payload: DbJson,
}

#[derive(Debug, Clone, Copy)]
struct EntitySpec {
    table: &'static str,
    joins: &'static str,
    payload_extra: &'static str,
    default_order: &'static str,
    time_column: Option<&'static str>,
}

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;
    let (sql, params) = to_sql_and_params(plan)?;
    let mut query = sql_query(&sql).into_boxed::<Pg>();

    for param in params {
        query = bind_param(query, param)?;
    }

    let rows: Vec<JsonPayloadRow> = query
        .load::<JsonPayloadRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(|row| row.payload.into()).collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;

    if let Some(rollup) = plan.rollup_stats.as_deref() {
        return build_rollup_sql(plan, rollup);
    }

    let spec = entity_spec(&plan.entity)?;
    let mut params = Vec::new();
    let where_sql = where_sql(plan, spec, &mut params)?;
    let order_sql = order_sql(&plan.entity, &plan.order, spec.default_order)?;
    let limit_ref = push_param(&mut params, BindParam::Int(plan.limit));
    let offset_ref = push_param(&mut params, BindParam::Int(plan.offset));

    let sql = format!(
        "SELECT to_jsonb(t) || {payload_extra} AS payload FROM {table} t {joins}{where_sql} {order_sql} LIMIT {limit_ref} OFFSET {offset_ref}",
        payload_extra = spec.payload_extra,
        table = spec.table,
        joins = spec.joins,
    );

    Ok((sql, params))
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    if is_service_monitoring_entity(&plan.entity) {
        Ok(())
    } else {
        Err(ServiceError::InvalidRequest(
            "entity not supported by service monitoring query".into(),
        ))
    }
}

fn is_service_monitoring_entity(entity: &Entity) -> bool {
    matches!(
        entity,
        Entity::MonitoredServices
            | Entity::ServiceCheckInstances
            | Entity::ServiceGroups
            | Entity::ServiceGroupMemberships
            | Entity::ServiceAvailability
            | Entity::ServiceLevelIndicators
            | Entity::ServiceLevelObjectives
            | Entity::ServiceLevelObjectiveEvaluations
    )
}

fn entity_spec(entity: &Entity) -> Result<EntitySpec> {
    match entity {
        Entity::MonitoredServices => Ok(EntitySpec {
            table: "monitored_services",
            joins: "",
            payload_extra: "jsonb_build_object('name', t.display_name, 'uid', t.id::text)",
            default_order: "t.updated_at DESC NULLS LAST, t.display_name ASC",
            time_column: Some("t.updated_at"),
        }),
        Entity::ServiceCheckInstances => Ok(EntitySpec {
            table: "check_instances",
            joins: "LEFT JOIN monitored_services s ON s.id = t.monitored_service_id LEFT JOIN monitoring_bindings b ON b.id = t.monitoring_binding_id",
            payload_extra: "jsonb_strip_nulls(jsonb_build_object('service_key', s.service_key, 'service_name', s.display_name, 'service_kind', s.service_kind, 'service_status', s.status, 'service_group_id', b.service_group_id, 'binding_name', b.name, 'uid', t.id::text))",
            default_order: "t.updated_at DESC NULLS LAST, t.check_key ASC",
            time_column: Some("t.updated_at"),
        }),
        Entity::ServiceGroups => Ok(EntitySpec {
            table: "service_groups",
            joins: "",
            payload_extra: "jsonb_build_object('uid', t.id::text)",
            default_order: "t.updated_at DESC NULLS LAST, t.name ASC",
            time_column: Some("t.updated_at"),
        }),
        Entity::ServiceGroupMemberships => Ok(EntitySpec {
            table: "service_group_memberships",
            joins: "LEFT JOIN service_groups g ON g.id = t.service_group_id LEFT JOIN monitored_services s ON s.id = t.monitored_service_id",
            payload_extra: "jsonb_strip_nulls(jsonb_build_object('group_name', g.name, 'group_slug', g.slug, 'service_key', s.service_key, 'service_name', s.display_name, 'service_kind', s.service_kind, 'uid', t.id::text))",
            default_order: "t.updated_at DESC NULLS LAST, t.id ASC",
            time_column: Some("t.updated_at"),
        }),
        Entity::ServiceAvailability => Ok(EntitySpec {
            table: "latest_check_states",
            joins: "LEFT JOIN check_instances ci ON ci.id = t.check_instance_id LEFT JOIN monitored_services s ON s.id = t.monitored_service_id LEFT JOIN monitoring_bindings b ON b.id = t.monitoring_binding_id",
            payload_extra: "jsonb_strip_nulls(jsonb_build_object('check_key', ci.check_key, 'descriptor_id', ci.descriptor_id, 'capability_kind', ci.capability_kind, 'service_key', s.service_key, 'service_name', s.display_name, 'service_kind', s.service_kind, 'service_status', s.status, 'service_group_id', b.service_group_id, 'binding_name', b.name, 'uid', t.id::text))",
            default_order: "t.last_observed_at DESC NULLS LAST, t.updated_at DESC NULLS LAST",
            time_column: Some("t.last_observed_at"),
        }),
        Entity::ServiceLevelIndicators => Ok(EntitySpec {
            table: "service_level_indicators",
            joins: "",
            payload_extra: "jsonb_build_object('uid', t.id::text)",
            default_order: "t.updated_at DESC NULLS LAST, t.name ASC",
            time_column: Some("t.updated_at"),
        }),
        Entity::ServiceLevelObjectives => Ok(EntitySpec {
            table: "service_level_objectives",
            joins: "LEFT JOIN service_level_indicators sli ON sli.id = t.sli_id LEFT JOIN service_groups g ON g.id = t.service_group_id LEFT JOIN LATERAL (SELECT e.compliance_state, e.budget_remaining_basis_points, e.burn_rate_short, e.burn_rate_long, e.projected_exhaustion_at, e.severity, e.evaluated_at FROM service_level_objective_evaluations e WHERE e.slo_id = t.id ORDER BY e.evaluated_at DESC NULLS LAST LIMIT 1) latest ON TRUE",
            payload_extra: "jsonb_strip_nulls(jsonb_build_object('uid', t.id::text, 'sli_key', sli.sli_key, 'sli_name', sli.name, 'sli_type', sli.sli_type, 'service_group_name', g.name, 'service_group_slug', g.slug, 'compliance_state', COALESCE(latest.compliance_state, t.last_compliance_state), 'budget_remaining_basis_points', COALESCE(latest.budget_remaining_basis_points, t.last_budget_remaining_basis_points), 'burn_rate_short', latest.burn_rate_short, 'burn_rate_long', COALESCE(latest.burn_rate_long, t.last_burn_rate), 'projected_exhaustion_at', latest.projected_exhaustion_at, 'severity', latest.severity, 'evaluated_at', COALESCE(latest.evaluated_at, t.last_evaluated_at)))",
            default_order: "t.updated_at DESC NULLS LAST, t.name ASC",
            time_column: Some("t.updated_at"),
        }),
        Entity::ServiceLevelObjectiveEvaluations => Ok(EntitySpec {
            table: "service_level_objective_evaluations",
            joins: "LEFT JOIN service_level_objectives slo ON slo.id = t.slo_id LEFT JOIN service_level_indicators sli ON sli.id = slo.sli_id LEFT JOIN service_groups g ON g.id = slo.service_group_id",
            payload_extra: "jsonb_strip_nulls(jsonb_build_object('uid', t.id::text, 'slo_key', slo.slo_key, 'slo_name', slo.name, 'owner', slo.owner, 'sli_key', sli.sli_key, 'sli_type', sli.sli_type, 'service_group_id', slo.service_group_id, 'service_group_name', g.name, 'service_group_slug', g.slug))",
            default_order: "t.evaluated_at DESC NULLS LAST, t.updated_at DESC NULLS LAST",
            time_column: Some("t.evaluated_at"),
        }),
        _ => Err(ServiceError::InvalidRequest(
            "unsupported service monitoring entity".into(),
        )),
    }
}

fn build_rollup_sql(plan: &QueryPlan, rollup: &str) -> Result<(String, Vec<BindParam>)> {
    if matches!(plan.entity, Entity::ServiceLevelObjectiveEvaluations) {
        if rollup.eq_ignore_ascii_case("slo_error_budget")
            || rollup.eq_ignore_ascii_case("error_budget")
        {
            return build_slo_error_budget_rollup_sql(plan);
        }

        return Err(ServiceError::InvalidRequest(format!(
            "unsupported slo_evaluations rollup_stats type: '{rollup}' (supported: slo_error_budget)"
        )));
    }

    if !matches!(plan.entity, Entity::ServiceAvailability) {
        return Err(ServiceError::InvalidRequest(
            "service monitoring rollup_stats is supported for in:service_availability".into(),
        ));
    }

    if !rollup.eq_ignore_ascii_case("availability") {
        return Err(ServiceError::InvalidRequest(format!(
            "unsupported service_availability rollup_stats type: '{rollup}' (supported: availability)"
        )));
    }

    let spec = entity_spec(&plan.entity)?;
    let mut params = Vec::new();
    let where_sql = where_sql(plan, spec, &mut params)?;

    let sql = format!(
        "SELECT jsonb_build_object(
          'total', count(*),
          'ok', count(*) FILTER (WHERE t.status = 'ok'),
          'warning', count(*) FILTER (WHERE t.status = 'warning'),
          'critical', count(*) FILTER (WHERE t.status = 'critical'),
          'unknown', count(*) FILTER (WHERE t.status = 'unknown'),
          'available', count(*) FILTER (WHERE t.status IN ('ok', 'warning')),
          'unavailable', count(*) FILTER (WHERE t.status IN ('critical', 'unknown')),
          'availability_pct', CASE WHEN count(*) = 0 THEN 0.0 ELSE round((count(*) FILTER (WHERE t.status IN ('ok', 'warning'))::numeric / count(*)::numeric) * 100.0, 2)::float END
        ) AS payload
        FROM {table} t {joins}{where_sql}",
        table = spec.table,
        joins = spec.joins,
    );

    Ok((sql, params))
}

fn build_slo_error_budget_rollup_sql(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    let spec = entity_spec(&plan.entity)?;
    let mut params = Vec::new();
    let where_sql = where_sql(plan, spec, &mut params)?;

    let sql = format!(
        "SELECT jsonb_build_object(
          'total', count(*),
          'compliant', count(*) FILTER (WHERE t.compliance_state = 'compliant'),
          'at_risk', count(*) FILTER (WHERE t.compliance_state = 'at_risk'),
          'noncompliant', count(*) FILTER (WHERE t.compliance_state = 'noncompliant'),
          'critical', count(*) FILTER (WHERE t.severity = 'critical'),
          'warning', count(*) FILTER (WHERE t.severity = 'warning'),
          'error_budget_total', COALESCE(sum(t.error_budget_total), 0),
          'error_budget_consumed', COALESCE(sum(t.error_budget_consumed), 0),
          'error_budget_remaining', COALESCE(sum(t.error_budget_remaining), 0),
          'avg_budget_remaining_basis_points', COALESCE(round(avg(t.budget_remaining_basis_points)::numeric, 2)::float, 0.0),
          'max_burn_rate_short', COALESCE(max(t.burn_rate_short), 0),
          'max_burn_rate_long', COALESCE(max(t.burn_rate_long), 0),
          'next_projected_exhaustion_at', min(t.projected_exhaustion_at)
        ) AS payload
        FROM {table} t {joins}{where_sql}",
        table = spec.table,
        joins = spec.joins,
    );

    Ok((sql, params))
}

fn where_sql(plan: &QueryPlan, spec: EntitySpec, params: &mut Vec<BindParam>) -> Result<String> {
    let mut predicates = Vec::new();

    if let (Some(TimeRange { start, end }), Some(column)) = (&plan.time_range, spec.time_column) {
        let start_ref = push_param(params, BindParam::timestamptz(*start));
        let end_ref = push_param(params, BindParam::timestamptz(*end));
        predicates.push(format!("{column} >= {start_ref} AND {column} <= {end_ref}"));
    }

    for filter in &plan.filters {
        predicates.push(filter_predicate(&plan.entity, filter, params)?);
    }

    if predicates.is_empty() {
        Ok(String::new())
    } else {
        Ok(format!(" WHERE {}", predicates.join(" AND ")))
    }
}

fn filter_predicate(
    entity: &Entity,
    filter: &Filter,
    params: &mut Vec<BindParam>,
) -> Result<String> {
    let field = filter.field.trim().to_ascii_lowercase();

    if let Some(tag_key) = field
        .strip_prefix("tag.")
        .or_else(|| field.strip_prefix("tags."))
    {
        return json_text_filter(filter, "t.tags", tag_key, params);
    }

    match field.as_str() {
        "id" | "uid" => text_filter(filter, "t.id::text", params),
        "status" => match entity {
            Entity::MonitoredServices
            | Entity::ServiceCheckInstances
            | Entity::ServiceGroups
            | Entity::ServiceAvailability
            | Entity::ServiceLevelIndicators
            | Entity::ServiceLevelObjectives => text_filter(filter, "t.status", params),
            _ => unsupported_field(entity, &field),
        },
        "compliance" | "compliance_state" => match entity {
            Entity::ServiceLevelObjectives => text_filter(
                filter,
                "COALESCE(latest.compliance_state, t.last_compliance_state)",
                params,
            ),
            Entity::ServiceLevelObjectiveEvaluations => {
                text_filter(filter, "t.compliance_state", params)
            }
            _ => unsupported_field(entity, &field),
        },
        "severity" => match entity {
            Entity::ServiceLevelObjectiveEvaluations => text_filter(filter, "t.severity", params),
            Entity::ServiceLevelObjectives => text_filter(filter, "latest.severity", params),
            _ => unsupported_field(entity, &field),
        },
        "source" => text_filter(filter, "t.source", params),
        "created_at" | "inserted_at" => timestamp_filter(filter, "t.inserted_at", params),
        "updated_at" => timestamp_filter(filter, "t.updated_at", params),
        "service_key" => match entity {
            Entity::MonitoredServices => text_filter(filter, "t.service_key", params),
            Entity::ServiceCheckInstances
            | Entity::ServiceGroupMemberships
            | Entity::ServiceAvailability => text_filter(filter, "s.service_key", params),
            _ => unsupported_field(entity, &field),
        },
        "name" | "display_name" | "service_name" => match entity {
            Entity::MonitoredServices => text_filter(filter, "t.display_name", params),
            Entity::ServiceGroups => text_filter(filter, "t.name", params),
            Entity::ServiceCheckInstances
            | Entity::ServiceGroupMemberships
            | Entity::ServiceAvailability => text_filter(filter, "s.display_name", params),
            _ => unsupported_field(entity, &field),
        },
        "slug" => match entity {
            Entity::ServiceGroups => text_filter(filter, "t.slug", params),
            Entity::ServiceGroupMemberships => text_filter(filter, "g.slug", params),
            _ => unsupported_field(entity, &field),
        },
        "service_kind" | "kind" => match entity {
            Entity::MonitoredServices => text_filter(filter, "t.service_kind", params),
            Entity::ServiceCheckInstances
            | Entity::ServiceGroupMemberships
            | Entity::ServiceAvailability => text_filter(filter, "s.service_kind", params),
            _ => unsupported_field(entity, &field),
        },
        "protocol" => match entity {
            Entity::MonitoredServices => text_filter(filter, "t.protocol", params),
            _ => unsupported_field(entity, &field),
        },
        "host" => match entity {
            Entity::MonitoredServices => text_filter(filter, "t.host", params),
            _ => unsupported_field(entity, &field),
        },
        "url" | "endpoint_url" => match entity {
            Entity::MonitoredServices => text_filter(filter, "t.endpoint_url", params),
            _ => unsupported_field(entity, &field),
        },
        "port" => match entity {
            Entity::MonitoredServices => int_filter(filter, "t.port", params),
            _ => unsupported_field(entity, &field),
        },
        "device_uid" | "device_id" => match entity {
            Entity::MonitoredServices
            | Entity::ServiceCheckInstances
            | Entity::ServiceAvailability => text_filter(filter, "t.device_uid", params),
            _ => unsupported_field(entity, &field),
        },
        "check_key" => match entity {
            Entity::ServiceCheckInstances => text_filter(filter, "t.check_key", params),
            Entity::ServiceAvailability => text_filter(filter, "ci.check_key", params),
            _ => unsupported_field(entity, &field),
        },
        "descriptor_id" | "capability" => match entity {
            Entity::ServiceCheckInstances => text_filter(filter, "t.descriptor_id", params),
            Entity::ServiceAvailability => text_filter(filter, "ci.descriptor_id", params),
            _ => unsupported_field(entity, &field),
        },
        "capability_kind" => match entity {
            Entity::ServiceCheckInstances => text_filter(filter, "t.capability_kind", params),
            Entity::ServiceAvailability => text_filter(filter, "ci.capability_kind", params),
            _ => unsupported_field(entity, &field),
        },
        "agent_id" => match entity {
            Entity::ServiceCheckInstances | Entity::ServiceAvailability => {
                text_filter(filter, "t.agent_id", params)
            }
            _ => unsupported_field(entity, &field),
        },
        "vantage_id" => match entity {
            Entity::ServiceCheckInstances | Entity::ServiceAvailability => {
                text_filter(filter, "t.vantage_id", params)
            }
            _ => unsupported_field(entity, &field),
        },
        "service_group_id" | "group_id" => match entity {
            Entity::ServiceGroups => text_filter(filter, "t.id::text", params),
            Entity::ServiceGroupMemberships => {
                text_filter(filter, "t.service_group_id::text", params)
            }
            Entity::ServiceCheckInstances | Entity::ServiceAvailability => {
                text_filter(filter, "b.service_group_id::text", params)
            }
            Entity::ServiceLevelObjectives => text_filter(filter, "t.service_group_id::text", params),
            Entity::ServiceLevelObjectiveEvaluations => {
                text_filter(filter, "slo.service_group_id::text", params)
            }
            _ => unsupported_field(entity, &field),
        },
        "monitored_service_id" | "service_id" => match entity {
            Entity::MonitoredServices => text_filter(filter, "t.id::text", params),
            Entity::ServiceCheckInstances | Entity::ServiceAvailability => {
                text_filter(filter, "t.monitored_service_id::text", params)
            }
            Entity::ServiceGroupMemberships => {
                text_filter(filter, "t.monitored_service_id::text", params)
            }
            _ => unsupported_field(entity, &field),
        },
        "selection_mode" => match entity {
            Entity::ServiceGroups => text_filter(filter, "t.selection_mode", params),
            _ => unsupported_field(entity, &field),
        },
        "last_observed_at" | "observed_at" => match entity {
            Entity::ServiceAvailability => timestamp_filter(filter, "t.last_observed_at", params),
            _ => unsupported_field(entity, &field),
        },
        "response_time_ms" => match entity {
            Entity::ServiceAvailability => int_filter(filter, "t.response_time_ms", params),
            _ => unsupported_field(entity, &field),
        },
        "sli_key" => match entity {
            Entity::ServiceLevelIndicators => text_filter(filter, "t.sli_key", params),
            Entity::ServiceLevelObjectives | Entity::ServiceLevelObjectiveEvaluations => {
                text_filter(filter, "sli.sli_key", params)
            }
            _ => unsupported_field(entity, &field),
        },
        "slo_key" => match entity {
            Entity::ServiceLevelObjectives => text_filter(filter, "t.slo_key", params),
            Entity::ServiceLevelObjectiveEvaluations => text_filter(filter, "slo.slo_key", params),
            _ => unsupported_field(entity, &field),
        },
        "sli_type" => match entity {
            Entity::ServiceLevelIndicators => text_filter(filter, "t.sli_type", params),
            Entity::ServiceLevelObjectives | Entity::ServiceLevelObjectiveEvaluations => {
                text_filter(filter, "sli.sli_type", params)
            }
            _ => unsupported_field(entity, &field),
        },
        "slo_kind" => match entity {
            Entity::ServiceLevelObjectives => text_filter(filter, "t.slo_kind", params),
            Entity::ServiceLevelObjectiveEvaluations => text_filter(filter, "slo.slo_kind", params),
            _ => unsupported_field(entity, &field),
        },
        "owner" => match entity {
            Entity::ServiceLevelObjectives => text_filter(filter, "t.owner", params),
            Entity::ServiceLevelObjectiveEvaluations => text_filter(filter, "slo.owner", params),
            _ => unsupported_field(entity, &field),
        },
        "goal_basis_points" | "goal" => match entity {
            Entity::ServiceLevelObjectives | Entity::ServiceLevelObjectiveEvaluations => {
                int_filter(filter, "t.goal_basis_points", params)
            }
            _ => unsupported_field(entity, &field),
        },
        "budget_remaining_basis_points" | "budget_remaining" => match entity {
            Entity::ServiceLevelObjectives => int_filter(
                filter,
                "COALESCE(latest.budget_remaining_basis_points, t.last_budget_remaining_basis_points)",
                params,
            ),
            Entity::ServiceLevelObjectiveEvaluations => {
                int_filter(filter, "t.budget_remaining_basis_points", params)
            }
            _ => unsupported_field(entity, &field),
        },
        "burn_rate" | "burn_rate_short" => match entity {
            Entity::ServiceLevelObjectives => {
                decimal_filter(filter, "COALESCE(latest.burn_rate_short, t.last_burn_rate)", params)
            }
            Entity::ServiceLevelObjectiveEvaluations => {
                decimal_filter(filter, "t.burn_rate_short", params)
            }
            _ => unsupported_field(entity, &field),
        },
        "burn_rate_long" => match entity {
            Entity::ServiceLevelObjectives => {
                decimal_filter(filter, "COALESCE(latest.burn_rate_long, t.last_burn_rate)", params)
            }
            Entity::ServiceLevelObjectiveEvaluations => {
                decimal_filter(filter, "t.burn_rate_long", params)
            }
            _ => unsupported_field(entity, &field),
        },
        "evaluated_at" => match entity {
            Entity::ServiceLevelObjectives => timestamp_filter(
                filter,
                "COALESCE(latest.evaluated_at, t.last_evaluated_at)",
                params,
            ),
            Entity::ServiceLevelObjectiveEvaluations => timestamp_filter(filter, "t.evaluated_at", params),
            _ => unsupported_field(entity, &field),
        },
        other => unsupported_field(entity, other),
    }
}

fn text_filter(filter: &Filter, column: &str, params: &mut Vec<BindParam>) -> Result<String> {
    match filter.op {
        FilterOp::Eq => {
            let placeholder = push_param(params, BindParam::Text(filter.value.as_scalar()?.into()));
            Ok(format!("{column} = {placeholder}"))
        }
        FilterOp::NotEq => {
            let placeholder = push_param(params, BindParam::Text(filter.value.as_scalar()?.into()));
            Ok(format!("{column} <> {placeholder}"))
        }
        FilterOp::Like => {
            let placeholder = push_param(params, BindParam::Text(filter.value.as_scalar()?.into()));
            Ok(format!("{column} ILIKE {placeholder}"))
        }
        FilterOp::NotLike => {
            let placeholder = push_param(params, BindParam::Text(filter.value.as_scalar()?.into()));
            Ok(format!("{column} NOT ILIKE {placeholder}"))
        }
        FilterOp::In => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                Ok("TRUE".into())
            } else {
                let placeholder = push_param(params, BindParam::TextArray(values));
                Ok(format!("{column} = ANY({placeholder})"))
            }
        }
        FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                Ok("TRUE".into())
            } else {
                let placeholder = push_param(params, BindParam::TextArray(values));
                Ok(format!("{column} <> ALL({placeholder})"))
            }
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for text filter: {:?}",
            filter.op
        ))),
    }
}

fn json_text_filter(
    filter: &Filter,
    json_column: &str,
    key: &str,
    params: &mut Vec<BindParam>,
) -> Result<String> {
    let key = safe_json_key(key)?;
    text_filter(filter, &format!("{json_column} ->> '{key}'"), params)
}

fn int_filter(filter: &Filter, column: &str, params: &mut Vec<BindParam>) -> Result<String> {
    match filter.op {
        FilterOp::Eq
        | FilterOp::NotEq
        | FilterOp::Gt
        | FilterOp::Gte
        | FilterOp::Lt
        | FilterOp::Lte => {
            let value = parse_i64(filter.value.as_scalar()?)?;
            let placeholder = push_param(params, BindParam::Int(value));
            Ok(format!(
                "{column} {} {placeholder}",
                numeric_operator(filter.op.clone())?
            ))
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = parse_i64_list(&filter.value)?;
            if values.is_empty() {
                Ok("TRUE".into())
            } else {
                let placeholder = push_param(params, BindParam::IntArray(values));
                let op = if matches!(filter.op, FilterOp::In) {
                    "= ANY"
                } else {
                    "<> ALL"
                };
                Ok(format!("{column} {op}({placeholder})"))
            }
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for integer filter: {:?}",
            filter.op
        ))),
    }
}

fn decimal_filter(filter: &Filter, column: &str, params: &mut Vec<BindParam>) -> Result<String> {
    match filter.op {
        FilterOp::Eq
        | FilterOp::NotEq
        | FilterOp::Gt
        | FilterOp::Gte
        | FilterOp::Lt
        | FilterOp::Lte => {
            let value = parse_f64(filter.value.as_scalar()?)?;
            let placeholder = push_param(params, BindParam::Float(value));
            Ok(format!(
                "{column} {} {placeholder}",
                numeric_operator(filter.op.clone())?
            ))
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for decimal filter: {:?}",
            filter.op
        ))),
    }
}

fn timestamp_filter(filter: &Filter, column: &str, params: &mut Vec<BindParam>) -> Result<String> {
    let value = filter.value.as_scalar()?.to_string();
    let placeholder = push_param(params, BindParam::Timestamptz(value));

    match filter.op {
        FilterOp::Eq
        | FilterOp::NotEq
        | FilterOp::Gt
        | FilterOp::Gte
        | FilterOp::Lt
        | FilterOp::Lte => Ok(format!(
            "{column} {} {placeholder}",
            numeric_operator(filter.op.clone())?
        )),
        _ => Err(ServiceError::InvalidRequest(
            "timestamp filters only support scalar comparison".into(),
        )),
    }
}

fn numeric_operator(op: FilterOp) -> Result<&'static str> {
    match op {
        FilterOp::Eq => Ok("="),
        FilterOp::NotEq => Ok("<>"),
        FilterOp::Gt => Ok(">"),
        FilterOp::Gte => Ok(">="),
        FilterOp::Lt => Ok("<"),
        FilterOp::Lte => Ok("<="),
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported comparison operator: {op:?}"
        ))),
    }
}

fn order_sql(entity: &Entity, order: &[OrderClause], fallback: &str) -> Result<String> {
    if order.is_empty() {
        return Ok(format!("ORDER BY {fallback}"));
    }

    let mut parts = Vec::with_capacity(order.len());
    for clause in order {
        let column = order_column(entity, &clause.field)?;
        let direction = match clause.direction {
            OrderDirection::Asc => "ASC",
            OrderDirection::Desc => "DESC",
        };
        parts.push(format!("{column} {direction} NULLS LAST"));
    }

    Ok(format!("ORDER BY {}", parts.join(", ")))
}

fn order_column(entity: &Entity, field: &str) -> Result<&'static str> {
    let normalized = field.trim().to_ascii_lowercase();

    match normalized.as_str() {
        "id" | "uid" => Ok("t.id"),
        "status" => Ok("t.status"),
        "created_at" | "inserted_at" => Ok("t.inserted_at"),
        "updated_at" => Ok("t.updated_at"),
        "name" | "display_name" | "service_name" => match entity {
            Entity::MonitoredServices => Ok("t.display_name"),
            Entity::ServiceGroups => Ok("t.name"),
            Entity::ServiceCheckInstances
            | Entity::ServiceGroupMemberships
            | Entity::ServiceAvailability => Ok("s.display_name"),
            Entity::ServiceLevelIndicators | Entity::ServiceLevelObjectives => Ok("t.name"),
            Entity::ServiceLevelObjectiveEvaluations => Ok("slo.name"),
            _ => unsupported_order_field(entity, &normalized),
        },
        "service_kind" | "kind" => match entity {
            Entity::MonitoredServices => Ok("t.service_kind"),
            Entity::ServiceCheckInstances
            | Entity::ServiceGroupMemberships
            | Entity::ServiceAvailability => Ok("s.service_kind"),
            _ => unsupported_order_field(entity, &normalized),
        },
        "check_key" => match entity {
            Entity::ServiceCheckInstances => Ok("t.check_key"),
            Entity::ServiceAvailability => Ok("ci.check_key"),
            _ => unsupported_order_field(entity, &normalized),
        },
        "descriptor_id" | "capability" => match entity {
            Entity::ServiceCheckInstances => Ok("t.descriptor_id"),
            Entity::ServiceAvailability => Ok("ci.descriptor_id"),
            _ => unsupported_order_field(entity, &normalized),
        },
        "slug" => match entity {
            Entity::ServiceGroups => Ok("t.slug"),
            Entity::ServiceGroupMemberships => Ok("g.slug"),
            _ => unsupported_order_field(entity, &normalized),
        },
        "last_observed_at" | "observed_at" => match entity {
            Entity::ServiceAvailability => Ok("t.last_observed_at"),
            _ => unsupported_order_field(entity, &normalized),
        },
        "response_time_ms" => match entity {
            Entity::ServiceAvailability => Ok("t.response_time_ms"),
            _ => unsupported_order_field(entity, &normalized),
        },
        "evaluated_at" => match entity {
            Entity::ServiceLevelObjectives => Ok("COALESCE(latest.evaluated_at, t.last_evaluated_at)"),
            Entity::ServiceLevelObjectiveEvaluations => Ok("t.evaluated_at"),
            _ => unsupported_order_field(entity, &normalized),
        },
        "compliance" | "compliance_state" => match entity {
            Entity::ServiceLevelObjectives => {
                Ok("COALESCE(latest.compliance_state, t.last_compliance_state)")
            }
            Entity::ServiceLevelObjectiveEvaluations => Ok("t.compliance_state"),
            _ => unsupported_order_field(entity, &normalized),
        },
        "severity" => match entity {
            Entity::ServiceLevelObjectives => Ok("latest.severity"),
            Entity::ServiceLevelObjectiveEvaluations => Ok("t.severity"),
            _ => unsupported_order_field(entity, &normalized),
        },
        "budget_remaining_basis_points" | "budget_remaining" => match entity {
            Entity::ServiceLevelObjectives => Ok(
                "COALESCE(latest.budget_remaining_basis_points, t.last_budget_remaining_basis_points)",
            ),
            Entity::ServiceLevelObjectiveEvaluations => Ok("t.budget_remaining_basis_points"),
            _ => unsupported_order_field(entity, &normalized),
        },
        other => unsupported_order_field(entity, other),
    }
}

fn unsupported_field<T>(entity: &Entity, field: &str) -> Result<T> {
    Err(ServiceError::InvalidRequest(format!(
        "unsupported filter field for {}: '{field}'",
        entity_name(entity)
    )))
}

fn unsupported_order_field<T>(entity: &Entity, field: &str) -> Result<T> {
    Err(ServiceError::InvalidRequest(format!(
        "unsupported sort field for {}: '{field}'",
        entity_name(entity)
    )))
}

fn entity_name(entity: &Entity) -> &'static str {
    match entity {
        Entity::MonitoredServices => "monitored_services",
        Entity::ServiceCheckInstances => "service_checks",
        Entity::ServiceGroups => "service_groups",
        Entity::ServiceGroupMemberships => "service_group_memberships",
        Entity::ServiceAvailability => "service_availability",
        Entity::ServiceLevelIndicators => "slis",
        Entity::ServiceLevelObjectives => "slos",
        Entity::ServiceLevelObjectiveEvaluations => "slo_evaluations",
        _ => "service_monitoring",
    }
}

fn safe_json_key(key: &str) -> Result<String> {
    let trimmed = key.trim();
    if trimmed.is_empty()
        || trimmed
            .chars()
            .any(|ch| !ch.is_ascii_alphanumeric() && ch != '_' && ch != '-' && ch != '.')
    {
        return Err(ServiceError::InvalidRequest(format!(
            "invalid tag filter key '{key}'"
        )));
    }

    Ok(trimmed.replace('\'', ""))
}

fn push_param(params: &mut Vec<BindParam>, param: BindParam) -> String {
    params.push(param);
    format!("${}", params.len())
}

fn parse_i64(raw: &str) -> Result<i64> {
    raw.parse::<i64>()
        .map_err(|_| ServiceError::InvalidRequest(format!("expected integer value, got '{raw}'")))
}

fn parse_f64(raw: &str) -> Result<f64> {
    raw.parse::<f64>()
        .map_err(|_| ServiceError::InvalidRequest(format!("expected decimal value, got '{raw}'")))
}

fn parse_i64_list(value: &FilterValue) -> Result<Vec<i64>> {
    value
        .as_list()?
        .iter()
        .map(|item| parse_i64(item))
        .collect()
}

fn bind_param<'a>(
    query: BoxedSqlQuery<'a, Pg, SqlQuery>,
    param: BindParam,
) -> Result<BoxedSqlQuery<'a, Pg, SqlQuery>> {
    match param {
        BindParam::Text(value) => Ok(query.bind::<Text, _>(value)),
        BindParam::TextArray(values) => Ok(query.bind::<Array<Text>, _>(values)),
        BindParam::IntArray(values) => Ok(query.bind::<Array<BigInt>, _>(values)),
        BindParam::Bool(value) => Ok(query.bind::<Bool, _>(value)),
        BindParam::Int(value) => Ok(query.bind::<BigInt, _>(value)),
        BindParam::Float(value) => Ok(query.bind::<Float8, _>(value)),
        BindParam::Timestamptz(value) => {
            let timestamp = chrono::DateTime::parse_from_rfc3339(&value)
                .map(|dt| dt.with_timezone(&chrono::Utc))
                .map_err(|err| {
                    ServiceError::InvalidRequest(format!(
                        "invalid timestamp filter value {value:?}: {err}"
                    ))
                })?;
            Ok(query.bind::<Timestamptz, _>(timestamp))
        }
        BindParam::Uuid(value) => Ok(query.bind::<diesel::sql_types::Uuid, _>(value)),
    }
}
