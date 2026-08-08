# MuonFP Fingerprint Source Audit

ServiceRadar pins MuonFP as a license-clean TCP SYN fingerprint format
reference, not as an embedded signature database.

## Upstream

- Source URL: https://github.com/sundruid/muonfp
- Pinned commit: `fa507cc944ebbf63d6748cbdeda9f4c4b0680791`
- Commit date: 2025-09-24T10:28:34-07:00
- Commit subject: `Rename MuonFP Fingerprint Specification to MuonFP Fingerprint Specification.md`

## Vendored Files

- `SPEC.md`
  - Upstream path: `MuonFP Fingerprint Specification.md`
  - License stated in file: CC BY 4.0
  - sha256: `955be749c4010bdc8bf52a3b4e3e95d062225c6d20fa222de2fe5b509f47363c`
- `reference-fingerprint.rs`
  - Upstream path: `src/fingerprint.rs`
  - License from repository `LICENSE`: MIT
  - sha256: `abac046b2b5bacfe9de712e5979250c2a5bd6f1d33d177694a20111b709fad5d`
- `LICENSE-MIT.txt`
  - Upstream path: `LICENSE`
  - sha256: `0ad82385a6c4f6e62cdbafe87e66bb38c61ea71f6fef72b90d55ee55e9c29fb4`

## Audit Notes

The pinned upstream tree does not contain a standalone MuonFP signature
corpus. It contains the format specification, reference encoder, runtime
capture tool, and package/install files. ServiceRadar therefore vendors the
format specification and reference encoder only. The in-tree matcher work must
not assume a bundled MuonFP label database exists unless a future upstream
release adds one and this audit is updated.

The upstream repository has a license inconsistency: `LICENSE` is MIT, while
`README.md` says the tool is "under the GPL license." No `COPYING`, GPL text,
or source-file GPL headers are present at the pinned commit. ServiceRadar does
not vendor the runtime tool or depend on its crate; it vendors only the format
specification and reference encoder for auditability. Treat future upstream
license changes as blocking until reviewed.

Dependency and text audit at the pinned commit found no references to FoxIO,
JA4+, `huginn-net`, or FoxIO-1.1 licensed methods.
