//! Query execution for endpoint package inventory rows.

use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    jsonb::DbJson,
    models::EndpointPackageRow,
    parser::{Entity, Filter, FilterOp, FilterValue, OrderClause, OrderDirection},
    schema::endpoint_inventory_packages::dsl::{
        agent_id as col_agent_id, architecture as col_architecture, cpes as col_cpes,
        current as col_current, device_uid as col_device_uid, ecosystem as col_ecosystem,
        endpoint_inventory_packages, endpoint_package_ref as col_endpoint_package_ref,
        inserted_at as col_inserted_at, license as col_license, name as col_name,
        package_manager as col_package_manager, purl as col_purl,
        purl_canonical as col_purl_canonical, source as col_source, supplier as col_supplier,
        updated_at as col_updated_at, version as col_version,
    },
    time::TimeRange,
};
use chrono::{DateTime, Utc};
use diesel::deserialize::QueryableByName;
use diesel::dsl::{not, sql};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, BoxedSqlQuery, FromClause, SqlQuery};
use diesel::sql_query;
use diesel::sql_types::{Array, Bool, Jsonb, Text, Timestamptz};
use diesel::{PgArrayExpressionMethods, PgTextExpressionMethods};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type EndpointPackagesTable = crate::schema::endpoint_inventory_packages::table;
type EndpointPackagesFromClause = FromClause<EndpointPackagesTable>;
type EndpointPackagesQuery<'a> = BoxedSelectStatement<
    'a,
    <EndpointPackagesTable as AsQuery>::SqlType,
    EndpointPackagesFromClause,
    Pg,
>;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;

    if let Some(rollup_sql) = build_rollup_stats_query(plan)? {
        let rows: Vec<EndpointPackageRollupPayload> = rollup_sql
            .to_boxed_query()
            .load::<EndpointPackageRollupPayload>(conn)
            .await
            .map_err(|err| ServiceError::Internal(err.into()))?;

        return Ok(rows
            .into_iter()
            .map(|row| serde_json::Value::from(row.payload))
            .collect());
    }

    let query = build_query(plan)?;
    let rows: Vec<EndpointPackageRow> = query
        .select(EndpointPackageRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<EndpointPackageRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .map(EndpointPackageRow::into_json)
        .collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;

    if let Some(rollup_sql) = build_rollup_stats_query(plan)? {
        let sql = rewrite_placeholders(&rollup_sql.sql);
        let params = rollup_sql
            .binds
            .into_iter()
            .map(bind_param_from_rollup)
            .collect();

        return Ok((sql, params));
    }

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
        Entity::EndpointPackages => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by endpoint_packages query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<EndpointPackagesQuery<'static>> {
    if let Some(rollup) = plan.rollup_stats.as_deref() {
        return Err(ServiceError::InvalidRequest(format!(
            "unsupported rollup_stats type for endpoint_packages: '{rollup}'"
        )));
    }

    let mut query = endpoint_inventory_packages.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_inserted_at.ge(*start).and(col_inserted_at.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

#[derive(Debug, Clone)]
struct EndpointPackageRollupSql {
    sql: String,
    binds: Vec<SqlBindValue>,
}

impl EndpointPackageRollupSql {
    fn to_boxed_query(&self) -> BoxedSqlQuery<'_, Pg, SqlQuery> {
        // Keep the native `$N` placeholders: diesel's BoxedSqlQuery passes the
        // SQL string to Postgres verbatim and only appends bind values, so a
        // `?` placeholder is parsed by Postgres as a (jsonb) operator and the
        // query fails with a syntax error.
        let mut query = sql_query(self.sql.clone()).into_boxed::<Pg>();

        for bind in &self.binds {
            query = bind.apply(query);
        }

        query
    }
}

#[derive(Debug, QueryableByName)]
#[diesel(check_for_backend(diesel::pg::Pg))]
struct EndpointPackageRollupPayload {
    #[diesel(sql_type = Jsonb)]
    payload: DbJson,
}

#[derive(Debug, Clone)]
enum SqlBindValue {
    Text(String),
    TextArray(Vec<String>),
    Timestamp(DateTime<Utc>),
}

impl SqlBindValue {
    fn apply<'a>(&self, query: BoxedSqlQuery<'a, Pg, SqlQuery>) -> BoxedSqlQuery<'a, Pg, SqlQuery> {
        match self {
            Self::Text(value) => query.bind::<Text, _>(value.clone()),
            Self::TextArray(value) => {
                query.bind::<diesel::sql_types::Array<Text>, _>(value.clone())
            }
            Self::Timestamp(value) => query.bind::<Timestamptz, _>(*value),
        }
    }
}

