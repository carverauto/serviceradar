use crate::cookie_domain::CookieDomain;
use crate::cookie_expiration::CookieExpiration;
use crate::cookie_path::CookiePath;

use crate::utils::{is_http_scheme, is_secure};
use cookie::{Cookie as RawCookie, CookieBuilder as RawCookieBuilder, ParseError};
#[cfg(feature = "serde")]
use serde_derive::{Deserialize, Serialize};
use std::borrow::Cow;
use std::convert::TryFrom;
use std::fmt;
use std::ops::Deref;
use time;
use url::Url;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// Cookie had attribute HttpOnly but was received from a request-uri which was not an http
    /// scheme
    NonHttpScheme,
    /// Cookie did not specify domain but was received from non-relative-scheme request-uri from
    /// which host could not be determined
    NonRelativeScheme,
    /// Cookie received from a request-uri that does not domain-match
    DomainMismatch,
    /// Cookie is Expired
    Expired,
    /// `cookie::Cookie` Parse error
    Parse,
    #[cfg(feature = "public_suffix")]
    /// Cookie specified a public suffix domain-attribute that does not match the canonicalized
    /// request-uri host
    PublicSuffix,
    /// Tried to use a CookieDomain variant of `Empty` or `NotPresent` in a context requiring a Domain value
    UnspecifiedDomain,
}

impl std::error::Error for Error {}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}",
            match *self {
                Error::NonHttpScheme =>
                    "request-uri is not an http scheme but HttpOnly attribute set",
                Error::NonRelativeScheme => {
                    "request-uri is not a relative scheme; cannot determine host"
                }
                Error::DomainMismatch => "request-uri does not domain-match the cookie",
                Error::Expired => "attempted to utilize an Expired Cookie",
                Error::Parse => "unable to parse string as cookie::Cookie",
                #[cfg(feature = "public_suffix")]
                Error::PublicSuffix => "domain-attribute value is a public suffix",
                Error::UnspecifiedDomain => "domain-attribute is not specified",
            }
        )
    }
}

// cookie::Cookie::parse returns Result<Cookie, ()>
impl From<ParseError> for Error {
    fn from(_: ParseError) -> Error {
        Error::Parse
    }
}

pub type CookieResult<'a> = Result<Cookie<'a>, Error>;

/// A cookie conforming more closely to [IETF RFC6265](https://datatracker.ietf.org/doc/html/rfc6265)
#[derive(PartialEq, Clone, Debug)]
#[cfg_attr(feature = "serde", derive(Serialize, Deserialize))]
pub struct Cookie<'a> {
    /// The parsed Set-Cookie data
    #[cfg_attr(feature = "serde", serde(serialize_with = "serde_raw_cookie::serialize"))]
    #[cfg_attr(feature = "serde", serde(deserialize_with = "serde_raw_cookie::deserialize"))]
    raw_cookie: RawCookie<'a>,
    /// The Path attribute from a Set-Cookie header or the default-path as
    /// determined from
    /// the request-uri
    pub path: CookiePath,
    /// The Domain attribute from a Set-Cookie header, or a HostOnly variant if no
    /// non-empty Domain attribute
    /// found
    pub domain: CookieDomain,
    /// For a persistent Cookie (see [IETF RFC6265 Section
    /// 5.3](https://datatracker.ietf.org/doc/html/rfc6265#section-5.3)),
    /// the expiration time as defined by the Max-Age or Expires attribute,
    /// otherwise SessionEnd,
    /// indicating a non-persistent `Cookie` that should expire at the end of the
    /// session
    pub expires: CookieExpiration,
}

#[cfg(feature = "serde")]
mod serde_raw_cookie {
    use cookie::Cookie as RawCookie;
    use serde::de::Error;
    use serde::de::Unexpected;
    use serde::{Deserialize, Deserializer, Serialize, Serializer};
    use std::str::FromStr;

    pub fn serialize<S>(cookie: &RawCookie<'_>, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        cookie.to_string().serialize(serializer)
    }

    pub fn deserialize<'a, D>(deserializer: D) -> Result<RawCookie<'static>, D::Error>
    where
        D: Deserializer<'a>,
    {
        let cookie = String::deserialize(deserializer)?;
        match RawCookie::from_str(&cookie) {
            Ok(cookie) => Ok(cookie),
            Err(_) => Err(D::Error::invalid_value(
                Unexpected::Str(&cookie),
                &"a cookie string",
            )),
        }
    }
}

