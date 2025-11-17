//! Minimal SRQL DSL parser that converts the key:value syntax into a structured AST.

use crate::{
    error::{Result, ServiceError},
    time::{parse_time_value, TimeFilterSpec},
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Entity {
    Devices,
    Events,
    Logs,
}

#[derive(Debug, Clone)]
pub struct QueryAst {
    pub entity: Entity,
    pub filters: Vec<Filter>,
    pub order: Vec<OrderClause>,
    pub limit: Option<i64>,
    pub time_filter: Option<TimeFilterSpec>,
}

#[derive(Debug, Clone)]
pub struct Filter {
    pub field: String,
    pub op: FilterOp,
    pub value: FilterValue,
}

#[derive(Debug, Clone)]
pub enum FilterOp {
    Eq,
    NotEq,
    Like,
    NotLike,
    In,
    NotIn,
}

#[derive(Debug, Clone)]
pub enum FilterValue {
    Scalar(String),
    List(Vec<String>),
}

impl FilterValue {
    pub fn as_scalar(&self) -> Result<&str> {
        match self {
            FilterValue::Scalar(v) => Ok(v.as_str()),
            FilterValue::List(_) => {
                Err(ServiceError::InvalidRequest("expected scalar value".into()))
            }
        }
    }

    pub fn as_list(&self) -> Result<&[String]> {
        match self {
            FilterValue::List(items) => Ok(items.as_slice()),
            FilterValue::Scalar(_) => {
                Err(ServiceError::InvalidRequest("expected list value".into()))
            }
        }
    }
}

#[derive(Debug, Clone)]
pub struct OrderClause {
    pub field: String,
    pub direction: OrderDirection,
}

#[derive(Debug, Clone, Copy)]
pub enum OrderDirection {
    Asc,
    Desc,
}

pub fn parse(input: &str) -> Result<QueryAst> {
    let mut entity = None;
    let mut filters = Vec::new();
    let mut order = Vec::new();
    let mut limit = None;
    let mut time_filter = None;

    for token in tokenize(input) {
        let (raw_key, raw_value) = split_token(&token)?;
        let key = raw_key.trim().to_lowercase();
        let value = parse_value(raw_value);

        match key.as_str() {
            "in" => {
                entity = Some(parse_entity(value.as_scalar()?)?);
            }
            "limit" => {
                let parsed = value
                    .as_scalar()?
                    .parse::<i64>()
                    .map_err(|_| ServiceError::InvalidRequest("invalid limit".into()))?;
                if parsed <= 0 {
                    return Err(ServiceError::InvalidRequest(
                        "limit must be a positive integer".into(),
                    ));
                }
                limit = Some(parsed);
            }
            "sort" | "order" => {
                order.extend(parse_order(value.as_scalar()?));
            }
            "time" | "timeframe" => {
                time_filter = Some(parse_time_value(value.as_scalar()?)?);
            }
            "stats" | "window" | "bounded" | "mode" => {
                // Aggregations and streaming hints are ignored for now.
                continue;
            }
            _ => {
                filters.push(build_filter(raw_key, value));
            }
        }
    }

    let entity = entity.ok_or_else(|| {
        ServiceError::InvalidRequest("queries must include an in:<entity> token".into())
    })?;

    Ok(QueryAst {
        entity,
        filters,
        order,
        limit,
        time_filter,
    })
}

fn parse_entity(raw: &str) -> Result<Entity> {
    let normalized = raw.trim_matches('"').trim_matches('\'').to_lowercase();
    match normalized.as_str() {
        "devices" | "device" | "device_inventory" => Ok(Entity::Devices),
        "events" | "activity" => Ok(Entity::Events),
        "logs" => Ok(Entity::Logs),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported entity '{other}'"
        ))),
    }
}

fn build_filter(key: &str, value: FilterValue) -> Filter {
    let mut field = key.trim();
    let mut negated = false;
    if let Some(stripped) = field.strip_prefix('!') {
        field = stripped;
        negated = true;
    }

    let op = match &value {
        FilterValue::Scalar(v) => {
            if v.contains('%') {
                if negated {
                    FilterOp::NotLike
                } else {
                    FilterOp::Like
                }
            } else if negated {
                FilterOp::NotEq
            } else {
                FilterOp::Eq
            }
        }
        FilterValue::List(_) => {
            if negated {
                FilterOp::NotIn
            } else {
                FilterOp::In
            }
        }
    };

    Filter {
        field: field.to_lowercase(),
        op,
        value,
    }
}

