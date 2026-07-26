# Design: Rust Dgraph client

## Context

Reference implementation: `ctx/dgo` (`dgraph-io/dgo` v250.0.0-3-g7bb5398), 7 non-test Go
files, ~1058 lines. Protobuf bindings already build as
`//proto/dgraph:proto_dgraph_bindings` (crate `proto_dgraph`, module `proto_dgraph::api`).
Destination crate `rust/dgraph-client` exists and is a workspace member.

Constraints that shape every decision below:

- 100% safe Rust, no `unsafe`.
- Static dispatch only. No `dyn`, no trait objects; therefore **no `Box<dyn Error>` in a
  public signature**.
- Minimal dependencies. All versions come from `[workspace.dependencies]`.
- The crate-structure convention in `rust/README_RUST.md` section 6 (one type per module,
  `tests/` mirrors `src/`, shared helpers in `src/utils_tests/`, no prelude).

## Goals / Non-Goals

**Goals.** Protocol and transaction-semantics parity with dgo v250; a client that cannot
panic on caller input; typed errors; correct IPv6; credential redaction.

**Non-Goals.** Byte-identical error strings; Go's deprecated surface; a connection pool
or load-balancer beyond what tonic provides; retry policy beyond dgo's single-shot JWT
refresh (adding backoff would change semantics and add a dependency).

## Decisions

### D1. Dependencies: zero new crates

`tonic`, `tonic-prost`, `prost`, `tokio`, `thiserror`, `tracing`, and `urlencoding` are
all already in `[workspace.dependencies]`. Notably **`url` is not**, and adding it would
force a re-vendor for one struct. The connection-string parser is therefore hand-written
over `std` plus `urlencoding` for percent-decoding, which is also what lets us fix the
IPv6 defect rather than inherit a parser's opinion.

`proto_dgraph` is an in-repo path dependency, not a crates.io crate. **This crate is the
first in the repo to depend on a proto binding**, so there is no precedent to copy - the
wiring is specified explicitly in `tasks.md` and must be verified under Bazel, not just
Cargo.

### D2. Error model: public newtype struct wrapping a classification enum

Static dispatch bars `Box<dyn Error>`. Each error is a **public tuple struct wrapping a
classification enum**, which is the repo's established pattern for non-API-breaking
forward evolution: new failure modes are added as enum variants without changing the
public type, and the wrapper leaves room to change the internal representation later
(adding context, a source chain, or a backtrace) without a semver break.

```rust
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ConnectionStringError(ConnectionStringErrorEnum);   // field private

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum ConnectionStringErrorEnum {
    InvalidScheme(String),
    MissingPort,
    ConflictingAuth,
    UnknownSslMode(String),
    IncompleteCredentials,
    InvalidNamespace(String),
    // ...
}

impl ConnectionStringError {
    pub(crate) fn new(variant: ConnectionStringErrorEnum) -> Self { Self(variant) }

    /// Classification, for callers that need to branch on the failure.
    pub fn kind(&self) -> &ConnectionStringErrorEnum { &self.0 }

    #[allow(non_snake_case)]
    pub fn MissingPort() -> Self { Self(ConnectionStringErrorEnum::MissingPort) }
    // ... one associated constructor per variant
}
```

`Display` is implemented by hand, matching on the inner enum, as is
`std::error::Error`. The five error types, one module each under `src/errors/`:

- `ConnectionStringError` - one variant per validation failure in the `dgraph://` parser.
- `ConnectError` - transport/TLS/readiness failures during construction.
- `AuthError` - login, refresh, and JWT-decode failures.
- `TransactionError` - `Finished`, `ReadOnly`, `Aborted`, `StartTsMismatch`.
- `DgraphError` - the top-level type the public API returns, aggregating the above.

Three consequences, recorded because they are not obvious:

**The inner field is private, and the enum is `#[non_exhaustive]`.** A `pub` inner field
would let callers `match err.0 { .. }` exhaustively, which is exactly the API break the
pattern exists to prevent; it would also violate the repo's "public types keep all fields
private" rule. Callers branch through `kind()` instead.

**`thiserror` is not used and is not a dependency.** The pattern implements `Display` by
hand, so the derive macro buys nothing. One fewer proc-macro dependency.

**Errors store `tonic::Code` + message, not `tonic::Status`.** `Status` is
`#[derive(Clone)]` only - it has no `PartialEq`, `Eq`, or `Hash` - so holding one would
block the derives above. `Code` derives all three. Storing the code and message also keeps
tonic types out of the public API, which is the same shielding rule as D7.

