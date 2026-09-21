use super::flows::normalize_cidr_literal;
use super::{PaginationMeta, QueryPlan, TranslateResponse, types::BindParam};
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, Filter},
};
use chrono::{SecondsFormat, Timelike, Utc};

/// Compile an authorized SRQL plan to StarRocks SQL.
///
/// Unsupported shapes return a capability error instead of silently falling
/// back to PostgreSQL.
pub fn translate(plan: &QueryPlan, database: &str) -> Result<TranslateResponse> {
    translate_inner(plan, database, true)
}

/// Compile an authorized SRQL plan to StarRocks SQL without hourly rollups.
///
/// The Elixir rollup-freshness gate selects this entry point when an hourly
/// materialized view is stale: the query reads the StarRocks raw table
/// instead, never CNPG.
pub fn translate_raw(plan: &QueryPlan, database: &str) -> Result<TranslateResponse> {
    translate_inner(plan, database, false)
}

fn translate_inner(
    plan: &QueryPlan,
    database: &str,
    allow_rollup: bool,
) -> Result<TranslateResponse> {
    match dataset_for(&plan.entity) {
        Some(dataset) => {
            refuse_unimplemented_features(plan)?;
            if let Some(kind) = rollup_stats_kind(plan) {
                return rollup_stats_sql(plan, dataset, database, kind);
            }
            dataset_sql(plan, dataset, database, allow_rollup)
        }
        None => Err(ServiceError::NotImplemented(format!(
            "starrocks_unsupported_entity: {:?}",
            plan.entity
        ))),
    }
}

#[derive(Clone, Copy)]
struct Dataset {
    raw_table: &'static str,
    time_column: &'static str,
    scope: Option<&'static str>,
    hourly: Option<HourlyRollup>,
}

/// An hourly materialized view (priv/starrocks/0017) a bucketed query may read
/// instead of the raw table. `dimensions` is every column the view groups by
/// besides `bucket` and its partition column `day`, so a filter or series
/// outside that list has no equivalent there.
#[derive(Clone, Copy)]
struct HourlyRollup {
    table: &'static str,
    dimensions: &'static [&'static str],
}

const HOURLY_ROLLUP_GRAIN_SECONDS: i64 = 3600;

const FLOW_HOURLY: HourlyRollup = HourlyRollup {
    table: "ocsf_network_activity_hourly",
    dimensions: &[],
};

const METRIC_HOURLY: HourlyRollup = HourlyRollup {
    table: "timeseries_metrics_hourly",
    dimensions: &["device_id", "metric_type", "metric_name"],
};

/// `timeseries_metrics` and `events` are each one physical table holding
/// several families, exactly as they are on CNPG, so an entity scoped to one
/// family carries that family's `scope` predicate. The sysmon entities are
/// deliberately absent: CNPG serves them from their own `cpu_metrics`/
/// `memory_metrics`/`disk_metrics`/`process_metrics` tables, which EventWriter
/// never mirrors into the warehouse.
fn dataset_for(entity: &Entity) -> Option<Dataset> {
    match entity {
        Entity::Flows => Some(Dataset {
            raw_table: "ocsf_network_activity",
            time_column: "time",
            scope: None,
            hourly: Some(FLOW_HOURLY),
        }),
        // The flow rollup groups by bucket alone, so it cannot carry the
        // attributed-flow discriminator and never serves this entity.
        Entity::AttributedFlows => Some(Dataset {
            raw_table: "ocsf_network_activity",
            time_column: "time",
            scope: Some(ATTRIBUTED_FLOW_SCOPE),
            hourly: None,
        }),
        Entity::TimeseriesMetrics => Some(Dataset {
            raw_table: "timeseries_metrics",
            time_column: "timestamp",
            scope: None,
            hourly: Some(METRIC_HOURLY),
        }),
        Entity::SnmpMetrics => Some(Dataset {
            raw_table: "timeseries_metrics",
            time_column: "timestamp",
            scope: Some(SNMP_METRIC_SCOPE),
            hourly: Some(METRIC_HOURLY),
        }),
        Entity::RperfMetrics => Some(Dataset {
            raw_table: "timeseries_metrics",
            time_column: "timestamp",
            scope: Some(RPERF_METRIC_SCOPE),
            hourly: Some(METRIC_HOURLY),
        }),
        Entity::Logs => Some(Dataset {
            raw_table: "logs",
            time_column: "timestamp",
            scope: None,
            hourly: None,
        }),
        Entity::Events => Some(Dataset {
            raw_table: "events",
            time_column: "time",
            scope: None,
            hourly: None,
        }),
        Entity::SecurityFindings => Some(Dataset {
            raw_table: "events",
            time_column: "time",
            scope: Some(SECURITY_FINDINGS_SCOPE),
            hourly: None,
        }),
        Entity::ScanActivity => Some(Dataset {
            raw_table: "events",
            time_column: "time",
            scope: Some(SCAN_ACTIVITY_SCOPE),
            hourly: None,
        }),
        Entity::DnsActivity => Some(Dataset {
            raw_table: "events",
            time_column: "time",
            scope: Some(DNS_ACTIVITY_SCOPE),
            hourly: None,
        }),
        _ => None,
    }
}

// Mirrors the CNPG ocsf_payload discriminator in query/flows/expressions.rs:
// attributed_flows is a strict SUBSET of flows, not a projection of it.
const ATTRIBUTED_FLOW_SCOPE: &str = "event_type = 'attributed_flow'";

const SNMP_METRIC_SCOPE: &str = "metric_type = 'snmp'";
const RPERF_METRIC_SCOPE: &str = "metric_type = 'rperf'";

// Mirrors the CNPG ocsf_events discriminators in query/events/query.rs.
const SECURITY_FINDINGS_SCOPE: &str = "category_uid = 2";
const SCAN_ACTIVITY_SCOPE: &str = "class_uid = 6007 AND category_uid = 6";
const DNS_ACTIVITY_SCOPE: &str = "class_uid = 4003 AND category_uid = 4";

const FLOW_PROTOCOL_GROUP_SQL: &str =
    "CASE WHEN protocol_num = 6 THEN 'tcp' WHEN protocol_num = 17 THEN 'udp' ELSE 'other' END";
const FLOW_BYTES_TOTAL_SQL: &str =
    "COALESCE(bytes_total, COALESCE(bytes_in, 0) + COALESCE(bytes_out, 0))";
const FLOW_PACKETS_TOTAL_SQL: &str =
    "COALESCE(packets_total, COALESCE(packets_in, 0) + COALESCE(packets_out, 0))";
const FLOW_ROW_FIELDS: &[&str] = &[
    "id",
    "time",
    "device_uid",
    "src_endpoint_ip",
    "dst_endpoint_ip",
    "src_endpoint_port",
    "dst_endpoint_port",
    "protocol_num",
    "protocol_name",
    "protocol_group",
    "bytes_total",
    "packets_total",
    "bytes_in",
    "bytes_out",
    "packets_in",
    "packets_out",
    "sampling_rate",
    "direction_label",
    "sampler_address",
    "dst_service_label",
    "src_as_number",
    "dst_as_number",
    "tcp_flags",
    "input_snmp",
    "output_snmp",
    "start_time",
    "end_time",
    "pid",
    "comm",
    "cmdline",
    "workload_identity",
    "attribution_status",
];

// `device_uid` and `sampler_address` also exist on netflow_interface_cache, so
// an unqualified row projection is ambiguous the moment that join is present.
fn flow_row_select(plan: &QueryPlan) -> Result<String> {
    let mut parts = Vec::with_capacity(FLOW_ROW_FIELDS.len());
    for field in FLOW_ROW_FIELDS {
        let expr = field_sql(plan, field)?;
        if expr == *field {
            parts.push(expr);
        } else {
            parts.push(format!("{expr} AS {field}"));
        }
    }
    Ok(parts.join(", "))
}

fn dataset_sql(
    plan: &QueryPlan,
    dataset: Dataset,
    database: &str,
    allow_rollup: bool,
) -> Result<TranslateResponse> {
    // A `profile_hour_of_week[_peak]` query carries a bucket clause but is a
    // profile aggregation, not a downsample, and it owns its own WHERE because
    // `timezone:` steers the profile rather than filtering a column.
    if is_profile_stats(plan) {
        return profile_sql(plan, dataset, database);
    }

    let joins = catalog_joins(plan, dataset)?;
    let direction = plan_mentions(plan, &["direction"]);
    let derived = direction || filters_on_flow_cidr(plan);
    let hour_grained = if joins.is_empty() && !derived {
        hourly_rollup(plan, dataset)
    } else {
        None
    };
    let rollup = if allow_rollup { hour_grained } else { None };
    let time_column = match rollup {
        Some(_) => "bucket",
        None => dataset.time_column,
    };
    let qualified = format!(
        "{database}.{}",
        rollup.map_or(dataset.raw_table, |rollup| rollup.table)
    );
    let from = if derived {
        let base = if direction {
            direction_source(&qualified)
        } else {
            ip_hex_source(&qualified)
        };
        if joins.is_empty() {
            format!("{base} AS f")
        } else {
            from_with_catalog_joins(&base, &joins)
        }
    } else {
        from_with_catalog_joins(&qualified, &joins)
    };
    let (mut where_sql, params) = time_predicate(
        plan,
        time_column,
        derived || !joins.is_empty(),
        hour_grained.is_some(),
    );
    if let Some(scope) = dataset.scope {
        where_sql.push_str(&format!(" AND ({scope})"));
    }
    let raw_table = format!("{database}.{}", dataset.raw_table);
    for predicate in filter_predicates(plan, dataset, &raw_table, &where_sql)? {
        where_sql.push_str(" AND ");
        where_sql.push_str(&predicate);
    }
    if let Some(downsample) = plan.downsample.as_ref() {
        let sql = downsample_sql(
            plan,
            dataset,
            downsample,
            &from,
            &where_sql,
            time_column,
            rollup,
        )?;
        return Ok(TranslateResponse {
            sql,
            params,
            pagination: PaginationMeta {
                next_cursor: None,
                prev_cursor: None,
                limit: Some(plan.limit),
            },
            viz: None,
        });
    }
    let (select, group) = stats_select(plan, dataset)?;
    let order = order_sql(plan, time_column)?;
    let sql = format!(
        "SELECT {select} FROM {from}{where_sql}{group}{order} LIMIT {limit} OFFSET {offset}",
        limit = plan.limit.max(1),
        offset = plan.offset.max(0)
    );

    Ok(TranslateResponse {
        sql,
        params,
        pagination: PaginationMeta {
            next_cursor: None,
            prev_cursor: None,
            limit: Some(plan.limit),
        },
        viz: None,
    })
}

/// A plan feature this dialect has no translation for is an error, never a
/// no-op. `rollup_stats:` used to be dropped here: the query compiled to
/// `SELECT *`, and the stat cards read their counters off a raw row as zeros
/// inside an `{:ok, ...}` response. Anything the compile below does not consume
/// is refused by name instead, so the caller sees a failure rather than a
/// wrong answer.
///
/// `include_deleted` is not refused: only the device inventory has tombstones
/// (`query/devices.rs`), no warehouse dataset does, and CNPG ignores it for
/// these entities too, so dropping it cannot change a result.
fn refuse_unimplemented_features(plan: &QueryPlan) -> Result<()> {
    if plan.other {
        return Err(ServiceError::InvalidRequest(
            "StarRocks does not implement other:true (top-N with an Other tail)".into(),
        ));
    }
    let Some(kind) = rollup_stats_kind(plan) else {
        return Ok(());
    };
    if !matches!(
        (&plan.entity, kind),
        (Entity::Logs, "severity") | (Entity::Events, "anomaly_findings")
    ) {
        return Err(ServiceError::InvalidRequest(format!(
            "StarRocks does not implement rollup_stats:{kind} for {:?}",
            plan.entity
        )));
    }
    // A rollup is one fixed aggregate. CNPG answers it before it looks at
    // anything else in the plan; here a clause that cannot shape the answer is
    // refused rather than dropped.
    for (present, clause) in [
        (plan.stats.is_some(), "stats:"),
        (plan.downsample.is_some(), "bucket:"),
    ] {
        if present {
            return Err(ServiceError::InvalidRequest(format!(
                "StarRocks rollup_stats:{kind} cannot be combined with {clause}"
            )));
        }
    }
    Ok(())
}

fn rollup_stats_kind(plan: &QueryPlan) -> Option<&str> {
    plan.rollup_stats
        .as_deref()
        .map(str::trim)
        .filter(|kind| !kind.is_empty())
}

/// CNPG answers these from continuous aggregates and hands back one `payload`
/// jsonb, which the SRQL response unwraps into a single result map. A
/// warehouse result is already one map per row keyed by column name, so the
/// same counters are emitted as plain columns under the payload's key names;
/// `Stats.Extract` reads the identical `results` shape from either backend.
fn rollup_stats_sql(
    plan: &QueryPlan,
    dataset: Dataset,
    database: &str,
    kind: &str,
) -> Result<TranslateResponse> {
    let table = format!("{database}.{}", dataset.raw_table);
    let (where_sql, params) = time_predicate(plan, dataset.time_column, false, false);
    let sql = match (&plan.entity, kind) {
        (Entity::Logs, "severity") => logs_severity_rollup_sql(plan, &table, &where_sql)?,
        (Entity::Events, "anomaly_findings") => {
            events_anomaly_findings_rollup_sql(plan, &table, &where_sql)?
        }
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "StarRocks does not implement rollup_stats:{kind} for {:?}",
                plan.entity
            )));
        }
    };
    Ok(TranslateResponse {
        sql,
        params,
        pagination: PaginationMeta {
            next_cursor: None,
            prev_cursor: None,
            limit: Some(plan.limit),
        },
        viz: None,
    })
}

// platform.serviceradar_log_severity_bucket, the classifier behind the
// logs_severity_stats_5m aggregate: recognized severity text decides the
// bucket, and the OTEL severity number only speaks for a row whose text is
// absent or unrecognized. `critical` is an error, not a fatal.
const LOG_SEVERITY_BUCKETS: &[(&str, &[&str], (i32, i32))] = &[
    (
        "fatal",
        &[
            "fatal",
            "emergency",
            "alert",
            "severity_number_fatal",
            "severity_number_fatal2",
            "severity_number_fatal3",
            "severity_number_fatal4",
        ],
        (21, 24),
    ),
    (
        "error",
        &[
            "error",
            "err",
            "critical",
            "severity_number_error",
            "severity_number_error2",
            "severity_number_error3",
            "severity_number_error4",
        ],
        (17, 20),
    ),
    (
        "warning",
        &[
            "warning",
            "warn",
            "severity_number_warn",
            "severity_number_warn2",
            "severity_number_warn3",
            "severity_number_warn4",
        ],
        (13, 16),
    ),
    (
        "info",
        &[
            "info",
            "information",
            "informational",
            "notice",
            "severity_number_info",
            "severity_number_info2",
            "severity_number_info3",
            "severity_number_info4",
        ],
        (9, 12),
    ),
    (
        "debug",
        &[
            "debug",
            "trace",
            "severity_number_debug",
            "severity_number_debug2",
            "severity_number_debug3",
            "severity_number_debug4",
            "severity_number_trace",
            "severity_number_trace2",
            "severity_number_trace3",
            "severity_number_trace4",
        ],
        (1, 8),
    ),
];

fn log_severity_bucket_sql() -> String {
    let mut arms = String::new();
    for (bucket, texts, _) in LOG_SEVERITY_BUCKETS {
        arms.push_str(&format!(
            " WHEN LOWER(COALESCE(severity_text, '')) IN ({}) THEN '{bucket}'",
            literal_list(texts.iter().copied())
        ));
    }
    for (bucket, _, (low, high)) in LOG_SEVERITY_BUCKETS {
        arms.push_str(&format!(
            " WHEN severity_number BETWEEN {low} AND {high} THEN '{bucket}'"
        ));
    }
    format!("CASE{arms} ELSE NULL END")
}

fn literal_list<'a>(values: impl Iterator<Item = &'a str>) -> String {
    values.map(sql_literal).collect::<Vec<_>>().join(", ")
}

/// `rollup_stats:severity`, computed from the raw log rows. The aggregate it
/// mirrors groups by service_name alone, so that is the only filter either
/// backend accepts here.
fn logs_severity_rollup_sql(plan: &QueryPlan, table: &str, where_sql: &str) -> Result<String> {
    let mut where_sql = where_sql.to_string();
    for filter in &plan.filters {
        match filter.field.as_str() {
            "service_name" | "service" => {
                where_sql.push_str(" AND ");
                where_sql.push_str(&text_filter_sql("service_name", filter, false)?);
            }
            other => {
                return Err(ServiceError::InvalidRequest(format!(
                    "rollup_stats:severity only supports service_name filter, got: '{other}'"
                )));
            }
        }
    }
    let counters = LOG_SEVERITY_BUCKETS
        .iter()
        .map(|(bucket, _, _)| {
            format!("COUNT(CASE WHEN severity_bucket = '{bucket}' THEN 1 END) AS `{bucket}`")
        })
        .collect::<Vec<_>>()
        .join(", ");
    Ok(format!(
        "SELECT COUNT(*) AS `total`, {counters} FROM (SELECT {} AS severity_bucket FROM {table}{where_sql}) s",
        log_severity_bucket_sql()
    ))
}

/// A text comparison as CNPG writes one: equality and lists are exact, LIKE is
/// ILIKE. `keep_null` is the difference between its two callers. An ordinary
/// column filter (`apply_text_filter!`) keeps a NULL row under every negation,
/// `col IS NULL OR col <> v`; the severity rollup's own clause builder
/// (query/logs/rollup.rs) does not.
fn text_filter_sql(column: &str, filter: &Filter, keep_null: bool) -> Result<String> {
    use crate::parser::FilterOp;
    let negation = |predicate: String| {
        if keep_null {
            format!("({column} IS NULL OR {predicate})")
        } else {
            predicate
        }
    };
    Ok(match filter.op {
        FilterOp::Eq => format!("{column} = {}", sql_literal(filter.value.as_scalar()?)),
        FilterOp::NotEq => negation(format!(
            "{column} != {}",
            sql_literal(filter.value.as_scalar()?)
        )),
        FilterOp::Like => format!(
            "LOWER({column}) LIKE {}",
            sql_literal(&filter.value.as_scalar()?.to_lowercase())
        ),
        FilterOp::NotLike => negation(format!(
            "LOWER({column}) NOT LIKE {}",
            sql_literal(&filter.value.as_scalar()?.to_lowercase())
        )),
        FilterOp::In => format!(
            "{column} IN ({})",
            literal_list(list_values(filter)?.iter().map(String::as_str))
        ),
        FilterOp::NotIn => negation(format!(
            "{column} NOT IN ({})",
            literal_list(list_values(filter)?.iter().map(String::as_str))
        )),
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported operator for text filter: {:?}",
                filter.op
            )));
        }
    })
}

// CNPG caps a log list filter at 200 values (query/logs/mod.rs).
const MAX_LIST_FILTER_VALUES: usize = 200;

fn list_values(filter: &Filter) -> Result<&[String]> {
    let values = filter.value.as_list()?;
    if values.is_empty() {
        return Err(ServiceError::InvalidRequest("empty filter list".into()));
    }
    if values.len() > MAX_LIST_FILTER_VALUES {
        return Err(ServiceError::InvalidRequest(format!(
            "{} filters support at most {MAX_LIST_FILTER_VALUES} values",
            filter.field
        )));
    }
    Ok(values)
}

/// The values of an equality-or-list filter and whether it negates -- the only
/// operators CNPG's document filters accept.
fn exact_values<'a>(filter: &'a Filter, label: &str) -> Result<(Vec<&'a str>, bool)> {
    use crate::parser::FilterOp;
    let negate = matches!(filter.op, FilterOp::NotEq | FilterOp::NotIn);
    let values = match filter.op {
        FilterOp::Eq | FilterOp::NotEq => vec![filter.value.as_scalar()?],
        FilterOp::In | FilterOp::NotIn => list_values(filter)?.iter().map(String::as_str).collect(),
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "{label} filter only supports equality and IN/NOT IN comparisons"
            )));
        }
    };
    Ok((values, negate))
}

fn any_of(clauses: Vec<String>, negate: bool) -> String {
    let clause = clauses
        .into_iter()
        .map(|clause| format!("({clause})"))
        .collect::<Vec<_>>()
        .join(" OR ");
    if negate {
        format!("NOT ({clause})")
    } else {
        format!("({clause})")
    }
}

/// A text value inside one of the `events` JSON documents (`metadata`,
/// `unmapped`, `device`), which the warehouse keeps as VARCHAR. CNPG reads the
/// same path with `->>` / `#>>`; both return NULL for a missing key, a JSON
/// null or a NULL document. Every key is quoted into the path, so each one is
/// validated before it is interpolated.
fn event_json_text(document: &str, path: &[&str]) -> Result<String> {
    let mut json_path = String::from("$");
    for key in path {
        if !super::filters_common::is_valid_jsonb_key(key) {
            return Err(ServiceError::InvalidRequest(format!(
                "invalid JSON key '{key}'"
            )));
        }
        json_path.push_str(&format!(".\"{key}\""));
    }
    Ok(format!("get_json_string({document}, '{json_path}')"))
}

