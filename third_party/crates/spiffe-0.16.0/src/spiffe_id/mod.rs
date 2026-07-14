//! SPIFFE-ID and `TrustDomain` types compliant with the SPIFFE standard.

use std::fmt;
use std::fmt::{Display, Formatter};
use std::str::FromStr;

use thiserror::Error;

/// The canonical URI scheme name for SPIFFE IDs (`spiffe`).
///
/// Defined by the SPIFFE specification.
pub const SPIFFE_SCHEME: &str = "spiffe";

/// The URI prefix used by SPIFFE IDs.
///
/// This is equivalent to `"{SPIFFE_SCHEME}://"` in canonical lowercase. For
/// case-insensitive scheme detection, use [`uri_has_spiffe_scheme`].
pub const SPIFFE_SCHEME_PREFIX: &str = "spiffe://";

/// Returns `true` if `uri` begins with `scheme://` where `scheme` is `spiffe` (ASCII case-insensitive).
///
/// Use for early filtering (e.g. URI SAN entries) before [`SpiffeId::new`]; full validation still
/// happens during parse.
pub fn uri_has_spiffe_scheme(uri: &str) -> bool {
    uri.split_once("://")
        .is_some_and(|(scheme, _)| scheme.eq_ignore_ascii_case(SPIFFE_SCHEME))
}

/// Recommended maximum length for a generated SPIFFE ID URI in bytes, including
/// the `spiffe://` prefix.
///
/// Per SPIFFE specification: "SPIFFE implementations MUST support SPIFFE URIs up to 2048 bytes
/// in length and SHOULD NOT generate URIs of length greater than 2048 bytes."
///
/// This implementation uses the limit when constructing SPIFFE IDs from path
/// segments in `SpiffeId::from_segments`.
/// See: <https://github.com/spiffe/spiffe/blob/main/standards/SPIFFE-ID.md#23-maximum-spiffe-id-length>
const MAX_SPIFFE_ID_URI_LENGTH: usize = 2048;

/// Maximum length for a SPIFFE trust domain name in bytes.
///
/// The SPIFFE ID specification states that the maximum length of a trust domain
/// name is 255 bytes.
const MAX_TRUST_DOMAIN_LENGTH: usize = 255;

/// A validated [SPIFFE ID].
///
/// Guarantees that the contained trust domain and path conform to
/// the SPIFFE ID specification:
/// <https://github.com/spiffe/spiffe/blob/main/standards/SPIFFE-ID.md#2-spiffe-identity>.
///
/// Instances of `SpiffeId` are always valid and can be safely compared,
/// formatted, and reused across the API.
#[derive(Debug, Clone, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct SpiffeId {
    trust_domain: TrustDomain,
    path: String,
}

/// A validated SPIFFE trust domain.
///
/// A `TrustDomain` represents the authority component of a SPIFFE ID and
/// is guaranteed to contain only characters allowed by the SPIFFE
/// specification:
/// <https://github.com/spiffe/spiffe/blob/main/standards/SPIFFE-ID.md#21-trust-domain>.
///
/// Trust domains are **case-insensitive** per the SPIFFE specification.
/// This type stores and exposes trust domains in a **canonical lowercase
/// representation**. Inputs containing uppercase ASCII letters are accepted
/// and normalized to lowercase; other disallowed characters are rejected with
/// [`SpiffeIdError::BadTrustDomainChar`].
#[derive(Debug, Clone, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct TrustDomain {
    name: String,
}

/// Errors that can arise parsing a SPIFFE ID.
#[derive(Debug, Error, PartialEq, Clone)]
#[non_exhaustive]
pub enum SpiffeIdError {
    /// An empty string cannot be parsed as a SPIFFE ID.
    #[error("cannot be empty")]
    Empty,

    /// The trust domain name of SPIFFE ID cannot be empty.
    #[error("trust domain is missing")]
    MissingTrustDomain,

    /// A SPIFFE ID must have a scheme 'spiffe'.
    #[error("scheme is missing or invalid")]
    WrongScheme,

    /// A trust domain name can only contain chars in a limited char set.
    #[error(
        "trust domain may only contain ASCII letters (case-insensitive), digits, dots, dashes, and \
         underscores"
    )]
    BadTrustDomainChar,

    /// A path segment can only contain chars in a limited char set.
    #[error(
        "path segment characters are limited to letters, numbers, dots, dashes, and underscores"
    )]
    BadPathSegmentChar,

    /// Path cannot contain empty segments, e.g '//'
    #[error("path cannot contain empty segments")]
    EmptySegment,

    /// Path cannot contain dot segments, e.g '/.', '/..'
    #[error("path cannot contain dot segments")]
    DotSegment,

    /// Path cannot have a trailing slash.
    #[error("path cannot have a trailing slash")]
    TrailingSlash,

    /// Constructed SPIFFE ID URI exceeds the library's maximum length policy.
    #[error("SPIFFE ID URI exceeds maximum length ({max} bytes)")]
    SpiffeIdTooLong {
        /// Maximum allowed length for a SPIFFE ID URI.
        max: usize,
    },

    /// Trust domain name exceeds maximum allowed length.
    #[error("trust domain exceeds maximum length ({max} bytes)")]
    TrustDomainTooLong {
        /// Maximum allowed length for a trust domain name.
        max: usize,
    },
}