impl<'a> Cookie<'a> {
    /// Whether this `Cookie` should be included for `request_url`
    pub fn matches(&self, request_url: &Url) -> bool {
        self.path.matches(request_url)
            && self.domain.matches(request_url)
            && (!self.raw_cookie.secure().unwrap_or(false) || is_secure(request_url))
            && (!self.raw_cookie.http_only().unwrap_or(false) || is_http_scheme(request_url))
    }

    /// Should this `Cookie` be persisted across sessions?
    pub fn is_persistent(&self) -> bool {
        match self.expires {
            CookieExpiration::AtUtc(_) => true,
            CookieExpiration::SessionEnd => false,
        }
    }

    /// Expire this cookie
    pub fn expire(&mut self) {
        self.expires = CookieExpiration::from(0u64);
    }

    /// Return whether the `Cookie` is expired *now*
    pub fn is_expired(&self) -> bool {
        self.expires.is_expired()
    }

    /// Indicates if the `Cookie` expires as of `utc_tm`.
    pub fn expires_by(&self, utc_tm: &time::OffsetDateTime) -> bool {
        self.expires.expires_by(utc_tm)
    }

    /// Parses a new `cookie_store::Cookie` from `cookie_str`.
    pub fn parse<S>(cookie_str: S, request_url: &Url) -> CookieResult<'a>
    where
        S: Into<Cow<'a, str>>,
    {
        Cookie::try_from_raw_cookie(&RawCookie::parse(cookie_str)?, request_url)
    }

    /// Create a new `cookie_store::Cookie` from a `cookie::Cookie` (from the `cookie` crate)
    /// received from `request_url`.
    pub fn try_from_raw_cookie(raw_cookie: &RawCookie<'a>, request_url: &Url) -> CookieResult<'a> {
        if raw_cookie.http_only().unwrap_or(false) && !is_http_scheme(request_url) {
            // If the cookie was received from a "non-HTTP" API and the
            // cookie's http-only-flag is set, abort these steps and ignore the
            // cookie entirely.
            return Err(Error::NonHttpScheme);
        }

        let domain = match CookieDomain::try_from(raw_cookie) {
            // 6.   If the domain-attribute is non-empty:
            Ok(d @ CookieDomain::Suffix(_)) => {
                if !d.matches(request_url) {
                    //    If the canonicalized request-host does not domain-match the
                    //    domain-attribute:
                    //       Ignore the cookie entirely and abort these steps.
                    Err(Error::DomainMismatch)
                } else {
                    //    Otherwise:
                    //       Set the cookie's host-only-flag to false.
                    //       Set the cookie's domain to the domain-attribute.
                    Ok(d)
                }
            }
            Err(_) => Err(Error::Parse),
            // Otherwise:
            //    Set the cookie's host-only-flag to true.
            //    Set the cookie's domain to the canonicalized request-host.
            _ => CookieDomain::host_only(request_url),
        }?;

        let path = raw_cookie
            .path()
            .as_ref()
            .and_then(|p| CookiePath::parse(p))
            .unwrap_or_else(|| CookiePath::default_path(request_url));

        // per RFC6265, Max-Age takes precedence, then Expires, otherwise is Session
        // only
        let expires = if let Some(max_age) = raw_cookie.max_age() {
            CookieExpiration::from(max_age)
        } else if let Some(expiration) = raw_cookie.expires() {
            CookieExpiration::from(expiration)
        } else {
            CookieExpiration::SessionEnd
        };

        Ok(Cookie {
            raw_cookie: raw_cookie.clone(),
            path,
            expires,
            domain,
        })
    }

    pub fn into_owned(self) -> Cookie<'static> {
        Cookie {
            raw_cookie: self.raw_cookie.into_owned(),
            path: self.path,
            domain: self.domain,
            expires: self.expires,
        }
    }
}

impl<'a> Deref for Cookie<'a> {
    type Target = RawCookie<'a>;
    fn deref(&self) -> &Self::Target {
        &self.raw_cookie
    }
}

