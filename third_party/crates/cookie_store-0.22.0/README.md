[![Build Status](https://github.com/pfernie/cookie_store/actions/workflows/ci.yml/badge.svg)](https://github.com/pfernie/cookie_store/actions/workflows/ci.yml)
[![Documentation](https://docs.rs/cookie_store/badge.svg)](https://docs.rs/cookie_store)

Provides an implementation for storing and retrieving `Cookie`s per the path and domain matching 
rules specified in [RFC6265](https://datatracker.ietf.org/doc/html/rfc6265).

## Features

* `preserve_order` - if enabled, iteration order of cookies will be maintained in insertion order. Pulls in an additional dependency on the [indexmap](https://crates.io/crates/indexmap) crate.

## Usage with [reqwest](https://crates.io/crates/reqwest)

Please refer to the [reqwest_cookie_store](https://crates.io/crates/reqwest_cookie_store) crate, which now provides an implementation of the `reqwest::cookie::CookieStore` trait for `cookie_store::CookieStore`.

## License
This project is licensed and distributed under the terms of both the MIT license and Apache License (Version 2.0).

See [LICENSE-APACHE](LICENSE-APACHE) and [LICENSE-MIT](LICENSE-MIT)
