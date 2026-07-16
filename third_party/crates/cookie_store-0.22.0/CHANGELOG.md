# Changelog

## [0.22.0] - 2025-07-20

### Bug Fixes

- Guard `public_suffix_list` in `new()` w/ `#cfg`
- [**breaking**] Add `new_with_public_suffix` ctor under `public_suffix` feature

### Documentation

- Update CONTRIBUTORS.md

### Miscellaneous Tasks

- Rustfmt

### Ci

- Update `release.sh` to use `cargo semver-checks`

## [0.21.1] - 2024-11-09

### Documentation

- Update CONTRIBUTORS.md
- Switch to using `document-feature` for genearating feature flag documentation
- Improve documentation around features
- Add documentation around legacy serialization vs. `serde` module

### Features

- Gate serialization behind features `serde{,_json,_ron}`

### Miscellaneous Tasks

- Bump `indexmap` to `2.6.0`

### Build

- Set `rust-version=1.63.0`
- Add `serde_json` as a default feature
- Specify feature dependencies with explcit `dep:`

### Ci

- Split ci check step `build` into `build` + `test`. Add `msrv` job

### Refact

- De/serialize through simple `Vec` instead of `CookieStoreSerialized`
- Collect legacy `mod cookie_store` serialization impl
- Rename `mod serialization` -> `serde`; split out `json`, `ron`
- Split `ron` and `json` serialization tests
- Reorganize tests to respect `serde*` features
- Move serialization into dedicated `mod serialization`

## [0.21.0] - 2024-02-08

### Miscellaneous Tasks

- Update CONTRIBUTORS.md

### Ci

- Add missing v0.20.1 CHANGELOG entries
- Rm `--topo-order` from `git-cliff` call

## [0.20.1] - 2024-02-08

### Bug Fixes

- Pub use `cookie_store::StoreAction`
- Need to maintain 0.20.x series for [patch] behavior to work

### Miscellaneous Tasks

- Update CONTRIBUTORS.md

## [0.20.0] - 2023-06-17

### Features

- Re-export dependency cookie
- Add `CookieStore::new()`

### Styling

- Rust_fmt changes

## [0.19.1] - 2023-06-17

### Ci

- Allow specification of last tag to generate CHANGELOG from
- Fix git-cliff args for latest release
- Allow serde and serde_derive to compile in parallel
- Check tag format in release.sh

## [0.19.0] - 2022-11-05

### Bug Fixes

- Store clone of original raw cookie

### Cookie_store

- Fix missing raw cookie elements

## [0.18.0] - 2022-10-25

### Documentation

- Remove old `reqwest_impl` REMOVAL notice

### Features

- Make logging secure cookie values opt-in

### Miscellaneous Tasks

- Dependency bumps
- Update CONTRIBUTORS
- Update to idna 0.3
- Do not use annotated tags in release.sh
- Prepare version item for `release.sh`
- Prepare to start using `git-cliff`

### Styling

- Cargo fmt
- Fix release.sh comments/whitespace

### Build

- Expose feature `wasm-bindgen`

### Cookie_store

- Derive clone for CookieStore
- Add API to save all cookies

### Rename

- New `save_all` methods to emphasize divergence from RFC behavior

## [0.17.0] - 2022-08-30

### Miscellaneous Tasks

- Prepare version item for `release.sh`
- Prepare to start using `git-cliff`

## [0.16.1]
* Export `cookie_domain::CookieDomain` as `pub`
* Export `pub use cookie_expiration::CookieExpiration`
* Export `pub use cookie_path::CookiePath`
* Make `CookieStore::from_cookies` pub
* Add methods `CookieStore::load_json_all` and `CookieStore::load_all` to allow
  for loading both __unexpired__ and __expired__ cookies.

## [0.16.0]
* Update of dependencies in public API in `0.15.2` should have qualified as minor version bump

## [0.15.2] __YANKED__
* Upgrade dependencies

## [0.15.1]
* Attach `Secure` cookies to requests for `http://localhost` and loopback IP addresses (e.g. `127.0.0.1`). This change aligns `cookie_store`'s behaviour to the behaviour of [Chromium-based browsers](https://bugs.chromium.org/p/chromium/issues/detail?id=1177877#c7) and [Firefox](https://hg.mozilla.org/integration/autoland/rev/c4d13b3ca1e2).

## [0.15.0]
* deprecation in `v0.14.1` should have qualified as minor version bump
* Upgrade dependencies

## [0.14.1]
* Improve documentation on `CookieStore::get_request_cookies`
* Introduce alternative `CookieStore::get_request_values`, mark `CookieStore::get_request_cookies` as deprecated, and suggest usage of `get_request_values` instead.

## [0.14.0]
* **BREAKING** The `CookieStoreMutex` and `CookieStoreRwLock` implementation previously provided under the `reqwest_impl` feature have been migrated to a dedicated crate, `reqwest_cookie_store`, and the feature has been removed.
* **BREAKING** `reqwest` is no longer a direct depdency, but rather a `dev-depedency`. Furthermore, now only the needed `reqwest` features (`cookies`) are enabled, as opposed to all default features. This is potentially a breaking change for users.
* `reqwest` is no longer an optional dependency, it is now a `dev-dependency` for doctests.
  * Only enable the needed features for `reqwest` (@blyxxyz)
* Upgrade `publisuffix` dependency to `v2` (@rushmorem)
* Remove unused dev-dependencies

## [0.13.3]
* Fix attributes & configuration for feature support in docs.rs

## [0.13.0]
* Introduce optional feature `reqwest_impl`, providing implementations of the `reqwest::cookie::CookieStore` trait
* Upgrade to `reqwest 0.11.2`
* Upgrade to `env_logger 0.8`
* Upgrade to `pretty_assertions 0.7`
* Upgrade to `cookie 0.15`

## [0.12.0]
* Upgrade to `cookie 0.14`
* Upgrade to `time 0.2`

## [0.11.0]
* Implement `{De,}Serialize` for `CookieStore` (@Felerius)

## [0.10.0]
* introduce optional feature `preserve_order` which maintains cookies in insertion order.

## [0.9.0]
* remove `try_from` dependency again now that `reqwest` minimum rust version is bumped
* upgrade to `url 2.0` (@benesch)
* Upgrade to `idna 0.2`

## [0.8.0]
* Remove dependency on `failure` (seanmonstar)

## [0.7.0]
* Revert removal of `try_from` dependency

## [0.6.0]
* Upgrades to `cookies` v0.12
* Drop dependency `try_from` in lieu of `std::convert::TryFrom` (@oherrala)
* Drop dependency on `serde_derive`, rely on `serde` only (@oherrala)

## [0.4.0]
* Update to Rust 2018 edition

## [0.3.1]

* Upgrades to `cookies` v0.11
* Minor dependency upgrades

## [0.3]

* Upgrades to `reqwest` v0.9
* Replaces `error-chain` with `failure`

## [0.2]

* Removes separate `ReqwestSession::ErrorKind`. Added as variant `::ErrorKind::Reqwest` instead.
