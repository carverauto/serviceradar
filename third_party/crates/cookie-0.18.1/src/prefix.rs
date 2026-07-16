use std::marker::PhantomData;
use std::borrow::{Borrow, BorrowMut, Cow};

use crate::{CookieJar, Cookie};

/// A child jar that automatically [prefixes](Prefix) cookies.
///
/// Obtained via [`CookieJar::prefixed()`] and [`CookieJar::prefixed_mut()`].
///
/// This jar implements the [HTTP RFC6265 draft] "cookie prefixes" extension by
/// automatically adding and removing a specified [`Prefix`] from cookies that
/// are added and retrieved from this jar, respectively. Additionally, upon
/// being added to this jar, cookies are automatically made to
/// [conform](Prefix::conform()) to the corresponding prefix's specifications.
///
/// **Note:** Cookie prefixes are specified in an HTTP draft! Their meaning and
/// definition are subject to change.
///
/// [HTTP RFC6265 draft]:
/// https://datatracker.ietf.org/doc/html/draft-ietf-httpbis-rfc6265bis#name-cookie-name-prefixes
pub struct PrefixedJar<P: Prefix, J> {
    parent: J,
    _prefix: PhantomData<fn() -> P>,
}

/// The [`"__Host-"`] cookie [`Prefix`].
///
/// See [`Prefix`] and [`PrefixedJar`] for usage details.
///
/// [`"__Host-"`]:
/// https://datatracker.ietf.org/doc/html/draft-ietf-httpbis-rfc6265bis#name-the-__host-prefix
pub struct Host;

/// The [`"__Secure-"`] cookie [`Prefix`].
///
/// See [`Prefix`] and [`PrefixedJar`] for usage details.
///
/// [`"__Secure-"`]:
/// https://datatracker.ietf.org/doc/html/draft-ietf-httpbis-rfc6265bis#name-the-__secure-prefix
pub struct Secure;

/// Trait identifying [HTTP RFC6265 draft] cookie prefixes.
///
/// A [`Prefix`] can be applied to cookies via a child [`PrefixedJar`], itself
/// obtainable via [`CookieJar::prefixed()`] and [`CookieJar::prefixed_mut()`].
/// Cookies added/retrieved to/from these child jars have the corresponding
/// [prefix](Prefix::conform()) automatically prepended/removed as needed.
/// Additionally, added cookies are automatically make to
/// [conform](Prefix::conform()).
///
/// **Note:** Cookie prefixes are specified in an HTTP draft! Their meaning and
/// definition are subject to change.
///
/// [HTTP RFC6265 draft]:
/// https://datatracker.ietf.org/doc/html/draft-ietf-httpbis-rfc6265bis#name-cookie-name-prefixes
pub trait Prefix: private::Sealed {
    /// The prefix string to prepend.
    ///
    /// See [`Host::PREFIX`] and [`Secure::PREFIX`] for specifics.
    const PREFIX: &'static str;

    /// Alias to [`Host`].
    #[allow(non_upper_case_globals)]
    const Host: Host = Host;

    /// Alias to [`Secure`].
    #[allow(non_upper_case_globals)]
    const Secure: Secure = Secure;

