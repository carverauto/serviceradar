use super::super::DeviceQuery;
use crate::{
    error::{Result, ServiceError},
    parser::{Filter, FilterOp, FilterValue},
};
use diesel::{
    dsl::{not, sql},
    prelude::*,
    sql_types::{Array, Bool, Text},
};

/// Which column of a declarative check instance the filter compares.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(in crate::query::devices) enum DeclarativeColumn {
    Verdict,
    Status,
}

impl DeclarativeColumn {
    fn column(self) -> &'static str {
        match self {
            DeclarativeColumn::Verdict => "r.verdict",
            DeclarativeColumn::Status => "r.status",
        }
    }
}

/// Splits `declarative.<slug>` / `declarative.<slug>.status` into its parts.
///
/// Mirrors `parse_composite_field`, while matching `platform.declarative_checks`'s
/// slug contract (`^[a-z0-9][a-z0-9._-]{0,126}$`). A `.status` suffix selects the
/// normalized status column (`healthy|degraded|down|unknown`), while `.verdict`
/// is rejected as a misspelled suffix (`declarative.<slug>` already compares
/// `r.verdict`).
pub(in crate::query::devices) fn parse_declarative_field(
    field: &str,
) -> Option<(String, DeclarativeColumn)> {
    let rest = field.strip_prefix("declarative.")?;

    if rest.ends_with(".verdict") {
        return None;
    }

    let (slug, column) = if let Some(slug) = rest.strip_suffix(".status") {
        (slug, DeclarativeColumn::Status)
    } else {
        (rest, DeclarativeColumn::Verdict)
    };

    if is_valid_slug(slug) {
        Some((slug.to_string(), column))
    } else {
        None
    }
}

fn is_valid_slug(slug: &str) -> bool {
    let mut chars = slug.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if slug.len() > 127 || slug.contains("..") {
        return false;
    }
    if !(first.is_ascii_lowercase() || first.is_ascii_digit()) {
        return false;
    }
    if slug.ends_with('-') || slug.ends_with('.') || slug.ends_with('_') {
        return false;
    }
    slug.chars()
        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '-' | '_' | '.'))
}

/// Compiles a declarative check verdict/status filter into a correlated `EXISTS`
/// over `declarative_check_instances` joined with `declarative_checks`.
///
/// Mirrors `apply_composite_verdict_filter`: binds `Text` (slug) then
/// `Array<Text>` (values), in lockstep with `filters/params.rs`.
pub(in crate::query::devices) fn apply_declarative_verdict_filter<'a>(
    query: DeviceQuery<'a>,
    filter: &Filter,
    slug: &str,
    column: DeclarativeColumn,
) -> Result<DeviceQuery<'a>> {
    let values = filter_values(filter);

    if values.is_empty() {
        return Ok(query);
    }

    let negated = match filter.op {
        FilterOp::Eq | FilterOp::In => false,
        FilterOp::NotEq | FilterOp::NotIn => true,
        _ => {
            return Err(ServiceError::InvalidRequest(
                "declarative check filters only support equality and list membership".into(),
            ));
        }
    };

    let expr = sql::<Bool>(
        "EXISTS (SELECT 1 FROM declarative_check_instances r \
         JOIN declarative_checks c ON c.id = r.check_id \
         WHERE r.device_uid = ocsf_devices.uid AND c.slug = ",
    )
    .bind::<Text, _>(slug.to_string())
    .sql(&format!(" AND {} = ANY(", column.column()))
    .bind::<Array<Text>, _>(values)
    .sql("))");

    Ok(if negated {
        query.filter(not(expr))
    } else {
        query.filter(expr)
    })
}

pub(in crate::query::devices) fn filter_values(filter: &Filter) -> Vec<String> {
    match &filter.value {
        FilterValue::Scalar(v) => vec![v.to_string()],
        FilterValue::List(list) => list.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_verdict_field() {
        assert_eq!(
            parse_declarative_field("declarative.edge-tls-expiry"),
            Some(("edge-tls-expiry".to_string(), DeclarativeColumn::Verdict))
        );
    }

    #[test]
    fn parses_a_status_field() {
        assert_eq!(
            parse_declarative_field("declarative.edge-tls-expiry.status"),
            Some(("edge-tls-expiry".to_string(), DeclarativeColumn::Status))
        );
    }

    #[test]
    fn parses_slugs_with_underscores_and_dots() {
        assert_eq!(
            parse_declarative_field("declarative.storage.entitlement_utilization"),
            Some((
                "storage.entitlement_utilization".to_string(),
                DeclarativeColumn::Verdict
            ))
        );
        assert_eq!(
            parse_declarative_field("declarative.storage.entitlement_utilization.status"),
            Some((
                "storage.entitlement_utilization".to_string(),
                DeclarativeColumn::Status
            ))
        );
    }

    #[test]
    fn rejects_a_bare_prefix() {
        assert_eq!(parse_declarative_field("declarative."), None);
        assert_eq!(parse_declarative_field("declarative"), None);
    }

    #[test]
    fn a_check_slugged_status_is_addressable() {
        assert_eq!(
            parse_declarative_field("declarative.status"),
            Some(("status".to_string(), DeclarativeColumn::Verdict))
        );
        assert_eq!(
            parse_declarative_field("declarative.status.status"),
            Some(("status".to_string(), DeclarativeColumn::Status))
        );
    }

    #[test]
    fn rejects_verdict_suffix_and_malformed_slugs() {
        assert_eq!(
            parse_declarative_field("declarative.edge-tls-expiry.verdict"),
            None
        );
        assert_eq!(parse_declarative_field("declarative.Bad Slug"), None);
        assert_eq!(
            parse_declarative_field("declarative.a';DROP TABLE x;--"),
            None
        );
        assert_eq!(parse_declarative_field("declarative.-leading"), None);
        assert_eq!(parse_declarative_field("declarative._leading"), None);
        assert_eq!(parse_declarative_field("declarative.trailing-"), None);
        assert_eq!(parse_declarative_field("declarative.trailing."), None);
        assert_eq!(parse_declarative_field("declarative..double"), None);
        assert_eq!(parse_declarative_field("declarative.UPPER"), None);
    }

    #[test]
    fn accepts_maximal_and_rejects_overlong_slugs() {
        let slug = "a".repeat(127);
        assert_eq!(
            parse_declarative_field(&format!("declarative.{slug}")),
            Some((slug, DeclarativeColumn::Verdict))
        );

        let overlong = "a".repeat(128);
        assert_eq!(
            parse_declarative_field(&format!("declarative.{overlong}")),
            None
        );
    }
}
