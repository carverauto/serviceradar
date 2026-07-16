use std::borrow::{Cow, Borrow, BorrowMut};

use crate::{Cookie, SameSite, Expiration};

/// Structure that follows the builder pattern for building `Cookie` structs.
///
/// To construct a cookie:
///
///   1. Call [`Cookie::build()`] to start building.
///   2. Use any of the builder methods to set fields in the cookie.
///
/// The resulting `CookieBuilder` can be passed directly into methods expecting
/// a `T: Into<Cookie>`:
///
/// ```rust
/// use cookie::{Cookie, CookieJar};
///
/// let mut jar = CookieJar::new();
/// jar.add(Cookie::build(("key", "value")).secure(true).path("/"));
/// jar.remove(Cookie::build("key").path("/"));
/// ```
///
/// You can also call [`CookieBuilder::build()`] directly to get a `Cookie`:
///
/// ```rust
/// use cookie::Cookie;
/// use cookie::time::Duration;
///
/// let cookie: Cookie = Cookie::build(("name", "value"))
///     .domain("www.rust-lang.org")
///     .path("/")
///     .secure(true)
///     .http_only(true)
///     .max_age(Duration::days(1))
///     .build();
/// ```
#[derive(Debug, Clone, PartialEq)]
pub struct CookieBuilder<'c> {
    /// The cookie being built.
    cookie: Cookie<'c>,
}

impl<'c> CookieBuilder<'c> {
    /// Creates a new `CookieBuilder` instance from the given name and value.
    ///
    /// This method is typically called indirectly via [`Cookie::build()`].
    ///
    /// # Example
    ///
    /// ```rust
    /// use cookie::Cookie;
    ///
    /// // These two snippets are equivalent:
    ///
    /// let c = Cookie::build(("foo", "bar"));
    /// assert_eq!(c.inner().name_value(), ("foo", "bar"));
    ///
    /// let c = Cookie::new("foo", "bar");
    /// assert_eq!(c.name_value(), ("foo", "bar"));
    /// ```
    pub fn new<N, V>(name: N, value: V) -> Self
        where N: Into<Cow<'c, str>>,
              V: Into<Cow<'c, str>>
    {
        CookieBuilder { cookie: Cookie::new(name, value) }
    }

    /// Sets the `expires` field in the cookie being built.
    ///
    /// See [`Expiration`] for conversions.
    ///
    /// # Example
    ///
    /// ```rust
    /// # extern crate cookie;
    /// use cookie::{Cookie, Expiration};
    /// use cookie::time::OffsetDateTime;
    ///
    /// # fn main() {
    /// let c = Cookie::build(("foo", "bar")).expires(OffsetDateTime::now_utc());
    /// assert!(c.inner().expires().is_some());
    ///
    /// let c = Cookie::build(("foo", "bar")).expires(None);
    /// assert_eq!(c.inner().expires(), Some(Expiration::Session));
    /// # }
    /// ```
    #[inline]
    pub fn expires<E: Into<Expiration>>(mut self, when: E) -> Self {
        self.cookie.set_expires(when);
        self
    }

    /// Sets the `max_age` field in the cookie being built.
    ///
    /// # Example
    ///
    /// ```rust
    /// use cookie::Cookie;
    /// use cookie::time::Duration;
    ///
    /// let c = Cookie::build(("foo", "bar")).max_age(Duration::minutes(30));
    /// assert_eq!(c.inner().max_age(), Some(Duration::seconds(30 * 60)));
    /// ```
    #[inline]
    pub fn max_age(mut self, value: time::Duration) -> Self {
        self.cookie.set_max_age(value);
        self
    }

