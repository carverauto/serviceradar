use super::{
    rollup::{
        anomaly_detection_rollup_source_clause, capacity_forecast_at_risk_rollup_clause,
        capacity_forecast_rollup_source_clause,
    },
    types::EventsQuery,
};
use crate::{
    error::{Result, ServiceError},
    parser::Filter,
    query::BindParam,
    schema::ocsf_events::dsl::{
        activity_id as col_activity_id, activity_name as col_activity_name,
        category_uid as col_category_uid, class_uid as col_class_uid, id as col_id,
        log_level as col_log_level, log_name as col_log_name, log_provider as col_log_provider,
        message as col_message, severity as col_severity, severity_id as col_severity_id,
        span_id as col_span_id, status as col_status, status_code as col_status_code,
        status_detail as col_status_detail, status_id as col_status_id, trace_id as col_trace_id,
        type_uid as col_type_uid,
    },
};
use diesel::{PgTextExpressionMethods, dsl::sql, prelude::*, sql_types::Bool};

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

pub(super) fn apply_filter<'a>(
    mut query: EventsQuery<'a>,
    filter: &Filter,
) -> Result<EventsQuery<'a>> {
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
        "event_type" => {
            query = apply_event_type_filter(query, filter)?;
        }
        "finding_rollup" => {
            query = apply_finding_rollup_filter(query, filter)?;
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
        "device_uid_exact" => {
            query = apply_device_uid_exact_filter(query, filter)?;
        }
        "service_radar_device_uid" => {
            query = apply_service_radar_device_uid_filter(query, filter)?;
        }
        "agent_id" => {
            query = apply_agent_id_filter(query, filter)?;
        }
        "host_id" | "hostname" => {
            query = apply_host_id_filter(query, filter)?;
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
            )));
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

fn apply_event_type_filter<'a>(query: EventsQuery<'a>, filter: &Filter) -> Result<EventsQuery<'a>> {
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
                "event_type filter only supports equality and IN/NOT IN comparisons".into(),
            ));
        }
    };

    let clauses = values
        .into_iter()
        .map(|value| {
            let literal = sql_string_literal(&value);

            format!(
                "metadata ->> 'event_type' = {literal} OR \
                 metadata #>> '{{service_radar,event_type}}' = {literal} OR \
                 unmapped ->> 'event_type' = {literal}"
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

fn apply_finding_rollup_filter<'a>(
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
                "finding_rollup filter only supports equality and IN/NOT IN comparisons".into(),
            ));
        }
    };

    let anomaly_clause = anomaly_detection_rollup_source_clause();
    let capacity_source_clause = capacity_forecast_rollup_source_clause();
    let capacity_at_risk_clause = capacity_forecast_at_risk_rollup_clause();
    let anomaly_count_clause = format!("({anomaly_clause}) AND NOT ({capacity_source_clause})");
    let detection_finding_gate =
        r#""ocsf_events"."class_uid" = 2004 AND "ocsf_events"."category_uid" = 2"#;

    let clauses = values
        .into_iter()
        .map(|value| match value.as_str() {
            "anomaly" | "anomaly_findings" => Ok(format!(
                "({detection_finding_gate} AND ({anomaly_count_clause}))"
            )),
            "capacity_at_risk" | "at_risk_capacity" => Ok(format!(
                "({detection_finding_gate} AND ({capacity_at_risk_clause}))"
            )),
            "health" | "health_findings" => Ok(format!(
                "({detection_finding_gate} AND (({anomaly_count_clause}) OR ({capacity_at_risk_clause})))"
            )),
            other => Err(ServiceError::InvalidRequest(format!(
                "unsupported finding_rollup value '{other}' (supported: anomaly, capacity_at_risk, health)"
            ))),
        })
        .collect::<Result<Vec<_>>>()?;

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

fn apply_device_uid_exact_filter<'a>(
    query: EventsQuery<'a>,
    filter: &Filter,
) -> Result<EventsQuery<'a>> {
    apply_metadata_exact_filter(
        query,
        filter,
        &[
            "metadata #>> '{service_radar,device_uid}'",
            "metadata ->> 'device_uid'",
            "metadata ->> 'source_device_uid'",
            "unmapped ->> 'device_uid'",
            "unmapped ->> 'source_device_uid'",
            "device ->> 'uid'",
        ],
        "device_uid_exact",
    )
}

fn apply_service_radar_device_uid_filter<'a>(
    query: EventsQuery<'a>,
    filter: &Filter,
) -> Result<EventsQuery<'a>> {
    apply_metadata_exact_filter(
        query,
        filter,
        &["metadata #>> '{service_radar,device_uid}'"],
        "service_radar_device_uid",
    )
}

fn apply_agent_id_filter<'a>(query: EventsQuery<'a>, filter: &Filter) -> Result<EventsQuery<'a>> {
    apply_metadata_exact_filter(
        query,
        filter,
        &[
            "metadata #>> '{service_radar,agent_id}'",
            "metadata #>> '{service_radar,device_uid}'",
            "metadata ->> 'agent_id'",
            "unmapped ->> 'agent_id'",
            "device ->> 'uid'",
        ],
        "agent_id",
    )
}

fn apply_host_id_filter<'a>(query: EventsQuery<'a>, filter: &Filter) -> Result<EventsQuery<'a>> {
    apply_metadata_exact_filter(
        query,
        filter,
        &[
            "metadata #>> '{service_radar,device_hostname}'",
            "metadata #>> '{service_radar,source_instance}'",
            "metadata #>> '{service_radar,device_uid}'",
            "metadata ->> 'hostname'",
            "metadata ->> 'host_id'",
            "unmapped ->> 'hostname'",
            "unmapped ->> 'host_id'",
            "device ->> 'name'",
            "device ->> 'hostname'",
        ],
        "host_id",
    )
}

