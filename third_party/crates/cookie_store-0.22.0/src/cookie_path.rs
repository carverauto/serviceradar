#[cfg(feature = "serde")]
use serde_derive::{Deserialize, Serialize};
use std::cmp::max;
use std::ops::Deref;
use url::Url;

/// Returns true if `request_url` path-matches `path` per
/// [IETF RFC6265 Section 5.1.4](https://datatracker.ietf.org/doc/html/rfc6265#section-5.1.4)
pub fn is_match(path: &str, request_url: &Url) -> bool {
    CookiePath::parse(path).map_or(false, |cp| cp.matches(request_url))
}

/// The path of a `Cookie`
#[derive(PartialEq, Eq, Clone, Debug, Hash, PartialOrd, Ord)]
#[cfg_attr(feature = "serde", derive(Serialize, Deserialize))]
pub struct CookiePath(String, bool);
impl CookiePath {
    /// Determine if `request_url` path-matches this `CookiePath` per
    /// [IETF RFC6265 Section 5.1.4](https://datatracker.ietf.org/doc/html/rfc6265#section-5.1.4)
    pub fn matches(&self, request_url: &Url) -> bool {
        if request_url.cannot_be_a_base() {
            false
        } else {
            let request_path = request_url.path();
            let cookie_path = &*self.0;
            // o  The cookie-path and the request-path are identical.
            cookie_path == request_path
                || (request_path.starts_with(cookie_path)
                    && (cookie_path.ends_with('/')
                        || &request_path[cookie_path.len()..=cookie_path.len()] == "/"))
        }
    }

    /// Returns true if this `CookiePath` was set from a Path attribute; this allows us to
    /// distinguish from the case where Path was explicitly set to "/"
    pub fn is_from_path_attr(&self) -> bool {
        self.1
    }

    // The user agent MUST use an algorithm equivalent to the following
    // algorithm to compute the default-path of a cookie:
    //
    // 1.  Let uri-path be the path portion of the request-uri if such a
    //     portion exists (and empty otherwise).  For example, if the
    //     request-uri contains just a path (and optional query string),
    //     then the uri-path is that path (without the %x3F ("?") character
    //     or query string), and if the request-uri contains a full
    //     absoluteURI, the uri-path is the path component of that URI.
    //
    // 2.  If the uri-path is empty or if the first character of the uri-
    //     path is not a %x2F ("/") character, output %x2F ("/") and skip
    //     the remaining steps.
    //
    // 3.  If the uri-path contains no more than one %x2F ("/") character,
    //     output %x2F ("/") and skip the remaining step.
    //
    // 4.  Output the characters of the uri-path from the first character up
    //     to, but not including, the right-most %x2F ("/").
    /// Determine the default-path of `request_url` per
    /// [IETF RFC6265 Section 5.1.4](https://datatracker.ietf.org/doc/html/rfc6265#section-5.1.4)
    pub fn default_path(request_url: &Url) -> CookiePath {
        let cp = if request_url.cannot_be_a_base() {
            // non-relative path scheme, default to "/" (uri-path "empty", case 2)
            "/".into()
        } else {
            let path = request_url.path();
            match path.rfind('/') {
                None => "/".into(),                   // no "/" in string, default to "/" (case 2)
                Some(i) => path[0..max(i, 1)].into(), // case 4 (subsumes case 3)
            }
        };
        CookiePath(cp, false)
    }

    /// Attempt to parse `path` as a `CookiePath`; if unsuccessful, the default-path of
    /// `request_url` will be returned as the `CookiePath`.
    pub fn new(path: &str, request_url: &Url) -> CookiePath {
        match CookiePath::parse(path) {
            Some(cp) => cp,
            None => CookiePath::default_path(request_url),
        }
    }

    /// Attempt to parse `path` as a `CookiePath`. If `path` does not have a leading "/",
    /// `None` is returned.
    pub fn parse(path: &str) -> Option<CookiePath> {
        if path.starts_with('/') {
            Some(CookiePath(String::from(path), true))
        } else {
            None
        }
    }
}

impl AsRef<str> for CookiePath {
    fn as_ref(&self) -> &str {
        &self.0
    }
}

impl Deref for CookiePath {
    type Target = str;
    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl<'a> From<&'a CookiePath> for String {
    fn from(cp: &CookiePath) -> String {
        cp.0.clone()
    }
}

impl From<CookiePath> for String {
    fn from(cp: CookiePath) -> String {
        cp.0
    }
}

#[cfg(test)]
mod tests {
    use super::CookiePath;
    use url::Url;

