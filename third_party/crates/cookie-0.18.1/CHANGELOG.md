# Version 0.18

## Version 0.18.1 (Mar 25, 2024)

### New Features

  * Added support for the draft `Partitioned` attribute.

    The new `CookieBuilder::partition()`, `Cookie::partitioned()`, and
    `Cookie::set_partitioned()` methods allow enabling and/or disabling the
    attribute. Additionally, the attribute is recognized during parsing.

  * Added `CookieBuilder::removal()`, counterpart to `Cookie::make_removal()`.

## Version 0.18.0 (Oct 9, 2023)

### Breaking Changes

  * The MSRV is now 1.56.

  * `Cookie::value()` no longer trims surrounding double quotes. (89eddd)

    Use `Cookie::value_trimmed()` for the previous behavior.

  * Many methods now expect a `T: Into<Cookie>` in place of `Cookie`. (49ff7b)

    Functions and methods that previously accepted a `Cookie` now accept any `T:
    Into<Cookie>`. This particularly affects the `CookieJar` API, which now allows
    simpler addition and removal of cookies:

      * `jar.add(("foo", "bar"));`
      * `jar.add(Cookie::build(("foo", "bar")).path("/"));`
      * `jar.remove("foo");`
      * `jar.remove(Cookie::build("foo").path("/"));`

  * `CookieJar::force_remove()` now expects a `T: AsRef<str>` in place of
    `&Cookie`.

    Force-removal never requires more information than a cookie's name. The API
    has been simplified to reflect this.

  * `CookieBuilder::finish()` was deprecated in favor of
    `CookieBuilder::build()`.

    This largely serves as a compile-time notice that calling `finish()` or
    `build()` is largely unnecessary given that `CookieBuilder` implements
    `Into<Cookie>`.

  * `Cookie::named()` was deprecated in favor of using `Cookie::build()` or
    `Cookie::from()`.

      * `Cookie::named("foo")` is equivalent to `Cookie::from("foo")`.
      * `Cookie::build("foo")` begins building a cookie equivalent to
        `Cookie::named("foo")`.

### New Features

  * Added `Cookie::value_trimmed()` and `Cookie::name_value_trimmed()`.

    These versions of `Cookie::value()` and `Cookie::name_value()`,
    respectively, trim a matching pair of surrounding double quotes from the
    cookie's value, if any are present.

  * String-like types, tuples of string-like types, and `CookieBuilder`
    implement `Into<Cookie>`.

    Implementations of `Into<Cookie>` for string-like types (`&str`, `String`,
    `Cow<str>`), tuples of string-like types `(name: string, value: string)`,
    and `CookieBuilder` were added. The former implementations create a cookie
    with a name corresponding to the string and an empty value. The tuple
    implementation creates a cookie with the given name and value strings. The
    `CookieBuilder` implementation returns the built cookie.

  * `Key` implements `Debug`.

    To not leak sensitive information, the representation is simply `"Key"`.

  * `CookieBuilder` implements `Borrow{Mut}<Cookie>`, `As{Ref,Mut}<Cookie>`,
    `Display`.

  * Added `CookieBuilder::inner{_mut}()` to (mutably) borrow cookies being
    built.

  * Added `PrefixedJar` and `CookieJar::prefixed{_mut}()`, which implement the
    cookie prefixes HTTP draft.

## Version 0.18.0.rc.0 (Sep 27, 2023)

See the entry above for 0.18.0.

# Version 0.17

## Version 0.17.0 (Jan 22, 2022)

### Breaking Changes

  * Cookie parsing no longer removes a `.` `Domain` prefix. `Cookie::domain()`
    now removes a `.` prefix before returning.

    As these changes are inverses, they are not likely observable. The change
    only affects manually set `domain` values via the `.domain()` builder
    method, the `set_domain()` setter method, or similar, which will now have a
    prefix of `.` removed when returned by `Cookie::domain()`. This results in
    more consistent treatment of `Domain` values.

### New Features

  * Added `Cookie::split_parse()` and `Cookie::split_parse_encoded()` methods.

    The methods split a `;`-joined cookie string and parse/decode the split
    values. They return a newly introduced iterator value of type `SplitCookies`
    over the parse results.

### General Changes and Fixes

  * Parsing fuzzers were introduced and run for 48 CPU hours without failure.
  * `base64` was updated to `0.21`.

# Version 0.16

## Version 0.16.2 (Dec 16, 2022)

### General Changes

  * `base64` was updated to `0.20`.

## Version 0.16.1 (Sep 25, 2022)

### Changes and Fixes

  * The `,`, `(`, and `)` are percent-encoded/decoded when encoding is used.
  * The `aes-gcm` dependency was updated to 0.10.

## Version 0.16.0 (Dec 28, 2021)

