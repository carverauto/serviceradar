//! JWT SVID types.
//!
//! Supports two common flows:
//! 1) **Workload API (trusted)**: tokens are fetched from the SPIRE agent (already validated by the agent).
//!    Use [`JwtSvid::from_workload_api_token`] to parse and inspect the token.
//! 2) **Offline verification**: verify a token using JWT authorities from bundles.
//!    Requires a JWT verification backend feature (`jwt-verify-rust-crypto` or `jwt-verify-aws-lc-rs`)
//!    and [`JwtSvid::parse_and_validate`].

use std::fmt;
use std::marker::PhantomData;
use std::str::FromStr;
use std::sync::Arc;

use serde::{de, Deserialize, Deserializer, Serialize};
use thiserror::Error;
use time::OffsetDateTime;
use zeroize::Zeroize;

use crate::spiffe_id::{SpiffeId, SpiffeIdError, TrustDomain};

#[cfg(any(feature = "jwt-verify-rust-crypto", feature = "jwt-verify-aws-lc-rs"))]
use crate::bundle::jwt::{JwtAuthority, JwtBundle};
#[cfg(any(feature = "jwt-verify-rust-crypto", feature = "jwt-verify-aws-lc-rs"))]
use crate::bundle::BundleSource;

#[cfg(any(feature = "jwt-verify-rust-crypto", feature = "jwt-verify-aws-lc-rs"))]
use jsonwebtoken::{DecodingKey, Validation};

/// Algorithms supported for JWT-SVIDs according to the SPIFFE JWT-SVID profile.
///
/// Represents the subset of JWT signature algorithms compliant with the SPIFFE JWT-SVID specification.
///
/// Offline verification (`parse_and_validate`) currently depends on
/// `jsonwebtoken` v10 (enabled via `jwt-verify-rust-crypto` or
/// `jwt-verify-aws-lc-rs`), which does not provide ES512 (P-521) verification.
/// ES512 JWT-SVIDs are accepted by parsing APIs, but offline verification
/// returns [`JwtSvidError::BackendUnsupportedAlgorithm`].
#[derive(Debug, Clone, Copy, Eq, PartialEq)]
#[non_exhaustive]
pub enum JwtAlg {
    /// RSASSA-PKCS1-v1_5 using SHA-256
    RS256,
    /// RSASSA-PKCS1-v1_5 using SHA-384
    RS384,
    /// RSASSA-PKCS1-v1_5 using SHA-512
    RS512,
    /// ECDSA using P-256 and SHA-256
    ES256,
    /// ECDSA using P-384 and SHA-384
    ES384,
    /// ECDSA using P-521 and SHA-512
    ES512,
    /// RSASSA-PSS using SHA-256 and MGF1 with SHA-256
    PS256,
    /// RSASSA-PSS using SHA-384 and MGF1 with SHA-384
    PS384,
    /// RSASSA-PSS using SHA-512 and MGF1 with SHA-512
    PS512,
}

impl JwtAlg {
    fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "RS256" => Self::RS256,
            "RS384" => Self::RS384,
            "RS512" => Self::RS512,
            "ES256" => Self::ES256,
            "ES384" => Self::ES384,
            "ES512" => Self::ES512,
            "PS256" => Self::PS256,
            "PS384" => Self::PS384,
            "PS512" => Self::PS512,
            _ => return None,
        })
    }

    #[cfg(any(feature = "jwt-verify-rust-crypto", feature = "jwt-verify-aws-lc-rs"))]
    const fn to_jsonwebtoken(self) -> Option<jsonwebtoken::Algorithm> {
        match self {
            Self::RS256 => Some(jsonwebtoken::Algorithm::RS256),
            Self::RS384 => Some(jsonwebtoken::Algorithm::RS384),
            Self::RS512 => Some(jsonwebtoken::Algorithm::RS512),
            Self::ES256 => Some(jsonwebtoken::Algorithm::ES256),
            Self::ES384 => Some(jsonwebtoken::Algorithm::ES384),
            // ES512 is valid per SPIFFE JWT-SVID, but is unavailable in the
            // jsonwebtoken verification backend used here.
            Self::ES512 => None,
            Self::PS256 => Some(jsonwebtoken::Algorithm::PS256),
            Self::PS384 => Some(jsonwebtoken::Algorithm::PS384),
            Self::PS512 => Some(jsonwebtoken::Algorithm::PS512),
        }
    }
}

/// Represents a SPIFFE JWT-SVID.
///
/// The serialized token is zeroized on drop.
///
/// ## Usage Patterns
///
/// - **Trusted tokens** (from Workload API): Use [`JwtSvid::from_workload_api_token`]
/// - **Untrusted tokens** (from network): Use [`JwtSvid::parse_and_validate`] (requires a JWT verification backend feature)
///
/// See the [module documentation](self) for details on verification modes.
///
/// ## Invariants
///
/// - `spiffe_id` and `claims.sub` always represent the same SPIFFE ID
///   (the `sub` claim is validated to be a valid `SpiffeId` during parsing)
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JwtSvid {
    spiffe_id: SpiffeId,
    hint: Option<Arc<str>>,
    expiry: OffsetDateTime,
    claims: Claims,
    kid: String,
    token: Token,
    alg: JwtAlg,
}