impl<'a> From<Cookie<'a>> for RawCookie<'a> {
    fn from(cookie: Cookie<'a>) -> RawCookie<'static> {
        let mut builder =
            RawCookieBuilder::new(cookie.name().to_owned(), cookie.value().to_owned());

        // Max-Age is relative, will not have same meaning now, so only set `Expires`.
        match cookie.expires {
            CookieExpiration::AtUtc(utc_tm) => {
                builder = builder.expires(utc_tm);
            }
            CookieExpiration::SessionEnd => {}
        }

        if cookie.path.is_from_path_attr() {
            builder = builder.path(String::from(cookie.path));
        }

        if let CookieDomain::Suffix(s) = cookie.domain {
            builder = builder.domain(s);
        }

        builder.build()
    }
}

#[cfg(test)]
mod tests {
    use super::Cookie;
    use crate::cookie_domain::CookieDomain;
    use crate::cookie_expiration::CookieExpiration;
    use cookie::Cookie as RawCookie;
    use time::{Duration, OffsetDateTime};
    use url::Url;

    use crate::utils::test as test_utils;

    fn cmp_domain(cookie: &str, url: &str, exp: CookieDomain) {
        let ua = test_utils::make_cookie(cookie, url, None, None);
        assert!(ua.domain == exp, "\n{:?}", ua);
    }

    #[test]
    fn no_domain() {
        let url = test_utils::url("http://example.com/foo/bar");
        cmp_domain(
            "cookie1=value1",
            "http://example.com/foo/bar",
            CookieDomain::host_only(&url).expect("unable to parse domain"),
        );
    }

    // per RFC6265:
    // If the attribute-value is empty, the behavior is undefined.  However,
    //   the user agent SHOULD ignore the cookie-av entirely.
    #[test]
    fn empty_domain() {
        let url = test_utils::url("http://example.com/foo/bar");
        cmp_domain(
            "cookie1=value1; Domain=",
            "http://example.com/foo/bar",
            CookieDomain::host_only(&url).expect("unable to parse domain"),
        );
    }

    #[test]
    fn mismatched_domain() {
        let ua = Cookie::parse(
            "cookie1=value1; Domain=notmydomain.com",
            &test_utils::url("http://example.com/foo/bar"),
        );
        assert!(ua.is_err(), "{:?}", ua);
    }

    #[test]
    fn domains() {
        fn domain_from(domain: &str, request_url: &str, is_some: bool) {
            let cookie_str = format!("cookie1=value1; Domain={}", domain);
            let raw_cookie = RawCookie::parse(cookie_str).unwrap();
            let cookie = Cookie::try_from_raw_cookie(&raw_cookie, &test_utils::url(request_url));
            assert_eq!(is_some, cookie.is_ok())
        }
        //        The user agent will reject cookies unless the Domain attribute
        // specifies a scope for the cookie that would include the origin
        // server.  For example, the user agent will accept a cookie with a
        // Domain attribute of "example.com" or of "foo.example.com" from
        // foo.example.com, but the user agent will not accept a cookie with a
        // Domain attribute of "bar.example.com" or of "baz.foo.example.com".
        domain_from("example.com", "http://foo.example.com", true);
        domain_from(".example.com", "http://foo.example.com", true);
        domain_from("foo.example.com", "http://foo.example.com", true);
        domain_from(".foo.example.com", "http://foo.example.com", true);

        domain_from("oo.example.com", "http://foo.example.com", false);
        domain_from("myexample.com", "http://foo.example.com", false);
        domain_from("bar.example.com", "http://foo.example.com", false);
        domain_from("baz.foo.example.com", "http://foo.example.com", false);
    }

    #[test]
    fn httponly() {
        let c = RawCookie::parse("cookie1=value1; HttpOnly").unwrap();
        let url = Url::parse("ftp://example.com/foo/bar").unwrap();
        let ua = Cookie::try_from_raw_cookie(&c, &url);
        assert!(ua.is_err(), "{:?}", ua);
    }

    #[test]
    fn identical_domain() {
        cmp_domain(
            "cookie1=value1; Domain=example.com",
            "http://example.com/foo/bar",
            CookieDomain::Suffix(String::from("example.com")),
        );
    }