    /// Modify `cookie` so it conforms to the requirements of `self`.
    ///
    /// See [`Host::conform()`] and [`Secure::conform()`] for specifics.
    //
    // This is the only required method. Everything else is shared across
    // implementations via the default implementations below and should not be
    // implemented.
    fn conform(cookie: Cookie<'_>) -> Cookie<'_>;

    /// Returns a string with `name` prefixed with `self`.
    #[doc(hidden)]
    #[inline(always)]
    fn prefixed_name(name: &str) -> String {
        format!("{}{}", Self::PREFIX, name)
    }

    /// Prefix `cookie`'s name with `Self`.
    #[doc(hidden)]
    fn prefix(mut cookie: Cookie<'_>) -> Cookie<'_> {
        use crate::CookieStr;

        cookie.name = CookieStr::Concrete(match cookie.name {
            CookieStr::Concrete(Cow::Owned(mut string)) => {
                string.insert_str(0, Self::PREFIX);
                string.into()
            }
            _ => Self::prefixed_name(cookie.name()).into(),
        });

        cookie
    }

    /// Remove the prefix `Self` from `cookie`'s name and return it.
    ///
    /// If the prefix isn't in `cookie`, the cookie is returned unmodified. This
    /// method is expected to be called only when `cookie`'s name is known to
    /// contain the prefix.
    #[doc(hidden)]
    fn clip(mut cookie: Cookie<'_>) -> Cookie<'_> {
        use std::borrow::Cow::*;
        use crate::CookieStr::*;

        if !cookie.name().starts_with(Self::PREFIX) {
            return cookie;
        }

        let len = Self::PREFIX.len();
        cookie.name = match cookie.name {
            Indexed(i, j) => Indexed(i + len, j),
            Concrete(Borrowed(v)) => Concrete(Borrowed(&v[len..])),
            Concrete(Owned(v)) => Concrete(Owned(v[len..].to_string())),
        };

        cookie
    }

    /// Prefix and _conform_ `cookie`: prefix `cookie` with `Self` and make it
    /// conform to the required specification by modifying it.
    #[inline]
    #[doc(hidden)]
    fn apply(cookie: Cookie<'_>) -> Cookie<'_> {
        Self::conform(Self::prefix(cookie))
    }
}

impl<P: Prefix, J> PrefixedJar<P, J> {
    #[inline(always)]
    pub(crate) fn new(parent: J) -> Self {
        Self { parent, _prefix: PhantomData }
    }
}

impl<P: Prefix, J: Borrow<CookieJar>> PrefixedJar<P, J> {
    /// Fetches the `Cookie` inside this jar with the prefix `P` and removes the
    /// prefix before returning it. If the cookie isn't found, returns `None`.
    ///
    /// See [`CookieJar::prefixed()`] for more examples.
    ///
    /// # Example
    ///
    /// ```rust
    /// use cookie::CookieJar;
    /// use cookie::prefix::{Host, Secure};
    ///
    /// // Add a `Host` prefixed cookie.
    /// let mut jar = CookieJar::new();
    /// jar.prefixed_mut(Host).add(("h0st", "value"));
    /// assert_eq!(jar.prefixed(Host).get("h0st").unwrap().name(), "h0st");
    /// assert_eq!(jar.prefixed(Host).get("h0st").unwrap().value(), "value");
    /// ```
    pub fn get(&self, name: &str) -> Option<Cookie<'static>> {
        self.parent.borrow()
            .get(&P::prefixed_name(name))
            .map(|c| P::clip(c.clone()))
    }
}

impl<P: Prefix, J: BorrowMut<CookieJar>> PrefixedJar<P, J> {
    /// Adds `cookie` to the parent jar. The cookie's name is prefixed with `P`,
    /// and the cookie's attributes are made to [`conform`](Prefix::conform()).
    ///
    /// See [`CookieJar::prefixed_mut()`] for more examples.
    ///
    /// # Example
    ///
    /// ```rust
    /// use cookie::{Cookie, CookieJar};
    /// use cookie::prefix::{Host, Secure};
    ///
    /// // Add a `Host` prefixed cookie.
    /// let mut jar = CookieJar::new();
    /// jar.prefixed_mut(Secure).add(Cookie::build(("name", "value")).secure(false));
    /// assert_eq!(jar.prefixed(Secure).get("name").unwrap().value(), "value");
    /// assert_eq!(jar.prefixed(Secure).get("name").unwrap().secure(), Some(true));
    /// ```
    pub fn add<C: Into<Cookie<'static>>>(&mut self, cookie: C) {
        self.parent.borrow_mut().add(P::apply(cookie.into()));
    }

    /// Adds `cookie` to the parent jar. The cookie's name is prefixed with `P`,
    /// and the cookie's attributes are made to [`conform`](Prefix::conform()).
    ///
    /// Adding an original cookie does not affect the [`CookieJar::delta()`]
    /// computation. This method is intended to be used to seed the cookie jar
    /// with cookies. For accurate `delta` computations, this method should not
    /// be called after calling `remove`.
    ///
    /// # Example
    ///
    /// ```rust
    /// use cookie::{Cookie, CookieJar};
    /// use cookie::prefix::{Host, Secure};
    ///
    /// // Add a `Host` prefixed cookie.
    /// let mut jar = CookieJar::new();
    /// jar.prefixed_mut(Secure).add_original(("name", "value"));
    /// assert_eq!(jar.iter().count(), 1);
    /// assert_eq!(jar.delta().count(), 0);
    /// ```
    pub fn add_original<C: Into<Cookie<'static>>>(&mut self, cookie: C) {
        self.parent.borrow_mut().add_original(P::apply(cookie.into()));
    }

    /// Removes `cookie` from the parent jar.
    ///
    /// The cookie's name is prefixed with `P`, and the cookie's attributes are
    /// made to [`conform`](Prefix::conform()) before attempting to remove the
    /// cookie. For correct removal, the passed in `cookie` must contain the
    /// same `path` and `domain` as the cookie that was initially set.
    ///
    /// # Example
    ///
    /// ```rust
    /// use cookie::{Cookie, CookieJar};
    /// use cookie::prefix::{Host, Secure};
    ///
    /// let mut jar = CookieJar::new();
    /// let mut prefixed_jar = jar.prefixed_mut(Host);
    ///
    /// prefixed_jar.add(("name", "value"));
    /// assert!(prefixed_jar.get("name").is_some());
    ///
    /// prefixed_jar.remove("name");
    /// assert!(prefixed_jar.get("name").is_none());
    /// ```
    pub fn remove<C: Into<Cookie<'static>>>(&mut self, cookie: C) {
        self.parent.borrow_mut().remove(P::apply(cookie.into()));
    }
}

