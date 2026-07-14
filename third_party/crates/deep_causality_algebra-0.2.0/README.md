[//]: # (---)

[//]: # (SPDX-License-Identifier: MIT)

[//]: # (---)

# DeepCausality Algebra

[![Crates.io][crates-badge]][crates-url]
[![Docs.rs][docs-badge]][docs-url]
[![MIT licensed][mit-badge]][mit-url]

[crates-badge]: https://img.shields.io/badge/Crates.io-Latest-blue

[crates-url]: https://crates.io/crates/deep_causality_algebra

[docs-badge]: https://img.shields.io/badge/Docs.rs-Latest-blue

[docs-url]: https://docs.rs/deep_causality_algebra/latest/deep_causality_algebra/

[mit-badge]: https://img.shields.io/badge/License-MIT-blue.svg

[mit-url]: https://github.com/deepcausality-rs/deep_causality/blob/main/LICENSE

## Summary

Abstract algebra traits for the [DeepCausality project](http://www.deepcausality.com). The crate defines the trait
tower that the numeric and physics crates build on:

- **Structure traits:** Magma, Semigroup, Monoid, Group, Ring, Field, and the algebra-over-a-ring traits.
- **Scalar traits:** `Real`, `Scalar`, `RealField`, `ComplexField`, `Normed`, `NormedScalar`, and `ConjugateScalar`.
- **Marker traits:** `Associative`, `Commutative`, `Distributive`, `Idempotent`, and the semilattice markers.
- **Isomorphism markers:** `GroupIso`, `RingIso`, `FieldIso`, `AlgebraIso`, and `DivisionAlgebraIso`, plus their
  witness-typed Tier 2 counterparts.

Blanket implementations cover the real primitives (`f32`, `f64`, `Float106`) through the `Float` trait from
`deep_causality_num`. The concrete number types implement these traits in their own crates: `Complex`, `Quaternion`,
and `Octonion` in `deep_causality_num_complex`, and `Dual` in `deep_causality_num_dual`.

The implementation is macro-free and unsafe-free. Its only dependency is `deep_causality_num`.

## Reference documentation

- [Algebraic Traits](README_ALGEBRA_TRAITS.md) — the full trait hierarchy, from Magma to Field, with the laws each
  trait promises and the types that implement it.
- [Isomorphism Traits](README_ISOMORPHISM.md) — the three-tier iso vocabulary (`From`-based markers, witness-typed
  isos, and the HKT bridge in `deep_causality_haft`).

## Dependency

Add the crate to your `Cargo.toml`:

```toml
[dependencies]
deep_causality_algebra = "0.1"
```

## License

This project is licensed under the [MIT license](LICENSE).