    #[test]
    fn identical_domain_leading_dot() {
        cmp_domain(
            "cookie1=value1; Domain=.example.com",
            "http://example.com/foo/bar",
            CookieDomain::Suffix(String::from("example.com")),
        );
    }

    #[test]
    fn identical_domain_two_leading_dots() {
        cmp_domain(
            "cookie1=value1; Domain=..example.com",
            "http://..example.com/foo/bar",
            CookieDomain::Suffix(String::from(".example.com")),
        );
    }

    #[test]
    fn upper_case_domain() {
        cmp_domain(
            "cookie1=value1; Domain=EXAMPLE.com",
            "http://example.com/foo/bar",
            CookieDomain::Suffix(String::from("example.com")),
        );
    }

    fn cmp_path(cookie: &str, url: &str, exp: &str) {
        let ua = test_utils::make_cookie(cookie, url, None, None);
        assert!(String::from(ua.path.clone()) == exp, "\n{:?}", ua);
    }

    #[test]
    fn no_path() {
        // no Path specified
        cmp_path("cookie1=value1", "http://example.com/foo/bar/", "/foo/bar");
        cmp_path("cookie1=value1", "http://example.com/foo/bar", "/foo");
        cmp_path("cookie1=value1", "http://example.com/foo", "/");
        cmp_path("cookie1=value1", "http://example.com/", "/");
        cmp_path("cookie1=value1", "http://example.com", "/");
    }

    #[test]
    fn empty_path() {
        // Path specified with empty value
        cmp_path(
            "cookie1=value1; Path=",
            "http://example.com/foo/bar/",
            "/foo/bar",
        );
        cmp_path(
            "cookie1=value1; Path=",
            "http://example.com/foo/bar",
            "/foo",
        );
        cmp_path("cookie1=value1; Path=", "http://example.com/foo", "/");
        cmp_path("cookie1=value1; Path=", "http://example.com/", "/");
        cmp_path("cookie1=value1; Path=", "http://example.com", "/");
    }

    #[test]
    fn invalid_path() {
        // Invalid Path specified (first character not /)
        cmp_path(
            "cookie1=value1; Path=baz",
            "http://example.com/foo/bar/",
            "/foo/bar",
        );
        cmp_path(
            "cookie1=value1; Path=baz",
            "http://example.com/foo/bar",
            "/foo",
        );
        cmp_path("cookie1=value1; Path=baz", "http://example.com/foo", "/");
        cmp_path("cookie1=value1; Path=baz", "http://example.com/", "/");
        cmp_path("cookie1=value1; Path=baz", "http://example.com", "/");
    }

    #[test]
    fn path() {
        // Path specified, single /
        cmp_path(
            "cookie1=value1; Path=/baz",
            "http://example.com/foo/bar/",
            "/baz",
        );
        // Path specified, multiple / (for valid attribute-value on path, take full
        // string)
        cmp_path(
            "cookie1=value1; Path=/baz/",
            "http://example.com/foo/bar/",
            "/baz/",
        );
    }

    // expiry-related tests
    #[inline]
    fn in_days(days: i64) -> OffsetDateTime {
        OffsetDateTime::now_utc() + Duration::days(days)
    }
    #[inline]
    fn in_minutes(mins: i64) -> OffsetDateTime {
        OffsetDateTime::now_utc() + Duration::minutes(mins)
    }

    #[test]
    fn max_age_bounds() {
        let ua = test_utils::make_cookie(
            "cookie1=value1",
            "http://example.com/foo/bar",
            None,
            Some(9223372036854776),
        );
        assert!(match ua.expires {
            CookieExpiration::AtUtc(_) => true,
            _ => false,
        });
    }

    #[test]
    fn max_age() {
        let ua = test_utils::make_cookie(
            "cookie1=value1",
            "http://example.com/foo/bar",
            None,
            Some(60),
        );
        assert!(!ua.is_expired());
        assert!(ua.expires_by(&in_minutes(2)));
    }

