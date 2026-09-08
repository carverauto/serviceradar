# Change: Rust native add-on SDK & reference

## Why
The framework (`add-agent-feature-sets`) is polyglot by design — the agent's
`go-plugin` client speaks gRPC over a Unix-domain socket with AutoMTLS, which any
language can implement — and the Go SDK (`go/pkg/addon`) plus a Go reference add-on
already exist. The planned host-network-visibility capability (`netprobe`) is Rust, and
future Rust add-ons need the same rails. To unblock Rust add-ons we need a Rust
handshake/gRPC helper (or a precise documented contract) and a Rust reference add-on
proving end-to-end interop with the agent's go-plugin client.

## What Changes
- Provide a **Rust handshake + gRPC-contract helper** (a crate, or a documented
  contract with generated stubs) that implements the go-plugin handshake (magic
  cookie, app protocol version), serves the add-on gRPC service over the UDS, and
  participates in AutoMTLS so the agent's go-plugin client accepts it.
- Add a **Rust reference add-on** that builds against the helper and is supervised by
  the agent as an `agent-sidecar`, proving the Go↔Rust contract end to end.
- Author a `rust-sample` `addon.yaml` (`pushed-artifact` / `agent-sidecar`,
  `language: rust`) as the reference consumer and confirm the contract expresses it
  without gaps. (The real passive-fingerprinting capability is `netprobe`, migrated
  onto the framework separately by `migrate-netprobe-to-native-addon`.)

## Impact
- **Depends on:** `add-agent-feature-sets` (the gRPC contract in `proto/agent/addon/v1`
  and the agent go-plugin client).
- **Affected specs:** ADDED requirement to `agent-feature-sets` (Rust SDK and interop).
- **Affected code:** a Rust crate under `rust/` implementing the handshake/contract;
  generated gRPC stubs from `proto/agent/addon/v1/`; a Rust reference add-on; an
  `addons/rust-sample-addon/` manifest package.
- **Validates:** the framework's polyglot claim and the `agent-sidecar` supervision
  model against a non-Go implementation.