#[derive(Debug, Clone, Eq, PartialEq, Deserialize)]
struct Header {
    #[serde(default)]
    kid: Option<String>,
    #[serde(default)]
    typ: Option<String>,
    alg: String,
}

/// Errors that can arise parsing a [`JwtSvid`] from a JWT token or validating
/// the token signature or audience.
#[derive(Debug, Error)]
#[non_exhaustive]
pub enum JwtSvidError {
    /// The 'sub' claim is not a valid SPIFFE ID.
    #[error("invalid spiffe_id in token 'sub' claim")]
    InvalidSubject(#[from] SpiffeIdError),

    /// The header 'kid' is not present.
    #[error("token header 'kid' not found")]
    MissingKeyId,

    /// The header 'typ' contains a value other than 'JWT' or 'JOSE'.
    #[error("token header 'typ' should be 'JWT' or 'JOSE'")]
    InvalidTyp,

    /// Invalid 'exp' claim value.
    #[error("invalid token expiration ('exp') claim")]
    InvalidExpiration,

    /// The token algorithm is not supported by this crate.
    #[error("algorithm in 'alg' header is not supported")]
    UnsupportedAlgorithm,

    /// The token algorithm is valid for JWT-SVID but unsupported by the
    /// configured offline verification backend.
    #[error("algorithm in 'alg' header is unsupported by offline verification backend: {0:?}")]
    BackendUnsupportedAlgorithm(JwtAlg),

    /// Token does not have 3 dot-separated parts.
    #[error("malformed jwt token: expected 3 dot-separated parts")]
    InvalidJwtFormat,

    /// Invalid base64url encoding in JWT header/claims.
    #[error("malformed jwt token: invalid base64url encoding")]
    InvalidBase64,

    /// Invalid JSON in JWT header or claims.
    #[error("malformed jwt token: invalid json")]
    InvalidJson(#[source] serde_json::Error),

    /// Cannot find a JWT bundle for the trust domain, to validate the token signature.
    #[error("cannot find JWT bundle for trust domain: {0}")]
    BundleNotFound(TrustDomain),

    /// Cannot find the JWT authority with `key_id`, to validate the token signature.
    #[error("cannot find JWT authority for key_id: {0}")]
    AuthorityNotFound(String),

    /// The token doesn't have the expected audience.
    #[error("expected audience in {0:?} (audience={1:?})")]
    InvalidAudience(Vec<String>, Vec<String>),

    /// Error returned by the bundle source while fetching the bundle.
    #[error("bundle source error")]
    BundleSourceError(#[source] Box<dyn std::error::Error + Send + Sync + 'static>),

    /// Offline verification backend is not enabled.
    #[error("jwt offline verification not enabled (enable feature: jwt-verify-rust-crypto or jwt-verify-aws-lc-rs)")]
    JwtVerifyNotEnabled,

    /// The authority JWK JSON could not be parsed.
    #[cfg(any(feature = "jwt-verify-rust-crypto", feature = "jwt-verify-aws-lc-rs"))]
    #[error("cannot parse authority JWK JSON: {0}")]
    InvalidAuthorityJwk(#[from] serde_json::Error),

    /// Error returned by the JWT decoding library.
    #[cfg(any(feature = "jwt-verify-rust-crypto", feature = "jwt-verify-aws-lc-rs"))]
    #[error("cannot decode token")]
    InvalidToken(#[from] jsonwebtoken::errors::Error),
}

impl From<std::convert::Infallible> for JwtSvidError {
    fn from(never: std::convert::Infallible) -> Self {
        match never {}
    }
}

#[derive(Debug, Clone, Eq, PartialEq, Zeroize)]
#[zeroize(drop)]
struct Token {
    inner: String,
}

impl From<&str> for Token {
    fn from(token: &str) -> Self {
        Self {
            inner: token.to_owned(),
        }
    }
}

impl AsRef<str> for Token {
    fn as_ref(&self) -> &str {
        self.inner.as_ref()
    }
}

/// Required JWT-SVID claims.
#[derive(Debug, Clone, Eq, PartialEq, Serialize, Deserialize)]
pub struct Claims {
    sub: String,
    #[serde(deserialize_with = "string_or_seq_string")]
    aud: Vec<String>,
    exp: i64,
}

impl Claims {
    /// Returns the SPIFFE ID (from the `sub` claim).
    pub fn sub(&self) -> &str {
        &self.sub
    }

    /// Returns the audience (from the `aud` claim).
    pub fn aud(&self) -> &[String] {
        &self.aud
    }

    /// Returns the expiration timestamp (from the `exp` claim).
    pub const fn exp(&self) -> i64 {
        self.exp
    }
}

impl JwtSvid {
    /// Parses a JWT-SVID obtained from the SPIFFE Workload API.
    ///
    /// This performs **no signature verification**. It is intended for tokens that are
    /// trusted by construction (i.e., fetched from the SPIRE agent).
    ///
    /// For untrusted tokens, use [`JwtSvid::parse_and_validate`] (requires a JWT verification backend feature).
    ///
    /// # Errors
    ///
    /// See [`JwtSvid::parse_insecure`].
    pub fn from_workload_api_token(token: &str) -> Result<Self, JwtSvidError> {
        Self::parse_insecure(token)
    }

    /// Parses a JWT-SVID without performing signature verification.
    ///
    /// This method validates only token **structure** and required headers/claims. It is
    /// appropriate when the token is **trusted by construction**, such as tokens obtained
    /// from the SPIFFE Workload API.
    ///
    /// For untrusted tokens, use [`JwtSvid::parse_and_validate`] instead (requires
    /// a JWT verification backend feature: `jwt-verify-rust-crypto` or `jwt-verify-aws-lc-rs`).
    ///
    /// # Errors
    ///
    /// Returns [`JwtSvidError`] if:
    /// - the token is not a 3-part JWT (`header.payload.signature`),
    /// - header/claims are not valid base64url or JSON,
    /// - required headers/claims are missing or invalid (`kid`, `sub`, `aud`, `exp`),
    /// - the `sub` claim is not a valid SPIFFE ID,
    /// - the `alg` header is not supported,
    /// - the optional `typ` header is present but not `JWT` or `JOSE`.
    pub fn parse_insecure(token: &str) -> Result<Self, JwtSvidError> {
        Self::from_str(token)
    }

    /// Parses and validates `token` offline:
    /// - verifies the signature using the provided bundle source,
    /// - validates the audience against `expected_audience`,
    /// - validates expiration (`exp`).
    ///
    /// Requires a JWT verification backend feature (`jwt-verify-rust-crypto` or `jwt-verify-aws-lc-rs`).
    ///
    /// ## Validation Policy
    ///
    /// This method validates:
    /// - **Signature**: Verified using the JWT authority from the bundle
    /// - **Expiration (`exp`)**: Token must not be expired (no clock skew leeway)
    /// - **Audience (`aud`)**: Must match one of the values in `expected_audience`
    /// - **Required claims**: `sub`, `aud`, `exp` must be present and valid
    /// - **Algorithm**: Must be supported by the SPIFFE JWT-SVID profile and by
    ///   the configured offline verification backend
    ///
    /// This method does **not** validate:
    /// - **Issued at (`iat`)**: Not checked
    /// - **Not before (`nbf`)**: Not checked
    /// - **Issuer (`iss`)**: Not checked (trust domain is derived from `sub`)
    /// - **Clock skew**: No leeway is applied to expiration checks
    ///
    /// # Errors
    ///
    /// Returns [`JwtSvidError`] if:
    /// - the token is malformed or cannot be decoded,
    /// - required headers/claims are missing or invalid (e.g. `kid`, `sub`, `exp`),
    /// - the token uses an unsupported signature algorithm,
    /// - the trust domain bundle or authority (`kid`) cannot be found,
    /// - the signature verification fails,
    /// - the token is expired, or the audience does not match `expected_audience`,
    /// - the bundle source returns an error while fetching bundles.
    #[cfg(any(feature = "jwt-verify-rust-crypto", feature = "jwt-verify-aws-lc-rs"))]
    pub fn parse_and_validate<B, T>(
        token: &str,
        bundle_source: &B,
        expected_audience: &[T],
    ) -> Result<Self, JwtSvidError>
    where
        B: BundleSource<Item = JwtBundle>,
        B::Error: std::error::Error + Send + Sync + 'static,
        T: AsRef<str> + fmt::Debug,
    {
        use jsonwebtoken::jwk::Jwk;

        // Parse untrusted token to extract trust domain, kid, and alg.
        // Note: The `aud` claim size limit is enforced during Claims deserialization,
        // rejecting oversized arrays before signature verification and other expensive processing.
        let untrusted = Self::parse_insecure(token)?;

        let jw_alg = untrusted
            .alg
            .to_jsonwebtoken()
            .ok_or(JwtSvidError::BackendUnsupportedAlgorithm(untrusted.alg))?;

        let jwt_authority = Self::find_jwt_authority(
            bundle_source,
            untrusted.spiffe_id.trust_domain(),
            &untrusted.kid,
        )?;

        let mut validation = Validation::new(jw_alg);
        validation.validate_exp = true;
        validation.leeway = 0;

        let aud: Vec<&str> = expected_audience.iter().map(AsRef::as_ref).collect();
        validation.set_audience(&aud);

        // Convert stored authority JSON to a jsonwebtoken Jwk, then to DecodingKey.
        let jwk: Jwk = serde_json::from_slice(jwt_authority.jwk_json())?;
        let dec_key = DecodingKey::from_jwk(&jwk)?;

        // Perform a validating decode (signature, exp, aud).
        jsonwebtoken::decode::<Claims>(token, &dec_key, &validation)?;

        Ok(untrusted)
    }

    /// Returns a copy of this JWT-SVID with the given Workload API hint attached.
    ///
    /// This hint is not part of the JWT; it is metadata returned by the SPIFFE Workload API.
    #[must_use]
    pub fn with_hint(mut self, hint: impl Into<Arc<str>>) -> Self {
        self.hint = Some(hint.into());
        self
    }

    /// Returns the serialized token.
    pub fn token(&self) -> &str {
        self.token.as_ref()
    }

    /// Returns the SPIFFE ID (from the `sub` claim).
    pub const fn spiffe_id(&self) -> &SpiffeId {
        &self.spiffe_id
    }

    /// Returns the audience (from the `aud` claim).
    pub fn audience(&self) -> &[String] {
        &self.claims.aud
    }

    /// Returns the token expiration timestamp (from the `exp` claim).
    pub const fn expiry(&self) -> OffsetDateTime {
        self.expiry
    }

    /// Returns the `kid` header.
    ///
    /// The key ID identifies which public key should be used to verify the token's signature.
    /// It corresponds to the `kid` field in the JWT bundle.
    pub fn key_id(&self) -> &str {
        &self.kid
    }

    /// Returns the parsed claims (untrusted unless validated).
    ///
    /// **Note:** Claims are only trustworthy if the token was validated using
    /// [`JwtSvid::parse_and_validate`]. Tokens parsed with [`JwtSvid::from_workload_api_token`]
    /// are trusted by construction (fetched from the SPIRE agent).
    pub const fn claims(&self) -> &Claims {
        &self.claims
    }

    /// Returns the Workload API hint (if any).
    ///
    /// This hint is not part of the JWT; it is metadata returned by the SPIFFE Workload API
    /// when more than one SVID is available.
    pub fn hint(&self) -> Option<&str> {
        self.hint.as_deref()
    }

    #[cfg(any(feature = "jwt-verify-rust-crypto", feature = "jwt-verify-aws-lc-rs"))]
    fn find_jwt_authority<B>(
        bundle_source: &B,
        trust_domain: &TrustDomain,
        key_id: &str,
    ) -> Result<Arc<JwtAuthority>, JwtSvidError>
    where
        B: BundleSource<Item = JwtBundle>,
        B::Error: std::error::Error + Send + Sync + 'static,
    {
        let bundle = bundle_source
            .bundle_for_trust_domain(trust_domain)
            .map_err(|e| JwtSvidError::BundleSourceError(Box::new(e)))?
            .ok_or_else(|| JwtSvidError::BundleNotFound(trust_domain.clone()))?;

        bundle
            .find_jwt_authority(key_id) // Option<&Arc<Jwk>>
            .cloned() // Option<Arc<Jwk>>
            .ok_or_else(|| JwtSvidError::AuthorityNotFound(key_id.to_owned()))
    }
}

impl FromStr for JwtSvid {
    type Err = JwtSvidError;

    /// Creates a new [`JwtSvid`] from `token` without signature verification.
    fn from_str(token: &str) -> Result<Self, Self::Err> {
        // Split JWT parts.
        let mut it = token.split('.');
        let header_b64 = it.next().ok_or(JwtSvidError::InvalidJwtFormat)?;
        let claims_b64 = it.next().ok_or(JwtSvidError::InvalidJwtFormat)?;
        let _sig_b64 = it.next().ok_or(JwtSvidError::InvalidJwtFormat)?;
        if it.next().is_some() {
            return Err(JwtSvidError::InvalidJwtFormat);
        }

        let header_json = decode_b64url_to_vec(header_b64)?;
        let claims_json = decode_b64url_to_vec(claims_b64)?;

        let header: Header =
            serde_json::from_slice(&header_json).map_err(JwtSvidError::InvalidJson)?;
        let claims: Claims =
            serde_json::from_slice(&claims_json).map_err(JwtSvidError::InvalidJson)?;

        // Validate typ if present.
        if let Some(t) = header.typ.as_deref() {
            match t {
                "JWT" | "JOSE" => {}
                _ => return Err(JwtSvidError::InvalidTyp),
            }
        }

        // Validate alg.
        let alg = JwtAlg::parse(header.alg.as_str()).ok_or(JwtSvidError::UnsupportedAlgorithm)?;

        let kid = header.kid.ok_or(JwtSvidError::MissingKeyId)?;

        // Parse SPIFFE ID.
        let spiffe_id = SpiffeId::from_str(&claims.sub)?;

        // Parse exp.
        let expiry = OffsetDateTime::from_unix_timestamp(claims.exp)
            .map_err(|time::error::ComponentRange { .. }| JwtSvidError::InvalidExpiration)?;

        Ok(Self {
            spiffe_id,
            hint: None,
            expiry,
            claims,
            kid,
            alg,
            token: Token::from(token),
        })
    }
}

/// Maximum number of audience values allowed in a JWT `aud` claim.
///
/// This limit prevents `DoS` attacks through excessive memory allocation when processing
/// JWT tokens with large audience arrays. A typical JWT-SVID has 1-3 audience values.
/// A limit of 32 is conservative and sufficient for legitimate use cases while preventing
/// resource exhaustion from adversarial or malformed tokens.
const MAX_JWT_AUDIENCE_COUNT: usize = 32;

// Deserialize 'aud' claim being either a String or a sequence of strings.
// Enforces MAX_JWT_AUDIENCE_COUNT during deserialization to prevent DoS attacks.
fn string_or_seq_string<'de, D>(deserializer: D) -> Result<Vec<String>, D::Error>
where
    D: Deserializer<'de>,
{
    struct StringOrVec(PhantomData<Vec<String>>);

    impl<'de> de::Visitor<'de> for StringOrVec {
        type Value = Vec<String>;

        fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
            formatter.write_str("string or sequence of strings")
        }

        fn visit_str<E>(self, v: &str) -> Result<Self::Value, E>
        where
            E: de::Error,
        {
            Ok(vec![v.to_owned()])
        }

        fn visit_seq<S>(self, mut seq: S) -> Result<Self::Value, S::Error>
        where
            S: de::SeqAccess<'de>,
        {
            // Enforce a hard upper bound during deserialization to cap allocations and prevent DoS attacks.
            let mut result = Vec::new();
            while let Some(elem) = seq.next_element::<String>()? {
                if result.len() >= MAX_JWT_AUDIENCE_COUNT {
                    // Exceeded limit during deserialization - return error to prevent further allocation.
                    // This error will surface as InvalidJson (deserialization errors map to InvalidJson),
                    // which is appropriate since the token's JSON structure violates size constraints.
                    return Err(de::Error::custom(format!(
                        "JWT `aud` claim has too many entries (max {MAX_JWT_AUDIENCE_COUNT})"
                    )));
                }
                result.push(elem);
            }
            Ok(result)
        }
    }

    deserializer.deserialize_any(StringOrVec(PhantomData))
}

/// Maximum size for a JWT segment (header or claims) after base64url decoding.
///
/// This limit prevents excessive memory allocation from malicious or malformed tokens.
/// 64KB is more than sufficient for any valid JWT-SVID.
const MAX_JWT_SEGMENT_SIZE: usize = 64 * 1024;

/// Decode base64url (no padding) into bytes.
///
/// Applies size limits to prevent excessive memory allocation from malicious input.
fn decode_b64url_to_vec(input: &str) -> Result<Vec<u8>, JwtSvidError> {
    use base64ct::{Base64UrlUnpadded, Encoding as _};

    // Base64url encoding expands data by ~33%, so the encoded size gives us an upper bound.
    // Reject obviously oversized inputs before attempting to decode.
    if input.len() > MAX_JWT_SEGMENT_SIZE * 4 / 3 {
        return Err(JwtSvidError::InvalidBase64);
    }

    let mut buf = vec![0u8; input.len()];

    let len = Base64UrlUnpadded::decode(input, &mut buf)
        .map_err(|err| {
            match err {
                base64ct::Error::InvalidLength | base64ct::Error::InvalidEncoding => {}
            }
            JwtSvidError::InvalidBase64
        })?
        .len();

    // Defensive check: decoded size should not exceed our limit.
    if len > MAX_JWT_SEGMENT_SIZE {
        return Err(JwtSvidError::InvalidBase64);
    }

    buf.truncate(len);
    Ok(buf)
}

#[cfg(test)]
fn mk_token(header_json: &str, claims_json: &str) -> String {
    use base64ct::{Base64UrlUnpadded, Encoding as _};

    let h = Base64UrlUnpadded::encode_string(header_json.as_bytes());
    let c = Base64UrlUnpadded::encode_string(claims_json.as_bytes());

    // Signature bytes are irrelevant for parsing tests; only token shape matters.
    format!("{h}.{c}.sig")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_insecure_ok_with_aud_string() {
        let token = mk_token(
            r#"{"alg":"ES256","kid":"k1","typ":"JWT"}"#,
            r#"{"sub":"spiffe://example.org/service","aud":"aud1","exp":4294967295}"#,
        );

        let svid = JwtSvid::parse_insecure(&token).unwrap();
        assert_eq!(svid.spiffe_id().to_string(), "spiffe://example.org/service");
        assert_eq!(svid.key_id(), "k1");
        assert_eq!(svid.audience(), &["aud1".to_string()]);
        assert_eq!(svid.token(), token);
    }

    #[test]
    fn parse_insecure_ok_with_aud_array() {
        let token = mk_token(
            r#"{"alg":"RS256","kid":"k1"}"#,
            r#"{"sub":"spiffe://example.org/service","aud":["a","b"],"exp":4294967295}"#,
        );

        let svid = JwtSvid::parse_insecure(&token).unwrap();
        assert_eq!(svid.audience(), &["a".to_string(), "b".to_string()]);
    }

    #[test]
    fn parse_insecure_rejects_missing_kid() {
        let token = mk_token(
            r#"{"alg":"ES256"}"#,
            r#"{"sub":"spiffe://example.org/service","aud":"aud1","exp":4294967295}"#,
        );

        let err = JwtSvid::parse_insecure(&token).unwrap_err();
        assert!(matches!(err, JwtSvidError::MissingKeyId));
    }

    #[test]
    fn parse_insecure_rejects_invalid_typ() {
        let token = mk_token(
            r#"{"alg":"ES256","kid":"k1","typ":"NOPE"}"#,
            r#"{"sub":"spiffe://example.org/service","aud":"aud1","exp":4294967295}"#,
        );

        let err = JwtSvid::parse_insecure(&token).unwrap_err();
        assert!(matches!(err, JwtSvidError::InvalidTyp));
    }

    #[test]
    fn parse_insecure_rejects_unsupported_alg() {
        let token = mk_token(
            r#"{"alg":"HS256","kid":"k1"}"#,
            r#"{"sub":"spiffe://example.org/service","aud":"aud1","exp":4294967295}"#,
        );

        let err = JwtSvid::parse_insecure(&token).unwrap_err();
        assert!(matches!(err, JwtSvidError::UnsupportedAlgorithm));
    }

    #[test]
    fn parse_insecure_accepts_es512_alg() {
        let token = mk_token(
            r#"{"alg":"ES512","kid":"k1"}"#,
            r#"{"sub":"spiffe://example.org/service","aud":"aud1","exp":4294967295}"#,
        );

        let svid = JwtSvid::parse_insecure(&token).unwrap();
        assert_eq!(svid.alg, JwtAlg::ES512);
    }

    #[test]
    fn parse_insecure_rejects_bad_format() {
        let err = JwtSvid::parse_insecure("a.b").unwrap_err();
        assert!(matches!(err, JwtSvidError::InvalidJwtFormat));
    }

    #[test]
    fn parse_insecure_rejects_bad_base64() {
        let err = JwtSvid::parse_insecure("!!!.!!!.sig").unwrap_err();
        assert!(matches!(err, JwtSvidError::InvalidBase64));
    }

    #[test]
    fn parse_insecure_rejects_invalid_json() {
        let token = mk_token(
            r#"{"alg":"ES256","kid":"k1"}"#,
            r#"{"sub":,"aud":"aud1","exp":4294967295}"#, // invalid JSON
        );

        let err = JwtSvid::parse_insecure(&token).unwrap_err();
        assert!(matches!(err, JwtSvidError::InvalidJson(_)));
    }

    #[test]
    fn parse_insecure_rejects_invalid_sub() {
        let token = mk_token(
            r#"{"alg":"ES256","kid":"k1"}"#,
            r#"{"sub":"not-a-spiffe-id","aud":"aud1","exp":4294967295}"#,
        );

        let err = JwtSvid::parse_insecure(&token).unwrap_err();
        assert!(matches!(err, JwtSvidError::InvalidSubject(_)));
    }

    #[test]
    fn parse_insecure_rejects_invalid_exp() {
        let token = mk_token(
            r#"{"alg":"ES256","kid":"k1"}"#,
            r#"{"sub":"spiffe://example.org/service","aud":"aud1","exp":"nope"}"#,
        );

        let err = JwtSvid::parse_insecure(&token).unwrap_err();
        assert!(matches!(err, JwtSvidError::InvalidJson(_)));
    }
}

#[expect(
    clippy::expect_used,
    clippy::tests_outside_test_module,
    clippy::unwrap_used,
    reason = "https://github.com/rust-lang/rust-clippy/issues/16476"
)]
#[cfg(all(
    test,
    any(feature = "jwt-verify-rust-crypto", feature = "jwt-verify-aws-lc-rs")
))]
mod test {
    use super::*;
    use crate::bundle::jwt::JwtBundleSet;