fn parse_order(raw: &str) -> Vec<OrderClause> {
    raw.split(',')
        .filter_map(|segment| {
            let trimmed = segment.trim();
            if trimmed.is_empty() {
                return None;
            }

            let mut parts = trimmed.splitn(3, ':');
            let field = parts.next()?.trim().to_lowercase();
            let direction = parts
                .next()
                .map(|dir| match dir.to_lowercase().as_str() {
                    "asc" => OrderDirection::Asc,
                    "desc" => OrderDirection::Desc,
                    _ => OrderDirection::Desc,
                })
                .unwrap_or(OrderDirection::Desc);

            Some(OrderClause { field, direction })
        })
        .collect()
}

fn tokenize(input: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut quote = None;
    let mut depth = 0usize;
    let mut escape = false;

    for ch in input.chars() {
        if escape {
            current.push(ch);
            escape = false;
            continue;
        }

        if let Some(q) = quote {
            if ch == '\\' {
                escape = true;
                continue;
            }
            if ch == q {
                quote = None;
            }
            current.push(ch);
            continue;
        }

        match ch {
            '"' | '\'' | '`' => {
                quote = Some(ch);
                current.push(ch);
            }
            '(' => {
                depth += 1;
                current.push(ch);
            }
            ')' => {
                depth = depth.saturating_sub(1);
                current.push(ch);
            }
            c if c.is_whitespace() && depth == 0 => {
                if !current.trim().is_empty() {
                    tokens.push(current.trim().to_string());
                }
                current.clear();
            }
            _ => current.push(ch),
        }
    }

    if !current.trim().is_empty() {
        tokens.push(current.trim().to_string());
    }

    tokens
}

fn split_token(token: &str) -> Result<(&str, &str)> {
    let mut parts = token.splitn(2, ':');
    let key = parts
        .next()
        .ok_or_else(|| ServiceError::InvalidRequest("invalid token".into()))?;
    let value = parts
        .next()
        .ok_or_else(|| ServiceError::InvalidRequest("missing ':' in token".into()))?;
    Ok((key, value))
}

fn parse_value(raw: &str) -> FilterValue {
    let trimmed = raw.trim();
    if trimmed.starts_with('(') && trimmed.ends_with(')') {
        let inner = &trimmed[1..trimmed.len().saturating_sub(1)];
        let values = split_list(inner)
            .into_iter()
            .map(|item| item.trim().trim_matches('"').trim_matches('\'').to_string())
            .filter(|item| !item.is_empty())
            .collect::<Vec<_>>();
        FilterValue::List(values)
    } else {
        FilterValue::Scalar(trimmed.trim_matches('"').trim_matches('\'').to_string())
    }
}

fn split_list(value: &str) -> Vec<String> {
    let mut items = Vec::new();
    let mut current = String::new();
    let mut quote = None;
    let mut depth = 0usize;
    let mut escape = false;

    for ch in value.chars() {
        if escape {
            current.push(ch);
            escape = false;
            continue;
        }

        if let Some(q) = quote {
            if ch == '\\' {
                escape = true;
                continue;
            }
            if ch == q {
                quote = None;
            }
            current.push(ch);
            continue;
        }

        match ch {
            '"' | '\'' | '`' => {
                quote = Some(ch);
                current.push(ch);
            }
            '(' => {
                depth += 1;
                current.push(ch);
            }
            ')' => {
                depth = depth.saturating_sub(1);
                current.push(ch);
            }
            ',' if depth == 0 => {
                items.push(current.trim().to_string());
                current.clear();
            }
            _ => current.push(ch),
        }
    }

    if !current.trim().is_empty() {
        items.push(current.trim().to_string());
    }

    items
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_basic_query() {
        let ast = parse("in:devices hostname:%cam% limit:50 sort:last_seen:desc").unwrap();
        assert_eq!(ast.limit, Some(50));
        assert_eq!(ast.order.len(), 1);
        assert_eq!(ast.filters.len(), 1);
        assert!(matches!(ast.entity, Entity::Devices));
        assert!(matches!(ast.filters[0].op, FilterOp::Like));
    }

    #[test]
    fn parses_lists() {
        let ast = parse("in:devices discovery_sources:(sweep,armis)").unwrap();
        assert_eq!(ast.filters.len(), 1);
        assert!(matches!(ast.filters[0].value, FilterValue::List(_)));
    }

    #[test]
    fn parses_time() {
        let ast = parse("in:devices time:last_7d").unwrap();
        assert!(ast.time_filter.is_some());
    }

    #[test]
    fn parses_list_values() {
        let ast = parse("in:devices discovery_sources:(sweep,armis)").unwrap();
        assert_eq!(ast.filters.len(), 1);
        match &ast.filters[0].value {
            FilterValue::List(items) => {
                assert_eq!(items.len(), 2);
                assert_eq!(items[0], "sweep");
                assert_eq!(items[1], "armis");
            }
            _ => panic!("expected list value"),
        }
    }
}
