[//]: # (---)

[//]: # (SPDX-License-Identifier: MIT)

[//]: # (---)

# 🏁 Data structures 🏁

[![Crates.io][crates-badge]][crates-url]
[![Docs.rs][docs-badge]][docs-url]
[![MIT licensed][mit-badge]][mit-url]
![Tests][test-url]

[crates-badge]: https://img.shields.io/badge/Crates.io-Latest-blue

[crates-url]: https://crates.io/crates/deep_causality_data_structures

[docs-badge]: https://img.shields.io/badge/Docs.rs-Latest-blue

[docs-url]: https://docs.rs/deep_causality_data_structures/latest/deep_causality_data_structures/

[mit-badge]: https://img.shields.io/badge/License-MIT-blue.svg

[mit-url]: https://github.com/deepcausality-rs/deep_causality/blob/main/LICENSE

[test-url]: https://github.com/deepcausality-rs/deep_causality/actions/workflows/run_tests.yml/badge.svg

High performance datastructures used in [DeepCausality](https://github.com/deepcausality-rs/deep_causality).

ArrayGrid is an abstraction over scalars, vectors, and low dimensional matrices similar to a tensor.
In contrast to a tensor, an ArrayGrid is limited to low dimensions (1 to 4), only allowing a scalar,
vector, or matrix type. Still, all of them are represented as a static fixed-size const generic array.
Fixed-sized arrays allow for several compiler optimizations, including a cache-aligned data layout and the removal of
runtime array boundary checks because all structural parameters are known upfront, providing a significant performance
boost over tensors.


The sliding window implementation over-allocates to trade space (memory) for time complexity by delaying the rewind
operation when hitting the end of the underlying data structure.
Specifically, a sliding window of size N can hold, without any array copy, approximately C-1 elements,
where C is the total capacity defined as NxM with N as the window size and M as a multiple.
This crate has two implementations, one over vector and the second over a const generic array. The const generic
implementation is significantly faster than the vector-based version.

## 🤔 Why?

1) Zero cost abstraction.
2) Zero unsafe.
3) Zero macros.
4) Zero external dependencies.

# Performance:

## ArrayGrid

**Set value:**

| Dimension | Safe Implementation | Unsafe Implementation | Improvement |
|-----------|---------------------|-----------------------|-------------|
| 1D Grid   | 604.71 ps           | 271.38 ps             | 55.1%       |
| 2D Grid   | 581.33 ps           | 417.39 ps             | 28.2%       |
| 3D Grid   | 862.16 ps           | 577.04 ps             | 33.0%       |
| 4D Grid   | 1.137 ns            | 812.62 ps             | 28.5%       |

More details on performance can be found in the [Performance](README_ArrayGrid.md#performance) section
of the [ArrayGrid document](README_ArrayGrid.md).

## Sliding Window

**Single Push:**

| Implementation      	 | Single Push Time 	 | Notes                                                	 |
|-----------------------|--------------------|--------------------------------------------------------|
| ArrayStorage        	 | ~2.08ns          	 | Optimized for continuous access patterns             	 |
| VectorStorage       	 | ~2.5ns           	 | Good for dynamic sizing                              	 |
| UnsafeVectorStorage 	 | ~2.3ns           	 | Better performance than safe vector                  	 |
| UnsafeArrayStorage  	 | ~1.9ns           	 | Best performance for sequential and batch operations 	 |

**Sequential Operations:**

| Implementation      | Operation Time | Notes                    | 
|---------------------|----------------|--------------------------| 
| UnsafeArrayStorage  | ~550ps         | Best cache utilization   | 
| ArrayStorage        | ~605ps         | Excellent cache locality | 
| UnsafeVectorStorage | ~750ps         | Good for mixed workloads | 
| VectorStorage       | ~850ps         | Most predictable         |

More details on performance can be found in the [Performance](README_SlidingWindow.md#performance) section
of the [SlidingWindow document](README_SlidingWindow.md).

## 🚀 Install

Just run:

```bash
cargo add deep_causality_data_structures
```

## 📚 Docs

* [API Docs](https://docs.rs/deep_causality_data_structures/latest/deep_causality_data_structures)
* [ArrayGrid Summary](README_ArrayGrid.md)
* [CausalTensor Summary](../deep_causality_tensor/README.md)
* [SlidingWindow Summary](README_SlidingWindow)

## ⭐ Usage

**ArrayGrid:**
* [Design & Details](README_ArrayGrid)
* [Benchmark](benches/benchmarks)
* [Examples](examples/array_grid)
* [Test](tests/grid_type)

* **SlidingWindow:**
* [Design & Details](README_SlidingWindow.md)
* [Benchmark](benches/benchmarks)
* [Examples](examples/window_type)
* [Test](tests/window_type)

## 🙏 Prior Art

The project took inspiration from:

* [sliding_features](https://crates.io/crates/sliding_features)
* [sliding-window-aggregation](https://crates.io/crates/sliding-window-aggregation)
* [sliding_window_alt](https://crates.io/crates/sliding_window_alt)
* [sliding_windows](https://crates.io/crates/sliding_windows)

## 👨‍💻👩‍💻 Contribution

Contributions are welcomed especially related to documentation, example code, and fixes.
If unsure where to start, just open an issue and ask.

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in deep_causality by you,
shall be licensed under the MIT licence, without any additional terms or conditions.

## 📜 Licence

This project is licensed under the [MIT license](LICENSE).

## 👮️ Security

For details about security, please read
the [security policy](https://github.com/deepcausality-rs/deep_causality/blob/main/SECURITY.md).

## 💻 Author

* [Marvin Hansen](https://github.com/marvin-hansen).
* Github GPG key ID: 369D5A0B210D39BC
* GPG Fingerprint: 4B18 F7B2 04B9 7A72 967E 663E 369D 5A0B 210D 39BC