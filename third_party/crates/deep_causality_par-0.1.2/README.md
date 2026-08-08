[//]: # (---)

[//]: # (SPDX-License-Identifier: MIT)

[//]: # (---)

# DeepCausality Parallel traits

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

Shared parallelism primitives for the DeepCausality workspace.

The crate carries two items.

`MaybeParallel` is the feature-conditional thread-safety marker used by the
`parallel` features of `deep_causality_topology` and `deep_causality_fft`.
With `--features parallel` the trait is a `Send + Sync` alias
(blanket-implemented); without it the trait is vacuous, so serial builds
carry no extra bounds.

`scoped_map` is the minimal in-house fork-join surface: an order-preserving
map over a slice that fans out on `std::thread::scope` threads under the
`parallel` feature (one contiguous chunk per available core) and runs
inline without it. It targets few, long, data-independent tasks such as
counterfactual branch fan-outs; it is not a work-stealing scheduler and
adds no external dependency.

Hosting both in one Tier-0 crate guarantees a single definition:
downstream crates forward their own `parallel` feature to
`deep_causality_par/parallel`, and Cargo feature unification keeps every
crate in a build agreeing on what the bound means.

No `unsafe` — the crate opts into the workspace-wide
`unsafe_code = "forbid"` lint policy.


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