Two dgo behaviors are deliberately improved:

- `Aborted` retains the server's status code and message. dgo overwrites the whole status
  with a fixed sentinel (`txn.go:209-211`), making the abort reason unrecoverable.
- When a relogin fails mid-retry, dgo discards the original error and surfaces only the
  login error - frequently the useless `"refresh jwt should not be empty"`. Our
  `AuthError` retains **both** the login failure and the originating failure.

Callers match on `kind()`. No caller is ever expected to string-match, which is the single
biggest improvement over dgo, where `"Token is expired"` and `"Please retry"` are both
load-bearing substrings.

### D3. Transaction state: typestate for the ergonomic path, runtime check for the escape hatch

dgo encodes transaction legality in four `bool` fields and enforces it at runtime, with
one path (`BestEffort`) enforced by `panic!`. We split the type:

```
Txn<ReadWrite>  -- query, mutate, commit, discard
Txn<ReadOnly>   -- query, best_effort, discard      (no mutate, no commit)
```

`best_effort()` exists only on `Txn<ReadOnly>`, so dgo's panic becomes a compile error.
`mutate()` and `commit()` exist only on `Txn<ReadWrite>`, so `ErrReadOnly` is
unrepresentable for the typed API.

`TransactionError::ReadOnly` is still **retained** because the raw `do_request()` escape
hatch accepts a caller-built `Request` that may carry mutations; that path keeps dgo's
runtime check.

`commit(self)` and `discard(self)` consume the transaction, so dgo's `ErrFinished` cannot
occur on the typed path either. It is retained for one real case: dgo auto-discards a
transaction when a request carrying mutations fails (`txn.go:203-205`), which leaves the
caller holding a dead handle. We reproduce that (it is protocol-relevant, not a defect)
by marking the transaction poisoned; subsequent operations return
`TransactionError::Finished`.

Alternative rejected: pure runtime flags mirroring Go. It reproduces the panic risk and
throws away the one place where Rust's type system pays for itself.

### D4. `Drop` does not silently discard

An uncommitted transaction that made mutations holds server-side state until the alpha
times it out. Go relies on `defer txn.Discard(ctx)`. Rust cannot run async code in `Drop`,
and spawning a detached discard task would require a runtime handle and would surprise
callers.

Decision: `Drop` does **not** perform I/O. Dropping a mutated, uncommitted transaction
emits a `tracing` warning naming the leak. This is documented on the type. Rejected:
`block_on` in `Drop` (deadlocks on a current-thread runtime) and a background discard task
(hidden I/O, unclear cancellation).

### D5. JWT refresh is single-flight, and the lock is `tokio::sync::RwLock`

dgo holds a write lock across the whole login RPC, which accidentally gives single-flight
de-duplication. That is worth keeping deliberately rather than by accident. `std::sync::RwLock`
cannot be held across `.await`, so this must be `tokio::sync::RwLock`.

The refresh is single-shot with **no backoff**, matching dgo: exactly one retry, no sleep,
no jitter, no cap, and `UNAVAILABLE`/`DEADLINE_EXCEEDED` are not retried. Adding
`tower::retry` or exponential backoff would change semantics and add a dependency.

### D6. Expiry detection prefers status codes, with a documented fallback

dgo detects expiry by `strings.Contains(err.Error(), "Token is expired")`. The port
matches on `Status::code()` first and falls back to `Status::message()` containment only
when the code is ambiguous, with the fallback documented as a server-message dependency.

A subtlety worth recording: in Go, `status.FromError` returns `ok == false` for non-status
errors, so `isJwtExpired` cannot fire on a local transport error. In tonic **every** RPC
error is a `Status`, so a naive translation widens the retry trigger. The port must
explicitly exclude locally-generated errors.

### D7. Generated prost types are internal; wrappers own the public surface

prost generates types with public fields, which appears to collide with the convention's
"public types keep all fields private". It does not, because the generated types are not
public types of this crate: the convention permits public fields on private types
"provided they do not leak outside their defined scope", and the wrappers are what define
that scope. Shielding generated types behind owned wrappers is standard practice for
protobuf clients.

Concretely:

- The crate owns thin wrappers (`Response`, `Mutation`, `Request`) with private fields and
  getters. These are the public API.
