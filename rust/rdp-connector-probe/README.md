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

To run the lab-only TLS upgrade smoke probe against a target that uses a
self-signed or otherwise untrusted RDP certificate:

```bash
SERVICERADAR_RDP_LIVE_TARGET=192.168.1.45 \
  SERVICERADAR_RDP_LIVE_TLS_INSECURE_ACCEPT_INVALID_CERTS=1 \
  cargo test --manifest-path rust/rdp-connector-probe/Cargo.toml --locked \
  live_tls_upgrade_reaches_credssp_boundary_when_lab_insecure_is_enabled -- --nocapture
```

This second probe intentionally accepts invalid certificates and is only for
controlled lab validation. It proves the TCP stream can be upgraded to TLS, a
peer certificate public key can be extracted for CredSSP binding, IronRDP moves
to the CredSSP state, and the recorded bytes do not contain the test password.
It does not prove production certificate verification, CredSSP completion, user
authentication, media, cleanup ordering, or helper readiness.

To run the live TLS upgrade probe with normal certificate verification, provide a
PEM or DER CA bundle for the target certificate:

```bash
SERVICERADAR_RDP_LIVE_TARGET=192.168.1.45 \
  SERVICERADAR_RDP_LIVE_SERVER_NAME=win-admin-01.example.com \
  SERVICERADAR_RDP_LIVE_CA_BUNDLE_FILE=/path/to/rdp-ca.pem \
  cargo test --manifest-path rust/rdp-connector-probe/Cargo.toml --locked \
  live_verified_tls_upgrade_reaches_credssp_boundary_when_configured -- --nocapture
```

This verified probe skips unless both `SERVICERADAR_RDP_LIVE_TARGET` and
`SERVICERADAR_RDP_LIVE_CA_BUNDLE_FILE` are set. It proves the live target can
complete the RDP TLS upgrade using configured trust and server identity, then
reach the CredSSP state without recorded cleartext password exposure. It still
does not complete CredSSP authentication, active desktop media, cleanup ordering,
or helper readiness.