fn bind_param_from_rollup(value: SqlBindValue) -> BindParam {
    match value {
        SqlBindValue::Text(value) => BindParam::Text(value),
        SqlBindValue::TextArray(value) => BindParam::TextArray(value),
        SqlBindValue::Timestamp(value) => BindParam::timestamptz(value),
    }
}

fn build_rollup_stats_query(plan: &QueryPlan) -> Result<Option<EndpointPackageRollupSql>> {
    let rollup_type = match plan.rollup_stats.as_ref() {
        Some(value) if !value.trim().is_empty() => value.trim(),
        _ => return Ok(None),
    };

    match rollup_type {
        "current_counts" | "current_package_counts" | "package_current_counts" => {
            build_current_package_counts_rollup(plan)
        }
        "current_cpe_counts" | "cpe_current_counts" => build_current_cpe_counts_rollup(plan),
        "package_counts_hourly" | "historical_counts" | "history_counts" => {
            build_package_counts_hourly_rollup(plan)
        }
        "cpe_counts_hourly" | "historical_cpe_counts" => build_cpe_counts_hourly_rollup(plan),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported rollup_stats type for endpoint_packages: '{other}' (supported: current_counts, current_cpe_counts, package_counts_hourly, cpe_counts_hourly)"
        ))),
    }
    .map(Some)
}

fn build_current_package_counts_rollup(plan: &QueryPlan) -> Result<EndpointPackageRollupSql> {
    if plan.time_range.is_some() {
        return Err(ServiceError::InvalidRequest(
            "endpoint_packages rollup_stats:current_counts does not support time filters".into(),
        ));
    }

    let mut binds = Vec::new();
    let where_sql = build_package_count_where(&plan.filters, &mut binds)?;
    let sql = format!(
        r#"SELECT jsonb_build_object(
    'rollup_type', 'current_counts',
    'coordinate_hash', coordinate_hash,
    'package_manager', package_manager,
    'ecosystem', ecosystem,
    'name', name,
    'version', version,
    'architecture', architecture,
    'purl_canonical', purl_canonical,
    'canonical_purl', purl_canonical,
    'cpes', cpes,
    'host_count', host_count,
    'first_seen_at', first_seen_at,
    'last_seen_at', last_seen_at,
    'updated_at', updated_at
) AS payload
FROM endpoint_inventory_current_package_counts
{where_sql}
ORDER BY host_count DESC, package_manager ASC, name ASC, version ASC NULLS LAST
LIMIT {} OFFSET {}"#,
        plan.limit, plan.offset
    );

    Ok(EndpointPackageRollupSql { sql, binds })
}

fn build_current_cpe_counts_rollup(plan: &QueryPlan) -> Result<EndpointPackageRollupSql> {
    if plan.time_range.is_some() {
        return Err(ServiceError::InvalidRequest(
            "endpoint_packages rollup_stats:current_cpe_counts does not support time filters"
                .into(),
        ));
    }

    let mut binds = Vec::new();
    let where_sql = build_cpe_count_where(&plan.filters, &mut binds)?;
    let sql = format!(
        r#"SELECT jsonb_build_object(
    'rollup_type', 'current_cpe_counts',
    'cpe', cpe,
    'host_count', host_count,
    'first_seen_at', first_seen_at,
    'last_seen_at', last_seen_at,
    'updated_at', updated_at
) AS payload
FROM endpoint_inventory_current_cpe_counts
{where_sql}
ORDER BY host_count DESC, cpe ASC
LIMIT {} OFFSET {}"#,
        plan.limit, plan.offset
    );

    Ok(EndpointPackageRollupSql { sql, binds })
}

