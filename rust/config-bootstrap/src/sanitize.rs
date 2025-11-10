//! TOML sanitization functionality that mirrors pkg/config/toml_mask.go
//!
//! This module provides line-based TOML filtering to remove sensitive keys
//! before writing config to KV storage.

use serde::{Deserialize, Serialize};
use std::io::{BufRead, Write};

/// Identifies a specific key inside an optional table (e.g. table="outputs.prometheus", key="token").
/// Use table="*" to match keys in any table or key="*" to drop an entire table.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TomlPath {
    pub table: String,
    pub key: String,
}

/// Container for sanitization rules loaded from config/sanitization-rules.json
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SanitizationRules {
    #[serde(default)]
    pub description: String,
    pub toml_deny_list: Vec<TomlPath>,
}

/// Load sanitization rules from the embedded or filesystem copy.
///
/// This function looks for the sanitization rules in the following order:
/// 1. Embedded at compile time (if built with embed feature)
/// 2. /etc/serviceradar/sanitization-rules.json
/// 3. config/sanitization-rules.json (relative to cwd)
pub fn load_sanitization_rules() -> Result<SanitizationRules, Box<dyn std::error::Error>> {
    // Try embedded rules first (if we add embed feature later)
    // For now, try filesystem paths

    let paths = [
        "/etc/serviceradar/sanitization-rules.json",
        "config/sanitization-rules.json",
        "../config/sanitization-rules.json",
        "../../config/sanitization-rules.json",
    ];

    for path in &paths {
        if let Ok(data) = std::fs::read(path) {
            if let Ok(rules) = serde_json::from_slice::<SanitizationRules>(&data) {
                tracing::debug!(path = %path, "loaded sanitization rules");
                return Ok(rules);
            }
        }
    }

    // Return default rules if file not found
    tracing::warn!("sanitization rules not found; using default deny list");
    Ok(default_sanitization_rules())
}

fn default_sanitization_rules() -> SanitizationRules {
    SanitizationRules {
        description: "Default sanitization rules".to_string(),
        toml_deny_list: vec![
            TomlPath {
                table: "*".to_string(),
                key: "token".to_string(),
            },
            TomlPath {
                table: "*".to_string(),
                key: "secret".to_string(),
            },
            TomlPath {
                table: "*".to_string(),
                key: "password".to_string(),
            },
            TomlPath {
                table: "*".to_string(),
                key: "api_key".to_string(),
            },
            TomlPath {
                table: "*".to_string(),
                key: "apiKey".to_string(),
            },
        ],
    }
}

/// Sanitize TOML by removing lines containing sensitive keys.
///
/// This mirrors the line-based filtering in pkg/config/toml_mask.go.
/// It handles basic table headers ([table]) and key/value pairs (key = value).
pub fn sanitize_toml(data: &[u8], deny_list: &[TomlPath]) -> Vec<u8> {
    if data.is_empty() || deny_list.is_empty() {
        return data.to_vec();
    }

    let deny_map = build_deny_map(deny_list);

    let mut output = Vec::new();
    let mut current_table = String::new();

    let reader = std::io::Cursor::new(data);
    for line in reader.lines() {
        let Ok(raw_line) = line else {
            continue;
        };

        let trimmed = raw_line.trim();

        // Preserve blank lines and comments
        if trimmed.is_empty() || trimmed.starts_with('#') {
            writeln!(&mut output, "{}", raw_line).ok();
            continue;
        }

        // Update current table
        if is_table_header(trimmed) {
            current_table = trimmed.trim_matches(|c| c == '[' || c == ']').to_string();
            writeln!(&mut output, "{}", raw_line).ok();
            continue;
        }

        // Extract key from key=value line
        let key = extract_key(trimmed);
        if key.is_empty() {
            writeln!(&mut output, "{}", raw_line).ok();
            continue;
        }

        // Check if we should drop this key
        if should_drop_key(&current_table, &key, &deny_map) {
            tracing::debug!(table = %current_table, key = %key, "dropping sensitive key");
            continue;
        }

        writeln!(&mut output, "{}", raw_line).ok();
    }

    // Trim trailing newlines
    while output.last() == Some(&b'\n') {
        output.pop();
    }

    output
}

