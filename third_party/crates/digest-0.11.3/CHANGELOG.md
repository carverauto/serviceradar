# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.11.3 (2026-04-03)
### Added
- `dev::initialized_mac_test` function ([#2367])
- `TryCustomizedInit` trait ([#2395])

[#2367]: https://github.com/RustCrypto/traits/pull/2367
[#2395]: https://github.com/RustCrypto/traits/pull/2395

## 0.11.2 (2026-03-13)
### Changed
- Do not implement `Clone` as part of `(Reset)MacTraits` in the `buffer_fixed!` macro ([#2341])
- `EagerHash` trait to be a sub-trait of `Clone` ([#2341])

[#2341]: https://github.com/RustCrypto/traits/pull/2341

## 0.11.1 (2026-02-25) [YANKED]
Note: this version was yanked because v0.11.2 introduces minor breaking changes
affecting only pre-release versions of downstream crates.

### Added
- `SmallBlockSizeUser` helper trait. The trait is a sub-trait of `BlockSizeUser`
  with `BlockSize` bounded by `block_buffer::BlockSizes`. ([#2309])

### Changed
- `BufferKindUser` is now a sub-trait of `SmallBlockSizeUser` ([#2309])

[#2309]: https://github.com/RustCrypto/traits/pull/2309

## 0.11.0 (2026-02-13) [YANKED]
Note: this version was yanked because v0.11.1 introduces breaking changes.
Users should migrate to `digest` v0.11.1 and `crypto-common` v0.2.1 using `cargo update`.

### Added
- `CustomizedInit` trait ([#1334])
- `SerializableState` support ([#1369])
- `DynDigestWithOid` wrapper trait ([#1390])
- `VariableOutputCoreCustomized` trait ([#1787], [#2043])
- `buffer_fixed`, `buffer_ct_variable`, `buffer_rt_variable`, and `buffer_xof` macros ([#1799])
- `XofFixedWrapper` ([#1815])
- `CollisionResistance` trait ([#1820])
- `CoreProxy::compose/decompose` methods ([#1898])
- `EagerHash` trait ([#2014])

### Changed
- Replaced `generic-array` with `hybrid-array` ([#1358])
- `crypto-common` dependency bumped to v0.2 ([#1173])
- Edition changed to 2024 and MSRV bumped to 1.85 ([#1759])
- Bump `const-oid` dependency to v0.10 ([#1772])
- `digest::core_api` renamed to `digest::block_api` ([#1799])
- `CtVariableCoreWrapper` renamed to `CtOutWrapper` ([#1799])
- Removed the OID type parameter from `CtOutWrapper` ([#1799])
- Implementations of the `SerializableState` trait ([#1953])
- `new_test!` and `new_mac_test!` macros ([#1958])
- Bump `block-buffer` to v0.11 ([#2082])
- Re-export of `crypto-common` moved to `digest::common` ([#2237])
- Bump `crypto-common` to v0.2 ([#2276])
- Replace `subtle` with `ctutils` ([#2301])

### Removed
- `Mac::new`, `Mac::new_from_slice`, and `Mac::generate_key` methods ([#1173])
- `CoreWrapper`, `RtVariableCoreWrapper`, and `XofReaderCoreWrapper` types ([#1799])
- `io::Write/Read` implementations in favor of the `digest_io::IoWrapper` type ([#1809])
- `VariableOutput` trait ([#2043])
- Implementation of `subtle::ConstantTimeEq` for `CtOutput`. Note that implementation of
  `PartialEq`/`Eq` trait is still const time. ([#2292])

[#1173]: https://github.com/RustCrypto/traits/pull/1173
[#1334]: https://github.com/RustCrypto/traits/pull/1334
[#1358]: https://github.com/RustCrypto/traits/pull/1358
[#1369]: https://github.com/RustCrypto/traits/pull/1369
[#1390]: https://github.com/RustCrypto/traits/pull/1390
[#1759]: https://github.com/RustCrypto/traits/pull/1759
[#1772]: https://github.com/RustCrypto/traits/pull/1772
[#1787]: https://github.com/RustCrypto/traits/pull/1787
[#1799]: https://github.com/RustCrypto/traits/pull/1799
[#1809]: https://github.com/RustCrypto/traits/pull/1809
[#1815]: https://github.com/RustCrypto/traits/pull/1815
[#1820]: https://github.com/RustCrypto/traits/pull/1820
[#1898]: https://github.com/RustCrypto/traits/pull/1898
[#1953]: https://github.com/RustCrypto/traits/pull/1953
[#1958]: https://github.com/RustCrypto/traits/pull/1958
[#2014]: https://github.com/RustCrypto/traits/pull/2014
[#2043]: https://github.com/RustCrypto/traits/pull/2043
[#2082]: https://github.com/RustCrypto/traits/pull/2082
[#2237]: https://github.com/RustCrypto/traits/pull/2237
[#2276]: https://github.com/RustCrypto/traits/pull/2276
[#2292]: https://github.com/RustCrypto/traits/pull/2292
[#2301]: https://github.com/RustCrypto/traits/pull/2301

## 0.10.7 (2023-05-19)
### Changed
- Loosen `subtle` version requirement ([#1260])

[#1260]: https://github.com/RustCrypto/traits/pull/1260

## 0.10.6 (2022-11-17)
### Added
- `Mac::verify_reset` and `Mac::verify_slice_reset` methods ([#1154])

[#1154]: https://github.com/RustCrypto/traits/pull/1154

## 0.10.5 (2022-09-16)
### Fixed 
- MSRV build ([#1117])

[#1117]: https://github.com/RustCrypto/traits/pull/1117

## 0.10.4 (2022-09-16)
### Added
- Feature-gated implementation of the `const_oid::AssociatedOid` trait
for the core wrappers. ([#1098])

[#1098]: https://github.com/RustCrypto/traits/pull/1098

## 0.10.3 (2022-02-16)
### Fixed
- Minimal versions build ([#940])

[#940]: https://github.com/RustCrypto/traits/pull/940

## 0.10.2 (2022-02-10)
### Changed
- Relax bounds on the `Mac` trait ([#849])

[#849]: https://github.com/RustCrypto/traits/pull/849

## 0.10.1 (2021-12-14) [YANKED]
### Added
- `Update::chain` and `Digest::new_with_prefix` methods. ([#846])
- `Mac::generate_key` method. ([#847])

### Fixed
- Doc cfg attribute for `CtOutput` and `MacError`. ([#842])
- Expose `KeyInit::generate_key` method in docs. ([#847])

[#842]: https://github.com/RustCrypto/traits/pull/842
[#846]: https://github.com/RustCrypto/traits/pull/846
[#847]: https://github.com/RustCrypto/traits/pull/847

## 0.10.0 (2021-12-07) [YANKED]
### Changed
- Dirty traits are removed and instead block-level traits are introduced.
Variable output traits reworked and now support both run and compile time selection of output size. ([#380], [#819])
- The `crypto-mac` traits are reworked and merged in. ([#819])

[#819]: https://github.com/RustCrypto/traits/pull/819
[#380]: https://github.com/RustCrypto/traits/pull/380

## 0.9.0 (2020-06-09)
### Added
- `ExtendableOutputDirty` and `VariableOutputDirty` traits ([#183])
- `FixedOutputDirty` trait + `finalize_into*` ([#180])
- `XofReader::read_boxed` method ([#178], [#181], [#182])
- `alloc` feature ([#163])
- Re-export `typenum::consts` as `consts` ([#123])
- `Output` type alias ([#115])

### Changed
- Rename `*result*` methods to `finalize` ala IUF ([#161])
- Use `impl AsRef<[u8]>` instead of generic params on methods ([#112])
- Rename `Input::input` to `Update::update` ala IUF ([#111])
- Upgrade to Rust 2018 edition ([#109])
- Bump `generic-array` to v0.14 ([#95])

[#183]: https://github.com/RustCrypto/traits/pull/183
[#181]: https://github.com/RustCrypto/traits/pull/181
[#182]: https://github.com/RustCrypto/traits/pull/182
[#180]: https://github.com/RustCrypto/traits/pull/180
[#178]: https://github.com/RustCrypto/traits/pull/178
[#163]: https://github.com/RustCrypto/traits/pull/163
[#161]: https://github.com/RustCrypto/traits/pull/161
[#123]: https://github.com/RustCrypto/traits/pull/123
[#115]: https://github.com/RustCrypto/traits/pull/115
[#111]: https://github.com/RustCrypto/traits/pull/111
[#112]: https://github.com/RustCrypto/traits/pull/112
[#109]: https://github.com/RustCrypto/traits/pull/109
[#95]: https://github.com/RustCrypto/traits/pull/95

## 0.8.1 (2019-06-30)

## 0.8.0 (2018-10-01)

## 0.7.6 (2018-09-21)

## 0.7.5 (2018-07-13)

## 0.7.4 (2018-06-21)

## 0.7.3 (2018-06-20)

## 0.7.2 (2017-11-17)

## 0.7.1 (2017-11-15)

## 0.7.0 (2017-11-14)

## 0.6.2 (2017-07-24)

## 0.6.1 (2017-06-18)

## 0.6.0 (2017-06-12)

## 0.5.2 (2017-05-02)

## 0.5.1 (2017-05-02)

## 0.5.0 (2017-04-06)

## 0.4.0 (2016-12-24)

## 0.3.1 (2016-12-16)

## 0.3.0 (2016-11-17)

## 0.2.1 (2016-10-14)

## 0.2.0 (2016-10-14)

## 0.1.0 (2016-10-06)