    use base64ct::{Base64UrlUnpadded, Encoding as _};
    use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
    use p256::ecdsa::SigningKey;
    use p256::elliptic_curve::pkcs8::EncodePrivateKey as _;
    // use rand_core::OsRng;
    use p256::elliptic_curve::rand_core::OsRng;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn b64u(data: &[u8]) -> String {
        Base64UrlUnpadded::encode_string(data)
    }

    /// Build a minimal ES256 public JWK JSON with `kid`.
    ///
    /// Shape matches what `jsonwebtoken::jwk::Jwk` expects:
    /// { "kty":"EC", "crv":"P-256", "x":"...", "y":"...", "alg":"ES256", "use":"sig", "kid":"..." }
    fn make_es256_public_jwk_json(signing_key: &SigningKey, kid: &str) -> Vec<u8> {
        let verifying_key = signing_key.verifying_key();
        let point = verifying_key.to_encoded_point(false); // uncompressed form

        let x = point.x().expect("x coordinate missing");
        let y = point.y().expect("y coordinate missing");

        serde_json::to_vec(&serde_json::json!({
            "kty": "EC",
            "crv": "P-256",
            "x": b64u(x),
            "y": b64u(y),
            "alg": "ES256",
            "use": "sig",
            "kid": kid,
        }))
        .expect("JWK should serialize")
    }

