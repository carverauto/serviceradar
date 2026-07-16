use std::io::{BufRead, Write};
use std::ops::Deref;

use cookie::Cookie as RawCookie;
use log::debug;
use url::Url;

use crate::cookie::Cookie;
use crate::cookie_domain::is_match as domain_match;
use crate::cookie_path::is_match as path_match;
use crate::utils::{is_http_scheme, is_secure};
use crate::CookieError;

#[cfg(feature = "preserve_order")]
use indexmap::IndexMap;
#[cfg(not(feature = "preserve_order"))]
use std::collections::HashMap;
#[cfg(feature = "preserve_order")]
type Map<K, V> = IndexMap<K, V>;
#[cfg(not(feature = "preserve_order"))]
type Map<K, V> = HashMap<K, V>;

type NameMap = Map<String, Cookie<'static>>;
type PathMap = Map<String, NameMap>;
type DomainMap = Map<String, PathMap>;

#[derive(PartialEq, Clone, Debug, Eq)]
pub enum StoreAction {
    /// The `Cookie` was successfully added to the store
    Inserted,
    /// The `Cookie` successfully expired a `Cookie` already in the store
    ExpiredExisting,
    /// The `Cookie` was added to the store, replacing an existing entry
    UpdatedExisting,
}

pub type StoreResult<T> = Result<T, crate::Error>;
pub type InsertResult = Result<StoreAction, CookieError>;

#[derive(Debug, Default, Clone)]
/// An implementation for storing and retrieving [`Cookie`]s per the path and domain matching
/// rules specified in [RFC6265](https://datatracker.ietf.org/doc/html/rfc6265).
pub struct CookieStore {
    /// Cookies stored by domain, path, then name
    cookies: DomainMap,
    #[cfg(feature = "public_suffix")]
    /// If set, enables [public suffix](https://datatracker.ietf.org/doc/html/rfc6265#section-5.3) rejection based on the provided `publicsuffix::List`
    public_suffix_list: Option<publicsuffix::List>,
}