fn apply_metadata_exact_filter<'a>(
    query: EventsQuery<'a>,
    filter: &Filter,
    expressions: &[&str],
    label: &str,
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
                "{label} filter only supports equality and IN/NOT IN comparisons"
            )));
        }
    };

    let clauses = values
        .into_iter()
        .map(|value| {
            let literal = sql_string_literal(&value);

            expressions
                .iter()
                .map(|expr| format!("{expr} = {literal}"))
                .collect::<Vec<_>>()
                .join(" OR ")
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
            )));
        }
    };

    let mut clauses = Vec::new();

    for value in values {
        // Anchored, index-eligible equality on the two canonical device-key paths
        // that build_anomaly_detection_finding_row writes after the ingest re-key
        // (device.uid and metadata.service_radar.device_uid). For a canonical
        // "sr:" uid this adds the fast path so the planner range-scans
        // idx_ocsf_events_sr_device_uid_time instead of leading-wildcard
        // seq-scanning device/metadata/unmapped/observables ::text (the 15.6s ->
        // statement_timeout path the device anomaly panel was hitting).
        clauses.push(canonical_device_identity_clause(&value));

        // The inventory-alias EXISTS resolves d.uid/d.uid_alt = value and then
        // matches events keyed under the device's hostnames / IPs / alt-uids. It is
        // the ONLY clause that finds historical, *raw*-keyed anomaly findings (the
        // ~15.6k rows written before the #4 ingest re-key) and is shared by the
        // SecurityFindings / ScanActivity / DnsActivity canonical-uid lookups. It is
        // an EXISTS over platform.ocsf_devices, not a leading-wildcard scan of the
        // events table, so it must stay even for canonical "sr:" values — otherwise
        // a canonical lookup silently drops every pre-re-key / alias-keyed finding.
        if keys == EVENT_DEVICE_IDENTITY_KEYS {
            clauses.push(device_inventory_identity_clause(&value));
        }

        // Legacy / free-text fallback: only widen to the non-indexable, leading-
        // wildcard multi-column ::text ILIKE over the events table (the actual
        // 15.6s offender) when the caller passes a raw, pre-re-key id (host name,
        // agent id, series key, bare device id). A canonical "sr:" lookup is served
        // by the anchored equality above plus the alias-EXISTS, so it never needs
        // this substring scan — which is what keeps the dominant device-detail panel
        // path index-served while legacy ids still resolve exactly as before.
        if !is_canonical_device_uid(&value) {
            for key in keys {
                let key_pattern = escape_like_fragment(key);
                let value_pattern = escape_like_fragment(&value);
                let pattern =
                    sql_string_literal(&format!("%\"{key_pattern}\"%\"{value_pattern}\"%"));

                clauses.push(format!(
                    "(device::text ILIKE {pattern} ESCAPE '\\' OR \
                      metadata::text ILIKE {pattern} ESCAPE '\\' OR \
                      unmapped::text ILIKE {pattern} ESCAPE '\\' OR \
                      observables::text ILIKE {pattern} ESCAPE '\\')"
                ));
            }
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
            ));
        }
    };

    let clauses = values
        .into_iter()
        .map(|value| {
            let literal = sql_string_literal(&value);

            format!(
                "metadata #>> '{{finding_info,uid}}' = {literal} OR \
                 metadata #>> '{{security_signal,finding_uid}}' = {literal} OR \
                 metadata #>> '{{uid}}' = {literal} OR \
                 metadata #>> '{{event_id}}' = {literal}"
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

/// Anchored equality on the canonical device-key paths an OCSF detection finding
/// carries after the ingest re-key. Both terms are plain `#>>`/`->>` text equality,
/// so the partial expression index idx_ocsf_events_sr_device_uid_time (on
/// `metadata #>> '{service_radar,device_uid}'` WHERE class_uid = 2004) serves the
/// dominant `metadata` term, and `device ->> 'uid'` covers the OCSF device block.
fn canonical_device_identity_clause(value: &str) -> String {
    let literal = sql_string_literal(value);

    format!(
        "(metadata #>> '{{service_radar,device_uid}}' = {literal} \
          OR device ->> 'uid' = {literal})"
    )
}

/// Canonical inventory uids are always `sr:`-prefixed. A value that already looks
/// canonical does not need the legacy free-text fallback scan, which is what lets
/// the device-detail panel lookup stay purely index-served.
fn is_canonical_device_uid(value: &str) -> bool {
    value.starts_with("sr:")
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
            )));
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

pub(super) fn collect_filter_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.field.as_str() {
        "activity_name" | "severity" | "message" | "short_message" | "log_name"
        | "log_provider" | "log_level" | "status" | "status_code" | "status_detail"
        | "trace_id" | "span_id" => collect_text_params(params, filter),
        "device_id"
        | "uid"
        | "source_device_uid"
        | "device_uid_exact"
        | "service_radar_device_uid"
        | "agent_id"
        | "host_id"
        | "hostname"
        | "source"
        | "source_type"
        | "addon_id"
        | "event_type"
        | "finding_rollup"
        | "purl"
        | "purl_canonical"
        | "canonical_purl"
        | "cpe"
        | "cpes"
        | "cve"
        | "vulnerability_id"
        | "finding_uid" => Ok(()),
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

fn parse_i32(raw: &str) -> Result<i32> {
    raw.parse::<i32>()
        .map_err(|_| ServiceError::InvalidRequest(format!("invalid integer '{raw}'")))
}

fn parse_uuid(raw: &str) -> Result<uuid::Uuid> {
    uuid::Uuid::parse_str(raw)
        .map_err(|_| ServiceError::InvalidRequest(format!("invalid uuid '{raw}'")))
}
