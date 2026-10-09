//! Shared SQL placeholder rewriting for SRQL queries.
//!
//! Replaces positional parameter placeholders (such as `?`) with native
//! PostgreSQL `$1, $2, ...` numbered parameters while skipping string literals
//! (`'...'`), doubled-quote escapes (`''`), dollar-quoted literals
//! (`$$...$$` or `$tag$...$tag$`), double-quoted identifiers, and comments.
//!
//! This prevents the 42P18 bind-shift bug (GH #3509) where a question mark inside
//! a string literal (e.g. in a regex pattern `~ '^[0-9]+(\.[0-9]+)?$'`) was mistakenly
//! rewritten as a parameter bind.

/// Target parameter placeholder style for rewriting.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlaceholderStyle {
    /// PostgreSQL numbered positional parameters: `$1, $2, ...`
    /// starting at `start_index`.
    NumberedDollar { start_index: usize },
    /// Question mark positional parameters: `?`.
    QuestionMark,
}

/// Rewrites question-mark placeholders (`?`) outside string literals, comments,
/// and dollar-quoted blocks to PostgreSQL numbered parameters (`$1, $2, ...`),
/// starting at parameter index 1.
pub fn rewrite_placeholders(sql: &str) -> String {
    rewrite_placeholders_from(sql, 1)
}

/// Rewrites question-mark placeholders (`?`) outside string literals to PostgreSQL
/// numbered parameters starting at `start_index`.
pub fn rewrite_placeholders_from(sql: &str, start_index: usize) -> String {
    rewrite_placeholders_with_style(sql, PlaceholderStyle::NumberedDollar { start_index })
}

/// Rewrites PostgreSQL numbered parameters (`$1, $2, ...`) outside string literals to question marks (`?`).
pub fn rewrite_numbered_to_question_marks(sql: &str) -> String {
    rewrite_placeholders_with_style(sql, PlaceholderStyle::QuestionMark)
}

/// Rewrites SQL placeholders according to the specified `PlaceholderStyle`.
pub fn rewrite_placeholders_with_style(sql: &str, style: PlaceholderStyle) -> String {
    let bytes = sql.as_bytes();
    let mut result = String::with_capacity(sql.len() + 16);
    let mut i = 0usize;
    let mut current_index = match style {
        PlaceholderStyle::NumberedDollar { start_index } => start_index,
        PlaceholderStyle::QuestionMark => 0,
    };

    while i < bytes.len() {
        match bytes[i] {
            // Single-quoted string literal: '...' with '' quote-doubling escape
            b'\'' => {
                let start = i;
                let is_escape_string = start > 0 && matches!(bytes[start - 1], b'e' | b'E');
                i += 1;
                while i < bytes.len() {
                    if bytes[i] == b'\'' {
                        if bytes.get(i + 1) == Some(&b'\'') {
                            // Doubled quote inside literal ('')
                            i += 2;
                        } else {
                            // End of literal
                            i += 1;
                            break;
                        }
                    } else if is_escape_string && bytes[i] == b'\\' {
                        // C-style escape string E'...' allows \'
                        i = (i + 2).min(bytes.len());
                    } else {
                        i += 1;
                    }
                }
                result.push_str(&sql[start..i]);
            }

            // Dollar-quoted string literal: $$...$$ or $tag$...$tag$
            b'$' if is_dollar_quote_start(bytes, i) => {
                let tag = parse_dollar_quote_tag(bytes, i).unwrap();
                let start = i;
                i += tag.len();
                // Find closing delimiter matching tag
                if let Some(rel_end) = find_subslice(&bytes[i..], tag) {
                    i += rel_end + tag.len();
                    result.push_str(&sql[start..i]);
                } else {
                    // Unclosed dollar quote: copy tag and continue
                    result.push_str(&sql[start..i]);
                }
            }

            // Double-quoted identifier: "..." with "" escape
            b'"' => {
                let start = i;
                i += 1;
                while i < bytes.len() {
                    if bytes[i] == b'"' {
                        if bytes.get(i + 1) == Some(&b'"') {
                            i += 2;
                        } else {
                            i += 1;
                            break;
                        }
                    } else {
                        i += 1;
                    }
                }
                result.push_str(&sql[start..i]);
            }

            // Line comment: -- ...
            b'-' if bytes.get(i + 1) == Some(&b'-') => {
                let start = i;
                i += 2;
                while i < bytes.len() && bytes[i] != b'\n' {
                    i += 1;
                }
                result.push_str(&sql[start..i]);
            }

            // Block comment: /* ... */
            b'/' if bytes.get(i + 1) == Some(&b'*') => {
                let start = i;
                i += 2;
                let mut depth = 1usize;
                while i + 1 < bytes.len() {
                    if bytes[i] == b'/' && bytes[i + 1] == b'*' {
                        depth += 1;
                        i += 2;
                    } else if bytes[i] == b'*' && bytes[i + 1] == b'/' {
                        depth -= 1;
                        i += 2;
                        if depth == 0 {
                            break;
                        }
                    } else {
                        i += 1;
                    }
                }
                if depth > 0 && i < bytes.len() {
                    i += 1;
                }
                result.push_str(&sql[start..i]);
            }

            // Question mark placeholder
            b'?' => match style {
                PlaceholderStyle::NumberedDollar { .. } => {
                    result.push('$');
                    result.push_str(&current_index.to_string());
                    current_index += 1;
                    i += 1;
                }
                PlaceholderStyle::QuestionMark => {
                    result.push('?');
                    i += 1;
                }
            },

            // Numbered dollar parameter: $1, $2, ...
            b'$' if bytes.get(i + 1).is_some_and(u8::is_ascii_digit) => {
                match style {
                    PlaceholderStyle::QuestionMark => {
                        i += 1;
                        while i < bytes.len() && bytes[i].is_ascii_digit() {
                            i += 1;
                        }
                        result.push('?');
                    }
                    PlaceholderStyle::NumberedDollar { .. } => {
                        // Preserved as-is
                        let start = i;
                        i += 1;
                        while i < bytes.len() && bytes[i].is_ascii_digit() {
                            i += 1;
                        }
                        result.push_str(&sql[start..i]);
                    }
                }
            }

            // Other characters (including UTF-8 sequences)
            _ => {
                let start = i;
                i += 1;
                while i < bytes.len()
                    && !matches!(bytes[i], b'\'' | b'$' | b'"' | b'-' | b'/' | b'?')
                {
                    i += 1;
                }
                result.push_str(&sql[start..i]);
            }
        }
    }

    result
}

