use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::EventRow,
    parser::{Entity, Filter, OrderClause, OrderDirection},
    schema::ocsf_events::dsl::{
        activity_id as col_activity_id, activity_name as col_activity_name,
        category_uid as col_category_uid, class_uid as col_class_uid, id as col_id,
        log_level as col_log_level, log_name as col_log_name, log_provider as col_log_provider,
        message as col_message, ocsf_events, severity as col_severity,
        severity_id as col_severity_id, span_id as col_span_id, status as col_status,
        status_code as col_status_code, status_detail as col_status_detail,
        status_id as col_status_id, time as col_time, trace_id as col_trace_id,
        type_uid as col_type_uid,
    },
    time::TimeRange,
};
use diesel::dsl::sql;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel::sql_types::Bool;
use diesel::PgTextExpressionMethods;
use diesel_async::{AsyncPgConnection, RunQueryDsl};

type EventsTable = crate::schema::ocsf_events::table;
type EventsFromClause = FromClause<EventsTable>;
type EventsQuery<'a> =
    BoxedSelectStatement<'a, <EventsTable as AsQuery>::SqlType, EventsFromClause, Pg>;

const EVENT_DEVICE_IDENTITY_KEYS: &[&str] = &[
    "service_radar.device_uid",
    "service_radar.device.uid",
    "service_radar.device_id",
    "serviceradar.device_id",
    "serviceradar.device.uid",
    "device_id",
    "device_uid",
    "source_device_uid",
    "target_device_uid",
    "uid",
    "id",
];
const EVENT_DEVICE_HOST_KEYS: &[&str] = &[
    "service_radar.device_hostname",
    "service_radar.source_instance",
    "service_radar.node_name",
    "service_radar.device_ip",
    "service_radar.source_ip",
    "hostname",
    "host",
    "host.name",
    "k8s.node.name",
    "source.host",
    "source.hostname",
    "source.ip",
    "server_identity",
    "ip",
];
const DEVICE_INVENTORY_ALIAS_EXPRESSIONS: &[&str] = &[
    "d.uid",
    "d.uid_alt",
    "d.hostname",
    "d.name",
    "d.ip",
    "d.agent_id",
    "d.metadata->>'sys_name'",
    "d.metadata->>'snmp_name'",
    "d.metadata->>'controller_name'",
    "d.metadata->>'unifi_device_id'",
    "d.metadata->>'device_id'",
];

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    let rows: Vec<EventRow> = query
        .select(EventRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<EventRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(EventRow::into_json).collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;
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
        Entity::Events | Entity::SecurityFindings | Entity::ScanActivity | Entity::DnsActivity => {
            Ok(())
        }
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by events query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<EventsQuery<'static>> {
    let mut query = ocsf_events.into_boxed::<Pg>();

    query = match plan.entity {
        Entity::SecurityFindings => {
            query.filter(sql::<Bool>("\"ocsf_events\".\"category_uid\" = 2"))
        }
        Entity::ScanActivity => query.filter(sql::<Bool>(
            "\"ocsf_events\".\"class_uid\" = 6007 AND \"ocsf_events\".\"category_uid\" = 6",
        )),
        Entity::DnsActivity => query.filter(sql::<Bool>(
            "\"ocsf_events\".\"class_uid\" = 4003 AND \"ocsf_events\".\"category_uid\" = 4",
        )),
        _ => query,
    };

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_time.ge(*start).and(col_time.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

fn apply_filter<'a>(mut query: EventsQuery<'a>, filter: &Filter) -> Result<EventsQuery<'a>> {
    match filter.field.as_str() {
        "id" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_id,
                parse_uuid(filter.value.as_scalar()?)?,
                "id only supports equality comparisons"
            )?;
        }
        "class_uid" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_class_uid,
                parse_i32(filter.value.as_scalar()?)?,
                "class_uid only supports equality comparisons"
            )?;
        }
        "category_uid" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_category_uid,
                parse_i32(filter.value.as_scalar()?)?,
                "category_uid only supports equality comparisons"
            )?;
        }
        "type_uid" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_type_uid,
                parse_i32(filter.value.as_scalar()?)?,
                "type_uid only supports equality comparisons"
            )?;
        }
        "activity_id" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_activity_id,
                parse_i32(filter.value.as_scalar()?)?,
                "activity_id only supports equality comparisons"
            )?;
        }
        "activity_name" => {
            query = apply_text_filter!(query, filter, col_activity_name)?;
        }
        "severity_id" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_severity_id,
                parse_i32(filter.value.as_scalar()?)?,
                "severity_id only supports equality comparisons"
            )?;
        }
        "severity" => {
            query = apply_text_filter!(query, filter, col_severity)?;
        }
        "message" | "short_message" => {
            query = apply_text_filter!(query, filter, col_message)?;
        }
        "log_name" => {
            query = apply_text_filter!(query, filter, col_log_name)?;
        }
        "log_provider" => {
            query = apply_text_filter!(query, filter, col_log_provider)?;
        }
        "log_level" => {
            query = apply_text_filter!(query, filter, col_log_level)?;
        }
        "status_id" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_status_id,
                parse_i32(filter.value.as_scalar()?)?,
                "status_id only supports equality comparisons"
            )?;
        }
        "status" => {
            query = apply_text_filter!(query, filter, col_status)?;
        }
        "status_code" => {
            query = apply_text_filter!(query, filter, col_status_code)?;
        }
        "status_detail" => {
            query = apply_text_filter!(query, filter, col_status_detail)?;
        }
        "source" | "source_type" | "addon_id" => {
            query = apply_metadata_source_filter(query, filter)?;
        }
        "trace_id" => {
            query = apply_text_filter!(query, filter, col_trace_id)?;
        }
        "span_id" => {
            query = apply_text_filter!(query, filter, col_span_id)?;
        }
        "device_id" | "uid" | "source_device_uid" => {
            query = apply_metadata_identity_filter(query, filter, EVENT_DEVICE_IDENTITY_KEYS)?;
        }
        "finding_uid" => {
            query = apply_finding_uid_filter(query, filter)?;
        }
        "purl" | "purl_canonical" | "canonical_purl" => {
            query = apply_json_coordinate_filter(
                query,
                filter,
                &["purl_canonical", "purlCanonical", "canonical_purl", "purl"],
            )?;
        }
        "cpe" | "cpes" => {
            query = apply_json_coordinate_filter(query, filter, &["cpe", "cpes", "primary_cpe"])?;
        }
        "cve" | "vulnerability_id" => {
            query = apply_json_coordinate_filter(
                query,
                filter,
                &["cve", "cve_id", "vulnerability_id", "vulnerabilityId"],
            )?;
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for events: '{other}'"
            )));
        }
    }

    Ok(query)
}