impl CookieStore {
    #[deprecated(
        since = "0.14.1",
        note = "Please use the `get_request_values` function instead"
    )]
    /// Return an `Iterator` of the cookies for `url` in the store, suitable for submitting in an
    /// HTTP request. As the items are intended for use in creating a `Cookie` header in a GET request,
    /// they may contain only the `name` and `value` of a received cookie, eliding other parameters
    /// such as `path` or `expires`. For iteration over `Cookie` instances containing all data, please
    /// refer to [`CookieStore::matches`].
    pub fn get_request_cookies(&self, url: &Url) -> impl Iterator<Item = &RawCookie<'static>> {
        self.matches(url).into_iter().map(|c| c.deref())
    }

    /// Return an `Iterator` of the cookie (`name`, `value`) pairs for `url` in the store, suitable
    /// for use in the `Cookie` header of an HTTP request. For iteration over `Cookie` instances,
    /// please refer to [`CookieStore::matches`].
    pub fn get_request_values(&self, url: &Url) -> impl Iterator<Item = (&str, &str)> {
        self.matches(url).into_iter().map(|c| c.name_value())
    }

    /// Store the `cookies` received from `url`
    pub fn store_response_cookies<I: Iterator<Item = RawCookie<'static>>>(
        &mut self,
        cookies: I,
        url: &Url,
    ) {
        for cookie in cookies {
            if cookie.secure() != Some(true) || cfg!(feature = "log_secure_cookie_values") {
                debug!("inserting Set-Cookie '{:?}'", cookie);
            } else {
                debug!("inserting secure cookie '{}'", cookie.name());
            }

            if let Err(e) = self.insert_raw(&cookie, url) {
                debug!("unable to store Set-Cookie: {:?}", e);
            }
        }
    }

    /// Specify a `publicsuffix::List` for the `CookieStore` to allow [public suffix
    /// matching](https://datatracker.ietf.org/doc/html/rfc6265#section-5.3)
    #[cfg(feature = "public_suffix")]
    pub fn with_suffix_list(self, psl: publicsuffix::List) -> CookieStore {
        CookieStore {
            cookies: self.cookies,
            public_suffix_list: Some(psl),
        }
    }

    /// Returns true if the `CookieStore` contains an __unexpired__ `Cookie` corresponding to the
    /// specified `domain`, `path`, and `name`.
    pub fn contains(&self, domain: &str, path: &str, name: &str) -> bool {
        self.get(domain, path, name).is_some()
    }

    /// Returns true if the `CookieStore` contains any (even an __expired__) `Cookie` corresponding
    /// to the specified `domain`, `path`, and `name`.
    pub fn contains_any(&self, domain: &str, path: &str, name: &str) -> bool {
        self.get_any(domain, path, name).is_some()
    }

    /// Returns a reference to the __unexpired__ `Cookie` corresponding to the specified `domain`,
    /// `path`, and `name`.
    pub fn get(&self, domain: &str, path: &str, name: &str) -> Option<&Cookie<'_>> {
        self.get_any(domain, path, name).and_then(|cookie| {
            if cookie.is_expired() {
                None
            } else {
                Some(cookie)
            }
        })
    }

    /// Returns a mutable reference to the __unexpired__ `Cookie` corresponding to the specified
    /// `domain`, `path`, and `name`.
    fn get_mut(&mut self, domain: &str, path: &str, name: &str) -> Option<&mut Cookie<'static>> {
        self.get_mut_any(domain, path, name).and_then(|cookie| {
            if cookie.is_expired() {
                None
            } else {
                Some(cookie)
            }
        })
    }

    /// Returns a reference to the (possibly __expired__) `Cookie` corresponding to the specified
    /// `domain`, `path`, and `name`.
    pub fn get_any(&self, domain: &str, path: &str, name: &str) -> Option<&Cookie<'static>> {
        self.cookies.get(domain).and_then(|domain_cookies| {
            domain_cookies
                .get(path)
                .and_then(|path_cookies| path_cookies.get(name))
        })
    }

    /// Returns a mutable reference to the (possibly __expired__) `Cookie` corresponding to the
    /// specified `domain`, `path`, and `name`.
    fn get_mut_any(
        &mut self,
        domain: &str,
        path: &str,
        name: &str,
    ) -> Option<&mut Cookie<'static>> {
        self.cookies.get_mut(domain).and_then(|domain_cookies| {
            domain_cookies
                .get_mut(path)
                .and_then(|path_cookies| path_cookies.get_mut(name))
        })
    }

    /// Removes a `Cookie` from the store, returning the `Cookie` if it was in the store
    pub fn remove(&mut self, domain: &str, path: &str, name: &str) -> Option<Cookie<'static>> {
        #[cfg(not(feature = "preserve_order"))]
        fn map_remove<K, V, Q>(map: &mut Map<K, V>, key: &Q) -> Option<V>
        where
            K: std::borrow::Borrow<Q> + std::cmp::Eq + std::hash::Hash,
            Q: std::cmp::Eq + std::hash::Hash + ?Sized,
        {
            map.remove(key)
        }
        #[cfg(feature = "preserve_order")]
        fn map_remove<K, V, Q>(map: &mut Map<K, V>, key: &Q) -> Option<V>
        where
            K: std::borrow::Borrow<Q> + std::cmp::Eq + std::hash::Hash,
            Q: std::cmp::Eq + std::hash::Hash + ?Sized,
        {
            map.shift_remove(key)
        }

        let (removed, remove_domain) = match self.cookies.get_mut(domain) {
            None => (None, false),
            Some(domain_cookies) => {
                let (removed, remove_path) = match domain_cookies.get_mut(path) {
                    None => (None, false),
                    Some(path_cookies) => {
                        let removed = map_remove(path_cookies, name);
                        (removed, path_cookies.is_empty())
                    }
                };

                if remove_path {
                    map_remove(domain_cookies, path);
                    (removed, domain_cookies.is_empty())
                } else {
                    (removed, false)
                }
            }
        };

        if remove_domain {
            map_remove(&mut self.cookies, domain);
        }

        removed
    }

    /// Returns a collection of references to __unexpired__ cookies that path- and domain-match
    /// `request_url`, as well as having HttpOnly and Secure attributes compatible with the
    /// `request_url`.
    pub fn matches(&self, request_url: &Url) -> Vec<&Cookie<'static>> {
        // although we domain_match and path_match as we descend through the tree, we
        // still need to
        // do a full Cookie::matches() check in the last filter. Otherwise, we cannot
        // properly deal
        // with HostOnly Cookies.
        let cookies = self
            .cookies
            .iter()
            .filter(|&(d, _)| domain_match(d, request_url))
            .flat_map(|(_, dcs)| {
                dcs.iter()
                    .filter(|&(p, _)| path_match(p, request_url))
                    .flat_map(|(_, pcs)| {
                        pcs.values()
                            .filter(|c| !c.is_expired() && c.matches(request_url))
                    })
            });
        match (!is_http_scheme(request_url), !is_secure(request_url)) {
            (true, true) => cookies
                .filter(|c| !c.http_only().unwrap_or(false) && !c.secure().unwrap_or(false))
                .collect(),
            (true, false) => cookies
                .filter(|c| !c.http_only().unwrap_or(false))
                .collect(),
            (false, true) => cookies.filter(|c| !c.secure().unwrap_or(false)).collect(),
            (false, false) => cookies.collect(),
        }
    }

    /// Parses a new `Cookie` from `cookie_str` and inserts it into the store.
    pub fn parse(&mut self, cookie_str: &str, request_url: &Url) -> InsertResult {
        Cookie::parse(cookie_str, request_url)
            .and_then(|cookie| self.insert(cookie.into_owned(), request_url))
    }

    /// Converts a `cookie::Cookie` (from the `cookie` crate) into a `cookie_store::Cookie` and
    /// inserts it into the store.
    pub fn insert_raw(&mut self, cookie: &RawCookie<'_>, request_url: &Url) -> InsertResult {
        Cookie::try_from_raw_cookie(cookie, request_url)
            .and_then(|cookie| self.insert(cookie.into_owned(), request_url))
    }

    /// Inserts `cookie`, received from `request_url`, into the store, following the rules of the
    /// [IETF RFC6265 Storage Model](https://datatracker.ietf.org/doc/html/rfc6265#section-5.3). If the
    /// `Cookie` is __unexpired__ and is successfully inserted, returns
    /// `Ok(StoreAction::Inserted)`. If the `Cookie` is __expired__ *and* matches an existing
    /// `Cookie` in the store, the existing `Cookie` wil be `expired()` and
    /// `Ok(StoreAction::ExpiredExisting)` will be returned.
    pub fn insert(&mut self, cookie: Cookie<'static>, request_url: &Url) -> InsertResult {
        if cookie.http_only().unwrap_or(false) && !is_http_scheme(request_url) {
            // If the cookie was received from a "non-HTTP" API and the
            // cookie's http-only-flag is set, abort these steps and ignore the
            // cookie entirely.
            return Err(CookieError::NonHttpScheme);
        }
        #[cfg(feature = "public_suffix")]
        let mut cookie = cookie;
        #[cfg(feature = "public_suffix")]
        if let Some(ref psl) = self.public_suffix_list {
            // If the user agent is configured to reject "public suffixes"
            if cookie.domain.is_public_suffix(psl) {
                // and the domain-attribute is a public suffix:
                if cookie.domain.host_is_identical(request_url) {
                    //   If the domain-attribute is identical to the canonicalized
                    //   request-host:
                    //     Let the domain-attribute be the empty string.
                    // (NB: at this point, an empty domain-attribute should be represented
                    // as the HostOnly variant of CookieDomain)
                    cookie.domain = crate::cookie_domain::CookieDomain::host_only(request_url)?;
                } else {
                    //   Otherwise:
                    //     Ignore the cookie entirely and abort these steps.
                    return Err(CookieError::PublicSuffix);
                }
            }
        }
        if !cookie.domain.matches(request_url) {
            // If the canonicalized request-host does not domain-match the
            // domain-attribute:
            //    Ignore the cookie entirely and abort these steps.
            return Err(CookieError::DomainMismatch);
        }
        // NB: we do not bail out above on is_expired(), as servers can remove a cookie
        // by sending
        // an expired one, so we need to do the old_cookie check below before checking
        // is_expired() on an incoming cookie

        {
            // At this point in parsing, any non-present Domain attribute should have been
            // converted into a HostOnly variant
            let cookie_domain = cookie
                .domain
                .as_cow()
                .ok_or_else(|| CookieError::UnspecifiedDomain)?;
            if let Some(old_cookie) = self.get_mut(&cookie_domain, &cookie.path, cookie.name()) {
                if old_cookie.http_only().unwrap_or(false) && !is_http_scheme(request_url) {
                    // 2.  If the newly created cookie was received from a "non-HTTP"
                    //    API and the old-cookie's http-only-flag is set, abort these
                    //    steps and ignore the newly created cookie entirely.
                    return Err(CookieError::NonHttpScheme);
                } else if cookie.is_expired() {
                    old_cookie.expire();
                    return Ok(StoreAction::ExpiredExisting);
                }
            }
        }

        if !cookie.is_expired() {
            Ok(
                if self
                    .cookies
                    .entry(String::from(&cookie.domain))
                    .or_insert_with(Map::new)
                    .entry(String::from(&cookie.path))
                    .or_insert_with(Map::new)
                    .insert(cookie.name().to_owned(), cookie)
                    .is_none()
                {
                    StoreAction::Inserted
                } else {
                    StoreAction::UpdatedExisting
                },
            )
        } else {
            Err(CookieError::Expired)
        }
    }

    /// Clear the contents of the store
    pub fn clear(&mut self) {
        self.cookies.clear()
    }

    /// An iterator visiting all the __unexpired__ cookies in the store
    pub fn iter_unexpired<'a>(&'a self) -> impl Iterator<Item = &'a Cookie<'static>> + 'a {
        self.cookies
            .values()
            .flat_map(|dcs| dcs.values())
            .flat_map(|pcs| pcs.values())
            .filter(|c| !c.is_expired())
    }

    /// An iterator visiting all (including __expired__) cookies in the store
    pub fn iter_any<'a>(&'a self) -> impl Iterator<Item = &'a Cookie<'static>> + 'a {
        self.cookies
            .values()
            .flat_map(|dcs| dcs.values())
            .flat_map(|pcs| pcs.values())
    }

    /// Serialize any __unexpired__ and __persistent__ cookies in the store with `cookie_to_string`
    /// and write them to `writer`
    pub fn save<W, E, F>(&self, writer: &mut W, cookie_to_string: F) -> StoreResult<()>
    where
        W: Write,
        F: Fn(&Cookie<'static>) -> Result<String, E>,
        crate::Error: From<E>,
    {
        for cookie in self.iter_unexpired().filter_map(|c| {
            if c.is_persistent() {
                Some(cookie_to_string(c))
            } else {
                None
            }
        }) {
            writeln!(writer, "{}", cookie?)?;
        }
        Ok(())
    }

    /// Serialize all (including __expired__ and __non-persistent__) cookies in the store with `cookie_to_string` and write them to `writer`
    pub fn save_incl_expired_and_nonpersistent<W, E, F>(
        &self,
        writer: &mut W,
        cookie_to_string: F,
    ) -> StoreResult<()>
    where
        W: Write,
        F: Fn(&Cookie<'static>) -> Result<String, E>,
        crate::Error: From<E>,
    {
        for cookie in self.iter_any() {
            writeln!(writer, "{}", cookie_to_string(cookie)?)?;
        }
        Ok(())
    }

    /// Load cookies from `reader`, deserializing with `cookie_from_str`, skipping any __expired__
    /// cookies
    pub fn load<R, E, F>(reader: R, cookie_from_str: F) -> StoreResult<CookieStore>
    where
        R: BufRead,
        F: Fn(&str) -> Result<Cookie<'static>, E>,
        crate::Error: From<E>,
    {
        CookieStore::load_from(reader, cookie_from_str, false)
    }

    /// Load cookies from `reader`, deserializing with `cookie_from_str`, loading both __unexpired__
    /// and __expired__ cookies
    pub fn load_all<R, E, F>(reader: R, cookie_from_str: F) -> StoreResult<CookieStore>
    where
        R: BufRead,
        F: Fn(&str) -> Result<Cookie<'static>, E>,
        crate::Error: From<E>,
    {
        CookieStore::load_from(reader, cookie_from_str, true)
    }

    fn load_from<R, E, F>(
        reader: R,
        cookie_from_str: F,
        include_expired: bool,
    ) -> StoreResult<CookieStore>
    where
        R: BufRead,
        F: Fn(&str) -> Result<Cookie<'static>, E>,
        crate::Error: From<E>,
    {
        let cookies = reader.lines().map(|line_result| {
            line_result
                .map_err(Into::into)
                .and_then(|line| cookie_from_str(&line).map_err(crate::Error::from))
        });
        Self::from_cookies(cookies, include_expired)
    }

    /// Create a `CookieStore` from an iterator of `Cookie` values. When
    /// `include_expired` is `true`, both __expired__ and __unexpired__ cookies in the incoming
    /// iterator will be included in the produced `CookieStore`; otherwise, only
    /// __unexpired__ cookies will be included, and __expired__ cookies filtered
    /// out.
    pub fn from_cookies<I, E>(iter: I, include_expired: bool) -> Result<Self, E>
    where
        I: IntoIterator<Item = Result<Cookie<'static>, E>>,
    {
        let mut cookies = Map::new();
        for cookie in iter {
            let cookie = cookie?;
            if include_expired || !cookie.is_expired() {
                cookies
                    .entry(String::from(&cookie.domain))
                    .or_insert_with(Map::new)
                    .entry(String::from(&cookie.path))
                    .or_insert_with(Map::new)
                    .insert(cookie.name().to_owned(), cookie);
            }
        }
        Ok(Self {
            cookies,
            #[cfg(feature = "public_suffix")]
            public_suffix_list: None,
        })
    }

    pub fn new() -> Self {
        Self {
            cookies: DomainMap::new(),
            #[cfg(feature = "public_suffix")]
            public_suffix_list: None,
        }
    }

    #[cfg(feature = "public_suffix")]
    pub fn new_with_public_suffix(public_suffix_list: Option<publicsuffix::List>) -> Self {
        Self {
            cookies: DomainMap::new(),
            public_suffix_list,
        }
    }
}

#[cfg(feature = "serde_json")]
/// Legacy serialization implementations. These methods do **not** produce/consume valid JSON output compatible with
/// typical JSON libraries/tools.
impl CookieStore {
    /// Serialize any __unexpired__ and __persistent__ cookies in the store to JSON format and
    /// write them to `writer`
    ///
    /// __NB__: this method does not produce valid JSON which can be directly loaded; such output
    /// must be loaded via the corresponding method [CookieStore::load_json]. For a more
    /// robust/universal
    /// JSON format, see [crate::serde::json], which produces output __incompatible__ with this
    /// method.
    #[deprecated(
        since = "0.22.0",
        note = "See `cookie_store::serde` modules for more robust de/serialization options"
    )]
    pub fn save_json<W: Write>(&self, writer: &mut W) -> StoreResult<()> {
        self.save(writer, ::serde_json::to_string)
    }

    /// Serialize all (including __expired__ and __non-persistent__) cookies in the store to JSON format and write them to `writer`
    ///
    /// __NB__: this method does not produce valid JSON which can be directly loaded; such output
    /// must be loaded via the corresponding method [CookieStore::load_json]. For a more
    /// robust/universal
    /// JSON format, see [crate::serde::json], which produces output __incompatible__ with this
    /// method.
    #[deprecated(
        since = "0.22.0",
        note = "See `cookie_store::serde` modules for more robust de/serialization options"
    )]
    pub fn save_incl_expired_and_nonpersistent_json<W: Write>(
        &self,
        writer: &mut W,
    ) -> StoreResult<()> {
        self.save_incl_expired_and_nonpersistent(writer, ::serde_json::to_string)
    }

    /// Load JSON-formatted cookies from `reader`, skipping any __expired__ cookies
    ///
    /// __NB__: this method does not expect true valid JSON; it is designed to load output
    /// from the corresponding method [CookieStore::save_json]. For a more robust/universal
    /// JSON format, see [crate::serde::json], which produces output __incompatible__ with this
    /// method.
    #[deprecated(
        since = "0.22.0",
        note = "See `cookie_store::serde` modules for more robust de/serialization options"
    )]
    pub fn load_json<R: BufRead>(reader: R) -> StoreResult<CookieStore> {
        CookieStore::load(reader, |cookie| ::serde_json::from_str(cookie))
    }

    /// Load JSON-formatted cookies from `reader`, loading both __expired__ and __unexpired__ cookies
    ///
    /// __NB__: this method does not expect true valid JSON; it is designed to load output
    /// from the corresponding method [CookieStore::save_json]. For a more robust/universal
    /// JSON format, see [crate::serde::json], which produces output __incompatible__ with this
    /// method.
    #[deprecated(
        since = "0.22.0",
        note = "See `cookie_store::serde` modules for more robust de/serialization options"
    )]
    pub fn load_json_all<R: BufRead>(reader: R) -> StoreResult<CookieStore> {
        CookieStore::load_all(reader, |cookie| ::serde_json::from_str(cookie))
    }
}

