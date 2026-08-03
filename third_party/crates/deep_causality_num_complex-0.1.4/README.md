[//]: # (---)

[//]: # (SPDX-License-Identifier: MIT)

[//]: # (---)

# DeepCausality Complex Numbers

[![Crates.io][crates-badge]][crates-url]
[![Docs.rs][docs-badge]][docs-url]
[![MIT licensed][mit-badge]][mit-url]

[crates-badge]: https://img.shields.io/badge/Crates.io-Latest-blue

[crates-url]: https://crates.io/crates/deep_causality_num_complex

[docs-badge]: https://img.shields.io/badge/Docs.rs-Latest-blue

[docs-url]: https://docs.rs/deep_causality_num_complex/latest/deep_causality_num_complex/

[mit-badge]: https://img.shields.io/badge/License-MIT-blue.svg

[mit-url]: https://github.com/deepcausality-rs/deep_causality/blob/main/LICENSE

## Summary

Hypercomplex number types for the [DeepCausality project](http://www.deepcausality.com):

- **`Complex`** — the complex field, with the `Complex32` and `Complex64` aliases.
- **`Quaternion`** — the non-commutative division ring, with `Quaternion32` and `Quaternion64`.
- **`Octonion`** — the non-associative division algebra, with `Octonion32` and `Octonion64`.

Each type is generic over its real base and implements the algebra traits from `deep_causality_algebra` that its
structure supports. `Complex` is a `Field` and a `ComplexField`; `Quaternion` is an associative ring; `Octonion` is a
division algebra. All three carry rotation, conjugation, and norm operations.

The implementation is macro-free and unsafe-free. It depends on `deep_causality_num` and `deep_causality_algebra`.

## Dependency

Add the crate to your `Cargo.toml`:

```toml
[dependencies]
deep_causality_num_complex = "0.1"
```

## License

This project is licensed under the [MIT license](LICENSE).
