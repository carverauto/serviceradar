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
        Some(dataset) => dataset_sql(plan, dataset, database, allow_rollup),
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

/// An hourly materialized view (priv/starrocks/0005) a bucketed query may read
/// instead of the raw table. `dimensions` is every column the view groups by,
/// so a filter or series outside that list has no equivalent there.
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
    let hour_grained = if joins.is_empty() && !direction {
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
    let from = if direction {
        let base = direction_source(&qualified);
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
        direction || !joins.is_empty(),
        hour_grained.is_some(),
    );
    if let Some(scope) = dataset.scope {
        where_sql.push_str(&format!(" AND ({scope})"));
    }
    for filter in &plan.filters {
        where_sql.push_str(" AND ");
        where_sql.push_str(&filter_sql(plan, filter)?);
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

const CNPG_CATALOG: &str = "cnpg_platform.platform";

#[derive(Clone, Copy, PartialEq, Eq)]
enum CatalogJoin {
    Devices,
    InputInterface,
    OutputInterface,
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
    let wants_device = plan_mentions(plan, &["hostname", "device_name"]);
    let wants_input_interface = plan_mentions(plan, &["in_if_name", "in_if_speed_bps"]);
    let wants_output_interface = plan_mentions(plan, &["out_if_name", "out_if_speed_bps"]);
    let wants_src_geo = plan_mentions(plan, &["src_country_iso2", "src_country"]);
    let wants_dst_geo = plan_mentions(plan, &["dst_country_iso2", "dst_country"]);
    if !wants_device
        && !wants_input_interface
        && !wants_output_interface
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
            (Sum | Rate | RateSum, "value") => Some("SUM(avg_value * sample_count)".to_string()),
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
    Ok(format!(
        "SELECT time_slice({time}, INTERVAL {bucket} SECOND) AS timestamp, {series} AS series, {agg} AS value FROM {from}{where_sql} GROUP BY 1, 2 ORDER BY 1 LIMIT {limit} OFFSET {offset}",
        limit = plan.limit.max(1),
        offset = plan.offset.max(0)
    ))
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
    let qualified =
        flow && (plan_mentions(plan, &["direction"]) || !catalog_joins(plan, dataset)?.is_empty());
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
            "id time class_uid category_uid type_uid activity_id severity_id severity source src_endpoint_ip firewall_rule_name source_type message activity_name status status_id log_name log_provider trace_id span_id"
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

fn direction_sql() -> String {
    let local = |endpoint: &str| {
        format!(
            "EXISTS (SELECT 1 FROM {CNPG_CATALOG}.netflow_local_cidrs_catalog c WHERE c.enabled AND (c.partition IS NULL OR c.partition = f.`partition`) AND LENGTH(f.{endpoint}_ip_hex) = LENGTH(c.first_ip_hex) AND f.{endpoint}_ip_hex BETWEEN c.first_ip_hex AND c.last_ip_hex)"
        )
    };
    let src = local("src");
    let dst = local("dst");
    format!(
        "CASE WHEN {src} AND {dst} THEN 'bidirectional' WHEN {dst} THEN 'ingress' WHEN {src} THEN 'egress' ELSE COALESCE(f.direction_label, 'unknown') END"
    )
}

fn direction_source(table: &str) -> String {
    let normalized = |col: &str| {
        format!(
            "LOWER(CASE WHEN LOCATE(':', {col}) > 0 AND LOCATE('.', {col}) > 0 THEN CONCAT(REGEXP_REPLACE({col}, '[^:]+$', ''), SUBSTRING(LPAD(HEX(INET_ATON(SUBSTRING_INDEX({col}, ':', -1))), 8, '0'), 1, 4), ':', SUBSTRING(LPAD(HEX(INET_ATON(SUBSTRING_INDEX({col}, ':', -1))), 8, '0'), 5, 4)) ELSE {col} END)"
        )
    };
    format!(
        "(SELECT f.*, {} AS direction FROM (SELECT normalized.*, {} AS src_ip_hex, {} AS dst_ip_hex FROM (SELECT *, {} AS src_ip_normalized, {} AS dst_ip_normalized FROM {table}) normalized) f)",
        direction_sql(),
        ip_hex_sql("src_ip_normalized"),
        ip_hex_sql("dst_ip_normalized"),
        normalized("src_endpoint_ip"),
        normalized("dst_endpoint_ip")
    )
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
    let field = field_sql(plan, &filter.field)?;
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
                    .map(|v| sql_literal(v))
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
        }
    };
    Ok(format!(
        "{field} {op} {}",
        sql_literal(filter.value.as_scalar()?)
    ))
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
    fn direction_queries_use_partition_scoped_cidr_classification() {
        for query in [
            r#"in:flows time:last_1h stats:"sum(bytes_total) as total by direction""#,
            "in:flows time:last_1h direction:ingress",
            "in:flows time:last_1h sort:direction:asc",
        ] {
            let compiled = translate(&plan(query), "serviceradar").unwrap();
            assert!(
                compiled
                    .sql
                    .contains("cnpg_platform.platform.netflow_local_cidrs_catalog")
            );
            assert!(compiled.sql.contains("c.enabled"));
            assert!(
                compiled
                    .sql
                    .contains("c.partition IS NULL OR c.partition = f.`partition`")
            );
            assert!(compiled.sql.contains("THEN 'bidirectional'"));
            assert!(compiled.sql.contains("THEN 'ingress'"));
            assert!(compiled.sql.contains("THEN 'egress'"));
            assert!(
                compiled
                    .sql
                    .contains("COALESCE(f.direction_label, 'unknown')")
            );
            assert!(compiled.sql.contains("AS src_ip_hex"));
            assert!(compiled.sql.contains("AS dst_ip_hex"));
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

    fn refute_postgres(sql: &str) {
        assert!(!sql.to_ascii_lowercase().contains("time_bucket"));
        assert!(!sql.to_ascii_lowercase().contains("::timestamptz"));
    }
}
