//! Rejects credential-shaped values in configuration files.
//!
//! Decision 10 puts customer topology in this repository, and the only thing that keeps that
//! acceptable is that configuration holds no credentials. The schema has no password field,
//! so this is not about a badly named field slipping in -- it is about a credential arriving
//! inside a field that legitimately holds a string, which is exactly how a DSN with an
//! embedded password gets committed.
//!
//! Detection is by SHAPE, and the input is the canonical text of the COMPILED binary rather
//! than the committed source. Both choices are load-bearing: a list of known-bad field names
//! would only catch fields someone already thought of, and scanning the source would flag the
//! word "password" in the comment that warns against them while missing a field the scanner
//! did not know to look at.

use crate::text::{unquoted, Pair};
use regex_automata::meta::Regex;

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct Finding {
    pub path: String,
    pub reason: &'static str,
}

/// Field-name fragments that name a credential. Present so a schema change that adds such a
/// field is caught here too, not only values inside existing fields.
const CREDENTIAL_NAMES: &[&str] = &[
    "password", "passwd", "secret", "token", "apikey", "api_key", "privatekey", "private_key",
    "credential", "passphrase",
];

struct Shape {
    re: Regex,
    reason: &'static str,
}

fn shapes() -> Vec<Shape> {
    let specs: &[(&str, &str)] = &[
        // scheme://user:pass@host -- userinfo carrying a password. Neither component may
        // contain '/' or '@', so a path segment or a bare host:port cannot match.
        (r"://[^/@[:space:]]*:[^/@[:space:]]*@", "URL with embedded credentials"),
        // A keyword=value credential parameter, as in a libpq DSN or a JDBC URL.
        (
            r"(?i)(password|passwd|secret|token|api[-_]?key|passphrase)[[:space:]]*=",
            "connection string with an embedded credential parameter",
        ),
        (r"-----BEGIN", "PEM-encoded key or certificate material"),
        // An unbroken base64 run as the WHOLE value. Anchored so it cannot fire on a
        // hostname, a DSN or a SPIFFE ID, all of which carry '.', '-', ':' or '/'.
        (r"^[A-Za-z0-9+/]{40,}={0,2}$", "high-entropy token"),
    ];
    specs
        .iter()
        .map(|(pattern, reason)| Shape {
            re: Regex::new(pattern).unwrap_or_else(|e| panic!("bad pattern {pattern:?}: {e}")),
            reason,
        })
        .collect()
}

/// Every credential-shaped field in `pairs`, ordered by `(path, reason)`.
pub fn scan(pairs: &[Pair]) -> Vec<Finding> {
    let shapes = shapes();
    let mut out = Vec::new();

    for pair in pairs {
        let leaf = pair.path.rsplit('.').next().unwrap_or(&pair.path).to_ascii_lowercase();
        if CREDENTIAL_NAMES.iter().any(|n| leaf.contains(n)) {
            out.push(Finding { path: pair.path.clone(), reason: "field name denotes a credential" });
        }

        let value = unquoted(&pair.value);
        for shape in &shapes {
            if shape.re.is_match(value) {
                out.push(Finding { path: pair.path.clone(), reason: shape.reason });
            }
        }
    }

    out.sort();
    out.dedup();
    out
}
