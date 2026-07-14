# Prime number tools for `crypto-bigint`

[![crate][crate-image]][crate-link]
[![Docs][docs-image]][docs-link]
![License][license-image]
[![Build Status][build-image]][build-link]
[![Coverage][coverage-image]][coverage-link]

This library implements prime number generation and primality checking for [`crypto-bigint`](https://crates.io/crates/crypto-bigint) integers.

At a high level, provides two primality tests that can be used by themselves or to generate random primes:
- The BPSW'21 test which improves on the commonly used BPSW'80, based on Baillie et al "Strengthening the Baillie-PSW primality test", Math. Comp. 90 1931-1955 (2021), DOI: [10.1090/mcom/3616](https://doi.org/10.1090/mcom/3616);
- The test prescribed by the [FIPS-186.5 standard](https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.186-5.pdf>), along with a function to calculate the required number of Miller-Rabin test iterations depending on the prime size and the bound on the probability of a false positive.

The generated primes can have additional constraints imposed on them, like having certain bits set, or requiring the primes to be safe.

Advanced users can use the primality test components from the [`hazmat`][hazmat-lnk] module to build a custom prime finding solution that best fit their needs:
- Sieving iterator;
- Miller-Rabin test;
- Lucas test with a choice of base and a specific variation.

The library is no-std compatible and contains no unsafe code.


## Example

Find a 196 bit prime returned in a 256-bit long `crypto_bigint::U256`:

```rust
use crypto_bigint::U256;
use rand_core::{OsRng, TryRngCore};
use crypto_primes::{Flavor, is_prime, random_prime};

let prime = random_prime::<U256, _>(&mut OsRng.unwrap_mut(), Flavor::Any, 196);
assert!(is_prime(Flavor::Any, &prime));
```

Find a 64 bit safe prime returned in a `crypto_bigint::U1024`:

```rust
use crypto_bigint::U1024;
use rand_core::{OsRng, TryRngCore};
use crypto_primes::{Flavor, is_prime, random_prime};

let prime = random_prime::<U1024, _>(&mut OsRng.unwrap_mut(), Flavor::Safe, 64);
assert!(is_prime(Flavor::Safe, &prime));
```

`random_prime()` returns primes with MSB set.
If a different behavior is desired, it can be done by manually creating a sieve:

```rust
use crypto_primes::{
    Flavor,
    hazmat::{SetBits, SmallFactorsSieveFactory},
    is_prime, random_prime, sieve_and_find,
};
use crypto_bigint::U256;
use rand_core::{OsRng, TryRngCore};

let flavor = Flavor::Any;
let factory = SmallFactorsSieveFactory::<U256>::new(flavor, 256, SetBits::TwoMsb).unwrap();
let prime = sieve_and_find(
    &mut OsRng.unwrap_mut(),
    factory,
    |_rng, candidate| is_prime(flavor, candidate)
).unwrap().unwrap();
assert!(is_prime(flavor, &prime));
```


## Features

The following features are available:

- `multicore`: Enables additional parallel prime finding functions. Disabled by default.


[crate-image]: https://img.shields.io/crates/v/crypto-primes.svg
[crate-link]: https://crates.io/crates/crypto-primes
[docs-image]: https://docs.rs/crypto-primes/badge.svg
[docs-link]: https://docs.rs/crypto-primes/
[license-image]: https://img.shields.io/crates/l/crypto-primes
[build-image]: https://github.com/entropyxyz/crypto-primes/actions/workflows/ci.yml/badge.svg
[build-link]: https://github.com/entropyxyz/crypto-primes/actions/workflows/ci.yml
[coverage-image]: https://codecov.io/gh/entropyxyz/crypto-primes/branch/master/graph/badge.svg
[coverage-link]: https://codecov.io/gh/entropyxyz/crypto-primes
[hazmat-lnk]: https://docs.rs/crypto-primes/latest/crypto_primes/hazmat
