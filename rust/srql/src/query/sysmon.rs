use super::{
    BindParam, QueryPlan, bind_sql_param,
    filters_common::{NumericComparison, NumericKind},
    validate_stats_alias,
};
use crate::{
    error::{Result, ServiceError},
    jsonb::DbJson,
    parser::{
        DownsampleAgg, Entity, Filter, FilterOp, FilterValue, OrderClause, OrderDirection,
        StatsSpec,
    },
};
use diesel::{pg::Pg, sql_query, sql_types::Jsonb};
use diesel_async::{AsyncPgConnection, RunQueryDsl};

pub(super) fn is_entity(entity: &Entity) -> bool {
    matches!(
        entity,
        Entity::CpuMetrics | Entity::MemoryMetrics | Entity::DiskMetrics | Entity::ProcessMetrics
    )
}

struct MetricSpec {
    metric_type: &'static str,
    dimensions: &'static [&'static str],
    values: &'static [(&'static str, &'static str)],
    quantities: &'static [&'static str],
}

fn spec(entity: &Entity) -> Result<MetricSpec> {
    Ok(match entity {
        Entity::CpuMetrics => MetricSpec {
            metric_type: "sysmon.cpu",
            dimensions: &["core_id", "label", "cluster"],
            values: &[
                ("usage_percent", "cpu.usage_percent"),
                ("frequency_hz", "cpu.frequency_hz"),
            ],
            quantities: &[],
        },
        Entity::MemoryMetrics => MetricSpec {
            metric_type: "sysmon.memory",
            dimensions: &[],
            values: &[("usage_percent", "memory.used_percent")],
            quantities: &["used_bytes", "total_bytes", "available_bytes"],
        },
        Entity::DiskMetrics => MetricSpec {
            metric_type: "sysmon.disk",
            dimensions: &["mount_point", "device_name"],
            values: &[("usage_percent", "disk.used_percent")],
            quantities: &["used_bytes", "total_bytes", "available_bytes"],
        },
        Entity::ProcessMetrics => MetricSpec {
            metric_type: "sysmon.process",
            dimensions: &["pid", "name", "status", "start_time"],
            values: &[
                ("cpu_usage", "process.cpu_usage"),
                ("memory_usage", "process.memory_usage"),
            ],
            quantities: &[],
        },
        _ => {
            return Err(ServiceError::InvalidRequest(
                "expected a sysmon entity".into(),
            ));
        }
    })
}

fn identifier(name: &str, warehouse: bool) -> String {
    if warehouse {
        format!("`{name}`")
    } else {
        format!("\"{name}\"")
    }
}

fn tag(name: &str, warehouse: bool) -> String {
    if warehouse {
        format!("NULLIF(get_json_string(tags, '$.{name}'), '')")
    } else {
        format!("NULLIF(tags ->> '{name}', '')")
    }
}

fn numeric_kind(field: &str) -> Option<NumericKind> {
    match field {
        "core_id" | "pid" => Some(NumericKind::Int4),
        "used_bytes" | "total_bytes" | "available_bytes" | "memory_usage" => {
            Some(NumericKind::Int8)
        }
        "usage_percent" | "frequency_hz" | "cpu_usage" => Some(NumericKind::Float8),
        _ => None,
    }
}

fn field(spec: &MetricSpec, name: &str, warehouse: bool) -> Result<String> {
    let normalized = name.trim().to_ascii_lowercase();
    let name = normalized.as_str();
    let name = if name == "uid" { "device_id" } else { name };
    if [
        "timestamp",
        "gateway_id",
        "agent_id",
        "host_id",
        "device_id",
        "partition",
    ]
    .contains(&name)
        || spec.dimensions.contains(&name)
        || spec.quantities.contains(&name)
        || spec.values.iter().any(|(column, _)| *column == name)
    {
        Ok(identifier(name, warehouse))
    } else {
        Err(ServiceError::InvalidRequest(format!(
            "unsupported sysmon field '{name}'"
        )))
    }
}