    fn new_es256_authority_and_encoding_key(kid: &str) -> (JwtAuthority, EncodingKey) {
        // Stable ES256 keypair
        let signing_key = SigningKey::random(&mut OsRng);

        // jsonwebtoken expects a DER-encoded EC private key for signing (PKCS#8 works well here).
        let pkcs8_der = signing_key
            .to_pkcs8_der()
            .expect("pkcs8 der should serialize");
        let encoding_key = EncodingKey::from_ec_der(pkcs8_der.as_bytes());

        // Public JWK JSON for verification side
        let jwk_json = make_es256_public_jwk_json(&signing_key, kid);
        let authority =
            JwtAuthority::from_jwk_json(&jwk_json).expect("authority should parse from JWK JSON");

        (authority, encoding_key)
    }

    #[test]
    fn test_parse_and_validate_jwt_svid() {
        let test_key_id = "test-key-id";

        let (authority, encoding_key) = new_es256_authority_and_encoding_key(test_key_id);

        let target_audience = vec!["audience".to_owned()];

        // generate signed token
        let token = generate_token(
            target_audience.clone(),
            "spiffe://example.org/service".to_string(),
            Some("JWT".to_string()),
            Some(test_key_id.to_string()),
            0xFFFF_FFFF,
            Algorithm::ES256,
            &encoding_key,
        );

        // create a new source of JWT bundles
        let mut bundle_source = JwtBundleSet::default();
        let trust_domain = TrustDomain::new("example.org").unwrap();
        let mut bundle = JwtBundle::new(trust_domain);

        bundle.add_jwt_authority(authority);
        bundle_source.add_bundle(bundle);

        // parse and validate JWT-SVID from signed token
        let jwt_svid = JwtSvid::parse_and_validate(&token, &bundle_source, &["audience"]).unwrap();

        assert_eq!(
            jwt_svid.spiffe_id,
            SpiffeId::new("spiffe://example.org/service").unwrap()
        );
        assert_eq!(jwt_svid.audience(), &target_audience);
        assert_eq!(jwt_svid.token(), token);
    }

