//! `stats:count() as n [by ...]` rollups for `in:declarative_check_results`.

use super::super::{BindParam, QueryPlan};
use super::{TimestampBound, parse_check_uuid, parse_timestamp_bound};
use crate::{
    error::{Result, ServiceError},
    jsonb::DbJson,
    parser::{Filter, FilterOp},
    time::TimeRange,
};
use chrono::{DateTime, Utc};
use diesel::QueryableByName;
use diesel::sql_types::{Jsonb, Nullable};

pub(super) const SUPPORTED_GROUP_FIELDS: &str = "check_slug, slug, check, check_name, check_id, verdict, status, state, target_key, target_kind, device_uid";

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
    CheckSlug,
    Check,
    CheckName,
    CheckId,
    Verdict,
    Status,
    State,
    TargetKey,
    TargetKind,
    DeviceUid,
}

impl GroupField {
    fn parse(raw: &str) -> Result<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "check_slug" | "slug" => Ok(Self::CheckSlug),
            "check" => Ok(Self::Check),
            "check_name" | "name" => Ok(Self::CheckName),
            "check_id" => Ok(Self::CheckId),
            "verdict" => Ok(Self::Verdict),
            "status" => Ok(Self::Status),
            "state" | "check_state" => Ok(Self::State),
            "target_key" | "target" => Ok(Self::TargetKey),
            "target_kind" => Ok(Self::TargetKind),
            "device_uid" | "device" | "device_id" | "uid" => Ok(Self::DeviceUid),
            other => Err(ServiceError::InvalidRequest(format!(
                "unsupported stats group field '{other}'. Supported fields: {SUPPORTED_GROUP_FIELDS}"
            ))),
        }
    }

    fn column(self) -> &'static str {
        match self {
            Self::CheckSlug | Self::Check => "declarative_checks.slug",
            Self::CheckName => "declarative_checks.name",
            Self::CheckId => "declarative_check_instances.check_id",
            Self::Verdict => "declarative_check_instances.verdict",
            Self::Status => "declarative_check_instances.status",
            Self::State => "declarative_checks.state",
            Self::TargetKey => "declarative_check_instances.target_key",
            Self::TargetKind => "declarative_check_instances.target_kind",
            Self::DeviceUid => "declarative_check_instances.device_uid",
        }
    }

    fn response_key(self) -> &'static str {
        match self {
            Self::CheckSlug => "check_slug",
            Self::Check => "check",
            Self::CheckName => "check_name",
            Self::CheckId => "check_id",
            Self::Verdict => "verdict",
            Self::Status => "status",
            Self::State => "state",
            Self::TargetKey => "target_key",
            Self::TargetKind => "target_kind",
            Self::DeviceUid => "device_uid",
        }
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
            "declarative_check_results stats must be of the form 'count() as alias'".into(),
        ));
    }

    if !tokens[0].eq_ignore_ascii_case("count()") || !tokens[1].eq_ignore_ascii_case("as") {
        return Err(ServiceError::InvalidRequest(
            "declarative_check_results stats only support count()".into(),
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

pub(super) fn build_stats_query(
    plan: &QueryPlan,
    spec: &StatsSpec,
    now: DateTime<Utc>,
) -> Result<StatsSql> {
    let mut params = Vec::new();
    let mut clauses = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        clauses.push("declarative_check_instances.evaluated_at >= ?".to_string());
        params.push(BindParam::timestamptz(*start));
        clauses.push("declarative_check_instances.evaluated_at <= ?".to_string());
        params.push(BindParam::timestamptz(*end));
    }

    for filter in &plan.filters {
        clauses.push(filter_clause(filter, &mut params, now)?);
    }

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
        "\nFROM declarative_check_instances\nINNER JOIN declarative_checks ON declarative_checks.id = declarative_check_instances.check_id",
    );

    if !clauses.is_empty() {
        sql.push_str("\nWHERE ");
        sql.push_str(&clauses.join(" AND "));
    }

    if !spec.group_fields.is_empty() {
        let mut group_columns = Vec::with_capacity(spec.group_fields.len());
        for field in &spec.group_fields {
            let col = field.column();
            if !group_columns.contains(&col) {
                group_columns.push(col);
            }
        }
        let group_by = group_columns.join(", ");
        sql.push_str(&format!("\nGROUP BY {group_by}"));
        sql.push_str("\nORDER BY COUNT(*) DESC");
        let limit = plan.limit.max(1);
        sql.push_str(&format!("\nLIMIT {limit}"));
        if plan.offset > 0 {
            sql.push_str(&format!(" OFFSET {}", plan.offset));
        }
    }

    Ok(StatsSql { sql, params })
}

fn filter_clause(
    filter: &Filter,
    params: &mut Vec<BindParam>,
    now: DateTime<Utc>,
) -> Result<String> {
    match filter.field.as_str() {
        "check_id" => {
            if !matches!(filter.op, FilterOp::Eq | FilterOp::NotEq) {
                return Err(ServiceError::InvalidRequest(
                    "check_id filter only supports equality".into(),
                ));
            }
            let uuid = parse_check_uuid(filter)?;
            params.push(BindParam::Uuid(uuid));
            return Ok(if matches!(filter.op, FilterOp::Eq) {
                "declarative_check_instances.check_id = ?".to_string()
            } else {
                "declarative_check_instances.check_id <> ?".to_string()
            });
        }
        "evaluated_at" | "changed_at" => {
            let column = if filter.field == "evaluated_at" {
                "declarative_check_instances.evaluated_at"
            } else {
                "declarative_check_instances.changed_at"
            };
            return match parse_timestamp_bound(filter, now)? {
                TimestampBound::Comparison(ts) => {
                    let op = match filter.op {
                        FilterOp::Eq => "=",
                        FilterOp::NotEq => "<>",
                        FilterOp::Gt => ">",
                        FilterOp::Gte => ">=",
                        FilterOp::Lt => "<",
                        FilterOp::Lte => "<=",
                        _ => unreachable!("validated by parse_timestamp_bound"),
                    };
                    params.push(BindParam::timestamptz(ts));
                    Ok(format!("{column} {op} ?"))
                }
                TimestampBound::Range {
                    start,
                    end,
                    negated: false,
                } => {
                    params.push(BindParam::timestamptz(start));
                    params.push(BindParam::timestamptz(end));
                    Ok(format!("({column} >= ? AND {column} <= ?)"))
                }
                TimestampBound::Range {
                    start,
                    end,
                    negated: true,
                } => {
                    params.push(BindParam::timestamptz(start));
                    params.push(BindParam::timestamptz(end));
                    Ok(format!("({column} < ? OR {column} > ?)"))
                }
            };
        }
        _ => {}
    }

    let column = match filter.field.as_str() {
        "check" | "check_slug" | "slug" => "declarative_checks.slug",
        "check_name" | "name" => "declarative_checks.name",
        "state" | "check_state" => "declarative_checks.state",
        "target_key" | "target" => "declarative_check_instances.target_key",
        "target_kind" => "declarative_check_instances.target_kind",
        "device_uid" | "device" | "device_id" | "uid" => "declarative_check_instances.device_uid",
        "service_target_id" => "declarative_check_instances.service_target_id",
        "verdict" => "declarative_check_instances.verdict",
        "status" => "declarative_check_instances.status",
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field '{other}' for declarative check results"
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