    /// Sets the `domain` field in the cookie being built.
    ///
    /// # Example
    ///
    /// ```rust
    /// use cookie::Cookie;
    ///
    /// let c = Cookie::build(("foo", "bar")).domain("www.rust-lang.org");
    /// assert_eq!(c.inner().domain(), Some("www.rust-lang.org"));
    /// ```
    pub fn domain<D: Into<Cow<'c, str>>>(mut self, value: D) -> Self {
        self.cookie.set_domain(value);
        self
    }

    /// Sets the `path` field in the cookie being built.
    ///
    /// # Example
    ///
    /// ```rust
    /// use cookie::Cookie;
    ///
    /// let c = Cookie::build(("foo", "bar")).path("/");
    /// assert_eq!(c.inner().path(), Some("/"));
    /// ```
    pub fn path<P: Into<Cow<'c, str>>>(mut self, path: P) -> Self {
        self.cookie.set_path(path);
        self
    }

    /// Sets the `secure` field in the cookie being built.
    ///
    /// # Example
    ///
    /// ```rust
    /// use cookie::Cookie;
    ///
    /// let c = Cookie::build(("foo", "bar")).secure(true);
    /// assert_eq!(c.inner().secure(), Some(true));
    /// ```
    #[inline]
    pub fn secure(mut self, value: bool) -> Self {
        self.cookie.set_secure(value);
        self
    }

    /// Sets the `http_only` field in the cookie being built.
    ///
    /// # Example
    ///
    /// ```rust
    /// use cookie::Cookie;
    ///
    /// let c = Cookie::build(("foo", "bar")).http_only(true);
    /// assert_eq!(c.inner().http_only(), Some(true));
    /// ```
    #[inline]
    pub fn http_only(mut self, value: bool) -> Self {
        self.cookie.set_http_only(value);
        self
    }

    /// Sets the `same_site` field in the cookie being built.
    ///
    /// # Example
    ///
    /// ```rust
    /// use cookie::{Cookie, SameSite};
    ///
    /// let c = Cookie::build(("foo", "bar")).same_site(SameSite::Strict);
    /// assert_eq!(c.inner().same_site(), Some(SameSite::Strict));
    /// ```
    #[inline]
    pub fn same_site(mut self, value: SameSite) -> Self {
        self.cookie.set_same_site(value);
        self
    }

    /// Sets the `partitioned` field in the cookie being built.
    ///
    /// **Note:** _Partitioned_ cookies require the `Secure` attribute to be
    /// set. As such, `Partitioned` cookies are always rendered with the
    /// `Secure` attribute, irrespective of the `Secure` attribute's setting.
    ///
    /// **Note:** This cookie attribute is an [HTTP draft]! Its meaning and
    /// definition are not standardized and therefore subject to change.
    ///
    /// [HTTP draft]: https://www.ietf.org/id/draft-cutler-httpbis-partitioned-cookies-01.html
    ///
    /// # Example
    ///
    /// ```rust
    /// use cookie::Cookie;
    ///
    /// let c = Cookie::build(("foo", "bar")).partitioned(true);
    /// assert_eq!(c.inner().partitioned(), Some(true));
    /// assert!(c.to_string().contains("Secure"));
    /// ```
    #[inline]
    pub fn partitioned(mut self, value: bool) -> Self {
        self.cookie.set_partitioned(value);
        self
    }

    /// Makes the cookie being built 'permanent' by extending its expiration and
    /// max age 20 years into the future. See also [`Cookie::make_permanent()`].
    ///
    /// # Example
    ///
    /// ```rust
    /// # extern crate cookie;
    /// use cookie::Cookie;
    /// use cookie::time::Duration;
    ///
    /// # fn main() {
    /// let c = Cookie::build(("foo", "bar")).permanent();
    /// assert_eq!(c.inner().max_age(), Some(Duration::days(365 * 20)));
    /// # assert!(c.inner().expires().is_some());
    /// # }
    /// ```
    #[inline]
    pub fn permanent(mut self) -> Self {
        self.cookie.make_permanent();
        self
    }

    /// Makes the cookie being built 'removal' by clearing its value, setting a
    /// max-age of `0`, and setting an expiration date far in the past. See also
    /// [`Cookie::make_removal()`].
    ///
    /// # Example
    ///
    /// ```rust
    /// # extern crate cookie;
    /// use cookie::Cookie;
    /// use cookie::time::Duration;
    ///
    /// # fn main() {
    /// let mut builder = Cookie::build("foo").removal();
    /// assert_eq!(builder.inner().max_age(), Some(Duration::ZERO));
    ///
    /// let mut builder = Cookie::build(("name", "value")).removal();
    /// assert_eq!(builder.inner().value(), "");
    /// assert_eq!(builder.inner().max_age(), Some(Duration::ZERO));
    /// # }
    /// ```
    #[inline]
    pub fn removal(mut self) -> Self {
        self.cookie.make_removal();
        self
    }

    /// Returns a borrow to the cookie currently being built.
    ///
    /// # Example
    ///
    /// ```rust
    /// use cookie::Cookie;
    ///
    /// let builder = Cookie::build(("name", "value"))
    ///     .domain("www.rust-lang.org")
    ///     .path("/")
    ///     .http_only(true);
    ///
    /// assert_eq!(builder.inner().name_value(), ("name", "value"));
    /// assert_eq!(builder.inner().domain(), Some("www.rust-lang.org"));
    /// assert_eq!(builder.inner().path(), Some("/"));
    /// assert_eq!(builder.inner().http_only(), Some(true));
    /// assert_eq!(builder.inner().secure(), None);
    /// ```
    #[inline]
    pub fn inner(&self) -> &Cookie<'c> {
        &self.cookie
    }

    /// Returns a mutable borrow to the cookie currently being built.
    ///
    /// # Example
    ///
    /// ```rust
    /// use cookie::Cookie;
    ///
    /// let mut builder = Cookie::build(("name", "value"))
    ///     .domain("www.rust-lang.org")
    ///     .path("/")
    ///     .http_only(true);
    ///
    /// assert_eq!(builder.inner().http_only(), Some(true));
    ///
    /// builder.inner_mut().set_http_only(false);
    /// assert_eq!(builder.inner().http_only(), Some(false));
    /// ```
    #[inline]
    pub fn inner_mut(&mut self) -> &mut Cookie<'c> {
        &mut self.cookie
    }

    /// Finishes building and returns the built `Cookie`.
    ///
    /// This method usually does not need to be called directly. This is because
    /// `CookieBuilder` implements `Into<Cookie>`, so a value of `CookieBuilder`
    /// can be passed directly into any method that expects a `C: Into<Cookie>`.
    ///
    /// # Example
    ///
    /// ```rust
    /// use cookie::{Cookie, CookieJar};
    ///
    /// // We don't usually need to use `build()`. Inspect with `inner()`, and
    /// // pass the builder directly into methods expecting `T: Into<Cookie>`.
    /// let c = Cookie::build(("foo", "bar"))
    ///     .domain("crates.io")
    ///     .path("/");
    ///
    /// // Use `inner()` and inspect the cookie.
    /// assert_eq!(c.inner().name_value(), ("foo", "bar"));
    /// assert_eq!(c.inner().domain(), Some("crates.io"));
    /// assert_eq!(c.inner().path(), Some("/"));
    ///
    /// // Add the cookie to a jar. Note the automatic conversion.
    /// CookieJar::new().add(c);
    ///
    /// // We could use `build()` to get a `Cookie` when needed.
    /// let c = Cookie::build(("foo", "bar"))
    ///     .domain("crates.io")
    ///     .path("/")
    ///     .build();
    ///
    /// // Inspect the built cookie.
    /// assert_eq!(c.name_value(), ("foo", "bar"));
    /// assert_eq!(c.domain(), Some("crates.io"));
    /// assert_eq!(c.path(), Some("/"));
    ///
    /// // Add the cookie to a jar.
    /// CookieJar::new().add(c);
    /// ```
    #[inline]
    pub fn build(self) -> Cookie<'c> {
        self.cookie
    }

    /// Deprecated. Convert `self` into a `Cookie`.
    ///
    /// Instead of using this method, pass a `CookieBuilder` directly into
    /// methods expecting a `T: Into<Cookie>`. For other cases, use
    /// [`CookieBuilder::build()`].
    #[deprecated(since="0.18.0", note="`CookieBuilder` can be passed in to methods expecting a `Cookie`; for other cases, use `CookieBuilder::build()`")]
    pub fn finish(self) -> Cookie<'c> {
        self.cookie
    }
}

