use crate::{
    error::{Result, ServiceError},
    parser::FilterValue,
};

pub(super) fn tokenize(input: &str) -> Vec<String> {
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
            '(' | '[' => {
                depth += 1;
                current.push(ch);
            }
            ')' | ']' => {
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

pub(super) fn split_token(token: &str) -> Result<(&str, &str)> {
    let mut parts = token.splitn(2, ':');
    let key = parts
        .next()
        .ok_or_else(|| ServiceError::InvalidRequest("invalid token".into()))?;
    let value = parts
        .next()
        .ok_or_else(|| ServiceError::InvalidRequest("missing ':' in token".into()))?;
    Ok((key, value))
}

pub(super) fn parse_value(raw: &str) -> FilterValue {
    let trimmed = raw.trim();
    let list_bounds = [('(', ')'), ('[', ']')];

    if let Some((open, close)) = list_bounds
        .iter()
        .copied()
        .find(|(open, close)| trimmed.starts_with(*open) && trimmed.ends_with(*close))
    {
        let inner = &trimmed[open.len_utf8()..trimmed.len().saturating_sub(close.len_utf8())];
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
            '(' | '[' => {
                depth += 1;
                current.push(ch);
            }
            ')' | ']' => {
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