fn build_package_counts_hourly_rollup(plan: &QueryPlan) -> Result<EndpointPackageRollupSql> {
    let mut binds = Vec::new();
    let where_sql = build_package_count_where(&plan.filters, &mut binds)?;
    let time_sql = build_bucket_time_clause(&plan.time_range, &mut binds);
    let where_sql = join_where_clauses(where_sql, time_sql);
    let sql = format!(
        r#"SELECT jsonb_build_object(
    'rollup_type', 'package_counts_hourly',
    'bucket', bucket,
    'coordinate_hash', coordinate_hash,
    'package_manager', package_manager,
    'ecosystem', NULLIF(ecosystem, ''),
    'name', name,
    'version', NULLIF(version, ''),
    'architecture', NULLIF(architecture, ''),
    'purl_canonical', NULLIF(purl_canonical, ''),
    'canonical_purl', NULLIF(purl_canonical, ''),
    'host_count', max_host_count,
    'max_host_count', max_host_count,
    'min_host_count', min_host_count,
    'net_count_delta', net_count_delta,
    'sample_count', sample_count
) AS payload
FROM endpoint_inventory_package_counts_hourly
{where_sql}
ORDER BY bucket DESC, max_host_count DESC, package_manager ASC, name ASC
LIMIT {} OFFSET {}"#,
        plan.limit, plan.offset
    );

    Ok(EndpointPackageRollupSql { sql, binds })
}

fn build_cpe_counts_hourly_rollup(plan: &QueryPlan) -> Result<EndpointPackageRollupSql> {
    let mut binds = Vec::new();
    let where_sql = build_cpe_count_where(&plan.filters, &mut binds)?;
    let time_sql = build_bucket_time_clause(&plan.time_range, &mut binds);
    let where_sql = join_where_clauses(where_sql, time_sql);
    let sql = format!(
        r#"SELECT jsonb_build_object(
    'rollup_type', 'cpe_counts_hourly',
    'bucket', bucket,
    'cpe', cpe,
    'host_count', max_host_count,
    'max_host_count', max_host_count,
    'min_host_count', min_host_count,
    'net_count_delta', net_count_delta,
    'sample_count', sample_count
) AS payload
FROM endpoint_inventory_cpe_counts_hourly
{where_sql}
ORDER BY bucket DESC, max_host_count DESC, cpe ASC
LIMIT {} OFFSET {}"#,
        plan.limit, plan.offset
    );

    Ok(EndpointPackageRollupSql { sql, binds })
}

fn build_package_count_where(filters: &[Filter], binds: &mut Vec<SqlBindValue>) -> Result<String> {
    let mut clauses = Vec::new();

    for filter in filters {
        match filter.field.as_str() {
            "name" | "package" => clauses.push(text_clause("name", filter, binds)?),
            "version" => clauses.push(text_clause("version", filter, binds)?),
            "architecture" | "arch" => clauses.push(text_clause("architecture", filter, binds)?),
            "package_manager" | "manager" => {
                clauses.push(text_clause("package_manager", filter, binds)?);
            }
            "ecosystem" => clauses.push(text_clause("ecosystem", filter, binds)?),
            "purl" | "purl_canonical" | "canonical_purl" => {
                clauses.push(text_clause("purl_canonical", filter, binds)?);
            }
            "cpe" | "cpes" => clauses.push(array_overlap_clause("cpes", filter, binds)?),
            other => {
                return Err(ServiceError::InvalidRequest(format!(
                    "endpoint package rollups do not support filter field '{other}'"
                )));
            }
        }
    }

    Ok(where_from_clauses(clauses))
}

fn build_cpe_count_where(filters: &[Filter], binds: &mut Vec<SqlBindValue>) -> Result<String> {
    let mut clauses = Vec::new();

    for filter in filters {
        match filter.field.as_str() {
            "cpe" | "cpes" => clauses.push(text_clause("cpe", filter, binds)?),
            other => {
                return Err(ServiceError::InvalidRequest(format!(
                    "endpoint CPE rollups do not support filter field '{other}'"
                )));
            }
        }
    }

    Ok(where_from_clauses(clauses))
}

fn build_bucket_time_clause(
    time_range: &Option<TimeRange>,
    binds: &mut Vec<SqlBindValue>,
) -> String {
    let Some(TimeRange { start, end }) = time_range else {
        return String::new();
    };

    let start_idx = push_bind(binds, SqlBindValue::Timestamp(*start));
    let end_idx = push_bind(binds, SqlBindValue::Timestamp(*end));
    format!("bucket >= ${start_idx} AND bucket <= ${end_idx}")
}

