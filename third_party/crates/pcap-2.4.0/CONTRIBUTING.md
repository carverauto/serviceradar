# Contributing

## Code coverage

The current code coverage for the `main` branch is automatically published on every push to `main` on https://rust-pcap.github.io/pcap/.

### Pre-requisites

To obtain code coverage locally you will need [compatible LLVM coverage tools](https://doc.rust-lang.org/rustc/instrument-coverage.html#installing-llvm-coverage-tools) and [`grcov`](https://github.com/mozilla/grcov).

The easiest way to obtain compatible LLVM coverage tools is by adding the `llvm-tools-preview` `rustup` component (for nightly!):
```
rustup component add llvm-tools-preview
```

`grcov` can be installed through cargo:
```
cargo install grcov
```

### Obtaining code coverage

Clean any previously compiled objects and binaries.
```
rm -rf ./target/debug/{coverage,profraw}
cargo clean -p pcap
```

Compile and run the tests. We set `RUSTFLAGS="-C instrument-coverage"` to enable source-based code coverage and `LLVM_PROFILE_FILE="target/debug/coverage/profraw/pcap-%p-%m.profraw"` to make sure each test gets its own profile information.
```
env RUSTFLAGS="-C instrument-coverage" \
    LLVM_PROFILE_FILE="target/debug/profraw/pcap-%p-%m.profraw" \
    cargo test --all-features --all-targets
```

And finally, run `grcov` to obtain a report.
```
grcov target/debug/profraw \
      --binary-path ./target/debug/ \
      --output-types html \
      --source-dir . \
      --ignore-not-existing \
      --ignore "build.rs" \
      --ignore "tests/*" \
      --ignore "examples/*" \
      --excl-start "GRCOV_EXCL_START|mod tests \{" \
      --excl-stop "GRCOV_EXCL_STOP" \
      --output-path ./target/debug/coverage/
```

The code coverage report will be available in `target/debug/coverage/index.html` which you can explore in your browser.
```
xdg-open target/debug/coverage/index.html
```

### More information

For more information on LLVM code coverage in Rust: https://doc.rust-lang.org/rustc/instrument-coverage.html

For more information on `grcov`: https://github.com/mozilla/grcov