impl SpiffeId {
    /// Attempts to parse a SPIFFE ID from the given id string.
    ///
    /// # Arguments
    ///
    /// * `id` - A SPIFFE ID, e.g. `spiffe://trustdomain/path/other`
    ///
    /// # Errors
    ///
    /// If the function cannot parse the input as a SPIFFE ID, a [`SpiffeIdError`] variant will be returned.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::SpiffeId;
    ///
    /// let spiffe_id = SpiffeId::new("spiffe://trustdomain/path").unwrap();
    /// assert_eq!("trustdomain", spiffe_id.trust_domain().to_string());
    /// assert_eq!("/path", spiffe_id.path());
    /// ```
    pub fn new(id: impl AsRef<str>) -> Result<Self, SpiffeIdError> {
        let id = id.as_ref();
        if id.is_empty() {
            return Err(SpiffeIdError::Empty);
        }

        let rest = strip_spiffe_scheme(id)?;

        let (td, path) = match rest.find('/') {
            Some(idx) => rest.split_at(idx),
            None => (rest, ""),
        };

        if td.is_empty() {
            return Err(SpiffeIdError::MissingTrustDomain);
        }

        // Normalize the trust domain to lowercase while validating allowed characters.
        let canonical_td = normalize_trust_domain_to_lower(td)?;

        if !path.is_empty() {
            validate_path(path)?;
        }

        Ok(Self {
            trust_domain: TrustDomain { name: canonical_td },
            path: path.to_string(),
        })
    }

    /// Returns a new SPIFFE ID in the given trust domain with joined
    /// path segments. The path segments must be valid according to the SPIFFE
    /// specification and must not contain path separators.
    /// See `https://github.com/spiffe/spiffe/blob/main/standards/SPIFFE-ID.md#22-path`
    ///
    /// # Arguments
    ///
    /// * `trust_domain` - A [`TrustDomain`] object.
    /// * `segments` - A slice of path segments.
    ///
    /// # Errors
    ///
    /// If the segments contain not allowed characters, a [`SpiffeIdError`] variant will be returned.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::{SpiffeId, TrustDomain};
    ///
    /// let trust_domain = TrustDomain::new("trustdomain").unwrap();
    /// let spiffe_id = SpiffeId::from_segments(trust_domain, &["path1", "path2", "path3"]).unwrap();
    /// assert_eq!(
    ///     "spiffe://trustdomain/path1/path2/path3",
    ///     spiffe_id.to_string()
    /// );
    /// ```
    pub fn from_segments(
        trust_domain: TrustDomain,
        segments: &[&str],
    ) -> Result<Self, SpiffeIdError> {
        if segments.is_empty() {
            return Ok(Self {
                trust_domain,
                path: String::new(),
            });
        }

        let total_len: usize = segments.iter().map(|s| s.len()).sum::<usize>() + segments.len();
        let mut path = String::with_capacity(total_len);

        for seg in segments {
            validate_segment(seg)?;
            path.push('/');
            path.push_str(seg);
        }

        // Enforce the library's construction-time SPIFFE ID URI length policy.
        let uri_len = SPIFFE_SCHEME_PREFIX.len() + trust_domain.as_str().len() + path.len();
        if uri_len > MAX_SPIFFE_ID_URI_LENGTH {
            return Err(SpiffeIdError::SpiffeIdTooLong {
                max: MAX_SPIFFE_ID_URI_LENGTH,
            });
        }

        Ok(Self { trust_domain, path })
    }

    /// Returns the trust domain of the SPIFFE ID.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::{SpiffeId, TrustDomain};
    ///
    /// let spiffe_id = SpiffeId::new("spiffe://example.org/service")?;
    /// let trust_domain = spiffe_id.trust_domain();
    /// assert_eq!(trust_domain.to_string(), "example.org");
    /// # Ok::<(), Box<dyn std::error::Error>>(())
    /// ```
    pub const fn trust_domain(&self) -> &TrustDomain {
        &self.trust_domain
    }

    /// Returns the trust domain name of this SPIFFE ID.
    ///
    /// This is equivalent to `self.trust_domain().as_str()` and does not
    /// allocate. The returned string is guaranteed to be a valid SPIFFE
    /// trust domain.
    pub fn trust_domain_name(&self) -> &str {
        self.trust_domain.as_str()
    }

    /// Returns the path of the SPIFFE ID.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::SpiffeId;
    ///
    /// let spiffe_id = SpiffeId::new("spiffe://example.org/service/api")?;
    /// assert_eq!(spiffe_id.path(), "/service/api");
    ///
    /// let spiffe_id = SpiffeId::new("spiffe://example.org")?;
    /// assert_eq!(spiffe_id.path(), "");
    /// # Ok::<(), Box<dyn std::error::Error>>(())
    /// ```
    pub fn path(&self) -> &str {
        &self.path
    }

