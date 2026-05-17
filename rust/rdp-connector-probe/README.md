# ServiceRadar RDP Connector Probe

This is a review-only Rust sub-workspace for the IronRDP connector dependency graph
and ServiceRadar-to-IronRDP config mapping.

It intentionally has its own `Cargo.lock` and is not a member of the repository root
workspace. Keep connector, CredSSP, SSPI, and PKI dependencies here until the optional
RDP helper is ready to own a separate production dependency graph.

Run:

```bash
cargo test --manifest-path rust/rdp-connector-probe/Cargo.toml --locked
```

To run the opt-in live boundary probe against a private RDP target:

```bash
SERVICERADAR_RDP_LIVE_TARGET=192.168.1.45 \
  cargo test --manifest-path rust/rdp-connector-probe/Cargo.toml --locked \
  live_blocking_connect_begin_reaches_tls_upgrade_boundary_when_configured -- --nocapture
```

`SERVICERADAR_RDP_LIVE_TARGET` accepts `host` or `host:port` and defaults to port
`3389` when no port is provided. This probe only drives `ironrdp-blocking` through
the X.224/NLA negotiation boundary and verifies that no cleartext password appears
in the initial client bytes. It does not complete TLS verification, CredSSP, user
authentication, or the active desktop stage.