fn apply_metadata_source_filter<'a>(
    query: EventsQuery<'a>,
    filter: &Filter,
) -> Result<EventsQuery<'a>> {
    let negate = matches!(
        filter.op,
        crate::parser::FilterOp::NotEq | crate::parser::FilterOp::NotIn
    );

    let values = match filter.op {
        crate::parser::FilterOp::Eq | crate::parser::FilterOp::NotEq => {
            vec![filter.value.as_scalar()?.to_string()]
        }
        crate::parser::FilterOp::In | crate::parser::FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(query);
            }
            values
        }
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "{} filter only supports equality and IN/NOT IN comparisons",
                filter.field
            )))
        }
    };

    let mut clauses = Vec::new();

    for value in values {
        let literal = sql_string_literal(&value);

        clauses.push(format!(
            "\"ocsf_events\".\"log_provider\" = {literal} OR \
             \"ocsf_events\".\"log_name\" = {literal} OR \
             metadata #>> '{{service_radar,source_type}}' = {literal} OR \
             metadata #>> '{{service_radar,addon_id}}' = {literal} OR \
             metadata #>> '{{serviceradar,source_type}}' = {literal} OR \
             metadata #>> '{{serviceradar,addon_id}}' = {literal} OR \
             metadata ->> 'source' = {literal} OR \
             unmapped ->> 'source_type' = {literal} OR \
             unmapped ->> 'addon_id' = {literal}"
        ));
    }

    if clauses.is_empty() {
        return Ok(query);
    }

    let clause = clauses
        .into_iter()
        .map(|clause| format!("({clause})"))
        .collect::<Vec<_>>()
        .join(" OR ");
    let sql_clause = if negate {
        format!("NOT ({clause})")
    } else {
        format!("({clause})")
    };

    Ok(query.filter(sql::<Bool>(&sql_clause)))
}

