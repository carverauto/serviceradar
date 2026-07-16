# utf8-zero

Zero-copy, incremental UTF-8 decoding with error handling.

Unlike `std::str::from_utf8()`, which requires the entire input up front, this crate is designed
for streaming: bytes can arrive in arbitrary chunks (from a network socket, file reader, etc.)
and the decoder correctly handles multi-byte code points split across chunk boundaries.

The crate provides three levels of API:

* **`utf8::decode()`** — low-level, single-shot decode of a byte slice. Returns the valid
  prefix and either an invalid sequence or an incomplete suffix that can be completed with
  more input.
* **`LossyDecoder`** — a push-based streaming decoder. Feed it chunks of bytes and it calls
  back with `&str` slices, replacing errors with U+FFFD.
* **`BufReadDecoder`** — a pull-based streaming decoder wrapping any `BufRead`, with both
  strict and lossy modes.

### Example

```rust
use utf8::{decode, DecodeError};

let bytes = b"Hello\xC0World";
match decode(bytes) {
    Ok(s) => println!("valid: {s}"),
    Err(DecodeError::Invalid { valid_prefix, invalid_sequence, remaining_input }) => {
        // valid_prefix = "Hello", invalid_sequence = [0xC0], remaining_input = b"World"
        println!("got {:?} before error", valid_prefix);
    }
    Err(DecodeError::Incomplete { valid_prefix, incomplete_suffix }) => {
        // Input ended mid-codepoint — feed more bytes via incomplete_suffix.try_complete()
        println!("need more input after {:?}", valid_prefix);
    }
}
```

## History

* Originally written by [Simon Sapin](https://github.com/SimonSapin) as
  [SimonSapin/rust-utf8](https://github.com/SimonSapin/rust-utf8), published
  as the [`utf-8`](https://crates.io/crates/utf-8) crate.
* The upstream repo was [archived](https://github.com/SimonSapin/rust-utf8/commit/218fea2b57b0e4c3de9fa17a376fcc4a4c0d08f3)
  and is no longer maintained.
* Used by [ureq](https://github.com/algesten/ureq) among others.
  Simon Sapin [suggested](https://github.com/servo/servo/issues/42853#issuecomment-3971787017)
  inlining the code into crates that need it rather than republishing.
* Forked here as a standalone repo (not a GitHub fork) to allow continued maintenance.
* Added fuzz testing.
* Modernized code: set Rust edition to 2021, ran `cargo fmt`, fixed lifetime syntax and clippy warnings.
* Added GitHub Actions CI (lint, clippy, tests, Miri on every push/PR; nightly fuzzing).
* Removed defunct bench setup (missing shared modules from upstream).
* Added `#![deny(missing_docs)]` and documented all public items.
* Added `no_std` support for all but `BufReadDecoder`.

## Fuzzing

Fuzz tests use [`cargo-fuzz`](https://github.com/rust-fuzz/cargo-fuzz) (libFuzzer). Three targets cover the main API surface:

* **`fuzz_decode`** — `utf8::decode()`, validated against `std::str::from_utf8()`
* **`fuzz_lossy_decoder`** — `LossyDecoder` with random chunk splits, validated against `String::from_utf8_lossy()`
* **`fuzz_bufread_decoder`** — `BufReadDecoder::read_to_string_lossy()`, validated against `String::from_utf8_lossy()`

To run locally:

```sh
cargo install cargo-fuzz
cargo +nightly fuzz run fuzz_decode
cargo +nightly fuzz run fuzz_lossy_decoder
cargo +nightly fuzz run fuzz_bufread_decoder
```

A GitHub Actions workflow runs all targets nightly.

## Miri

[Miri](https://github.com/rust-lang/miri) runs on every push/PR to validate the `unsafe` code
(three `str::from_utf8_unchecked()` calls). The test suite uses exhaustive input partitioning,
which is exponential, so inputs longer than 10 bytes are skipped under Miri to keep CI fast.

```sh
cargo +nightly miri test
```

## License

MIT OR Apache-2.0