fn text_clause(column: &str, filter: &Filter, binds: &mut Vec<SqlBindValue>) -> Result<String> {
    match filter.op {
        FilterOp::Eq => {
            let idx = push_bind(
                binds,
                SqlBindValue::Text(filter.value.as_scalar()?.to_string()),
            );
            Ok(format!("{column} = ${idx}"))
        }
        FilterOp::In => {
            let values = filter.value.as_list()?.to_vec();
            let idx = push_bind(binds, SqlBindValue::TextArray(values));
            Ok(format!("{column} = ANY(${idx})"))
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "endpoint package rollup filter {column} only supports equality and membership"
        ))),
    }
}

fn array_overlap_clause(
    column: &str,
    filter: &Filter,
    binds: &mut Vec<SqlBindValue>,
) -> Result<String> {
    match filter.op {
        FilterOp::Eq | FilterOp::In => {
            let values = cpe_values(&filter.value)?;
            let idx = push_bind(binds, SqlBindValue::TextArray(values));
            Ok(format!("{column} && ${idx}"))
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "endpoint package rollup filter {column} only supports equality and membership"
        ))),
    }
}

fn push_bind(binds: &mut Vec<SqlBindValue>, value: SqlBindValue) -> usize {
    binds.push(value);
    binds.len()
}

fn where_from_clauses(clauses: Vec<String>) -> String {
    if clauses.is_empty() {
        String::new()
    } else {
        format!("WHERE {}", clauses.join(" AND "))
    }
}

fn join_where_clauses(first: String, second: String) -> String {
    match (first.is_empty(), second.is_empty()) {
        (true, true) => String::new(),
        (false, true) => first,
        (true, false) => format!("WHERE {second}"),
        (false, false) => format!("{first} AND {second}"),
    }
}

fn rewrite_placeholders(sql: &str) -> String {
    let mut output = String::with_capacity(sql.len());
    let mut chars = sql.chars().peekable();

    while let Some(ch) = chars.next() {
        if ch == '$' && matches!(chars.peek(), Some(next) if next.is_ascii_digit()) {
            while matches!(chars.peek(), Some(next) if next.is_ascii_digit()) {
                chars.next();
            }
            output.push('?');
        } else {
            output.push(ch);
        }
    }

    output
}

fn apply_filter<'a>(
    mut query: EndpointPackagesQuery<'a>,
    filter: &Filter,
) -> Result<EndpointPackagesQuery<'a>> {
    match filter.field.as_str() {
        "device_uid" | "device_id" => {
            query = apply_text_filter!(query, filter, col_device_uid)?;
        }
        "agent_id" => {
            query = apply_text_filter!(query, filter, col_agent_id)?;
        }
        "package_id" | "endpoint_package_ref" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_endpoint_package_ref,
                parse_uuid(filter.value.as_scalar()?)?,
                "package_id only supports equality comparisons"
            )?;
        }
        "name" | "package" => {
            query = apply_text_filter!(query, filter, col_name)?;
        }
        "version" => {
            query = apply_text_filter!(query, filter, col_version)?;
        }
        "architecture" | "arch" => {
            query = apply_text_filter!(query, filter, col_architecture)?;
        }
        "package_manager" | "manager" => {
            query = apply_text_filter!(query, filter, col_package_manager)?;
        }
        "ecosystem" => {
            query = apply_text_filter!(query, filter, col_ecosystem)?;
        }
        "purl" | "purl_canonical" | "canonical_purl" => {
            query = apply_text_filter!(query, filter, col_purl_canonical)?;
        }
        "raw_purl" => {
            query = apply_text_filter!(query, filter, col_purl)?;
        }
        "supplier" => {
            query = apply_text_filter!(query, filter, col_supplier)?;
        }
        "license" => {
            query = apply_text_filter!(query, filter, col_license)?;
        }
        "source" => {
            query = apply_text_filter!(query, filter, col_source)?;
        }
        "current" => {
            query = apply_current_filter(query, filter)?;
        }
        "cpe" | "cpes" => {
            query = apply_cpe_filter(query, filter)?;
        }
        "cve" | "cve_id" => {
            query = apply_package_match_cve_filter(query, filter)?;
        }
        "kev" => {
            query = apply_package_match_kev_filter(query, filter)?;
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for endpoint_packages: '{other}'"
            )));
        }
    }

    Ok(query)
}

