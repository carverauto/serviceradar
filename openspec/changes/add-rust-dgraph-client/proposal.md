# Change: Add a first-party Rust Dgraph client

## Why

ServiceRadar needs to talk to Dgraph from Rust. The reference implementation is the
official Go client `dgraph-io/dgo` (vendored for study at `ctx/dgo`, pinned at
`v250.0.0-3-g7bb5398`, the last commit on `main`). There is no maintained Rust client
that tracks the v250 protocol surface, and the protobuf bindings already build in this
repo as `//proto/dgraph:proto_dgraph_bindings`, so the remaining work is the client
semantics on top of them.

This is a **clean-room port, not a transliteration**. `dgo` carries defects and dated
design that must not be reproduced: `Close()` is a no-op that leaks every connection,
IPv6 endpoints are rejected outright, `Txn.BestEffort()` panics on caller input, its
"round robin" client selection is actually `rand.Intn`, and JWT-expiry detection is a
case-sensitive substring match on a server message. The Rust client reproduces the
protocol and the transaction semantics, and fixes the rest.

## What Changes

- Add the `dgraph-client` crate at `rust/dgraph-client` (crate `dgraph_client`), built
  by both Cargo and Bazel, depending on `//proto/dgraph:proto_dgraph_bindings`.
- Implement client construction, including full `dgraph://` connection-string support
  with correct IPv6 authority parsing and per-failure typed errors.
- Implement ACL login, namespace login, and single-flight JWT refresh.
- Implement the transaction lifecycle with compile-time separation of read-only and
  read-write transactions, so `BestEffort` and `Mutate` misuse cannot be expressed.
- Implement queries (DQL and RDF), variables, mutations, upserts, commit and discard,
  and transaction-context merging.
- Implement schema operations, namespace operations, and UID/timestamp/namespace lease
  allocation.
- Define a typed, programmatically matchable error taxonomy with **no** `Box<dyn Error>`
  in any public signature (the repo mandates static dispatch).
- **BREAKING for nothing** - this is a net-new crate with no existing consumers.

Deliberately **not** ported (no capability is lost; see `design.md`):
`NewDgraphClient`, `DialCloud`, `GetJwt`, `GetAPIClients`, and Go's no-op `Close`.

## Impact

- Affected specs: `dgraph-client` (new capability).
- Affected code:
  - `rust/dgraph-client/**` (new source, tests, `BUILD.bazel`, `tests/BUILD.bazel`)
  - `Cargo.toml` (workspace member already present; crate gains dependencies)
  - `Cargo.lock` and `third_party/crates/**` (re-vendor required - see tasks)
  - `rust/README_RUST.md` (crate-structure convention, added by this change)
- No runtime service consumes the crate yet; wiring Dgraph into a service is a separate
  change.