impl Prefix for Host {
    /// The [`"__Host-"` prefix] string.
    ///
    /// [`"__Host-"` prefix]:
    /// https://datatracker.ietf.org/doc/html/draft-ietf-httpbis-rfc6265bis#name-the-__host-prefix
    const PREFIX: &'static str = "__Host-";

    /// Modify `cookie` so it conforms to the prefix's requirements.
    ///
    /// **Note: this method is called automatically by [`PrefixedJar`]. It _does
    /// not need to_ and _should not_ be called manually under normal
    /// circumstances.**
    ///
    /// According to [RFC 6265bis-12 §4.1.3.2]:
    ///
    /// ```text
    /// If a cookie's name begins with a case-sensitive match for the string
    /// __Host-, then the cookie will have been set with a Secure attribute,
    /// a Path attribute with a value of /, and no Domain attribute.
    /// ```
    ///
    /// As such, to make a cookie conforn, this method:
    ///
    ///   * Sets [`secure`](Cookie::set_secure()) to `true`.
    ///   * Sets the [`path`](Cookie::set_path()) to `"/"`.
    ///   * Removes the [`domain`](Cookie::unset_domain()), if any.
    ///
    /// [RFC 6265bis-12 §4.1.3.2]:
    /// https://datatracker.ietf.org/doc/html/draft-ietf-httpbis-rfc6265bis#name-the-__host-prefix
    ///
    /// # Example
    ///
    /// ```rust
    /// use cookie::{CookieJar, Cookie, prefix::Host};
    ///
    /// // A cookie with some non-conformant properties.
    /// let cookie = Cookie::build(("name", "some-value"))
    ///     .secure(false)
    ///     .path("/foo/bar")
    ///     .domain("rocket.rs")
    ///     .http_only(true);
    ///
    /// // Add the cookie to the jar.
    /// let mut jar = CookieJar::new();
    /// jar.prefixed_mut(Host).add(cookie);
    ///
    /// // Fetch the cookie: notice it's been made to conform.
    /// let cookie = jar.prefixed(Host).get("name").unwrap();
    /// assert_eq!(cookie.name(), "name");
    /// assert_eq!(cookie.value(), "some-value");
    /// assert_eq!(cookie.secure(), Some(true));
    /// assert_eq!(cookie.path(), Some("/"));
    /// assert_eq!(cookie.domain(), None);
    /// assert_eq!(cookie.http_only(), Some(true));
    /// ```
    fn conform(mut cookie: Cookie<'_>) -> Cookie<'_> {
        cookie.set_secure(true);
        cookie.set_path("/");
        cookie.unset_domain();
        cookie
    }
}

impl Prefix for Secure {
    /// The [`"__Secure-"` prefix] string.
    ///
    /// [`"__Secure-"` prefix]:
    /// https://datatracker.ietf.org/doc/html/draft-ietf-httpbis-rfc6265bis#name-the-__secure-prefix
    const PREFIX: &'static str = "__Secure-";

    /// Modify `cookie` so it conforms to the prefix's requirements.
    ///
    /// **Note: this method is called automatically by [`PrefixedJar`]. It _does
    /// not need to_ and _should not_ be called manually under normal
    /// circumstances.**
    ///
    /// According to [RFC 6265bis-12 §4.1.3.1]:
    ///
    /// ```text
    /// If a cookie's name begins with a case-sensitive match for the string
    /// __Secure-, then the cookie will have been set with a Secure
    /// attribute.
    /// ```
    ///
    /// As such, to make a cookie conforn, this method:
    ///
    ///   * Sets [`secure`](Cookie::set_secure()) to `true`.
    ///
    /// [RFC 6265bis-12 §4.1.3.1]:
    /// https://datatracker.ietf.org/doc/html/draft-ietf-httpbis-rfc6265bis#name-the-__secure-prefix
    ///
    /// # Example
    ///
    /// ```rust
    /// use cookie::{CookieJar, Cookie, prefix::Secure};
    ///
    /// // A cookie with some non-conformant properties.
    /// let cookie = Cookie::build(("name", "some-value"))
    ///     .secure(false)
    ///     .path("/guide")
    ///     .domain("rocket.rs")
    ///     .http_only(true);
    ///
    /// // Add the cookie to the jar.
    /// let mut jar = CookieJar::new();
    /// jar.prefixed_mut(Secure).add(cookie);
    ///
    /// // Fetch the cookie: notice it's been made to conform.
    /// let cookie = jar.prefixed(Secure).get("name").unwrap();
    /// assert_eq!(cookie.name(), "name");
    /// assert_eq!(cookie.value(), "some-value");
    /// assert_eq!(cookie.secure(), Some(true));
    /// assert_eq!(cookie.path(), Some("/guide"));
    /// assert_eq!(cookie.domain(), Some("rocket.rs"));
    /// assert_eq!(cookie.http_only(), Some(true));
    /// ```
    fn conform(mut cookie: Cookie<'_>) -> Cookie<'_> {
        cookie.set_secure(true);
        cookie
    }
}

mod private {
    pub trait Sealed {}

    impl Sealed for super::Host {}
    impl Sealed for super::Secure {}
}