    #[test]
    fn test_parse_jwt_svid_with_unsupported_algorithm() {
        let target_audience = vec!["audience".to_owned()];

        // HS256 is not in your SUPPORTED_ALGORITHMS => should error
        let token = generate_token(
            target_audience,
            "spiffe://example.org/service".to_string(),
            Some("JWT".to_string()),
            Some("some_key_id".to_string()),
            0xFFFF_FFFF,
            Algorithm::HS256,
            &EncodingKey::from_secret("secret".as_ref()),
        );

        let result = JwtSvid::parse_insecure(&token).unwrap_err();
        assert!(matches!(result, JwtSvidError::UnsupportedAlgorithm));
    }

    #[test]
    fn test_parse_and_validate_es512_fails_before_bundle_lookup() {
        // ES512 is accepted by parse_insecure but is currently unsupported by
        // offline verification with jsonwebtoken.
        let token = mk_token(
            r#"{"alg":"ES512","kid":"some_key_id"}"#,
            r#"{"sub":"spiffe://example.org/service","aud":"audience","exp":4294967295}"#,
        );

        // Unsupported algorithm should be reported before bundle lookup errors.
        let bundle_source = JwtBundleSet::default();
        let result =
            JwtSvid::parse_and_validate(&token, &bundle_source, &["audience"]).unwrap_err();
        assert!(matches!(
            result,
            JwtSvidError::BackendUnsupportedAlgorithm(JwtAlg::ES512)
        ));
    }