// (document, path) pairs, mirroring the clause lists in query/events/filters.rs
// and query/events/rollup.rs one for one.
type EventPath = (&'static str, &'static [&'static str]);

const EVENT_TYPE_PATHS: &[EventPath] = &[
    ("metadata", &["event_type"]),
    ("metadata", &["service_radar", "event_type"]),
    ("unmapped", &["event_type"]),
];
const EVENT_FINDING_UID_PATHS: &[EventPath] = &[
    ("metadata", &["finding_info", "uid"]),
    ("metadata", &["security_signal", "finding_uid"]),
    ("metadata", &["uid"]),
    ("metadata", &["event_id"]),
];
const EVENT_SOURCE_PATHS: &[EventPath] = &[
    ("metadata", &["service_radar", "source_type"]),
    ("metadata", &["service_radar", "addon_id"]),
    ("metadata", &["serviceradar", "source_type"]),
    ("metadata", &["serviceradar", "addon_id"]),
    ("metadata", &["source"]),
    ("unmapped", &["source_type"]),
    ("unmapped", &["addon_id"]),
];
const EVENT_CANONICAL_DEVICE_PATHS: &[EventPath] = &[
    ("metadata", &["service_radar", "device_uid"]),
    ("device", &["uid"]),
];
const EVENT_DEVICE_UID_EXACT_PATHS: &[EventPath] = &[
    ("metadata", &["service_radar", "device_uid"]),
    ("metadata", &["device_uid"]),
    ("metadata", &["source_device_uid"]),
    ("unmapped", &["device_uid"]),
    ("unmapped", &["source_device_uid"]),
    ("device", &["uid"]),
];
const EVENT_SERVICE_RADAR_DEVICE_UID_PATHS: &[EventPath] =
    &[("metadata", &["service_radar", "device_uid"])];
const EVENT_AGENT_ID_PATHS: &[EventPath] = &[
    ("metadata", &["service_radar", "agent_id"]),
    ("metadata", &["service_radar", "device_uid"]),
    ("metadata", &["agent_id"]),
    ("unmapped", &["agent_id"]),
    ("device", &["uid"]),
];
const EVENT_HOST_PATHS: &[EventPath] = &[
    ("metadata", &["service_radar", "device_hostname"]),
    ("metadata", &["service_radar", "source_instance"]),
    ("metadata", &["service_radar", "device_uid"]),
    ("metadata", &["hostname"]),
    ("metadata", &["host_id"]),
    ("unmapped", &["hostname"]),
    ("unmapped", &["host_id"]),
    ("device", &["name"]),
    ("device", &["hostname"]),
];
// EVENT_DEVICE_IDENTITY_KEYS in query/events/filters.rs: the key names the
// free-text fallback looks for ahead of a raw, pre-re-key device id.
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
const EVENT_DOCUMENTS: &[&str] = &["device", "metadata", "unmapped", "observables"];

fn event_paths_equal(paths: &[EventPath], value: &str) -> Result<String> {
    let literal = sql_literal(value);
    Ok(paths
        .iter()
        .map(|(document, path)| Ok(format!("{} = {literal}", event_json_text(document, path)?)))
        .collect::<Result<Vec<_>>>()?
        .join(" OR "))
}

fn event_exact_filter_sql(filter: &Filter, paths: &[EventPath], label: &str) -> Result<String> {
    let (values, negate) = exact_values(filter, label)?;
    let clauses = values
        .into_iter()
        .map(|value| event_paths_equal(paths, value))
        .collect::<Result<Vec<_>>>()?;
    Ok(any_of(clauses, negate))
}

/// `source:` / `source_type:` / `addon_id:` name where an event came from, and
/// an emitter may record that in the provider, the log name or any of the
/// metadata spellings. The warehouse's flattened `source_type` column is the
/// first two of those spellings, which is what lets a row written before the
/// documents were stored still match.
fn event_source_filter_sql(filter: &Filter) -> Result<String> {
    let (values, negate) = exact_values(filter, &filter.field)?;
    let clauses = values
        .into_iter()
        .map(|value| {
            let literal = sql_literal(value);
            Ok(format!(
                "log_provider = {literal} OR log_name = {literal} OR source_type = {literal} OR {}",
                event_paths_equal(EVENT_SOURCE_PATHS, value)?
            ))
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(any_of(clauses, negate))
}

fn escape_like_fragment(value: &str) -> String {
    value
        .replace('\\', r"\\")
        .replace('%', r"\%")
        .replace('_', r"\_")
}

/// Every alias the inventory holds for one device, lowercased, as a subquery
/// that names no event column. The list is DEVICE_INVENTORY_ALIAS_EXPRESSIONS
/// in query/events/filters.rs, and five of its members are keys of the
/// device's jsonb metadata, which the JDBC catalog cannot carry; CNPG unpivots
/// them into `device_inventory_aliases_catalog`, blank and NULL aliases already
/// dropped.
fn device_inventory_aliases_sql(uid: &str) -> String {
    format!(
        "SELECT LOWER(a.alias) AS alias FROM {CNPG_CATALOG}.device_inventory_aliases_catalog a WHERE a.uid = {uid} OR a.uid_alt = {uid}"
    )
}

/// The events, within the query's own bounds, whose stored documents hold one
/// of the device's aliases as a quoted JSON string. CNPG finds them with an
/// EXISTS whose LIKE pattern comes from the device row, a non-equality
/// correlated subquery StarRocks refuses; a join against the handful of
/// aliases is the same test, and the outer predicate stays an uncorrelated
/// `id IN (...)`. LIKE wildcards in an alias are escaped, as CNPG escapes them.
fn events_naming_an_alias_sql(table: &str, bounds: &str, aliases: &str) -> String {
    let pattern = r#"CONCAT('%"', REPLACE(REPLACE(REPLACE(da.alias, '\\', '\\\\'), '%', '\\%'), '_', '\\_'), '"%')"#;
    let mentions = EVENT_DOCUMENTS
        .iter()
        .map(|document| format!("LOWER(e.{document}) LIKE da.pattern"))
        .collect::<Vec<_>>()
        .join(" OR ");
    format!(
        "SELECT e.id FROM {table} e JOIN (SELECT {pattern} AS pattern FROM ({aliases}) da) da ON {mentions}{bounds}"
    )
}

/// `device_id:` on events, arm for arm as CNPG builds it. A canonical `sr:`
/// uid is an anchored equality on the two paths an emitter writes after the
/// ingest re-key. Every value also resolves the device's inventory aliases,
/// which is what finds an event keyed under a hostname or an address instead
/// of the uid. A raw id additionally gets the case-insensitive scan of the
/// documents for a `"<identity key>" ... "<value>"` pair.
///
/// Under negation each arm keeps CNPG's truth values. The canonical equality
/// is NULL for an event that carries neither path, there and here, so
/// `!device_id:` returns the events known to be about another device. CNPG's
/// alias arm is an EXISTS and its scan reads NOT NULL jsonb, so both are FALSE
/// rather than NULL for an event that names no device; the warehouse documents
/// are nullable, and the same arms are made two-valued to match.
fn event_device_identity_filter_sql(filter: &Filter, table: &str, bounds: &str) -> Result<String> {
    let (values, negate) = exact_values(filter, &filter.field)?;
    let mut clauses = Vec::new();
    for value in values {
        clauses.push(event_paths_equal(EVENT_CANONICAL_DEVICE_PATHS, value)?);

        let aliases = device_inventory_aliases_sql(&sql_literal(value));
        clauses.push(format!(
            "COALESCE(LOWER(src_endpoint_ip), '') IN ({aliases})"
        ));
        clauses.push(format!(
            "id IN ({})",
            events_naming_an_alias_sql(table, bounds, &aliases)
        ));

        if value.starts_with("sr:") {
            continue;
        }
        for key in EVENT_DEVICE_IDENTITY_KEYS {
            let pattern = sql_literal(
                &format!(
                    "%\"{}\"%\"{}\"%",
                    escape_like_fragment(key),
                    escape_like_fragment(value)
                )
                .to_lowercase(),
            );
            clauses.push(format!(
                "COALESCE({}, FALSE)",
                EVENT_DOCUMENTS
                    .iter()
                    .map(|document| format!("LOWER({document}) LIKE {pattern}"))
                    .collect::<Vec<_>>()
                    .join(" OR ")
            ));
        }
    }
    Ok(any_of(clauses, negate))
}

// The three predicates behind the anomaly finding cards, from
// query/events/rollup.rs, path for path. They are deliberately not widened to
// the flattened `source_type` column: the anomaly verdict is `source AND NOT
// capacity`, and the capacity test is NULL -- so the verdict is NULL -- for a
// row stored before the documents were kept, whatever its flattened columns
// say. Such a row is outside these counts until it ages out or is backfilled.
fn event_anomaly_source_sql() -> Result<String> {
    Ok(format!(
        "({} = 'anomaly_detection' OR {} = 'anomaly-detection' OR {} = 'anomaly' OR {} = 'anomaly_detection' OR log_provider = 'anomaly_detection' OR {} IN ('anomaly', 'anomaly_detection'))",
        event_json_text("metadata", &["service_radar", "source_type"])?,
        event_json_text("metadata", &["service_radar", "addon_id"])?,
        event_json_text("metadata", &["detection_finding", "type"])?,
        event_json_text("metadata", &["security_signal", "source"])?,
        event_json_text("unmapped", &["event_type"])?,
    ))
}

fn event_capacity_source_sql() -> Result<String> {
    Ok(format!(
        "({} = 'capacity_forecast' OR {} = 'capacity_forecast' OR log_provider = 'capacity_forecasting')",
        event_json_text("metadata", &["event_type"])?,
        event_json_text("unmapped", &["event_type"])?,
    ))
}

fn event_capacity_at_risk_sql() -> Result<String> {
    Ok(format!(
        "({} AND (COALESCE(severity_id, 0) >= 3 OR {} IN ('projected', 'at_risk', 'exhaustion_projected') OR NULLIF({}, '') IS NOT NULL))",
        event_capacity_source_sql()?,
        event_json_text("unmapped", &["capacity_forecast", "status"])?,
        event_json_text(
            "unmapped",
            &["capacity_forecast", "projected_exhaustion_at"]
        )?,
    ))
}

fn event_anomaly_count_sql() -> Result<String> {
    Ok(format!(
        "({} AND NOT {})",
        event_anomaly_source_sql()?,
        event_capacity_source_sql()?
    ))
}

const DETECTION_FINDING_GATE: &str = "class_uid = 2004 AND category_uid = 2";

fn event_finding_rollup_filter_sql(filter: &Filter) -> Result<String> {
    let (values, negate) = exact_values(filter, "finding_rollup")?;
    let clauses = values
        .into_iter()
        .map(|value| {
            let body = match value {
                "anomaly" | "anomaly_findings" => event_anomaly_count_sql()?,
                "capacity_at_risk" | "at_risk_capacity" => event_capacity_at_risk_sql()?,
                "health" | "health_findings" => format!(
                    "({} OR {})",
                    event_anomaly_count_sql()?,
                    event_capacity_at_risk_sql()?
                ),
                other => {
                    return Err(ServiceError::InvalidRequest(format!(
                        "unsupported finding_rollup value '{other}' (supported: anomaly, capacity_at_risk, health)"
                    )));
                }
            };
            Ok(format!("{DETECTION_FINDING_GATE} AND {body}"))
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(any_of(clauses, negate))
}

/// `rollup_stats:anomaly_findings`, the same counters CNPG builds in
/// query/events/rollup.rs. The two verdicts are evaluated once per row in the
/// inner select; a NULL verdict counts as false in both the outer WHERE and
/// the CASE, exactly as it does under PostgreSQL's `FILTER (WHERE ...)`.
fn events_anomaly_findings_rollup_sql(
    plan: &QueryPlan,
    table: &str,
    where_sql: &str,
) -> Result<String> {
    if !plan.filters.is_empty() {
        let fields = plan
            .filters
            .iter()
            .map(|filter| filter.field.as_str())
            .collect::<Vec<_>>()
            .join(", ");
        return Err(ServiceError::InvalidRequest(format!(
            "rollup_stats:anomaly_findings does not support filters, got: '{fields}'"
        )));
    }
    Ok(format!(
        "SELECT COUNT(*) AS `total`, COUNT(CASE WHEN is_anomaly THEN 1 END) AS `anomalies`, COUNT(CASE WHEN is_at_risk THEN 1 END) AS `at_risk`, COUNT(CASE WHEN is_anomaly AND COALESCE(severity_id, 0) >= 5 THEN 1 END) AS `critical`, COUNT(CASE WHEN is_anomaly AND COALESCE(severity_id, 0) = 4 THEN 1 END) AS `high` FROM (SELECT severity_id, {} AS is_anomaly, {} AS is_at_risk FROM {table}{where_sql} AND {DETECTION_FINDING_GATE}) f WHERE is_anomaly OR is_at_risk",
        event_anomaly_count_sql()?,
        event_capacity_at_risk_sql()?
    ))
}

/// Every WHERE predicate the plan's filters compile to. Almost all are one
/// filter each; `severity_match:any` is the exception, a marker that joins the
/// log severity text and number filters into one predicate. The event device
/// filter is compiled here rather than in `filter_sql` because one of its arms
/// reads the events table again, inside `bounds`, the WHERE the query itself
/// has built so far.
fn filter_predicates(
    plan: &QueryPlan,
    dataset: Dataset,
    table: &str,
    bounds: &str,
) -> Result<Vec<String>> {
    let severity_any = dataset.raw_table == "logs" && logs_severity_match_any(plan);
    let mut predicates = Vec::new();
    let mut severity_text = None;
    let mut severity_number = None;
    for filter in &plan.filters {
        match filter.field.as_str() {
            "severity_match" if severity_any => {}
            "severity_text" | "severity" | "level" if severity_any => severity_text = Some(filter),
            "severity_number" if severity_any => severity_number = Some(filter),
            "device_id" | "uid" | "source_device_uid" if dataset.raw_table == "events" => {
                predicates.push(event_device_identity_filter_sql(filter, table, bounds)?)
            }
            _ => predicates.push(filter_sql(plan, filter)?),
        }
    }
    if severity_any {
        predicates.push(logs_severity_any_sql(severity_text, severity_number)?);
    }
    Ok(predicates)
}

fn logs_severity_match_any(plan: &QueryPlan) -> bool {
    plan.filters.iter().any(|filter| {
        filter.field == "severity_match"
            && matches!(filter.op, crate::parser::FilterOp::Eq)
            && matches!(filter.value.as_scalar(), Ok("any"))
    })
}

/// The log cards group rows by `serviceradar_log_severity_bucket`, where
/// recognized text is authoritative and the number only speaks for a row whose
/// text is absent or unrecognized. `severity_match:any` selects the same rows,
/// so it is not a plain OR of the two lists (query/logs/filters.rs).
fn logs_severity_any_sql(text: Option<&Filter>, number: Option<&Filter>) -> Result<String> {
    use crate::parser::FilterOp;
    let (Some(text), Some(number)) = (text, number) else {
        return Err(ServiceError::InvalidRequest(
            "severity_match:any requires severity and severity_number filters".into(),
        ));
    };
    if !matches!(text.op, FilterOp::In) || !matches!(number.op, FilterOp::In) {
        return Err(ServiceError::InvalidRequest(
            "severity_match:any requires IN-list filters".into(),
        ));
    }
    let texts = list_values(text)?
        .iter()
        .map(|value| value.to_lowercase())
        .collect::<Vec<_>>();
    let numbers = severity_numbers(list_values(number)?)?;
    Ok(format!(
        "(LOWER(severity_text) IN ({}) OR ((severity_text IS NULL OR LOWER(severity_text) NOT IN ({})) AND severity_number IN ({})))",
        literal_list(texts.iter().map(String::as_str)),
        literal_list(super::logs::RECOGNIZED_SEVERITY_TEXTS.iter().copied()),
        numbers
    ))
}

fn severity_numbers(values: &[String]) -> Result<String> {
    Ok(values
        .iter()
        .map(|value| value.parse::<i32>().map(|n| n.to_string()))
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(|_| ServiceError::InvalidRequest("severity_number list must be integers".into()))?
        .join(", "))
}

/// `severity:` / `level:` are the log's severity text, compared without regard
/// to case as CNPG does (`lower(severity_text)`, ILIKE).
fn logs_severity_text_filter_sql(filter: &Filter) -> Result<String> {
    use crate::parser::FilterOp;
    let column = "LOWER(severity_text)";
    Ok(match filter.op {
        FilterOp::Eq | FilterOp::NotEq | FilterOp::Like | FilterOp::NotLike => {
            let op = match filter.op {
                FilterOp::Eq => "=",
                FilterOp::NotEq => "!=",
                FilterOp::Like => "LIKE",
                _ => "NOT LIKE",
            };
            format!(
                "{column} {op} {}",
                sql_literal(&filter.value.as_scalar()?.to_lowercase())
            )
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = list_values(filter)?
                .iter()
                .map(|value| value.to_lowercase())
                .collect::<Vec<_>>();
            let op = if matches!(filter.op, FilterOp::In) {
                "IN"
            } else {
                "NOT IN"
            };
            format!(
                "{column} {op} ({})",
                literal_list(values.iter().map(String::as_str))
            )
        }
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported operator for text filter: {:?}",
                filter.op
            )));
        }
    })
}

/// `device_id:` on logs. A log row carries no device uid; CNPG resolves the
/// uid to the addresses and names the inventory knows and matches the syslog
/// `source` / `source_ip` columns against them, with uncorrelated subqueries so
/// each is evaluated once (query/logs/metadata.rs). The same eight lookups run
/// here through the JDBC catalog. An interface's addresses are a PostgreSQL
/// array, which the catalog cannot carry, so that one reads the view CNPG
/// unnests them into.
fn logs_device_identity_filter_sql(filter: &Filter) -> Result<String> {
    let (values, negate) = exact_values(filter, &filter.field)?;
    let clauses = values
        .into_iter()
        .map(|value| {
            let uid = sql_literal(value);
            let device = |column: &str| {
                format!(
                    "SELECT d.{column} FROM {CNPG_CATALOG}.ocsf_devices d WHERE (d.uid = {uid} OR d.uid_alt = {uid}) AND d.{column} IS NOT NULL"
                )
            };
            let identifiers = format!(
                "SELECT di.identifier_value FROM {CNPG_CATALOG}.device_identifiers di WHERE di.device_id = {uid} AND di.identifier_type IN ('ip', 'hostname') AND di.identifier_value IS NOT NULL"
            );
            let interface_addresses = format!(
                "SELECT ia.ip FROM {CNPG_CATALOG}.device_interface_addresses_catalog ia WHERE ia.device_id = {uid}"
            );
            let interface_device_ip = format!(
                "SELECT di_if.device_ip FROM {CNPG_CATALOG}.discovered_interfaces di_if WHERE di_if.device_id = {uid} AND di_if.device_ip IS NOT NULL"
            );
            format!(
                "source_ip IN ({ip}) OR source IN ({ip}) OR source IN ({hostname}) OR source IN ({name}) OR source_ip IN ({identifiers}) OR source IN ({identifiers}) OR source_ip IN ({interface_addresses}) OR source_ip IN ({interface_device_ip})",
                ip = device("ip"),
                hostname = device("hostname"),
                name = device("name"),
            )
        })
        .collect();
    Ok(any_of(clauses, negate))
}

// The columns CNPG compares with `apply_text_filter!` (query/logs/filters.rs,
// query/events/filters.rs).
const LOG_TEXT_FILTER_FIELDS: &[&str] = &[
    "trace_id",
    "span_id",
    "service_name",
    "service_version",
    "source",
    "source_ip",
    "event_name",
    "body",
    "ingest_identity",
    "ingest_agent_id",
    "ingest_partition",
];
const EVENT_TEXT_FILTER_FIELDS: &[&str] = &[
    "activity_name",
    "severity",
    "message",
    "log_name",
    "log_provider",
    "log_level",
    "status",
    "trace_id",
    "span_id",
];

/// Filter fields whose meaning is more than one warehouse column. `None` means
/// the field is an ordinary column and the generic comparison applies.
fn dataset_filter_sql(dataset: Dataset, filter: &Filter) -> Result<Option<String>> {
    let field = filter.field.as_str();
    Ok(Some(match (dataset.raw_table, field) {
        ("logs", "severity_text" | "severity" | "level") => logs_severity_text_filter_sql(filter)?,
        ("logs", "device_id" | "uid") => logs_device_identity_filter_sql(filter)?,
        ("events", "event_type") => event_exact_filter_sql(filter, EVENT_TYPE_PATHS, field)?,
        ("events", "finding_uid") => {
            event_exact_filter_sql(filter, EVENT_FINDING_UID_PATHS, field)?
        }
        ("events", "finding_rollup") => event_finding_rollup_filter_sql(filter)?,
        ("events", "source" | "source_type" | "addon_id") => event_source_filter_sql(filter)?,
        ("events", "device_uid_exact") => {
            event_exact_filter_sql(filter, EVENT_DEVICE_UID_EXACT_PATHS, field)?
        }
        ("events", "service_radar_device_uid") => {
            event_exact_filter_sql(filter, EVENT_SERVICE_RADAR_DEVICE_UID_PATHS, field)?
        }
        ("events", "agent_id") => event_exact_filter_sql(filter, EVENT_AGENT_ID_PATHS, field)?,
        ("events", "host_id" | "hostname") => {
            event_exact_filter_sql(filter, EVENT_HOST_PATHS, "host_id")?
        }
        ("logs", _) if LOG_TEXT_FILTER_FIELDS.contains(&field) => {
            text_filter_sql(field, filter, true)?
        }
        ("events", _) if EVENT_TEXT_FILTER_FIELDS.contains(&field) => {
            text_filter_sql(field, filter, true)?
        }
        _ => return Ok(None),
    }))
}

const CNPG_CATALOG: &str = "cnpg_platform.platform";

#[derive(Clone, Copy, PartialEq, Eq)]
enum CatalogJoin {
    Devices,
    InputInterface,
    OutputInterface,
    Exporter,
    SrcGeo,
    DstGeo,
}

impl CatalogJoin {
    fn sql(self) -> &'static str {
        match self {
            Self::Devices => {
                "LEFT JOIN cnpg_platform.platform.ocsf_devices AS dev ON dev.uid = f.device_uid"
            }
            Self::InputInterface => {
                "LEFT JOIN cnpg_platform.platform.netflow_interface_cache AS in_if ON in_if.sampler_address = f.sampler_address AND in_if.if_index = f.input_snmp"
            }
            Self::OutputInterface => {
                "LEFT JOIN cnpg_platform.platform.netflow_interface_cache AS out_if ON out_if.sampler_address = f.sampler_address AND out_if.if_index = f.output_snmp"
            }
            // `sampler_address` is the cache's primary key, so this join can
            // never count a flow twice.
            Self::Exporter => {
                "LEFT JOIN cnpg_platform.platform.netflow_exporter_cache AS exp ON exp.sampler_address = f.sampler_address"
            }
            // Country is never stored on the flow row, on either backend: GeoIP
            // answers change and expire, so it is resolved against the cache at
            // query time. An expired entry is ignored, as it is on CNPG.
            Self::SrcGeo => {
                "LEFT JOIN cnpg_platform.platform.ip_geo_enrichment_cache AS src_geo ON src_geo.ip = f.src_endpoint_ip AND (src_geo.expires_at IS NULL OR src_geo.expires_at > UTC_TIMESTAMP())"
            }
            Self::DstGeo => {
                "LEFT JOIN cnpg_platform.platform.ip_geo_enrichment_cache AS dst_geo ON dst_geo.ip = f.dst_endpoint_ip AND (dst_geo.expires_at IS NULL OR dst_geo.expires_at > UTC_TIMESTAMP())"
            }
        }
    }
}

fn catalog_joins(plan: &QueryPlan, dataset: Dataset) -> Result<Vec<CatalogJoin>> {
    // pid/comm and prefix tags are persisted warehouse columns, read off the
    // observation row. The JDBC catalog carries live device identity and the
    // exporter interface names/speeds the warehouse row does not store.
    // On the event tables `hostname` is a document filter, not a device join.
    let wants_device =
        dataset.raw_table != "events" && plan_mentions(plan, &["hostname", "device_name"]);
    let wants_input_interface = plan_mentions(plan, &["in_if_name", "in_if_speed_bps"]);
    let wants_output_interface = plan_mentions(plan, &["out_if_name", "out_if_speed_bps"]);
    let wants_exporter = plan_mentions(plan, &["exporter_name"]);
    let wants_src_geo = plan_mentions(plan, &["src_country_iso2", "src_country"]);
    let wants_dst_geo = plan_mentions(plan, &["dst_country_iso2", "dst_country"]);
    if !wants_device
        && !wants_input_interface
        && !wants_output_interface
        && !wants_exporter
        && !wants_src_geo
        && !wants_dst_geo
    {
        return Ok(Vec::new());
    }
    if dataset.raw_table != "ocsf_network_activity" {
        return Err(ServiceError::NotImplemented(
            "starrocks_catalog_unsupported_entity".to_string(),
        ));
    }
    let mut joins = Vec::new();
    if wants_device {
        joins.push(CatalogJoin::Devices);
    }
    if wants_input_interface {
        joins.push(CatalogJoin::InputInterface);
    }
    if wants_output_interface {
        joins.push(CatalogJoin::OutputInterface);
    }
    if wants_exporter {
        joins.push(CatalogJoin::Exporter);
    }
    if wants_src_geo {
        joins.push(CatalogJoin::SrcGeo);
    }
    if wants_dst_geo {
        joins.push(CatalogJoin::DstGeo);
    }
    Ok(joins)
}

fn plan_mentions(plan: &QueryPlan, fields: &[&str]) -> bool {
    let hit = |name: &str| {
        let name = name.to_ascii_lowercase();
        fields.iter().any(|field| name == *field)
    };
    if plan.order.iter().any(|order| hit(&order.field))
        || plan
            .downsample
            .as_ref()
            .is_some_and(|d| d.series.as_deref().is_some_and(hit))
    {
        return true;
    }
    if plan.filters.iter().any(|filter| hit(&filter.field)) {
        return true;
    }
    if let Some(stats) = plan.stats.as_ref() {
        let raw = stats.as_raw().to_ascii_lowercase();
        if fields.iter().any(|field| {
            raw.split(|c: char| !c.is_ascii_alphanumeric() && c != '_')
                .any(|tok| tok == *field)
        }) {
            return true;
        }
    }
    false
}

fn from_with_catalog_joins(table: &str, joins: &[CatalogJoin]) -> String {
    if joins.is_empty() {
        return table.to_string();
    }
    let mut from = format!("{table} AS f");
    for join in joins {
        from.push(' ');
        from.push_str(join.sql());
    }
    from
}

fn stats_select(plan: &QueryPlan, dataset: Dataset) -> Result<(String, String)> {
    let Some(stats) = plan.stats.as_ref() else {
        let select = if dataset.raw_table.contains("ocsf_network_activity") {
            flow_row_select(plan)?
        } else {
            "*".to_string()
        };
        return Ok((select, String::new()));
    };

    let mut select = Vec::new();
    for (function, field, alias) in parse_aggregations(stats)? {
        select.push(starrocks_agg(plan, function, field, alias)?);
    }
    if let Some(group_cols) = stats_group_by(Some(stats)) {
        let mut rewritten = Vec::new();
        for col in group_cols.split(',') {
            let col = col.trim();
            if col.is_empty() {
                continue;
            }
            let expr = field_sql(plan, col)?;
            select.push(format!("{expr} AS {alias}", alias = group_alias(col)));
            rewritten.push(expr);
        }
        Ok((
            select.join(", "),
            format!(" GROUP BY {}", rewritten.join(", ")),
        ))
    } else {
        Ok((select.join(", "), String::new()))
    }
}

fn group_alias(col: &str) -> String {
    let trimmed = col.trim();
    if let Some(rest) = trimmed.strip_prefix("src_cidr:") {
        return format!("src_cidr_{rest}");
    }
    if let Some(rest) = trimmed.strip_prefix("dst_cidr:") {
        return format!("dst_cidr_{rest}");
    }
    match trimmed {
        "dst_port" => "dst_endpoint_port".to_string(),
        "src_port" => "src_endpoint_port".to_string(),
        "app" => "app".to_string(),
        "tcp_flag" => "tcp_flags_label".to_string(),
        "duration" => "duration_bucket".to_string(),
        // `partition` is reserved in StarRocks and cannot stand as a bare alias.
        "partition" => "flow_partition".to_string(),
        other => other.to_string(),
    }
}

fn ipv4_prefix_sql(column: &str, prefix: &str) -> String {
    match prefix {
        "8" => format!("CONCAT(SPLIT_PART({column}, '.', 1), '.0.0.0')"),
        "16" => {
            format!(
                "CONCAT(SPLIT_PART({column}, '.', 1), '.', SPLIT_PART({column}, '.', 2), '.0.0')"
            )
        }
        "24" => format!(
            "CONCAT(SPLIT_PART({column}, '.', 1), '.', SPLIT_PART({column}, '.', 2), '.', SPLIT_PART({column}, '.', 3), '.0')"
        ),
        _ => column.to_string(),
    }
}

/// The rollup a bucketed query may read instead of the raw table.
///
/// Only the downsample path qualifies: a bucket is already a coarsening, so an
/// hour-grained source is a difference of degree, while a scalar `stats` total
/// has no bucket to absorb it. The remaining conditions keep every stored
/// aggregate exactly re-aggregatable into the requested bucket.
///
/// The window bounds are not hour-aligned, so `time_predicate` widens them to
/// whole hours and each edge bucket therefore carries the whole hour it falls
/// in, including traffic just outside the request. That is the hour grain this
/// query is scored on, so the raw table is read the same way and the freshness
/// gate cannot change the answer; the edges are never backfilled from another
/// store.
fn hourly_rollup(plan: &QueryPlan, dataset: Dataset) -> Option<HourlyRollup> {
    let rollup = dataset.hourly?;
    let downsample = plan.downsample.as_ref()?;
    if plan.stats.is_some() {
        return None;
    }
    if downsample.bucket_seconds < HOURLY_ROLLUP_GRAIN_SECONDS
        || downsample.bucket_seconds % HOURLY_ROLLUP_GRAIN_SECONDS != 0
    {
        return None;
    }
    let dimension = |field: &str| {
        let field = field.to_ascii_lowercase();
        rollup.dimensions.iter().any(|name| *name == field)
    };
    if plan.filters.iter().any(|filter| !dimension(&filter.field)) {
        return None;
    }
    if downsample.series.as_deref().is_some_and(|s| !dimension(s)) {
        return None;
    }
    rollup_agg(rollup, downsample, default_value_field(dataset)).map(|_| rollup)
}

/// Re-aggregates a stored hourly aggregate into the requested bucket. `None`
/// means the stored aggregate cannot reproduce the requested one, so the caller
/// stays on the raw table.
fn rollup_agg(
    rollup: HourlyRollup,
    downsample: &crate::parser::DownsampleSpec,
    default_field: &str,
) -> Option<String> {
    use crate::parser::DownsampleAgg::{Avg, Count, Max, Min, Rate, RateSum, Sum};

    let field = downsample.value_field.as_deref().unwrap_or(default_field);
    match rollup.table {
        "ocsf_network_activity_hourly" => match (downsample.agg, field) {
            (
                Sum | Rate | RateSum,
                "bytes_total" | "packets_total" | "bytes_in" | "bytes_out" | "packets_in"
                | "packets_out",
            ) => Some(format!("SUM({field})")),
            (Count, _) => Some("SUM(flow_count)".to_string()),
            _ => None,
        },
        "timeseries_metrics_hourly" => match (downsample.agg, field) {
            // No Rate here: `value` holds cumulative counters, and an hourly
            // average of a counter cannot give back the delta between two
            // samples. Rate stays on the raw table (`counter_rate_sql`).
            (Sum, "value") => Some("SUM(avg_value * sample_count)".to_string()),
            (Avg, "value") => {
                Some("SUM(avg_value * sample_count) / NULLIF(SUM(sample_count), 0)".to_string())
            }
            (Min, "value") => Some("MIN(min_value)".to_string()),
            (Max, "value") => Some("MAX(max_value)".to_string()),
            (Count, _) => Some("SUM(sample_count)".to_string()),
            _ => None,
        },
        _ => None,
    }
}

/// Hour-of-week profiles, the StarRocks half of the CNPG `profile_hour_of_week`
/// and `profile_hour_of_week_peak` routes (`timeseries_metrics.rs`).
///
/// Two deliberate differences from the CNPG builder, both forced by the engine:
/// percentiles are `PERCENTILE_APPROX` rather than exact `percentile_cont`, and
/// the row is flat columns rather than a `jsonb` payload -- the MySQL protocol
/// would hand a JSON object back as an opaque string, and both consumers
/// already read a flat row (`Map.get(row, "payload", row)`).
///
/// A profile always reads the raw table, on both entry points. It re-derives
/// the hourly grain itself, so `timeseries_metrics_hourly` could in principle
/// serve it -- but the view groups by `(bucket, device_id, metric_type,
/// metric_name)` and every shipped caller asks for `series:uid`, a column the
/// view does not carry. There is no query that reaches this route and can be
/// answered from the view, so there is no rollup branch to keep in step with
/// the freshness gate.
fn profile_sql(plan: &QueryPlan, dataset: Dataset, database: &str) -> Result<TranslateResponse> {
    let spec = ProfileSpec::parse(plan)?;

    if dataset.raw_table != "timeseries_metrics" {
        return Err(ServiceError::NotImplemented(format!(
            "starrocks_unsupported_stats: {} is not a metric dataset",
            dataset.raw_table
        )));
    }

    let Some(range) = plan.time_range.as_ref() else {
        return Err(ServiceError::InvalidRequest(
            "profile_hour_of_week requires an explicit time range".into(),
        ));
    };

    let source = format!("{database}.{}", dataset.raw_table);
    let bucket = format!("date_trunc('hour', `{}`)", dataset.time_column);
    // One sample per (hour, device, metric_type, metric_name): the grain the
    // profile scores. Grouping by (device, hour) alone would collapse every
    // metric a device reports into one cell.
    let sample = if spec.peak {
        "MAX(`value`)"
    } else {
        "AVG(`value`)"
    };
    let group = "\n  GROUP BY 1, 2, 3, 4";

    let mut clauses = vec!["device_id IS NOT NULL".to_string()];
    if let Some(scope) = dataset.scope {
        clauses.push(format!("({scope})"));
    }
    // The window bounds are `now`-relative and so never hour-aligned, but a
    // profile scores whole hours: read verbatim they drop the hour holding
    // `start` and the hour holding `end`, answering the same query differently
    // than CNPG, whose builder widens for the same reason
    // (`hourly_cagg_*_bound_clause`).
    let time_column = format!("`{}`", dataset.time_column);
    clauses.push(format!(
        "{time_column} >= '{start}'",
        start = floor_hour(range.start).to_rfc3339_opts(SecondsFormat::Secs, true)
    ));
    clauses.push(format!(
        "{time_column} < '{end}'",
        end = exclusive_hour_end(range.end).to_rfc3339_opts(SecondsFormat::Secs, true)
    ));
    for filter in &plan.filters {
        if filter.field.eq_ignore_ascii_case("timezone") {
            continue;
        }
        clauses.push(filter_sql(plan, filter)?);
    }
    let where_sql = format!("WHERE {}", clauses.join(" AND "));

    let tz = sql_literal(&spec.timezone);
    let local = format!(
        "CONVERT_TZ({bucket_expr}, 'UTC', {tz})",
        bucket_expr = "bucket"
    );
    let limit = plan.limit.max(1);
    let offset = plan.offset.max(0);

    // StarRocks DAYOFWEEK is 1=Sunday; the profile contract is Postgres EXTRACT(DOW), 0=Sunday.
    let head = format!(
        r#"WITH hourly AS (
  SELECT device_id AS series, metric_type, metric_name, {bucket} AS bucket, {sample} AS sample_value
  FROM {source}
  {where_sql}{group}
),
local_hourly AS (
  SELECT series, bucket, sample_value, DAYOFWEEK({local}) - 1 AS dow, HOUR({local}) AS hod
  FROM hourly
),
ranked AS (
  SELECT series, bucket, sample_value, dow, hod,
    ROW_NUMBER() OVER (PARTITION BY series ORDER BY bucket DESC) AS series_rank,
    ROW_NUMBER() OVER (PARTITION BY series, dow, hod ORDER BY bucket DESC) AS cell_rank
  FROM local_hourly
),
latest AS (
  SELECT series, bucket, sample_value, dow, hod FROM ranked WHERE series_rank = 1
)"#
    );

    let sql = if spec.peak {
        format!(
            r#"{head},
profile_values AS (
  SELECT h.series, h.hod, h.bucket, h.sample_value
  FROM local_hourly h
  JOIN latest l ON l.series = h.series AND l.hod = h.hod
  WHERE h.bucket <> l.bucket
),
prior_values AS (
  SELECT h.series, h.sample_value
  FROM local_hourly h
  JOIN latest l ON l.series = h.series
  WHERE h.bucket <> l.bucket
),
cell_profile AS (
  SELECT series, hod, COUNT(*) AS bucket_count,
    PERCENTILE_APPROX(sample_value, 0.5) AS center,
    PERCENTILE_APPROX(sample_value, 0.05) AS p05,
    PERCENTILE_APPROX(sample_value, 0.95) AS p95
  FROM profile_values GROUP BY 1, 2
),
series_prior AS (
  SELECT series,
    PERCENTILE_APPROX(sample_value, 0.05) AS prior_p05,
    PERCENTILE_APPROX(sample_value, 0.95) AS prior_p95
  FROM prior_values GROUP BY 1
)
SELECT l.series AS series, l.dow AS dow, l.hod AS hod, l.sample_value AS sample_value,
  l.bucket AS bucket, c.bucket_count AS bucket_count, c.center AS center,
  c.p05 AS p05, c.p95 AS p95, c.p95 AS q95,
  (c.p95 - c.p05) * 0.30398 AS scale,
  (p.prior_p95 - p.prior_p05) * 0.30398 AS prior_scale
FROM latest l
LEFT JOIN cell_profile c ON c.series = l.series AND c.hod = l.hod
LEFT JOIN series_prior p ON p.series = l.series
{order}
LIMIT {limit} OFFSET {offset}"#,
            order = profile_order_sql(plan, "c")
        )
    } else {
        let selected = if spec.full { "profile_rows" } else { "latest" };
        format!(
            r#"{head},
profile_rows AS (
  SELECT series, bucket, sample_value, dow, hod FROM ranked WHERE cell_rank = 1
),
profile_keys AS (
  SELECT DISTINCT series, dow, hod FROM {selected}
),
mean_profile AS (
  SELECT h.series, h.dow, h.hod, COUNT(*) AS bucket_count,
    SUM(h.sample_value) AS bucket_sum,
    SUM(h.sample_value * h.sample_value) AS bucket_sum_sq
  FROM local_hourly h
  JOIN profile_keys k ON k.series = h.series AND k.dow = h.dow AND k.hod = h.hod
  GROUP BY 1, 2, 3
),
robust_values AS (
  SELECT h.series, h.dow, h.hod, h.sample_value
  FROM local_hourly h
  JOIN profile_keys k ON k.series = h.series AND k.dow = h.dow AND k.hod = h.hod
  LEFT JOIN latest l ON l.series = h.series AND l.bucket = h.bucket
  WHERE l.bucket IS NULL
),
robust_base AS (
  SELECT series, dow, hod,
    PERCENTILE_APPROX(sample_value, 0.5) AS center,
    PERCENTILE_APPROX(sample_value, 0.05) AS p05,
    PERCENTILE_APPROX(sample_value, 0.95) AS p95
  FROM robust_values GROUP BY 1, 2, 3
),
robust_profile AS (
  SELECT b.series, b.dow, b.hod, b.center, COUNT(v.sample_value) AS robust_bucket_count,
    PERCENTILE_APPROX(ABS(v.sample_value - b.center), 0.5) AS mad, b.p05, b.p95
  FROM robust_base b
  JOIN robust_values v ON v.series = b.series AND v.dow = b.dow AND v.hod = b.hod
  GROUP BY b.series, b.dow, b.hod, b.center, b.p05, b.p95
)
SELECT l.series AS series, l.dow AS dow, l.hod AS hod, l.sample_value AS sample_value,
  l.bucket AS bucket, p.bucket_count AS bucket_count,
  COALESCE(r.robust_bucket_count, 0) AS robust_bucket_count,
  p.bucket_sum AS bucket_sum, p.bucket_sum_sq AS bucket_sum_sq,
  r.center AS center, r.mad AS mad, r.p05 AS p05, r.p95 AS p95
FROM {selected} l
JOIN mean_profile p ON p.series = l.series AND p.dow = l.dow AND p.hod = l.hod
LEFT JOIN robust_profile r ON r.series = l.series AND r.dow = l.dow AND r.hod = l.hod
{order}
LIMIT {limit} OFFSET {offset}"#,
            order = profile_order_sql(plan, "p")
        )
    };

    Ok(TranslateResponse {
        sql,
        params: vec![
            BindParam::timestamptz(range.start),
            BindParam::timestamptz(range.end),
        ],
        pagination: PaginationMeta {
            next_cursor: None,
            prev_cursor: None,
            limit: Some(plan.limit),
        },
        viz: None,
    })
}

