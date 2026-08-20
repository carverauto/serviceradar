/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

mod connection_string_debug;
mod connection_string_from_str;

use crate::errors::connection_string_error::ConnectionStringError;
use crate::types::secret::Secret;
use std::path::{Path, PathBuf};
use crate::types::tls_mode::TlsMode;

const SCHEME: &str = "dgraph";

/// A parsed `dgraph://` connection string.
///
/// Format: `dgraph://[username:password@]host:port[?params]`, where `params` may set
/// `sslmode`, `apikey`, `bearertoken`, and `namespace`.
///
/// Unlike the Go client this accepts bracketed IPv6 literals, e.g.
/// `dgraph://[::1]:9080`, because the authority is parsed properly instead of by counting
/// colons.
///
/// `Debug` is hand-written and redacts every credential.
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct ConnectionString {
    host: String,
    port: u16,
    tls: TlsMode,
    username: Option<String>,
    password: Option<Secret>,
    api_key: Option<Secret>,
    bearer_token: Option<Secret>,
    namespace: Option<u64>,
    ca_cert_path: Option<PathBuf>,
}

impl ConnectionString {
    /// Parse a `dgraph://` connection string.
    ///
    /// Errors never contain credential material, even when the failure is in the
    /// userinfo.
    pub fn parse(input: &str) -> Result<Self, ConnectionStringError> {
        let rest = Self::strip_scheme(input)?;

        // Split the query off first: a '?' cannot appear in an authority, and doing this
        // before the userinfo split keeps a '@' inside a query value from being mistaken
        // for the userinfo separator.
        let (authority_and_userinfo, query) = match rest.split_once('?') {
            Some((left, right)) => (left, Some(right)),
            None => (rest, None),
        };

        let (userinfo, authority) = match authority_and_userinfo.rsplit_once('@') {
            Some((userinfo, authority)) => (Some(userinfo), authority),
            None => (None, authority_and_userinfo),
        };

        let (host, port) = Self::parse_authority(authority)?;
        let (username, password) = Self::parse_userinfo(userinfo)?;
        let params = Self::parse_query(query)?;

        let api_key = params.api_key.map(Secret::new);
        let bearer_token = params.bearer_token.map(Secret::new);
        if api_key.is_some() && bearer_token.is_some() {
            return Err(ConnectionStringError::ConflictingAuth());
        }

        Ok(Self {
            host,
            port,
            tls: params.tls,
            username,
            password,
            api_key,
            bearer_token,
            namespace: params.namespace,
            ca_cert_path: params.ca_cert_path,
        })
    }

    fn strip_scheme(input: &str) -> Result<&str, ConnectionStringError> {
        match input.split_once("://") {
            Some((scheme, rest)) if scheme.eq_ignore_ascii_case(SCHEME) => Ok(rest),
            // Echo only the scheme, never the remainder: the remainder may hold userinfo.
            Some((scheme, _)) => Err(ConnectionStringError::InvalidScheme(scheme.to_string())),
            None => Err(ConnectionStringError::InvalidScheme(
                "<missing>".to_string(),
            )),
        }
    }

    /// Parse `host:port`, including bracketed IPv6 literals such as `[::1]:9080`.
    fn parse_authority(authority: &str) -> Result<(String, u16), ConnectionStringError> {
        if authority.is_empty() {
            return Err(ConnectionStringError::MissingHost());
        }

        let (host, port_str) = if let Some(after_bracket) = authority.strip_prefix('[') {
            // IPv6 literal. The host runs to the closing bracket; a port may follow.
            let (host, remainder) = after_bracket.split_once(']').ok_or_else(|| {
                ConnectionStringError::MalformedAuthority(
                    "unterminated IPv6 literal: missing ']'".to_string(),
                )
            })?;
            match remainder.strip_prefix(':') {
                Some(port) => (host, port),
                None if remainder.is_empty() => return Err(ConnectionStringError::MissingPort()),
                None => {
                    return Err(ConnectionStringError::MalformedAuthority(
                        "expected ':' after IPv6 literal".to_string(),
                    ));
                }
            }
        } else {
            // Splitting from the right keeps an unbracketed IPv6 literal from silently
            // parsing as host:port; the port check below then rejects it.
            match authority.rsplit_once(':') {
                Some((host, port)) => (host, port),
                None => return Err(ConnectionStringError::MissingPort()),
            }
        };

        if host.is_empty() {
            return Err(ConnectionStringError::MissingHost());
        }
        if port_str.is_empty() {
            return Err(ConnectionStringError::MissingPort());
        }

        let port = port_str
            .parse::<u16>()
            .map_err(|err| ConnectionStringError::InvalidPort(format!("'{port_str}': {err}")))?;

        Ok((host.to_string(), port))
    }