    #[test]
    fn test_parse_invalid_jwt_svid_without_key_id() {
        // kid is missing, but we still need a valid ES256 token for parse_insecure
        let (_authority, encoding_key) = new_es256_authority_and_encoding_key("ignored-kid");

        let target_audience = vec!["audience".to_owned()];

        let token = generate_token(
            target_audience,
            "spiffe://example.org/service".to_string(),
            Some("JWT".to_string()),
            None, // no kid
            0xFFFF_FFFF,
            Algorithm::ES256,
            &encoding_key,
        );

        let result = JwtSvid::parse_insecure(&token).unwrap_err();
        assert!(matches!(result, JwtSvidError::MissingKeyId));
    }

    #[test]
    fn test_parse_invalid_jwt_svid_with_invalid_header_typ() {
        let (_authority, encoding_key) = new_es256_authority_and_encoding_key("ignored-kid");

        let target_audience = vec!["audience".to_owned()];

        let token = generate_token(
            target_audience,
            "spiffe://example.org/service".to_string(),
            Some("OTHER".to_string()), // invalid typ
            Some("kid".to_string()),
            0xFFFF_FFFF,
            Algorithm::ES256,
            &encoding_key,
        );

        let result = JwtSvid::parse_insecure(&token).unwrap_err();
        assert!(matches!(result, JwtSvidError::InvalidTyp));
    }

