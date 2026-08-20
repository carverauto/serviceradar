//! Flattens protobuf text format to `path=value` pairs.
//!
//! Needed because the two artifacts being compared are TEXT, not messages: the committed
//! instance carries comments and blank lines that no encoder emits, and neither prost nor
//! Elixir's `:protobuf` can parse text format, so a real decoder is not an option here.
//!
//! Unrecognised syntax is an error rather than a skipped line. A flattener that silently
//! ignores what it cannot read would report two files as equal because it read neither.

/// One leaf field: its full dotted path and its value exactly as written.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct Pair {
    pub path: String,
    pub value: String,
}

#[derive(Debug, PartialEq, Eq)]
pub struct TextError {
    pub line: usize,
    pub detail: String,
}

impl std::fmt::Display for TextError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "line {}: {}", self.line, self.detail)
    }
}

/// Truncates at the first `#` that is not inside a quoted string.
///
/// Quote-aware because a value may legitimately contain `#`, and because the alternative --
/// splitting on the first `#` anywhere -- silently corrupts such a value into a shorter one
/// that still parses.
fn strip_comment(line: &str) -> &str {
    let mut in_string = false;
    let mut escaped = false;
    for (i, c) in line.char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        match c {
            '\\' if in_string => escaped = true,
            '"' => in_string = !in_string,
            '#' if !in_string => return &line[..i],
            _ => {}
        }
    }
    line
}

fn is_identifier(s: &str) -> bool {
    !s.is_empty()
        && s.chars().next().is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// Every leaf field in `src`, in file order. Repeated fields yield one pair each.
pub fn flatten(src: &str) -> Result<Vec<Pair>, TextError> {
    let mut stack: Vec<&str> = Vec::new();
    let mut out = Vec::new();

    for (i, raw) in src.lines().enumerate() {
        let line = strip_comment(raw).trim();
        let n = i + 1;
        if line.is_empty() {
            continue;
        }

        if line == "}" {
            if stack.pop().is_none() {
                return Err(TextError { line: n, detail: "unmatched '}'".into() });
            }
        } else if let Some(name) = line.strip_suffix('{') {
            let name = name.trim();
            if !is_identifier(name) {
                return Err(TextError { line: n, detail: format!("bad message name {name:?}") });
            }
            stack.push(name);
        } else if let Some((key, value)) = line.split_once(':') {
            let key = key.trim();
            let value = value.trim();
            if !is_identifier(key) {
                return Err(TextError { line: n, detail: format!("bad field name {key:?}") });
            }
            if value.is_empty() {
                return Err(TextError { line: n, detail: format!("field {key:?} has no value") });
            }
            let mut path = stack.join(".");
            if !path.is_empty() {
                path.push('.');
            }
            path.push_str(key);
            out.push(Pair { path, value: value.to_string() });
        } else {
            return Err(TextError { line: n, detail: format!("unrecognised syntax: {line:?}") });
        }
    }

    if !stack.is_empty() {
        return Err(TextError {
            line: src.lines().count(),
            detail: format!("unclosed message {:?}", stack.join(".")),
        });
    }
    Ok(out)
}

/// The value with its surrounding quotes removed, if it has any.
pub fn unquoted(value: &str) -> &str {
    value
        .strip_prefix('"')
        .and_then(|v| v.strip_suffix('"'))
        .unwrap_or(value)
}
