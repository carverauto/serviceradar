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

/// Which column of a composite check result the filter compares.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(in crate::query::devices) enum CompositeColumn {
    Verdict,
    Status,
}

impl CompositeColumn {
    fn column(self) -> &'static str {
        match self {
            CompositeColumn::Verdict => "r.verdict",
            CompositeColumn::Status => "r.status",
        }
    }
}

/// Splits `composite.<slug>` / `composite.<slug>.status` into its parts.
///
/// Returns `None` for anything that is not a well-formed composite field, which
/// the caller turns into a named query error. Slug shape is enforced here rather
/// than at the SQL boundary: the slug is bound as a parameter, so this is not
/// the injection defence, it is what stops a typo becoming a filter that
/// silently matches nothing.
pub(in crate::query::devices) fn parse_composite_field(
    field: &str,
) -> Option<(String, CompositeColumn)> {
    let rest = field.strip_prefix("composite.")?;

    let (slug, column) = match rest.rsplit_once('.') {
        Some((slug, "status")) => (slug, CompositeColumn::Status),
        // Any other suffix would otherwise be absorbed into the slug and match
        // nothing; reject it so the caller learns the field name is wrong.
        Some(_) => return None,
        None => (rest, CompositeColumn::Verdict),
    };

    if is_valid_slug(slug) {
        Some((slug.to_string(), column))
    } else {
        None
    }
}

fn is_valid_slug(slug: &str) -> bool {
    !slug.is_empty()
        && slug.len() <= 64
        && !slug.starts_with('-')
        && !slug.ends_with('-')
        && slug
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

/// Compiles a composite verdict filter into a correlated `EXISTS`.
///
/// No JOIN: `DeviceQuery` is boxed over `ocsf_devices` alone, so joining would
/// change its type across the whole module. Table names are unqualified because
/// the connection `search_path` supplies the schema, matching
/// `apply_agent_availability_filter`.
///
/// An unknown slug joins no check row, so the predicate matches nothing and the
/// filter returns zero devices. It cannot degrade into "match everything".
/// Reporting the unknown slug as a named error happens in the Elixir layer,
/// which has a database connection; this translator does not.
///
/// The binds here are `Text` (slug) then `Array<Text>` (values), in that order.
/// `collect_filter_params` must push exactly those, in the same order.
pub(in crate::query::devices) fn apply_composite_verdict_filter<'a>(
    query: DeviceQuery<'a>,
    filter: &Filter,
    slug: &str,
    column: CompositeColumn,
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
                "composite check filters only support equality and list membership".into(),
            ));
        }
    };

    let expr = sql::<Bool>(
        "EXISTS (SELECT 1 FROM device_composite_check_results r \
         JOIN composite_checks c ON c.id = r.check_id \
         WHERE r.device_uid = ocsf_devices.uid AND c.slug = ",
    )
    .bind::<Text, _>(slug.to_string())
    .sql(&format!(" AND {} = ANY(", column.column()))
    .bind::<Array<Text>, _>(values)
    .sql("))");

    // `NOT EXISTS` also matches devices with no result row for this check. That
    // is the intended reading of "does not hold that verdict" -- a device
    // outside the check's scope does not hold it either.
    Ok(if negated {
        query.filter(not(expr))
    } else {
        query.filter(expr)
    })
}

/// Shared by the params collector so both sides derive values identically.
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
            parse_composite_field("composite.pci-isolation"),
            Some(("pci-isolation".to_string(), CompositeColumn::Verdict))
        );
    }

    #[test]
    fn parses_a_status_field() {
        assert_eq!(
            parse_composite_field("composite.pci-isolation.status"),
            Some(("pci-isolation".to_string(), CompositeColumn::Status))
        );
    }

    #[test]
    fn rejects_a_bare_prefix() {
        assert_eq!(parse_composite_field("composite."), None);
        assert_eq!(parse_composite_field("composite"), None);
    }

    #[test]
    fn a_check_slugged_status_is_addressable() {
        // `composite.status` has no second dot, so "status" is the slug, not a
        // column suffix. Reading it as a suffix would make a legitimately
        // slugged check unaddressable.
        assert_eq!(
            parse_composite_field("composite.status"),
            Some(("status".to_string(), CompositeColumn::Verdict))
        );
        assert_eq!(
            parse_composite_field("composite.status.status"),
            Some(("status".to_string(), CompositeColumn::Status))
        );
    }

    #[test]
    fn rejects_an_unknown_suffix() {
        assert_eq!(
            parse_composite_field("composite.pci-isolation.verdict"),
            None
        );
        assert_eq!(parse_composite_field("composite.a.b.c"), None);
    }

    #[test]
    fn rejects_a_slug_that_is_not_slug_shaped() {
        assert_eq!(parse_composite_field("composite.Bad Slug"), None);
        assert_eq!(parse_composite_field("composite.a';DROP TABLE x;--"), None);
        assert_eq!(parse_composite_field("composite.-leading"), None);
        assert_eq!(parse_composite_field("composite.trailing-"), None);
        assert_eq!(parse_composite_field("composite.UPPER"), None);
    }

    #[test]
    fn accepts_a_maximal_slug() {
        let slug = "a".repeat(64);
        assert_eq!(
            parse_composite_field(&format!("composite.{slug}")),
            Some((slug, CompositeColumn::Verdict))
        );
    }

    #[test]
    fn rejects_an_overlong_slug() {
        let slug = "a".repeat(65);
        assert_eq!(parse_composite_field(&format!("composite.{slug}")), None);
    }

    #[test]
    fn a_slug_named_status_still_parses_as_a_verdict_field() {
        // `composite.status` is a bare prefix + "status" with no slug, so it is
        // rejected above. But a check legitimately slugged "status-checks" must
        // not be mistaken for a status suffix.
        assert_eq!(
            parse_composite_field("composite.status-checks"),
            Some(("status-checks".to_string(), CompositeColumn::Verdict))
        );
        assert_eq!(
            parse_composite_field("composite.status-checks.status"),
            Some(("status-checks".to_string(), CompositeColumn::Status))
        );
    }
}