    #[test]
    fn expired() {
        let ua = test_utils::make_cookie(
            "cookie1=value1",
            "http://example.com/foo/bar",
            None,
            Some(0u64),
        );
        assert!(ua.is_expired());
        assert!(ua.expires_by(&in_days(-1)));
        let ua = test_utils::make_cookie(
            "cookie1=value1; Max-Age=0",
            "http://example.com/foo/bar",
            None,
            None,
        );
        assert!(ua.is_expired());
        assert!(ua.expires_by(&in_days(-1)));
        let ua = test_utils::make_cookie(
            "cookie1=value1; Max-Age=-1",
            "http://example.com/foo/bar",
            None,
            None,
        );
        assert!(ua.is_expired());
        assert!(ua.expires_by(&in_days(-1)));
    }

    #[test]
    fn session_end() {
        let ua =
            test_utils::make_cookie("cookie1=value1", "http://example.com/foo/bar", None, None);
        assert!(match ua.expires {
            CookieExpiration::SessionEnd => true,
            _ => false,
        });
        assert!(!ua.is_expired());
        assert!(!ua.expires_by(&in_days(1)));
        assert!(!ua.expires_by(&in_days(-1)));
    }

    #[test]
    fn expires_tmrw_at_utc() {
        let ua = test_utils::make_cookie(
            "cookie1=value1",
            "http://example.com/foo/bar",
            Some(in_days(1)),
            None,
        );
        assert!(!ua.is_expired());
        assert!(ua.expires_by(&in_days(2)));
    }

    #[test]
    fn expired_yest_at_utc() {
        let ua = test_utils::make_cookie(
            "cookie1=value1",
            "http://example.com/foo/bar",
            Some(in_days(-1)),
            None,
        );
        assert!(ua.is_expired());
        assert!(!ua.expires_by(&in_days(-2)));
    }

    #[test]
    fn is_persistent() {
        let ua =
            test_utils::make_cookie("cookie1=value1", "http://example.com/foo/bar", None, None);
        assert!(!ua.is_persistent()); // SessionEnd
        let ua = test_utils::make_cookie(
            "cookie1=value1",
            "http://example.com/foo/bar",
            Some(in_days(1)),
            None,
        );
        assert!(ua.is_persistent()); // AtUtc from Expires
        let ua = test_utils::make_cookie(
            "cookie1=value1",
            "http://example.com/foo/bar",
            Some(in_days(1)),
            Some(60),
        );
        assert!(ua.is_persistent()); // AtUtc from Max-Age
    }

    #[test]
    fn max_age_overrides_expires() {
        // Expires indicates expiration yesterday, but Max-Age indicates expiry in 1
        // minute
        let ua = test_utils::make_cookie(
            "cookie1=value1",
            "http://example.com/foo/bar",
            Some(in_days(-1)),
            Some(60),
        );
        assert!(!ua.is_expired());
        assert!(ua.expires_by(&in_minutes(2)));
    }

