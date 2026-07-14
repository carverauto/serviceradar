# NUID

[![License Apache 2](https://img.shields.io/badge/License-Apache2-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)

A highly performant unique identifier generator.

## Installation

In Cargo.toml:

```toml
[dependencies]
nuid = "0.5"
```

## Basic Usage

```rust
// Utilize the global locked instance
nuid := nuid::next();

// Create an instance, these are not locked.
n := nuid::NUID::new();
nuid = n.next();

// Generate a new crypto/rand seeded prefix.
// Generally not needed, happens automatically.
n.randomize_prefix();
```

## Performance

NUID needs to be very fast to generate and be truly unique, all while being entropy pool friendly.
NUID uses 12 bytes of crypto generated data (entropy draining), and 10 bytes of pseudo-random
sequential data that increments with a pseudo-random increment.

Total length of a NUID string is 22 bytes of base 62 ascii text, so 62^22 or
2707803647802660400290261537185326956544 possibilities.

NUID can generate identifiers as fast as 60ns, or ~16 million per second. There is an associated
benchmark you can use to test performance on your own hardware.

## License

Unless otherwise noted, the NATS source files are distributed
under the Apache Version 2.0 license found in the LICENSE file.