impl std::fmt::Display for CookieBuilder<'_> {
    #[inline(always)]
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.cookie.fmt(f)
    }
}

// NOTE: We don't implement `Deref` or `DerefMut` because there are tons of name
// collisions with builder methods.
impl<'a> Borrow<Cookie<'a>> for CookieBuilder<'a> {
    fn borrow(&self) -> &Cookie<'a> {
        &self.cookie
    }
}

impl<'a> BorrowMut<Cookie<'a>> for CookieBuilder<'a> {
    fn borrow_mut(&mut self) -> &mut Cookie<'a> {
        &mut self.cookie
    }
}

impl<'a> AsRef<Cookie<'a>> for CookieBuilder<'a> {
    fn as_ref(&self) -> &Cookie<'a> {
        &self.cookie
    }
}

impl<'a> AsMut<Cookie<'a>> for CookieBuilder<'a> {
    fn as_mut(&mut self) -> &mut Cookie<'a> {
        &mut self.cookie
    }
}

impl<'a, 'b> PartialEq<Cookie<'b>> for CookieBuilder<'a> {
    fn eq(&self, other: &Cookie<'b>) -> bool {
        &self.cookie == other
    }
}

impl<'a, 'b> PartialEq<CookieBuilder<'b>> for Cookie<'a> {
    fn eq(&self, other: &CookieBuilder<'b>) -> bool {
        self == &other.cookie
    }
}

impl<'c> From<Cookie<'c>> for CookieBuilder<'c> {
    fn from(cookie: Cookie<'c>) -> Self {
        CookieBuilder { cookie }
    }
}
