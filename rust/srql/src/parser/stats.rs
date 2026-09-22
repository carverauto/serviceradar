use crate::{
    error::{Result, ServiceError},
    parser::{StatsAggType, StatsAggregation, StatsSpec},
};

pub(super) const MAX_STATS_EXPR_LEN: usize = 1024;

fn split_stats_group_by(expr: &str) -> (String, Option<String>) {
    let trimmed = expr.trim();
    let lower = trimmed.to_lowercase();

    if let Some(idx) = lower.find(" by ") {
        let aggs = trimmed[..idx].trim().to_string();
        let group_by = trimmed[idx + 4..].trim().to_string();
        let group_by = if group_by.is_empty() {
            None
        } else {
            Some(group_by)
        };
        (aggs, group_by)
    } else {
        (trimmed.to_string(), None)
    }
}

pub(super) fn merge_stats_exprs(existing: &str, next: &str) -> Result<String> {
    let (existing_aggs, existing_by) = split_stats_group_by(existing);
    let (next_aggs, next_by) = split_stats_group_by(next);

    if existing_aggs.is_empty() || next_aggs.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "stats expression must include at least one aggregation".into(),
        ));
    }

    let merged_by = match (existing_by, next_by) {
        (Some(left), Some(right)) if !left.eq_ignore_ascii_case(&right) => {
            return Err(ServiceError::InvalidRequest(
                "conflicting 'by' clauses across stats expressions".into(),
            ));
        }
        (Some(left), Some(_)) => Some(left),
        (Some(left), None) => Some(left),
        (None, Some(right)) => Some(right),
        (None, None) => None,
    };

    let merged = format!("{existing_aggs}, {next_aggs}");
    Ok(match merged_by {
        Some(group_by) => format!("{merged} by {group_by}"),
        None => merged,
    })
}

/// Parse a stats expression like "count() as total" or "sum(field) as total, avg(field) as average"
pub(super) fn parse_stats_expr(raw: &str) -> StatsSpec {
    let raw = raw.trim().trim_matches('"').trim_matches('\'');
    let (agg_expr, _group_by) = split_stats_group_by(raw);
    let aggregations = split_top_level_commas(&agg_expr)
        .into_iter()
        .filter_map(|part| parse_single_stats_agg(part.trim()))
        .collect();

    StatsSpec {
        raw: raw.to_string(),
        aggregations,
    }
}

/// Parse a single stats aggregation like "count() as total" or "sum(field) as total"
fn parse_single_stats_agg(expr: &str) -> Option<StatsAggregation> {
    let expr = expr.trim().to_lowercase();

    // Pattern: func() as alias or func(field) as alias
    // Split on " as " to get function part and alias
    let (func_part, alias) = {
        let idx = expr.find(" as ")?;
        let (f, a) = expr.split_at(idx);
        (f.trim(), a[4..].trim()) // Skip " as "
    };

    if alias.is_empty() {
        return None;
    }

    // Parse the function: count(), sum(field), avg(field), min(field), max(field)
    if let Some(inner) = func_part
        .strip_prefix("count(")
        .and_then(|s| s.strip_suffix(')'))
    {
        let _ = inner;
        return Some(StatsAggregation {
            agg_type: StatsAggType::Count,
            field: None,
            field2: None,
            alias: alias.to_string(),
        });
    }

    for (prefix, agg_type) in [
        ("sum(", StatsAggType::Sum),
        ("avg(", StatsAggType::Avg),
        ("min(", StatsAggType::Min),
        ("max(", StatsAggType::Max),
    ] {
        if let Some(inner) = func_part
            .strip_prefix(prefix)
            .and_then(|s| s.strip_suffix(')'))
        {
            let field = inner.trim();
            if !field.is_empty() {
                return Some(StatsAggregation {
                    agg_type,
                    field: Some(field.to_string()),
                    field2: None,
                    alias: alias.to_string(),
                });
            }
        }
    }

    // Two-argument aggregations. `strip_prefix` is anchored, so "wavg(" does not
    // collide with the "avg(" arm above.
    for (prefix, agg_type) in [
        ("loss_ratio(", StatsAggType::LossRatio),
        ("wavg(", StatsAggType::Wavg),
    ] {
        if let Some((first, second)) = func_part
            .strip_prefix(prefix)
            .and_then(|s| s.strip_suffix(')'))
            .and_then(split_two_args)
        {
            return Some(StatsAggregation {
                agg_type,
                field: Some(first),
                field2: Some(second),
                alias: alias.to_string(),
            });
        }
    }

    None
}

/// Split on commas that are not inside parentheses.
///
/// A two-argument aggregation contains a comma of its own, so splitting a
/// projection on every comma tears `loss_ratio(sent, received)` into two
/// unparseable halves — which `filter_map` would then silently discard, leaving
/// an aggregation-free stats spec.
pub(crate) fn split_top_level_commas(s: &str) -> Vec<&str> {
    let mut parts = Vec::new();
    let mut depth = 0usize;
    let mut start = 0usize;

    for (idx, ch) in s.char_indices() {
        match ch {
            '(' => depth += 1,
            ')' => depth = depth.saturating_sub(1),
            ',' if depth == 0 => {
                parts.push(&s[start..idx]);
                start = idx + 1;
            }
            _ => {}
        }
    }
    parts.push(&s[start..]);
    parts
}

/// Split the inner text of a two-argument aggregation into its operands.
///
/// Returns None for any arity other than two, or for an empty operand, so a
/// malformed call does not silently become a one-argument aggregation. Callers
/// that need an error rather than a skip validate the raw expression themselves;
/// see the entity stats builders.
fn split_two_args(inner: &str) -> Option<(String, String)> {
    let mut parts = inner.split(',');
    let first = parts.next()?.trim();
    let second = parts.next()?.trim();

    if parts.next().is_some() || first.is_empty() || second.is_empty() {
        return None;
    }

    Some((first.to_string(), second.to_string()))
}
