# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).


## [0.7.0-pre.3] - 2025-09-13

### Fixed

- Fixed docs.rs build.


## [0.7.0-pre.2] - 2025-09-12

### Changed

- Bumped `crypto-bigint` dependency to 0.7.0-pre.5. ([#91])
- The crate's methods are now bound on `crypto_bigint::Unsigned` instead of `Integer` ([#91])


[#91]: https://github.com/entropyxyz/crypto-primes/pull/91


## [0.7.0-pre.1] - 2025-05-30

### Changed

- Replaced the default GMP-style primality check with the BPSW'21 check. ([#70])
- Removed `is_prime_with_rng()` and `is_safe_prime_with_rng()` since the primality check is now deterministic. ([#70])
- `SieveIterator` removed from the public API. ([#79])
- Removed `RandomPrimeWithRng` trait. ([#79])
- Removed `default-rng` features and corresponding API items. ([#79])
- Renamed `generate_(safe_)prime_with_rng()` to `random_(safe_)prime()`, `fips_is_(safe_)prime_with_rng()` to `fips_is_(safe_)prime()`. ([#79])
- Moved multicore functions to `multicore` module and removed `par_` prefixes. ([#79])
- Introduced `Flavor` enum and removed `_safe` suffixes from functions. ([#79])
- `SieveFactory` trait moved to `hazmat` module. ([#79])
- The base chosen by `MillerRabin::test_random_base()` can now be equal to 2. ([#79])
- Introudced `Error` enum; `hazmat` functions and method now return it instead of panicking. ([#79])
- Renamed `SmallPrimesSieveFactory` to `SmallFactorsSieveFactory`. ([#79])
- Moved `fips_is_prime()` to its own `fips` submodule and renamed to `is_prime`. ([#79])
- Bumped `crypto-bigint` to 0.7.0-pre.1 and MSRV to 1.85. ([#80])
- Bumped `crypto-bigint` to 0.7.0-pre.2. ([#84])
- Bumped `crypto-bigint` to 0.7.0-pre.4. ([#85])
- Bumped Rust edition to 2024. ([#84])


### Added

- `LucasCheck::Regular` (the recommended one from the FIPS-186.5 standard). ([#72])
- `hamzat::minimum_mr_iterations()` (to calculate the number of MR checks according to the FIPS-186.5 standard). ([#72])
- Add `fips_is_prime_with_rng()` and `fips_is_safe_prime_with_rng()`. ([#72])
- Add `estimate_primecount()` – estimate the number of prime numbers smaller than `x`. ([#81])


[#70]: https://github.com/entropyxyz/crypto-primes/pull/70
[#72]: https://github.com/entropyxyz/crypto-primes/pull/72
[#79]: https://github.com/entropyxyz/crypto-primes/pull/79
[#80]: https://github.com/entropyxyz/crypto-primes/pull/80
[#81]: https://github.com/entropyxyz/crypto-primes/pull/81
[#84]: https://github.com/entropyxyz/crypto-primes/pull/84
[#85]: https://github.com/entropyxyz/crypto-primes/pull/85


## [0.7.0-pre.0] - 2025-02-22

### Changed

- Bumped `rand-core` to 0.9. ([#74])


[#74]: https://github.com/entropyxyz/crypto-primes/pull/74


## [0.6.2] - 2025-03-07

### Fixed

- `crypto-bigint` dependency bumped to 0.6.1.


## [0.6.1] - 2025-02-17

### Added

- Relaxed `CryptoRngCore` bounds to allow `?Sized`. ([#76])


[#76]: https://github.com/entropyxyz/crypto-primes/pull/76


## [0.6.0] - 2025-01-29

### Changed

- Renamed `Sieve` to `SmallPrimesSieve`. ([#64])
- Bumped `crypto-bigint` to 0.6.0-rc.7 and MSRV to 1.83. ([#67])
- Bumped `crypto-bigint` to 0.6. ([#68])
- `random_odd_integer()` takes an additional `SetBits` argument. ([#69])
- `random_odd_integer()` now returns a `Result` instead of panicking. ([#69])


### Added

- Parallel prime finding methods and a "multicore" feature ([#60])
- Generalized sieving: `SieveFactory` trait, `SieveIterator`, and the convenience functions `sieve_and_find()` and `par_sieve_and_find()`. ([#64])


[#60]: https://github.com/entropyxyz/crypto-primes/pull/60
[#64]: https://github.com/entropyxyz/crypto-primes/pull/64
[#67]: https://github.com/entropyxyz/crypto-primes/pull/67
[#68]: https://github.com/entropyxyz/crypto-primes/pull/68
[#69]: https://github.com/entropyxyz/crypto-primes/pull/69


## [0.6.0-pre.2] - 2024-10-18

### Changed

- Bumped `crypto-bigint` to 0.6.0-rc.6 and MSRV to 1.81. ([#55])
- Switch to binary GCD for improved performance ([#54])
- Remove bit precision from the public API ([#46])


[#55]: https://github.com/entropyxyz/crypto-primes/pull/55
[#54]: https://github.com/entropyxyz/crypto-primes/pull/54
[#46]: https://github.com/entropyxyz/crypto-primes/pull/46


## [0.6.0-pre.1] - 2024-10-03

### Changed

- Bumped `crypto-bigint` to 0.6.0-rc.2 (and pinned, since there is a bug introduced in rc.3).
  ([#48])


[#48]: https://github.com/entropyxyz/crypto-primes/pull/48


## [0.6.0-pre.0] - 2023-12-29

### Changed

- Bumped `crypto-bigint` to 0.6.0-pre.7. ([#40])
- Bumped MSRV to 1.73. ([#36])
- `MillerRabin::new()` takes an `Odd`-wrapped integer by value. `random_odd_uint()` returns an `Odd`-wrapped integer. `LucasBase::generate()` takes an `Odd`-wrapped integer. `lucas_test` takes an `Odd`-wrapped integer. ([#36])
- `random_odd_uint()` is renamed to `random_odd_integer()`, takes a `NonZeroU32` for `bit_length`. ([#38])
- All bit length-type parameters take `u32` instead of `usize`. ([#36])
- All the API is based on the `Integer` trait instead of `Uint` specifically. ([#38])
- High-level generation/checking functions take an additional `bits_precision` argument. ([#40])


[#36]: https://github.com/entropyxyz/crypto-primes/pull/36
[#38]: https://github.com/entropyxyz/crypto-primes/pull/38
[#40]: https://github.com/entropyxyz/crypto-primes/pull/40


## [0.5.0] - 2023-08-20

### Changed

- Set and explicit MSRV 1.65 in `Cargo.toml`. ([#31])
- Set lower bound `openssl = 0.10.39`. ([#31])
- Set lower bound `rand_core = 0.6.4`. ([#31])


[#31]: https://github.com/entropyxyz/crypto-primes/pull/31


## [0.4.1] - 2023-07-11

### Fixed

- `subtle` version requirement relaxed to the (implicit) 2.4, instead of technically requiring 2.5 to compile. ([#30])


[#30]: https://github.com/entropyxyz/crypto-primes/pull/30


## [0.4.0] - 2023-06-28

### Changed

- The crate is relicensed as Apache-2.0 or MIT, instead of AGPL-v3. ([#29])
- `getrandom` is not an explicit dependency anymore. This may break builds with the `wasm32-unknown-unknown` target which relied on `crypto-primes` enabling the `getrandom/js` feature. These builds are advised to do it themselves. ([#28])


### Fixed

- `Sieve::new()` now panics when `max_bit_length == 0` (which would lead to incorrect results anyway, so it is not considered a breaking change). ([#26])
- Default preset now uses A* instead of A base selection method for the Lucas test. This does not change the outcomes, but is implemented as a security recommendation. ([#26])


[#26]: https://github.com/entropyxyz/crypto-primes/pull/26
[#28]: https://github.com/entropyxyz/crypto-primes/pull/28
[#29]: https://github.com/entropyxyz/crypto-primes/pull/29


## [0.3.0] - 2023-05-05

### Changed

- `sieve_once()` was removed ([#22]).
- `MillerRabin::new()` and `test_random_base()` will panic if the input is invalid. ([#22])
- `MillerRabin::check()` renamed to `test()`. ([#22])
- Prime-generating function take `Option<usize>` instead of `usize`, where `None` means the full size of the `Uint`. ([#19])
- Renamed `prime()` to `generate_prime()`, `safe_prime()` to `generate_safe_prime()`, `prime_with_rng()` to `generate_prime_with_rng()`, `safe_prime_with_rng()` to `generate_safe_prime_with_rng()`. ([#24])


### Added

- An alternative propagation method for Lucas sequences improving the performance of `lucas_test()`. ([#20])


### Fixed

- Some mistakes in the description of Lucas checks (the logic itself was fine). ([#20])
- Major performance increase across the board due to better sieving (especially for random safe prime finding). ([#22])
- Performance increase for the cases when the bit size of the generated prime is smaller than that of the containing `Uint`. ([#19])


[#19]: https://github.com/entropyxyz/crypto-primes/pull/19
[#20]: https://github.com/entropyxyz/crypto-primes/pull/20
[#22]: https://github.com/entropyxyz/crypto-primes/pull/22
[#24]: https://github.com/entropyxyz/crypto-primes/pull/24


## [0.2.0] - 2023-03-06

### Changed

- Bumped MSRV to 1.65 (`crypto-bigint` requirement). ([#18])
- Bumped `crypto-bigint` to 0.5 with the corresponding changes in the API. ([#13], [#18])
- `Sieve::new()` now does not panic; if the parameters imply an empty output, that's what the iterator generates. ([#14])


### Added

- `RandomPrimeWithRng` trait for use in generic code. ([#12])


### Fixed

- Added a `gcd(Q, n) == 1` check to the Lucas test. ([#11])
- Added a simple 3 mod 4 check for safe primes, speeding up their generation. ([#14])
- Fixed multiple corner cases in `Sieve` for small ranges. ([#14])


[#11]: https://github.com/entropyxyz/crypto-primes/pull/11
[#12]: https://github.com/entropyxyz/crypto-primes/pull/12
[#13]: https://github.com/entropyxyz/crypto-primes/pull/13
[#14]: https://github.com/entropyxyz/crypto-primes/pull/14
[#18]: https://github.com/entropyxyz/crypto-primes/pull/18


## [0.1.0] - 2023-01-20

Initial release.


[0.1.0]: https://github.com/entropyxyz/crypto-primes/releases/tag/v0.1.0
[0.2.0]: https://github.com/entropyxyz/crypto-primes/releases/tag/v0.2.0
[0.3.0]: https://github.com/entropyxyz/crypto-primes/releases/tag/v0.3.0
[0.4.0]: https://github.com/entropyxyz/crypto-primes/releases/tag/v0.4.0
[0.4.1]: https://github.com/entropyxyz/crypto-primes/releases/tag/v0.4.1
[0.5.0]: https://github.com/entropyxyz/crypto-primes/releases/tag/v0.5.0
[0.6.0-pre.0]: https://github.com/entropyxyz/crypto-primes/releases/tag/v0.6.0-pre.0
[0.6.0-pre.1]: https://github.com/entropyxyz/crypto-primes/releases/tag/v0.6.0-pre.1
[0.6.0-pre.2]: https://github.com/entropyxyz/crypto-primes/releases/tag/v0.6.0-pre.2
[0.6.0]: https://github.com/entropyxyz/crypto-primes/releases/tag/v0.6.0
[0.6.1]: https://github.com/entropyxyz/crypto-primes/releases/tag/v0.6.1
[0.6.2]: https://github.com/entropyxyz/crypto-primes/releases/tag/v0.6.2
[0.7.0-pre.0]: https://github.com/entropyxyz/crypto-primes/releases/tag/v0.7.0-pre.0
[0.7.0-pre.1]: https://github.com/entropyxyz/crypto-primes/releases/tag/v0.7.0-pre.1
[0.7.0-pre.2]: https://github.com/entropyxyz/crypto-primes/releases/tag/v0.7.0-pre.2
[0.7.0-pre.3]: https://github.com/entropyxyz/crypto-primes/releases/tag/v0.7.0-pre.3