    /// Returns `true` if this SPIFFE ID has the given `TrustDomain`.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::{SpiffeId, TrustDomain};
    ///
    /// let spiffe_id = SpiffeId::new("spiffe://example.org/service")?;
    /// let trust_domain = TrustDomain::new("example.org")?;
    /// assert!(spiffe_id.is_member_of(&trust_domain));
    ///
    /// let other_domain = TrustDomain::new("other.org")?;
    /// assert!(!spiffe_id.is_member_of(&other_domain));
    /// # Ok::<(), Box<dyn std::error::Error>>(())
    /// ```
    pub fn is_member_of(&self, trust_domain: &TrustDomain) -> bool {
        &self.trust_domain == trust_domain
    }
}

impl Display for SpiffeId {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        write!(f, "{}://{}{}", SPIFFE_SCHEME, self.trust_domain, self.path)
    }
}

impl FromStr for SpiffeId {
    type Err = SpiffeIdError;

    fn from_str(id: &str) -> Result<Self, Self::Err> {
        Self::new(id)
    }
}

impl TryFrom<String> for SpiffeId {
    type Error = SpiffeIdError;
    fn try_from(s: String) -> Result<Self, Self::Error> {
        Self::new(&s)
    }
}

impl TryFrom<&str> for SpiffeId {
    type Error = SpiffeIdError;
    fn try_from(s: &str) -> Result<Self, Self::Error> {
        Self::new(s)
    }
}

impl TrustDomain {
    /// Attempts to parse a `TrustDomain` instance from the given name or `spiffe_id` string.
    ///
    /// # Arguments
    ///
    /// * `id_or_name` - Name of a trust domain, it also can be a SPIFFE ID string from which the domain name
    ///   is extracted.
    ///
    /// # Errors
    ///
    /// If the function cannot parse the input as a Trust domain, a [`SpiffeIdError`] variant will be returned.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::TrustDomain;
    ///
    /// let trust_domain = TrustDomain::new("domain.test").unwrap();
    /// assert_eq!("domain.test", trust_domain.to_string());
    /// assert_eq!("spiffe://domain.test", trust_domain.id_string());
    ///
    /// let trust_domain = TrustDomain::new("spiffe://example.org/path").unwrap();
    /// assert_eq!("example.org", trust_domain.to_string());
    /// assert_eq!("spiffe://example.org", trust_domain.id_string());
    /// ```
    pub fn new(id_or_name: impl AsRef<str>) -> Result<Self, SpiffeIdError> {
        let id_or_name = id_or_name.as_ref();

        if id_or_name.is_empty() {
            return Err(SpiffeIdError::MissingTrustDomain);
        }

        // Any input containing `://` is treated as a `scheme://...` URI: we require
        // the scheme to be `spiffe` (ASCII case-insensitive) via `strip_spiffe_scheme`;
        // other schemes (e.g. `http://...`) yield [`SpiffeIdError::WrongScheme`].
        if id_or_name.contains("://") {
            let rest = strip_spiffe_scheme(id_or_name)?;

            let td = rest.split_once('/').map_or(rest, |(td, _path)| td);

            if td.is_empty() {
                return Err(SpiffeIdError::MissingTrustDomain);
            }

            let name = normalize_trust_domain_to_lower(td)?;

            return Ok(Self { name });
        }

        if id_or_name.contains(":/") {
            return Err(SpiffeIdError::WrongScheme);
        }

        let name = normalize_trust_domain_to_lower(id_or_name)?;
        Ok(Self { name })
    }

    /// Returns the trust domain name as a string slice.
    ///
    /// This is a borrowed view into the underlying trust domain and does not
    /// allocate. The returned string is guaranteed to be a valid SPIFFE
    /// trust domain according to the specification.
    pub fn as_str(&self) -> &str {
        &self.name
    }

    /// Returns a string representation of the SPIFFE ID of the trust domain,
    /// e.g. `spiffe://example.org`.
    pub fn id_string(&self) -> String {
        let mut s = String::with_capacity(SPIFFE_SCHEME_PREFIX.len() + self.name.len());
        s.push_str(SPIFFE_SCHEME_PREFIX);
        s.push_str(&self.name);
        s
    }
}

impl Display for TrustDomain {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.name)
    }
}

impl AsRef<str> for TrustDomain {
    fn as_ref(&self) -> &str {
        self.name.as_str()
    }
}

impl FromStr for TrustDomain {
    type Err = SpiffeIdError;

    fn from_str(name: &str) -> Result<Self, Self::Err> {
        Self::new(name)
    }
}

impl TryFrom<&str> for TrustDomain {
    type Error = SpiffeIdError;

    fn try_from(name: &str) -> Result<Self, Self::Error> {
        Self::new(name)
    }
}

impl TryFrom<String> for TrustDomain {
    type Error = SpiffeIdError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        Self::new(value)
    }
}

