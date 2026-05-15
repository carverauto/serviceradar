# ServiceRadar RDP Connector Probe

This is a review-only Rust sub-workspace for the IronRDP connector dependency graph.

It intentionally has its own `Cargo.lock` and is not a member of the repository root
workspace. Keep connector, CredSSP, SSPI, and PKI dependencies here until the optional
RDP helper is ready to own a separate production dependency graph.

Run:

```bash
cargo test --manifest-path rust/rdp-connector-probe/Cargo.toml --locked
```
