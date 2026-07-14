# rapidhash – portable rust hashing

A rust implementation of [rapidhash](https://github.com/Nicoshev/rapidhash), the official successor to [wyhash](https://github.com/wangyi-fudan/wyhash).

- **High quality** – the fastest hash to pass all [SMHasher](https://github.com/rurban/smhasher) and [SMHasher3](https://gitlab.com/fwojcik/smhasher3) tests, with near-ideal collision probability.
- **Very fast** – significant throughput improvement over wyhash and foldhash.
- **Platform independent and no-std compatible** – stable hash output on all platforms with no dependency on vectorized or cryptographic hardware instructions. Optimized for both AMD64 and AArch64.
- **Official successor to wyhash** with improved speed, quality, and compatibility.
- **Run-time and compile-time hashing** – the hash implementation is fully `const`.
- **Idiomatic** `std::hash::Hasher` compatible hasher for `HashMap` and `HashSet`.
- **Non-cryptographic** – "minimally DoS resistant" in the same manner as foldhash.
- **Streamable** – incremental and `Read`-based hashing for large files and other streams.
- **CLI tool** for hashing files or stdin.

**Sponsored by [Upon](https://uponvault.com?utm_source=github&utm_campaign=rapidhash)**, inheritance vaults for your digital life. Ensure your family can access your devices, accounts, and assets when the unexpected happens.

## Usage
### In-Memory Hashing
The in-memory hasher follows rust's `std::hash` traits. The underlying hash function may change between minor versions and is only suitable for in-memory use (e.g. `HashMap`, `HashSet`). Available in `rapidhash::fast` and `rapidhash::quality` flavours.

- `RapidHasher`: a `std::hash::Hasher` compatible hasher using the rapidhash algorithm.
- `RandomState`: a `std::hash::BuildHasher` that initializes the hasher with a random seed and secrets.
- `GlobalState`: a `std::hash::BuildHasher` that initializes the hasher with a global seed and secrets, randomized once per process.
- `SeedableState`: a `std::hash::BuildHasher` that initializes the hasher with a custom seed and secrets.
- `RapidHashMap` / `RapidHashSet`: helper types using `fast::RandomState` with `HashMap` and `HashSet`.

```rust
use rapidhash::RapidHashMap;

// A HashMap using RapidHasher for fast in-memory hashing.
let mut map = RapidHashMap::default();
map.insert("key", "value");
```

```rust
use std::hash::BuildHasher;
use rapidhash::quality::SeedableState;

// Using the RapidHasher directly for in-memory hashing.
let hasher = SeedableState::fixed();
assert_eq!(hasher.hash_one(b"hello world"), 3348275917668072623);
```

### Portable Hashing
Fully compatible with the C++ rapidhash algorithms. Methods are provided for all rapidhash V1, V2, and V3 (with micro/nano) variants. These are stable functions whose output will not change between crate versions.

```rust
use rapidhash::v3::{rapidhash_v3_seeded, rapidhash_v3_file_seeded, RapidSecrets, RapidStreamHasherV3};

/// Set your global hashing secrets.
/// - For HashDoS resistance, choose a randomized secret.
/// - For C++ compatibility, use the `seed_cpp` method or `DEFAULT_RAPID_SECRETS`.
const SECRETS: RapidSecrets = RapidSecrets::seed(0x123456);

// Bulk: hash a complete byte slice.
let bulk = rapidhash_v3_seeded(b"hello world", &SECRETS);

// Stream: write chunks of any size, same output regardless of chunk boundaries.
let mut hasher = RapidStreamHasherV3::new(&SECRETS);
hasher.write(b"hello ");
hasher.write(b"world");
let stream = hasher.finish();

// Read: hash from any `Read` source (files, cursors, etc.).
let read = rapidhash_v3_file_seeded(std::io::Cursor::new(b"hello world"), &SECRETS).unwrap();

assert_eq!(bulk, stream);
assert_eq!(bulk, read);
```

See the [`portable-hash` crate](https://github.com/hoxxep/portable-hash?tab=readme-ov-file#whats-wrong-with-the-stdhash-traits) for why using the standard library hashing traits is not recommended for portable hashing. Rapidhash is planning to implement the `PortableHash` and `PortableHasher` traits in a future release.

### CLI
Rapidhash can be installed as a CLI tool to hash files or stdin. Not a cryptographic hash, but much faster than one. Fully compatible with the C++ rapidhash V1, V2, and V3 algorithms.

Output is the decimal `u64` hash value.

```shell
# install
cargo install rapidhash

# hash a file (output: 8543579700415218186)
rapidhash --v3 example.txt

# hash stdin (output: 8543579700415218186)
echo "example" | rapidhash --v3
```

## Features

- `default`: `std`
- `std`: Enables the `RapidHashMap` and `RapidHashSet` helper types.
- `rand`: Enables using the `rand` library to more securely initialize `RandomState`. Includes the `rand` crate dependency.
- `rng`: Enables `RapidRng`, a fast, non-cryptographic PRNG based on rapidrng. Includes the `rand_core` crate dependency.
- `unsafe`: Uses unsafe pointer arithmetic to skip some unnecessary bounds checks for a small 3-4% performance improvement.
- `nightly`: Enable nightly-only features for even faster hashing, such as overriding `Hasher::write_str` and likely hints.

## Benchmarks

In our benchmarking, rapidhash is one of the fastest general-purpose non-cryptographic hash functions. It places second to gxhash on some benchmarks, but gxhash is not portable and requires AES instructions to compile.

![Hashing Benchmarks](https://github.com/hoxxep/rapidhash/raw/master/docs/bench_hash_aarch64_apple_m1_max.svg)

Rapidhash uses raw throughput benchmarks (the charts) to measure performance over various input sizes, and the [foldhash benchmark suite](https://github.com/orlp/foldhash?tab=readme-ov-file#performance) (the txt tables) to measure workloads that are closer to real-world usage. The foldhash suite benchmarks hashers by measuring raw hash throughput, hashmap lookup miss, hashmap lookup hit, and hashmap insertion performance on a wide variety of commonly hashed types.

The benchmarks have been compiled with and without `-C target-cpu=native` on a variety of platforms to demonstrate rapidhash's strong all-round performance. The full results are available in the [docs folder](https://github.com/hoxxep/rapidhash/tree/master/docs) and are summarised below.

<details>
<summary><strong>aarch64 Apple M1 Max</strong></summary>

```text
┌────────────────┬─────────────┬─────────────┬────────────┬────────────┬────────┬───────┬─────────┐
│         metric ┆ rapidhash-f ┆ rapidhash-q ┆ foldhash-f ┆ foldhash-q ┆ fxhash ┆ ahash ┆ siphash │
╞════════════════╪═════════════╪═════════════╪════════════╪════════════╪════════╪═══════╪═════════╡
│       avg_rank ┆        2.11 ┆        3.53 ┆       2.84 ┆       4.62 ┆   2.88 ┆  5.05 ┆    6.97 │
│ geometric_mean ┆        4.29 ┆        4.82 ┆       4.83 ┆       5.24 ┆   5.50 ┆  5.94 ┆   22.17 │
└────────────────┴─────────────┴─────────────┴────────────┴────────────┴────────┴───────┴─────────┘
```

![Hashing Benchmarks](https://github.com/hoxxep/rapidhash/raw/master/docs/bench_hash_aarch64_apple_m1_max.svg)

</details>

<details>
<summary><strong>aarch64 Apple M1 Max (target-cpu=native)</strong></summary>

```text
┌────────────────┬─────────────┬─────────────┬────────────┬────────────┬────────┬────────┬───────┬─────────┐
│         metric ┆ rapidhash-f ┆ rapidhash-q ┆ foldhash-f ┆ foldhash-q ┆ gxhash ┆ fxhash ┆ ahash ┆ siphash │
╞════════════════╪═════════════╪═════════════╪════════════╪════════════╪════════╪════════╪═══════╪═════════╡
│       avg_rank ┆        2.23 ┆        3.94 ┆       3.30 ┆       5.08 ┆   4.69 ┆   3.16 ┆  5.64 ┆    7.97 │
│ geometric_mean ┆        4.25 ┆        4.79 ┆       4.79 ┆       5.19 ┆   4.93 ┆   5.48 ┆  5.91 ┆   21.99 │
└────────────────┴─────────────┴─────────────┴────────────┴────────────┴────────┴────────┴───────┴─────────┘
```

![Hashing Benchmarks](https://github.com/hoxxep/rapidhash/raw/master/docs/bench_hash_aarch64_apple_m1_max_native.svg)

</details>

<details>
<summary><strong>aarch64 AWS Graviton3</strong></summary>

```text
┌────────────────┬─────────────┬─────────────┬────────────┬────────────┬────────┬───────┬─────────┐
│         metric ┆ rapidhash-f ┆ rapidhash-q ┆ foldhash-f ┆ foldhash-q ┆ fxhash ┆ ahash ┆ siphash │
╞════════════════╪═════════════╪═════════════╪════════════╪════════════╪════════╪═══════╪═════════╡
│       avg_rank ┆        2.27 ┆        3.88 ┆       3.08 ┆       4.66 ┆   2.11 ┆  5.05 ┆    6.97 │
│ geometric_mean ┆        7.82 ┆        9.03 ┆       8.53 ┆       9.66 ┆   8.02 ┆ 10.98 ┆   29.31 │
└────────────────┴─────────────┴─────────────┴────────────┴────────────┴────────┴───────┴─────────┘
```

![Hashing Benchmarks](https://github.com/hoxxep/rapidhash/raw/master/docs/bench_hash_aarch64_aws_graviton3.svg)

</details>

<details>
<summary><strong>aarch64 AWS Graviton3 (target-cpu=native)</strong></summary>

```text
┌────────────────┬─────────────┬─────────────┬────────────┬────────────┬────────┬────────┬───────┬─────────┐
│         metric ┆ rapidhash-f ┆ rapidhash-q ┆ foldhash-f ┆ foldhash-q ┆ gxhash ┆ fxhash ┆ ahash ┆ siphash │
╞════════════════╪═════════════╪═════════════╪════════════╪════════════╪════════╪════════╪═══════╪═════════╡
│       avg_rank ┆        2.59 ┆        4.20 ┆       3.38 ┆       5.28 ┆   4.09 ┆   2.50 ┆  5.98 ┆    7.97 │
│ geometric_mean ┆        7.84 ┆        8.97 ┆       8.56 ┆       9.68 ┆   8.59 ┆   8.15 ┆ 11.16 ┆   32.59 │
└────────────────┴─────────────┴─────────────┴────────────┴────────────┴────────┴────────┴───────┴─────────┘
```

![Hashing Benchmarks](https://github.com/hoxxep/rapidhash/raw/master/docs/bench_hash_aarch64_aws_graviton3_native.svg)

</details>

<details>
<summary><strong>x86_64 AMD EPYC 9R14</strong></summary>

```text
┌────────────────┬─────────────┬─────────────┬────────────┬────────────┬────────┬───────┬─────────┐
│         metric ┆ rapidhash-f ┆ rapidhash-q ┆ foldhash-f ┆ foldhash-q ┆ fxhash ┆ ahash ┆ siphash │
╞════════════════╪═════════════╪═════════════╪════════════╪════════════╪════════╪═══════╪═════════╡
│       avg_rank ┆        2.05 ┆        3.75 ┆       2.81 ┆       4.42 ┆   3.09 ┆  4.91 ┆    6.97 │
│ geometric_mean ┆        4.67 ┆        5.38 ┆       5.27 ┆       5.99 ┆   6.13 ┆  6.50 ┆   23.66 │
└────────────────┴─────────────┴─────────────┴────────────┴────────────┴────────┴───────┴─────────┘
```

![Hashing Benchmarks](https://github.com/hoxxep/rapidhash/raw/master/docs/bench_hash_x86_64_amd_epyc_9R14.svg)

</details>

<details>
<summary><strong>x86_64 AMD EPYC 9R14 (target-cpu=native)</strong></summary>

```text
┌────────────────┬─────────────┬─────────────┬────────────┬────────────┬────────┬────────┬───────┬─────────┐
│         metric ┆ rapidhash-f ┆ rapidhash-q ┆ foldhash-f ┆ foldhash-q ┆ gxhash ┆ fxhash ┆ ahash ┆ siphash │
╞════════════════╪═════════════╪═════════════╪════════════╪════════════╪════════╪════════╪═══════╪═════════╡
│       avg_rank ┆        2.56 ┆        4.36 ┆       3.45 ┆       5.38 ┆   4.31 ┆   3.36 ┆  4.61 ┆    7.97 │
│ geometric_mean ┆        4.68 ┆        5.34 ┆       5.24 ┆       5.91 ┆   5.01 ┆   5.98 ┆  5.63 ┆   25.75 │
└────────────────┴─────────────┴─────────────┴────────────┴────────────┴────────┴────────┴───────┴─────────┘
```

![Hashing Benchmarks](https://github.com/hoxxep/rapidhash/raw/master/docs/bench_hash_x86_64_amd_epyc_9R14_native.svg)

</details>

<details>
<summary><strong>x86_64 Intel Xeon Platinum 8488C</strong></summary>

```text
┌────────────────┬─────────────┬─────────────┬────────────┬────────────┬────────┬───────┬─────────┐
│         metric ┆ rapidhash-f ┆ rapidhash-q ┆ foldhash-f ┆ foldhash-q ┆ fxhash ┆ ahash ┆ siphash │
╞════════════════╪═════════════╪═════════════╪════════════╪════════════╪════════╪═══════╪═════════╡
│       avg_rank ┆        1.86 ┆        3.83 ┆       2.86 ┆       4.50 ┆   2.95 ┆  5.03 ┆    6.97 │
│ geometric_mean ┆        4.52 ┆        5.18 ┆       4.95 ┆       5.55 ┆   5.67 ┆  6.33 ┆   20.24 │
└────────────────┴─────────────┴─────────────┴────────────┴────────────┴────────┴───────┴─────────┘
```

![Hashing Benchmarks](https://github.com/hoxxep/rapidhash/raw/master/docs/bench_hash_x86_64_intel_xeon_8488c.svg)

</details>

<details>
<summary><strong>x86_64 Intel Xeon Platinum 8488C (target-cpu=native)</strong></summary>

```text
┌────────────────┬─────────────┬─────────────┬────────────┬────────────┬────────┬────────┬───────┬─────────┐
│         metric ┆ rapidhash-f ┆ rapidhash-q ┆ foldhash-f ┆ foldhash-q ┆ gxhash ┆ fxhash ┆ ahash ┆ siphash │
╞════════════════╪═════════════╪═════════════╪════════════╪════════════╪════════╪════════╪═══════╪═════════╡
│       avg_rank ┆        2.38 ┆        4.69 ┆       3.52 ┆       5.30 ┆   4.08 ┆   3.39 ┆  4.69 ┆    7.97 │
│ geometric_mean ┆        4.46 ┆        5.09 ┆       4.88 ┆       5.42 ┆   4.73 ┆   5.58 ┆  5.26 ┆   21.34 │
└────────────────┴─────────────┴─────────────┴────────────┴────────────┴────────┴────────┴───────┴─────────┘
```

![Hashing Benchmarks](https://github.com/hoxxep/rapidhash/raw/master/docs/bench_hash_x86_64_intel_xeon_8488c_native.svg)

</details>

<details>
<summary><strong>Benchmark notes</strong></summary>

- Hash throughput does not measure hash "quality", and many of the benchmarked functions fail the [SMHasher3 hash quality benchmarks](https://gitlab.com/fwojcik/smhasher3). Rapidhash is the fastest hash to pass all quality benchmarks. Hash quality affects hashmap performance, as well as algorithms that benefit from high quality hash functions such as HyperLogLog and MinHash.
- **Comparison to foldhash**: Rapidhash uses the same integer buffer construction as foldhash, but is notably faster when hashing strings by making use of the rapidhash algorithm. Rapidhash also offers portable and streaming hash flavours.
- **Comparison to gxhash**: gxhash achieves its high throughput by using AES instructions and consistently outperforms the other accelerated hashers (ahash, th1a, xxhash3_64). It's a great hash function, but is not a portable hash function, requiring `target-cpu=native` or specific feature flags to compile. Gxhash is a great choice for applications that can guarantee the availability of AES instructions and mostly hash strings, but rapidhash may be preferred for hashing tuples and structs, or by libraries that aim to support a wide range of platforms.
- The default rust hasher (SipHasher) unexpectedly appears to run consistently faster _without_ `target-cpu=native` on various x86 and ARM chips.
- Benchmark your own use case, with your real world dataset! We suggest experimenting with different hash functions to see which one works best for your use case. Rapidhash is great for fast general-purpose hashing in libraries and applications that only need minimal DoS resistance, but certain hashers will outperform for specific use cases.
- We recommend using `lto = "fat"` and `codegen-units = 1` in your `Cargo.toml` release and bench profiles to ensure consistent inlining, application performance, and benchmarking results. For example:
    ```toml
    [profile.release]
    opt-level = 3
    lto = "fat"
    codegen-units = 1
    ```

</details>

## Minimal DoS Resistance

Rapidhash is a keyed hash function and the rust implementation deviates from its C++ counterpart by also randomising the secrets array. The algorithm primarily relies on the same 128-bit folded multiply mixing step used by foldhash and ahash's fallback algorithm. It aims to be immune to length extension and re-ordering attacks.

We believe rapidhash is a minimally DoS resistant hash function, such that a non-interactive attacker cannot trivially create collisions if they do not know the seed or secrets. The adverb "minimally" is used to describe that rapidhash is not a cryptographic hash, it is possible to construct collisions if the seed or secrets are known, and it may be possible for an interactive attacker to learn the seed by observing hash outputs or application response times over a large number of inputs.

Provided rapidhash has been instantiated through `RandomState` or `RapidSecrets` using a randomized secret seed, we believe rapidhash is minimally resistant to hash DoS attacks.

## Rapidhash Versioning

### Portable Hashing
C++ compatibility is presented in `rapidhash::v1`, `rapidhash::v2`, and `rapidhash::v3` modules. The output for these is guaranteed to be stable between major crate versions.

Rapidhash V3 is the recommended, fastest, and most recent version of the hash. Streaming is only possible with the rapidhash V3 algorithm. Others are provided for backwards compatibility.

### In-Memory Hashing
Rust hashing traits (`RapidHasher`, `RandomState`, etc.) are implemented in `rapidhash::fast`, `rapidhash::quality`, and `rapidhash::inner` modules. These are not guaranteed to give a consistent hash output between platforms, compiler versions, or crate versions as the rust `Hasher` trait [is not suitable](https://github.com/hoxxep/portable-hash/?tab=readme-ov-file#whats-wrong-with-the-stdhash-traits) for portable hashing.

- Use `rapidhash::fast` for optimal hashing speed with a slightly lower hash quality. Best for most datastructures such as HashMap and HashSet usage.
- Use `rapidhash::quality` where statistical hash quality is the priority, such as HyperLogLog or MinHash algorithms.
- Use `rapidhash::inner` to set advanced parameters to configure the hash function specifically to your use case.

## Crate Versioning
The minimum supported Rust version (MSRV) is 1.71.0.

The rapidhash crate follows this versioning scheme:
- **Major**: breaking API changes, MSRV bumps, or any changes to `rapidhash_v*` output.
- **Minor**: API additions/deprecations, or changes to `RapidHasher` output.
- **Patch**: bug fixes and performance improvements.

Portable hash outputs (e.g. `rapidhash_v3`) are guaranteed to be stable. In-memory hash outputs (e.g. `RapidHasher`) may change between minor versions to allow freely improving performance.

## License and Acknowledgements
This project is licensed under both the MIT and Apache-2.0 licenses. You are free to choose either license.

With thanks to [Nicolas De Carli](https://github.com/Nicoshev) for the original [rapidhash](https://github.com/Nicoshev/rapidhash) C++ implementation, which is licensed under the [MIT License](https://github.com/Nicoshev/rapidhash/blob/master/LICENSE).

With thanks to [Orson Peters](https://github.com/orlp) for his work on [foldhash](https://github.com/orlp/foldhash), which inspired much of the integer hashing optimisations in this crate. Some of the RapidHasher string hashing [optimisations](https://github.com/orlp/foldhash/pull/35) have also made their way back into foldhash as a thanks.

With thanks to [Justin Bradford](https://github.com/jabr) for letting us use the rapidhash crate name 🍻