fn bind(params: &mut Vec<BindParam>, param: BindParam, warehouse: bool) -> String {
    if warehouse {
        match param {
            BindParam::Int(value) => value.to_string(),
            BindParam::Float(value) => value.to_string(),
            BindParam::Text(value) => super::starrocks::sql_literal(&value),
            BindParam::Timestamptz(value) => super::starrocks::sql_literal(
                &chrono::DateTime::parse_from_rfc3339(&value)
                    .expect("typed timestamp")
                    .format("%Y-%m-%d %H:%M:%S%.6f")
                    .to_string(),
            ),
            _ => unreachable!(),
        }
    } else {
        params.push(param);
        format!("${}", params.len())
    }
}

fn predicate(
    spec: &MetricSpec,
    filter: &Filter,
    params: &mut Vec<BindParam>,
    warehouse: bool,
    keep_null: bool,
) -> Result<String> {
    let column = field(spec, &filter.field, warehouse)?;
    if let Some(kind) = numeric_kind(&filter.field) {
        let comparison = NumericComparison::parse(filter, kind)?;
        let value = bind(params, comparison.value.bind_param(), warehouse);
        return Ok(format!("{column} {} {value}", comparison.op_sql));
    }
    let negated = matches!(
        filter.op,
        FilterOp::NotEq | FilterOp::NotLike | FilterOp::NotIn
    );
    let sql = match filter.op {
        FilterOp::In | FilterOp::NotIn => {
            let values = filter.value.as_list()?;
            if values.is_empty() {
                return Ok("TRUE".into());
            }
            let values = values
                .iter()
                .map(|v| bind(params, BindParam::Text(v.clone()), warehouse))
                .collect::<Vec<_>>()
                .join(", ");
            format!(
                "{column} {} ({values})",
                if negated { "NOT IN" } else { "IN" }
            )
        }
        FilterOp::Eq | FilterOp::NotEq | FilterOp::Like | FilterOp::NotLike => {
            let value = bind(
                params,
                BindParam::Text(filter.value.as_scalar()?.into()),
                warehouse,
            );
            match filter.op {
                FilterOp::Like | FilterOp::NotLike => format!(
                    "LOWER({column}) {} LOWER({value})",
                    if negated { "NOT LIKE" } else { "LIKE" }
                ),
                _ => format!("{column} {} {value}", if negated { "<>" } else { "=" }),
            }
        }
        _ => {
            return Err(ServiceError::InvalidRequest(
                "unsupported sysmon text operator".into(),
            ));
        }
    };
    Ok(if negated && keep_null {
        format!("({column} IS NULL OR {sql})")
    } else {
        sql
    })
}

fn source(
    plan: &QueryPlan,
    spec: &MetricSpec,
    database: Option<&str>,
    params: &mut Vec<BindParam>,
) -> Result<String> {
    let warehouse = database.is_some();
    let table = match database {
        Some(db) if !db.is_empty() && db.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') => {
            format!("{db}.timeseries_metrics")
        }
        Some(_) => {
            return Err(ServiceError::InvalidRequest(
                "invalid warehouse database".into(),
            ));
        }
        None => "timeseries_metrics".into(),
    };
    let mut dimensions = [
        "timestamp",
        "gateway_id",
        "agent_id",
        "device_id",
        "partition",
    ]
    .iter()
    .map(|name| identifier(name, warehouse))
    .collect::<Vec<_>>();
    let mut projection = dimensions.clone();
    for name in std::iter::once(&"host_id").chain(spec.dimensions.iter()) {
        let value = if numeric_kind(name).is_some() {
            format!("CAST({} AS INTEGER)", tag(name, warehouse))
        } else {
            tag(name, warehouse)
        };
        projection.push(format!("{value} AS {}", identifier(name, warehouse)));
        dimensions.push(value);
    }
    for (column, metric) in spec.values {
        let value = format!("MAX(CASE WHEN metric_name = '{metric}' THEN value END)");
        let value = if *column == "memory_usage" {
            format!("CAST({value} AS BIGINT)")
        } else {
            value
        };
        projection.push(format!("{value} AS {}", identifier(column, warehouse)));
    }
    for name in spec.quantities {
        let value = if *name == "available_bytes" {
            format!(
                "COALESCE(CAST({} AS BIGINT), CAST({} AS BIGINT) - CAST({} AS BIGINT))",
                tag(name, warehouse),
                tag("total_bytes", warehouse),
                tag("used_bytes", warehouse)
            )
        } else {
            format!("CAST({} AS BIGINT)", tag(name, warehouse))
        };
        projection.push(format!("MAX({value}) AS {}", identifier(name, warehouse)));
    }
    let mut conditions = vec![
        format!("metric_type = '{}'", spec.metric_type),
        format!(
            "metric_name IN ({})",
            spec.values
                .iter()
                .map(|(_, m)| format!("'{m}'"))
                .collect::<Vec<_>>()
                .join(", ")
        ),
    ];
    if let Some(range) = &plan.time_range {
        let start = bind(params, BindParam::timestamptz(range.start), warehouse);
        let end = bind(params, BindParam::timestamptz(range.end), warehouse);
        conditions.push(format!(
            "timestamp >= {start} AND timestamp {} {end}",
            if plan.downsample.is_some() { "<" } else { "<=" }
        ));
    }
    Ok(format!(
        "SELECT {} FROM {table} WHERE {} GROUP BY {}",
        projection.join(", "),
        conditions.join(" AND "),
        dimensions.join(", ")
    ))
}

