# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.4.13 (2026-06-27)
### Added
- `ArraySize` for `U521` and `U522` for NIST P-521 ([#228])

[#228]: https://github.com/RustCrypto/hybrid-array/pull/228

## 0.4.12 (2026-05-09)
### Added
- `ArraySize` impls for Classic McEliece ([#220])

[#220]: https://github.com/RustCrypto/hybrid-array/pull/220

## 0.4.11 (2026-04-24)
### Added
- HPKE Hybrid KEM sizes ([#218])

### Removed
- `Clone` bounds on `Box`/`Vec` conversions ([#209])

[#209]: https://github.com/RustCrypto/hybrid-array/pull/209
[#218]: https://github.com/RustCrypto/hybrid-array/pull/218

## 0.4.10 (2026-03-31)
### Added
- `AsMut<Array<T, U>>` impl for `Array<T, U>` ([#193])
- HQC KEM sizes ([#195])

[#193]: https://github.com/RustCrypto/hybrid-array/pull/193
[#195]: https://github.com/RustCrypto/hybrid-array/pull/195

## 0.4.9 (2026-03-30)
### Added
- Functions for casting from core references ([#181])
  - `Array::cast_from_core`: `const fn` equivalent of `From<[T; N]>`
  - `Array::cast_from_core_mut`: `mut` equivalent of the above
  - `Array::from_ref`: cast `&T` to `&Array<T; U1>`
  - `Array::from_mut`: `mut` equivalent of the above

[#181]: https://github.com/RustCrypto/hybrid-array/pull/181

## 0.4.8 (2026-03-08)
### Added
- `ctutils` support ([#177])

[#177]: https://github.com/RustCrypto/hybrid-array/pull/177

## 0.4.7 (2026-02-03)
### Added
- `Flatten` and `Unflatten` traits ([#170])
- `Array::slice_as_(mut_)array` ([#171])
- `SliceExt` ([#172])

[#170]: https://github.com/RustCrypto/hybrid-array/pull/170
[#171]: https://github.com/RustCrypto/hybrid-array/pull/171
[#172]: https://github.com/RustCrypto/hybrid-array/pull/172

## 0.4.6 (2026-01-22)
### Added
- Optional dependency on `zerocopy` with impls for `Array` ([#162])
- `Debug` bound to `ArraySize` ([#165])

[#162]: https://github.com/RustCrypto/hybrid-array/pull/162
[#165]: https://github.com/RustCrypto/hybrid-array/pull/165

## 0.4.5 (2025-09-29)
### Added
- Impl `arbitrary::Arbitrary` for `Array` ([#153])

### Changed
- Switch from `doc_auto_cfg` to `doc_cfg` ([#154])

[#153]: https://github.com/RustCrypto/hybrid-array/pull/153
[#154]: https://github.com/RustCrypto/hybrid-array/pull/154

## 0.4.4 (2025-09-24)
### Added
- Enable the `subtle/const-generics` feature ([#149])

[#149]: https://github.com/RustCrypto/hybrid-array/pull/149

## 0.4.3 (2025-09-23)
### Added
- `Array::as_(mut_)ptr` ([#147])

### Changed
- Remove bounds on `Array::slice_as_flattened(_mut)`; make `const fn` ([#144])
- Make `Array::as_(mut_)slice` a `const fn` ([#147])
- Make `Array::<Array<T, U>::as_flattened(_mut)` a `const fn` ([#147])

[#144]: https://github.com/RustCrypto/hybrid-array/pull/144
[#147]: https://github.com/RustCrypto/hybrid-array/pull/147

## 0.4.2 (2025-09-21) [YANKED]
### Added
- `Array::slice_as_flattened(_mut)` ([#142])

[#142]: https://github.com/RustCrypto/hybrid-array/pull/142

## 0.4.1 (2025-09-10)
### Changed
- Make slice conversions `const fn` ([#140])

[#140]: https://github.com/RustCrypto/hybrid-array/pull/140

## 0.4.0 (2025-09-01)
### Added
- `ArraySize` impls for `U536` and `U568` ([#128])
- `AsArrayRef`/`AsArrayMut` traits with impls on `[T; N]` and `Array` ([#135])
- `alloc` feature with `Box`/`Vec` conversions to/from `Array` ([#136], [#138])

### Removed
- `AsRef`/`AsMut` impls on `[T; N]` ([#133])

[#128]: https://github.com/RustCrypto/hybrid-array/pull/128
[#133]: https://github.com/RustCrypto/hybrid-array/pull/133
[#135]: https://github.com/RustCrypto/hybrid-array/pull/135
[#136]: https://github.com/RustCrypto/hybrid-array/pull/136
[#138]: https://github.com/RustCrypto/hybrid-array/pull/138

## 0.3.1 (2025-03-30)
### Added
- `subtle` feature ([#126])

[#126]: https://github.com/RustCrypto/hybrid-array/pull/126

## 0.3.0 (2025-02-21)
### Changed
- Bump edition to 2024; MSRV 1.85 ([#116])

### Removed
- `U3293` as an unused ML-DSA size ([#117])

[#116]: https://github.com/RustCrypto/hybrid-array/pull/116
[#117]: https://github.com/RustCrypto/hybrid-array/pull/117

## 0.2.3 (2024-12-07)
### Added
- Additional ML-DSA sizes ([#108])

[#108]: https://github.com/RustCrypto/hybrid-array/pull/108

## 0.2.2 (2024-11-11)
### Added
- FrodoKEM sizes ([#104])

[#104]: https://github.com/RustCrypto/hybrid-array/pull/104

## 0.2.1 (2024-10-20)
### Fixed
- MSRV badge ([9d47c798](https://github.com/RustCrypto/hybrid-array/commit/9d47c79861057b3a04bb19cb2dfaa1f75cbf9ddd))

## 0.2.0 (2024-10-19)
### Added
- Reference conversion support from core arrays ([utils#904])
- Impl `Default` for `Array` ([utils#905])
- `Deref`/`DerefMut` impls for `Array` ([utils#908], [utils#913])
- Impl `From<Array<T, U>>` for `[T; N]` ([utils#945])
- Impl `IntoIterator` for all `ArraySize`s ([utils#956])
- Impl `IntoIterator` for references to all `ArraySize`s ([utils#957])
- Concat and split methods ([utils#958])
- `slice_as_chunks(_mut)` methods ([utils#974])
- Impl `Zeroize`/`ZeroizeOnDrop` for `Array` ([utils#984])
- `AssocArraySize` trait ([utils#1006], [#40])
- `sizes` submodule ([utils#1014], [#68])
- `ArrayN` type alias ([utils#1017])
- Impl `FromIterator` ([utils#1039])
- `Array::try_from_iter` ([#4])
- Helper functions for `Array<MaybeUninit<T>, U>` ([#8])
- `Send` and `Sync` impls for `Array` ([#15])
- `Array::map` ([#61])
- Support all array sizes up to `U512` ([#67])
- `Array<Array<...>>::as_flattened{_mut}()` ([#86])
- `serde` support ([#88])
- `bytemuck` support ([#99])

### Changed
- Use GATs for `ArraySize` ([utils#893])
- Make `ArraySize` an `unsafe trait` ([utils#914])
- MSRV 1.81 ([#85])

### Removed
- `ByteArray` type alias ([utils#995])
- `ArrayOps` trait ([#30])
- `std` feature ([#85])

[utils#893]: https://github.com/RustCrypto/utils/pull/893
[utils#904]: https://github.com/RustCrypto/utils/pull/904
[utils#905]: https://github.com/RustCrypto/utils/pull/905
[utils#908]: https://github.com/RustCrypto/utils/pull/908
[utils#913]: https://github.com/RustCrypto/utils/pull/913
[utils#914]: https://github.com/RustCrypto/utils/pull/914
[utils#945]: https://github.com/RustCrypto/utils/pull/945
[utils#956]: https://github.com/RustCrypto/utils/pull/956
[utils#957]: https://github.com/RustCrypto/utils/pull/957
[utils#958]: https://github.com/RustCrypto/utils/pull/958
[utils#974]: https://github.com/RustCrypto/utils/pull/974
[utils#984]: https://github.com/RustCrypto/utils/pull/984
[utils#995]: https://github.com/RustCrypto/utils/pull/995
[utils#1006]: https://github.com/RustCrypto/utils/pull/1006
[utils#1014]: https://github.com/RustCrypto/utils/pull/1014
[utils#1017]: https://github.com/RustCrypto/utils/pull/1017
[utils#1039]: https://github.com/RustCrypto/utils/pull/1039
[#4]: https://github.com/RustCrypto/hybrid-array/pull/4
[#8]: https://github.com/RustCrypto/hybrid-array/pull/8
[#15]: https://github.com/RustCrypto/hybrid-array/pull/15
[#30]: https://github.com/RustCrypto/hybrid-array/pull/30
[#40]: https://github.com/RustCrypto/hybrid-array/pull/40
[#61]: https://github.com/RustCrypto/hybrid-array/pull/61
[#67]: https://github.com/RustCrypto/hybrid-array/pull/67
[#68]: https://github.com/RustCrypto/hybrid-array/pull/68
[#85]: https://github.com/RustCrypto/hybrid-array/pull/85
[#86]: https://github.com/RustCrypto/hybrid-array/pull/86
[#88]: https://github.com/RustCrypto/hybrid-array/pull/88
[#99]: https://github.com/RustCrypto/hybrid-array/pull/99

## 0.1.0 (2022-05-07)
- Initial release