fn apply_current_filter<'a>(
    query: EndpointPackagesQuery<'a>,
    filter: &Filter,
) -> Result<EndpointPackagesQuery<'a>> {
    let value = parse_bool(filter.value.as_scalar()?)?;

    match filter.op {
        FilterOp::Eq => Ok(query.filter(col_current.eq(value))),
        FilterOp::NotEq => Ok(query.filter(col_current.ne(value))),
        _ => Err(ServiceError::InvalidRequest(
            "current filter only supports equality".into(),
        )),
    }
}

fn apply_cpe_filter<'a>(
    query: EndpointPackagesQuery<'a>,
    filter: &Filter,
) -> Result<EndpointPackagesQuery<'a>> {
    let values = cpe_values(&filter.value)?;

    if values.is_empty() {
        return Ok(query);
    }

    match filter.op {
        FilterOp::Eq | FilterOp::In => Ok(query.filter(col_cpes.overlaps_with(values))),
        FilterOp::NotEq | FilterOp::NotIn => Ok(query.filter(not(col_cpes.overlaps_with(values)))),
        _ => Err(ServiceError::InvalidRequest(
            "cpe filter only supports equality and membership".into(),
        )),
    }
}

fn apply_package_match_cve_filter<'a>(
    query: EndpointPackagesQuery<'a>,
    filter: &Filter,
) -> Result<EndpointPackagesQuery<'a>> {
    let prefix = "EXISTS (SELECT 1 FROM endpoint_vulnerability_assessments a \
         WHERE a.endpoint_package_ref = endpoint_inventory_packages.endpoint_package_ref \
         AND a.device_uid = endpoint_inventory_packages.device_uid \
         AND a.status = 'active' AND a.assessment = 'confirmed' \
         AND a.disposition = 'affected' AND ";
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq | FilterOp::In | FilterOp::NotIn => {
            let values = crate::query::advisory::cve_eq_values(filter)?;
            if values.is_empty() {
                return Ok(query);
            }
            let expr = sql::<Bool>(prefix)
                .sql("a.cve_id = ANY(")
                .bind::<Array<Text>, _>(values)
                .sql("))");
            Ok(if matches!(filter.op, FilterOp::NotEq | FilterOp::NotIn) {
                query.filter(not(expr))
            } else {
                query.filter(expr)
            })
        }
        FilterOp::Like | FilterOp::NotLike => {
            let value = filter.value.as_scalar()?.to_string();
            let expr = sql::<Bool>(prefix)
                .sql("a.cve_id ILIKE ")
                .bind::<Text, _>(value)
                .sql(")");
            Ok(if matches!(filter.op, FilterOp::NotLike) {
                query.filter(not(expr))
            } else {
                query.filter(expr)
            })
        }
        _ => Err(ServiceError::InvalidRequest(
            "cve filter only supports equality, membership, and % wildcards".into(),
        )),
    }
}

fn apply_package_match_kev_filter<'a>(
    query: EndpointPackagesQuery<'a>,
    filter: &Filter,
) -> Result<EndpointPackagesQuery<'a>> {
    if !matches!(filter.op, FilterOp::Eq | FilterOp::NotEq) {
        return Err(ServiceError::InvalidRequest(
            "kev filter only supports equality".into(),
        ));
    }
    let want = parse_bool(filter.value.as_scalar()?)?;
    let want = if matches!(filter.op, FilterOp::NotEq) {
        !want
    } else {
        want
    };
    let expr = sql::<Bool>(
        "EXISTS (SELECT 1 FROM endpoint_vulnerability_assessments a \
         WHERE a.endpoint_package_ref = endpoint_inventory_packages.endpoint_package_ref \
         AND a.device_uid = endpoint_inventory_packages.device_uid \
         AND a.status = 'active' AND a.assessment = 'confirmed' \
         AND a.disposition = 'affected' AND a.kev = ",
    )
    .bind::<Bool, _>(true)
    .sql(")");
    Ok(if want {
        query.filter(expr)
    } else {
        query.filter(not(expr))
    })
}

fn cpe_values(value: &FilterValue) -> Result<Vec<String>> {
    match value {
        FilterValue::Scalar(item) => Ok(vec![item.clone()]),
        FilterValue::List(items) => Ok(items.clone()),
    }
}