    #[test]
    fn default_path() {
        fn get_path(url: &str) -> String {
            CookiePath::default_path(&Url::parse(url).expect("unable to parse url in default_path"))
                .into()
        }
        assert_eq!(get_path("data:foobusbar"), "/");
        assert_eq!(get_path("http://example.com"), "/");
        assert_eq!(get_path("http://example.com/"), "/");
        assert_eq!(get_path("http://example.com/foo"), "/");
        assert_eq!(get_path("http://example.com/foo/"), "/foo");
        assert_eq!(get_path("http://example.com//foo/"), "//foo");
        assert_eq!(get_path("http://example.com/foo//"), "/foo/");
        assert_eq!(get_path("http://example.com/foo/bus/bar"), "/foo/bus");
        assert_eq!(get_path("http://example.com/foo//bus/bar"), "/foo//bus");
        assert_eq!(get_path("http://example.com/foo/bus/bar/"), "/foo/bus/bar");
    }

    fn do_match(exp: bool, cp: &str, rp: &str) {
        let url = Url::parse(&format!("http://example.com{}", rp))
            .expect("unable to parse url in do_match");
        let cp = CookiePath::parse(cp).expect("unable to parse CookiePath in do_match");
        assert!(
            exp == cp.matches(&url),
            "\n>> {:?}\nshould{}match\n>> {:?}\n>> {:?}\n",
            cp,
            if exp { " " } else { " NOT " },
            url,
            url.path()
        );
    }
    fn is_match(cp: &str, rp: &str) {
        do_match(true, cp, rp);
    }
    fn is_mismatch(cp: &str, rp: &str) {
        do_match(false, cp, rp);
    }

    #[test]
    fn bad_paths() {
        assert!(CookiePath::parse("").is_none());
        assert!(CookiePath::parse("a/foo").is_none());
    }

    #[test]
    fn bad_path_defaults() {
        fn get_path(cp: &str, url: &str) -> String {
            CookiePath::new(
                cp,
                &Url::parse(url).expect("unable to parse url in bad_path_defaults"),
            )
            .into()
        }
        assert_eq!(get_path("", "http://example.com/"), "/");
        assert_eq!(get_path("a/foo", "http://example.com/"), "/");
        assert_eq!(get_path("", "http://example.com/foo/bar"), "/foo");
        assert_eq!(get_path("a/foo", "http://example.com/foo/bar"), "/foo");
        assert_eq!(get_path("", "http://example.com/foo/bar/"), "/foo/bar");
        assert_eq!(get_path("a/foo", "http://example.com/foo/bar/"), "/foo/bar");
    }

    #[test]
    fn shortest_path() {
        is_match("/", "/");
    }

    // A request-path path-matches a given cookie-path if at least one of
    // the following conditions holds:
    #[test]
    fn identical_paths() {
        // o  The cookie-path and the request-path are identical.
        is_match("/foo/bus", "/foo/bus"); // identical
        is_mismatch("/foo/bus", "/foo/buss"); // trailing character
        is_mismatch("/foo/bus", "/zoo/bus"); // character mismatch
        is_mismatch("/foo/bus", "/zfoo/bus"); // leading character
    }

    #[test]
    fn cookie_path_prefix1() {
        // o  The cookie-path is a prefix of the request-path, and the last
        //    character of the cookie-path is %x2F ("/").
        is_match("/foo/", "/foo/bus"); // cookie-path a prefix and ends in "/"
        is_mismatch("/bar", "/foo/bus"); // cookie-path not a prefix of request-path
        is_mismatch("/foo/bus/bar", "/foo/bus"); // cookie-path not a prefix of request-path
        is_mismatch("/fo", "/foo/bus"); // cookie-path a prefix, but last char != "/" and first char in request-path ("o") after prefix != "/"
    }

    #[test]
    fn cookie_path_prefix2() {
        // o  The cookie-path is a prefix of the request-path, and the first
        //    character of the request-path that is not included in the cookie-
        //    path is a %x2F ("/") character.
        is_match("/foo", "/foo/bus"); // cookie-path a prefix of request-path, and next char in request-path = "/"
        is_mismatch("/bar", "/foo/bus"); // cookie-path not a prefix of request-path
        is_mismatch("/foo/bus/bar", "/foo/bus"); // cookie-path not a prefix of request-path
        is_mismatch("/fo", "/foo/bus"); // cookie-path a prefix, but next char in request-path ("o") != "/"
    }
}