fn is_dollar_quote_start(bytes: &[u8], i: usize) -> bool {
    parse_dollar_quote_tag(bytes, i).is_some()
}

fn parse_dollar_quote_tag(bytes: &[u8], start: usize) -> Option<&[u8]> {
    if bytes.get(start) != Some(&b'$') {
        return None;
    }
    // Tag can be $$ (empty tag)
    if bytes.get(start + 1) == Some(&b'$') {
        return Some(&bytes[start..=start + 1]);
    }
    // Tag must start with an ASCII letter or underscore
    let first = bytes.get(start + 1)?;
    if !first.is_ascii_alphabetic() && *first != b'_' {
        return None;
    }
    let mut i = start + 2;
    while i < bytes.len() {
        if bytes[i] == b'$' {
            return Some(&bytes[start..=i]);
        }
        if !bytes[i].is_ascii_alphanumeric() && bytes[i] != b'_' {
            return None;
        }
        i += 1;
    }
    None
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rewrite_placeholders_numbers_binds_outside_literals() {
        assert_eq!(
            rewrite_placeholders("SELECT 1 WHERE a >= ? AND b <= ? LIMIT ? OFFSET ?"),
            "SELECT 1 WHERE a >= $1 AND b <= $2 LIMIT $3 OFFSET $4"
        );
    }

    #[test]
    fn rewrite_placeholders_skips_question_marks_inside_string_literals() {
        let sql = r"SELECT x ~ '^[0-9]+(\.[0-9]+)?$' AS ok FROM t WHERE a = ? AND b = ?";
        assert_eq!(
            rewrite_placeholders(sql),
            r"SELECT x ~ '^[0-9]+(\.[0-9]+)?$' AS ok FROM t WHERE a = $1 AND b = $2"
        );
    }

    #[test]
    fn rewrite_placeholders_handles_escaped_quote_doubling() {
        let sql = "SELECT 'what''s this?' AS q WHERE a = ? AND b = 'x' AND c = ?";
        assert_eq!(
            rewrite_placeholders(sql),
            "SELECT 'what''s this?' AS q WHERE a = $1 AND b = 'x' AND c = $2"
        );
    }

    #[test]
    fn rewrite_placeholders_handles_dollar_quoted_literals() {
        let sql = "SELECT ag_catalog.cypher('graph', $srql$MATCH (n) WHERE n.name = '?'$srql$) LIMIT ? OFFSET ?";
        assert_eq!(
            rewrite_placeholders(sql),
            "SELECT ag_catalog.cypher('graph', $srql$MATCH (n) WHERE n.name = '?'$srql$) LIMIT $1 OFFSET $2"
        );
    }

    #[test]
    fn rewrite_placeholders_supports_offset_start_index() {
        let sql = "SELECT 1 WHERE a >= ? AND b <= ?";
        assert_eq!(
            rewrite_placeholders_from(sql, 5),
            "SELECT 1 WHERE a >= $5 AND b <= $6"
        );
    }

    #[test]
    fn rewrite_numbered_to_question_marks_converts_placeholders() {
        let sql = "SELECT * FROM t WHERE a = $1 AND b = $2 AND c = 'val $3'";
        assert_eq!(
            rewrite_numbered_to_question_marks(sql),
            "SELECT * FROM t WHERE a = ? AND b = ? AND c = 'val $3'"
        );
    }

    #[test]
    fn rewrite_placeholders_ignores_comments_and_double_quotes() {
        let sql =
            "SELECT \"col?name\" -- Is this ?\nFROM t WHERE a = ? /* block ? comment */ AND b = ?";
        assert_eq!(
            rewrite_placeholders(sql),
            "SELECT \"col?name\" -- Is this ?\nFROM t WHERE a = $1 /* block ? comment */ AND b = $2"
        );
    }
}
