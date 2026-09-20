/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

//! Keeping the Dgraph ACL password out of error text.
//!
//! `DGRAPH_URL` carries `groot:<password>@` userinfo, and a connect error names
//! the target it failed to reach. Both the schema Job and the migrator Job print
//! that error to stderr on every retry, so the redaction belongs where the error
//! is built rather than at each call site: a constructor that cannot hold the
//! credential cannot leak it, whoever calls it.

/// A connection string with any `user:password@` removed.
///
/// Everything else is kept, because host, port and TLS parameters are what
/// makes a connect failure diagnosable.
#[must_use]
pub fn redact_userinfo(target: &str) -> String {
    let Some((scheme, rest)) = target.split_once("://") else {
        return target.to_string();
    };
    let authority_end = rest.find(['/', '?']).unwrap_or(rest.len());
    let (authority, tail) = rest.split_at(authority_end);
    match authority.rsplit_once('@') {
        Some((_userinfo, host)) => format!("{scheme}://{host}{tail}"),
        None => target.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::redact_userinfo;

    #[test]
    fn userinfo_never_survives_into_error_text() {
        assert_eq!(
            redact_userinfo("dgraph://groot:s3cr3t@alpha.example.com:9080?sslmode=verify-ca"),
            "dgraph://alpha.example.com:9080?sslmode=verify-ca"
        );
        assert_eq!(
            redact_userinfo("dgraph://groot:p@ss:word@alpha.example.com:9080"),
            "dgraph://alpha.example.com:9080"
        );
    }

    #[test]
    fn a_target_without_userinfo_is_unchanged() {
        assert_eq!(
            redact_userinfo("dgraph://alpha.example.com:9080?sslmode=require"),
            "dgraph://alpha.example.com:9080?sslmode=require"
        );
        assert_eq!(
            redact_userinfo("alpha.example.com:9080"),
            "alpha.example.com:9080"
        );
    }
}
