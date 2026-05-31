# Tasks: Rust native add-on SDK & reference

> Implements the Rust half of the native add-on SDK from `add-agent-feature-sets`.
> Task numbers in parentheses map back to that change.

## 1. Rust contract helper
- [x] 1.1 Generate Rust gRPC stubs from `proto/agent/addon/v1/` (tonic or equivalent).
- [x] 1.2 Implement the go-plugin handshake (magic cookie, app protocol version) and
  UDS gRPC serving with AutoMTLS in a reusable Rust crate (or document the exact
  contract if a crate is deferred). (3425 §6b.2)

## 2. Rust reference add-on
- [x] 2.1 Build a Rust reference add-on against the helper that the agent supervises as
  an `agent-sidecar`, proving Go↔Rust interop end to end. (§6b.3)
- [x] 2.2 Add it to `build/native_addons/addon_inventory.bzl` so it builds/bundles/signs
  like a first-party add-on.

## 3. Reference consumer manifest
- [x] 3.1 Author `addons/rust-sample-addon/addon.yaml` (`pushed-artifact` / `agent-sidecar`,
  `language: rust`) and confirm the contract expresses it without gaps. (§9.1)

## 4. Validation
- [x] 4.1 `openspec validate add-native-addon-rust-sdk --strict` passes.
- [x] 4.2 An integration test launches the Rust reference add-on via the agent's
  go-plugin client and exercises Info/Configure/Health.