#[cfg(feature = "serde")]
/// Legacy de/serialization implementation which elides the collection-nature of the contained
/// cookies. Suitable for line-oriented cookie persistence, but prefer/consider
/// `cookie_store::serde` modules for more universally consumable serialization formats.
mod serde_legacy {
    use serde::de::{SeqAccess, Visitor};
    use serde::{Deserialize, Deserializer, Serialize, Serializer};

    impl Serialize for super::CookieStore {
        fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
        where
            S: Serializer,
        {
            serializer.collect_seq(self.iter_unexpired().filter(|c| c.is_persistent()))
        }
    }

    struct CookieStoreVisitor;

    impl<'de> Visitor<'de> for CookieStoreVisitor {
        type Value = super::CookieStore;

        fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            write!(formatter, "a sequence of cookies")
        }

        fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
        where
            A: SeqAccess<'de>,
        {
            super::CookieStore::from_cookies(
                std::iter::from_fn(|| seq.next_element().transpose()),
                false,
            )
        }
    }

    impl<'de> Deserialize<'de> for super::CookieStore {
        fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
        where
            D: Deserializer<'de>,
        {
            deserializer.deserialize_seq(CookieStoreVisitor)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::CookieStore;
    use super::{InsertResult, StoreAction};
    use crate::cookie::Cookie;
    use crate::CookieError;
    use ::cookie::Cookie as RawCookie;
    use time::OffsetDateTime;

    use crate::utils::test as test_utils;

    macro_rules! inserted {
        ($e: expr) => {
            assert_eq!(Ok(StoreAction::Inserted), $e)
        };
    }
    macro_rules! updated {
        ($e: expr) => {
            assert_eq!(Ok(StoreAction::UpdatedExisting), $e)
        };
    }
    macro_rules! expired_existing {
        ($e: expr) => {
            assert_eq!(Ok(StoreAction::ExpiredExisting), $e)
        };
    }
    macro_rules! domain_mismatch {
        ($e: expr) => {
            assert_eq!(Err(CookieError::DomainMismatch), $e)
        };
    }
    macro_rules! non_http_scheme {
        ($e: expr) => {
            assert_eq!(Err(CookieError::NonHttpScheme), $e)
        };
    }
    macro_rules! non_rel_scheme {
        ($e: expr) => {
            assert_eq!(Err(CookieError::NonRelativeScheme), $e)
        };
    }
    macro_rules! expired_err {
        ($e: expr) => {
            assert_eq!(Err(CookieError::Expired), $e)
        };
    }
    macro_rules! values_are {
        ($store: expr, $url: expr, $values: expr) => {{
            let mut matched_values = $store
                .matches(&test_utils::url($url))
                .iter()
                .map(|c| &c.value()[..])
                .collect::<Vec<_>>();
            matched_values.sort();

            let mut values: Vec<&str> = $values;
            values.sort();

            assert!(
                matched_values == values,
                "\n{:?}\n!=\n{:?}\n",
                matched_values,
                values
            );
        }};
    }

    fn add_cookie(
        store: &mut CookieStore,
        cookie: &str,
        url: &str,
        expires: Option<OffsetDateTime>,
        max_age: Option<u64>,
    ) -> InsertResult {
        store.insert(
            test_utils::make_cookie(cookie, url, expires, max_age),
            &test_utils::url(url),
        )
    }

    fn make_match_store() -> CookieStore {
        let mut store = CookieStore::default();
        inserted!(add_cookie(
            &mut store,
            "cookie1=1",
            "http://example.com/foo/bar",
            None,
            Some(60 * 5),
        ));
        inserted!(add_cookie(
            &mut store,
            "cookie2=2; Secure",
            "https://example.com/sec/",
            None,
            Some(60 * 5),
        ));
        inserted!(add_cookie(
            &mut store,
            "cookie3=3; HttpOnly",
            "https://example.com/sec/",
            None,
            Some(60 * 5),
        ));
        inserted!(add_cookie(
            &mut store,
            "cookie4=4; Secure; HttpOnly",
            "https://example.com/sec/",
            None,
            Some(60 * 5),
        ));
        inserted!(add_cookie(
            &mut store,
            "cookie5=5",
            "http://example.com/foo/",
            None,
            Some(60 * 5),
        ));
        inserted!(add_cookie(
            &mut store,
            "cookie6=6",
            "http://example.com/",
            None,
            Some(60 * 5),
        ));
        inserted!(add_cookie(
            &mut store,
            "cookie7=7",
            "http://bar.example.com/foo/",
            None,
            Some(60 * 5),
        ));

        inserted!(add_cookie(
            &mut store,
            "cookie8=8",
            "http://example.org/foo/bar",
            None,
            Some(60 * 5),
        ));
        inserted!(add_cookie(
            &mut store,
            "cookie9=9",
            "http://bar.example.org/foo/bar",
            None,
            Some(60 * 5),
        ));
        store
    }

    macro_rules! check_matches {
        ($store: expr) => {{
            values_are!($store, "http://unknowndomain.org/foo/bar", vec![]);
            values_are!($store, "http://example.org/foo/bar", vec!["8"]);
            values_are!($store, "http://example.org/bus/bar", vec![]);
            values_are!($store, "http://bar.example.org/foo/bar", vec!["9"]);
            values_are!($store, "http://bar.example.org/bus/bar", vec![]);
            values_are!(
                $store,
                "https://example.com/sec/foo",
                vec!["6", "4", "3", "2"]
            );
            values_are!($store, "http://example.com/sec/foo", vec!["6", "3"]);
            values_are!($store, "ftp://example.com/sec/foo", vec!["6"]);
            values_are!($store, "http://bar.example.com/foo/bar/bus", vec!["7"]);
            values_are!(
                $store,
                "http://example.com/foo/bar/bus",
                vec!["1", "5", "6"]
            );
        }};
    }

    #[test]
    fn insert_raw() {
        let mut store = CookieStore::default();
        inserted!(store.insert_raw(
            &RawCookie::parse("cookie1=value1").unwrap(),
            &test_utils::url("http://example.com/foo/bar"),
        ));
        non_rel_scheme!(store.insert_raw(
            &RawCookie::parse("cookie1=value1").unwrap(),
            &test_utils::url("data:nonrelativescheme"),
        ));
        non_http_scheme!(store.insert_raw(
            &RawCookie::parse("cookie1=value1; HttpOnly").unwrap(),
            &test_utils::url("ftp://example.com/"),
        ));
        expired_existing!(store.insert_raw(
            &RawCookie::parse("cookie1=value1; Max-Age=0").unwrap(),
            &test_utils::url("http://example.com/foo/bar"),
        ));
        expired_err!(store.insert_raw(
            &RawCookie::parse("cookie1=value1; Max-Age=-1").unwrap(),
            &test_utils::url("http://example.com/foo/bar"),
        ));
        updated!(store.insert_raw(
            &RawCookie::parse("cookie1=value1").unwrap(),
            &test_utils::url("http://example.com/foo/bar"),
        ));
        expired_existing!(store.insert_raw(
            &RawCookie::parse("cookie1=value1; Max-Age=-1").unwrap(),
            &test_utils::url("http://example.com/foo/bar"),
        ));
        domain_mismatch!(store.insert_raw(
            &RawCookie::parse("cookie1=value1; Domain=bar.example.com").unwrap(),
            &test_utils::url("http://example.com/foo/bar"),
        ));
    }

    #[test]
    fn parse() {
        let mut store = CookieStore::default();
        inserted!(store.parse(
            "cookie1=value1",
            &test_utils::url("http://example.com/foo/bar"),
        ));
        non_rel_scheme!(store.parse("cookie1=value1", &test_utils::url("data:nonrelativescheme"),));
        non_http_scheme!(store.parse(
            "cookie1=value1; HttpOnly",
            &test_utils::url("ftp://example.com/"),
        ));
        expired_existing!(store.parse(
            "cookie1=value1; Max-Age=0",
            &test_utils::url("http://example.com/foo/bar"),
        ));
        expired_err!(store.parse(
            "cookie1=value1; Max-Age=-1",
            &test_utils::url("http://example.com/foo/bar"),
        ));
        updated!(store.parse(
            "cookie1=value1",
            &test_utils::url("http://example.com/foo/bar"),
        ));
        expired_existing!(store.parse(
            "cookie1=value1; Max-Age=-1",
            &test_utils::url("http://example.com/foo/bar"),
        ));
        domain_mismatch!(store.parse(
            "cookie1=value1; Domain=bar.example.com",
            &test_utils::url("http://example.com/foo/bar"),
        ));
    }

    #[test]
    fn domains() {
        let mut store = CookieStore::default();
        //        The user agent will reject cookies unless the Domain attribute
        // specifies a scope for the cookie that would include the origin
        // server.  For example, the user agent will accept a cookie with a
        // Domain attribute of "example.com" or of "foo.example.com" from
        // foo.example.com, but the user agent will not accept a cookie with a
        // Domain attribute of "bar.example.com" or of "baz.foo.example.com".
        fn domain_cookie_from(domain: &str, request_url: &str) -> Cookie<'static> {
            let cookie_str = format!("cookie1=value1; Domain={}", domain);
            Cookie::parse(cookie_str, &test_utils::url(request_url)).unwrap()
        }

        {
            let request_url = test_utils::url("http://foo.example.com");
            // foo.example.com can submit cookies for example.com and foo.example.com
            inserted!(store.insert(
                domain_cookie_from("example.com", "http://foo.example.com",),
                &request_url,
            ));
            updated!(store.insert(
                domain_cookie_from(".example.com", "http://foo.example.com",),
                &request_url,
            ));
            inserted!(store.insert(
                domain_cookie_from("foo.example.com", "http://foo.example.com",),
                &request_url,
            ));
            updated!(store.insert(
                domain_cookie_from(".foo.example.com", "http://foo.example.com",),
                &request_url,
            ));
            // not for bar.example.com
            domain_mismatch!(store.insert(
                domain_cookie_from("bar.example.com", "http://bar.example.com",),
                &request_url,
            ));
            domain_mismatch!(store.insert(
                domain_cookie_from(".bar.example.com", "http://bar.example.com",),
                &request_url,
            ));
            // not for bar.foo.example.com
            domain_mismatch!(store.insert(
                domain_cookie_from("bar.foo.example.com", "http://bar.foo.example.com",),
                &request_url,
            ));
            domain_mismatch!(store.insert(
                domain_cookie_from(".bar.foo.example.com", "http://bar.foo.example.com",),
                &request_url,
            ));
        }

        {
            let request_url = test_utils::url("http://bar.example.com");
            // bar.example.com can submit for example.com and bar.example.com
            updated!(store.insert(
                domain_cookie_from("example.com", "http://foo.example.com",),
                &request_url,
            ));
            updated!(store.insert(
                domain_cookie_from(".example.com", "http://foo.example.com",),
                &request_url,
            ));
            inserted!(store.insert(
                domain_cookie_from("bar.example.com", "http://bar.example.com",),
                &request_url,
            ));
            updated!(store.insert(
                domain_cookie_from(".bar.example.com", "http://bar.example.com",),
                &request_url,
            ));
            // bar.example.com cannot submit for foo.example.com
            domain_mismatch!(store.insert(
                domain_cookie_from("foo.example.com", "http://foo.example.com",),
                &request_url,
            ));
            domain_mismatch!(store.insert(
                domain_cookie_from(".foo.example.com", "http://foo.example.com",),
                &request_url,
            ));
        }
        {
            let request_url = test_utils::url("http://example.com");
            // example.com can submit for example.com
            updated!(store.insert(
                domain_cookie_from("example.com", "http://foo.example.com",),
                &request_url,
            ));
            updated!(store.insert(
                domain_cookie_from(".example.com", "http://foo.example.com",),
                &request_url,
            ));
            // example.com cannot submit for foo.example.com or bar.example.com
            domain_mismatch!(store.insert(
                domain_cookie_from("foo.example.com", "http://foo.example.com",),
                &request_url,
            ));
            domain_mismatch!(store.insert(
                domain_cookie_from(".foo.example.com", "http://foo.example.com",),
                &request_url,
            ));
            domain_mismatch!(store.insert(
                domain_cookie_from("bar.example.com", "http://bar.example.com",),
                &request_url,
            ));
            domain_mismatch!(store.insert(
                domain_cookie_from(".bar.example.com", "http://bar.example.com",),
                &request_url,
            ));
        }
    }

    #[test]
    fn http_only() {
        let mut store = CookieStore::default();
        let c = Cookie::parse(
            "cookie1=value1; HttpOnly",
            &test_utils::url("http://example.com/foo/bar"),
        )
        .unwrap();
        // cannot add a HttpOnly cookies from a non-http source
        non_http_scheme!(store.insert(c, &test_utils::url("ftp://example.com/foo/bar"),));
    }

    #[test]
    fn clear() {
        let mut store = CookieStore::default();
        inserted!(add_cookie(
            &mut store,
            "cookie1=value1",
            "http://example.com/foo/bar",
            Some(test_utils::in_days(1)),
            None,
        ));
        assert!(
            store
                .iter_any()
                .any(|c| c.name_value() == ("cookie1", "value1")),
            "did not find expected cookie1=value1 cookie in store"
        );
        store.clear();
        assert!(
            store.iter_any().count() == 0,
            "found unexpected cookies in cleared store"
        );
    }

    #[test]
    fn add_and_get() {
        let mut store = CookieStore::default();
        assert!(store.get("example.com", "/foo", "cookie1").is_none());

        inserted!(add_cookie(
            &mut store,
            "cookie1=value1",
            "http://example.com/foo/bar",
            None,
            None,
        ));
        assert!(store.get("example.com", "/foo/bar", "cookie1").is_none());
        assert!(store.get("example.com", "/foo", "cookie2").is_none());
        assert!(store.get("example.org", "/foo", "cookie1").is_none());
        assert!(store.get("example.com", "/foo", "cookie1").unwrap().value() == "value1");

        updated!(add_cookie(
            &mut store,
            "cookie1=value2",
            "http://example.com/foo/bar",
            None,
            None,
        ));
        assert!(store.get("example.com", "/foo", "cookie1").unwrap().value() == "value2");

        inserted!(add_cookie(
            &mut store,
            "cookie2=value3",
            "http://example.com/foo/bar",
            None,
            None,
        ));
        assert!(store.get("example.com", "/foo", "cookie1").unwrap().value() == "value2");
        assert!(store.get("example.com", "/foo", "cookie2").unwrap().value() == "value3");

        inserted!(add_cookie(
            &mut store,
            "cookie3=value4; HttpOnly",
            "http://example.com/foo/bar",
            None,
            None,
        ));
        assert!(store.get("example.com", "/foo", "cookie1").unwrap().value() == "value2");
        assert!(store.get("example.com", "/foo", "cookie2").unwrap().value() == "value3");
        assert!(store.get("example.com", "/foo", "cookie3").unwrap().value() == "value4");

        non_http_scheme!(add_cookie(
            &mut store,
            "cookie3=value5",
            "ftp://example.com/foo/bar",
            None,
            None,
        ));
        assert!(store.get("example.com", "/foo", "cookie1").unwrap().value() == "value2");
        assert!(store.get("example.com", "/foo", "cookie2").unwrap().value() == "value3");
        assert!(store.get("example.com", "/foo", "cookie3").unwrap().value() == "value4");
    }

    #[test]
    fn matches() {
        let store = make_match_store();
        check_matches!(&store);
    }

    fn matches_are(store: &CookieStore, url: &str, exp: Vec<&str>) {
        let matches = store
            .matches(&test_utils::url(url))
            .iter()
            .map(|c| format!("{}={}", c.name(), c.value()))
            .collect::<Vec<_>>();
        for e in &exp {
            assert!(
                matches.iter().any(|m| &m[..] == *e),
                "{}: matches missing '{}'\nmatches: {:?}\n    exp: {:?}",
                url,
                e,
                matches,
                exp
            );
        }
        assert!(
            matches.len() == exp.len(),
            "{}: matches={:?} != exp={:?}",
            url,
            matches,
            exp
        );
    }

    #[test]
    fn some_non_https_uris_are_secure() {
        // Matching the list in Firefox's regression test:
        // https://hg.mozilla.org/integration/autoland/rev/c4d13b3ca1e2
        let secure_uris = vec![
            "http://localhost",
            "http://localhost:1234",
            "http://127.0.0.1",
            "http://127.0.0.2",
            "http://127.1.0.1",
            "http://[::1]",
        ];
        for secure_uri in secure_uris {
            let mut store = CookieStore::default();
            inserted!(add_cookie(
                &mut store,
                "cookie1=1a; Secure",
                secure_uri,
                None,
                None,
            ));
            matches_are(&store, secure_uri, vec!["cookie1=1a"]);
        }
    }

    #[cfg(feature = "serde_json")]
    macro_rules! dump_json {
        ($e: expr, $i: ident) => {{
            use serde_json;
            println!("");
            println!(
                "==== {}: {} ====",
                $e,
                time::OffsetDateTime::now_utc()
                    .format(crate::rfc3339_fmt::RFC3339_FORMAT)
                    .unwrap()
            );
            for c in $i.iter_any() {
                println!(
                    "{} {}",
                    if c.is_expired() {
                        "XXXXX"
                    } else if c.is_persistent() {
                        "PPPPP"
                    } else {
                        "     "
                    },
                    serde_json::to_string(c).unwrap()
                );
                println!("----------------");
            }
            println!("================");
        }};
    }

    #[test]
    fn domain_collisions() {
        let mut store = CookieStore::default();
        // - HostOnly, so no collisions here
        inserted!(add_cookie(
            &mut store,
            "cookie1=1a",
            "http://foo.bus.example.com/",
            None,
            None,
        ));
        inserted!(add_cookie(
            &mut store,
            "cookie1=1b",
            "http://bus.example.com/",
            None,
            None,
        ));
        // - Suffix
        // both cookie2's domain-match bus.example.com
        inserted!(add_cookie(
            &mut store,
            "cookie2=2a; Domain=bus.example.com",
            "http://foo.bus.example.com/",
            None,
            None,
        ));
        inserted!(add_cookie(
            &mut store,
            "cookie2=2b; Domain=example.com",
            "http://bus.example.com/",
            None,
            None,
        ));
        #[cfg(feature = "serde_json")]
        dump_json!("domain_collisions", store);
        matches_are(
            &store,
            "http://foo.bus.example.com/",
            vec!["cookie1=1a", "cookie2=2a", "cookie2=2b"],
        );
        matches_are(
            &store,
            "http://bus.example.com/",
            vec!["cookie1=1b", "cookie2=2a", "cookie2=2b"],
        );
        matches_are(&store, "http://example.com/", vec!["cookie2=2b"]);
        matches_are(&store, "http://foo.example.com/", vec!["cookie2=2b"]);
    }

    #[test]
    fn path_collisions() {
        let mut store = CookieStore::default();
        // will be default-path: /foo/bar, and /foo, resp.
        // both should match /foo/bar/
        inserted!(add_cookie(
            &mut store,
            "cookie3=3a",
            "http://bus.example.com/foo/bar/",
            None,
            None,
        ));
        inserted!(add_cookie(
            &mut store,
            "cookie3=3b",
            "http://bus.example.com/foo/",
            None,
            None,
        ));
        // - Path set explicitly
        inserted!(add_cookie(
            &mut store,
            "cookie4=4a; Path=/foo/bar/",
            "http://bus.example.com/",
            None,
            None,
        ));
        inserted!(add_cookie(
            &mut store,
            "cookie4=4b; Path=/foo/",
            "http://bus.example.com/",
            None,
            None,
        ));
        #[cfg(feature = "serde_json")]
        dump_json!("path_collisions", store);
        matches_are(
            &store,
            "http://bus.example.com/foo/bar/",
            vec!["cookie3=3a", "cookie3=3b", "cookie4=4a", "cookie4=4b"],
        );
        // Agrees w/ chrome, but not FF... FF also sends cookie4=4a, but this should be
        // a path-match
        // fail since request-uri /foo/bar is a *prefix* of the cookie path /foo/bar/
        matches_are(
            &store,
            "http://bus.example.com/foo/bar",
            vec!["cookie3=3a", "cookie3=3b", "cookie4=4b"],
        );
        matches_are(
            &store,
            "http://bus.example.com/foo/ba",
            vec!["cookie3=3b", "cookie4=4b"],
        );
        matches_are(
            &store,
            "http://bus.example.com/foo/",
            vec!["cookie3=3b", "cookie4=4b"],
        );
        // Agrees w/ chrome, but not FF... FF also sends cookie4=4b, but this should be
        // a path-match
        // fail since request-uri /foo is a *prefix* of the cookie path /foo/
        matches_are(&store, "http://bus.example.com/foo", vec!["cookie3=3b"]);
        matches_are(&store, "http://bus.example.com/fo", vec![]);
        matches_are(&store, "http://bus.example.com/", vec![]);
        matches_are(&store, "http://bus.example.com", vec![]);
    }

    #[cfg(feature = "serde_json")]
    #[allow(deprecated)]
    mod serde_json_tests {
        use super::{add_cookie, make_match_store, CookieStore, StoreAction};
        use crate::cookie::Cookie;
        use crate::CookieError;

        use crate::utils::test as test_utils;

        macro_rules! has_str {
            ($e: expr, $i: ident) => {{
                let val = std::str::from_utf8(&$i[..]).unwrap();
                assert!(val.contains($e), "exp: {}\nval: {}", $e, val);
            }};
        }
        macro_rules! not_has_str {
            ($e: expr, $i: ident) => {{
                let val = std::str::from_utf8(&$i[..]).unwrap();
                assert!(!val.contains($e), "exp: {}\nval: {}", $e, val);
            }};
        }

        #[test]
        fn save_json() {
            let mut output = vec![];
            let mut store = CookieStore::default();
            store.save_json(&mut output).unwrap();
            assert_eq!("", std::str::from_utf8(&output[..]).unwrap());
            // non-persistent cookie, should not be saved
            inserted!(add_cookie(
                &mut store,
                "cookie0=value0",
                "http://example.com/foo/bar",
                None,
                None,
            ));
            store.save_json(&mut output).unwrap();
            assert_eq!("", std::str::from_utf8(&output[..]).unwrap());

            // persistent cookie, Max-Age
            inserted!(add_cookie(
                &mut store,
                "cookie1=value1",
                "http://example.com/foo/bar",
                None,
                Some(10),
            ));
            store.save_json(&mut output).unwrap();
            not_has_str!("cookie0=value0", output);
            has_str!("cookie1=value1", output);
            output.clear();

            // persistent cookie, Expires
            inserted!(add_cookie(
                &mut store,
                "cookie2=value2",
                "http://example.com/foo/bar",
                Some(test_utils::in_days(1)),
                None,
            ));
            store.save_json(&mut output).unwrap();
            not_has_str!("cookie0=value0", output);
            has_str!("cookie1=value1", output);
            has_str!("cookie2=value2", output);
            output.clear();

            inserted!(add_cookie(
                &mut store,
                "cookie3=value3; Domain=example.com",
                "http://foo.example.com/foo/bar",
                Some(test_utils::in_days(1)),
                None,
            ));
            inserted!(add_cookie(
                &mut store,
                "cookie4=value4; Path=/foo/",
                "http://foo.example.com/foo/bar",
                Some(test_utils::in_days(1)),
                None,
            ));
            inserted!(add_cookie(
                &mut store,
                "cookie5=value5",
                "http://127.0.0.1/foo/bar",
                Some(test_utils::in_days(1)),
                None,
            ));
            inserted!(add_cookie(
                &mut store,
                "cookie6=value6",
                "http://[::1]/foo/bar",
                Some(test_utils::in_days(1)),
                None,
            ));
            inserted!(add_cookie(
                &mut store,
                "cookie7=value7; Secure",
                "https://[::1]/foo/bar",
                Some(test_utils::in_days(1)),
                None,
            ));
            inserted!(add_cookie(
                &mut store,
                "cookie8=value8; HttpOnly",
                "http://[::1]/foo/bar",
                Some(test_utils::in_days(1)),
                None,
            ));
            store.save_json(&mut output).unwrap();
            not_has_str!("cookie0=value0", output);
            has_str!("cookie1=value1", output);
            has_str!("cookie2=value2", output);
            has_str!("cookie3=value3", output);
            has_str!("cookie4=value4", output);
            has_str!("cookie5=value5", output);
            has_str!("cookie6=value6", output);
            has_str!("cookie7=value7; Secure", output);
            has_str!("cookie8=value8; HttpOnly", output);
            output.clear();
        }

        #[test]
        fn serialize_json() {
            let mut output = vec![];
            let mut store = CookieStore::default();
            serde_json::to_writer(&mut output, &store).unwrap();
            assert_eq!("[]", std::str::from_utf8(&output[..]).unwrap());
            output.clear();

            // non-persistent cookie, should not be saved
            inserted!(add_cookie(
                &mut store,
                "cookie0=value0",
                "http://example.com/foo/bar",
                None,
                None,
            ));
            serde_json::to_writer(&mut output, &store).unwrap();
            assert_eq!("[]", std::str::from_utf8(&output[..]).unwrap());
            output.clear();

            // persistent cookie, Max-Age
            inserted!(add_cookie(
                &mut store,
                "cookie1=value1",
                "http://example.com/foo/bar",
                None,
                Some(10),
            ));
            serde_json::to_writer(&mut output, &store).unwrap();
            not_has_str!("cookie0=value0", output);
            has_str!("cookie1=value1", output);
            output.clear();

            // persistent cookie, Expires
            inserted!(add_cookie(
                &mut store,
                "cookie2=value2",
                "http://example.com/foo/bar",
                Some(test_utils::in_days(1)),
                None,
            ));
            serde_json::to_writer(&mut output, &store).unwrap();
            not_has_str!("cookie0=value0", output);
            has_str!("cookie1=value1", output);
            has_str!("cookie2=value2", output);
            output.clear();

            inserted!(add_cookie(
                &mut store,
                "cookie3=value3; Domain=example.com",
                "http://foo.example.com/foo/bar",
                Some(test_utils::in_days(1)),
                None,
            ));
            inserted!(add_cookie(
                &mut store,
                "cookie4=value4; Path=/foo/",
                "http://foo.example.com/foo/bar",
                Some(test_utils::in_days(1)),
                None,
            ));
            inserted!(add_cookie(
                &mut store,
                "cookie5=value5",
                "http://127.0.0.1/foo/bar",
                Some(test_utils::in_days(1)),
                None,
            ));
            inserted!(add_cookie(
                &mut store,
                "cookie6=value6",
                "http://[::1]/foo/bar",
                Some(test_utils::in_days(1)),
                None,
            ));
            inserted!(add_cookie(
                &mut store,
                "cookie7=value7; Secure",
                "https://[::1]/foo/bar",
                Some(test_utils::in_days(1)),
                None,
            ));
            inserted!(add_cookie(
                &mut store,
                "cookie8=value8; HttpOnly",
                "http://[::1]/foo/bar",
                Some(test_utils::in_days(1)),
                None,
            ));
            serde_json::to_writer(&mut output, &store).unwrap();
            not_has_str!("cookie0=value0", output);
            has_str!("cookie1=value1", output);
            has_str!("cookie2=value2", output);
            has_str!("cookie3=value3", output);
            has_str!("cookie4=value4", output);
            has_str!("cookie5=value5", output);
            has_str!("cookie6=value6", output);
            has_str!("cookie7=value7; Secure", output);
            has_str!("cookie8=value8; HttpOnly", output);
            output.clear();
        }

        #[test]
        fn load_json() {
            let mut store = CookieStore::default();
            // non-persistent cookie, should not be saved
            inserted!(add_cookie(
                &mut store,
                "cookie0=value0",
                "http://example.com/foo/bar",
                None,
                None,
            ));
            // persistent cookie, Max-Age
            inserted!(add_cookie(
                &mut store,
                "cookie1=value1",
                "http://example.com/foo/bar",
                None,
                Some(10),
            ));
            // persistent cookie, Expires
            inserted!(add_cookie(
                &mut store,
                "cookie2=value2",
                "http://example.com/foo/bar",
                Some(test_utils::in_days(1)),
                None,
            ));
            inserted!(add_cookie(
                &mut store,
                "cookie3=value3; Domain=example.com",
                "http://foo.example.com/foo/bar",
                Some(test_utils::in_days(1)),
                None,
            ));
            inserted!(add_cookie(
                &mut store,
                "cookie4=value4; Path=/foo/",
                "http://foo.example.com/foo/bar",
                Some(test_utils::in_days(1)),
                None,
            ));
            inserted!(add_cookie(
                &mut store,
                "cookie5=value5",
                "http://127.0.0.1/foo/bar",
                Some(test_utils::in_days(1)),
                None,
            ));
            inserted!(add_cookie(
                &mut store,
                "cookie6=value6",
                "http://[::1]/foo/bar",
                Some(test_utils::in_days(1)),
                None,
            ));
            inserted!(add_cookie(
                &mut store,
                "cookie7=value7; Secure",
                "http://example.com/foo/bar",
                Some(test_utils::in_days(1)),
                None,
            ));
            inserted!(add_cookie(
                &mut store,
                "cookie8=value8; HttpOnly",
                "http://example.com/foo/bar",
                Some(test_utils::in_days(1)),
                None,
            ));
            let mut output = vec![];
            store.save_json(&mut output).unwrap();
            not_has_str!("cookie0=value0", output);
            has_str!("cookie1=value1", output);
            has_str!("cookie2=value2", output);
            has_str!("cookie3=value3", output);
            has_str!("cookie4=value4", output);
            has_str!("cookie5=value5", output);
            has_str!("cookie6=value6", output);
            has_str!("cookie7=value7; Secure", output);
            has_str!("cookie8=value8; HttpOnly", output);
            let store = CookieStore::load_json(&output[..]).unwrap();
            assert!(store.get("example.com", "/foo", "cookie0").is_none());
            assert!(store.get("example.com", "/foo", "cookie1").unwrap().value() == "value1");
            assert!(store.get("example.com", "/foo", "cookie2").unwrap().value() == "value2");
            assert!(store.get("example.com", "/foo", "cookie3").unwrap().value() == "value3");
            assert!(
                store
                    .get("foo.example.com", "/foo/", "cookie4")
                    .unwrap()
                    .value()
                    == "value4"
            );
            assert!(store.get("127.0.0.1", "/foo", "cookie5").unwrap().value() == "value5");
            assert!(store.get("[::1]", "/foo", "cookie6").unwrap().value() == "value6");
            assert!(store.get("example.com", "/foo", "cookie7").unwrap().value() == "value7");
            assert!(store.get("example.com", "/foo", "cookie8").unwrap().value() == "value8");

            output.clear();
            let store = make_match_store();
            store.save_json(&mut output).unwrap();
            let store = CookieStore::load_json(&output[..]).unwrap();
            check_matches!(&store);
        }

        #[test]
        fn deserialize_json() {
            let mut store = CookieStore::default();
            // non-persistent cookie, should not be saved
            inserted!(add_cookie(
                &mut store,
                "cookie0=value0",
                "http://example.com/foo/bar",
                None,
                None,
            ));
            // persistent cookie, Max-Age
            inserted!(add_cookie(
                &mut store,
                "cookie1=value1",
                "http://example.com/foo/bar",
                None,
                Some(10),
            ));
            // persistent cookie, Expires
            inserted!(add_cookie(
                &mut store,
                "cookie2=value2",
                "http://example.com/foo/bar",
                Some(test_utils::in_days(1)),
                None,
            ));
            inserted!(add_cookie(
                &mut store,
                "cookie3=value3; Domain=example.com",
                "http://foo.example.com/foo/bar",
                Some(test_utils::in_days(1)),
                None,
            ));
            inserted!(add_cookie(
                &mut store,
                "cookie4=value4; Path=/foo/",
                "http://foo.example.com/foo/bar",
                Some(test_utils::in_days(1)),
                None,
            ));
            inserted!(add_cookie(
                &mut store,
                "cookie5=value5",
                "http://127.0.0.1/foo/bar",
                Some(test_utils::in_days(1)),
                None,
            ));
            inserted!(add_cookie(
                &mut store,
                "cookie6=value6",
                "http://[::1]/foo/bar",
                Some(test_utils::in_days(1)),
                None,
            ));
            inserted!(add_cookie(
                &mut store,
                "cookie7=value7; Secure",
                "http://example.com/foo/bar",
                Some(test_utils::in_days(1)),
                None,
            ));
            inserted!(add_cookie(
                &mut store,
                "cookie8=value8; HttpOnly",
                "http://example.com/foo/bar",
                Some(test_utils::in_days(1)),
                None,
            ));
            let mut output = vec![];
            serde_json::to_writer(&mut output, &store).unwrap();
            not_has_str!("cookie0=value0", output);
            has_str!("cookie1=value1", output);
            has_str!("cookie2=value2", output);
            has_str!("cookie3=value3", output);
            has_str!("cookie4=value4", output);
            has_str!("cookie5=value5", output);
            has_str!("cookie6=value6", output);
            has_str!("cookie7=value7; Secure", output);
            has_str!("cookie8=value8; HttpOnly", output);
            let store: CookieStore = serde_json::from_reader(&output[..]).unwrap();
            assert!(store.get("example.com", "/foo", "cookie0").is_none());
            assert!(store.get("example.com", "/foo", "cookie1").unwrap().value() == "value1");
            assert!(store.get("example.com", "/foo", "cookie2").unwrap().value() == "value2");
            assert!(store.get("example.com", "/foo", "cookie3").unwrap().value() == "value3");
            assert!(
                store
                    .get("foo.example.com", "/foo/", "cookie4")
                    .unwrap()
                    .value()
                    == "value4"
            );
            assert!(store.get("127.0.0.1", "/foo", "cookie5").unwrap().value() == "value5");
            assert!(store.get("[::1]", "/foo", "cookie6").unwrap().value() == "value6");
            assert!(store.get("example.com", "/foo", "cookie7").unwrap().value() == "value7");
            assert!(store.get("example.com", "/foo", "cookie8").unwrap().value() == "value8");

            output.clear();
            let store = make_match_store();
            serde_json::to_writer(&mut output, &store).unwrap();
            let store: CookieStore = serde_json::from_reader(&output[..]).unwrap();
            check_matches!(&store);
        }

        #[test]
        fn expiry_json() {
            let mut store = make_match_store();
            let request_url = test_utils::url("http://foo.example.com");
            let expired_cookie = Cookie::parse("cookie1=value1; Max-Age=-1", &request_url).unwrap();
            expired_err!(store.insert(expired_cookie, &request_url));
            check_matches!(&store);
            match store.get_mut("example.com", "/", "cookie6") {
                Some(cookie) => cookie.expire(),
                None => unreachable!(),
            }
            values_are!(store, "http://unknowndomain.org/foo/bar", vec![]);
            values_are!(store, "http://example.org/foo/bar", vec!["8"]);
            values_are!(store, "http://example.org/bus/bar", vec![]);
            values_are!(store, "http://bar.example.org/foo/bar", vec!["9"]);
            values_are!(store, "http://bar.example.org/bus/bar", vec![]);
            values_are!(store, "https://example.com/sec/foo", vec!["4", "3", "2"]);
            values_are!(store, "http://example.com/sec/foo", vec!["3"]);
            values_are!(store, "ftp://example.com/sec/foo", vec![]);
            values_are!(store, "http://bar.example.com/foo/bar/bus", vec!["7"]);
            values_are!(store, "http://example.com/foo/bar/bus", vec!["1", "5"]);
            match store.get_any("example.com", "/", "cookie6") {
                Some(cookie) => assert!(cookie.is_expired()),
                None => unreachable!(),
            }
            // inserting an expired cookie that matches an existing cookie should expire
            // the existing
            let request_url = test_utils::url("http://example.com/foo/");
            let expired_cookie = Cookie::parse("cookie5=value5; Max-Age=-1", &request_url).unwrap();
            expired_existing!(store.insert(expired_cookie, &request_url));
            values_are!(store, "http://unknowndomain.org/foo/bar", vec![]);
            values_are!(store, "http://example.org/foo/bar", vec!["8"]);
            values_are!(store, "http://example.org/bus/bar", vec![]);
            values_are!(store, "http://bar.example.org/foo/bar", vec!["9"]);
            values_are!(store, "http://bar.example.org/bus/bar", vec![]);
            values_are!(store, "https://example.com/sec/foo", vec!["4", "3", "2"]);
            values_are!(store, "http://example.com/sec/foo", vec!["3"]);
            values_are!(store, "ftp://example.com/sec/foo", vec![]);
            values_are!(store, "http://bar.example.com/foo/bar/bus", vec!["7"]);
            values_are!(store, "http://example.com/foo/bar/bus", vec!["1"]);
            match store.get_any("example.com", "/foo", "cookie5") {
                Some(cookie) => assert!(cookie.is_expired()),
                None => unreachable!(),
            }
            // save and loading the store should drop any expired cookies
            let mut output = vec![];
            store.save_json(&mut output).unwrap();
            store = CookieStore::load_json(&output[..]).unwrap();
            values_are!(store, "http://unknowndomain.org/foo/bar", vec![]);
            values_are!(store, "http://example.org/foo/bar", vec!["8"]);
            values_are!(store, "http://example.org/bus/bar", vec![]);
            values_are!(store, "http://bar.example.org/foo/bar", vec!["9"]);
            values_are!(store, "http://bar.example.org/bus/bar", vec![]);
            values_are!(store, "https://example.com/sec/foo", vec!["4", "3", "2"]);
            values_are!(store, "http://example.com/sec/foo", vec!["3"]);
            values_are!(store, "ftp://example.com/sec/foo", vec![]);
            values_are!(store, "http://bar.example.com/foo/bar/bus", vec!["7"]);
            values_are!(store, "http://example.com/foo/bar/bus", vec!["1"]);
            assert!(store.get_any("example.com", "/", "cookie6").is_none());
            assert!(store.get_any("example.com", "/foo", "cookie5").is_none());
        }

        #[test]
        fn non_persistent_json() {
            let mut store = make_match_store();
            check_matches!(&store);
            let request_url = test_utils::url("http://example.com/tmp/");
            let non_persistent = Cookie::parse("cookie10=value10", &request_url).unwrap();
            inserted!(store.insert(non_persistent, &request_url));
            match store.get("example.com", "/tmp", "cookie10") {
                None => unreachable!(),
                Some(cookie) => assert_eq!("value10", cookie.value()),
            }
            // save and loading the store should drop any non-persistent cookies
            let mut output = vec![];
            store.save_json(&mut output).unwrap();
            store = CookieStore::load_json(&output[..]).unwrap();
            check_matches!(&store);
            assert!(store.get("example.com", "/tmp", "cookie10").is_none());
            assert!(store.get_any("example.com", "/tmp", "cookie10").is_none());
        }
    }
}