    #[test]
    fn test_parse_and_validate_jwt_svid_from_expired_token() {
        let test_key_id = "test-key-id";

        let (authority, encoding_key) = new_es256_authority_and_encoding_key(test_key_id);

        let target_audience = vec!["audience".to_owned()];

        // expired token
        let token = generate_token(
            target_audience,
            "spiffe://example.org/service".to_string(),
            Some("JWT".to_string()),
            Some(test_key_id.to_string()),
            1, // exp in the past
            Algorithm::ES256,
            &encoding_key,
        );

        let mut bundle_source = JwtBundleSet::default();
        let trust_domain = TrustDomain::new("example.org").unwrap();
        let mut bundle = JwtBundle::new(trust_domain);

        bundle.add_jwt_authority(authority);
        bundle_source.add_bundle(bundle);

        let result =
            JwtSvid::parse_and_validate(&token, &bundle_source, &["audience"]).unwrap_err();

        assert!(matches!(result, JwtSvidError::InvalidToken(_)));
    }

    fn generate_token(
        aud: Vec<String>,
        sub: String,
        typ: Option<String>,
        kid: Option<String>,
        exp: i64,
        alg: Algorithm,
        encoding_key: &EncodingKey,
    ) -> String {
        let claims = Claims { sub, aud, exp };

        let mut header = Header::new(alg);
        header.typ = typ;
        header.kid = kid;

        encode(&header, &claims, encoding_key).unwrap()
    }

    /// Build an ES256 public JWK JSON with `use = "jwt-svid"` (SPIFFE-compliant).
    ///
    /// Per SPIFFE spec §4.2.2, the `use` field for JWT bundle keys is `"jwt-svid"`
    /// or `"x509-svid"` (not `"sig"` / `"enc"`).
    fn make_es256_public_jwk_json_with_use_jwt_svid(
        signing_key: &SigningKey,
        kid: &str,
    ) -> Vec<u8> {
        let verifying_key = signing_key.verifying_key();
        let point = verifying_key.to_encoded_point(false);

        let x = point.x().expect("x coordinate missing");
        let y = point.y().expect("y coordinate missing");

        serde_json::to_vec(&serde_json::json!({
            "kty": "EC",
            "crv": "P-256",
            "x": b64u(x),
            "y": b64u(y),
            "alg": "ES256",
            "use": "jwt-svid",
            "kid": kid,
        }))
        .expect("JWK should serialize")
    }

