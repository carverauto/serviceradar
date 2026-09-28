//! Token and value splitting for the SRQL key:value syntax.
//!
//! Quoting has one rule, applied in one place. `tokenize` and `split_list` only
//! find boundaries: they track quotes (`"`, `'`, backtick) and brackets so that
//! whitespace and commas inside them do not split, and they keep the text raw,
//! backslashes included. `unquote` is the only step that decodes, and it runs
//! once per value, whether that value is a scalar or a list item. A value
//! reaching the database has therefore had exactly one level of `\x` escapes
//! removed, and a client escapes a list item the same way it escapes a scalar.

use crate::{
    error::{Result, ServiceError},
    parser::FilterValue,
};

pub(super) fn tokenize(input: &str) -> Vec<String> {
    split_outside_quotes(input, char::is_whitespace)
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
            .iter()
            .map(|item| unquote(item))
            .filter(|item| !item.is_empty())
            .collect::<Vec<_>>();
        FilterValue::List(values)
    } else {
        FilterValue::Scalar(unquote(trimmed))
    }
}

/// Decode one raw value.
///
/// Inside a quoted span a backslash is dropped and the character after it is
/// kept literally, so `\"`, `\'` and `\\` yield `"`, `'` and `\`. Outside
/// quotes a backslash is an ordinary character. Quote characters are kept,
/// except that a single outer `"` or `'` pair is removed when the value both
/// opens with that quote and ends on an unescaped closing one. Backtick quotes
/// group text but are never removed.
pub(super) fn unquote(raw: &str) -> String {
    let raw = raw.trim();
    let mut out = String::with_capacity(raw.len());
    let mut quote = None;
    let mut escape = false;
    // The quote character whose span was closed by the most recent character.
    let mut closed_by_last = None;

    for ch in raw.chars() {
        closed_by_last = None;

        if escape {
            out.push(ch);
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
                closed_by_last = Some(q);
            }
            out.push(ch);
            continue;
        }

        if matches!(ch, '"' | '\'' | '`') {
            quote = Some(ch);
        }
        out.push(ch);
    }

    if escape {
        // A backslash that ends an unterminated quote escapes nothing.
        out.push('\\');
    }

    let opened_with = raw.chars().next().filter(|ch| matches!(ch, '"' | '\''));
    match (opened_with, closed_by_last) {
        // Both delimiters are one byte, and a closing quote implies an opening
        // one before it, so `out` holds at least two bytes.
        (Some(open), Some(close)) if open == close => out[1..out.len() - 1].to_string(),
        _ => out,
    }
}

fn split_list(value: &str) -> Vec<String> {
    split_outside_quotes(value, |ch| ch == ',')
}

/// Split `input` at each character `is_separator` accepts outside quotes and
/// brackets, dropping empty segments. Segments are trimmed but otherwise raw:
/// quotes and backslash escapes are kept for `unquote` to decode.
fn split_outside_quotes(input: &str, is_separator: impl Fn(char) -> bool) -> Vec<String> {
    let mut segments = Vec::new();
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
            } else if ch == q {
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
            c if depth == 0 && is_separator(c) => {
                push_segment(&mut segments, &current);
                current.clear();
            }
            _ => current.push(ch),
        }
    }

    push_segment(&mut segments, &current);
    segments
}

fn push_segment(segments: &mut Vec<String>, segment: &str) {
    let segment = segment.trim();
    if !segment.is_empty() {
        segments.push(segment.to_string());
    }
}