fn parse_bool(raw: &str) -> Result<bool> {
    match raw.to_ascii_lowercase().as_str() {
        "true" | "t" | "yes" | "y" | "1" => Ok(true),
        "false" | "f" | "no" | "n" | "0" => Ok(false),
        other => Err(ServiceError::InvalidRequest(format!(
            "invalid boolean value '{other}'"
        ))),
    }
}

fn parse_uuid(raw: &str) -> Result<uuid::Uuid> {
    uuid::Uuid::parse_str(raw)
        .map_err(|_| ServiceError::InvalidRequest(format!("invalid uuid '{raw}'")))
}

fn collect_text_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq | FilterOp::Like | FilterOp::NotLike => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        FilterOp::In | FilterOp::NotIn => {
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
        "device_uid" | "device_id" | "agent_id" | "name" | "package" | "version"
        | "architecture" | "arch" | "package_manager" | "manager" | "ecosystem" | "purl"
        | "purl_canonical" | "canonical_purl" | "raw_purl" | "supplier" | "license" | "source" => {
            collect_text_params(params, filter)
        }
        "package_id" | "endpoint_package_ref" => {
            params.push(BindParam::Uuid(parse_uuid(filter.value.as_scalar()?)?));
            Ok(())
        }
        "current" => {
            params.push(BindParam::Bool(parse_bool(filter.value.as_scalar()?)?));
            Ok(())
        }
        "cpe" | "cpes" => {
            let values = cpe_values(&filter.value)?;
            if values.is_empty() {
                return Ok(());
            }
            params.push(BindParam::TextArray(values));
            Ok(())
        }
        "cve" | "cve_id" => match filter.op {
            FilterOp::Eq | FilterOp::NotEq | FilterOp::In | FilterOp::NotIn => {
                let values = crate::query::advisory::cve_eq_values(filter)?;
                if values.is_empty() {
                    return Ok(());
                }
                params.push(BindParam::TextArray(values));
                Ok(())
            }
            FilterOp::Like | FilterOp::NotLike => {
                params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
                Ok(())
            }
            _ => Err(ServiceError::InvalidRequest(
                "cve filter only supports equality, membership, and % wildcards".into(),
            )),
        },
        "kev" => {
            let _ = parse_bool(filter.value.as_scalar()?)?;
            params.push(BindParam::Bool(true));
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field '{other}'"
        ))),
    }
}

fn apply_ordering<'a>(
    mut query: EndpointPackagesQuery<'a>,
    order: &[OrderClause],
) -> EndpointPackagesQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            apply_single_order(query, clause.field.as_str(), clause.direction)
        } else {
            apply_secondary_order(query, clause.field.as_str(), clause.direction)
        };
    }

    if !applied {
        query = query
            .order(col_updated_at.desc())
            .then_order_by(col_name.asc());
    }

    query
}

fn apply_single_order<'a>(
    query: EndpointPackagesQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> EndpointPackagesQuery<'a> {
    match field {
        "device_uid" | "device_id" => match direction {
            OrderDirection::Asc => query.order(col_device_uid.asc()),
            OrderDirection::Desc => query.order(col_device_uid.desc()),
        },
        "agent_id" => match direction {
            OrderDirection::Asc => query.order(col_agent_id.asc()),
            OrderDirection::Desc => query.order(col_agent_id.desc()),
        },
        "package_id" | "endpoint_package_ref" => match direction {
            OrderDirection::Asc => query.order(col_endpoint_package_ref.asc()),
            OrderDirection::Desc => query.order(col_endpoint_package_ref.desc()),
        },
        "name" | "package" => match direction {
            OrderDirection::Asc => query.order(col_name.asc()),
            OrderDirection::Desc => query.order(col_name.desc()),
        },
        "version" => match direction {
            OrderDirection::Asc => query.order(col_version.asc()),
            OrderDirection::Desc => query.order(col_version.desc()),
        },
        "architecture" | "arch" => match direction {
            OrderDirection::Asc => query.order(col_architecture.asc()),
            OrderDirection::Desc => query.order(col_architecture.desc()),
        },
        "package_manager" | "manager" => match direction {
            OrderDirection::Asc => query.order(col_package_manager.asc()),
            OrderDirection::Desc => query.order(col_package_manager.desc()),
        },
        "ecosystem" => match direction {
            OrderDirection::Asc => query.order(col_ecosystem.asc()),
            OrderDirection::Desc => query.order(col_ecosystem.desc()),
        },
        "current" => match direction {
            OrderDirection::Asc => query.order(col_current.asc()),
            OrderDirection::Desc => query.order(col_current.desc()),
        },
        "inserted_at" => match direction {
            OrderDirection::Asc => query.order(col_inserted_at.asc()),
            OrderDirection::Desc => query.order(col_inserted_at.desc()),
        },
        "updated_at" => match direction {
            OrderDirection::Asc => query.order(col_updated_at.asc()),
            OrderDirection::Desc => query.order(col_updated_at.desc()),
        },
        _ => query,
    }
}