### Breaking Changes

  * The MSRV is now `1.53`, up from `1.41` in `0.15`.
  * `time` has been updated to `0.3` and is reexported from the crate root.

### General Changes

  * `rust-crypto` dependencies were updated to their latest versions.

# Version 0.15

## Version 0.15.1 (Jul 14, 2021)

### Changes and Fixes

  * A panic that could result from non-char boundary indexing was fixed.
  * Stale doc references to version `0.14` were updated.

## Version 0.15.0 (Feb 25, 2021)

### Breaking Changes

  * `Cookie::force_remove()` takes `&Cookie` instead of `Cookie`.
  * Child jar methods split into immutable and mutable versions
    (`Cookie::{private{_mut}, signed{_mut}}`).
  * `Cookie::encoded()` returns a new `Display` struct.
  * Dates with year `<= 99` are handled like Chrome: range `0..=68` maps to
    `2000..=2068`, `69..=99` to `1969..=1999`.
  * `Cookie::{set_}expires()` operates on a new `Expiration` enum.

### New Features

  * Added `Cookie::make_removal()` to manually create expired cookies.
  * Added `Cookie::stripped()` display variant to print only the `name` and
    `value` of a cookie.
  * `Key` implements a constant-time `PartialEq`.
  * Added `Key::master()` to retrieve the full 512-bit master key.
  * Added `PrivateJar::decrypt()` to manually decrypt an encrypted `Cookie`.
  * Added `SignedJar::verify()` to manually verify a signed `Cookie`.
  * `Cookie::expires()` returns an `Option<Expiration>` to allow distinguishing
    between unset and `None` expirations.
  * Added `Cookie::expires_datetime()` to retrieve the expiration as an
    `OffsetDateTime`.
  * Added `Cookie::unset_expires()` to unset expirations.

### General Changes and Fixes

  * MSRV is 1.41.

# Version 0.14

## Version 0.14.3 (Nov 5, 2020)

### Changes and Fixes

  * `rust-crypto` dependencies were updated to their latest versions.

## Version 0.14.2 (Jul 22, 2020)

### Changes and Fixes

  * Documentation now builds on the stable channel.
  * `rust-crypto` dependencies were updated to their latest versions.
  * Fixed 'interator' -> 'iterator' documentation typo.

## Version 0.14.1 (Jun 5, 2020)

### Changes and Fixes

  * Updated `base64` dependency to 0.12.
  * Updated minimum `time` dependency to correct version: 0.2.11.
  * Added `readme` key to `Cargo.toml`, updated `license` field.

## Version 0.14.0 (May 29, 2020)

### Breaking Changes

  * The `Key::from_master()` method was deprecated in favor of the more aptly
    named `Key::derive_from()`.
  * The deprecated `CookieJar::clear()` method was removed.

### New Features

  * Added `Key::from()` to create a `Key` structure from a full-length key.
  * Signed and private cookie jars can be individually enabled via the new
    `signed` and `private` features, respectively.
  * Key derivation via key expansion can be individually enabled via the new
    `key-expansion` feature.

### General Changes and Fixes

  * `ring` is no longer a dependency: `RustCrypto`-based cryptography is used in
    lieu of `ring`. Prior to their inclusion here, the `hmac` and `hkdf` crates
    were audited.
  * Quotes, if present, are stripped from cookie values when parsing.

# Version 0.13

## Version 0.13.3 (Feb 3, 2020)

### Changes

  * The `time` dependency was unpinned from `0.2.4`, allowing any `0.2.x`
    version of `time` where `x >= 6`.

## Version 0.13.2 (Jan 28, 2020)

### Changes

  * The `time` dependency was pinned to `0.2.4` due to upstream breaking changes
    in `0.2.5`.

## Version 0.13.1 (Jan 23, 2020)

### New Features

  * Added the `CookieJar::reset_delta()` method, which reverts all _delta_
    changes to a `CookieJar`.

## Version 0.13.0 (Jan 21, 2020)

### Breaking Changes

  * `time` was updated from 0.1 to 0.2.
  * `ring` was updated from 0.14 to 0.16.
  * `SameSite::None` now writes `SameSite=None` to correspond with updated
    `SameSite` draft. `SameSite` can be unset by passing `None` to
    `Cookie::set_same_site()`.
  * `CookieBuilder` gained a lifetime: `CookieBuilder<'c>`.

### General Changes and Fixes

  * Added a CHANGELOG.
  * `expires`, `max_age`, `path`, and `domain` can be unset by passing `None` to
    the respective `Cookie::set_{field}()` method.
  * The "Expires" field is limited to a date-time of Dec 31, 9999, 23:59:59.
  * The `%` character is now properly encoded and decoded.
  * Constructor methods on `CookieBuilder` allow non-static lifetimes.
