![WhoAmI Logo]

#### [Changelog] | [Source] | [Getting Started]

[![tests](https://github.com/ardaku/whoami/actions/workflows/ci.yml/badge.svg)](https://github.com/ardaku/whoami/actions/workflows/ci.yml)
[![GitHub commit activity](https://img.shields.io/github/commit-activity/y/ardaku/whoami)](https://github.com/ardaku/whoami/)
[![GitHub contributors](https://img.shields.io/github/contributors/ardaku/whoami)](https://github.com/ardaku/whoami/graphs/contributors)  
[![Crates.io](https://img.shields.io/crates/v/whoami)](https://crates.io/crates/whoami)
[![Crates.io](https://img.shields.io/crates/d/whoami)](https://crates.io/crates/whoami)
[![Crates.io (recent)](https://img.shields.io/crates/dr/whoami)](https://crates.io/crates/whoami)  
[![Crates.io](https://img.shields.io/crates/l/whoami)](https://github.com/search?q=repo%3Aardaku%2Fwhoami+path%3A**%2FLICENSE*&type=code)
[![Docs.rs](https://docs.rs/whoami/badge.svg)](https://docs.rs/whoami/)

Rust library for getting information about the current user and environment.

Check out the [documentation] for examples.

### Features

 - Get the user's full name
 - Get the user's username
 - Get the user's preferred language(s)
 - Get the devices's hostname
 - Get the devices's "pretty hostname" or "fancy name"
 - Get the devices's desktop environment
 - Get the devices's OS name and version
 - Get the devices's platform name
 - Get the devices's CPU architecture and its width

### Supported Platforms

WhoAmI targets all platforms that can run Rust, including:

 - Linux
 - Windows
 - Mac OS
 - BSD variants (FreeBSD, others)
 - illumos variants (SmartOS, OmniOS, others)
 - Redox
 - [Web Assembly]
   - Fake implementation
   - Web Browser - DOM
   - WASI (Wasite, others) **untested, testing planned later**
   - Daku (Ardaku/Quantii, others) **planned later**
 - Android **planned later**
 - iOS / watchOS / tvOS **untested**
 - Fuchsia **planned later**
 - GNU/Hurd **untested**
 - Others? (make a PR or open an issue)

## MSRV

MSRV is updated according to the [Ardaku MSRV guidelines], so it will only get
updated on minor and major version bumps.  All 2.x releases will be maintained
with bugfixes until the end of 2027 at minimum.  Past MSRV bumps and future
plans:

 - WhoAmI 2.3: Rust 1.95 MSRV (bump to get `cfg_select! {}` to make FFI code
   prettier)
 - WhoAmI 2.2: Rust 1.85 MSRV (bump to get the 2024 edition, pull in nix, etc.)
 - WhoAmI 2.1: Rust 1.75 MSRV (bump for new lang features, faster CI, pull in
   libc, etc.)
 - WhoAmI 2.0: Rust 1.65 MSRV (support based on original 2.0 plan)
 - WhoAmI 1.x: Rust 1.40 MSRV (old MSRV policy, maintained until end of 2025 at
   minimum)

Target-Specific MSRVs:

 - When the `std` feature is disabled, WhoAmI bumps the MSRV to Rust 1.81 for
   the WhoAmI 2.0 and WhoAmI 2.1 release tracks.  This feature should usually
   stay enabled, unless you have a specific use-case targeting no-std.

## Binary

[whome] - `whoami` command RiR (Re-written in Rust) that depends on this crate.

## Testing

The interactive testing procedure is documented in the release PR template.  The
full manual test suite is run for each change that affects multiple platforms.

## License

Copyright © 2017-2026 The WhoAmI Contributors.

Licensed under any of
 - Apache License, Version 2.0, ([LICENSE\_APACHE] or
   <https://www.apache.org/licenses/LICENSE-2.0>)
 - Boost Software License, Version 1.0, ([LICENSE\_BOOST] or
   <https://www.boost.org/LICENSE_1_0.txt>)
 - MIT License, ([LICENSE\_MIT] or <https://mit-license.org/>)

at your option.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in the work by you, as defined in the Apache-2.0 license, shall be
licensed as described above, without any additional terms or conditions.

## Help

If you want help using or contributing to this library, feel free to send me an
email at <aldaronlau@gmail.com>.

[documentation]: https://docs.rs/whoami
[whome]: https://crates.io/crates/whome
[Ardaku MSRV guidelines]: https://github.com/ardaku/.github/blob/v1/profile/MSRV.md
[Changelog]: https://github.com/ardaku/whoami/releases
[Getting Started]: https://docs.rs/whoami#getting-started
[LICENSE\_APACHE]: https://github.com/ardaku/whoami/blob/v2/LICENSE_APACHE
[LICENSE\_BOOST]: https://github.com/ardaku/whoami/blob/v2/LICENSE_BOOST
[LICENSE\_MIT]: https://github.com/ardaku/whoami/blob/v2/LICENSE_MIT
[Source]: https://github.com/ardaku/whoami
[Web Assembly]: https://github.com/ardaku/whoami/blob/v2/WASM.md
[WhoAmI Logo]: https://raw.githubusercontent.com/ardaku/whoami/v2/res/icon.svg