/// Mirrors `timeseries_metrics::build_profile_order_clause`: a caller's sort
/// decides which cells survive `limit:`, not merely how a page is ordered, so
/// dropping it returns a different set of rows than CNPG for the same query.
/// The profile-row identity is appended last because OFFSET pagination without
/// it can overlap or skip rows.
fn profile_order_sql(plan: &QueryPlan, bucket_count_alias: &str) -> String {
    use crate::parser::OrderDirection;

    let mut parts = Vec::new();
    for clause in &plan.order {
        let column = match clause.field.as_str() {
            "series" | "series_key" => "l.series",
            "dow" => "l.dow",
            "hod" => "l.hod",
            "bucket" => "l.bucket",
            "sample_value" => "l.sample_value",
            "bucket_count" => {
                if bucket_count_alias == "c" {
                    "c.bucket_count"
                } else {
                    "p.bucket_count"
                }
            }
            _ => continue,
        };

        let dir = match clause.direction {
            OrderDirection::Asc => "ASC",
            OrderDirection::Desc => "DESC",
        };
        parts.push(format!("{column} {dir}"));
    }

    for (field, column) in [("series", "l.series"), ("dow", "l.dow"), ("hod", "l.hod")] {
        if !plan.order.iter().any(|clause| {
            (field == "series" && matches!(clause.field.as_str(), "series" | "series_key"))
                || clause.field == field
        }) {
            parts.push(format!("{column} ASC"));
        }
    }

    format!("\nORDER BY {}", parts.join(", "))
}

fn floor_hour(value: chrono::DateTime<Utc>) -> chrono::DateTime<Utc> {
    value
        .with_minute(0)
        .and_then(|value| value.with_second(0))
        .and_then(|value| value.with_nanosecond(0))
        .unwrap_or(value)
}

/// Floor to the hour and add one, which is the exclusive upper bound CNPG's
/// `hourly_cagg_upper_bound_clause` emits: `time_bucket('1 hour', end) +
/// INTERVAL '1 hour'`, unconditionally. This is deliberately not a ceiling --
/// leaving an already-aligned end alone would exclude the bucket CNPG includes,
/// so the two backends would resolve `latest` to different hours for the same
/// query.
fn exclusive_hour_end(value: chrono::DateTime<Utc>) -> chrono::DateTime<Utc> {
    floor_hour(value) + chrono::Duration::hours(1)
}

struct ProfileSpec {
    peak: bool,
    full: bool,
    timezone: String,
}

impl ProfileSpec {
    fn parse(plan: &QueryPlan) -> Result<Self> {
        let raw = plan
            .stats
            .as_ref()
            .map(|stats| stats.as_raw().trim().to_ascii_lowercase())
            .unwrap_or_default();

        let (verb, rest) = raw.split_once('(').ok_or_else(|| {
            ServiceError::InvalidRequest("profile_hour_of_week requires a field".into())
        })?;
        let field = rest.trim_end_matches(')').trim();
        if field != "value" {
            return Err(ServiceError::InvalidRequest(format!(
                "{} only supports value",
                verb.trim()
            )));
        }

        let verb = verb.trim();
        let timezone = plan
            .filters
            .iter()
            .find(|filter| filter.field.eq_ignore_ascii_case("timezone"))
            .and_then(|filter| filter.value.as_scalar().ok())
            .map(super::timeseries_metrics::normalize_profile_timezone)
            .unwrap_or_else(|| super::timeseries_metrics::normalize_profile_timezone(""));

        Ok(Self {
            peak: verb == "profile_hour_of_week_peak",
            full: verb == "profile_hour_of_week_full",
            timezone,
        })
    }
}

/// A `profile_hour_of_week[_peak]` query is a profile aggregation, not a
/// downsample, even though its `bucket:1h` clause sets `plan.downsample`.
/// Both dialects route on this one predicate: if they disagreed, one branch
/// would build a profile while the other answered a different question.
pub(crate) fn is_profile_stats(plan: &QueryPlan) -> bool {
    plan.stats.as_ref().is_some_and(|stats| {
        stats
            .as_raw()
            .trim_start()
            .to_ascii_lowercase()
            .starts_with("profile_hour_of_week")
    })
}

/// The column a bucketed query aggregates when it names none. Each dataset
/// stores its measurement under a different name, so a single default silently
/// asks the wrong table for a column it does not have.
fn default_value_field(dataset: Dataset) -> &'static str {
    match dataset.raw_table {
        "timeseries_metrics" => "value",
        _ => "bytes_total",
    }
}

fn downsample_sql(
    plan: &QueryPlan,
    dataset: Dataset,
    downsample: &crate::parser::DownsampleSpec,
    from: &str,
    where_sql: &str,
    time: &str,
    rollup: Option<HourlyRollup>,
) -> Result<String> {
    let bucket = downsample.bucket_seconds.max(1);
    let default_field = default_value_field(dataset);
    if is_counter_rate(dataset, downsample) {
        return counter_rate_sql(plan, downsample, from, where_sql, time, default_field);
    }
    let agg = match rollup.and_then(|rollup| rollup_agg(rollup, downsample, default_field)) {
        Some(agg) => agg,
        None => {
            let value = aggregate_field_sql(
                plan,
                downsample.value_field.as_deref().unwrap_or(default_field),
            )?;
            match downsample.agg {
                crate::parser::DownsampleAgg::Sum => format!("SUM({value})"),
                crate::parser::DownsampleAgg::Avg => format!("AVG({value})"),
                crate::parser::DownsampleAgg::Min => format!("MIN({value})"),
                crate::parser::DownsampleAgg::Max => format!("MAX({value})"),
                crate::parser::DownsampleAgg::Count => "COUNT(*)".to_string(),
                // Only flows reach this arm (`is_counter_rate` takes the metric
                // tables). A flow row is already a delta, so its total is the sum.
                crate::parser::DownsampleAgg::Rate | crate::parser::DownsampleAgg::RateSum => {
                    format!("SUM({value})")
                }
            }
        }
    };
    let series = match downsample.series.as_deref() {
        Some(field) => format!("CAST({} AS STRING)", field_sql(plan, field)?),
        None => "'all'".to_string(),
    };
    let body = format!(
        "SELECT time_slice({time}, INTERVAL {bucket} SECOND) AS timestamp, {series} AS series, {agg} AS value FROM {from}{where_sql} GROUP BY 1, 2"
    );
    Ok(finalize_downsample(plan, "", &body))
}

/// Orders and limits a downsample. `body` is the bucketing `SELECT`, ending
/// after its `GROUP BY 1, 2`; `with` is any CTE prefix it reads from, kept at
/// the top level so the wrapped form can still see it.
///
/// A chart is always returned oldest bucket first. When `limit:` is smaller
/// than the number of buckets in the window, `sort:<time>:desc` says which end
/// survives: the newest. That is CNPG's rule (`downsample_keeps_newest`), and
/// every sysmon chart sends it. Ignoring it kept the OLDEST buckets, so a
/// 30-day chart capped at 300 points showed its first 300 hours and stopped.
/// The newest are therefore cut descending inside a derived table and sorted
/// ascending on the way out.
fn finalize_downsample(plan: &QueryPlan, with: &str, body: &str) -> String {
    let limit = plan.limit.max(1);
    let offset = plan.offset.max(0);
    let newest = plan
        .order
        .first()
        .is_some_and(|clause| matches!(clause.direction, crate::parser::OrderDirection::Desc));
    if newest {
        format!(
            "{with}SELECT timestamp, series, value FROM ({body} ORDER BY 1 DESC, 2 ASC \
LIMIT {limit} OFFSET {offset}) windowed ORDER BY 1 ASC, 2 ASC"
        )
    } else {
        format!("{with}{body} ORDER BY 1 ASC, 2 ASC LIMIT {limit} OFFSET {offset}")
    }
}

/// `timeseries_metrics` stores SNMP-style cumulative counters, so a rate over
/// it is the change between consecutive samples, never an aggregate of the
/// stored values. Summing them draws the counter itself: a 1 Gbit/s port whose
/// counter has reached 450 GB reads as "450 GB/s".
fn is_counter_rate(dataset: Dataset, downsample: &crate::parser::DownsampleSpec) -> bool {
    use crate::parser::DownsampleAgg::{Rate, RateSum};
    dataset.raw_table == "timeseries_metrics" && matches!(downsample.agg, Rate | RateSum)
}

/// The StarRocks half of the CNPG rate query (`downsample/sql.rs`), and meant
/// to agree with it sample for sample:
///
/// * the previous sample is found per physical counter -- gateway, agent,
///   metric type, metric name, series key -- not per display series, so one
///   display series collapsing several counters never subtracts one device's
///   counter from another's;
/// * the rate is the delta over the real elapsed time between the two samples;
/// * a decrease is a wrap when adding 2^32 gives a rate a 32-bit counter could
///   produce, and otherwise a reset, which yields no rate rather than a huge
///   negative or positive one;
/// * a display bucket combines its per-sample rates with AVG (`rate`) or SUM
///   (`rate_sum`).
///
/// One CNPG rule has no equivalent: the producer-supplied
/// `max_counter_rate_per_second` ceiling lives in a `metadata` column the
/// warehouse table does not carry. Without it CNPG never adds the 2^64 modulus
/// either, so the two agree wherever that ceiling is absent.
fn counter_rate_sql(
    plan: &QueryPlan,
    downsample: &crate::parser::DownsampleSpec,
    from: &str,
    where_sql: &str,
    time: &str,
    default_field: &str,
) -> Result<String> {
    const WRAP_32: &str = "4294967296";
    const COUNTER: &str =
        "gateway_id, COALESCE(agent_id, ''), metric_type, metric_name, series_key";

    let value = aggregate_field_sql(
        plan,
        downsample.value_field.as_deref().unwrap_or(default_field),
    )?;
    let series = match downsample.series.as_deref() {
        Some(field) => format!("CAST({} AS STRING)", field_sql(plan, field)?),
        None => "'all'".to_string(),
    };
    let combine = match downsample.agg {
        crate::parser::DownsampleAgg::RateSum => "SUM",
        _ => "AVG",
    };
    let bucket = downsample.bucket_seconds.max(1);
    let elapsed = "NULLIF(milliseconds_diff(ts, prev_ts) / 1000.0, 0)";
    let wrapped = format!("(v + {WRAP_32} - prev_v) / {elapsed}");

    let with = format!(
        "WITH ordered AS (\
SELECT {time} AS ts, {series} AS series, {value} AS v, counter_width, \
LAG({value}) OVER (PARTITION BY {COUNTER} ORDER BY {time}) AS prev_v, \
LAG({time}) OVER (PARTITION BY {COUNTER} ORDER BY {time}) AS prev_ts \
FROM {from}{where_sql}), \
rated AS (\
SELECT ts, series, CASE \
WHEN v >= prev_v THEN (v - prev_v) / {elapsed} \
WHEN counter_width = 32 AND {wrapped} <= {WRAP_32} THEN {wrapped} \
WHEN prev_v < {WRAP_32} AND {wrapped} <= {WRAP_32} THEN {wrapped} \
ELSE NULL END AS rate_value \
FROM ordered WHERE prev_v IS NOT NULL) "
    );
    let body = format!(
        "SELECT time_slice(ts, INTERVAL {bucket} SECOND) AS timestamp, series, \
{combine}(rate_value) AS value FROM rated WHERE rate_value IS NOT NULL GROUP BY 1, 2"
    );
    Ok(finalize_downsample(plan, &with, &body))
}

fn stats_group_by(stats: Option<&crate::parser::StatsSpec>) -> Option<String> {
    let raw = stats?.as_raw();
    let lowered = raw.to_ascii_lowercase();
    let idx = lowered.rfind(" by ")?;
    let cols = raw[idx + 4..].trim();
    if cols.is_empty() {
        None
    } else {
        Some(cols.to_string())
    }
}

fn parse_aggregations(stats: &crate::parser::StatsSpec) -> Result<Vec<(&str, &str, &str)>> {
    let raw = stats.as_raw();
    let lowered = raw.to_ascii_lowercase();
    let aggregates = &raw[..lowered.find(" by ").unwrap_or(raw.len())];
    aggregates
        .split(',')
        .map(|term| {
            let term = term.trim();
            let lowered = term.to_ascii_lowercase();
            let (call, alias) = lowered
                .find(" as ")
                .map(|idx| (term[..idx].trim(), term[idx + 4..].trim()))
                .ok_or_else(|| {
                    ServiceError::InvalidRequest("aggregation requires an alias".into())
                })?;
            validate_identifier(alias)?;
            let (function, argument) = call
                .split_once('(')
                .and_then(|(function, rest)| {
                    rest.strip_suffix(')')
                        .map(|arg| (function.trim(), arg.trim()))
                })
                .ok_or_else(|| ServiceError::InvalidRequest("invalid aggregation".into()))?;
            if !matches!(
                function.to_ascii_lowercase().as_str(),
                "count" | "count_distinct" | "sum" | "avg" | "min" | "max"
            ) {
                return Err(ServiceError::InvalidRequest(
                    "unsupported aggregation".into(),
                ));
            }
            let argument = if argument.is_empty() && function.eq_ignore_ascii_case("count") {
                "*"
            } else {
                argument
            };
            Ok((function, argument, alias))
        })
        .collect()
}

fn starrocks_agg(plan: &QueryPlan, function: &str, field: &str, alias: &str) -> Result<String> {
    let function = function.to_ascii_uppercase();
    let value = match (function.as_str(), field) {
        ("COUNT", "*") => "*".to_string(),
        ("COUNT" | "COUNT_DISTINCT", _) => field_sql(plan, field)?,
        _ => aggregate_field_sql(plan, field)?,
    };
    if function == "COUNT_DISTINCT" {
        Ok(format!("COUNT(DISTINCT {value}) AS {alias}"))
    } else {
        Ok(format!("{function}({value}) AS {alias}"))
    }
}

