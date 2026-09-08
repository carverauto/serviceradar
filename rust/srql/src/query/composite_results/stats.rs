//! `stats:count() as n by …` for `in:composite_results`.
//!
//! The row query ignores `plan.stats`. That is a silent lie: the parser
//! accepts the clause and the entity returns a truncated dump. This builder
//! is the GROUP BY path. Unsupported aggregations and group fields error.

use super::super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    jsonb::DbJson,
    parser::{Filter, FilterOp},
    time::TimeRange,
};
use diesel::QueryableByName;
use diesel::sql_types::{Jsonb, Nullable};

pub(super) const SUPPORTED_GROUP_FIELDS: &str =
    "check, check_slug, check_name, verdict, status, input_key, input_value, input_stale";

const MAX_GROUP_LIMIT: i64 = 500;

#[derive(Debug, QueryableByName)]
#[diesel(check_for_backend(diesel::pg::Pg))]
pub(super) struct StatsPayload {
    #[diesel(sql_type = Nullable<Jsonb>)]
    pub(super) payload: Option<DbJson>,
}

#[derive(Debug, Clone)]
pub(super) struct StatsSpec {
    pub(super) alias: String,
    pub(super) group_fields: Vec<GroupField>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum GroupField {
    Check,
    CheckName,
    Verdict,
    Status,
    InputKey,
    InputValue,
    InputStale,
}

impl GroupField {
    fn parse(raw: &str) -> Result<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "check" | "check_slug" | "slug" => Ok(Self::Check),
            "check_name" => Ok(Self::CheckName),
            "verdict" => Ok(Self::Verdict),
            "status" => Ok(Self::Status),
            "input_key" => Ok(Self::InputKey),
            "input_value" => Ok(Self::InputValue),
            "input_stale" => Ok(Self::InputStale),
            other => Err(ServiceError::InvalidRequest(format!(
                "unsupported stats group field '{other}'. Supported fields: {SUPPORTED_GROUP_FIELDS}"
            ))),
        }
    }

    fn column(self) -> &'static str {
        match self {
            Self::Check => "composite_checks.slug",
            Self::CheckName => "composite_checks.name",
            Self::Verdict => "device_composite_check_results.verdict",
            Self::Status => "device_composite_check_results.status",
            Self::InputKey => "input.key",
            Self::InputValue => "input.value->>'value'",
            Self::InputStale => "COALESCE((input.value->>'stale')::boolean, false)",
        }
    }

    fn response_key(self) -> &'static str {
        match self {
            Self::Check => "check",
            Self::CheckName => "check_name",
            Self::Verdict => "verdict",
            Self::Status => "status",
            Self::InputKey => "input_key",
            Self::InputValue => "input_value",
            Self::InputStale => "input_stale",
        }
    }

    fn needs_unnest(self) -> bool {
        matches!(self, Self::InputKey | Self::InputValue | Self::InputStale)
    }
}

#[derive(Debug, Clone)]
pub(super) struct StatsSql {
    pub(super) sql: String,
    pub(super) params: Vec<BindParam>,
}

pub(super) fn parse_stats_spec(raw: Option<&str>) -> Result<Option<StatsSpec>> {
    let raw = match raw {
        Some(raw) if !raw.trim().is_empty() => raw.trim(),
        _ => return Ok(None),
    };

    let tokens: Vec<&str> = raw.split_whitespace().collect();
    if tokens.len() < 3 {
        return Err(ServiceError::InvalidRequest(
            "composite_results stats must be of the form 'count() as alias'".into(),
        ));
    }

    if !tokens[0].eq_ignore_ascii_case("count()") || !tokens[1].eq_ignore_ascii_case("as") {
        return Err(ServiceError::InvalidRequest(
            "composite_results stats only support count()".into(),
        ));
    }

    let alias = tokens[2]
        .trim_matches('"')
        .trim_matches('\'')
        .to_ascii_lowercase();
    if alias.is_empty()
        || alias
            .chars()
            .any(|ch| !ch.is_ascii_alphanumeric() && ch != '_')
    {
        return Err(ServiceError::InvalidRequest(
            "stats alias must be alphanumeric".into(),
        ));
    }

    let group_fields = if tokens.len() >= 5 {
        if !tokens[3].eq_ignore_ascii_case("by") {
            return Err(ServiceError::InvalidRequest(
                "expected 'by <field>' after stats alias".into(),
            ));
        }
        parse_group_fields(&tokens[4..].join(" "))?
    } else if tokens.len() > 3 {
        return Err(ServiceError::InvalidRequest(
            "expected 'by <field>' after stats alias".into(),
        ));
    } else {
        Vec::new()
    };

    Ok(Some(StatsSpec {
        alias,
        group_fields,
    }))
}