    fn parse_userinfo(
        userinfo: Option<&str>,
    ) -> Result<(Option<String>, Option<Secret>), ConnectionStringError> {
        let Some(userinfo) = userinfo else {
            return Ok((None, None));
        };

        let (raw_user, raw_password) = match userinfo.split_once(':') {
            Some((user, password)) => (user, Some(password)),
            None => (userinfo, None),
        };

        // Decode without ever putting the decoded value into an error message.
        let username = Self::percent_decode(raw_user, "username")?;
        let password = match raw_password {
            Some(value) => Some(Self::percent_decode(value, "password")?),
            None => None,
        };

        // Both or neither, matching the Go client: a half-supplied credential is far more
        // likely to be a mistake than an intent to connect anonymously.
        match (username.is_empty(), password) {
            (true, None) => Ok((None, None)),
            (false, Some(password)) if !password.is_empty() => {
                Ok((Some(username), Some(Secret::new(password))))
            }
            _ => Err(ConnectionStringError::IncompleteCredentials()),
        }
    }

    fn percent_decode(value: &str, field: &str) -> Result<String, ConnectionStringError> {
        urlencoding::decode(value)
            .map(|decoded| decoded.into_owned())
            // The error names the field only; including the value would leak the secret.
            .map_err(|_| {
                ConnectionStringError::InvalidPercentEncoding(format!(
                    "{field} is not valid percent-encoded UTF-8"
                ))
            })
    }

    fn parse_query(query: Option<&str>) -> Result<QueryParams, ConnectionStringError> {
        let mut params = QueryParams::default();
        let Some(query) = query else {
            return Ok(params);
        };

        let mut ssl_mode_raw: Option<String> = None;

        for pair in query.split('&').filter(|pair| !pair.is_empty()) {
            let (key, value) = pair.split_once('=').ok_or_else(|| {
                // `pair` has no '=', so it is a bare key and cannot be carrying a secret
                // value; echoing it is safe.
                ConnectionStringError::MalformedQuery(format!("parameter '{pair}' has no value"))
            })?;

            match key {
                "sslmode" => ssl_mode_raw = Some(Self::percent_decode(value, "sslmode")?),
                "apikey" => params.api_key = Some(Self::percent_decode(value, "apikey")?),
                "bearertoken" => {
                    params.bearer_token = Some(Self::percent_decode(value, "bearertoken")?)
                }
                "namespace" => {
                    let raw = Self::percent_decode(value, "namespace")?;
                    let parsed = raw.parse::<u64>().map_err(|err| {
                        ConnectionStringError::InvalidNamespace(format!("'{raw}': {err}"))
                    })?;
                    params.namespace = Some(parsed);
                }
                "sslrootcert" => {
                    let raw = Self::percent_decode(value, "sslrootcert")?;
                    params.ca_cert_path = Some(PathBuf::from(raw));
                }
                // Unknown parameters are ignored, matching the Go client, which reads only
                // the four it knows about.
                _ => {}
            }
        }

        if let Some(raw) = ssl_mode_raw {
            params.tls = TlsMode::from_wire(&raw)
                .ok_or_else(|| ConnectionStringError::UnknownSslMode(raw.clone()))?;
        }

        Ok(params)
    }

    /// Host portion of the authority, with IPv6 brackets removed.
    pub fn host(&self) -> &str {
        &self.host
    }

    /// Port portion of the authority.
    pub fn port(&self) -> u16 {
        self.port
    }

    /// Transport security selected by `sslmode`.
    pub fn tls_mode(&self) -> TlsMode {
        self.tls
    }

    /// ACL username, if credentials were supplied.
    pub fn username(&self) -> Option<&str> {
        self.username.as_deref()
    }

    /// ACL password, if credentials were supplied.
    pub fn password(&self) -> Option<&Secret> {
        self.password.as_ref()
    }

    /// Dgraph Cloud API key, if supplied.
    pub fn api_key(&self) -> Option<&Secret> {
        self.api_key.as_ref()
    }

    /// Bearer token, if supplied.
    pub fn bearer_token(&self) -> Option<&Secret> {
        self.bearer_token.as_ref()
    }

    /// Namespace to log into, if supplied.
    pub fn namespace(&self) -> Option<u64> {
        self.namespace
    }

    /// Path to a CA certificate from `sslrootcert`, if supplied. Read when the channel is
    /// built, so a missing file surfaces at connect rather than at parse.
    pub fn ca_cert_path(&self) -> Option<&Path> {
        self.ca_cert_path.as_deref()
    }

    /// The `host:port` authority, re-bracketing an IPv6 literal.
    pub fn authority(&self) -> String {
        if self.host.contains(':') {
            format!("[{}]:{}", self.host, self.port)
        } else {
            format!("{}:{}", self.host, self.port)
        }
    }
}

#[derive(Default)]
struct QueryParams {
    tls: TlsMode,
    api_key: Option<String>,
    bearer_token: Option<String>,
    namespace: Option<u64>,
    ca_cert_path: Option<PathBuf>,
}