fn stats_spec(raw: &str, spec: &MetricSpec) -> Result<(String, String, bool)> {
    let lower = raw.to_ascii_lowercase();
    let (expression, group) = match lower.rsplit_once(" by ") {
        Some((expression, group)) => (expression.trim(), Some(group.trim())),
        None => (lower.trim(), None),
    };
    if !matches!(group, None | Some("device_id"))
        || (group.is_none() && spec.metric_type != "sysmon.cpu")
    {
        return Err(ServiceError::InvalidRequest(
            "sysmon stats group by device_id".into(),
        ));
    }
    let (expression, alias) = match expression.split_once(" as ") {
        Some((expression, alias)) => (expression.trim(), Some(alias.trim())),
        None if spec.metric_type == "sysmon.cpu" => (expression, None),
        None => {
            return Err(ServiceError::InvalidRequest(
                "sysmon stats require an alias".into(),
            ));
        }
    };
    let column = expression
        .strip_prefix("avg(")
        .and_then(|inner| inner.strip_suffix(')'))
        .map(str::trim)
        .filter(|field| {
            (spec.values.iter().any(|(column, _)| column == field) && *field != "frequency_hz")
                || (spec.quantities.contains(field) && *field != "total_bytes")
        })
        .ok_or_else(|| {
            ServiceError::InvalidRequest("unsupported sysmon stats expression".into())
        })?;
    let alias = alias
        .map(str::to_string)
        .unwrap_or_else(|| format!("avg_{column}"));
    validate_stats_alias(&alias)?;
    Ok((column.to_string(), alias, group.is_some()))
}

fn metric_aggregate_plan(plan: &QueryPlan, spec: &MetricSpec) -> Result<Option<QueryPlan>> {
    if plan
        .filters
        .iter()
        .any(|f| !["device_id", "gateway_id", "agent_id", "partition"].contains(&f.field.as_str()))
    {
        return Ok(None);
    }
    let mut normalized = plan.clone();
    if let Some(ds) = &mut normalized.downsample {
        ds.value_field = ds
            .value_field
            .as_ref()
            .map(|field| field.trim().to_ascii_lowercase());
        ds.series = ds
            .series
            .as_ref()
            .map(|field| field.trim().to_ascii_lowercase());
    }
    normalized.entity = Entity::TimeseriesMetrics;
    let metric_name = if let Some(ds) = &mut normalized.downsample {
        if matches!(ds.agg, DownsampleAgg::Rate | DownsampleAgg::RateSum)
            || ds
                .series
                .as_deref()
                .is_some_and(|s| !["device_id", "gateway_id", "agent_id", "partition"].contains(&s))
        {
            return Ok(None);
        }
        let Some((_, metric)) = spec.values.iter().find(|(field, _)| {
            Some(*field) == ds.value_field.as_deref().or(Some(spec.values[0].0))
        }) else {
            return Ok(None);
        };
        ds.value_field = Some("value".into());
        *metric
    } else if let Some(stats) = &plan.stats {
        let (column, alias, grouped) = stats_spec(&stats.raw, spec)?;
        let Some((_, metric)) = spec.values.iter().find(|(field, _)| *field == column) else {
            return Ok(None);
        };
        normalized.stats = Some(StatsSpec::from_raw(&format!(
            "avg(value) as {alias}{}",
            if grouped { " by device_id" } else { "" }
        )));
        if normalized.order.is_empty() {
            normalized.order.push(OrderClause {
                field: alias,
                direction: OrderDirection::Desc,
            });
        }
        *metric
    } else {
        return Ok(None);
    };
    for (field, value) in [
        ("metric_type", spec.metric_type),
        ("metric_name", metric_name),
    ] {
        normalized.filters.push(Filter {
            field: field.into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar(value.into()),
        });
    }
    Ok(Some(normalized))
}