fn apply_secondary_order<'a>(
    query: EndpointPackagesQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> EndpointPackagesQuery<'a> {
    match field {
        "device_uid" | "device_id" => match direction {
            OrderDirection::Asc => query.then_order_by(col_device_uid.asc()),
            OrderDirection::Desc => query.then_order_by(col_device_uid.desc()),
        },
        "agent_id" => match direction {
            OrderDirection::Asc => query.then_order_by(col_agent_id.asc()),
            OrderDirection::Desc => query.then_order_by(col_agent_id.desc()),
        },
        "package_id" | "endpoint_package_ref" => match direction {
            OrderDirection::Asc => query.then_order_by(col_endpoint_package_ref.asc()),
            OrderDirection::Desc => query.then_order_by(col_endpoint_package_ref.desc()),
        },
        "name" | "package" => match direction {
            OrderDirection::Asc => query.then_order_by(col_name.asc()),
            OrderDirection::Desc => query.then_order_by(col_name.desc()),
        },
        "version" => match direction {
            OrderDirection::Asc => query.then_order_by(col_version.asc()),
            OrderDirection::Desc => query.then_order_by(col_version.desc()),
        },
        "architecture" | "arch" => match direction {
            OrderDirection::Asc => query.then_order_by(col_architecture.asc()),
            OrderDirection::Desc => query.then_order_by(col_architecture.desc()),
        },
        "package_manager" | "manager" => match direction {
            OrderDirection::Asc => query.then_order_by(col_package_manager.asc()),
            OrderDirection::Desc => query.then_order_by(col_package_manager.desc()),
        },
        "ecosystem" => match direction {
            OrderDirection::Asc => query.then_order_by(col_ecosystem.asc()),
            OrderDirection::Desc => query.then_order_by(col_ecosystem.desc()),
        },
        "current" => match direction {
            OrderDirection::Asc => query.then_order_by(col_current.asc()),
            OrderDirection::Desc => query.then_order_by(col_current.desc()),
        },
        "inserted_at" => match direction {
            OrderDirection::Asc => query.then_order_by(col_inserted_at.asc()),
            OrderDirection::Desc => query.then_order_by(col_inserted_at.desc()),
        },
        "updated_at" => match direction {
            OrderDirection::Asc => query.then_order_by(col_updated_at.asc()),
            OrderDirection::Desc => query.then_order_by(col_updated_at.desc()),
        },
        _ => query,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::{Filter, FilterOp, FilterValue};

    fn plan_with(filters: Vec<Filter>) -> QueryPlan {
        QueryPlan {
            entity: Entity::EndpointPackages,
            filters,
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: None,
            stats: None,
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
        }
    }

    fn rollup_plan(rollup: &str, filters: Vec<Filter>) -> QueryPlan {
        QueryPlan {
            rollup_stats: Some(rollup.to_string()),
            ..plan_with(filters)
        }
    }

    #[test]
    fn builds_query_with_package_filters() {
        for field in [
            "device_uid",
            "agent_id",
            "package_id",
            "name",
            "version",
            "architecture",
            "package_manager",
            "ecosystem",
            "purl",
            "purl_canonical",
            "canonical_purl",
            "raw_purl",
            "supplier",
            "license",
            "source",
        ] {
            let value = if field == "package_id" {
                "11111111-1111-4111-8111-111111111111"
            } else {
                "x"
            };

            let plan = plan_with(vec![Filter {
                field: field.into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar(value.to_string()),
            }]);
            assert!(
                build_query(&plan).is_ok(),
                "should build query with {field} filter"
            );
        }
    }

    #[test]
    fn builds_query_with_current_and_cpe_filters() {
        let plan = plan_with(vec![
            Filter {
                field: "current".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("true".to_string()),
            },
            Filter {
                field: "cpe".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:*".into()),
            },
        ]);

        assert!(build_query(&plan).is_ok());
    }

    #[test]
    fn cve_pivot_uses_only_actionable_assessments() {
        let plan = plan_with(vec![Filter {
            field: "cve".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("cve-2026-0001".into()),
        }]);
        let (sql, params) = to_sql_and_params(&plan).expect("sql");
        assert!(
            sql.contains("endpoint_vulnerability_assessments"),
            "expected EXISTS against assessments, got {sql}"
        );
        assert!(sql.contains("a.status = 'active'"));
        assert!(sql.contains("a.assessment = 'confirmed'"));
        assert!(sql.contains("a.disposition = 'affected'"));
        assert!(
            sql.contains("a.device_uid = endpoint_inventory_packages.device_uid"),
            "assessment lookup must stay scoped to the package's device, got {sql}"
        );
        assert!(
            sql.contains("endpoint_inventory_packages"),
            "package grain must be preserved, got {sql}"
        );
        assert!(
            params.iter().any(|param| {
                matches!(param, BindParam::TextArray(values) if values == &["CVE-2026-0001".to_string()])
            }),
            "CVE must be bound uppercased, got {params:?}"
        );
    }

    #[test]
    fn kev_pivot_is_scoped_to_the_package_device() {
        let plan = plan_with(vec![Filter {
            field: "kev".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("true".into()),
        }]);
        let (sql, _params) = to_sql_and_params(&plan).expect("sql");

        assert!(sql.contains("a.status = 'active'"));
        assert!(sql.contains("a.assessment = 'confirmed'"));
        assert!(sql.contains("a.disposition = 'affected'"));
        assert!(
            sql.contains("a.device_uid = endpoint_inventory_packages.device_uid"),
            "KEV lookup must stay scoped to the package's device, got {sql}"
        );
    }

    #[test]
    fn unknown_filter_field_returns_error() {
        let plan = plan_with(vec![Filter {
            field: "scan_ref".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("x".to_string()),
        }]);

        match build_query(&plan) {
            Err(err) => assert!(
                err.to_string().contains("unsupported filter field"),
                "unexpected error: {err}"
            ),
            Ok(_) => panic!("expected error for unsupported filter field"),
        }
    }

    #[test]
    fn current_counts_rollup_uses_maintained_count_table() {
        let plan = rollup_plan(
            "current_counts",
            vec![Filter {
                field: "name".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("nginx".to_string()),
            }],
        );

        let (sql, params) = to_sql_and_params(&plan).expect("current counts rollup SQL");

        assert!(
            sql.contains("endpoint_inventory_current_package_counts"),
            "expected current count table in SQL, got: {sql}"
        );
        assert!(
            !sql.contains("endpoint_inventory_packages"),
            "rollup must not aggregate live current package rows, got: {sql}"
        );
        assert!(
            !sql.to_ascii_uppercase().contains("GROUP BY"),
            "current rollup must not GROUP BY current-state rows, got: {sql}"
        );
        assert_eq!(params.len(), 1);
    }

    #[test]
    fn package_counts_hourly_rollup_uses_continuous_aggregate() {
        let mut plan = rollup_plan(
            "package_counts_hourly",
            vec![Filter {
                field: "package_manager".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("dpkg".to_string()),
            }],
        );
        plan.time_range = Some(TimeRange {
            start: Utc::now() - chrono::Duration::hours(2),
            end: Utc::now(),
        });

        let (sql, params) = to_sql_and_params(&plan).expect("hourly package count SQL");

        assert!(
            sql.contains("endpoint_inventory_package_counts_hourly"),
            "expected package count CAGG in SQL, got: {sql}"
        );
        assert!(
            !sql.contains("endpoint_inventory_packages"),
            "historical rollup must not scan package current-state rows, got: {sql}"
        );
        assert_eq!(params.len(), 3);
    }

    #[test]
    fn unsupported_rollup_returns_bounded_error() {
        let plan = rollup_plan("ad_hoc_group_by", Vec::new());

        match to_sql_and_params(&plan) {
            Err(err) => assert!(
                err.to_string().contains("unsupported rollup_stats type"),
                "unexpected error: {err}"
            ),
            Ok(_) => panic!("expected unsupported rollup error"),
        }
    }
}