fn build_deny_map(
    deny_list: &[TomlPath],
) -> std::collections::HashMap<String, std::collections::HashSet<String>> {
    let mut map = std::collections::HashMap::new();

    for path in deny_list {
        let table = if path.table.is_empty() {
            ""
        } else {
            &path.table
        };

        let key = if path.key.is_empty() { "*" } else { &path.key };

        map.entry(table.to_string())
            .or_insert_with(std::collections::HashSet::new)
            .insert(key.to_string());
    }

    map
}

fn should_drop_key(
    table: &str,
    key: &str,
    deny_map: &std::collections::HashMap<String, std::collections::HashSet<String>>,
) -> bool {
    // Check exact table match
    if let Some(keys) = deny_map.get(table) {
        if keys.contains("*") || keys.contains(key) {
            return true;
        }
    }

    // Check wildcard table match
    if let Some(keys) = deny_map.get("*") {
        if keys.contains("*") || keys.contains(key) {
            return true;
        }
    }

    false
}

fn is_table_header(line: &str) -> bool {
    line.starts_with('[') && line.ends_with(']')
}

fn extract_key(line: &str) -> String {
    if let Some(idx) = line.find('=') {
        line[..idx].trim().to_string()
    } else {
        String::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_sanitize_toml_removes_tokens() {
        let input = b"
listen_addr = \"0.0.0.0:8080\"
token = \"secret123\"
log_level = \"info\"
";

        let deny_list = vec![TomlPath {
            table: "*".to_string(),
            key: "token".to_string(),
        }];

        let output = sanitize_toml(input, &deny_list);
        let output_str = String::from_utf8_lossy(&output);

        assert!(output_str.contains("listen_addr"));
        assert!(output_str.contains("log_level"));
        assert!(!output_str.contains("token"));
    }

    #[test]
    fn test_sanitize_toml_table_specific() {
        let input = b"
[general]
name = \"test\"
token = \"keep-this\"

[outputs.prometheus]
url = \"http://localhost:9090\"
token = \"drop-this\"
";

        let deny_list = vec![TomlPath {
            table: "outputs.prometheus".to_string(),
            key: "token".to_string(),
        }];

        let output = sanitize_toml(input, &deny_list);
        let output_str = String::from_utf8_lossy(&output);

        assert!(output_str.contains("token = \"keep-this\""));
        assert!(!output_str.contains("token = \"drop-this\""));
        assert!(output_str.contains("url ="));
    }

    #[test]
    fn test_sanitize_toml_preserves_comments() {
        let input = b"
# This is a comment
listen_addr = \"0.0.0.0:8080\"
# Another comment
token = \"secret\"
";

        let deny_list = vec![TomlPath {
            table: "*".to_string(),
            key: "token".to_string(),
        }];

        let output = sanitize_toml(input, &deny_list);
        let output_str = String::from_utf8_lossy(&output);

        assert!(output_str.contains("# This is a comment"));
        assert!(output_str.contains("# Another comment"));
        assert!(!output_str.contains("token"));
    }

    #[test]
    fn test_sanitize_toml_wildcard_table() {
        let input = b"
[security]
cert_path = \"/path/to/cert\"
key_path = \"/path/to/key\"

[general]
name = \"test\"
";

        let deny_list = vec![TomlPath {
            table: "security".to_string(),
            key: "*".to_string(),
        }];

        let output = sanitize_toml(input, &deny_list);
        let output_str = String::from_utf8_lossy(&output);

        assert!(!output_str.contains("cert_path"));
        assert!(!output_str.contains("key_path"));
        assert!(output_str.contains("name = \"test\""));
        assert!(output_str.contains("[security]")); // Table header preserved
    }

    #[test]
    fn test_default_rules_include_common_secrets() {
        let rules = default_sanitization_rules();
        let deny_list = &rules.toml_deny_list;

        assert!(deny_list.iter().any(|p| p.key == "token"));
        assert!(deny_list.iter().any(|p| p.key == "secret"));
        assert!(deny_list.iter().any(|p| p.key == "password"));
        assert!(deny_list.iter().any(|p| p.key == "api_key"));
    }
}