pub(super) fn to_sql_and_params(
    plan: &QueryPlan,
    database: Option<&str>,
    allow_rollup: bool,
) -> Result<(String, Vec<BindParam>)> {
    if plan.rollup_stats.is_some() {
        return Err(ServiceError::InvalidRequest(
            "sysmon does not support rollup_stats".into(),
        ));
    }
    let warehouse = database.is_some();
    let spec = spec(&plan.entity)?;
    if let Some(normalized) = metric_aggregate_plan(plan, &spec)? {
        if let Some(database) = database {
            let response = if allow_rollup {
                super::starrocks::translate(&normalized, database)?
            } else {
                super::starrocks::translate_raw(&normalized, database)?
            };
            return Ok((response.sql, response.params));
        }
        if normalized.downsample.is_some() {
            return super::downsample::to_sql_and_params(&normalized);
        }
        let (_, alias, grouped) = stats_spec(&plan.stats.as_ref().unwrap().raw, &spec)?;
        return super::timeseries_metrics::legacy_sysmon_stats_sql(&normalized, &alias, grouped);
    }
    let mut params = Vec::new();
    let source = source(plan, &spec, database, &mut params)?;
    let predicates = plan
        .filters
        .iter()
        .map(|f| predicate(&spec, f, &mut params, warehouse, plan.stats.is_none()))
        .collect::<Result<Vec<_>>>()?;
    let mut filtered = format!(
        "SELECT * FROM ({source}) samples{}",
        if predicates.is_empty() {
            String::new()
        } else {
            format!(" WHERE {}", predicates.join(" AND "))
        }
    );
    let mut outputs = Vec::new();
    let mut group = String::new();
    let select = if let Some(ds) = &plan.downsample {
        let value_field = ds
            .value_field
            .as_deref()
            .unwrap_or(spec.values[0].0)
            .trim()
            .to_ascii_lowercase();
        let value_field = value_field.as_str();
        if !spec.values.iter().any(|(c, _)| *c == value_field)
            && !spec.quantities.contains(&value_field)
        {
            return Err(ServiceError::InvalidRequest(
                "unsupported sysmon value_field".into(),
            ));
        }
        let value = field(&spec, value_field, warehouse)?;
        let bucket = if warehouse {
            format!(
                "from_unixtime(FLOOR(unix_timestamp(timestamp) / {}) * {})",
                ds.bucket_seconds, ds.bucket_seconds
            )
        } else {
            format!(
                "to_timestamp(FLOOR(EXTRACT(EPOCH FROM timestamp) / {}) * {})",
                ds.bucket_seconds, ds.bucket_seconds
            )
        };
        let series = match &ds.series {
            Some(name) => format!(
                "COALESCE(CAST({} AS {}), '')",
                field(&spec, name, warehouse)?,
                if warehouse { "STRING" } else { "TEXT" }
            ),
            None => {
                if warehouse {
                    "CAST(NULL AS STRING)".into()
                } else {
                    "CAST(NULL AS TEXT)".into()
                }
            }
        };
        let value = if matches!(ds.agg, DownsampleAgg::Rate | DownsampleAgg::RateSum) {
            let seconds = if warehouse {
                "unix_timestamp(timestamp) - unix_timestamp(prev_timestamp)"
            } else {
                "EXTRACT(EPOCH FROM (timestamp - prev_timestamp))"
            };
            filtered = format!(
                "SELECT * FROM (SELECT samples.*, LAG({value}) OVER (PARTITION BY {series} ORDER BY timestamp) AS prev_value, LAG(timestamp) OVER (PARTITION BY {series} ORDER BY timestamp) AS prev_timestamp FROM ({filtered}) samples) rates"
            );
            format!(
                "CASE WHEN {value} >= prev_value THEN ({value} - prev_value) / NULLIF({seconds}, 0) END"
            )
        } else {
            value
        };
        let aggregate = match ds.agg {
            DownsampleAgg::Avg | DownsampleAgg::Rate => format!("AVG({value})"),
            DownsampleAgg::Min => format!("MIN({value})"),
            DownsampleAgg::Max => format!("MAX({value})"),
            DownsampleAgg::Sum | DownsampleAgg::RateSum => format!("SUM({value})"),
            DownsampleAgg::Count => format!(
                "CAST(COUNT(*) AS {})",
                if warehouse {
                    "DOUBLE"
                } else {
                    "DOUBLE PRECISION"
                }
            ),
            DownsampleAgg::Last if warehouse => format!("max_by({value}, timestamp)"),
            DownsampleAgg::Last => format!("(array_agg({value} ORDER BY timestamp DESC))[1]"),
        };
        outputs.extend([
            "timestamp".to_string(),
            "series".to_string(),
            "value".to_string(),
        ]);
        group = " GROUP BY 1, 2".into();
        format!("{bucket} AS timestamp, {series} AS series, {aggregate} AS value")
    } else if let Some(stats) = &plan.stats {
        let (column, alias, grouped) = stats_spec(&stats.raw, &spec)?;
        outputs.push(alias.clone());
        let prefix = if grouped {
            group = " GROUP BY device_id".into();
            outputs.push("device_id".into());
            "device_id, "
        } else {
            ""
        };
        format!(
            "{prefix}AVG({}) AS {}",
            field(&spec, &column, warehouse)?,
            identifier(&alias, warehouse)
        )
    } else {
        "samples.*, device_id AS uid".into()
    };
    let mut order = Vec::new();
    for clause in plan.order.iter().filter(|_| plan.downsample.is_none()) {
        let column = if outputs.is_empty() {
            field(&spec, &clause.field, warehouse)?
        } else {
            let name = if clause.field == "uid" {
                "device_id"
            } else {
                &clause.field
            };
            if !outputs.iter().any(|s| s == name) {
                return Err(ServiceError::InvalidRequest(format!(
                    "unsupported sysmon result sort '{name}'"
                )));
            }
            identifier(name, warehouse)
        };
        order.push(format!(
            "{column} {}",
            super::starrocks::pg_order_sql(clause.direction)
        ));
    }
    if order.is_empty() {
        if plan.downsample.is_some() {
            order.push("timestamp ASC, series ASC NULLS FIRST".into());
        } else if plan.stats.is_none() {
            order.push("timestamp DESC".into());
        } else if !group.is_empty() {
            order.push(format!("{} DESC", identifier(&outputs[0], warehouse)));
        }
    }
    let order = if order.is_empty() {
        String::new()
    } else {
        format!(" ORDER BY {}", order.join(", "))
    };
    let limit = bind(&mut params, BindParam::Int(plan.limit), warehouse);
    let offset = bind(&mut params, BindParam::Int(plan.offset), warehouse);
    let sql = if plan.downsample.is_some()
        && plan
            .order
            .as_slice()
            .first()
            .is_some_and(|c| matches!(c.direction, OrderDirection::Desc))
    {
        format!(
            "SELECT timestamp, series, value FROM (SELECT {select} FROM ({filtered}) samples{group} ORDER BY 1 DESC, 2 ASC NULLS FIRST LIMIT {limit} OFFSET {offset}) windowed ORDER BY 1 ASC, 2 ASC NULLS FIRST"
        )
    } else {
        format!(
            "SELECT {select} FROM ({filtered}) samples{group}{order} LIMIT {limit} OFFSET {offset}"
        )
    };
    Ok((sql, params))
}

#[derive(diesel::QueryableByName)]
struct Payload {
    #[diesel(sql_type = Jsonb)]
    payload: DbJson,
}

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    let (sql, params) = to_sql_and_params(plan, None, true)?;
    let mut query = sql_query(format!(
        "SELECT to_jsonb(result) AS payload FROM ({sql}) result"
    ))
    .into_boxed::<Pg>();
    for param in params {
        query = bind_sql_param(query, param)?;
    }
    let rows = query
        .load::<Payload>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;
    Ok(rows.into_iter().map(|row| row.payload.into()).collect())
}