fn parse_group_fields(raw: &str) -> Result<Vec<GroupField>> {
    let fields = raw
        .split(',')
        .map(str::trim)
        .filter(|field| !field.is_empty())
        .map(GroupField::parse)
        .collect::<Result<Vec<_>>>()?;

    if fields.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "expected at least one stats group field".into(),
        ));
    }

    Ok(fields)
}

pub(super) fn build_stats_query(plan: &QueryPlan, spec: &StatsSpec) -> Result<StatsSql> {
    let mut params = Vec::new();
    let mut clauses = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        clauses.push("device_composite_check_results.evaluated_at >= ?".to_string());
        params.push(BindParam::timestamptz(*start));
        clauses.push("device_composite_check_results.evaluated_at <= ?".to_string());
        params.push(BindParam::timestamptz(*end));
    }

    for filter in &plan.filters {
        clauses.push(filter_clause(filter, &mut params)?);
    }

    let needs_unnest = spec.group_fields.iter().any(|field| field.needs_unnest());

    let mut sql = if spec.group_fields.is_empty() {
        format!(
            "SELECT jsonb_build_object('{}', COUNT(*)) AS payload",
            spec.alias
        )
    } else {
        let pairs = spec
            .group_fields
            .iter()
            .map(|field| format!("'{}', {}", field.response_key(), field.column()))
            .collect::<Vec<_>>()
            .join(", ");
        format!(
            "SELECT jsonb_build_object({pairs}, '{}', COUNT(*)) AS payload",
            spec.alias
        )
    };

    sql.push_str(
        "\nFROM device_composite_check_results\nINNER JOIN composite_checks ON composite_checks.id = device_composite_check_results.check_id",
    );

    if needs_unnest {
        sql.push_str(
            "\nCROSS JOIN LATERAL jsonb_each(COALESCE(device_composite_check_results.inputs, '{}'::jsonb)) AS input(key, value)",
        );
    }

    if !clauses.is_empty() {
        sql.push_str("\nWHERE ");
        sql.push_str(&clauses.join(" AND "));
    }

    if !spec.group_fields.is_empty() {
        let group_by = spec
            .group_fields
            .iter()
            .map(|field| field.column())
            .collect::<Vec<_>>()
            .join(", ");
        sql.push_str(&format!("\nGROUP BY {group_by}"));
        sql.push_str("\nORDER BY COUNT(*) DESC");
        let limit = plan.limit.clamp(1, MAX_GROUP_LIMIT);
        sql.push_str(&format!("\nLIMIT {limit}"));
        if plan.offset > 0 {
            sql.push_str(&format!(" OFFSET {}", plan.offset));
        }
    }

    Ok(StatsSql { sql, params })
}

pub(super) fn rewrite_placeholders(sql: &str) -> String {
    let mut result = String::with_capacity(sql.len());
    let mut index = 1;
    for ch in sql.chars() {
        if ch == '?' {
            result.push('$');
            result.push_str(&index.to_string());
            index += 1;
        } else {
            result.push(ch);
        }
    }
    result
}

fn filter_clause(filter: &Filter, params: &mut Vec<BindParam>) -> Result<String> {
    let column = match filter.field.as_str() {
        "check" | "check_slug" | "slug" => "composite_checks.slug",
        "check_name" => "composite_checks.name",
        "verdict" => "device_composite_check_results.verdict",
        "status" => "device_composite_check_results.status",
        "device_uid" | "device" | "uid" => "device_composite_check_results.device_uid",
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field '{other}' for composite results"
            )));
        }
    };

    match filter.op {
        FilterOp::Eq => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("{column} = ?"))
        }
        FilterOp::NotEq => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("({column} IS NULL OR {column} <> ?)"))
        }
        FilterOp::Like => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("{column} ILIKE ?"))
        }
        FilterOp::NotLike => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("({column} IS NULL OR {column} NOT ILIKE ?)"))
        }
        FilterOp::In => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok("1=1".to_string());
            }
            params.push(BindParam::TextArray(values));
            Ok(format!("{column} = ANY(?)"))
        }
        FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok("1=1".to_string());
            }
            params.push(BindParam::TextArray(values));
            Ok(format!("({column} IS NULL OR NOT ({column} = ANY(?)))"))
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "{} filter does not support that comparison",
            filter.field
        ))),
    }
}