    /// Regression test: accept SPIFFE-compliant JWKs with `use = "jwt-svid"`.
    ///
    /// This test protects against rejecting valid SPIFFE JWT bundle keys due to
    /// non-SPIFFE expectations around the JWK `use` field.
    #[test]
    fn test_accepts_jwk_with_use_jwt_svid() {
        let kid = "test-key-id-jwt-svid";

        let signing_key = SigningKey::random(&mut OsRng);

        let pkcs8_der = signing_key
            .to_pkcs8_der()
            .expect("PKCS#8 DER serialization should succeed");
        let encoding_key = EncodingKey::from_ec_der(pkcs8_der.as_bytes());

        // Create JWK with SPIFFE-compliant `use`
        let jwk_json = make_es256_public_jwk_json_with_use_jwt_svid(&signing_key, kid);
        let authority = JwtAuthority::from_jwk_json(&jwk_json)
            .expect("issue regression: should accept JWK with use=jwt-svid");

        // Bundle set for trust domain
        let trust_domain = TrustDomain::new("example.org").expect("valid trust domain");
        let mut bundle = JwtBundle::new(trust_domain);
        bundle.add_jwt_authority(authority);

        let mut bundle_set = JwtBundleSet::default();
        bundle_set.add_bundle(bundle);

        let target_audience = vec!["audience".to_owned()];

        let exp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock before UNIX_EPOCH")
            .as_secs()
            + 300;

        let token = generate_token(
            target_audience.clone(),
            "spiffe://example.org/workload".to_string(),
            None,                  // typ
            Some(kid.to_string()), // kid
            exp.try_into().unwrap(),
            Algorithm::ES256,
            &encoding_key,
        );

        let svid = JwtSvid::parse_and_validate(&token, &bundle_set, &["audience"])
            .expect("issue regression: JWT-SVID signed by use=jwt-svid key should validate");

        assert_eq!(
            svid.spiffe_id().to_string(),
            "spiffe://example.org/workload"
        );
        assert_eq!(svid.audience(), &target_audience);
    }

    /// Security test: JWT `aud` claim array size must be bounded to prevent `DoS` attacks.
    ///
    /// This test verifies that tokens with excessive `aud` claim values are rejected,
    /// preventing `DoS` attacks through excessive memory allocation. The limit applies
    /// to the token's `aud` claim content, not the caller's `expected_audience` parameter.
    #[test]
    fn test_jwt_audience_claim_size_limit() {
        let kid = "test-key-id";
        let signing_key = SigningKey::random(&mut OsRng);
        let pkcs8_der = signing_key
            .to_pkcs8_der()
            .expect("PKCS#8 DER serialization should succeed");
        let encoding_key = EncodingKey::from_ec_der(pkcs8_der.as_bytes());

        let jwk_json = make_es256_public_jwk_json_with_use_jwt_svid(&signing_key, kid);
        let authority = JwtAuthority::from_jwk_json(&jwk_json).expect("valid JWK JSON");

        let trust_domain = TrustDomain::new("example.org").expect("valid trust domain");
        let mut bundle = JwtBundle::new(trust_domain);
        bundle.add_jwt_authority(authority);

        let mut bundle_set = JwtBundleSet::default();
        bundle_set.add_bundle(bundle);

        // Use a near-future expiration to avoid boundary flakiness around "now".
        let exp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock before UNIX_EPOCH")
            .as_secs()
            .saturating_add(60)
            .try_into()
            .unwrap();

        // Test with excessive `aud` claim values in token (MAX_JWT_AUDIENCE_COUNT is 32, so 33 should trigger)
        let excessive_audiences: Vec<String> = (0..33).map(|i| format!("aud{i}")).collect();
        let oversized_token = generate_token(
            excessive_audiences,
            "spiffe://example.org/workload".to_string(),
            None,
            Some(kid.to_string()),
            exp,
            Algorithm::ES256,
            &encoding_key,
        );

        // Should reject token with excessive `aud` claim values during parsing
        // (before expensive signature verification)
        let result = JwtSvid::parse_and_validate(&oversized_token, &bundle_set, &["aud0"]);
        assert!(
            matches!(result, Err(JwtSvidError::InvalidJson(_))),
            "should reject token with excessive `aud` claim array size during deserialization"
        );

        // Also verify parse_insecure rejects it early
        let result_insecure = JwtSvid::parse_insecure(&oversized_token);
        assert!(
            matches!(result_insecure, Err(JwtSvidError::InvalidJson(_))),
            "parse_insecure should reject oversized `aud` claim during deserialization"
        );

        // Verify that large expected_audience arrays from caller are still accepted (not rejected due to size)
        // Create a token with an audience that matches one in the large expected_audience list
        let matching_audience = "expected50".to_string();
        let matching_token_audiences = vec![matching_audience];
        let matching_token = generate_token(
            matching_token_audiences,
            "spiffe://example.org/workload".to_string(),
            None,
            Some(kid.to_string()),
            exp,
            Algorithm::ES256,
            &encoding_key,
        );

        // Large expected_audience parameter should not cause rejection - validation should succeed
        let large_expected_audiences: Vec<String> =
            (0..100).map(|i| format!("expected{i}")).collect();
        let result =
            JwtSvid::parse_and_validate(&matching_token, &bundle_set, &large_expected_audiences);
        assert!(
            result.is_ok(),
            "large expected_audience array should be accepted when audiences match"
        );
    }
}