fn aggregate_field_sql(plan: &QueryPlan, field: &str) -> Result<String> {
    let value = field_sql(plan, field)?;
    if matches!(plan.entity, Entity::Flows | Entity::AttributedFlows)
        && matches!(
            field,
            "bytes_total"
                | "packets_total"
                | "bytes_in"
                | "bytes_out"
                | "packets_in"
                | "packets_out"
        )
    {
        let rate = field_sql(plan, "sampling_rate")?;
        Ok(format!(
            "(CAST(COALESCE({value}, 0) AS DOUBLE) * GREATEST(COALESCE({rate}, 1), 1))"
        ))
    } else {
        Ok(value)
    }
}

fn validate_identifier(value: &str) -> Result<()> {
    if value.is_empty()
        || !value
            .bytes()
            .enumerate()
            .all(|(i, c)| c == b'_' || c.is_ascii_alphabetic() || (i > 0 && c.is_ascii_digit()))
    {
        return Err(ServiceError::InvalidRequest(
            "invalid StarRocks identifier".into(),
        ));
    }
    Ok(())
}

fn field_sql(plan: &QueryPlan, field: &str) -> Result<String> {
    let dataset = dataset_for(&plan.entity).unwrap();
    let flow = matches!(plan.entity, Entity::Flows | Entity::AttributedFlows);
    let qualified = flow
        && (plan_mentions(plan, &["direction"])
            || filters_on_flow_cidr(plan)
            || !catalog_joins(plan, dataset)?.is_empty());
    let column = |name: &str| {
        if qualified {
            format!("f.{name}")
        } else {
            name.to_string()
        }
    };
    if flow {
        match field {
            "direction" => return Ok(column("direction")),
            "attribution_status" => {
                return Ok(format!(
                    "CASE WHEN {} IS NULL THEN 'unmatched' ELSE 'attributed' END",
                    column("pid")
                ));
            }
            "protocol_group" | "proto_group" => {
                return Ok(FLOW_PROTOCOL_GROUP_SQL.replace("protocol_num", &column("protocol_num")));
            }
            "bytes_total" => {
                return Ok(FLOW_BYTES_TOTAL_SQL
                    .replace("bytes_total", &column("bytes_total"))
                    .replace("bytes_in", &column("bytes_in"))
                    .replace("bytes_out", &column("bytes_out")));
            }
            "packets_total" => {
                return Ok(FLOW_PACKETS_TOTAL_SQL
                    .replace("packets_total", &column("packets_total"))
                    .replace("packets_in", &column("packets_in"))
                    .replace("packets_out", &column("packets_out")));
            }
            "src_ip" => return Ok(column("src_endpoint_ip")),
            "dst_ip" => return Ok(column("dst_endpoint_ip")),
            "src_port" => return Ok(column("src_endpoint_port")),
            "dst_port" => return Ok(column("dst_endpoint_port")),
            "app" => {
                return Ok(format!(
                    "COALESCE({}, 'unknown')",
                    column("dst_service_label")
                ));
            }
            "hostname" | "device_name" => return Ok("dev.hostname".into()),
            "in_if_name" => return Ok("COALESCE(in_if.if_name, 'Unknown')".into()),
            "out_if_name" => return Ok("COALESCE(out_if.if_name, 'Unknown')".into()),
            "in_if_speed_bps" => {
                return Ok("COALESCE(CAST(in_if.if_speed_bps AS STRING), 'Unknown')".into());
            }
            "out_if_speed_bps" => {
                return Ok("COALESCE(CAST(out_if.if_speed_bps AS STRING), 'Unknown')".into());
            }
            "exporter_name" => return Ok("COALESCE(exp.exporter_name, 'Unknown')".into()),
            "tcp_flags_label" | "tcp_flag" => {
                return Ok(tcp_flags_label_sql(&column("tcp_flags")));
            }
            "duration_bucket" | "duration" => {
                return Ok(duration_bucket_sql(
                    &column("start_time"),
                    &column("end_time"),
                ));
            }
            "src_country_iso2" | "src_country" => {
                return Ok("COALESCE(src_geo.country_iso2, 'Unknown')".into());
            }
            "dst_country_iso2" | "dst_country" => {
                return Ok("COALESCE(dst_geo.country_iso2, 'Unknown')".into());
            }
            _ => {}
        }
        for (prefix, name) in [
            ("src_cidr:", "src_endpoint_ip"),
            ("dst_cidr:", "dst_endpoint_ip"),
        ] {
            if let Some(bits) = field.strip_prefix(prefix) {
                if matches!(bits, "8" | "16" | "24") {
                    return Ok(ipv4_prefix_sql(&column(name), bits));
                }
                return Err(ServiceError::InvalidRequest(
                    "unsupported CIDR grouping".into(),
                ));
            }
        }
    }
    if dataset.raw_table == "timeseries_metrics"
        && let Some(key) = metric_tag_key(field)?
    {
        // `tags` is a JSON document in a VARCHAR. The key is quoted in the path
        // so a hyphen in it is part of the name, not an operator.
        return Ok(format!(
            "get_json_string({}, '$.\"{key}\"')",
            column("tags")
        ));
    }
    let fields = match dataset.raw_table {
        "ocsf_network_activity" => {
            "id device_uid time event_type src_endpoint_ip dst_endpoint_ip src_endpoint_port dst_endpoint_port protocol_num protocol_name direction_label dst_service_label start_time end_time src_as_number dst_as_number tcp_flags partition input_snmp output_snmp src_mac dst_mac src_mac_vendor dst_mac_vendor src_hosting_provider dst_hosting_provider protocol_source direction_source dst_service_source src_prefix_tags dst_prefix_tags bytes_in bytes_out packets_in packets_out sampling_rate attribution_version sampler_address pid comm cmdline workload_identity"
        }
        "timeseries_metrics" => {
            "timestamp gateway_id series_key agent_id metric_name metric_type device_id value unit if_index partition scale is_delta counter_width target_device_ip tags usage_percent"
        }
        "logs" => {
            "id timestamp ingest_identity severity_text severity_number body service_name source ingest_agent_id ingest_partition trace_id span_id event_name source_ip service_version observed_timestamp"
        }
        "events" => {
            "id time class_uid category_uid type_uid activity_id severity_id severity source src_endpoint_ip firewall_rule_name source_type message activity_name status status_id log_name log_provider log_level trace_id span_id"
        }
        _ => "",
    };
    if fields.split_whitespace().any(|name| name == field) {
        if field == "partition" {
            return Ok(column("`partition`"));
        }
        Ok(column(field))
    } else {
        Err(ServiceError::InvalidRequest(format!(
            "unsupported StarRocks field: {field}"
        )))
    }
}

// Bit order and names are `FlowEnrichment.@tcp_flag_bits`; the warehouse keeps
// only the integer, so the label is rebuilt from it, in CWR..FIN order joined
// by ','.
//
// A flow without TCP flags is labelled 'none': a NULL mask (ingest writes a zero
// mask as NULL, so this is every UDP and ICMP flow), a zero mask, a mask with
// none of the eight known bits, and a negative mask, which the enrichment
// decodes to no labels rather than reading its sign-extended bits. CNPG
// labelled these '', which charts as a blank slice that the UI's 'unknown'
// fallback does not catch. Flows have no CNPG read path any more, so 'none' is
// the product's behaviour and a deliberate improvement on that '', not a parity
// break. It is not 'Unknown' either: the flags are known, and there are none.
const TCP_FLAG_BITS: [(u16, &str); 8] = [
    (128, "CWR"),
    (64, "ECE"),
    (32, "URG"),
    (16, "ACK"),
    (8, "PSH"),
    (4, "RST"),
    (2, "SYN"),
    (1, "FIN"),
];

fn tcp_flags_label_sql(tcp_flags: &str) -> String {
    let labels = TCP_FLAG_BITS
        .iter()
        .map(|(bit, name)| format!("IF(BITAND({tcp_flags}, {bit}) = 0, NULL, '{name}')"))
        .collect::<Vec<_>>()
        .join(", ");
    format!(
        "CASE WHEN {tcp_flags} IS NULL OR {tcp_flags} < 0 OR BITAND({tcp_flags}, 255) = 0 THEN 'none' ELSE CONCAT_WS(',', {labels}) END"
    )
}

// Same edges as CNPG's FLOW_DURATION_BUCKET_EXPR, in whole milliseconds so the
// comparison stays integral.
fn duration_bucket_sql(start_time: &str, end_time: &str) -> String {
    let elapsed = format!("MILLISECONDS_DIFF({end_time}, {start_time})");
    format!(
        "CASE WHEN {start_time} IS NULL OR {end_time} IS NULL THEN 'unknown' WHEN {elapsed} < 1000 THEN '<1s' WHEN {elapsed} < 10000 THEN '1-10s' WHEN {elapsed} < 60000 THEN '10-60s' WHEN {elapsed} < 300000 THEN '1-5m' ELSE '>5m' END"
    )
}

/// The tag a metric field names, if it names one: `tags.<key>`, or `core_id`,
/// the shorter spelling the per-core CPU chart has always used for
/// `tags.core_id`. CNPG reads these with `tags->>'<key>'`
/// (`downsample/fields.rs`); without them here that chart, and any series split
/// by a tag, failed outright the moment metrics were read from the warehouse.
///
/// The key is interpolated into SQL, so it passes the same validator CNPG uses
/// before it gets anywhere near a string.
fn metric_tag_key(field: &str) -> Result<Option<&str>> {
    let key = match field {
        "core_id" => "core_id",
        other => match other.strip_prefix("tags.") {
            Some(key) => key,
            None => return Ok(None),
        },
    };
    if !super::filters_common::is_valid_jsonb_key(key) {
        return Err(ServiceError::InvalidRequest(format!(
            "invalid tag key '{key}'"
        )));
    }
    Ok(Some(key))
}

// Whether an endpoint falls inside a configured local CIDR, for the flow's
// partition. `lc` is the single row `direction_source` cross joins in, holding
// every enabled CIDR as three parallel arrays.
//
// CNPG asks this with a correlated EXISTS over a range test. StarRocks refuses
// that outright ("Not support Non-EQ correlated predicate in correlated
// subquery"), and a join against the CIDR rows would count a flow once per
// matching row, so nested CIDRs -- a /8 holding a /24 -- would double its bytes.
// A lambda over arrays on a one-row join can do neither: the row count is the
// flow count by construction. With no CIDRs configured the arrays are NULL,
// the match is NULL, and the CASE falls through to the persisted label.
fn direction_sql() -> String {
    let local = |endpoint: &str| {
        format!(
            "any_match((a, b, q) -> LENGTH(f.{endpoint}_ip_hex) = LENGTH(a) AND f.{endpoint}_ip_hex BETWEEN a AND b AND (q IS NULL OR q = f.`partition`), lc.firsts, lc.lasts, lc.parts)"
        )
    };
    let src = local("src");
    let dst = local("dst");
    format!(
        "CASE WHEN {src} AND {dst} THEN 'bidirectional' WHEN {dst} THEN 'ingress' WHEN {src} THEN 'egress' ELSE COALESCE(f.direction_label, 'unknown') END"
    )
}

// PARTITION is a reserved word in StarRocks; unquoted it is a syntax error.
fn local_cidrs_sql() -> String {
    format!(
        "(SELECT ARRAY_AGG(first_ip_hex) AS firsts, ARRAY_AGG(last_ip_hex) AS lasts, ARRAY_AGG(`partition`) AS parts FROM {CNPG_CATALOG}.netflow_local_cidrs_catalog WHERE enabled) lc"
    )
}

fn direction_source(table: &str) -> String {
    format!(
        "(SELECT f.*, {} AS direction FROM {} f CROSS JOIN {})",
        direction_sql(),
        ip_hex_source(table),
        local_cidrs_sql()
    )
}

// The flow table with each endpoint as fixed-width lowercase hex -- 8 digits
// for IPv4, 32 for IPv6 -- so that address order is string order. StarRocks has
// no inet type; this is the one representation every containment test here
// compares against.
fn ip_hex_source(table: &str) -> String {
    let normalized = |col: &str| {
        format!(
            "LOWER(CASE WHEN LOCATE(':', {col}) > 0 AND LOCATE('.', {col}) > 0 THEN CONCAT(REGEXP_REPLACE({col}, '[^:]+$', ''), SUBSTRING(LPAD(HEX(INET_ATON(SUBSTRING_INDEX({col}, ':', -1))), 8, '0'), 1, 4), ':', SUBSTRING(LPAD(HEX(INET_ATON(SUBSTRING_INDEX({col}, ':', -1))), 8, '0'), 5, 4)) ELSE {col} END)"
        )
    };
    format!(
        "(SELECT normalized.*, {} AS src_ip_hex, {} AS dst_ip_hex FROM (SELECT *, {} AS src_ip_normalized, {} AS dst_ip_normalized FROM {table}) normalized)",
        ip_hex_sql("src_ip_normalized"),
        ip_hex_sql("dst_ip_normalized"),
        normalized("src_endpoint_ip"),
        normalized("dst_endpoint_ip"),
    )
}

fn filters_on_flow_cidr(plan: &QueryPlan) -> bool {
    matches!(plan.entity, Entity::Flows | Entity::AttributedFlows)
        && plan
            .filters
            .iter()
            .any(|filter| matches!(filter.field.as_str(), "src_cidr" | "dst_cidr"))
}

// CNPG asks `try_inet(ip) <<= cidr`, or `<<= ANY(cidr[])` for a list. Here each
// CIDR becomes its first and last address in the `ip_hex_source` encoding. The
// length test keeps the families apart, as inet containment does: an IPv4 flow
// is never inside an IPv6 prefix.
//
// An address that is NULL or does not parse has a NULL hex. It is inside no
// CIDR, so it fails the positive test and passes the negated one -- the
// `try_inet(...) IS NULL OR NOT (...)` of CNPG's stats path, which is the path
// these aggregate queries took.
//
// The lambda is there to name the hex once. StarRocks inlines the derived
// column into the predicate, and the three references a plain range test makes
// put the expression past its 10000-node analyzer limit ("Expression too
// complex"). A list ORs its ranges inside the same lambda for the same reason.
fn flow_cidr_filter_sql(filter: &Filter, endpoint: &str) -> Result<String> {
    use crate::parser::FilterOp;
    let (cidrs, negated): (Vec<&str>, bool) = match filter.op {
        FilterOp::Eq | FilterOp::NotEq => (
            vec![filter.value.as_scalar()?],
            matches!(filter.op, FilterOp::NotEq),
        ),
        FilterOp::In | FilterOp::NotIn => (
            filter.value.as_list()?.iter().map(String::as_str).collect(),
            matches!(filter.op, FilterOp::NotIn),
        ),
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "{endpoint}_cidr filter only supports equality or list matching"
            )));
        }
    };
    if cidrs.is_empty() {
        return Err(ServiceError::InvalidRequest("empty filter list".into()));
    }
    let ranges = cidrs
        .iter()
        .map(|cidr| {
            let (first, last) = cidr_hex_bounds(cidr)?;
            Ok(format!(
                "(LENGTH(h) = {} AND h BETWEEN '{first}' AND '{last}')",
                first.len()
            ))
        })
        .collect::<Result<Vec<_>>>()?
        .join(" OR ");
    let test = if negated {
        format!("h IS NULL OR NOT ({ranges})")
    } else {
        ranges
    };
    Ok(format!("any_match(h -> {test}, [f.{endpoint}_ip_hex])"))
}

fn cidr_hex_bounds(value: &str) -> Result<(String, String)> {
    let cidr = normalize_cidr_literal(value)?;
    let (ip, prefix) = cidr
        .split_once('/')
        .ok_or_else(|| ServiceError::InvalidRequest("CIDR must be like 10.0.0.0/24".into()))?;
    let prefix: u32 = prefix.parse().map_err(|_| {
        ServiceError::InvalidRequest("CIDR must contain a valid prefix length".into())
    })?;
    let ip: std::net::IpAddr = ip.parse().map_err(|_| {
        ServiceError::InvalidRequest("CIDR must contain a valid IPv4/IPv6 address".into())
    })?;
    let (address, bits, digits) = match ip {
        std::net::IpAddr::V4(v4) => (u128::from(u32::from(v4)), 32, 8),
        std::net::IpAddr::V6(v6) => (u128::from(v6), 128, 32),
    };
    let host_mask = match bits - prefix {
        0 => 0,
        host_bits => u128::MAX >> (128 - host_bits),
    };
    // Postgres refuses a `cidr` with bits set right of the mask, so CNPG never
    // answers such a filter; widening it to its network here would.
    if address & host_mask != 0 {
        return Err(ServiceError::InvalidRequest(
            "CIDR must not have bits set to the right of the prefix".into(),
        ));
    }
    Ok((
        format!("{address:0digits$x}"),
        format!("{:0digits$x}", address | host_mask),
    ))
}

fn ip_hex_sql(ip: &str) -> String {
    let left = format!("SPLIT_PART({ip}, '::', 1)");
    let right = format!("SPLIT_PART({ip}, '::', 2)");
    let left_count = format!("IF({left} = '', 0, ARRAY_LENGTH(SPLIT({left}, ':')))");
    let right_count = format!("IF({right} = '', 0, ARRAY_LENGTH(SPLIT({right}, ':')))");
    let mut groups = Vec::new();
    for i in 1..=8 {
        groups.push(format!("CASE WHEN LOCATE('::', {ip}) = 0 THEN LPAD(SPLIT_PART({ip}, ':', {i}), 4, '0') WHEN {i} <= {left_count} THEN LPAD(SPLIT_PART({left}, ':', {i}), 4, '0') WHEN {i} > 8 - {right_count} THEN LPAD(SPLIT_PART({right}, ':', {i} - 8 + {right_count}), 4, '0') ELSE '0000' END"));
    }
    let group_pattern = "^([0-9a-f]{1,4}(:[0-9a-f]{1,4})*)?$";
    format!(
        "CASE WHEN LOCATE(':', {ip}) = 0 THEN LOWER(LPAD(HEX(INET_ATON({ip})), 8, '0')) WHEN {ip} REGEXP '^[0-9a-f]{{1,4}}(:[0-9a-f]{{1,4}}){{7}}$' OR (LOCATE('::', {ip}) > 0 AND {left} REGEXP '{group_pattern}' AND {right} REGEXP '{group_pattern}' AND LOCATE('::', SUBSTRING({ip}, LOCATE('::', {ip}) + 2)) = 0 AND {left_count} + {right_count} < 8) THEN CONCAT({}) ELSE NULL END",
        groups.join(", ")
    )
}