    // A request-path path-matches a given cookie-path if at least one of
    // the following conditions holds:
    // o  The cookie-path and the request-path are identical.
    // o  The cookie-path is a prefix of the request-path, and the last
    //    character of the cookie-path is %x2F ("/").
    // o  The cookie-path is a prefix of the request-path, and the first
    //    character of the request-path that is not included in the cookie-
    //    path is a %x2F ("/") character.
    #[test]
    fn matches() {
        fn do_match(exp: bool, cookie: &str, src_url: &str, request_url: Option<&str>) {
            let ua = test_utils::make_cookie(cookie, src_url, None, None);
            let request_url = request_url.unwrap_or(src_url);
            assert!(
                exp == ua.matches(&Url::parse(request_url).unwrap()),
                "\n>> {:?}\nshould{}match\n>> {:?}\n",
                ua,
                if exp { " " } else { " NOT " },
                request_url
            );
        }
        fn is_match(cookie: &str, url: &str, request_url: Option<&str>) {
            do_match(true, cookie, url, request_url);
        }
        fn is_mismatch(cookie: &str, url: &str, request_url: Option<&str>) {
            do_match(false, cookie, url, request_url);
        }

        // match: request-path & cookie-path (defaulted from request-uri) identical
        is_match("cookie1=value1", "http://example.com/foo/bar", None);
        // mismatch: request-path & cookie-path do not match
        is_mismatch(
            "cookie1=value1",
            "http://example.com/bus/baz/",
            Some("http://example.com/foo/bar"),
        );
        is_mismatch(
            "cookie1=value1; Path=/bus/baz",
            "http://example.com/foo/bar",
            None,
        );
        // match: cookie-path a prefix of request-path and last character of
        // cookie-path is /
        is_match(
            "cookie1=value1",
            "http://example.com/foo/bar",
            Some("http://example.com/foo/bar"),
        );
        is_match(
            "cookie1=value1; Path=/foo/",
            "http://example.com/foo/bar",
            None,
        );
        // mismatch: cookie-path a prefix of request-path but last character of
        // cookie-path is not /
        // and first character of request-path not included in cookie-path is not /
        is_mismatch(
            "cookie1=value1",
            "http://example.com/fo/",
            Some("http://example.com/foo/bar"),
        );
        is_mismatch(
            "cookie1=value1; Path=/fo",
            "http://example.com/foo/bar",
            None,
        );
        // match: cookie-path a prefix of request-path and first character of
        // request-path
        // not included in the cookie-path is /
        is_match(
            "cookie1=value1",
            "http://example.com/foo/",
            Some("http://example.com/foo/bar"),
        );
        is_match(
            "cookie1=value1; Path=/foo",
            "http://example.com/foo/bar",
            None,
        );
        // match: Path overridden to /, which matches all paths from the domain
        is_match(
            "cookie1=value1; Path=/",
            "http://example.com/foo/bar",
            Some("http://example.com/bus/baz"),
        );
        // mismatch: different domain
        is_mismatch(
            "cookie1=value1",
            "http://example.com/foo/",
            Some("http://notmydomain.com/foo/bar"),
        );
        is_mismatch(
            "cookie1=value1; Domain=example.com",
            "http://foo.example.com/foo/",
            Some("http://notmydomain.com/foo/bar"),
        );
        // match: secure protocol
        is_match(
            "cookie1=value1; Secure",
            "http://example.com/foo/bar",
            Some("https://example.com/foo/bar"),
        );
        // mismatch: non-secure protocol
        is_mismatch(
            "cookie1=value1; Secure",
            "http://example.com/foo/bar",
            Some("http://example.com/foo/bar"),
        );
        // match: no http restriction
        is_match(
            "cookie1=value1",
            "http://example.com/foo/bar",
            Some("ftp://example.com/foo/bar"),
        );
        // match: http protocol
        is_match(
            "cookie1=value1; HttpOnly",
            "http://example.com/foo/bar",
            Some("http://example.com/foo/bar"),
        );
        is_match(
            "cookie1=value1; HttpOnly",
            "http://example.com/foo/bar",
            Some("HTTP://example.com/foo/bar"),
        );
        is_match(
            "cookie1=value1; HttpOnly",
            "http://example.com/foo/bar",
            Some("https://example.com/foo/bar"),
        );
        // mismatch: http requried
        is_mismatch(
            "cookie1=value1; HttpOnly",
            "http://example.com/foo/bar",
            Some("ftp://example.com/foo/bar"),
        );
        is_mismatch(
            "cookie1=value1; HttpOnly",
            "http://example.com/foo/bar",
            Some("data:nonrelativescheme"),
        );
    }
}

#[cfg(all(test, feature = "serde_json"))]
mod serde_json_tests {
    use crate::cookie::Cookie;
    use crate::cookie_expiration::CookieExpiration;
    use crate::utils::test as test_utils;
    use crate::utils::test::*;
    use serde_json::json;
    use time;

    fn encode_decode(c: &Cookie<'_>, expected: serde_json::Value) {
        let encoded = serde_json::to_value(c).unwrap();
        assert_eq!(
            expected,
            encoded,
            "\nexpected: '{}'\n encoded: '{}'",
            expected.to_string(),
            encoded.to_string()
        );
        let decoded: Cookie<'_> = serde_json::from_value(encoded).unwrap();
        assert_eq!(
            *c,
            decoded,
            "\nexpected: '{}'\n decoded: '{}'",
            c.to_string(),
            decoded.to_string()
        );
    }

