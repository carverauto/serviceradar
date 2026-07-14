# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).


## [[0.2.5](https://github.com/Devolutions/sspi-rs/compare/winscard-v0.2.4...winscard-v0.2.5)] - 2025-12-11

### <!-- 4 -->Bug Fixes

- Use `String::from_utf16_lossy` over `String::from_utf16` to avoid changing the meaning of some buffers in case of invalid UTF-16 input ([#568](https://github.com/Devolutions/sspi-rs/issues/568)) ([a4889f5b1e](https://github.com/Devolutions/sspi-rs/commit/a4889f5b1e802395b09954f5846d1a6433546281)) 

## [[0.2.4](https://github.com/Devolutions/sspi-rs/compare/winscard-v0.2.3...winscard-v0.2.4)] - 2025-11-18

### <!-- 7 -->Build

- No zlib for flate2 on WASM ([#547](https://github.com/Devolutions/sspi-rs/issues/547)) ([9867f451f0](https://github.com/Devolutions/sspi-rs/commit/9867f451f0ab75204f900977c85ff387c31d1423)) 

  This PR switches flate2 to the default `miniz_oxide` (Rust-only
  implementation) for WASM and keeps using system `zlib` otherwise.
  
  The zlib backends are described
  [here](https://github.com/rust-lang/flate2-rs?tab=readme-ov-file#backends).

## [[0.2.3](https://github.com/Devolutions/sspi-rs/compare/winscard-v0.2.2...winscard-v0.2.3)] - 2025-10-06

### <!-- 1 -->Features

- System-provided smart card credentials (#483) ([786aae5ea1](https://github.com/Devolutions/sspi-rs/commit/786aae5ea14b76a4bcf262ed10a0ec9ca153ae1f)) 

- Data sigining using scard (#491) ([6728fb525c](https://github.com/Devolutions/sspi-rs/commit/6728fb525cedc96b395eed5dc4a8ea357b036b36)) 

- Automatic winscard cache initialization ([b799edf978](https://github.com/Devolutions/sspi-rs/commit/b799edf978834c2197d475d5c21d92d293180a17)) 

### <!-- 4 -->Bug Fixes

- General authenticate command validation (#509) ([748fa67c63](https://github.com/Devolutions/sspi-rs/commit/748fa67c63d4d3410e533d02c87f1bc253c3f1a0)) 

### <!-- 7 -->Build

- Bump the crypto dependencies (#489) ([1ecba764ec](https://github.com/Devolutions/sspi-rs/commit/1ecba764ec3b04e147ae76d018414afa8bec5f88)) 

## [[0.2.2](https://github.com/Devolutions/sspi-rs/compare/winscard-v0.2.1...winscard-v0.2.2)] - 2025-08-26

### <!-- 4 -->Bug Fixes

- Incorrect `SCARD_IO_REQUEST` usage (#487) ([7e23472a7a](https://github.com/Devolutions/sspi-rs/commit/7e23472a7af347460a89379f28dc56701f7be97e)) 

  Fixes incorrect [`SCARD_IO_REQUEST`](https://learn.microsoft.com/en-us/windows/win32/secauthn/scard-io-request) usage.