#[inline]
const fn is_valid_trust_domain_byte(b: u8) -> bool {
    matches!(b, b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_')
}

#[inline]
const fn is_valid_path_segment_byte(b: u8) -> bool {
    matches!(b, b'a'..=b'z' | b'A'..=b'Z' | b'0'..=b'9' | b'-' | b'.' | b'_')
}

fn validate_segment(seg: impl AsRef<str>) -> Result<(), SpiffeIdError> {
    let seg = seg.as_ref();

    if seg.is_empty() {
        return Err(SpiffeIdError::EmptySegment);
    }

    if seg.as_bytes().contains(&b'/') {
        return Err(SpiffeIdError::BadPathSegmentChar);
    }

    if seg == "." || seg == ".." {
        return Err(SpiffeIdError::DotSegment);
    }

    if !seg
        .as_bytes()
        .iter()
        .all(|&b| is_valid_path_segment_byte(b))
    {
        return Err(SpiffeIdError::BadPathSegmentChar);
    }

    Ok(())
}

/// Validates that a path string is a conformant SPIFFE ID path.
///
/// Requirements enforced:
/// - non-empty
/// - begins with '/'
/// - no trailing '/'
/// - no empty segments ('//')
/// - no dot segments ('/.', '/..')
/// - only allowed ASCII chars in segments
///
/// Note: This validates only path format. `SpiffeId::new` does not reject based
/// on total URI length.
fn validate_path(path: &str) -> Result<(), SpiffeIdError> {
    if path.is_empty() {
        return Err(SpiffeIdError::Empty);
    }

    let mut segments = path.split('/');

    if !segments.next().is_some_and(str::is_empty) {
        return Err(SpiffeIdError::BadPathSegmentChar);
    }

    let mut segments = segments.peekable();

    while let Some(segment) = segments.next() {
        if segment.is_empty() {
            return Err(if segments.peek().is_some() {
                SpiffeIdError::EmptySegment
            } else {
                SpiffeIdError::TrailingSlash
            });
        }

        if segment == "." || segment == ".." {
            return Err(SpiffeIdError::DotSegment);
        }

        if !segment
            .as_bytes()
            .iter()
            .all(|&b| is_valid_path_segment_byte(b))
        {
            return Err(SpiffeIdError::BadPathSegmentChar);
        }
    }

    Ok(())
}

fn strip_spiffe_scheme(id: &str) -> Result<&str, SpiffeIdError> {
    let (scheme, rest) = id.split_once("://").ok_or(SpiffeIdError::WrongScheme)?;

    if !scheme.eq_ignore_ascii_case(SPIFFE_SCHEME) {
        return Err(SpiffeIdError::WrongScheme);
    }

    Ok(rest)
}

fn normalize_trust_domain_to_lower(raw: &str) -> Result<String, SpiffeIdError> {
    if raw.len() > MAX_TRUST_DOMAIN_LENGTH {
        return Err(SpiffeIdError::TrustDomainTooLong {
            max: MAX_TRUST_DOMAIN_LENGTH,
        });
    }

    // Normalize to lowercase while validating that all characters are in the
    // allowed trust-domain character set after normalization.
    //
    // This permits mixed-case ASCII letters in input while keeping the internal
    // representation canonical and rejecting non-ASCII / disallowed characters.
    let mut out = String::with_capacity(raw.len());

    for b in raw.bytes() {
        // Convert ASCII uppercase letters to lowercase; leave all other bytes as-is.
        let lb = if b.is_ascii_uppercase() {
            b + (b'a' - b'A')
        } else {
            b
        };

        if !is_valid_trust_domain_byte(lb) {
            return Err(SpiffeIdError::BadTrustDomainChar);
        }

        out.push(char::from(lb));
    }

    Ok(out)
}

#[cfg(test)]
mod spiffe_id_tests {
    use super::*;

    macro_rules! spiffe_id_success_tests {
        ($($name:ident: $value:expr_2021,)*) => {
        $(
            #[test]
            fn $name() {
                let (input, expected) = $value;
                let spiffe_id = SpiffeId::from_str(input).unwrap();
                assert_eq!(spiffe_id, expected);
            }
        )*
        }
    }

    spiffe_id_success_tests! {
        from_valid_spiffe_id_str: (
            "spiffe://trustdomain",
            SpiffeId {
                trust_domain: TrustDomain::from_str("trustdomain").unwrap(),
                path: String::new(),
            }
        ),
        from_valid_uri_str: (
            "spiffe://trustdomain/path/element",
            SpiffeId {
                trust_domain: TrustDomain::from_str("trustdomain").unwrap(),
                path: "/path/element".to_string(),
            }
        ),
        from_mixed_case_scheme_and_trust_domain: (
            "SpIfFe://Example.Org/path",
            SpiffeId {
                trust_domain: TrustDomain::from_str("example.org").unwrap(),
                path: "/path".to_string(),
            }
        ),
    }

    #[test]
    fn uri_has_spiffe_scheme_case_insensitive() {
        assert!(uri_has_spiffe_scheme("spiffe://example.org/p"));
        assert!(uri_has_spiffe_scheme("SPIFFE://example.org/p"));
        assert!(uri_has_spiffe_scheme("SpIfFe://example.org/p"));
        assert!(!uri_has_spiffe_scheme("https://example.org"));
        assert!(!uri_has_spiffe_scheme("spiffe:example.org"));
    }

    #[test]
    fn test_is_member_of() {
        let spiffe_id = SpiffeId::from_str("spiffe://example.org").unwrap();
        let trust_domain = TrustDomain::from_str("example.org").unwrap();

        assert!(spiffe_id.is_member_of(&trust_domain));
    }

    #[test]
    fn test_new_from_string() {
        let id_string = String::from("spiffe://example.org/path/element");
        let spiffe_id = SpiffeId::try_from(id_string).unwrap();

        let expected_trust_domain = TrustDomain::from_str("example.org").unwrap();

        assert_eq!(spiffe_id.trust_domain, expected_trust_domain);
        assert_eq!(spiffe_id.path(), "/path/element");
    }

    #[test]
    fn test_to_string() {
        let spiffe_id = SpiffeId::from_str("spiffe://example.org/path/element").unwrap();
        assert_eq!(spiffe_id.to_string(), "spiffe://example.org/path/element");
    }

    #[test]
    fn test_to_string_canonicalizes_scheme_and_trust_domain_only() {
        let spiffe_id = SpiffeId::from_str("SPIFFE://EXAMPLE.ORG/MyService").unwrap();
        assert_eq!(spiffe_id.to_string(), "spiffe://example.org/MyService");
    }

    #[test]
    fn test_try_from_str() {
        let spiffe_id = SpiffeId::try_from("spiffe://example.org/path").unwrap();

        assert_eq!(
            spiffe_id.trust_domain,
            TrustDomain::from_str("example.org").unwrap()
        );
        assert_eq!(spiffe_id.path, "/path");
    }

    #[test]
    fn test_try_from_string() {
        let spiffe_id = SpiffeId::try_from(String::from("spiffe://example.org/path")).unwrap();

        assert_eq!(
            spiffe_id.trust_domain,
            TrustDomain::from_str("example.org").unwrap()
        );
        assert_eq!(spiffe_id.path, "/path");
    }

    #[test]
    fn test_equality_is_scheme_and_trust_domain_insensitive_but_path_sensitive() {
        let canonical = SpiffeId::from_str("spiffe://example.org/service").unwrap();
        let mixed_scheme = SpiffeId::from_str("SPIFFE://example.org/service").unwrap();
        let mixed_td = SpiffeId::from_str("spiffe://EXAMPLE.ORG/service").unwrap();
        let mixed_both = SpiffeId::from_str("SPIFFE://EXAMPLE.ORG/service").unwrap();
        let different_path_case = SpiffeId::from_str("spiffe://example.org/Service").unwrap();

        assert_eq!(canonical, mixed_scheme);
        assert_eq!(canonical, mixed_td);
        assert_eq!(canonical, mixed_both);
        assert_ne!(canonical, different_path_case);
    }

    macro_rules! spiffe_id_error_tests {
        ($($name:ident: $value:expr_2021,)*) => {
        $(
            #[test]
            fn $name() {
            let (input, expected_error) = $value;
                let spiffe_id = SpiffeId::from_str(input);
                let error = spiffe_id.unwrap_err();

                assert_eq!(error, expected_error);
            }
        )*
        }
    }

    spiffe_id_error_tests! {
        from_empty_str: ("", SpiffeIdError::Empty),
        from_str_invalid_uri_str_contains_ip_address: (
            "192.168.2.2:6688",
            SpiffeIdError::WrongScheme,
        ),
        from_str_uri_str_invalid_scheme: (
            "http://domain.test/path/element",
            SpiffeIdError::WrongScheme,
        ),
        from_str_uri_str_empty_authority: (
            "spiffe:/path/element",
            SpiffeIdError::WrongScheme,
        ),
        from_str_uri_str_empty_authority_after_slashes: (
            "spiffe:///path/element",
            SpiffeIdError::MissingTrustDomain,
        ),
        from_str_uri_str_empty_authority_no_slashes: (
            "spiffe:path/element",
            SpiffeIdError::WrongScheme,
        ),
        from_str_uri_str_with_query: (
            "spiffe://domain.test/path/element?query=1",
            SpiffeIdError::BadPathSegmentChar,
        ),
        from_str_uri_str_with_fragment: (
            "spiffe://domain.test/path/element#fragment-1",
            SpiffeIdError::BadPathSegmentChar,
        ),
        from_str_uri_str_with_port: (
            "spiffe://domain.test:8080/path/element",
            SpiffeIdError::BadTrustDomainChar,
        ),
        from_str_uri_str_with_user_info: (
            "spiffe://user:password@test.org/path/element",
            SpiffeIdError::BadTrustDomainChar,
        ),
        from_str_uri_str_with_trailing_slash: (
            "spiffe://test.org/",
            SpiffeIdError::TrailingSlash,
        ),
        from_str_uri_str_with_trailing_emtpy_segment: (
            "spiffe://test.org//",
            SpiffeIdError::EmptySegment,
        ),
        from_str_uri_str_with_emtpy_segment_: (
            "spiffe://test.org/path//other",
            SpiffeIdError::EmptySegment,
        ),
        from_str_uri_str_with_path_with_trailing_slash: (
            "spiffe://test.org/path/other/",
            SpiffeIdError::TrailingSlash,
        ),
        from_str_uri_str_with_dot_segment: (
            "spiffe://test.org/./other",
            SpiffeIdError::DotSegment,
        ),
        from_str_uri_str_with_double_dot_segment: (
            "spiffe://test.org/../other",
            SpiffeIdError::DotSegment,
        ),
    }

    #[test]
    fn test_parse_with_all_bytes() {
        // Iterate all byte values to ensure we reject non-ASCII and only accept the allowed ASCII set.
        for b in 0u8..=255u8 {
            // Build a UTF-8 string containing this byte.
            // For 0..=127 this is a single ASCII char.
            // For 128..=255 this becomes a Unicode scalar value U+0080..U+00FF encoded as UTF-8,
            // which our ASCII-only validators must reject.
            let c = char::from(b);

            // '/' is the delimiter between path segments
            if c == '/' {
                continue;
            }

            let path = format!("/path{c}");
            let id = format!("spiffe://trustdomain{path}");

            // Expect validity only for allowed ASCII path-segment chars.
            let expect_path_ok = c.is_ascii()
                && matches!(
                    b,
                    b'a'..=b'z'
                        | b'A'..=b'Z'
                        | b'0'..=b'9'
                        | b'-'
                        | b'.'
                        | b'_'
                );

            if expect_path_ok {
                let spiffe_id = SpiffeId::new(&id).unwrap();
                assert_eq!(spiffe_id.to_string(), id);
            } else {
                assert_eq!(
                    SpiffeId::new(&id).unwrap_err(),
                    SpiffeIdError::BadPathSegmentChar
                );
            }

            let td = format!("spiffe://trustdomain{c}");

            // Expect validity only for allowed ASCII trust-domain chars, treating
            // ASCII letters case-insensitively (upper-case is normalized).
            let expect_td_ok = c.is_ascii()
                && matches!(
                    b.to_ascii_lowercase(),
                    b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_'
                );

            if expect_td_ok {
                let spiffe_id = SpiffeId::new(&td).unwrap();
                // Trust domain is canonicalized to lowercase; path (none here) is preserved.
                let expected = format!("spiffe://trustdomain{}", c.to_ascii_lowercase());
                assert_eq!(spiffe_id.to_string(), expected);
            } else {
                assert_eq!(
                    SpiffeId::new(&td).unwrap_err(),
                    SpiffeIdError::BadTrustDomainChar
                );
            }
        }
    }

    #[test]
    fn test_from_segments_uri_length_limit() {
        let td = TrustDomain::new("example.org").unwrap();
        let base_len = SPIFFE_SCHEME_PREFIX.len() + td.as_str().len();
        let per_seg = 2usize; // "/a"

        // Max number of "/a" segments that still fits.
        let allowed_seg_count = (MAX_SPIFFE_ID_URI_LENGTH - base_len) / per_seg;

        // One more segment should exceed the limit.
        let overflow_seg_count = allowed_seg_count + 1;

        let allowed: Vec<&str> = vec!["a"; allowed_seg_count];
        let overflow: Vec<&str> = vec!["a"; overflow_seg_count];

        SpiffeId::from_segments(td.clone(), &allowed).unwrap();
        assert!(matches!(
            SpiffeId::from_segments(td, &overflow),
            Err(SpiffeIdError::SpiffeIdTooLong { .. })
        ));
    }

    #[test]
    fn test_from_segments_rejects_empty_segment() {
        let trust_domain = TrustDomain::new("example.org").unwrap();
        assert_eq!(
            SpiffeId::from_segments(trust_domain, &[""]).unwrap_err(),
            SpiffeIdError::EmptySegment
        );
    }

    #[test]
    fn test_from_segments_rejects_dot_segments() {
        let trust_domain = TrustDomain::new("example.org").unwrap();
        assert_eq!(
            SpiffeId::from_segments(trust_domain.clone(), &["."]).unwrap_err(),
            SpiffeIdError::DotSegment
        );
        assert_eq!(
            SpiffeId::from_segments(trust_domain, &[".."]).unwrap_err(),
            SpiffeIdError::DotSegment
        );
    }

    #[test]
    fn test_from_segments_rejects_embedded_slash() {
        let trust_domain = TrustDomain::new("example.org").unwrap();
        assert_eq!(
            SpiffeId::from_segments(trust_domain, &["foo/bar"]).unwrap_err(),
            SpiffeIdError::BadPathSegmentChar
        );
    }

    #[test]
    fn test_from_segments_preserves_path_case() {
        let trust_domain = TrustDomain::new("example.org").unwrap();
        let spiffe_id = SpiffeId::from_segments(trust_domain, &["MyService"]).unwrap();
        assert_eq!(spiffe_id.path(), "/MyService");
        assert_eq!(spiffe_id.to_string(), "spiffe://example.org/MyService");
    }

    #[test]
    fn test_ipv4_trust_domain_is_accepted() {
        let spiffe_id = SpiffeId::from_str("spiffe://1.2.3.4/service").unwrap();
        assert_eq!(spiffe_id.trust_domain_name(), "1.2.3.4");
        assert_eq!(spiffe_id.path(), "/service");
        assert_eq!(spiffe_id.to_string(), "spiffe://1.2.3.4/service");
    }

    #[test]
    fn test_underscore_trust_domain_is_accepted() {
        let spiffe_id = SpiffeId::from_str("spiffe://a_b.example/foo").unwrap();
        assert_eq!(spiffe_id.trust_domain_name(), "a_b.example");
        assert_eq!(spiffe_id.path(), "/foo");
    }

    #[test]
    fn test_from_segments_with_all_bytes() {
        // Iterate all byte values; for 128..=255 this produces non-ASCII UTF-8,
        // which must be rejected by ASCII-only validation.
        for b in 0u8..=255u8 {
            let c = char::from(b);

            let seg = format!("path{c}");
            let trust_domain = TrustDomain::new("trustdomain").unwrap();

            let expect_ok = c.is_ascii()
                && matches!(
                    b,
                    b'a'..=b'z'
                        | b'A'..=b'Z'
                        | b'0'..=b'9'
                        | b'-'
                        | b'.'
                        | b'_'
                );

            if expect_ok {
                let spiffe_id =
                    SpiffeId::from_segments(trust_domain.clone(), &[seg.as_str()]).unwrap();
                assert_eq!(spiffe_id.to_string(), format!("spiffe://trustdomain/{seg}"));
            } else {
                assert_eq!(
                    SpiffeId::from_segments(trust_domain.clone(), &[seg.as_str()]).unwrap_err(),
                    SpiffeIdError::BadPathSegmentChar
                );
            }
        }
    }
}

#[cfg(test)]
mod trust_domain_tests {
    use super::*;

    macro_rules! trust_domain_success_tests {
        ($($name:ident: $value:expr_2021,)*) => {
        $(
            #[test]
            fn $name() {
                let (input, expected) = $value;
                let trust_domain = TrustDomain::new(input).unwrap();
                assert_eq!(trust_domain, expected);
            }
        )*
        }
    }

    trust_domain_success_tests! {
        from_str_domain: ("trustdomain", TrustDomain{name: "trustdomain".to_string()}),
        from_str_spiffeid: ("spiffe://other.test", TrustDomain{name: "other.test".to_string()}),
        from_str_spiffeid_with_path: ("spiffe://domain.test/path/element", TrustDomain{name: "domain.test".to_string()}),
        from_mixed_case_domain: ("Example.Org", TrustDomain{name: "example.org".to_string()}),
        from_mixed_case_spiffeid: ("SpIfFe://Example.Org/Service", TrustDomain{name: "example.org".to_string()}),
    }

    macro_rules! trust_domain_error_tests {
        ($($name:ident: $value:expr_2021,)*) => {
        $(
            #[test]
            fn $name() {
                let (input, expected_error) = $value;
                let trust_domain = TrustDomain::new(input);
                let error = trust_domain.unwrap_err();
                assert_eq!(error, expected_error);
            }
        )*
        }
    }

    trust_domain_error_tests! {
        from_empty_str: ("", SpiffeIdError::MissingTrustDomain),
        from_invalid_scheme:  ("other://domain.test", SpiffeIdError::WrongScheme),
        from_uri_with_port: ("spiffe://domain.test:80", SpiffeIdError::BadTrustDomainChar),
        from_uri_with_userinfo: ("spiffe://user:pass@domain.test", SpiffeIdError::BadTrustDomainChar),
        from_uri_with_invalid_domain: ("spiffe:// domain.test", SpiffeIdError::BadTrustDomainChar),
        from_uri_with_empty_scheme: ("://domain.test", SpiffeIdError::WrongScheme),
        from_uri_with_empty_domain: ("spiffe:///path", SpiffeIdError::MissingTrustDomain),
    }

    #[test]
    fn test_equals() {
        let td_1 = TrustDomain::new("domain.test").unwrap();
        let td_2 = TrustDomain::new("domain.test").unwrap();
        assert_eq!(td_1, td_2);
    }

    #[test]
    fn test_not_equals() {
        let td_1 = TrustDomain::new("domain.test").unwrap();
        let td_2 = TrustDomain::new("other.test").unwrap();
        assert_ne!(td_1, td_2);
    }

    #[test]
    fn test_trust_domain_accepts_ipv4_dotted_quad() {
        let trust_domain = TrustDomain::from_str("1.2.3.4").unwrap();
        assert_eq!(trust_domain.to_string(), "1.2.3.4");
    }

    #[test]
    fn test_trust_domain_accepts_underscore() {
        let trust_domain = TrustDomain::from_str("a_b.example").unwrap();
        assert_eq!(trust_domain.to_string(), "a_b.example");
    }

    #[test]
    fn test_trust_domain_accepts_spec_non_dns_shapes() {
        for input in [
            "example..org",
            ".example.org",
            "example.org.",
            "-example.org",
            "example-.org",
        ] {
            let trust_domain = TrustDomain::from_str(input).unwrap();
            assert_eq!(trust_domain.as_str(), input);
        }
    }

    #[test]
    fn test_to_string() {
        let trust_domain = TrustDomain::from_str("spiffe://example.org").unwrap();
        assert_eq!(trust_domain.to_string(), "example.org");
    }

    #[test]
    fn test_to_id_string() {
        let trust_domain = TrustDomain::from_str("example.org").unwrap();
        assert_eq!(trust_domain.id_string(), "spiffe://example.org");
    }

    #[test]
    fn test_try_from_str() {
        let trust_domain = TrustDomain::try_from("example.org").unwrap();
        assert_eq!(trust_domain.to_string(), "example.org");
    }

    #[test]
    fn test_try_from_string() {
        let trust_domain = TrustDomain::try_from(String::from("example.org")).unwrap();
        assert_eq!(trust_domain.to_string(), "example.org");
    }

    #[test]
    fn test_trust_domain_parse_with_all_bytes() {
        // Iterate all byte values; for 128..=255 this produces non-ASCII UTF-8,
        // which must be rejected by ASCII-only trust-domain validation.
        for b in 0u8..=255u8 {
            let c = char::from(b);
            let td = format!("trustdomain{c}");

            let expect_ok = c.is_ascii()
                && matches!(
                    b.to_ascii_lowercase(),
                    b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_'
                );

            if expect_ok {
                let trust_domain = TrustDomain::new(&td).unwrap();
                // TrustDomain is canonicalized to lowercase.
                let expected = format!("trustdomain{}", c.to_ascii_lowercase());
                assert_eq!(trust_domain.to_string(), expected);
            } else {
                assert_eq!(
                    TrustDomain::new(&td).unwrap_err(),
                    SpiffeIdError::BadTrustDomainChar
                );
            }
        }
    }

    #[test]
    fn trust_domain_as_str() {
        let td = TrustDomain::new("example.org").unwrap();
        assert_eq!(td.as_str(), "example.org");
    }

    #[test]
    fn spiffe_id_trust_domain_name() {
        let id = SpiffeId::new("spiffe://example.org").unwrap();
        assert_eq!(id.trust_domain_name(), "example.org");

        let id = SpiffeId::new("spiffe://example.org/service").unwrap();
        assert_eq!(id.trust_domain_name(), "example.org");
    }

    #[test]
    fn test_spiffe_id_uri_length_limit() {
        let trust_domain = "example.org";
        let prefix_len = SPIFFE_SCHEME_PREFIX.len();
        let td_len = trust_domain.len();

        // Test with SPIFFE ID at maximum allowed length (2048 bytes total)
        let max_path_len = MAX_SPIFFE_ID_URI_LENGTH - prefix_len - td_len;
        let max_path: String = std::iter::once('/')
            .chain(std::iter::repeat('a'))
            .take(max_path_len)
            .collect();
        let id = format!("spiffe://{trust_domain}{max_path}");
        assert_eq!(id.len(), MAX_SPIFFE_ID_URI_LENGTH);
        assert!(
            SpiffeId::new(&id).is_ok(),
            "SPIFFE ID at max length (2048 bytes) should be accepted"
        );

        // Parsing should also accept IDs longer than 2048 bytes when they are
        // otherwise valid.
        let oversized_path: String = std::iter::once('/')
            .chain(std::iter::repeat('a'))
            .take(max_path_len + 1)
            .collect();
        let id = format!("spiffe://{trust_domain}{oversized_path}");
        assert_eq!(id.len(), MAX_SPIFFE_ID_URI_LENGTH + 1);
        assert!(
            SpiffeId::new(&id).is_ok(),
            "SPIFFE ID exceeding 2048 bytes should still be parsed when otherwise valid"
        );

        // TrustDomain::new should also accept an oversized SPIFFE ID URI when
        // the extracted trust domain itself is valid.
        let oversized_id = format!("spiffe://{trust_domain}{oversized_path}");
        let result = TrustDomain::new(&oversized_id);
        assert!(
            matches!(result, Ok(td) if td.as_str() == trust_domain),
            "TrustDomain::new should extract the trust domain from an oversized but otherwise valid SPIFFE ID URI"
        );
    }

    #[test]
    fn test_trust_domain_length_limit() {
        let at_limit = "a".repeat(MAX_TRUST_DOMAIN_LENGTH);
        let at_limit_td = TrustDomain::new(&at_limit).unwrap();
        assert_eq!(at_limit_td.as_str(), at_limit);

        let over_limit = "a".repeat(MAX_TRUST_DOMAIN_LENGTH + 1);
        let result = TrustDomain::new(&over_limit);
        assert!(matches!(
            result,
            Err(SpiffeIdError::TrustDomainTooLong {
                max: MAX_TRUST_DOMAIN_LENGTH
            })
        ));
    }
}
