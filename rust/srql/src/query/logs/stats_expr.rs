use crate::error::{Result, ServiceError};

#[derive(Debug, Clone)]
pub(super) enum LogsStatsExpr {
    Count { alias: String },
    GroupUniqArray { alias: String, column: &'static str },
}

impl LogsStatsExpr {
    pub(super) fn to_sql_fragment(&self) -> String {
        match self {
            LogsStatsExpr::Count { alias } => {
                format!("'{}', coalesce(COUNT(*), 0)", alias)
            }
            LogsStatsExpr::GroupUniqArray { alias, column } => {
                format!(
                    "'{}', coalesce(jsonb_agg(DISTINCT {column}) FILTER (WHERE {column} IS NOT NULL), '[]'::jsonb)",
                    alias
                )
            }
        }
    }
}

pub(super) fn parse_stats_expressions(raw: &str) -> Result<Vec<LogsStatsExpr>> {
    let segments = split_stats_segments(raw);
    let mut expressions = Vec::new();
    for segment in segments {
        if segment.trim().is_empty() {
            continue;
        }
        expressions.push(parse_stats_expr(&segment)?);
    }
    Ok(expressions)
}

fn split_stats_segments(raw: &str) -> Vec<String> {
    let mut parts = Vec::new();
    let mut current = String::new();
    let mut depth = 0usize;
    let mut in_string = None;

    for ch in raw.chars() {
        if let Some(q) = in_string {
            current.push(ch);
            if ch == q {
                in_string = None;
            }
            continue;
        }

        match ch {
            '(' => {
                depth += 1;
                current.push(ch);
            }
            ')' => {
                depth = depth.saturating_sub(1);
                current.push(ch);
            }
            '\'' | '"' | '`' => {
                in_string = Some(ch);
                current.push(ch);
            }
            ',' if depth == 0 => {
                parts.push(current.trim().to_string());
                current.clear();
            }
            _ => current.push(ch),
        }
    }

    if !current.trim().is_empty() {
        parts.push(current.trim().to_string());
    }

    parts
}

fn parse_stats_expr(segment: &str) -> Result<LogsStatsExpr> {
    let (expr_raw, alias_raw) = split_alias(segment)?;
    let alias = sanitize_alias(alias_raw)?;
    let expr = expr_raw.trim();

    if expr.eq_ignore_ascii_case("count()") {
        return Ok(LogsStatsExpr::Count { alias });
    }

    if expr.to_lowercase().starts_with("group_uniq_array(") && expr.ends_with(')') {
        let start = expr.find('(').unwrap_or(0) + 1;
        let inner = expr[start..expr.len() - 1].trim();
        let column = resolve_group_field(inner)?;
        return Ok(LogsStatsExpr::GroupUniqArray { alias, column });
    }

    Err(ServiceError::InvalidRequest(format!(
        "unsupported stats expression '{expr}'"
    )))
}

fn split_alias(segment: &str) -> Result<(String, String)> {
    let lower = segment.to_lowercase();
    if let Some(idx) = lower.rfind(" as ") {
        let expr = segment[..idx].trim().to_string();
        let alias = segment[idx + 4..]
            .trim()
            .trim_matches('"')
            .trim_matches('\'');
        return Ok((expr, alias.to_string()));
    }
    Err(ServiceError::InvalidRequest(
        "stats expressions must include an alias".into(),
    ))
}

fn sanitize_alias(raw: String) -> Result<String> {
    let alias = raw.trim().to_lowercase();
    if alias.is_empty()
        || alias
            .chars()
            .any(|ch| !ch.is_ascii_alphanumeric() && ch != '_')
    {
        return Err(ServiceError::InvalidRequest(
            "stats alias must be alphanumeric".into(),
        ));
    }
    Ok(alias)
}

fn resolve_group_field(field: &str) -> Result<&'static str> {
    match field.trim().to_lowercase().as_str() {
        "service_name" | "service" | "name" => Ok("service_name"),
        "service_version" | "version" => Ok("service_version"),
        "service_instance" | "instance" => Ok("service_instance"),
        "source" => Ok("source"),
        "scope_name" | "scope" => Ok("scope_name"),
        "scope_version" => Ok("scope_version"),
        "severity_text" | "severity" | "level" => Ok("severity_text"),
        "event_name" => Ok("event_name"),
        "trace_id" => Ok("trace_id"),
        "span_id" => Ok("span_id"),
        "body" | "message" => Ok("body"),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported field '{other}' for group_uniq_array"
        ))),
    }
}
