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

- **Algebraic Traits:** A complete hierarchy of abstract algebra structures (Magma → Monoid → Group → Ring → Field) with
  rigorous mathematical foundations
- **Cast Traits:** Safe primitive type conversions (`AsPrimitive`, `FromPrimitive`, `ToPrimitive`, `NumCast`)
- **Identity Traits:** Zero and One with const variants for compile-time evaluation
- **Float Types:** Standard floating-point abstractions plus `Float106` for double-double precision arithmetic
- **Complex Types:** Full implementations of `Complex`, `Quaternion`, and `Octonion` number systems

The implementation is **macro-free**, **unsafe-free**, and **dependency-free** (with optional `libm` for no-std float
support). Compiles for std, no-std, and no-std without float.

### Algebraic Traits

The algebra module provides a rigorous type-safe hierarchy of abstract algebraic structures:

| Structure           | Description                                            |
|---------------------|--------------------------------------------------------|
| **Magma**           | Set with a closed binary operation                     |
| **Monoid**          | Magma + associativity + identity                       |
| **Group**           | Monoid + inverses                                      |
| **Ring**            | Abelian group + multiplicative monoid + distributivity |
| **Field**           | Commutative ring + multiplicative inverses             |
| **RealField**       | Field + ordering + transcendental functions            |
| **Module**          | Vector-like structure over a ring                      |
| **Algebra**         | Module with bilinear product                           |
| **DivisionAlgebra** | Algebra with inverses (Complex, Quaternion, Octonion)  |

See [Algebraic Traits Reference](README_ALGEBRA_TRAITS.md) for the complete hierarchy diagram and mathematical
documentation.

### Integer Traits

Type-safe abstractions over Rust's primitive integer types, extending the `Ring` algebraic structure:

| Trait           | Covers               | Key Operations                                                      |
|-----------------|----------------------|---------------------------------------------------------------------|
| **Integer**     | All primitives       | Bit ops, checked/saturating/wrapping arithmetic, Euclidean division |
| **SignedInt**   | `i8`–`i128`, `isize` | `abs`, `signum`, `is_negative`, `checked_neg`                       |
| **UnsignedInt** | `u8`–`u128`, `usize` | `is_power_of_two`, `next_power_of_two`                              |

### Float Types

| Type            | Description                                                | Key Traits                          |
|-----------------|------------------------------------------------------------|-------------------------------------|
| **Float**       | Trait for `f32` and `f64`                                  | `RealField`, `Field`, `Float`       |
| **Float106**    | High-precision (~31 digits) using double-double arithmetic | `RealField`, `Field`, `Float`       |
| **FloatOption** | Abstracts over floats and their `Option` variants          | Utility trait for nullable numerics |

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

### Complex Types

| Type           | Algebra          | Associative | Commutative | Key Traits                                       |
|----------------|------------------|:-----------:|:-----------:|--------------------------------------------------|
| **Complex**    | Division Algebra |      ✅      |      ✅      | `Field`, `DivisionAlgebra`, `Rotation`           |
| **Quaternion** | Division Algebra |      ✅      |      ❌      | `AssociativeRing`, `DivisionAlgebra`, `Rotation` |
| **Octonion**   | Division Algebra |      ❌      |      ❌      | `DivisionAlgebra` (non-associative)              |

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

### Isomorphism Traits

A two-tier vocabulary for declaring **isomorphisms** between algebraic structures. The result is a type-checked, structure-preserving bijection that lets generic code accept either representation transparently.

| Tier | Module | Foundation | Use when |
|---|---|---|---|
| **Tier 1** | `iso::*` | Bidirectional `From` + empty marker subtraits | Both types live in (or are reachable from) your crate |
| **Tier 2** | `iso::witness::*` | Witness-typed `Iso<S, T>` with `to_target` / `to_source` | Cross-crate isos blocked by the orphan rule |

Both tiers expose the same algebraic hierarchy (`GroupIso` -> `RingIso` -> `FieldIso`; `AlgebraIso` -> `DivisionAlgebraIso`) and a matching suite of property-test helpers under `iso::test_support` and `iso::witness::test_support`. Tier 2 also provides `StandardIso<S, T>`: a zero-sized generic witness with blanket impls that automatically satisfy every marker subtrait when bidirectional `From` exists.

A companion **Tier 3** (`NaturalIso<F, G>` through `NaturalIso5`) lifts the same vocabulary to type constructors (HKTs); it lives in [`deep_causality_haft`](../deep_causality_haft/README.md#natural-isomorphisms-tier-3-iso-traits).

See [Isomorphism Reference](README_ISOMORPHISM.md) for the full three-tier design, trait-by-trait usage, helper signatures, and worked examples.

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

## License

This project is licensed under the [MIT license](LICENSE).

## Security

For details about security, please read
the [security policy](https://github.com/deepcausality-rs/deep_causality/blob/main/SECURITY.md).

## Author

* [Marvin Hansen](https://github.com/marvin-hansen).
* Github GPG key ID: 369D5A0B210D39BC
* GPG Fingerprint: 4B18 F7B2 04B9 7A72 967E 663E 369D 5A0B 210D 39BC