fn apply_metadata_identity_filter<'a>(
    query: EventsQuery<'a>,
    filter: &Filter,
    keys: &[&str],
) -> Result<EventsQuery<'a>> {
    let negate = matches!(
        filter.op,
        crate::parser::FilterOp::NotEq | crate::parser::FilterOp::NotIn
    );

    let values = match filter.op {
        crate::parser::FilterOp::Eq | crate::parser::FilterOp::NotEq => {
            vec![filter.value.as_scalar()?.to_string()]
        }
        crate::parser::FilterOp::In | crate::parser::FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(query);
            }
            values
        }
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "{} filter only supports equality and IN/NOT IN comparisons",
                filter.field
            )))
        }
    };

    let mut clauses = Vec::new();

    for value in values {
        for key in keys {
            let key_pattern = escape_like_fragment(key);
            let value_pattern = escape_like_fragment(&value);
            let pattern = sql_string_literal(&format!("%\"{key_pattern}\"%\"{value_pattern}\"%"));

            clauses.push(format!(
                "(device::text ILIKE {pattern} ESCAPE '\\' OR \
                  metadata::text ILIKE {pattern} ESCAPE '\\' OR \
                  unmapped::text ILIKE {pattern} ESCAPE '\\' OR \
                  observables::text ILIKE {pattern} ESCAPE '\\')"
            ));
        }

        if keys == EVENT_DEVICE_IDENTITY_KEYS {
            clauses.push(device_inventory_identity_clause(&value));
        }
    }

    if clauses.is_empty() {
        return Ok(query);
    }

    let clause = clauses.join(" OR ");
    let sql_clause = if negate {
        format!("NOT ({clause})")
    } else {
        format!("({clause})")
    };

    Ok(query.filter(sql::<Bool>(&sql_clause)))
}

fn apply_finding_uid_filter<'a>(
    query: EventsQuery<'a>,
    filter: &Filter,
) -> Result<EventsQuery<'a>> {
    let negate = matches!(
        filter.op,
        crate::parser::FilterOp::NotEq | crate::parser::FilterOp::NotIn
    );

    let values = match filter.op {
        crate::parser::FilterOp::Eq | crate::parser::FilterOp::NotEq => {
            vec![filter.value.as_scalar()?.to_string()]
        }
        crate::parser::FilterOp::In | crate::parser::FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(query);
            }
            values
        }
        _ => {
            return Err(ServiceError::InvalidRequest(
                "finding_uid filter only supports equality and IN/NOT IN comparisons".into(),
            ))
        }
    };

    let clauses = values
        .into_iter()
        .map(|value| {
            let literal = sql_string_literal(&value);

            format!(
                "metadata #>> '{{finding_info,uid}}' = {literal} OR \
                 metadata #>> '{{security_signal,finding_uid}}' = {literal}"
            )
        })
        .map(|clause| format!("({clause})"))
        .collect::<Vec<_>>();

    if clauses.is_empty() {
        return Ok(query);
    }

    let clause = clauses.join(" OR ");
    let sql_clause = if negate {
        format!("NOT ({clause})")
    } else {
        format!("({clause})")
    };

    Ok(query.filter(sql::<Bool>(&sql_clause)))
}

fn device_inventory_identity_clause(value: &str) -> String {
    let device_value = sql_string_literal(value);
    let alias_values = DEVICE_INVENTORY_ALIAS_EXPRESSIONS
        .iter()
        .map(|expr| format!("({expr})"))
        .collect::<Vec<_>>()
        .join(", ");

    format!(
        "EXISTS (\
           SELECT 1 \
           FROM platform.ocsf_devices AS d \
           CROSS JOIN LATERAL (\
             SELECT DISTINCT NULLIF(BTRIM(alias_value), '') AS alias_value \
             FROM (VALUES {alias_values}) AS aliases(alias_value)\
           ) AS device_alias \
           WHERE (d.uid = {device_value} OR d.uid_alt = {device_value}) \
             AND device_alias.alias_value IS NOT NULL \
             AND ({})\
         )",
        device_alias_event_match_clause("device_alias.alias_value")
    )
}

fn device_alias_event_match_clause(alias_expr: &str) -> String {
    let escaped_alias = format!(
        "replace(replace(replace({alias_expr}, E'\\\\', E'\\\\\\\\'), '%', E'\\\\%'), '_', E'\\\\_')"
    );

    let mut clauses = Vec::new();

    for key in EVENT_DEVICE_HOST_KEYS
        .iter()
        .chain(EVENT_DEVICE_IDENTITY_KEYS.iter())
    {
        let key_pattern = escape_like_fragment(key);

        for column in [
            "device::text",
            "metadata::text",
            "unmapped::text",
            "observables::text",
            "src_endpoint::text",
            "dst_endpoint::text",
        ] {
            clauses.push(format!(
                "{column} ILIKE ('%\"{key_pattern}\"%\"' || {escaped_alias} || '\"%') ESCAPE '\\'"
            ));
            clauses.push(format!(
                "{column} ILIKE ('%{key_pattern}=' || {escaped_alias} || '%') ESCAPE '\\'"
            ));
        }
    }

    clauses.join(" OR ")
}

