[//]: # (---)

[//]: # (SPDX-License-Identifier: MIT)

[//]: # (---)

# DeepCausality NUM types and traits

[![Crates.io][crates-badge]][crates-url]
[![Docs.rs][docs-badge]][docs-url]
[![MIT licensed][mit-badge]][mit-url]
![Tests][test-url]

[crates-badge]: https://img.shields.io/badge/Crates.io-Latest-blue

[crates-url]: https://crates.io/crates/deep_causality_num

[docs-badge]: https://img.shields.io/badge/Docs.rs-Latest-blue

[docs-url]: https://docs.rs/deep_causality_num/latest/deep_causality_num/

[mit-badge]: https://img.shields.io/badge/License-MIT-blue.svg

[mit-url]: https://github.com/deepcausality-rs/deep_causality/blob/main/LICENSE

[test-url]: https://github.com/deepcausality-rs/deep_causality/actions/workflows/run_tests.yml/badge.svg

## Summary

A comprehensive numerical foundation library for the [DeepCausality project](http://www.deepcausality.com). This crate
provides:

- **Cast Traits:** Safe primitive type conversions (`AsPrimitive`, `FromPrimitive`, `ToPrimitive`, `NumCast`)
- **Identity Traits:** Zero and One with const variants for compile-time evaluation
- **Float Types:** Standard floating-point abstractions plus `Float106` for double-double precision arithmetic
- **Integer Traits:** Type-safe abstractions over the primitive integer types

The implementation is **macro-free**, **unsafe-free**, and **dependency-free** (with optional `libm` for no-std float
support). Compiles for std, no-std, and no-std without float.

The abstract algebra traits, the hypercomplex number types, and the dual number type used to live here. They now have
their own crates:

- [`deep_causality_algebra`](../deep_causality_algebra/README.md) — the algebra trait tower (Magma → Group → Ring →
  Field), the scalar traits, and the isomorphism markers.
- [`deep_causality_num_complex`](../deep_causality_num_complex/README.md) — `Complex`, `Quaternion`, and `Octonion`.
- [`deep_causality_num_dual`](../deep_causality_num_dual/README.md) — the `Dual` number for forward-mode autodiff.

### Integer Traits

Type-safe abstractions over Rust's primitive integer types:

| Trait           | Covers               | Key Operations                                                      |
|-----------------|----------------------|---------------------------------------------------------------------|
| **Integer**     | All primitives       | Bit ops, checked/saturating/wrapping arithmetic, Euclidean division |
| **SignedInt**   | `i8`–`i128`, `isize` | `abs`, `signum`, `is_negative`, `checked_neg`                       |
| **UnsignedInt** | `u8`–`u128`, `usize` | `is_power_of_two`, `next_power_of_two`                              |

### Float Types

| Type            | Description                                                | Key Traits                          |
|-----------------|------------------------------------------------------------|-------------------------------------|
| **Float**       | Trait for `f32` and `f64`                                  | `Float`, `Num`                      |
| **Float106**    | High-precision (~31 digits) using double-double arithmetic | `Float`, `Num`                      |
| **FloatOption** | Abstracts over floats and their `Option` variants          | Utility trait for nullable numerics |

The real fields (`f32`, `f64`, `Float106`) also implement the full algebra tower (`RealField`, `Field`, `Scalar`, and
the rest); those trait implementations live in [`deep_causality_algebra`](../deep_causality_algebra/README.md).

#### Float106 vs f128 Comparison

| Aspect           | Float106                   | f128 (IEEE binary128)                                                     |
|------------------|----------------------------|---------------------------------------------------------------------------|
| Mantissa         | 106 bits                   | 112 bits                                                                  |
| Precision        | ~32 decimal digits (10⁻³¹) | ~34 decimal digits (10⁻³⁴)                                                |
| Speed            | ~2-4× slower than f64      | ~10-100× slower (software emulated)                                       |
| Hardware support | None (pure software)       | Very rare (POWER9, some ARMs)                                             |
| Rust status      | **Available now**          | Nightly only ([#116909](https://github.com/rust-lang/rust/issues/116909)) |

**Physical scale context:**

| Type         | Precision      | Scale              | Physical Reference    |
|--------------|----------------|--------------------|-----------------------|
| f64          | ~15 digits     | 10⁻¹⁵ (femto)      | Proton size           |
| **Float106** | **~32 digits** | **10⁻³¹ (quecto)** | Near Planck length    |
| f128         | ~34 digits     | 10⁻³⁴              | Planck length (10⁻³⁵) |

Float106 provides precision comparable to f128 while being significantly faster
on most hardware since it uses native f64 FMA operations.

### Numerical Traits:

**Cast Traits:**

* AsPrimitive
* FloatAsScalar
* IntAsScalar
* FromPrimitive
* ToPrimitive
* NumCast
* IntoFloat

**General traits:**

* Num
* NumOps

**Identity traits:**

* One / OneConst
* Zero / Zero Const

## non-std support

The `deep_causality_num` crate provides support for `no-std` environments. This is particularly useful for embedded
systems or other contexts where the standard library is not available. Note, the std feature is enabled by default thus
you need to opt-into non-std via feature flags.

To use this crate in a `no-std` environment, you need to disable the default `std` feature and, if your application
requires floating-point operations, enable the `libm_math` feature. The `libm_math` feature integrates the `libm` crate,
which provides software implementations of floating-point math functions for `no-std`.

### Cargo Build and Test for `no-std`

**1. Building for `no-std` with Floating-Point Math:**

To build the crate for `no-std` while including floating-point math support (via `libm`), use the following command:

```bash
cargo build --no-default-features --features libm_math -p deep_causality_num
```

**2. Testing for `no-std` with Floating-Point Math:**

To run tests in a `no-std` environment with floating-point math support, use:

```bash
cargo test --no-default-features --features libm_math -p deep_causality_num
```

There might be minor floating precision differences between std and non-std implementations that cause some tests to
fail. If you encounter these, please submit a PR with a fix.

**3. Building for `no-std` without Floating-Point Math (if not needed):**

If your `no-std` application does not require floating-point operations,
you can build without the `libm_math` feature:

```bash
cargo build --no-default-features -p deep_causality_num
```

**4. Testing for `no-std` without Floating-Point Math (if not needed):**

Similarly, to test without floating-point math functions:

```bash
cargo test --no-default-features -p deep_causality_num
```

However, this will cause about 138 tests because to fail since these tests are not configured for conditional test run
because non-std without floating-point math is considered a corner case. If you need better support for this particular
scenario, please open an issue.

### Bazel Build

For regular (std) builds, run:

```bash
   bazel build //deep_causality_num/...
```

and

```bash
   bazel test //deep_causality_num/...
```

for tests. When you want to build for non-std, use

```bash
   bazel build --@rules_rust//rust/settings:no_std=alloc //deep_causality_num/...
```

and

```bash
   bazel test --@rules_rust//rust/settings:no_std=alloc //deep_causality_num/...
```

## Contribution

Contributions are welcomed especially related to documentation, example code, and fixes.
If unsure where to start, just open an issue and ask.

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in deep_causality by you,
shall be licensed under the MIT licence, without any additional terms or conditions.

## Licence

This project is licensed under the [MIT license](LICENSE).

## Security

For details about security, please read
the [security policy](https://github.com/deepcausality-rs/deep_causality/blob/main/SECURITY.md).

