//! Extracts SRQL chart-query templates from Elixir source (`coverage` adds JSON dashboards and
//! the browser bundle, whose literals it groups with the same rules).
//!
//! This is a lexer, not a parser, and it is honest about what that buys. It reads string
//! literals and sigils (so a comment or a `bucket: bucket` keyword pair is never mistaken for
//! SRQL), replaces `#{...}` interpolations with a placeholder, and groups the literals of one
//! function into templates:
//!
//!   * a literal containing `in:<entity>` ROOTS a template; clause literals after it in the
//!     same function join that template (the token-list style, `["in:snmp_metrics", ...,
//!     "agg:rate"]`);
//!   * a clause key seen twice forks a second template off the same root (one base query
//!     charted two ways);
//!   * clause literals with no root in their function are FRAGMENTS (`"#{base} bucket:5m
//!     agg:sum"`), attributed by `coverage` to the warehouse entities their file names; one
//!     whose base really names another entity is a reasoned `scan_exclusions` entry.
//!
//! What it cannot see: a clause assembled from pieces that are not SRQL text on their own --
//! `maybe_add_token(tokens, "series", field)` yields no `series:` literal. Such callers have to
//! be inventoried by hand; the scan proves the floor, not the ceiling.

use crate::shape::{PLACEHOLDER, Shape, Token, shape_of_tokens, tokenize};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Literal {
    pub line: usize,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Template {
    pub file: String,
    pub line: usize,
    /// The literal text the template was assembled from, for the failure message.
    pub text: String,
    pub shape: Shape,
}

/// Every string literal in an Elixir source file, grouped by the function that contains it.
pub fn literals_by_function(source: &str) -> Vec<Vec<Literal>> {
    let mut windows: Vec<Vec<Literal>> = vec![Vec::new()];
    let chars: Vec<char> = source.chars().collect();
    let mut index = 0;
    let mut line = 1;
    let mut line_start = true;

    while index < chars.len() {
        let ch = chars[index];
        if line_start && starts_function(&chars, index) {
            windows.push(Vec::new());
        }
        if ch == '\n' {
            line += 1;
            line_start = true;
            index += 1;
            continue;
        }
        if !ch.is_whitespace() {
            line_start = false;
        }
        match ch {
            '#' => {
                while index < chars.len() && chars[index] != '\n' {
                    index += 1;
                }
            }
            // `?"` is a character literal, not the start of a string.
            '?' if index + 1 < chars.len() && !is_ident(chars.get(index.wrapping_sub(1))) => {
                index += if chars[index + 1] == '\\' { 3 } else { 2 };
            }
            '"' => {
                let documentation = is_documentation(&chars, index);
                let start_line = line;
                let (text, next, newlines) = read_quoted(&chars, index, true);
                if !documentation {
                    push(&mut windows, start_line, text);
                }
                line += newlines;
                index = next;
            }
            '~' if index + 2 < chars.len() && chars[index + 1].is_ascii_alphabetic() => {
                let sigil = chars[index + 1];
                let mut open_at = index + 2;
                // Multi-letter uppercase sigils (`~HEEX`) are legal; skip the rest of the name.
                while open_at < chars.len() && chars[open_at].is_ascii_uppercase() {
                    open_at += 1;
                }
                let start_line = line;
                match read_sigil(&chars, open_at, sigil.is_ascii_lowercase()) {
                    Some((text, next, newlines)) => {
                        // Regexes mention `stats:` to PARSE queries, never to send one.
                        if !matches!(sigil, 'r' | 'R') {
                            push(&mut windows, start_line, text);
                        }
                        line += newlines;
                        index = next;
                    }
                    None => index += 1,
                }
            }
            _ => index += 1,
        }
    }
    windows.retain(|window| !window.is_empty());
    windows
}

fn push(windows: &mut [Vec<Literal>], line: usize, text: String) {
    if let Some(window) = windows.last_mut() {
        window.push(Literal { line, text });
    }
}

fn is_ident(ch: Option<&char>) -> bool {
    ch.is_some_and(|c| c.is_alphanumeric() || *c == '_')
}

fn starts_function(chars: &[char], index: usize) -> bool {
    let mut at = index;
    while at < chars.len() && (chars[at] == ' ' || chars[at] == '\t') {
        at += 1;
    }
    ["defp ", "def ", "defmacro ", "defmacrop "]
        .iter()
        .any(|keyword| {
            chars[at..]
                .iter()
                .take(keyword.len())
                .copied()
                .eq(keyword.chars())
        })
}

fn is_documentation(chars: &[char], quote_at: usize) -> bool {
    let mut at = quote_at;
    while at > 0 && chars[at - 1].is_whitespace() && chars[at - 1] != '\n' {
        at -= 1;
    }
    let head: String = chars[at.saturating_sub(12)..at].iter().collect();
    ["@doc", "@moduledoc", "@typedoc", "@shortdoc"]
        .iter()
        .any(|attribute| head.ends_with(attribute))
}

/// Reads a `"..."` or `"""..."""` literal starting at `start`. Returns the text with
/// interpolations replaced, the index after the closing quote, and the newlines consumed.
fn read_quoted(chars: &[char], start: usize, interpolate: bool) -> (String, usize, usize) {
    let heredoc = chars[start..].iter().take(3).all(|c| *c == '"') && chars.len() >= start + 3;
    let open = if heredoc { 3 } else { 1 };
    read_until(chars, start + open, interpolate, |at| {
        if heredoc {
            chars[at..].iter().take(3).filter(|c| **c == '"').count() == 3
        } else {
            chars[at] == '"'
        }
    })
    .map(|(text, end, newlines)| (text, end + open, newlines))
    .unwrap_or((String::new(), chars.len(), 0))
}

fn read_sigil(chars: &[char], open_at: usize, interpolate: bool) -> Option<(String, usize, usize)> {
    let open = *chars.get(open_at)?;
    if open == '"' {
        return Some(read_quoted(chars, open_at, interpolate));
    }
    let close = match open {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        '<' => '>',
        '|' | '/' | '\'' => open,
        _ => return None,
    };
    let mut depth = 0usize;
    let mut at = open_at + 1;
    let mut end = None;
    while at < chars.len() {
        let c = chars[at];
        if c == '\\' {
            at += 2;
            continue;
        }
        // `~s|#{a |> b}|`: a delimiter inside an interpolation does not close the sigil.
        if interpolate && c == '#' && chars.get(at + 1) == Some(&'{') {
            let mut braces = 0usize;
            while at < chars.len() {
                match chars[at] {
                    '{' => braces += 1,
                    '}' => {
                        braces -= 1;
                        if braces == 0 {
                            break;
                        }
                    }
                    _ => {}
                }
                at += 1;
            }
            at += 1;
            continue;
        }
        if c == open && open != close {
            depth += 1;
        } else if c == close {
            if depth == 0 {
                end = Some(at);
                break;
            }
            depth -= 1;
        }
        at += 1;
    }
    let end = end?;
    let (text, _, newlines) = read_until(&chars[..end], open_at + 1, interpolate, |_| false)
        .unwrap_or((String::new(), end, 0));
    Some((text, end + 1, newlines))
}

/// Reads characters until `is_end`, or to the end of `chars` when it never fires.
fn read_until(
    chars: &[char],
    start: usize,
    interpolate: bool,
    is_end: impl Fn(usize) -> bool,
) -> Option<(String, usize, usize)> {
    let mut text = String::new();
    let mut newlines = 0;
    let mut at = start;
    while at < chars.len() {
        if is_end(at) {
            return Some((text, at, newlines));
        }
        let c = chars[at];
        if c == '\\' && at + 1 < chars.len() {
            // `\"` inside a literal is a quote in the SRQL text; other escapes are dropped.
            if chars[at + 1] == '"' {
                text.push('"');
            }
            at += 2;
            continue;
        }
        if interpolate && c == '#' && chars.get(at + 1) == Some(&'{') {
            let mut depth = 0usize;
            while at < chars.len() {
                match chars[at] {
                    '{' => depth += 1,
                    '}' => {
                        depth -= 1;
                        if depth == 0 {
                            break;
                        }
                    }
                    '\n' => newlines += 1,
                    _ => {}
                }
                at += 1;
            }
            text.push_str(PLACEHOLDER);
            at += 1;
            continue;
        }
        if c == '\n' {
            newlines += 1;
        }
        text.push(c);
        at += 1;
    }
    Some((text, at, newlines))
}

/// Groups one file's literals into chart templates. Non-chart templates (row listings, presence
/// probes) are dropped: the parity inventory is about aggregate translations.
pub fn templates_in(file: &str, source: &str) -> Vec<Template> {
    templates_from_literal_windows(file, literals_by_function(source))
}

/// The grouping rules above, over literal windows from any lexer (Elixir, JSON, JavaScript).
pub fn templates_from_literal_windows(file: &str, windows: Vec<Vec<Literal>>) -> Vec<Template> {
    let mut templates = Vec::new();
    for window in windows {
        let mut current: Option<(usize, String, Option<String>, Vec<Token>)> = None;
        for literal in window {
            let tokens = tokenize(&literal.text);
            let root = tokens
                .iter()
                .find(|token| token.key == "in")
                .map(|token| token.value.clone());
            let clause_tokens: Vec<Token> = tokens
                .into_iter()
                .filter(|token| token.key != "in" && is_shape_key(&token.key))
                .collect();
            if root.is_none() && clause_tokens.is_empty() {
                continue;
            }
            let repeats = current.as_ref().is_some_and(|(_, _, _, existing)| {
                // `stats` and `bucket` are alternative query kinds, so one after the other is
                // a second query just as surely as the same key twice.
                clause_tokens.iter().any(|token| {
                    existing.iter().any(|seen| {
                        seen.key == token.key
                            || (token.key == "stats" && seen.key == "bucket")
                            || (token.key == "bucket" && seen.key == "stats")
                    })
                })
            });
            if root.is_some() || repeats || current.is_none() {
                let inherited = if root.is_some() {
                    root
                } else {
                    current
                        .as_ref()
                        .and_then(|(_, _, entity, _)| entity.clone())
                };
                flush(file, current.take(), &mut templates);
                current = Some((literal.line, literal.text.clone(), inherited, clause_tokens));
            } else if let Some((_, text, _, existing)) = current.as_mut() {
                text.push(' ');
                text.push_str(&literal.text);
                existing.extend(clause_tokens);
            }
        }
        flush(file, current.take(), &mut templates);
    }
    templates
}

fn is_shape_key(key: &str) -> bool {
    crate::shape::CLAUSE_KEYS.contains(&key) || crate::shape::MODIFIER_KEYS.contains(&key)
}

fn flush(
    file: &str,
    template: Option<(usize, String, Option<String>, Vec<Token>)>,
    out: &mut Vec<Template>,
) {
    let Some((line, text, entity, tokens)) = template else {
        return;
    };
    let mut shape = shape_of_tokens(&tokens);
    shape.entity = entity.filter(|entity| !entity.contains(PLACEHOLDER));
    if shape.is_chart() {
        out.push(Template {
            file: file.to_string(),
            line,
            text,
            shape,
        });
    }
}

/// Every `in:<entity>` a file names in a string literal, chart query or not. A fragment with no
/// root of its own is attributed to these.
pub fn entities_named_in(source: &str) -> Vec<String> {
    let mut entities: Vec<String> = literals_by_function(source)
        .into_iter()
        .flatten()
        .flat_map(|literal| tokenize(&literal.text))
        .filter(|token| token.key == "in" && !token.value.contains(PLACEHOLDER))
        .map(|token| token.value)
        .collect();
    entities.sort();
    entities.dedup();
    entities
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shapes(source: &str) -> Vec<String> {
        templates_in("x.ex", source)
            .into_iter()
            .map(|template| template.shape.describe())
            .collect()
    }

    #[test]
    fn token_list_style_is_one_template() {
        let source = r##"
  def query(device_uid, bucket) do
    [
      "in:snmp_metrics",
      ~s(device_id:"#{escape_value(device_uid)}"),
      "bucket:#{bucket}",
      "agg:rate",
      "series:metric_name",
      "limit:#{limit}"
    ]
    |> Enum.join(" ")
  end
"##;
        assert_eq!(
            shapes(source),
            vec!["in:snmp_metrics agg=rate bucket=* series=metric_name +limit"]
        );
    }

    #[test]
    fn a_repeated_clause_forks_a_second_template_off_the_same_root() {
        let source = r##"
  defp charts(uid) do
    base = "in:snmp_metrics device_id:\"#{uid}\" time:last_1h"
    a = Enum.join([base, "bucket:5m", "agg:rate", "series:metric_name"], " ")
    b = Enum.join([base, "bucket:5m", "agg:avg", "series:metric_name"], " ")
  end
"##;
        assert_eq!(
            shapes(source),
            vec![
                "in:snmp_metrics agg=rate bucket=* series=metric_name",
                "in:snmp_metrics agg=avg bucket=* series=metric_name",
            ]
        );
    }

    #[test]
    fn a_fragment_has_no_entity_and_comments_docs_and_keywords_are_ignored() {
        let source = r##"
  @doc "Builds `in:flows bucket:5m agg:sum`."
  def chart(base, bucket) do
    # in:flows bucket:1h agg:max
    opts = [bucket: bucket, agg: "sum"]
    "#{base} bucket:#{bucket} agg:sum value_field:bytes_total"
  end
"##;
        assert_eq!(
            shapes(source),
            vec!["in:<entity from caller> agg=sum bucket=* value_field=bytes_total"]
        );
    }

    #[test]
    fn row_listings_and_regexes_are_not_chart_templates() {
        let source = r##"
  def recent, do: "in:flows time:last_1h sort:time:desc limit:100"
  def strip(q), do: String.replace(q, ~r/(^|\s)stats:"[^"]*"/i, "")
"##;
        assert!(shapes(source).is_empty());
        assert_eq!(entities_named_in(source), vec!["flows"]);
    }

    #[test]
    fn pipe_sigils_with_quoted_stats_are_read() {
        let source = r##"
  def top(base, limit) do
    ~s|#{base} stats:"sum(bytes_total) as total_bytes by src_endpoint_ip" sort:total_bytes:desc limit:#{limit}|
  end
"##;
        assert_eq!(
            shapes(source),
            vec!["in:<entity from caller> stats=sum(bytes_total)|by:src_endpoint_ip +limit +sort"]
        );
    }
}