fn apply_json_coordinate_filter<'a>(
    query: EventsQuery<'a>,
    filter: &Filter,
    keys: &[&str],
) -> Result<EventsQuery<'a>> {
    let negate = matches!(
        filter.op,
        crate::parser::FilterOp::NotEq | crate::parser::FilterOp::NotIn
    );

    let values = match filter.op {
        crate::parser::FilterOp::Eq | crate::parser::FilterOp::NotEq => {
            vec![filter.value.as_scalar()?.to_string()]
        }
        crate::parser::FilterOp::In | crate::parser::FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(query);
            }
            values
        }
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "{} filter only supports equality and IN/NOT IN comparisons",
                filter.field
            )))
        }
    };

    let mut clauses = Vec::new();

    for value in values {
        for key in keys {
            let key_pattern = escape_like_fragment(key);
            let value_pattern = escape_like_fragment(&value);
            let pattern = sql_string_literal(&format!("%\"{key_pattern}\"%\"{value_pattern}\"%"));

            clauses.push(format!(
                "(metadata::text ILIKE {pattern} ESCAPE '\\' OR \
                  unmapped::text ILIKE {pattern} ESCAPE '\\' OR \
                  observables::text ILIKE {pattern} ESCAPE '\\' OR \
                  raw_data ILIKE {pattern} ESCAPE '\\')"
            ));
        }
    }

    if clauses.is_empty() {
        return Ok(query);
    }

    let clause = clauses.join(" OR ");
    let sql_clause = if negate {
        format!("NOT ({clause})")
    } else {
        format!("({clause})")
    };

    Ok(query.filter(sql::<Bool>(&sql_clause)))
}

fn escape_like_fragment(value: &str) -> String {
    value
        .replace('\\', r"\\")
        .replace('%', r"\%")
        .replace('_', r"\_")
}

fn sql_string_literal(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

fn collect_text_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.op {
        crate::parser::FilterOp::Eq
        | crate::parser::FilterOp::NotEq
        | crate::parser::FilterOp::Like
        | crate::parser::FilterOp::NotLike => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        crate::parser::FilterOp::In | crate::parser::FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(());
            }
            params.push(BindParam::TextArray(values));
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
        "activity_name" | "severity" | "message" | "short_message" | "log_name"
        | "log_provider" | "log_level" | "status" | "status_code" | "status_detail"
        | "trace_id" | "span_id" => collect_text_params(params, filter),
        "device_id" | "uid" | "source_device_uid" | "source" | "source_type" | "addon_id"
        | "purl" | "purl_canonical" | "canonical_purl" | "cpe" | "cpes" | "cve"
        | "vulnerability_id" | "finding_uid" => Ok(()),
        "class_uid" | "category_uid" | "type_uid" | "activity_id" | "severity_id" | "status_id" => {
            params.push(BindParam::Int(i64::from(parse_i32(
                filter.value.as_scalar()?,
            )?)));
            Ok(())
        }
        "id" => {
            params.push(BindParam::Uuid(parse_uuid(filter.value.as_scalar()?)?));
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for events: '{other}'"
        ))),
    }
}

fn apply_ordering<'a>(mut query: EventsQuery<'a>, order: &[OrderClause]) -> EventsQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            match clause.field.as_str() {
                "time" | "event_timestamp" | "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.order(col_time.asc()),
                    OrderDirection::Desc => query.order(col_time.desc()),
                },
                _ => query,
            }
        } else {
            match clause.field.as_str() {
                "time" | "event_timestamp" | "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_time.asc()),
                    OrderDirection::Desc => query.then_order_by(col_time.desc()),
                },
                _ => query,
            }
        };
    }

    if !applied {
        query = query.order(col_time.desc());
    }

    query
}

fn parse_i32(raw: &str) -> Result<i32> {
    raw.parse::<i32>()
        .map_err(|_| ServiceError::InvalidRequest(format!("invalid integer '{raw}'")))
}

fn parse_uuid(raw: &str) -> Result<uuid::Uuid> {
    uuid::Uuid::parse_str(raw)
        .map_err(|_| ServiceError::InvalidRequest(format!("invalid uuid '{raw}'")))
}
