# Security Policy

## Supported Versions

| Version | Supported          |
|---------|--------------------|
| 0.1.x   | :white_check_mark: |

## Reporting a Vulnerability

If you discover a security vulnerability in `flowparser-sflow`, please report it responsibly.

**Do not open a public GitHub issue for security vulnerabilities.**

Instead, please email: **michael.mileusnich@gmail.com**

Include:
- A description of the vulnerability
- Steps to reproduce or a proof of concept
- The potential impact

You can expect an initial response within 72 hours. We will work with you to understand the issue and coordinate a fix before any public disclosure.

## Scope

This library parses untrusted network input (sFlow datagrams). The following are considered in scope:

- Buffer overflows or out-of-bounds reads
- Panics on malformed input (the parser should return errors, not panic)
- Excessive memory allocation from crafted input (denial of service)
- Any input that causes undefined behavior

## Hardening

The parser includes the following protections:

- **Max samples limit**: Configurable via `SflowParser::builder().with_max_samples(n)` to reject datagrams exceeding the limit before parsing any samples
- **Capped allocations**: All `Vec::with_capacity` calls are capped against available input length to prevent memory exhaustion from crafted count fields
- **Length-checked reads**: All field reads are bounds-checked before access
- **No unsafe code**: The library uses `#![forbid(unsafe_code)]` to guarantee no unsafe blocks at compile time
- **Fuzz testing**: The parser is fuzz-tested with `cargo-fuzz` against arbitrary byte inputs
