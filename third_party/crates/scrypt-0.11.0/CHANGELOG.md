# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.11.0 (2023-03-04)
### Added
- Ability to use custom output key length ([#255])
- Inherent constants for `Params` recommendations ([#387])

### Changed
- Bump `password-hash` to v0.5; MSRV 1.60 ([#383])
- Adopt OWASP recommendations ([#388])
- Bump `pbkdf2` to v0.12 ([#393])

[#255]: https://github.com/RustCrypto/password-hashes/pull/255
[#383]: https://github.com/RustCrypto/password-hashes/pull/383
[#387]: https://github.com/RustCrypto/password-hashes/pull/387
[#388]: https://github.com/RustCrypto/password-hashes/pull/388
[#393]: https://github.com/RustCrypto/password-hashes/pull/393

## 0.10.0 (2022-03-18)
### Changed
- Bump `password-hash` dependency to v0.4; MSRV 1.57 ([#283])
- Bump `pbkdf2` dependency to v0.11 ([#291])

[#283]: https://github.com/RustCrypto/password-hashes/pull/283
[#291]: https://github.com/RustCrypto/password-hashes/pull/291

## 0.9.0 (2022-02-17)
### Changed
- Bump `salsa20` dependency to v0.10, edition to 2021, and MSRV to 1.56 ([#273])

[#273]: https://github.com/RustCrypto/password-hashes/pull/273

## 0.8.1 (2021-11-25)
### Changed
- Bump `sha2` dependency to v0.10, `pbkdf2` to v0.10, `hmac` to v0.12 ([#254])

[#254]: https://github.com/RustCrypto/password-hashes/pull/254

## 0.8.0 (2021-08-27)
### Changed
- Bump `password-hash` to v0.3 ([#217])
- Use `resolver = "2"`; MSRV 1.51+ ([#220])
- Bump `pbkdf2` dependency to v0.9 ([#233])

### Removed
- `McfHasher` impls for `Scrypt` ([#219])

[#217]: https://github.com/RustCrypto/password-hashing/pull/217
[#219]: https://github.com/RustCrypto/password-hashing/pull/219
[#220]: https://github.com/RustCrypto/password-hashing/pull/220
[#233]: https://github.com/RustCrypto/password-hashing/pull/233

## 0.7.0 (2021-04-29)
### Changed
- Bump `password-hash` crate dependency to v0.2 ([#164])
- Bump `hmac` and `crypto-mac` crate deps to v0.11 ([#165])
- Bump `salsa20` crate dependency to v0.8 ([#166])
- Bump `pbkdf2` crate dependency to v0.8 ([#167])

[#164]: https://github.com/RustCrypto/password-hashing/pull/164
[#165]: https://github.com/RustCrypto/password-hashing/pull/165
[#166]: https://github.com/RustCrypto/password-hashing/pull/166
[#167]: https://github.com/RustCrypto/password-hashing/pull/167

## 0.6.5 (2021-03-27)
### Fixed
- Pin `password-hash` to v0.1.2 or newer ([#151])

[#151]: https://github.com/RustCrypto/password-hashing/pull/151

## 0.6.4 (2021-03-17)
### Changed
- Bump `base64ct` dependency to v1.0 ([#144])

[#144]: https://github.com/RustCrypto/password-hashing/pull/144

## 0.6.3 (2021-02-20)
### Changed
- Enable `rand_core` feature of `password-hash` ([#139])

[#139]: https://github.com/RustCrypto/password-hashing/pull/139

## 0.6.2 (2021-02-06)
### Added
- `Params` accessor methods ([#123])

[#123]: https://github.com/RustCrypto/password-hashing/pull/123

## 0.6.1 (2021-02-01)
### Changed
- Bump `base64ct` dependency to v0.2 ([#119])

[#119]: https://github.com/RustCrypto/password-hashing/pull/119

## 0.6.0 (2021-01-29)
### Added
- PHC hash support using `password-hash` crate ([#111])

### Changed
- Rename `include_simple` features to `simple` ([#99])
- Rename `ScryptParams` => `Params` ([#112])

[#99]: https://github.com/RustCrypto/password-hashing/pull/99
[#111]: https://github.com/RustCrypto/password-hashing/pull/111
[#112]: https://github.com/RustCrypto/password-hashing/pull/112

## 0.5.0 (2020-10-18)
### Changed
- Bump `crypto-mac` dependency to v0.10 ([#58])
- Use `salsa20`crate to implement Salsa20/8 ([#60])

[#60]: https://github.com/RustCrypto/password-hashing/pull/60
[#58]: https://github.com/RustCrypto/password-hashing/pull/58

## 0.4.1 (2020-08-24)
### Changed
- Minor documentation update ([#50])

[#50]: https://github.com/RustCrypto/password-hashing/pull/50

## 0.4.0 (2020-08-18)
### Changed
- Bump `pbkdf2` dependency to v0.5 ([#45])

[#45]: https://github.com/RustCrypto/password-hashing/pull/45

## 0.3.1 (2020-07-03)
### Fixed
- Enable `alloc` feature for `base64`. ([#38])
- Remove superfluous `main()` in documentation ([#40]) 

[#38]: https://github.com/RustCrypto/password-hashing/pull/38
[#40]: https://github.com/RustCrypto/password-hashing/pull/40

## 0.3.0 (2020-06-10)
### Added
- `recommended` method for easy creation of recommended ScryptParam ([#28])
- `std` feature ([#32])
- `thread_rng` feature ([#33])

### Changed
- Code improvements ([#33])
- Bump `rand` to v0.7 ([#33])
- Bump `hmac` to v0.8 ([#30])
- Bump `sha2` to v0.9 ([#30])
- Bump `pbkdf2` to v0.4 ([#36])
- Bump `subtle` to v2 ([#13])
- MSRV 1.41+ ([#30])
- Upgrade to Rust 2018 edition ([#24])

[#36]: https://github.com/RustCrypto/password-hashing/pull/36
[#33]: https://github.com/RustCrypto/password-hashing/pull/33
[#32]: https://github.com/RustCrypto/password-hashing/pull/32
[#30]: https://github.com/RustCrypto/password-hashing/pull/30
[#28]: https://github.com/RustCrypto/password-hashing/pull/28
[#24]: https://github.com/RustCrypto/password-hashing/pull/24
[#13]: https://github.com/RustCrypto/password-hashing/pull/13

## 0.2.0 (2018-10-08)

## 0.1.2 (2018-08-30)

## 0.1.1 (2018-07-15)

## 0.1.0 (2018-06-30)
