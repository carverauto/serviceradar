## Context
The agent supervises `agent-sidecar` add-ons with HashiCorp `go-plugin`, which is a
Go library on the host side but defines a wire protocol (a handshake line on stdout
plus gRPC over a Unix-domain socket, optionally AutoMTLS) that a plugin in any language
can satisfy. The add-on gRPC service is already defined in `proto/agent/addon/v1/`.

## Goals / Non-Goals
- Goals: let a Rust binary be launched and supervised by the existing agent go-plugin
  client with no host-side changes; prove it with a reference add-on; keep the contract
  identical to the Go path.
- Non-Goals: replacing go-plugin on the host; a general-purpose Rust framework beyond
  what an add-on needs; migrating an existing capability (the real passive-fingerprinting
  daemon is `netprobe`, migrated by `migrate-netprobe-to-native-addon`; this change ships
  only the SDK + a `rust-sample` reference).

## Decisions
- Decision: implement the go-plugin handshake + AutoMTLS in Rust against the existing
  proto, rather than changing the host transport. The host already speaks standard
  go-plugin; the contract is the proto + the handshake, both language-neutral.
  - Alternatives considered: (a) a bespoke Rust↔agent protocol — rejected, it forks the
    contract and the agent's client; (b) running Rust add-ons only via `systemd-*`
    delivery to avoid go-plugin — rejected, it denies Rust the supervised in-process
    health/restart story Go add-ons get.
- Decision: prefer shipping a thin reusable crate; if AutoMTLS in Rust proves
  disproportionate, fall back to a documented contract + generated stubs and a worked
  reference, and note the gap.

## Risks / Trade-offs
- AutoMTLS handshake details (cert exchange via env) must match go-plugin exactly →
  mitigate by testing against the real agent client, not a mock.
- go-plugin protocol drift on upgrade → pin the app protocol version in the manifest
  (`plugin.app_protocol_version`) and assert it in the handshake.

## Open Questions
- Crate vs. documented-contract-only for v1 (decided at implementation time based on the
  AutoMTLS effort).