fn filter_sql(plan: &QueryPlan, filter: &Filter) -> Result<String> {
    use crate::parser::FilterOp;
    if matches!(plan.entity, Entity::Flows | Entity::AttributedFlows) {
        match filter.field.as_str() {
            "device_id" => return device_scope_sql(plan, filter),
            "src_cidr" => return flow_cidr_filter_sql(filter, "src"),
            "dst_cidr" => return flow_cidr_filter_sql(filter, "dst"),
            "device_addr" | "device_address" => {
                if !matches!(filter.op, FilterOp::Eq | FilterOp::In) {
                    return Err(ServiceError::InvalidRequest(
                        "device_addr supports equality and lists".into(),
                    ));
                }
                let predicates = ["src_endpoint_ip", "dst_endpoint_ip", "sampler_address"]
                    .iter()
                    .map(|field| {
                        filter_sql(
                            plan,
                            &Filter {
                                field: (*field).into(),
                                ..filter.clone()
                            },
                        )
                    })
                    .collect::<Result<Vec<_>>>()?;
                return Ok(format!("({})", predicates.join(" OR ")));
            }
            _ => {}
        }
    }
    if let Some(dataset) = dataset_for(&plan.entity)
        && let Some(predicate) = dataset_filter_sql(dataset, filter)?
    {
        return Ok(predicate);
    }
    let field = field_sql(plan, &filter.field)?;
    let is_direction = matches!(plan.entity, Entity::Flows | Entity::AttributedFlows)
        && filter.field == "direction";
    let literal = |value: &str| {
        sql_literal(if is_direction {
            direction_value(value)
        } else {
            value
        })
    };
    let op = match filter.op {
        FilterOp::Eq => "=",
        FilterOp::NotEq => "!=",
        FilterOp::Gt => ">",
        FilterOp::Gte => ">=",
        FilterOp::Lt => "<",
        FilterOp::Lte => "<=",
        FilterOp::Like => "LIKE",
        FilterOp::NotLike => "NOT LIKE",
        FilterOp::In | FilterOp::NotIn => {
            let values = filter.value.as_list()?;
            if values.is_empty() {
                return Err(ServiceError::InvalidRequest("empty filter list".into()));
            }
            let op = if matches!(filter.op, FilterOp::In) {
                "IN"
            } else {
                "NOT IN"
            };
            return Ok(format!(
                "{field} {op} ({})",
                values
                    .iter()
                    .map(|v| literal(v))
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
        }
    };
    Ok(format!(
        "{field} {op} {}",
        literal(filter.value.as_scalar()?)
    ))
}

// The classifier names a flow by which end is local: both, the destination,
// the source, or neither. The UI names the same four cases from the network's
// point of view, and those are the words its direction chips send. Without
// this the chips matched nothing, on either backend.
fn direction_value(value: &str) -> &str {
    match value.to_ascii_lowercase().as_str() {
        "internal" => "bidirectional",
        "inbound" => "ingress",
        "outbound" => "egress",
        "external" => "unknown",
        _ => value,
    }
}

fn sql_literal(value: &str) -> String {
    format!("'{}'", value.replace('\\', "\\\\").replace('\'', "''"))
}

fn device_scope_sql(plan: &QueryPlan, filter: &Filter) -> Result<String> {
    use crate::parser::FilterOp;
    if !matches!(filter.op, FilterOp::Eq | FilterOp::NotEq) {
        return Err(ServiceError::InvalidRequest(
            "device_id only supports equality".into(),
        ));
    }
    let uid = sql_literal(filter.value.as_scalar()?);
    let addresses = format!(
        "SELECT d.ip FROM {CNPG_CATALOG}.ocsf_devices d WHERE d.uid = {uid} AND d.ip IS NOT NULL AND d.ip <> '' UNION SELECT das.alias_value FROM {CNPG_CATALOG}.device_alias_states das WHERE das.device_id = {uid} AND das.alias_type = 'ip' AND das.state IN ('detected', 'confirmed', 'updated')"
    );
    let samplers = format!(
        "SELECT ec.sampler_address FROM {CNPG_CATALOG}.netflow_exporter_cache ec WHERE ec.device_uid = {uid}"
    );
    let src = field_sql(plan, "src_endpoint_ip")?;
    let dst = field_sql(plan, "dst_endpoint_ip")?;
    let sampler = field_sql(plan, "sampler_address")?;
    let predicate =
        format!("({src} IN ({addresses}) OR {dst} IN ({addresses}) OR {sampler} IN ({samplers}))");
    Ok(if matches!(filter.op, FilterOp::NotEq) {
        format!("NOT {predicate}")
    } else {
        predicate
    })
}

fn order_sql(plan: &QueryPlan, time_column: &str) -> Result<String> {
    if plan.order.is_empty() {
        return Ok(if plan.stats.is_none() {
            if matches!(plan.entity, Entity::Flows | Entity::AttributedFlows) {
                format!(
                    " ORDER BY {time_column} DESC, {} DESC",
                    field_sql(plan, "id")?
                )
            } else {
                format!(" ORDER BY {time_column} DESC")
            }
        } else {
            String::new()
        });
    }
    let groups = stats_group_by(plan.stats.as_ref()).unwrap_or_default();
    let mut terms = Vec::new();
    for order in &plan.order {
        let field = if let Some(stats) = &plan.stats {
            if !parse_aggregations(stats)?
                .iter()
                .any(|(_, _, alias)| *alias == order.field)
                && !groups.split(',').any(|col| group_alias(col) == order.field)
            {
                return Err(ServiceError::InvalidRequest(
                    "stats ordering requires a selected field".into(),
                ));
            }
            validate_identifier(&order.field)?;
            order.field.clone()
        } else {
            field_sql(plan, &order.field)?
        };
        let direction = match order.direction {
            crate::parser::OrderDirection::Asc => "ASC",
            crate::parser::OrderDirection::Desc => "DESC",
        };
        terms.push(format!("{field} {direction}"));
    }
    if plan.stats.is_none()
        && matches!(plan.entity, Entity::Flows | Entity::AttributedFlows)
        && !plan.order.iter().any(|order| order.field == "id")
    {
        terms.push(format!("{} DESC", field_sql(plan, "id")?));
    }
    Ok(format!(" ORDER BY {}", terms.join(", ")))
}

/// `hour_grained` says the answer is scored on whole hours -- an hourly
/// aggregate could serve this query, whether or not this compile is allowed to
/// read one. Both edge hours therefore belong in the answer in full, so the
/// window is widened to them: `floor_hour(start)` and `exclusive_hour_end(end)`,
/// the same pair the profile route uses. That is a property of the query, never
/// of the source: the rollup-freshness gate recompiles the same query against
/// the raw table, and a bound that moved with the source would change an edge
/// bucket's value with no error -- `bucket < end` admits the row covering the
/// whole hour holding `end`, while `time < end` truncates it.
fn time_predicate(
    plan: &QueryPlan,
    time_column: &str,
    qualify_flow: bool,
    hour_grained: bool,
) -> (String, Vec<BindParam>) {
    let column = if qualify_flow {
        format!("f.`{time_column}`")
    } else {
        format!("`{time_column}`")
    };
    let (start, end) = match &plan.time_range {
        Some(range) => (range.start, range.end),
        None => {
            let end = Utc::now();
            (end - chrono::Duration::hours(1), end)
        }
    };
    let (lower, upper) = if hour_grained {
        (floor_hour(start), exclusive_hour_end(end))
    } else {
        (start, end)
    };
    (
        format!(
            " WHERE {column} >= '{}' AND {column} < '{}'",
            lower.to_rfc3339_opts(SecondsFormat::Secs, true),
            upper.to_rfc3339_opts(SecondsFormat::Secs, true)
        ),
        vec![BindParam::timestamptz(lower), BindParam::timestamptz(upper)],
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::AppConfig;
    use crate::parser;
    use crate::query::{QueryDirection, QueryRequest, build_query_plan};
    use std::time::Duration as StdDuration;

    fn config() -> AppConfig {
        AppConfig {
            listen_addr: "127.0.0.1:0".parse().unwrap(),
            database_url: "postgres://example/db".to_string(),
            age_graph_name: "platform_graph".to_string(),
            starrocks_database: "serviceradar".to_string(),
            dgraph_url: None,
            max_pool_size: 1,
            database_ca_pem: None,
            database_client_cert_pem: None,
            database_client_key_pem: None,
            database_tls_server_name: None,
            api_key: None,
            api_key_kv_key: None,
            allowed_origins: None,
            cursor_secret: "test-cursor-secret".to_string(),
            max_cursor_offset: 100_000,
            default_limit: 100,
            max_limit: 500,
            request_timeout: StdDuration::from_secs(30),
            db_statement_timeout: StdDuration::from_secs(30),
            rate_limit_max_requests: 120,
            rate_limit_window: StdDuration::from_secs(60),
        }
    }

    // A bucketed metric query names no value column, and the capacity
    // forecaster ships several. Defaulting to the flow measurement asked
    // timeseries_metrics for a column it does not have, so every default
    // forecasting source failed the moment metrics were cut over.
    #[test]
    fn a_bucketed_metric_query_defaults_to_the_metric_value_column() {
        let compiled = translate(
            &plan(
                r#"in:timeseries_metrics metric_type:"sysmon.cpu" metric_name:"cpu.usage_percent" time:last_30d bucket:1h agg:avg series:uid sort:timestamp:desc limit:500"#,
            ),
            "serviceradar",
        )
        .expect("metric downsample compiles");

        assert!(
            compiled
                .sql
                .contains("serviceradar.timeseries_metrics_hourly"),
            "{}",
            compiled.sql
        );
        assert!(compiled.sql.contains("avg_value"), "{}", compiled.sql);
        assert!(!compiled.sql.contains("bytes_total"), "{}", compiled.sql);
        assert!(
            compiled.sql.contains("CAST(device_id AS STRING) AS series"),
            "{}",
            compiled.sql
        );
    }

    #[test]
    fn a_bucketed_flow_query_still_defaults_to_the_flow_measurement() {
        let compiled = translate(
            &plan("in:flows time:last_7d bucket:1h agg:sum"),
            "serviceradar",
        )
        .expect("flow downsample compiles");

        assert!(compiled.sql.contains("bytes_total"), "{}", compiled.sql);
    }

    // Anomaly peak profiling and seasonal baselines are metric consumers, so a
    // metrics cutover has to keep answering them. Compiling their bucket clause
    // as a downsample returned timestamp/series/value rows under a profile
    // query's name; refusing them disabled the baselines instead.
    #[test]
    fn the_seasonal_profile_route_compiles_against_the_raw_metric_table() {
        let compiled = translate(
            &plan(
                r#"in:timeseries_metrics metric_type:"sysmon.memory" metric_name:"memory.used_percent" time:last_30d bucket:1h agg:avg series:uid stats:profile_hour_of_week(value) timezone:"America/Chicago" sort:dow:asc,hod:asc limit:500"#,
            ),
            "serviceradar",
        )
        .expect("profile compiles");

        let sql = compiled.sql;
        // `series:uid` is not a view dimension, so the hourly view cannot serve
        // this profile even on the rollup-eligible entry point.
        assert!(!sql.contains("timeseries_metrics_hourly"), "{sql}");
        assert!(
            sql.contains("FROM serviceradar.timeseries_metrics\n"),
            "{sql}"
        );
        // The consumers read a flat row; a jsonb payload would arrive as an
        // opaque string over the MySQL protocol.
        for column in [
            "AS series",
            "AS dow",
            "AS hod",
            "AS bucket_count",
            "AS bucket_sum",
            "AS bucket_sum_sq",
            "AS center",
            "AS mad",
            "AS p05",
            "AS p95",
        ] {
            assert!(sql.contains(column), "missing {column} in {sql}");
        }
        assert!(!sql.contains("jsonb_build_object"), "{sql}");
        assert!(!sql.contains("DISTINCT ON"), "{sql}");
        assert!(!sql.contains("WITHIN GROUP"), "{sql}");
        assert!(
            sql.contains("CONVERT_TZ(bucket, 'UTC', 'America/Chicago')"),
            "{sql}"
        );
        // StarRocks DAYOFWEEK is 1=Sunday; the profile contract is 0=Sunday.
        assert!(
            sql.contains("DAYOFWEEK(CONVERT_TZ") && sql.contains(") - 1 AS dow"),
            "{sql}"
        );
        assert!(sql.contains("metric_type = 'sysmon.memory'"), "{sql}");
        assert!(!sql.contains("timezone ="), "{sql}");
    }

    #[test]
    fn the_peak_profile_route_reads_the_maximum_and_carries_its_scale() {
        let compiled = translate(
            &plan(
                r#"in:timeseries_metrics metric_type:"sysmon.cpu" metric_name:"cpu.usage_percent" time:last_30d bucket:1h agg:avg series:uid stats:profile_hour_of_week_peak(value) timezone:"UTC" sort:dow:asc,hod:asc limit:400"#,
            ),
            "serviceradar",
        )
        .expect("peak profile compiles");

        let sql = compiled.sql;
        assert!(sql.contains("MAX(`value`) AS sample_value"), "{sql}");
        for column in ["AS center", "AS p95", "AS bucket_count", "AS prior_scale"] {
            assert!(sql.contains(column), "missing {column} in {sql}");
        }
        assert!(sql.contains("LIMIT 400"), "{sql}");
    }

    // The freshness gate recompiles a stale view's query through translate_raw,
    // so the profile route has to have a raw-table shape as well.
    #[test]
    fn a_stale_metric_view_recompiles_the_profile_from_the_raw_table() {
        let compiled = translate_raw(
            &plan(
                r#"in:timeseries_metrics metric_type:"sysmon.cpu" metric_name:"cpu.usage_percent" time:last_30d bucket:1h agg:avg series:uid stats:profile_hour_of_week_peak(value) timezone:"UTC" sort:dow:asc,hod:asc limit:400"#,
            ),
            "serviceradar",
        )
        .expect("raw profile compiles");

        let sql = compiled.sql;
        assert!(!sql.contains("timeseries_metrics_hourly"), "{sql}");
        assert!(
            sql.contains("FROM serviceradar.timeseries_metrics\n"),
            "{sql}"
        );
        assert!(
            sql.contains("date_trunc('hour', `timestamp`) AS bucket"),
            "{sql}"
        );
        assert!(sql.contains("MAX(`value`) AS sample_value"), "{sql}");
        assert!(sql.contains("GROUP BY 1, 2, 3, 4"), "{sql}");
    }

    #[test]
    fn a_profile_over_a_non_metric_dataset_is_still_refused() {
        let err = translate(
            &plan(
                r#"in:flows time:last_30d bucket:1h agg:avg stats:profile_hour_of_week(value) limit:10"#,
            ),
            "serviceradar",
        )
        .expect_err("flows have no hour-of-week profile");

        assert!(matches!(err, ServiceError::NotImplemented(_)), "{err:?}");
    }

    #[test]
    fn a_profile_over_a_field_other_than_value_is_rejected() {
        let err = translate(
            &plan(
                r#"in:timeseries_metrics time:last_30d bucket:1h agg:avg stats:profile_hour_of_week(usage_percent) limit:10"#,
            ),
            "serviceradar",
        )
        .expect_err("profile only supports value");

        assert!(matches!(err, ServiceError::InvalidRequest(_)), "{err:?}");
    }

    // The freshness gate exists to keep a rollup read and its raw fallback
    // answering the same question. The profile route has no rollup branch at
    // all, so the gate must not be able to change its answer: both entry points
    // have to compile the identical statement, sampled one row per (hour,
    // device, metric_type, metric_name) -- the grain the view itself stores.
    #[test]
    fn both_entry_points_compile_the_same_raw_profile() {
        let query = r#"in:timeseries_metrics metric_type:"sysmon.cpu" metric_name:"cpu.usage_percent" time:last_30d bucket:1h agg:avg series:uid stats:profile_hour_of_week(value) timezone:"UTC" limit:500"#;

        let rollup_entry = translate(&plan(query), "serviceradar").expect("profile compiles");
        let raw_entry = translate_raw(&plan(query), "serviceradar").expect("raw profile compiles");

        assert_eq!(rollup_entry.sql, raw_entry.sql);
        assert!(
            rollup_entry
                .sql
                .contains("device_id AS series, metric_type, metric_name"),
            "{}",
            rollup_entry.sql
        );
        assert!(
            rollup_entry.sql.contains("GROUP BY 1, 2, 3, 4"),
            "{}",
            rollup_entry.sql
        );
    }

    // `if_index` is a raw column the hourly view does not carry. It has to
    // survive into the profile's WHERE rather than being dropped as a filter
    // the source cannot answer.
    #[test]
    fn a_profile_filter_on_a_raw_only_column_is_applied() {
        let compiled = translate(
            &plan(
                r#"in:timeseries_metrics if_index:3 time:last_30d bucket:1h agg:avg stats:profile_hour_of_week(value) timezone:"UTC" limit:500"#,
            ),
            "serviceradar",
        )
        .expect("profile compiles");

        assert!(
            !compiled.sql.contains("timeseries_metrics_hourly"),
            "{}",
            compiled.sql
        );
        assert!(compiled.sql.contains("if_index"), "{}", compiled.sql);
    }

    // The one query shape the hourly view could have served: no `series:`, and
    // every filter inside its dimension set. Reading the view here would have
    // been correct, but it is a shape no shipped caller emits -- so keeping the
    // branch meant a second profile statement that only a hand-typed query
    // could reach, with its own sample population to keep in step.
    #[test]
    fn a_profile_filtered_only_on_view_dimensions_still_reads_the_raw_table() {
        let compiled = translate(
            &plan(
                r#"in:timeseries_metrics metric_type:"sysmon.cpu" time:last_30d bucket:1h agg:avg stats:profile_hour_of_week(value) timezone:"UTC" limit:500"#,
            ),
            "serviceradar",
        )
        .expect("profile compiles");

        assert!(
            !compiled.sql.contains("timeseries_metrics_hourly"),
            "{}",
            compiled.sql
        );
        assert!(
            compiled
                .sql
                .contains("FROM serviceradar.timeseries_metrics\n"),
            "{}",
            compiled.sql
        );
        assert!(
            compiled.sql.contains("AVG(`value`) AS sample_value"),
            "{}",
            compiled.sql
        );
    }

    // A profile query carries a LIMIT, so the sort decides which cells survive
    // it rather than merely how a page is ordered. Dropping the caller's sort
    // returned a different set of rows than CNPG for the same query.
    #[test]
    fn a_caller_sort_is_honoured_by_the_profile_route() {
        let compiled = translate(
            &plan(
                r#"in:timeseries_metrics metric_type:"sysmon.cpu" metric_name:"cpu.usage_percent" time:last_30d bucket:1h agg:avg stats:profile_hour_of_week_full(value) timezone:"UTC" sort:bucket_count:desc limit:50"#,
            ),
            "serviceradar",
        )
        .expect("profile compiles");

        assert!(
            compiled
                .sql
                .contains("ORDER BY p.bucket_count DESC, l.series ASC, l.dow ASC, l.hod ASC"),
            "{}",
            compiled.sql
        );

        let peak = translate(
            &plan(
                r#"in:timeseries_metrics metric_type:"sysmon.cpu" metric_name:"cpu.usage_percent" time:last_30d bucket:1h agg:avg stats:profile_hour_of_week_peak(value) timezone:"UTC" sort:sample_value:desc limit:50"#,
            ),
            "serviceradar",
        )
        .expect("peak profile compiles");

        assert!(
            peak.sql
                .contains("ORDER BY l.sample_value DESC, l.series ASC, l.dow ASC, l.hod ASC"),
            "{}",
            peak.sql
        );
    }

    #[test]
    fn the_internal_profile_sort_keeps_its_dow_hod_order() {
        let compiled = translate(
            &plan(
                r#"in:timeseries_metrics metric_type:"sysmon.cpu" metric_name:"cpu.usage_percent" time:last_30d bucket:1h agg:avg stats:profile_hour_of_week(value) timezone:"UTC" sort:dow:asc,hod:asc limit:500"#,
            ),
            "serviceradar",
        )
        .expect("profile compiles");

        assert!(
            compiled
                .sql
                .contains("ORDER BY l.dow ASC, l.hod ASC, l.series ASC"),
            "{}",
            compiled.sql
        );
    }

    // A profile scores whole hours, and the window bounds are `now`-relative so
    // they never land on an hour. Emitting them verbatim dropped the hour
    // holding `start` and the hour holding `end` from the view, while the raw
    // fallback's date_trunc kept the end hour -- so `latest` resolved to a
    // different cell depending only on whether the view happened to be fresh.
    #[test]
    fn profile_window_bounds_are_widened_to_whole_hours() {
        let query = r#"in:timeseries_metrics metric_type:"sysmon.cpu" metric_name:"cpu.usage_percent" time:[2026-09-11T00:37:00Z,2026-09-19T15:37:00Z] bucket:1h agg:avg series:uid stats:profile_hour_of_week_peak(value) timezone:"UTC" limit:400"#;

        let rollup_entry = translate(&plan(query), "serviceradar").expect("profile compiles");
        let raw_entry = translate_raw(&plan(query), "serviceradar").expect("raw profile compiles");

        // The hour holding `start` is included whole, and the hour holding
        // `end` is admitted by pushing the exclusive upper bound out to the
        // next hour.
        for sql in [&rollup_entry.sql, &raw_entry.sql] {
            assert!(sql.contains(">= '2026-09-11T00:00:00Z'"), "{sql}");
            assert!(sql.contains("< '2026-09-19T16:00:00Z'"), "{sql}");
            assert!(!sql.contains("00:37:00Z"), "{sql}");
            assert!(!sql.contains("15:37:00Z"), "{sql}");
        }
    }

    // CNPG adds the hour unconditionally, so an already-aligned end still
    // includes the bucket that starts at it. Excluding it would answer the same
    // query differently on the two backends.
    #[test]
    fn an_hour_aligned_profile_end_still_includes_its_own_bucket() {
        let compiled = translate(
            &plan(
                r#"in:timeseries_metrics metric_type:"sysmon.cpu" metric_name:"cpu.usage_percent" time:[2026-09-11T00:00:00Z,2026-09-19T15:00:00Z] bucket:1h agg:avg stats:profile_hour_of_week(value) timezone:"UTC" limit:400"#,
            ),
            "serviceradar",
        )
        .expect("profile compiles");

        assert!(
            compiled.sql.contains(">= '2026-09-11T00:00:00Z'"),
            "{}",
            compiled.sql
        );
        assert!(
            compiled.sql.contains("< '2026-09-19T16:00:00Z'"),
            "{}",
            compiled.sql
        );
    }

    fn plan(query: &str) -> QueryPlan {
        let ast = parser::parse(query).expect("parse");
        let request = QueryRequest {
            query: query.to_string(),
            limit: None,
            cursor: None,
            direction: QueryDirection::Next,
            mode: Some("starrocks".into()),
        };
        build_query_plan(&config(), &request, ast).expect("plan")
    }

    #[test]
    fn direction_filters_accept_the_ui_vocabulary() {
        for (ui, stored) in [
            ("internal", "bidirectional"),
            ("inbound", "ingress"),
            ("outbound", "egress"),
            ("external", "unknown"),
            ("ingress", "ingress"),
        ] {
            let compiled = translate(
                &plan(&format!("in:flows time:last_1h direction:{ui}")),
                "serviceradar",
            )
            .unwrap();
            assert!(
                compiled.sql.contains(&format!("direction = '{stored}'")),
                "direction:{ui} -> {}",
                compiled.sql
            );
        }

        let listed = translate(
            &plan("in:flows time:last_1h direction:(internal,outbound)"),
            "serviceradar",
        )
        .unwrap();
        assert!(
            listed.sql.contains("IN ('bidirectional', 'egress')"),
            "{}",
            listed.sql
        );

        // Only the direction field is translated.
        let other = translate(
            &plan("in:flows time:last_1h protocol_name:internal"),
            "serviceradar",
        )
        .unwrap();
        assert!(other.sql.contains("'internal'"), "{}", other.sql);
    }

    #[test]
    fn direction_queries_use_partition_scoped_cidr_classification() {
        for query in [
            r#"in:flows time:last_1h stats:"sum(bytes_total) as total by direction""#,
            "in:flows time:last_1h direction:ingress",
            "in:flows time:last_1h sort:direction:asc",
        ] {
            let compiled = translate(&plan(query), "serviceradar").unwrap();
            let sql = &compiled.sql;
            assert!(sql.contains("cnpg_platform.platform.netflow_local_cidrs_catalog"));

            // The CIDRs arrive as one row of parallel arrays, so the join cannot
            // change the number of flows however the CIDRs nest or overlap.
            assert!(sql.contains("CROSS JOIN (SELECT ARRAY_AGG(first_ip_hex) AS firsts, ARRAY_AGG(last_ip_hex) AS lasts, ARRAY_AGG(`partition`) AS parts"), "{sql}");
            assert!(sql.contains("WHERE enabled) lc"), "{sql}");
            assert!(sql.contains("any_match((a, b, q) -> LENGTH(f.src_ip_hex) = LENGTH(a) AND f.src_ip_hex BETWEEN a AND b AND (q IS NULL OR q = f.`partition`), lc.firsts, lc.lasts, lc.parts)"), "{sql}");
            assert!(
                sql.contains("any_match((a, b, q) -> LENGTH(f.dst_ip_hex) = LENGTH(a)"),
                "{sql}"
            );

            // StarRocks rejects a range test inside a correlated subquery
            // ("Not support Non-EQ correlated predicate"), so this shape took out
            // every direction filter and chart.
            assert!(
                !sql.contains("EXISTS (SELECT 1 FROM cnpg_platform"),
                "{sql}"
            );
            // PARTITION is reserved: unquoted, the whole query is a syntax error.
            assert!(!sql.contains("c.partition"), "{sql}");
            assert!(!sql.contains("ARRAY_AGG(partition)"), "{sql}");

            assert!(sql.contains("THEN 'bidirectional'"));
            assert!(sql.contains("THEN 'ingress'"));
            assert!(sql.contains("THEN 'egress'"));
            assert!(sql.contains("COALESCE(f.direction_label, 'unknown')"));
            assert!(sql.contains("AS src_ip_hex"));
            assert!(sql.contains("AS dst_ip_hex"));
        }
    }

    #[test]
    fn stats_preserve_count_fields_distinct_and_reject_partial_expressions() {
        let compiled = translate(&plan(r#"in:flows time:last_1h stats:"count(src_endpoint_port) as ports, count_distinct(src_endpoint_ip) as talkers" sort:talkers:desc"#), "serviceradar").unwrap();
        assert!(compiled.sql.starts_with("SELECT COUNT(src_endpoint_port) AS ports, COUNT(DISTINCT src_endpoint_ip) AS talkers FROM "));
        assert!(compiled.sql.contains("ORDER BY talkers DESC"));
        for expression in [
            "count(*) as total, unsupported(bytes_in) as bad",
            "count(*) as total,",
            "count(src_endpoint_port) ignored as ports",
            "count_distinct(*) as bad",
            "sum() as bad",
            "count(body) as bad",
        ] {
            let query = format!("in:flows time:last_1h stats:\"{expression}\"");
            assert!(translate(&plan(&query), "serviceradar").is_err(), "{query}");
        }
    }

    #[test]
    fn aggregate_totals_prefer_stored_counters_before_directional_fallback() {
        for (field, inbound, outbound) in [
            ("bytes_total", "bytes_in", "bytes_out"),
            ("packets_total", "packets_in", "packets_out"),
        ] {
            for (filter, prefix) in [("", ""), ("hostname:host01.example.com", "f.")] {
                let total = format!(
                    "COALESCE({prefix}{field}, COALESCE({prefix}{inbound}, 0) + COALESCE({prefix}{outbound}, 0))"
                );
                let stats = translate(
                    &plan(&format!(
                        "in:flows {filter} time:last_1h stats:\"sum({field}) as volume\""
                    )),
                    "serviceradar",
                )
                .unwrap();
                assert!(stats.sql.starts_with(&format!("SELECT SUM((CAST(COALESCE({total}, 0) AS DOUBLE) * GREATEST(COALESCE({prefix}sampling_rate, 1), 1))) AS volume")));
                let chart = translate(
                    &plan(&format!(
                        "in:flows {filter} time:last_1h bucket:1m agg:sum value_field:{field}"
                    )),
                    "serviceradar",
                )
                .unwrap();
                assert!(
                    chart
                        .sql
                        .contains(&format!("SUM((CAST(COALESCE({total}, 0) AS DOUBLE)"))
                );
            }
        }
    }

    #[test]
    fn volume_aggregates_and_charts_apply_sampling_without_weighting_counts() {
        for field in [
            "bytes_in",
            "bytes_out",
            "packets_in",
            "packets_out",
            "bytes_total",
            "packets_total",
        ] {
            let query = format!("in:flows time:last_1h stats:\"sum({field}) as volume\"");
            let compiled = translate(&plan(&query), "serviceradar").unwrap();
            let value = field_sql(&plan(&query), field).unwrap();
            let sampled = format!(
                "(CAST(COALESCE({value}, 0) AS DOUBLE) * GREATEST(COALESCE(sampling_rate, 1), 1))"
            );
            assert!(
                compiled
                    .sql
                    .starts_with(&format!("SELECT SUM({sampled}) AS volume"))
            );
            let chart = translate(
                &plan(&format!(
                    "in:flows time:last_1h bucket:1m agg:sum value_field:{field}"
                )),
                "serviceradar",
            )
            .unwrap();
            assert!(chart.sql.contains(&format!("SUM({sampled}) AS value")));
        }
        let count = translate(
            &plan(r#"in:flows time:last_1h stats:"count(bytes_in) as observations""#),
            "serviceradar",
        )
        .unwrap();
        assert!(
            count
                .sql
                .starts_with("SELECT COUNT(bytes_in) AS observations")
        );
    }

    #[test]
    fn device_scope_uses_endpoints_active_aliases_and_exporter_samplers() {
        let compiled = translate(
            &plan("in:flows time:last_1h device_id:device-example"),
            "serviceradar",
        )
        .unwrap();
        assert!(compiled.sql.contains("src_endpoint_ip IN (SELECT d.ip"));
        assert!(compiled.sql.contains("OR dst_endpoint_ip IN (SELECT d.ip"));
        assert!(compiled.sql.contains("das.device_id = 'device-example' AND das.alias_type = 'ip' AND das.state IN ('detected', 'confirmed', 'updated')"));
        assert!(compiled.sql.contains("OR sampler_address IN (SELECT ec.sampler_address FROM cnpg_platform.platform.netflow_exporter_cache ec WHERE ec.device_uid = 'device-example')"));
        let addresses = translate(&plan(
            r#"in:flows time:last_1h device_addr:[192.0.2.1,192.0.2.2] stats:"count(*) as total""#,
        ), "serviceradar")
        .unwrap();
        assert!(addresses.sql.contains("(src_endpoint_ip IN ('192.0.2.1', '192.0.2.2') OR dst_endpoint_ip IN ('192.0.2.1', '192.0.2.2') OR sampler_address IN ('192.0.2.1', '192.0.2.2'))"));
        let mut invalid = plan("in:flows time:last_1h");
        invalid.filters.push(Filter {
            field: "device_addr".into(),
            op: crate::parser::FilterOp::In,
            value: crate::parser::FilterValue::List(vec![]),
        });
        assert!(translate(&invalid, "serviceradar").is_err());
    }

    #[test]
    fn row_pagination_has_a_unique_tie_breaker() {
        for query in [
            "in:flows time:last_1h",
            "in:flows time:last_1h sort:time:desc",
            "in:attributed_flows time:last_1h sort:time:desc",
        ] {
            let compiled = translate(&plan(query), "serviceradar").unwrap();
            assert!(compiled.sql.contains("ORDER BY time DESC, id DESC LIMIT"));
        }
        let explicit =
            translate(&plan("in:flows time:last_1h sort:id:asc"), "serviceradar").unwrap();
        assert!(explicit.sql.contains("ORDER BY id ASC LIMIT"));
    }

    #[test]
    fn rejects_untrusted_sql_before_execution() {
        for query in [
            r#"in:flows time:last_1h stats:"(SELECT body FROM serviceradar.logs LIMIT 1) AS leaked" limit:1"#,
            r#"in:flows time:last_1h stats:"sum(body) as leaked""#,
            r#"in:flows time:last_1h stats:"sum(bytes_in) as total by body""#,
            r#"in:flows time:last_1h stats:"sum(bytes_in) as total;drop""#,
            "in:flows time:last_1h bucket:1m series:body",
            "in:flows time:last_1h unknown_field:value",
        ] {
            assert!(translate(&plan(query), "serviceradar").is_err(), "{query}");
        }
    }

    #[test]
    fn filtered_stats_preserve_order_and_cursor_offset() {
        let mut request = QueryRequest {
            query: r#"in:flows time:last_1h device_uid:device-example protocol_num:6 stats:"sum(bytes_total) as volume by src_endpoint_ip" sort:volume:desc limit:2"#.into(),
            limit: None,
            cursor: Some(crate::pagination::encode_cursor(2, &config().cursor_secret).unwrap()),
            direction: QueryDirection::Next,
            mode: Some("starrocks".into()),
        };
        let compiled = crate::query::translate_request(&config(), request.clone()).unwrap();
        assert!(
            compiled.sql.contains("AND device_uid = 'device-example'"),
            "{}",
            compiled.sql
        );
        assert!(compiled.sql.contains("AND protocol_num = '6'"));
        assert!(
            compiled
                .sql
                .ends_with("ORDER BY volume DESC LIMIT 2 OFFSET 2")
        );
        let next = compiled.pagination.next_cursor.unwrap();
        assert_eq!(
            crate::pagination::decode_cursor(&next, &config().cursor_secret, 100).unwrap(),
            4
        );
        request.cursor = Some(next);
        let next_page = crate::query::translate_request(&config(), request).unwrap();
        assert!(next_page.sql.ends_with("OFFSET 4"));
    }

    #[test]
    fn unmatched_attribution_and_long_downsample_use_raw_rows() {
        let compiled = translate(&plan(r#"in:attributed_flows time:last_7d attribution_status:unmatched stats:"count(*) as total by attribution_status""#), "serviceradar").unwrap();
        assert!(compiled.sql.contains("END = 'unmatched'"));
        assert!(compiled.sql.contains("GROUP BY CASE WHEN pid IS NULL"));
        assert!(!compiled.sql.contains("AND pid IS NOT NULL"));
        let chart = translate(
            &plan("in:attributed_flows time:last_7d bucket:1h agg:sum value_field:bytes_total"),
            "serviceradar",
        )
        .unwrap();
        assert!(chart.sql.contains("time_slice(time, INTERVAL 3600 SECOND)"));
        assert!(!chart.sql.contains("_hourly"));
    }

    #[test]
    fn whole_hour_flow_charts_read_the_hourly_rollup() {
        let chart = translate(
            &plan("in:flows time:last_7d bucket:1h agg:sum value_field:bytes_total"),
            "serviceradar",
        )
        .expect("rollup chart");
        assert!(
            chart
                .sql
                .contains("FROM serviceradar.ocsf_network_activity_hourly"),
            "{}",
            chart.sql
        );
        assert!(
            chart
                .sql
                .contains("time_slice(bucket, INTERVAL 3600 SECOND)")
        );
        assert!(chart.sql.contains("SUM(bytes_total) AS value"));
        refute_postgres(&chart.sql);
    }

    #[test]
    fn stale_rollups_compile_from_the_raw_table() {
        // The freshness gate selects translate_raw when the hourly MV is
        // stale: a rollup-eligible query must read the raw table, never CNPG.
        let raw = translate_raw(
            &plan("in:flows time:last_7d bucket:1h agg:sum value_field:bytes_total"),
            "serviceradar",
        )
        .expect("raw fallback");
        assert!(
            raw.sql.contains("FROM serviceradar.ocsf_network_activity"),
            "{}",
            raw.sql
        );
        assert!(!raw.sql.contains("_hourly"), "{}", raw.sql);
        // The raw table carries per-observation sampling weights the MV
        // already folded in, so the fallback re-applies them explicitly.
        assert!(raw.sql.contains("sampling_rate"), "{}", raw.sql);
        assert!(raw.sql.contains("AS value"), "{}", raw.sql);
        refute_postgres(&raw.sql);
    }

    #[test]
    fn rollup_windows_keep_every_hour_that_overlaps_them() {
        // 15:37 falls inside the 15:00 rollup row, which covers 15:00-16:00 and
        // therefore overlaps the window; a `bucket >= 15:37` predicate would
        // drop it whole and the first chart point would lose 23 minutes.
        // Flooring the bound to 15:00 admits that row and nothing earlier, and
        // the upper bound is pushed to the hour after the one holding 18:30.
        let rollup = translate(
            &plan(
                "in:flows time:[2026-09-11T15:37:12Z,2026-09-11T18:30:00Z] bucket:1h agg:sum value_field:bytes_total",
            ),
            "serviceradar",
        )
        .expect("overlap window");
        assert!(rollup.sql.contains("ocsf_network_activity_hourly"));
        assert!(
            rollup.sql.contains("`bucket` >= '2026-09-11T15:00:00Z'"),
            "{}",
            rollup.sql
        );
        assert!(
            rollup.sql.contains("`bucket` < '2026-09-11T19:00:00Z'"),
            "{}",
            rollup.sql
        );

        // A sub-hour bucket is not scored on the hour, so the window is the
        // window and the bound stays where the caller put it.
        let raw = translate(
            &plan(
                "in:flows time:[2026-09-11T15:37:12Z,2026-09-11T18:30:00Z] bucket:15m agg:sum value_field:bytes_total",
            ),
            "serviceradar",
        )
        .expect("raw window");
        assert!(!raw.sql.contains("_hourly"), "{}", raw.sql);
        assert!(
            raw.sql.contains("`time` >= '2026-09-11T15:37:12Z'"),
            "{}",
            raw.sql
        );
    }

    // The freshness gate recompiles the SAME query against the raw table when the
    // view falls behind, so neither bound may move with the source. `bucket >=
    // start` dropped the leading hour the view returns whole, and `time < end`
    // truncated the trailing hour the view returns whole, so the first and last
    // bars of the chart each changed by up to an hour of traffic with nothing in
    // the response saying so.
    #[test]
    fn a_stale_view_scores_the_same_hours_as_a_fresh_one() {
        for (window, lower, upper) in [
            (
                "[2026-09-11T15:37:12Z,2026-09-18T18:30:00Z]",
                "2026-09-11T15:00:00Z",
                "2026-09-18T19:00:00Z",
            ),
            (
                "[2026-09-11T00:00:00Z,2026-09-11T12:00:00Z]",
                "2026-09-11T00:00:00Z",
                "2026-09-11T13:00:00Z",
            ),
        ] {
            let query = format!("in:flows time:{window} bucket:1h agg:sum value_field:bytes_total");
            let fresh = translate(&plan(&query), "serviceradar").expect("fresh chart");
            let stale = translate_raw(&plan(&query), "serviceradar").expect("stale fallback");

            assert!(
                fresh.sql.contains("ocsf_network_activity_hourly"),
                "{}",
                fresh.sql
            );
            assert!(!stale.sql.contains("_hourly"), "{}", stale.sql);

            for sql in [&fresh.sql, &stale.sql] {
                assert!(sql.contains(&format!(">= '{lower}'")), "{sql}");
                assert!(sql.contains(&format!("< '{upper}'")), "{sql}");
            }
        }
    }

    #[test]
    fn rollups_are_skipped_whenever_they_cannot_reproduce_the_raw_answer() {
        // Sub-hour bucket: the rollup has no finer grain than an hour.
        let fine = translate(
            &plan("in:flows time:last_7d bucket:15m agg:sum value_field:bytes_total"),
            "serviceradar",
        )
        .expect("fine chart");
        assert!(!fine.sql.contains("_hourly"), "{}", fine.sql);

        // Filter on a column the flow rollup does not group by.
        let filtered = translate(
            &plan("in:flows time:last_7d src_endpoint_ip:192.0.2.10 bucket:1h agg:sum value_field:bytes_total"),
            "serviceradar",
        )
        .expect("filtered chart");
        assert!(!filtered.sql.contains("_hourly"), "{}", filtered.sql);

        // Series on a column the flow rollup does not group by.
        let series = translate(
            &plan("in:flows time:last_7d bucket:1h agg:sum value_field:bytes_total series:protocol_group"),
            "serviceradar",
        )
        .expect("series chart");
        assert!(!series.sql.contains("_hourly"), "{}", series.sql);

        // Scalar totals would gain or lose the partial hours at the edges.
        let totals = translate(
            &plan(r#"in:flows time:last_7d stats:"sum(bytes_total) as bytes_total""#),
            "serviceradar",
        )
        .expect("totals");
        assert!(!totals.sql.contains("_hourly"), "{}", totals.sql);
    }

    /// `value` holds cumulative counters. Summing them draws the counter, not the
    /// rate: a 1 Gbit/s port charted "476 GB/s" because its counter had reached
    /// 454 GB. The rate is the change between consecutive samples of ONE counter.
    #[test]
    fn metric_rate_differentiates_each_counter_instead_of_summing_it() {
        let chart = translate(
            &plan(
                r#"in:snmp_metrics device_id:"dev-1" if_index:7 time:last_24h bucket:5m agg:rate series:metric_name"#,
            ),
            "serviceradar",
        )
        .expect("interface rate chart");
        let sql = &chart.sql;

        assert!(!sql.contains("SUM(value)"), "{sql}");
        assert!(
            sql.contains(
                "LAG(value) OVER (PARTITION BY gateway_id, COALESCE(agent_id, ''), metric_type, \
                 metric_name, series_key ORDER BY timestamp) AS prev_v"
            ),
            "the previous sample must come from the same physical counter: {sql}"
        );
        assert!(
            sql.contains("(v - prev_v) / NULLIF(milliseconds_diff(ts, prev_ts) / 1000.0, 0)"),
            "a rate is a delta over real elapsed time: {sql}"
        );
        assert!(sql.contains("AVG(rate_value) AS value"), "{sql}");
        assert!(sql.contains("time_slice(ts, INTERVAL 300 SECOND)"), "{sql}");
        assert!(
            sql.contains("WHERE rate_value IS NOT NULL"),
            "a reset yields no rate: {sql}"
        );
        // The request's own predicates still bound the scan inside the CTE.
        assert!(
            sql.contains("FROM serviceradar.timeseries_metrics"),
            "{sql}"
        );
        assert!(sql.contains("if_index"), "{sql}");
        refute_postgres(sql);
    }

    /// A decrease is a wrap only when adding 2^32 gives a rate a 32-bit counter
    /// could produce; anything else is a reset and must not become a spike.
    #[test]
    fn metric_rate_recovers_a_32_bit_wrap_and_drops_a_reset() {
        let chart = translate(
            &plan("in:snmp_metrics time:last_1h bucket:1m agg:rate series:metric_name"),
            "serviceradar",
        )
        .expect("rate chart");
        let sql = &chart.sql;
        let wrapped =
            "(v + 4294967296 - prev_v) / NULLIF(milliseconds_diff(ts, prev_ts) / 1000.0, 0)";

        assert!(
            sql.contains(&format!(
                "WHEN counter_width = 32 AND {wrapped} <= 4294967296 THEN {wrapped}"
            )),
            "{sql}"
        );
        assert!(
            sql.contains(&format!(
                "WHEN prev_v < 4294967296 AND {wrapped} <= 4294967296 THEN {wrapped}"
            )),
            "{sql}"
        );
        assert!(sql.contains("ELSE NULL END AS rate_value"), "{sql}");
    }

    #[test]
    fn metric_rate_sum_adds_the_per_counter_rates() {
        let chart = translate(
            &plan("in:timeseries_metrics time:last_1h bucket:1m agg:rate_sum series:metric_name"),
            "serviceradar",
        )
        .expect("fleet rate chart");

        assert!(
            chart.sql.contains("SUM(rate_value) AS value"),
            "{}",
            chart.sql
        );
        assert!(chart.sql.contains("LAG(value) OVER"), "{}", chart.sql);
    }

    /// An hourly average of a counter cannot give back a delta, so a rate is
    /// never served from the rollup, however coarse the bucket.
    #[test]
    fn metric_rate_never_reads_the_hourly_rollup() {
        let chart = translate(
            &plan("in:snmp_metrics time:last_30d bucket:6h agg:rate series:device_id"),
            "serviceradar",
        )
        .expect("long rate chart");

        assert!(!chart.sql.contains("_hourly"), "{}", chart.sql);
        assert!(chart.sql.contains("LAG(value) OVER"), "{}", chart.sql);
    }

    /// A flow row is already a delta, so a flow "rate" stays the bucket total.
    #[test]
    fn flow_rate_is_still_the_bucket_total() {
        let chart = translate(
            &plan("in:flows time:last_1h bucket:5m agg:rate value_field:bytes_total"),
            "serviceradar",
        )
        .expect("flow rate chart");

        assert!(!chart.sql.contains("LAG("), "{}", chart.sql);
        assert!(chart.sql.contains("SUM("), "{}", chart.sql);
    }

    /// The per-core CPU chart splits by `core_id`, which lives in `tags`. With no
    /// way to name it the chart failed outright once metrics read the warehouse.
    #[test]
    fn metric_series_can_split_by_a_tag() {
        let chart = translate(
            &plan(
                r#"in:timeseries_metrics metric_type:"sysmon.cpu" time:last_24h bucket:5m agg:max series:core_id"#,
            ),
            "serviceradar",
        )
        .expect("per-core chart");
        assert!(
            chart
                .sql
                .contains(r#"CAST(get_json_string(tags, '$."core_id"') AS STRING) AS series"#),
            "{}",
            chart.sql
        );

        let by_tag = translate(
            &plan("in:timeseries_metrics time:last_1h bucket:1m agg:rate_sum series:tags.radius-server"),
            "serviceradar",
        )
        .expect("split by an arbitrary tag");
        assert!(
            by_tag
                .sql
                .contains(r#"get_json_string(tags, '$."radius-server"')"#),
            "a hyphen is part of the key, not an operator: {}",
            by_tag.sql
        );
    }

    /// The key reaches a SQL string, so it goes through CNPG's validator first.
    #[test]
    fn metric_tag_key_cannot_carry_sql() {
        let mut refused_by_the_dialect = 0;
        for series in ["tags.a'b", "tags.", r#"tags.a"b"#, "tags.a.b", "tags.a;b"] {
            let query =
                format!("in:timeseries_metrics time:last_1h bucket:1m agg:avg series:{series}");
            let Ok(parsed) = std::panic::catch_unwind(|| plan(&query)) else {
                continue; // refused by the parser, which is also a refusal
            };
            assert!(
                translate(&parsed, "serviceradar").is_err(),
                "{series} must be refused"
            );
            refused_by_the_dialect += 1;
        }
        assert!(
            refused_by_the_dialect > 0,
            "every case was stopped by the parser, so this proved nothing about the dialect"
        );
    }

    /// `sort:<time>:desc limit:N` keeps the NEWEST N buckets and still returns
    /// them oldest first. Ascending-only kept the oldest, so a long chart capped
    /// at 300 points stopped weeks before the present.
    #[test]
    fn downsample_limit_keeps_the_newest_buckets_in_chart_order() {
        let newest = translate(
            &plan("in:timeseries_metrics time:last_30d bucket:5m agg:avg sort:timestamp:desc limit:300"),
            "serviceradar",
        )
        .expect("newest buckets");
        assert!(
            newest
                .sql
                .starts_with("SELECT timestamp, series, value FROM (SELECT time_slice("),
            "{}",
            newest.sql
        );
        assert!(
            newest
                .sql
                .ends_with("GROUP BY 1, 2 ORDER BY 1 DESC, 2 ASC LIMIT 300 OFFSET 0) windowed ORDER BY 1 ASC, 2 ASC"),
            "{}",
            newest.sql
        );

        let oldest = translate(
            &plan("in:timeseries_metrics time:last_30d bucket:5m agg:avg limit:300"),
            "serviceradar",
        )
        .expect("default order");
        assert!(
            oldest
                .sql
                .ends_with("GROUP BY 1, 2 ORDER BY 1 ASC, 2 ASC LIMIT 300 OFFSET 0"),
            "{}",
            oldest.sql
        );
        assert!(!oldest.sql.contains("windowed"), "{}", oldest.sql);
    }

    /// The rate query reads CTEs, which must stay at the top level for the
    /// wrapped form to see them.
    #[test]
    fn rate_limit_keeps_the_newest_buckets_without_burying_its_ctes() {
        let chart = translate(
            &plan("in:snmp_metrics time:last_24h bucket:5m agg:rate series:metric_name sort:timestamp:desc limit:4"),
            "serviceradar",
        )
        .expect("newest rate buckets");
        assert!(chart.sql.starts_with("WITH ordered AS ("), "{}", chart.sql);
        assert!(
            chart.sql.contains(
                "SELECT timestamp, series, value FROM (SELECT time_slice(ts, INTERVAL 300 SECOND)"
            ),
            "{}",
            chart.sql
        );
        assert!(
            chart.sql.ends_with(
                "ORDER BY 1 DESC, 2 ASC LIMIT 4 OFFSET 0) windowed ORDER BY 1 ASC, 2 ASC"
            ),
            "{}",
            chart.sql
        );
    }

    #[test]
    fn metric_rollup_reaggregates_average_by_sample_count() {
        let chart = translate(
            &plan("in:snmp_metrics time:last_30d bucket:6h agg:avg value_field:value series:device_id"),
            "serviceradar",
        )
        .expect("metric rollup chart");
        assert!(
            chart
                .sql
                .contains("FROM serviceradar.timeseries_metrics_hourly"),
            "{}",
            chart.sql
        );
        assert!(
            chart
                .sql
                .contains("SUM(avg_value * sample_count) / NULLIF(SUM(sample_count), 0) AS value"),
            "{}",
            chart.sql
        );
        assert!(chart.sql.contains("metric_type = 'snmp'"), "{}", chart.sql);
        refute_postgres(&chart.sql);
    }

    #[test]
    fn flow_map_stats_group_by_endpoints_and_rewrite_bytes_total() {
        let compiled = translate(&plan(
            r#"in:flows time:last_1h stats:"sum(bytes_total) as bytes_total, sum(packets_total) as packets_total, count(*) as flow_count by src_endpoint_ip,dst_endpoint_ip" limit:120"#,
        ), "serviceradar")
        .expect("compile");
        assert!(
            compiled
                .sql
                .contains("FROM serviceradar.ocsf_network_activity")
        );
        assert!(
            compiled
                .sql
                .contains("COALESCE(bytes_in, 0) + COALESCE(bytes_out, 0)")
        );
        assert!(
            compiled.sql.contains("GROUP BY src_endpoint_ip"),
            "{}",
            compiled.sql
        );
        assert!(compiled.sql.contains("dst_endpoint_ip"), "{}", compiled.sql);
        assert!(!compiled.sql.contains("ocsf_network_activity_hourly"));
        refute_postgres(&compiled.sql);
    }

    #[test]
    fn flow_row_select_projects_protocol_group_and_bytes_total() {
        let compiled =
            translate(&plan("in:flows time:last_1h limit:5"), "serviceradar").expect("compile");
        assert!(
            compiled.sql.contains("AS protocol_group"),
            "{}",
            compiled.sql
        );
        assert!(compiled.sql.contains("AS bytes_total"), "{}", compiled.sql);
        assert!(
            compiled.sql.contains("ORDER BY time DESC"),
            "{}",
            compiled.sql
        );
        assert!(!compiled.sql.contains("SELECT *"), "{}", compiled.sql);
        refute_postgres(&compiled.sql);
    }

    #[test]
    fn flow_rows_project_stored_workload_identity() {
        for query in [
            "in:flows time:last_1h limit:5",
            "in:attributed_flows time:last_1h limit:5",
        ] {
            let compiled = translate(&plan(query), "serviceradar").expect("compile");
            let projection = compiled.sql.split(" FROM ").next().unwrap();
            assert!(
                projection
                    .split(", ")
                    .any(|field| field == "workload_identity")
            );
        }
    }

    #[test]
    fn interface_filtered_flow_rows_qualify_the_columns_the_join_also_defines() {
        let compiled = translate(
            &plan("in:flows in_if_name:eth0 time:last_24h sort:time:desc limit:100"),
            "serviceradar",
        )
        .expect("interface filtered rows");

        assert!(compiled.sql.contains("netflow_interface_cache AS in_if"));

        let projection = compiled.sql.split(" FROM ").next().unwrap();
        for ambiguous in ["device_uid", "sampler_address"] {
            assert!(
                !projection.split(", ").any(|item| item == ambiguous),
                "{projection}"
            );
            assert!(
                projection.contains(&format!("f.{ambiguous} AS {ambiguous}")),
                "{projection}"
            );
        }
        refute_postgres(&compiled.sql);
    }

    #[test]
    fn flow_downsample_emits_timestamp_series_value() {
        let compiled = translate(&plan(
            "in:flows time:last_1h bucket:1m agg:sum value_field:bytes_total series:protocol_group limit:2000",
        ), "serviceradar")
        .expect("compile");
        assert!(
            compiled
                .sql
                .contains("time_slice(time, INTERVAL 60 SECOND) AS timestamp"),
            "{}",
            compiled.sql
        );
        assert!(compiled.sql.contains("AS series"), "{}", compiled.sql);
        assert!(compiled.sql.contains("AS value"), "{}", compiled.sql);
        assert!(
            compiled.sql.contains("protocol_num = 6"),
            "{}",
            compiled.sql
        );
        assert!(compiled.sql.contains("GROUP BY 1, 2"), "{}", compiled.sql);
        refute_postgres(&compiled.sql);
    }

    #[test]
    fn flow_stats_compile_to_starrocks_sql_without_postgres_functions() {
        let compiled = translate(
            &plan(r#"in:flows time:last_1h stats:"sum(bytes_in) as bytes_in" limit:10"#),
            "serviceradar",
        )
        .expect("compile");
        assert!(
            compiled
                .sql
                .contains("FROM serviceradar.ocsf_network_activity")
        );
        assert!(compiled.sql.contains("SUM((CAST(COALESCE(bytes_in, 0) AS DOUBLE) * GREATEST(COALESCE(sampling_rate, 1), 1))) AS bytes_in"));
        assert!(compiled.sql.contains("LIMIT 10"));
        refute_postgres(&compiled.sql);
    }

    #[test]
    fn long_window_flow_stats_preserve_raw_window() {
        let compiled = translate(
            &plan(r#"in:flows time:last_7d stats:"sum(bytes_in) as bytes_in" limit:10"#),
            "serviceradar",
        )
        .expect("compile");
        assert!(
            compiled
                .sql
                .contains("FROM serviceradar.ocsf_network_activity WHERE")
        );
        assert!(compiled.sql.contains("SUM((CAST(COALESCE(bytes_in, 0) AS DOUBLE) * GREATEST(COALESCE(sampling_rate, 1), 1))) AS bytes_in"));
        refute_postgres(&compiled.sql);
    }

    #[test]
    fn unsupported_mv_filters_fall_back_to_raw_flows() {
        let compiled = translate(&plan(
            r#"in:flows time:last_7d src_endpoint_ip:192.0.2.10 stats:"sum(bytes_in) as bytes_in" limit:10"#,
        ), "serviceradar")
        .expect("compile");
        assert!(
            compiled
                .sql
                .contains("FROM serviceradar.ocsf_network_activity ")
                || compiled
                    .sql
                    .contains("FROM serviceradar.ocsf_network_activity WHERE")
        );
        assert!(!compiled.sql.contains("ocsf_network_activity_hourly"));
    }

    #[test]
    fn timeseries_metrics_compile_to_starrocks_sql() {
        let compiled = translate(
            &plan(r#"in:timeseries_metrics time:last_1h stats:"avg(value) as avg_value" limit:20"#),
            "serviceradar",
        )
        .expect("compile");
        assert!(
            compiled
                .sql
                .contains("FROM serviceradar.timeseries_metrics")
        );
        assert!(compiled.sql.contains("AVG(value) AS avg_value"));
        refute_postgres(&compiled.sql);
    }

    #[test]
    fn long_window_metrics_preserve_raw_window() {
        let compiled = translate(
            &plan(r#"in:snmp_metrics time:last_7d stats:"avg(value) as avg_value" limit:20"#),
            "serviceradar",
        )
        .expect("compile");
        assert!(
            compiled
                .sql
                .contains("FROM serviceradar.timeseries_metrics WHERE")
        );
        assert!(compiled.sql.contains("metric_type = 'snmp'"));
        refute_postgres(&compiled.sql);
    }

    #[test]
    fn logs_and_events_compile_to_starrocks_sql() {
        let logs = translate(&plan("in:logs time:last_1h limit:5"), "serviceradar").expect("logs");
        assert!(logs.sql.contains("FROM serviceradar.logs"));
        assert!(logs.sql.contains("`timestamp`"));

        let events =
            translate(&plan("in:events time:last_1h limit:5"), "serviceradar").expect("events");
        assert!(events.sql.contains("FROM serviceradar.events"));
        assert!(events.sql.contains("`time`"));
        refute_postgres(&logs.sql);
        refute_postgres(&events.sql);
    }

    #[test]
    fn attributed_flows_filter_persisted_pid_not_live_catalog_join() {
        let compiled = translate(
            &plan("in:attributed_flows time:last_1h limit:5"),
            "serviceradar",
        )
        .expect("compile");
        assert!(
            compiled
                .sql
                .contains("FROM serviceradar.ocsf_network_activity")
        );
        assert!(
            !compiled.sql.contains("AND pid IS NOT NULL"),
            "{}",
            compiled.sql
        );
        assert!(
            compiled.sql.contains("AS attribution_status"),
            "{}",
            compiled.sql
        );
        assert!(!compiled.sql.contains("flow_process_attribution_current"));
        assert!(!compiled.sql.contains("ocsf_network_activity_hourly"));
        refute_postgres(&compiled.sql);
    }

    #[test]
    fn flow_hostname_join_cnpg_devices() {
        let compiled = translate(&plan(
            r#"in:flows hostname:host-alpha time:last_1h stats:"sum(bytes_in) as bytes_in" limit:10"#,
        ), "serviceradar")
        .expect("compile");
        assert!(
            compiled
                .sql
                .contains("cnpg_platform.platform.ocsf_devices AS dev")
        );
        assert!(compiled.sql.contains("dev.uid = f.device_uid"));
        refute_postgres(&compiled.sql);
    }

    #[test]
    fn country_breakdowns_resolve_against_the_cnpg_geoip_cache() {
        // Neither backend stores a country on the flow row; CNPG joins
        // ip_geo_enrichment_cache at query time and so must the warehouse, or
        // the geo heatmap is refused as an unsupported field.
        let base = "in:flows time:last_1h";
        let dst = translate(
            &plan(&format!(
                "{base} stats:\"sum(bytes_total) as total_bytes by dst_country_iso2\" sort:total_bytes:desc limit:64"
            )),
            "serviceradar",
        )
        .expect("destination country breakdown");
        assert!(
            dst.sql.contains(
                "LEFT JOIN cnpg_platform.platform.ip_geo_enrichment_cache AS dst_geo ON dst_geo.ip = f.dst_endpoint_ip AND (dst_geo.expires_at IS NULL OR dst_geo.expires_at > UTC_TIMESTAMP())"
            ),
            "{}",
            dst.sql
        );
        assert!(
            dst.sql
                .contains("COALESCE(dst_geo.country_iso2, 'Unknown')")
        );
        assert!(!dst.sql.contains("src_geo"), "{}", dst.sql);
        refute_postgres(&dst.sql);

        let src = translate(
            &plan(&format!(
                "{base} stats:\"sum(bytes_total) as total_bytes by src_country\" sort:total_bytes:desc limit:64"
            )),
            "serviceradar",
        )
        .expect("source country breakdown");
        assert!(
            src.sql
                .contains("ip_geo_enrichment_cache AS src_geo ON src_geo.ip = f.src_endpoint_ip")
        );
        assert!(
            src.sql
                .contains("COALESCE(src_geo.country_iso2, 'Unknown')")
        );
        assert!(!src.sql.contains("dst_geo"), "{}", src.sql);

        // A plain flow query must not pay for a join it does not read.
        let plain = translate(
            &plan(&format!(
                "{base} stats:\"sum(bytes_total) as total_bytes by dst_endpoint_port\" limit:5"
            )),
            "serviceradar",
        )
        .expect("plain breakdown");
        assert!(
            !plain.sql.contains("ip_geo_enrichment_cache"),
            "{}",
            plain.sql
        );
    }

    #[test]
    fn top_interfaces_resolve_names_and_speeds_from_the_cnpg_interface_cache() {
        // The warehouse row stores only the ifIndex; the name and speed live in
        // netflow_interface_cache, which CNPG reaches with a lateral subquery.
        let base = "in:flows time:last_1h";
        let ingress = translate(
            &plan(&format!(
                "{base} stats:sum(bytes_total) as bytes_total by sampler_address,input_snmp,in_if_name,in_if_speed_bps sort:bytes_total:desc limit:5"
            )),
            "serviceradar",
        )
        .expect("ingress top interfaces");
        assert!(
            ingress.sql.contains(
                "LEFT JOIN cnpg_platform.platform.netflow_interface_cache AS in_if ON in_if.sampler_address = f.sampler_address AND in_if.if_index = f.input_snmp"
            ),
            "{}",
            ingress.sql
        );
        assert!(ingress.sql.contains("COALESCE(in_if.if_name, 'Unknown')"));
        assert!(
            ingress
                .sql
                .contains("COALESCE(CAST(in_if.if_speed_bps AS STRING), 'Unknown')")
        );
        assert!(!ingress.sql.contains("out_if"));
        refute_postgres(&ingress.sql);

        let egress = translate(
            &plan(&format!(
                "{base} stats:sum(bytes_total) as bytes_total by sampler_address,output_snmp,out_if_name,out_if_speed_bps sort:bytes_total:desc limit:5"
            )),
            "serviceradar",
        )
        .expect("egress top interfaces");
        assert!(
            egress.sql.contains(
                "LEFT JOIN cnpg_platform.platform.netflow_interface_cache AS out_if ON out_if.sampler_address = f.sampler_address AND out_if.if_index = f.output_snmp"
            ),
            "{}",
            egress.sql
        );
        assert!(egress.sql.contains("COALESCE(out_if.if_name, 'Unknown')"));
        assert!(!egress.sql.contains("in_if"));
    }

    #[test]
    fn flows_without_interface_fields_do_not_join_the_interface_cache() {
        let compiled = translate(
            &plan("in:flows time:last_1h stats:sum(bytes_total) as bytes_total by sampler_address limit:5"),
            "serviceradar",
        )
        .expect("compile");
        assert!(!compiled.sql.contains("netflow_interface_cache"));
    }

    #[test]
    fn unsupported_prefix_tag_filter_returns_capability_error() {
        assert!(
            translate(
                &plan("in:flows prefix_tag:example time:last_1h limit:10"),
                "serviceradar"
            )
            .is_err()
        );
    }

    #[test]
    fn plain_flows_do_not_join_the_cnpg_catalog() {
        let compiled =
            translate(&plan("in:flows time:last_1h limit:5"), "serviceradar").expect("compile");
        assert!(!compiled.sql.contains("cnpg_platform"));
        assert!(
            compiled
                .sql
                .contains("FROM serviceradar.ocsf_network_activity")
        );
    }

    #[test]
    fn current_alert_state_stays_a_capability_error() {
        let err =
            translate(&plan("in:alerts time:last_1h limit:5"), "serviceradar").expect_err("alerts");
        assert!(err.to_string().contains("starrocks_unsupported_entity"));
    }

    #[test]
    fn flow_summary_stats_carry_observed_coverage_bounds() {
        // The dashboard divides bytes/packets by MAX(time) - MIN(time), the same
        // observed-coverage denominator CNPG uses, so those two bounds have to
        // survive compilation.
        let compiled = translate(
            &plan(
                r#"in:flows time:last_1h stats:"sum(bytes_total) as bytes_total, sum(packets_total) as packets_total, count(*) as flow_count, min(time) as first_seen, max(time) as last_seen" limit:1"#,
            ),
            "serviceradar",
        )
        .expect("flow summary");
        assert!(compiled.sql.contains("AS first_seen"));
        assert!(compiled.sql.contains("AS last_seen"));
    }

    #[test]
    fn attributed_flows_are_a_subset_of_flows_not_a_projection() {
        // CNPG filters ocsf_payload ->> 'event_type' = 'attributed_flow'; without
        // the same predicate the Attributed Flows page aggregates every NetFlow
        // record in the window and labels it all unmatched.
        let attributed = translate(
            &plan("in:attributed_flows time:last_1h limit:5"),
            "serviceradar",
        )
        .expect("attributed");
        assert!(attributed.sql.contains("event_type = 'attributed_flow'"));

        let flows =
            translate(&plan("in:flows time:last_1h limit:5"), "serviceradar").expect("flows");
        assert!(!flows.sql.contains("event_type ="));
    }

    #[test]
    fn every_dataset_is_qualified_with_the_configured_database() {
        for query in [
            "in:flows time:last_1h limit:5",
            "in:attributed_flows time:last_1h limit:5",
            "in:timeseries_metrics time:last_1h limit:5",
            "in:logs time:last_1h limit:5",
            "in:events time:last_1h limit:5",
        ] {
            let compiled = translate(&plan(query), "warehouse").expect(query);
            assert!(
                compiled.sql.contains("warehouse."),
                "{query} did not use the configured database: {}",
                compiled.sql
            );
            assert!(
                !compiled.sql.contains("serviceradar."),
                "{query} still names the default database: {}",
                compiled.sql
            );
        }
    }

    #[test]
    fn prefix_tags_are_read_from_the_warehouse_row_not_the_catalog() {
        let compiled = translate(
            &plan("in:flows time:last_1h src_prefix_tags:example limit:5"),
            "serviceradar",
        )
        .expect("prefix tags");
        assert!(!compiled.sql.contains("cnpg_platform"));
        assert!(!compiled.sql.contains("prefix_tags_catalog"));
    }

    #[test]
    fn event_entities_carry_their_class_and_category_discriminators() {
        // The warehouse `events` table holds every shadowed family, so an
        // entity scoped to one of them must filter the same way CNPG does or
        // it returns firewall/Falco/Trivy rows labelled as that family.
        let findings = translate(
            &plan("in:security_findings time:last_1h limit:5"),
            "serviceradar",
        )
        .expect("findings");
        assert!(findings.sql.contains("FROM serviceradar.events"));
        assert!(findings.sql.contains("category_uid = 2"));

        let scans = translate(
            &plan("in:scan_activity time:last_1h limit:5"),
            "serviceradar",
        )
        .expect("scans");
        assert!(scans.sql.contains("class_uid = 6007 AND category_uid = 6"));

        let dns = translate(
            &plan("in:dns_activity time:last_1h limit:5"),
            "serviceradar",
        )
        .expect("dns");
        assert!(dns.sql.contains("class_uid = 4003 AND category_uid = 4"));

        // The unscoped entity spans every family, exactly as it does on CNPG.
        let all =
            translate(&plan("in:events time:last_1h limit:5"), "serviceradar").expect("events");
        assert!(!all.sql.contains("class_uid"));
        assert!(!all.sql.contains("category_uid"));
    }

    #[test]
    fn event_entity_aliases_resolve_to_the_same_scope() {
        for (query, expected) in [
            ("in:findings time:last_1h limit:5", "category_uid = 2"),
            (
                "in:security_finding time:last_1h limit:5",
                "category_uid = 2",
            ),
            (
                "in:security_scans time:last_1h limit:5",
                "class_uid = 6007 AND category_uid = 6",
            ),
            (
                "in:pdns time:last_1h limit:5",
                "class_uid = 4003 AND category_uid = 4",
            ),
        ] {
            let compiled = translate(&plan(query), "serviceradar").expect(query);
            assert!(compiled.sql.contains(expected), "{query}: {}", compiled.sql);
        }
    }

    #[test]
    fn metric_entities_carry_their_metric_type_discriminator() {
        let snmp = translate(
            &plan("in:snmp_metrics time:last_1h limit:5"),
            "serviceradar",
        )
        .expect("snmp");
        assert!(snmp.sql.contains("FROM serviceradar.timeseries_metrics"));
        assert!(snmp.sql.contains("metric_type = 'snmp'"));

        let rperf = translate(
            &plan("in:rperf_metrics time:last_1h limit:5"),
            "serviceradar",
        )
        .expect("rperf");
        assert!(rperf.sql.contains("metric_type = 'rperf'"));

        // The unscoped entity spans every family, exactly as it does on CNPG.
        let all = translate(
            &plan("in:timeseries_metrics time:last_1h limit:5"),
            "serviceradar",
        )
        .expect("all");
        assert!(!all.sql.contains("metric_type ="));
    }

    #[test]
    fn sysmon_entities_are_not_served_from_the_metrics_table() {
        // CNPG keeps these in their own tables with their own columns, and
        // EventWriter never mirrors them, so answering from timeseries_metrics
        // would return interface counters labelled as CPU.
        for query in [
            "in:cpu_metrics time:last_1h limit:5",
            "in:memory_metrics time:last_1h limit:5",
            "in:disk_metrics time:last_1h limit:5",
            "in:process_metrics time:last_1h limit:5",
        ] {
            let err = translate(&plan(query), "serviceradar").expect_err(query);
            assert!(err.to_string().contains("starrocks_unsupported_entity"));
        }
    }

    #[test]
    fn flow_grouping_quotes_the_reserved_partition_column() {
        let compiled = translate(&plan(
            r#"in:flows time:last_1h stats:"sum(bytes_total) as bytes_total by src_endpoint_ip,dst_endpoint_ip,partition" limit:10"#,
        ), "serviceradar")
        .expect("partition grouping");
        assert!(compiled.sql.contains("`partition` AS flow_partition"));
        assert!(
            compiled
                .sql
                .contains("GROUP BY src_endpoint_ip, dst_endpoint_ip, `partition`")
        );
    }

    #[test]
    fn unsupported_entities_return_a_capability_error() {
        let err = translate(&plan("in:devices time:last_1h limit:5"), "serviceradar")
            .expect_err("devices");
        assert!(err.to_string().contains("starrocks_unsupported_entity"));
    }

    #[test]
    fn tcp_flag_labels_are_rebuilt_from_the_bitmask() {
        for group in ["tcp_flags_label", "tcp_flag"] {
            let compiled = translate(
                &plan(&format!(
                    r#"in:flows time:last_1h stats:"count(*) as flows by {group}" limit:10"#
                )),
                "serviceradar",
            )
            .expect(group);
            let sql = &compiled.sql;
            let label = "CASE WHEN tcp_flags IS NULL OR tcp_flags < 0 OR BITAND(tcp_flags, 255) = 0 THEN 'none' ELSE CONCAT_WS(',', IF(BITAND(tcp_flags, 128) = 0, NULL, 'CWR'), IF(BITAND(tcp_flags, 64) = 0, NULL, 'ECE'), IF(BITAND(tcp_flags, 32) = 0, NULL, 'URG'), IF(BITAND(tcp_flags, 16) = 0, NULL, 'ACK'), IF(BITAND(tcp_flags, 8) = 0, NULL, 'PSH'), IF(BITAND(tcp_flags, 4) = 0, NULL, 'RST'), IF(BITAND(tcp_flags, 2) = 0, NULL, 'SYN'), IF(BITAND(tcp_flags, 1) = 0, NULL, 'FIN')) END";
            assert!(
                sql.contains(&format!("{label} AS tcp_flags_label")),
                "{sql}"
            );
            assert!(sql.contains(&format!(" GROUP BY {label}")), "{sql}");
            // The warehouse row has no label array, and needs no catalog.
            assert!(!sql.contains("tcp_flags_labels"), "{sql}");
            assert!(!sql.contains("array_to_string"), "{sql}");
            assert!(!sql.contains("cnpg_platform"), "{sql}");
        }
    }

    // Evaluates the emitted label expression the way the warehouse does:
    // BITAND on the integer, CONCAT_WS skipping NULL arguments, and a NULL
    // comparison never being true.
    fn eval_tcp_flags_label(sql: &str, mask: Option<i64>) -> String {
        let rest = sql
            .strip_prefix("CASE WHEN m IS NULL OR m < 0 OR BITAND(m, ")
            .expect("guard");
        let (known, rest) = rest.split_once(") = 0 THEN '").expect("known bits");
        let known: i64 = known.parse().expect("known bits literal");
        let (empty, rest) = rest.split_once("' ELSE CONCAT_WS('").expect("empty label");
        let (separator, rest) = rest.split_once("', ").expect("separator");
        let terms = rest.strip_suffix(") END").expect("end");
        let Some(mask) = mask.filter(|mask| *mask >= 0 && mask & known != 0) else {
            return empty.to_string();
        };
        terms
            .split("), ")
            .filter_map(|term| {
                let term = term.strip_prefix("IF(BITAND(m, ").expect("term");
                let (bit, name) = term.split_once(") = 0, NULL, '").expect("bit");
                let bit: i64 = bit.parse().expect("bit literal");
                let name = name.trim_end_matches(')').trim_end_matches('\'');
                (mask & bit != 0).then_some(name)
            })
            .collect::<Vec<_>>()
            .join(separator)
    }

    #[test]
    fn tcp_flag_labels_name_set_bits_in_order_and_none_otherwise() {
        let sql = tcp_flags_label_sql("m");
        for (mask, label) in [
            (None, "none"),
            (Some(0), "none"),
            (Some(256), "none"),
            (Some(-1), "none"),
            (Some(2), "SYN"),
            (Some(18), "ACK,SYN"),
            (Some(255), "CWR,ECE,URG,ACK,PSH,RST,SYN,FIN"),
        ] {
            assert_eq!(eval_tcp_flags_label(&sql, mask), label, "{mask:?}");
        }
    }

    #[test]
    fn duration_buckets_use_the_cnpg_edges() {
        for group in ["duration_bucket", "duration"] {
            let compiled = translate(
                &plan(&format!(
                    r#"in:flows time:last_1h stats:"count(*) as flows by {group}" limit:10"#
                )),
                "serviceradar",
            )
            .expect(group);
            let sql = &compiled.sql;
            let bucket = "CASE WHEN start_time IS NULL OR end_time IS NULL THEN 'unknown' WHEN MILLISECONDS_DIFF(end_time, start_time) < 1000 THEN '<1s' WHEN MILLISECONDS_DIFF(end_time, start_time) < 10000 THEN '1-10s' WHEN MILLISECONDS_DIFF(end_time, start_time) < 60000 THEN '10-60s' WHEN MILLISECONDS_DIFF(end_time, start_time) < 300000 THEN '1-5m' ELSE '>5m' END";
            assert!(
                sql.contains(&format!("{bucket} AS duration_bucket")),
                "{sql}"
            );
            assert!(sql.contains(&format!(" GROUP BY {bucket}")), "{sql}");
            assert!(!sql.contains("EXTRACT(EPOCH"), "{sql}");
            assert!(!sql.contains("cnpg_platform"), "{sql}");
        }
    }

    #[test]
    fn exporter_names_resolve_against_the_cnpg_exporter_cache() {
        let compiled = translate(
            &plan(
                r#"in:flows time:last_1h stats:"sum(bytes_total) as bytes by exporter_name" sort:bytes:desc limit:10"#,
            ),
            "serviceradar",
        )
        .expect("exporter_name grouping");
        let sql = &compiled.sql;
        assert!(
            sql.contains(
                "FROM serviceradar.ocsf_network_activity AS f LEFT JOIN cnpg_platform.platform.netflow_exporter_cache AS exp ON exp.sampler_address = f.sampler_address"
            ),
            "{sql}"
        );
        assert!(
            sql.contains("COALESCE(exp.exporter_name, 'Unknown') AS exporter_name"),
            "{sql}"
        );
        assert!(
            sql.contains(" GROUP BY COALESCE(exp.exporter_name, 'Unknown')"),
            "{sql}"
        );
        // Both tables carry `sampler_address`, so the flow side is qualified.
        assert!(sql.contains("f.bytes_total"), "{sql}");
        assert!(sql.contains("f.`time` >= "), "{sql}");
        assert!(!sql.contains("ocsf_network_activity_hourly"), "{sql}");
        assert!(!sql.contains("(SELECT ec.exporter_name"), "{sql}");

        let series = translate(
            &plan("in:flows time:last_24h bucket:1h agg:sum value_field:bytes_total series:exporter_name"),
            "serviceradar",
        )
        .expect("exporter_name series");
        assert!(
            series.sql.contains("netflow_exporter_cache AS exp"),
            "{}",
            series.sql
        );
        assert!(
            !series.sql.contains("ocsf_network_activity_hourly"),
            "{}",
            series.sql
        );

        let plain = translate(
            &plan(r#"in:flows time:last_1h stats:"count(*) as flows by sampler_address""#),
            "serviceradar",
        )
        .expect("plain grouping");
        assert!(
            !plain.sql.contains("netflow_exporter_cache"),
            "{}",
            plain.sql
        );
    }

    #[test]
    fn cidr_filters_become_a_hex_range_over_the_endpoint() {
        for (query, endpoint, other, width, first, last) in [
            (
                "src_cidr:192.0.2.0/24",
                "src",
                "dst",
                8,
                "c0000200",
                "c00002ff",
            ),
            (
                "dst_cidr:198.51.100.64/26",
                "dst",
                "src",
                8,
                "c6336440",
                "c633647f",
            ),
            (
                "dst_cidr:203.0.113.7/32",
                "dst",
                "src",
                8,
                "cb007107",
                "cb007107",
            ),
            (
                "src_cidr:0.0.0.0/0",
                "src",
                "dst",
                8,
                "00000000",
                "ffffffff",
            ),
            (
                "src_cidr:2001:db8:12::/48",
                "src",
                "dst",
                32,
                "20010db8001200000000000000000000",
                "20010db80012ffffffffffffffffffff",
            ),
            (
                "dst_cidr:2001:db8::1/128",
                "dst",
                "src",
                32,
                "20010db8000000000000000000000001",
                "20010db8000000000000000000000001",
            ),
        ] {
            let compiled = translate(
                &plan(&format!(
                    r#"in:flows time:last_1h {query} stats:"count(*) as flows" limit:10"#
                )),
                "serviceradar",
            )
            .expect(query);
            let sql = &compiled.sql;
            assert!(
                sql.contains(&format!(
                    " AND any_match(h -> (LENGTH(h) = {width} AND h BETWEEN '{first}' AND '{last}'), [f.{endpoint}_ip_hex])"
                )),
                "{query}: {sql}"
            );
            assert!(
                !sql.contains(&format!("[f.{other}_ip_hex]")),
                "{query}: {sql}"
            );
            assert!(
                sql.contains("AS src_ip_hex") && sql.contains("AS dst_ip_hex"),
                "{query}: {sql}"
            );
            assert!(sql.contains(") AS f WHERE f.`time` >= "), "{query}: {sql}");
            // Containment against a literal needs neither the catalog nor the
            // configured local CIDRs.
            assert!(!sql.contains("cnpg_platform"), "{query}: {sql}");
            assert!(!sql.contains("lc.firsts"), "{query}: {sql}");
            // More than one reference to the derived hex trips the analyzer's
            // expression-size limit on the warehouse.
            assert_eq!(
                sql.matches(&format!("f.{endpoint}_ip_hex")).count(),
                1,
                "{query}: {sql}"
            );
            assert!(!sql.contains("<<="), "{query}: {sql}");
            assert!(
                !sql.contains("ocsf_network_activity_hourly"),
                "{query}: {sql}"
            );
        }
    }

    #[test]
    fn negated_cidr_filters_keep_flows_without_a_parseable_address() {
        let compiled = translate(
            &plan(r#"in:flows time:last_1h !src_cidr:192.0.2.0/24 stats:"count(*) as flows""#),
            "serviceradar",
        )
        .expect("negated src_cidr");
        assert!(
            compiled.sql.contains(
                " AND any_match(h -> h IS NULL OR NOT ((LENGTH(h) = 8 AND h BETWEEN 'c0000200' AND 'c00002ff')), [f.src_ip_hex])"
            ),
            "{}",
            compiled.sql
        );
        assert_eq!(compiled.sql.matches("f.src_ip_hex").count(), 1);
    }

    #[test]
    fn cidr_lists_test_every_range_inside_one_lambda() {
        let ranges = "(LENGTH(h) = 8 AND h BETWEEN 'c0000200' AND 'c00002ff') OR (LENGTH(h) = 32 AND h BETWEEN '20010db8001200000000000000000000' AND '20010db80012ffffffffffffffffffff')";
        for (query, endpoint, test) in [
            (
                "src_cidr:(192.0.2.0/24,2001:db8:12::/48)",
                "src",
                ranges.to_string(),
            ),
            (
                "!dst_cidr:(192.0.2.0/24,2001:db8:12::/48)",
                "dst",
                format!("h IS NULL OR NOT ({ranges})"),
            ),
        ] {
            let compiled = translate(
                &plan(&format!(
                    r#"in:flows time:last_1h {query} stats:"count(*) as flows""#
                )),
                "serviceradar",
            )
            .expect(query);
            let sql = &compiled.sql;
            assert!(
                sql.contains(&format!(
                    " AND any_match(h -> {test}, [f.{endpoint}_ip_hex])"
                )),
                "{query}: {sql}"
            );
            assert_eq!(
                sql.matches(&format!("f.{endpoint}_ip_hex")).count(),
                1,
                "{query}: {sql}"
            );
        }
    }

    #[test]
    fn a_cidr_list_with_one_malformed_entry_is_rejected() {
        for (list, message) in [
            ("(192.0.2.0/24,198.51.100.0/33)", "CIDR prefix length"),
            ("(192.0.2.5/24,198.51.100.0/24)", "bits set to the right"),
        ] {
            for prefix in ["", "!"] {
                let err = translate(
                    &plan(&format!("in:flows time:last_1h {prefix}src_cidr:{list}")),
                    "serviceradar",
                )
                .expect_err(list);
                assert!(matches!(err, ServiceError::InvalidRequest(_)), "{err}");
                assert!(err.to_string().contains(message), "{list}: {err}");
            }
        }
    }

    #[test]
    fn cidr_filters_compose_with_catalog_joins_and_direction() {
        let joined = translate(
            &plan(
                r#"in:flows time:last_1h src_cidr:192.0.2.0/24 stats:"count(*) as flows by exporter_name""#,
            ),
            "serviceradar",
        )
        .expect("cidr with exporter join");
        assert!(
            joined.sql.contains(
                "normalized) AS f LEFT JOIN cnpg_platform.platform.netflow_exporter_cache AS exp"
            ),
            "{}",
            joined.sql
        );
        assert!(
            joined
                .sql
                .contains("BETWEEN 'c0000200' AND 'c00002ff'), [f.src_ip_hex])"),
            "{}",
            joined.sql
        );

        let directed = translate(
            &plan(
                r#"in:flows time:last_1h dst_cidr:192.0.2.0/24 stats:"count(*) as flows by direction""#,
            ),
            "serviceradar",
        )
        .expect("cidr with direction");
        assert_eq!(directed.sql.matches("AS src_ip_hex").count(), 1);
        assert!(
            directed
                .sql
                .contains("BETWEEN 'c0000200' AND 'c00002ff'), [f.dst_ip_hex])"),
            "{}",
            directed.sql
        );
        assert!(directed.sql.contains("lc.firsts"), "{}", directed.sql);
    }

    #[test]
    fn cidr_prefix_grouping_does_not_pay_for_the_hex_source() {
        let compiled = translate(
            &plan(r#"in:flows time:last_1h stats:"count(*) as flows by src_cidr:24""#),
            "serviceradar",
        )
        .expect("prefix grouping");
        assert!(!compiled.sql.contains("ip_hex"), "{}", compiled.sql);
    }

    #[test]
    fn malformed_cidr_filters_are_rejected() {
        for (value, message) in [
            ("192.0.2.0", "CIDR must be like"),
            ("192.0.2.0/33", "CIDR prefix length must be <= 32"),
            ("2001:db8::/129", "CIDR prefix length must be <= 128"),
            ("192.0.2.999/24", "valid IPv4/IPv6 address"),
            ("192.0.2.0/abc", "valid prefix length"),
            ("192.0.2.5/24", "bits set to the right of the prefix"),
            ("2001:db8::1/32", "bits set to the right of the prefix"),
        ] {
            for field in ["src_cidr", "dst_cidr"] {
                let err = translate(
                    &plan(&format!("in:flows time:last_1h {field}:{value}")),
                    "serviceradar",
                )
                .expect_err(value);
                assert!(
                    matches!(err, ServiceError::InvalidRequest(_)),
                    "{field}:{value}: {err}"
                );
                assert!(err.to_string().contains(message), "{field}:{value}: {err}");
            }
        }
    }

    #[test]
    fn cidr_filters_support_only_equality() {
        for (field, query) in [
            ("src_cidr", "src_cidr:>192.0.2.0/24"),
            ("dst_cidr", "dst_cidr:>=2001:db8::/32"),
            ("src_cidr", "src_cidr:<192.0.2.0/24"),
        ] {
            let err = translate(
                &plan(&format!("in:flows time:last_1h {query}")),
                "serviceradar",
            )
            .expect_err(query);
            assert!(
                matches!(err, ServiceError::InvalidRequest(_)),
                "{query}: {err}"
            );
            assert!(
                err.to_string().contains(&format!(
                    "{field} filter only supports equality or list matching"
                )),
                "{query}: {err}"
            );
        }
    }

    fn refused(query: &str) -> String {
        match translate(&plan(query), "serviceradar") {
            Ok(compiled) => panic!("expected a refusal, compiled: {}", compiled.sql),
            Err(err) => {
                assert!(
                    matches!(err, ServiceError::InvalidRequest(_)),
                    "expected InvalidRequest, got {err:?}"
                );
                err.to_string()
            }
        }
    }

    #[test]
    fn the_log_severity_rollup_counts_raw_rows_under_the_payload_keys() {
        let compiled = translate(
            &plan("in:logs time:[2026-09-19T10:00:00Z,2026-09-19T16:00:00Z] rollup_stats:severity"),
            "serviceradar",
        )
        .expect("severity rollup");
        let sql = &compiled.sql;

        // The card extractor reads these six keys off the first result row.
        for alias in ["total", "fatal", "error", "warning", "info", "debug"] {
            assert!(sql.contains(&format!("AS `{alias}`")), "{alias}: {sql}");
        }
        assert!(sql.starts_with("SELECT COUNT(*) AS `total`"), "{sql}");
        assert!(!sql.contains("SELECT *"), "{sql}");
        assert!(sql.contains("FROM serviceradar.logs"), "{sql}");
        assert!(
            sql.contains(
                "`timestamp` >= '2026-09-19T10:00:00Z' AND `timestamp` < '2026-09-19T16:00:00Z'"
            ),
            "{sql}"
        );
        // Text decides before the number does, and critical is an error.
        let text_arm = sql
            .find("IN ('error', 'err', 'critical'")
            .expect("error texts");
        let number_arm = sql
            .find("severity_number BETWEEN 21 AND 24")
            .expect("fatal numbers");
        assert!(text_arm < number_arm, "{sql}");
        assert!(sql.contains("IN ('fatal', 'emergency', 'alert',"), "{sql}");
        assert!(
            sql.contains("severity_number BETWEEN 1 AND 8 THEN 'debug'"),
            "{sql}"
        );
        refute_postgres(sql);
        assert!(!sql.contains("jsonb_build_object"), "{sql}");
        assert!(!sql.contains("logs_severity_stats_5m"), "{sql}");
    }

    #[test]
    fn the_log_severity_rollup_accepts_only_the_service_name_filter() {
        let compiled = translate(
            &plan("in:logs time:last_1h rollup_stats:severity service_name:(alpha,beta)"),
            "serviceradar",
        )
        .expect("service filter");
        assert!(
            compiled.sql.contains("service_name IN ('alpha', 'beta')"),
            "{}",
            compiled.sql
        );

        let message = refused("in:logs time:last_1h rollup_stats:severity source:host01");
        assert!(
            message.contains("rollup_stats:severity only supports service_name"),
            "{message}"
        );
    }

    #[test]
    fn the_anomaly_findings_rollup_counts_raw_rows_under_the_payload_keys() {
        let compiled = translate(
            &plan(
                "in:events time:[2026-09-19T10:00:00Z,2026-09-19T16:00:00Z] rollup_stats:anomaly_findings limit:1",
            ),
            "serviceradar",
        )
        .expect("anomaly rollup");
        let sql = &compiled.sql;

        for alias in ["total", "anomalies", "at_risk", "critical", "high"] {
            assert!(sql.contains(&format!("AS `{alias}`")), "{alias}: {sql}");
        }
        assert!(!sql.contains("SELECT *"), "{sql}");
        assert!(sql.contains("FROM serviceradar.events"), "{sql}");
        assert!(
            sql.contains("`time` >= '2026-09-19T10:00:00Z' AND `time` < '2026-09-19T16:00:00Z'"),
            "{sql}"
        );
        assert!(
            sql.contains("class_uid = 2004 AND category_uid = 2"),
            "{sql}"
        );
        assert!(
            sql.contains(
                "get_json_string(metadata, '$.\"service_radar\".\"source_type\"') = 'anomaly_detection'"
            ),
            "{sql}"
        );
        assert!(
            sql.contains(
                "get_json_string(unmapped, '$.\"capacity_forecast\".\"status\"') IN ('projected', 'at_risk', 'exhaustion_projected')"
            ),
            "{sql}"
        );
        assert!(sql.contains("COALESCE(severity_id, 0) >= 5"), "{sql}");
        assert!(sql.contains("COALESCE(severity_id, 0) = 4"), "{sql}");
        assert!(sql.ends_with("WHERE is_anomaly OR is_at_risk"), "{sql}");
        refute_postgres(sql);
        assert!(!sql.contains("#>>"), "{sql}");
        assert!(!sql.contains("FILTER (WHERE"), "{sql}");

        let message = refused("in:events time:last_1h rollup_stats:anomaly_findings severity:High");
        assert!(message.contains("does not support filters"), "{message}");
    }

    #[test]
    fn a_rollup_this_dialect_does_not_implement_is_refused_by_name() {
        for (query, feature) in [
            (
                "in:flows time:last_1h rollup_stats:summary",
                "rollup_stats:summary",
            ),
            (
                "in:logs time:last_1h rollup_stats:summary",
                "rollup_stats:summary",
            ),
            (
                "in:events time:last_1h rollup_stats:severity",
                "rollup_stats:severity",
            ),
            // The scoped event entities share the table but not the rollup.
            (
                "in:security_findings time:last_1h rollup_stats:anomaly_findings",
                "rollup_stats:anomaly_findings",
            ),
            (
                "in:timeseries_metrics time:last_1h rollup_stats:availability",
                "rollup_stats:availability",
            ),
        ] {
            let message = refused(query);
            assert!(message.contains(feature), "{query}: {message}");
        }
    }

    #[test]
    fn a_rollup_combined_with_stats_is_refused() {
        let message = refused("in:logs time:last_1h rollup_stats:severity stats:count() as total");
        assert!(message.contains("rollup_stats:severity"), "{message}");
        assert!(message.contains("stats:"), "{message}");
    }

    #[test]
    fn a_top_n_with_an_other_tail_is_refused_not_truncated() {
        let message = refused(
            "in:flows time:last_1h stats:sum(bytes_total) as bytes_total by src_endpoint_ip sort:bytes_total:desc limit:10 other:true",
        );
        assert!(message.contains("other:true"), "{message}");
    }

    #[test]
    fn log_severity_filters_ignore_case_like_cnpg() {
        for field in ["severity", "level", "severity_text"] {
            let compiled = translate(
                &plan(&format!("in:logs time:last_1h {field}:ERROR")),
                "serviceradar",
            )
            .expect(field);
            assert!(
                compiled.sql.contains("LOWER(severity_text) = 'error'"),
                "{field}: {}",
                compiled.sql
            );
        }

        let list = translate(
            &plan("in:logs time:last_1h severity:(Fatal,ERROR)"),
            "serviceradar",
        )
        .expect("list");
        assert!(
            list.sql
                .contains("LOWER(severity_text) IN ('fatal', 'error')"),
            "{}",
            list.sql
        );

        let negated =
            translate(&plan("in:logs time:last_1h !level:Debug"), "serviceradar").expect("negated");
        assert!(
            negated.sql.contains("LOWER(severity_text) != 'debug'"),
            "{}",
            negated.sql
        );
    }

    #[test]
    fn severity_match_any_joins_text_and_number_the_way_the_cards_bucket_them() {
        let compiled = translate(
            &plan(
                "in:logs time:last_1h severity:(ERROR,err) severity_number:(17,18,19,20) severity_match:any",
            ),
            "serviceradar",
        )
        .expect("severity any");
        let sql = &compiled.sql;

        assert!(
            sql.contains(
                "(LOWER(severity_text) IN ('error', 'err') OR ((severity_text IS NULL OR LOWER(severity_text) NOT IN ('fatal', 'critical',"
            ),
            "{sql}"
        );
        assert!(
            sql.contains("AND severity_number IN (17, 18, 19, 20)))"),
            "{sql}"
        );
        // The marker and the two lists become one predicate, not three ANDed.
        assert!(!sql.contains("severity_match"), "{sql}");
        assert!(!sql.contains("AND severity_number IN ('17'"), "{sql}");
        assert_eq!(sql.matches("LOWER(severity_text) IN (").count(), 1, "{sql}");

        let message = refused("in:logs time:last_1h severity:(ERROR) severity_match:any");
        assert!(
            message.contains("severity_match:any requires severity and severity_number"),
            "{message}"
        );
        let message =
            refused("in:logs time:last_1h severity:ERROR severity_number:17 severity_match:any");
        assert!(message.contains("requires IN-list filters"), "{message}");
        let message = refused(
            "in:logs time:last_1h severity:(ERROR) severity_number:(high) severity_match:any",
        );
        assert!(message.contains("must be integers"), "{message}");
    }

    #[test]
    fn a_log_device_filter_resolves_the_uid_through_the_inventory_catalog() {
        let compiled = translate(
            &plan("in:logs time:last_1h device_id:\"sr:device-0001\""),
            "serviceradar",
        )
        .expect("device_id");
        let sql = &compiled.sql;

        assert!(
            sql.contains(
                "source_ip IN (SELECT d.ip FROM cnpg_platform.platform.ocsf_devices d WHERE (d.uid = 'sr:device-0001' OR d.uid_alt = 'sr:device-0001') AND d.ip IS NOT NULL)"
            ),
            "{sql}"
        );
        assert!(sql.contains("source IN (SELECT d.hostname FROM"), "{sql}");
        assert!(sql.contains("source IN (SELECT d.name FROM"), "{sql}");
        for column in ["source_ip", "source"] {
            assert!(
                sql.contains(&format!(
                    "{column} IN (SELECT di.identifier_value FROM cnpg_platform.platform.device_identifiers di WHERE di.device_id = 'sr:device-0001' AND di.identifier_type IN ('ip', 'hostname') AND di.identifier_value IS NOT NULL)"
                )),
                "{column}: {sql}"
            );
        }
        assert!(
            sql.contains(
                "source_ip IN (SELECT ia.ip FROM cnpg_platform.platform.device_interface_addresses_catalog ia WHERE ia.device_id = 'sr:device-0001')"
            ),
            "{sql}"
        );
        assert!(
            sql.contains(
                "source_ip IN (SELECT di_if.device_ip FROM cnpg_platform.platform.discovered_interfaces di_if WHERE di_if.device_id = 'sr:device-0001' AND di_if.device_ip IS NOT NULL)"
            ),
            "{sql}"
        );
        // The alias table is the flow scope's lookup, not one CNPG makes here.
        assert!(!sql.contains("device_alias_states"), "{sql}");
        // Correlated lookups are what timed out on CNPG, and StarRocks refuses
        // the non-equality kind outright.
        assert!(!sql.contains("EXISTS"), "{sql}");

        let negated = translate(
            &plan("in:logs time:last_1h !device_id:\"sr:device-0001\""),
            "serviceradar",
        )
        .expect("negated");
        assert!(
            negated.sql.contains("AND NOT ((source_ip IN ("),
            "{}",
            negated.sql
        );
    }

    #[test]
    fn log_fields_with_no_warehouse_column_stay_refused() {
        for field in ["gateway_id", "agent_id", "scope_name", "source_device_uid"] {
            let message = refused(&format!("in:logs time:last_1h {field}:alpha"));
            assert!(
                message.contains("unsupported StarRocks field"),
                "{field}: {message}"
            );
        }
    }

    #[test]
    fn event_log_level_is_a_plain_column_filter() {
        let compiled = translate(
            &plan("in:events log_level:(ERROR,error) time:last_1h sort:time:desc limit:100"),
            "serviceradar",
        )
        .expect("log_level");
        assert!(
            compiled.sql.contains("log_level IN ('ERROR', 'error')"),
            "{}",
            compiled.sql
        );
    }

    #[test]
    fn event_type_reads_every_document_path_cnpg_reads() {
        let compiled = translate(
            &plan("in:events event_type:(anomaly,anomaly_detection) time:last_1h"),
            "serviceradar",
        )
        .expect("event_type");
        let sql = &compiled.sql;

        assert!(
            sql.contains(
                "((get_json_string(metadata, '$.\"event_type\"') = 'anomaly' OR get_json_string(metadata, '$.\"service_radar\".\"event_type\"') = 'anomaly' OR get_json_string(unmapped, '$.\"event_type\"') = 'anomaly') OR (get_json_string(metadata, '$.\"event_type\"') = 'anomaly_detection'"
            ),
            "{sql}"
        );
        assert!(!sql.contains("->>"), "{sql}");

        let negated = translate(
            &plan("in:events !event_type:anomaly time:last_1h"),
            "serviceradar",
        )
        .expect("negated");
        assert!(
            negated.sql.contains("AND NOT ((get_json_string("),
            "{}",
            negated.sql
        );

        let message = refused("in:events event_type:>anomaly time:last_1h");
        assert!(message.contains("equality and IN/NOT IN"), "{message}");
    }

    #[test]
    fn event_finding_uid_reads_the_finding_identity_paths() {
        let compiled = translate(
            &plan(
                "in:events source_type:capacity_forecasting finding_uid:finding-0001 time:last_1h",
            ),
            "serviceradar",
        )
        .expect("finding_uid");
        let sql = &compiled.sql;

        for path in [
            "'$.\"finding_info\".\"uid\"'",
            "'$.\"security_signal\".\"finding_uid\"'",
            "'$.\"uid\"'",
            "'$.\"event_id\"'",
        ] {
            assert!(
                sql.contains(&format!(
                    "get_json_string(metadata, {path}) = 'finding-0001'"
                )),
                "{path}: {sql}"
            );
        }
        // source_type is where the event came from, however the emitter spelled it.
        assert!(
            sql.contains("(log_provider = 'capacity_forecasting' OR log_name = 'capacity_forecasting' OR source_type = 'capacity_forecasting' OR get_json_string(metadata, '$.\"service_radar\".\"source_type\"') = 'capacity_forecasting'"),
            "{sql}"
        );
    }

    #[test]
    fn an_event_device_filter_anchors_a_canonical_uid_and_scans_only_for_a_raw_id() {
        let canonical = translate(
            &plan("in:events device_id:\"sr:device-0001\" time:last_1h"),
            "serviceradar",
        )
        .expect("canonical");
        assert!(
            canonical.sql.contains(
                "((get_json_string(metadata, '$.\"service_radar\".\"device_uid\"') = 'sr:device-0001' OR get_json_string(device, '$.\"uid\"') = 'sr:device-0001') OR (COALESCE(LOWER(src_endpoint_ip), '') IN ("
            ),
            "{}",
            canonical.sql
        );
        // The raw-id scan names an identity key ahead of the value.
        assert!(
            !canonical.sql.contains("\"device\\\\_uid\"%"),
            "{}",
            canonical.sql
        );

        let raw = translate(
            &plan("in:events device_id:\"Host_01.example.com\" time:last_1h"),
            "serviceradar",
        )
        .expect("raw");
        // Case-insensitive, with the LIKE wildcard in the value escaped.
        assert!(
            raw.sql.contains(
                "LOWER(metadata) LIKE '%\"device\\\\_uid\"%\"host\\\\_01.example.com\"%'"
            ),
            "{}",
            raw.sql
        );
        assert!(raw.sql.contains("LOWER(device) LIKE "), "{}", raw.sql);
        assert!(raw.sql.contains("LOWER(unmapped) LIKE "), "{}", raw.sql);
        assert!(raw.sql.contains("LOWER(observables) LIKE "), "{}", raw.sql);
    }

    #[test]
    fn an_event_device_filter_finds_events_whose_documents_name_an_inventory_alias() {
        let aliases = "SELECT LOWER(a.alias) AS alias FROM cnpg_platform.platform.device_inventory_aliases_catalog a WHERE a.uid = 'sr:device-0001' OR a.uid_alt = 'sr:device-0001'";
        // The scoped event entities share the lookup, as they do on CNPG, and
        // the inner read of the table carries the same scope and bounds.
        for (entity, scope) in [
            ("events", ""),
            ("security_findings", " AND (category_uid = 2)"),
        ] {
            let compiled = translate(
                &plan(&format!(
                    "in:{entity} device_id:\"sr:device-0001\" time:[1999-06-15T00:00:00Z,1999-06-16T00:00:00Z]"
                )),
                "serviceradar",
            )
            .expect(entity);
            let sql = &compiled.sql;
            assert!(
                sql.contains(&format!(
                    "COALESCE(LOWER(src_endpoint_ip), '') IN ({aliases})"
                )),
                "{entity}: {sql}"
            );
            assert!(
                sql.contains(&format!(
                    "id IN (SELECT e.id FROM serviceradar.events e JOIN (SELECT CONCAT('%\"', REPLACE(REPLACE(REPLACE(da.alias, '\\\\', '\\\\\\\\'), '%', '\\\\%'), '_', '\\\\_'), '\"%') AS pattern FROM ({aliases}) da) da ON LOWER(e.device) LIKE da.pattern OR LOWER(e.metadata) LIKE da.pattern OR LOWER(e.unmapped) LIKE da.pattern OR LOWER(e.observables) LIKE da.pattern WHERE `time` >= '1999-06-15T00:00:00Z' AND `time` < '1999-06-16T00:00:00Z'{scope})"
                )),
                "{entity}: {sql}"
            );
            assert!(!sql.contains("EXISTS"), "{sql}");
        }
    }

    #[test]
    fn a_negated_event_device_filter_keeps_only_the_canonical_arm_three_valued() {
        let compiled = translate(
            &plan("in:events !device_id:\"host02.example.com\" time:last_1h"),
            "serviceradar",
        )
        .expect("negated");
        let sql = &compiled.sql;
        let start = sql.find(" AND NOT (").expect(sql) + " AND NOT (".len();
        let end = sql.find(" ORDER BY ").expect(sql);
        let arms = sql[start..end]
            .trim_end_matches(')')
            .split(") OR (")
            .map(|arm| arm.trim_start_matches('('))
            .collect::<Vec<_>>();
        // CNPG's canonical equality is NULL for an event with neither path.
        assert!(
            arms[0].starts_with("get_json_string(metadata, "),
            "{}",
            arms[0]
        );
        // Its alias EXISTS and its scan of NOT NULL jsonb never are.
        for arm in &arms[1..] {
            assert!(
                arm.starts_with("COALESCE(") || arm.starts_with("id IN ("),
                "{arm}"
            );
        }
    }

    #[test]
    fn log_and_event_text_filters_ignore_case_and_keep_null_rows_under_negation() {
        for (query, predicate) in [
            (
                "in:logs time:last_1h event_name:\"%Timeout%\"",
                "AND LOWER(event_name) LIKE '%timeout%'",
            ),
            (
                "in:logs time:last_1h !event_name:\"%Timeout%\"",
                "AND (event_name IS NULL OR LOWER(event_name) NOT LIKE '%timeout%')",
            ),
            (
                "in:logs time:last_1h !service_name:core",
                "AND (service_name IS NULL OR service_name != 'core')",
            ),
            (
                "in:logs time:last_1h !source_ip:(192.0.2.10,192.0.2.11)",
                "AND (source_ip IS NULL OR source_ip NOT IN ('192.0.2.10', '192.0.2.11'))",
            ),
            (
                "in:logs time:last_1h service_name:Core",
                "AND service_name = 'Core'",
            ),
            (
                "in:events time:last_1h message:\"%Link Down%\"",
                "AND LOWER(message) LIKE '%link down%'",
            ),
            (
                "in:events time:last_1h !message:\"%Link Down%\"",
                "AND (message IS NULL OR LOWER(message) NOT LIKE '%link down%')",
            ),
            (
                "in:events time:last_1h !log_provider:falco",
                "AND (log_provider IS NULL OR log_provider != 'falco')",
            ),
            (
                "in:events time:last_1h !status:(open,new)",
                "AND (status IS NULL OR status NOT IN ('open', 'new'))",
            ),
        ] {
            let compiled = translate(&plan(query), "serviceradar").expect(query);
            assert!(
                compiled.sql.contains(predicate),
                "{query}: {}",
                compiled.sql
            );
        }
    }

    #[test]
    fn flow_and_metric_text_filters_are_unchanged() {
        let compiled = translate(
            &plan("in:flows time:last_1h !app:\"%HTTP%\""),
            "serviceradar",
        )
        .expect("flows");
        assert!(
            compiled
                .sql
                .contains("AND COALESCE(dst_service_label, 'unknown') NOT LIKE '%HTTP%'"),
            "{}",
            compiled.sql
        );
    }

    #[test]
    fn event_host_filters_read_the_host_identity_paths() {
        for field in ["hostname", "host_id"] {
            let compiled = translate(
                &plan(&format!(
                    "in:events {field}:host01.example.com time:last_1h"
                )),
                "serviceradar",
            )
            .expect(field);
            let sql = &compiled.sql;
            assert!(
                sql.contains("get_json_string(metadata, '$.\"service_radar\".\"device_hostname\"') = 'host01.example.com'"),
                "{sql}"
            );
            assert!(
                sql.contains("get_json_string(device, '$.\"hostname\"') = 'host01.example.com'"),
                "{sql}"
            );
        }
        // CNPG has no `host` field on events either.
        let message = refused("in:events host:host01.example.com time:last_1h");
        assert!(
            message.contains("unsupported StarRocks field: host"),
            "{message}"
        );
    }

    #[test]
    fn the_finding_rollup_drill_down_selects_the_rows_the_rollup_counts() {
        let rollup = translate(
            &plan("in:events time:last_1h rollup_stats:anomaly_findings"),
            "serviceradar",
        )
        .expect("rollup");
        for (kind, verdict) in [
            ("anomaly", event_anomaly_count_sql().expect("anomaly")),
            (
                "capacity_at_risk",
                event_capacity_at_risk_sql().expect("capacity"),
            ),
        ] {
            let compiled = translate(
                &plan(&format!(
                    "in:events finding_rollup:{kind} time:last_1h sort:time:desc"
                )),
                "serviceradar",
            )
            .expect(kind);
            assert!(
                compiled.sql.contains(&format!(
                    "(class_uid = 2004 AND category_uid = 2 AND {verdict})"
                )),
                "{kind}: {}",
                compiled.sql
            );
            assert!(rollup.sql.contains(&verdict), "{kind}: {}", rollup.sql);
        }
        let message = refused("in:events finding_rollup:everything time:last_1h");
        assert!(
            message.contains("unsupported finding_rollup value"),
            "{message}"
        );
    }

    #[test]
    fn an_event_document_key_cannot_carry_sql() {
        assert!(event_json_text("metadata", &["service_radar", "x') OR 1=1 --"]).is_err());
        assert!(event_json_text("metadata", &["a\"b"]).is_err());
        assert_eq!(
            event_json_text("unmapped", &["capacity_forecast", "status"]).expect("path"),
            "get_json_string(unmapped, '$.\"capacity_forecast\".\"status\"')"
        );
        let compiled = translate(
            &plan("in:events event_type:\"x' OR '1'='1\" time:last_1h"),
            "serviceradar",
        )
        .expect("quoted value");
        assert!(
            compiled.sql.contains("= 'x'' OR ''1''=''1'"),
            "{}",
            compiled.sql
        );
    }

    fn refute_postgres(sql: &str) {
        assert!(!sql.to_ascii_lowercase().contains("time_bucket"));
        assert!(!sql.to_ascii_lowercase().contains("::timestamptz"));
    }
}