- `proto_dgraph` is an **internal** dependency, not a public one. Generated types do not
  appear in any public signature, so regenerating the bindings is not a breaking change
  for consumers of `dgraph_client`.
- Raw access is not offered per-type via blanket `into_inner()`. That would re-export the
  generated types through the back door and make `proto_dgraph` a de facto public
  dependency. Instead there is exactly **one** clearly-labelled seam - the raw
  `do_request()` path already described in D3 - for callers who need to drive the protocol
  directly.

Cost, stated plainly: it is more code, and each proto field a caller needs must be exposed
through a getter. Accepted, because it is what keeps the generated types from leaking and
what lets the proto bindings be regenerated without churning the public API.

### D8. `sslmode=require` is retained but signposted

dgo's `sslmode=require` means TLS **with certificate verification disabled**
(`open.go:192` -> `InsecureSkipVerify: true`). That is exactly the "fragile design"
category, but removing it would break connection strings that already exist.

Decision: keep it, name the resulting Rust variant `TlsMode::RequireNoVerify` rather than
`Require`, document the exposure on both the enum and the parser, and emit a `tracing`
warning at connect time. The wire behavior is unchanged; what changes is that nobody
selects it by accident.

## Dropped from the Go client

| Go symbol | Why dropped | Capability preserved by |
|---|---|---|
| `NewDgraphClient(clients...)` | Deprecated; takes pre-built gRPC stubs and enables the `len == 0` panic in `anyClient()` | `DgraphClient::new` / `::builder()` |
| `DialCloud(endpoint, key)` | Deprecated; bespoke Cloud URL munging | `dgraph://...?apikey=` + `TlsMode::VerifyCa` |
| `GetJwt()` | Deprecated; leaks raw credentials to callers | nothing - deliberate, exposing tokens is the defect |
| `GetAPIClients()` | Leaks generated stubs to escape the abstraction | `DgraphClient::channel()` for advanced use |
| `Close()` | No-op bug: `open.go:250` builds `conns` but constructs `&Dgraph{dc: dc}` without it, so `client.go:277` iterates nil | tonic `Channel` is `Drop`-managed; no explicit close needed |

## Defects fixed relative to Go

1. **Connection leak.** `Close()` closes nothing (above). Fixed by construction in Rust.
2. **IPv6 rejected.** `open.go:170` requires `Split(host, ":")` to yield exactly 2 parts,
   so `[::1]:9080` fails. Fixed by real authority parsing.
3. **Panic on caller input.** `BestEffort()` panics (`txn.go:79`). Fixed by typestate.
   Second panic: `anyClient()` does `rand.Intn(len)` and panics on an empty client list;
   fixed by a private constructor that rejects an empty endpoint list.
4. **"Round robin" is random.** `client.go:230` is `rand.Intn`. Fixed by implementing
   real round-robin over a shared atomic cursor, named honestly.
5. **String-matched expiry.** See D6.
6. **`resp.Json` is not JSON.** `client.go:132` runs `proto.Unmarshal` on a field named
   `Json`. Wire behavior kept; the Rust code names it for what it is (protobuf-encoded
   `api.Jwt`) so the next reader is not misled.

## Risks / Trade-offs

- **Typestate rigidity.** A caller deciding read-only vs read-write at runtime cannot pick
  a type at compile time. Mitigation: both types expose the same query surface, and the
  raw `do_request()` path accepts either.
- **`resp` and `err` both non-nil.** `txn.go:200` can return a valid response *and* a
  `StartTs mismatch` error; `Result` cannot express that. Mitigation:
  `TransactionError::StartTsMismatch` carries the response so nothing is lost.
- **First proto-binding consumer.** No in-repo precedent for the Bazel wiring; a green
  `cargo check` will not prove it. Mitigation: `bazel build //rust/dgraph-client/...` is
  a required task, per the standing rule in AGENTS.md.
- **Re-vendor churn.** Adding dependencies to the crate changes `Cargo.lock` and requires
  `scripts/vendor.sh`, which rewrites the whole vendored tree.

## Migration Plan

Net-new crate, no consumers, nothing to migrate. Each implementation phase in `tasks.md`
is independently testable and leaves the tree green.

## Open Questions

- Should the crate expose a `tower` middleware seam for callers wanting their own retry
  or tracing layers? Deferred: not needed by any current consumer, and it would put
  generic bounds through the public API.
- Should `RunDQL` (the txn-less v250 path) and the transaction API share one request
  builder? Deferred to implementation; both must exist regardless.