    #[test]
    fn serde() {
        encode_decode(
            &test_utils::make_cookie("cookie1=value1", "http://example.com/foo/bar", None, None),
            json!({
                "raw_cookie": "cookie1=value1",
                "path": ["/foo", false],
                "domain": { "HostOnly": "example.com" },
                "expires": "SessionEnd"
            }),
        );

        encode_decode(
            &test_utils::make_cookie(
                "cookie2=value2; Domain=example.com",
                "http://foo.example.com/foo/bar",
                None,
                None,
            ),
            json!({
                "raw_cookie": "cookie2=value2; Domain=example.com",
                "path": ["/foo", false],
                "domain": { "Suffix": "example.com" },
                "expires": "SessionEnd"
            }),
        );

        encode_decode(
            &test_utils::make_cookie(
                "cookie3=value3; Path=/foo/bar",
                "http://foo.example.com/foo",
                None,
                None,
            ),
            json!({
                "raw_cookie": "cookie3=value3; Path=/foo/bar",
                "path": ["/foo/bar", true],
                "domain": { "HostOnly": "foo.example.com" },
                "expires": "SessionEnd",
            }),
        );

        let at_utc = time::macros::date!(2015 - 08 - 11)
            .with_time(time::macros::time!(16:41:42))
            .assume_utc();
        encode_decode(
            &test_utils::make_cookie(
                "cookie4=value4",
                "http://example.com/foo/bar",
                Some(at_utc),
                None,
            ),
            json!({
                "raw_cookie": "cookie4=value4; Expires=Tue, 11 Aug 2015 16:41:42 GMT",
                "path": ["/foo", false],
                "domain": { "HostOnly": "example.com" },
                "expires": { "AtUtc": at_utc.format(crate::rfc3339_fmt::RFC3339_FORMAT).unwrap().to_string() },
            }),
        );

        let expires = test_utils::make_cookie(
            "cookie5=value5",
            "http://example.com/foo/bar",
            Some(in_minutes(10)),
            None,
        );
        let utc_tm = match expires.expires {
            CookieExpiration::AtUtc(ref utc_tm) => utc_tm,
            CookieExpiration::SessionEnd => unreachable!(),
        };

        let utc_formatted = utc_tm
            .format(&time::format_description::well_known::Rfc2822)
            .unwrap()
            .to_string()
            .replace("+0000", "GMT");
        let raw_cookie_value = format!("cookie5=value5; Expires={utc_formatted}");

        encode_decode(
            &expires,
            json!({
                "raw_cookie": raw_cookie_value,
                "path":["/foo", false],
                "domain": { "HostOnly": "example.com" },
                "expires": { "AtUtc": utc_tm.format(crate::rfc3339_fmt::RFC3339_FORMAT).unwrap().to_string() },
            }),
        );
        dbg!(&at_utc);
        let max_age = test_utils::make_cookie(
            "cookie6=value6",
            "http://example.com/foo/bar",
            Some(at_utc),
            Some(10),
        );
        dbg!(&max_age);
        let utc_tm = match max_age.expires {
            CookieExpiration::AtUtc(ref utc_tm) => time::OffsetDateTime::parse(
                &utc_tm.format(crate::rfc3339_fmt::RFC3339_FORMAT).unwrap(),
                &time::format_description::well_known::Rfc3339,
            )
            .expect("could not re-parse time"),
            CookieExpiration::SessionEnd => unreachable!(),
        };
        dbg!(&utc_tm);
        encode_decode(
            &max_age,
            json!({
                "raw_cookie": "cookie6=value6; Max-Age=10; Expires=Tue, 11 Aug 2015 16:41:42 GMT",
                "path":["/foo", false],
                "domain": { "HostOnly": "example.com" },
                "expires": { "AtUtc": utc_tm.format(crate::rfc3339_fmt::RFC3339_FORMAT).unwrap().to_string() },
            }),
        );

        let max_age = test_utils::make_cookie(
            "cookie7=value7",
            "http://example.com/foo/bar",
            None,
            Some(10),
        );
        let utc_tm = match max_age.expires {
            CookieExpiration::AtUtc(ref utc_tm) => utc_tm,
            CookieExpiration::SessionEnd => unreachable!(),
        };
        encode_decode(
            &max_age,
            json!({
                "raw_cookie": "cookie7=value7; Max-Age=10",
                "path":["/foo", false],
                "domain": { "HostOnly": "example.com" },
                "expires": { "AtUtc": utc_tm.format(crate::rfc3339_fmt::RFC3339_FORMAT).unwrap().to_string() },
            }),
        );
    }
}
