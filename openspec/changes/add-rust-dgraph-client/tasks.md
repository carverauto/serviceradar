## 1. Crate skeleton and build wiring

- [x] 1.1 Add dependencies to `rust/dgraph-client/Cargo.toml` using `{ workspace = true }`
      only: `tonic`, `tonic-prost`, `prost`, `tokio`, `tracing`, `urlencoding`; dev-deps
      `tokio` (test features), `pretty_assertions`. NOT `thiserror` - see D2, Display is
      implemented by hand
- [x] 1.2 Add the in-repo proto dependency `proto_dgraph = { path = "../../proto/dgraph" }`
- [x] 1.3 Run `scripts/vendor.sh` (required: the crate previously had no dependencies, so
      `Cargo.lock` and `//third_party/crates` both change)
- [x] 1.4 Update `rust/dgraph-client/BUILD.bazel`: `deps = all_crate_deps(normal = True) +
      ["//proto/dgraph:proto_dgraph_bindings"]`, `edition = "2024"`
- [x] 1.5 Add `rust_test(crate = ":dgraph_client", ...)` for in-src unit tests, repeating
      any `crate_features` (they are NOT inherited - see AGENTS.md)
- [x] 1.6 Create `rust/dgraph-client/tests/BUILD.bazel` declaring the integration test
      targets and folder modules
- [x] 1.7 Verify: `cargo check -p dgraph-client` AND `bazel build //rust/dgraph-client/...`
      (this crate is the first proto-binding consumer in the repo; Cargo passing proves
      nothing about Bazel)
- [x] 1.8 Create the module skeleton per `rust/README_RUST.md` section 6: `src/errors/`,
      `src/traits/`, `src/types/`, `src/utils_tests/`, and `src/lib.rs` re-exports. No
      prelude.

## 2. Error taxonomy

- [x] 2.0 Establish the shared error shape (D2): each error is a public tuple struct with a
      PRIVATE field wrapping a `#[non_exhaustive]` classification enum; `pub(crate) fn new`,
      a public `kind()` accessor, and one `#[allow(non_snake_case)]` associated constructor
      per variant. `Display` and `std::error::Error` implemented by hand in their own files
      per the one-trait-one-file convention. Do NOT add `thiserror`
- [x] 2.1 `src/errors/connection_string_error/` - one variant per parser failure
- [x] 2.2 `src/errors/connect_error/` - transport, TLS, and readiness failures
- [x] 2.3 `src/errors/auth_error/` - login, refresh, JWT decode; the relogin-failure variant
      retains both the login failure and the originating failure
- [x] 2.4 `src/errors/transaction_error/` - `Finished`, `ReadOnly`, `Aborted` (retaining the
      status code and message), `StartTsMismatch` (retaining the response)
- [x] 2.5 `src/errors/dgraph_error/` - top-level type aggregating the above
- [x] 2.6 Store `tonic::Code` + message, never `tonic::Status`: `Status` is `Clone`-only and
      has no `PartialEq`/`Eq`/`Hash`, which would block the derives; this also keeps tonic
      types out of the public API
- [x] 2.7 Derive `Debug, Clone, PartialEq` on every error type, plus `Eq, Hash` wherever the
      payloads permit
- [x] 2.8 Assert no public signature returns `Box<dyn Error>` or a trait object
- [x] 2.9 Tests mirroring each error module under `tests/errors/`, covering `kind()`
      classification, every associated constructor, and `Display` text

## 3. Connection string and client construction

- [x] 3.1 `src/types/connection_string/` - authority parser handling bracketed IPv6, with
      percent-decoded userinfo via `urlencoding`; no `url` crate
- [x] 3.2 `src/types/tls_mode.rs` - `Disable`, `RequireNoVerify`, `VerifyCa`; warn on
      `RequireNoVerify`
- [x] 3.3 `src/types/credentials/` - secret wrapper with redacting `Debug`/`Display`
- [x] 3.4 `src/types/client_config/` - builder; private constructor rejects an empty
      endpoint list (removes Go's `rand.Intn` panic)
- [x] 3.5 `src/types/dgraph_client/` - channel construction, real round-robin over an
      atomic cursor, readiness check
- [x] 3.6 Tests: valid strings, IPv6, every rejection variant, redaction of secrets in
      `Debug`/`Display` and in errors

## 4. Authentication

- [x] 4.1 Login and login-into-namespace; decode the login payload as protobuf `api.Jwt`
      (the field is named `Json` but is not JSON) and name the Rust code accordingly
- [x] 4.2 Token cache behind `tokio::sync::RwLock` (`std::sync::RwLock` cannot be held
      across `.await`)
- [x] 4.3 Attach the access token as request metadata on every RPC
- [x] 4.4 Single-flight refresh; exactly one retry, no backoff
- [x] 4.5 Expiry detection by status code first, documented message fallback second;
      explicitly exclude locally-generated errors, since in tonic every RPC error is a
      `Status` and a naive port widens the trigger
- [ ] 4.6 Tests including concurrent refresh collapsing to a single login RPC

## 5. Transactions

- [x] 5.1 `src/types/txn/` with typestate markers for read-write and read-only
- [x] 5.2 Query, query-with-vars, and RDF variants on both transaction types
- [x] 5.3 `best_effort` on the read-only type only (removes Go's panic)
- [x] 5.4 `mutate` and `commit` on the read-write type only
- [x] 5.5 `commit(self)` / `discard(self)` consume the handle; discard issues no RPC when
      nothing was mutated
- [x] 5.6 Poisoning: a failed mutating request discards, surfaces the original error,
      suppresses the discard error, and makes later operations return `Finished`
- [x] 5.7 Transaction context merge: start timestamp established once, hash carried, keys
      and predicates accumulated for commit
- [x] 5.8 `Drop` performs no I/O and warns when a mutated transaction was neither
      committed nor discarded
- [x] 5.9 Raw `do_request` escape hatch retaining the runtime read-only check
- [ ] 5.10 Tests: compile-fail cases for the typestate rules, poisoning, query-failure
      does NOT poison, start-timestamp mismatch, abort mapping

## 6. Data and admin operations

- [x] 6.1 Mutation builder (JSON and RDF N-Quads, set and delete), commit-now, upsert
- [x] 6.2 Delete-edges helper that builds a mutation without issuing an RPC
- [x] 6.3 Transaction-less DQL entry point with read-only, best-effort, and response-format
      options
- [x] 6.4 Schema operations: set schema, drop all, drop data, drop predicate, drop type
- [x] 6.5 Namespace operations: create, drop by id, list
- [x] 6.6 Lease allocation: UIDs, timestamps, namespaces (start inclusive, end exclusive)
- [x] 6.7 Response/Request/Mutation wrappers with private fields and getters. Generated
      prost types stay internal: no generated type appears in a public signature, and no
      blanket `into_inner()` re-exports one. Raw protocol access is the single
      `do_request()` seam from task 5.9
- [x] 6.8 Verify `proto_dgraph` is not a public dependency: no public signature names a
      generated type, so regenerating the bindings cannot break consumers
- [x] 6.9 Tests for each operation

## 7. Verification and documentation

- [x] 7.1 `cargo fmt` and `cargo clippy` clean on the crate
- [x] 7.2 `cargo check -p dgraph-client` passes standalone (workspace feature unification
      must not be doing the work)
- [x] 7.3 `cargo check --workspace --lib --bins --tests` passes
- [x] 7.4 `bazel build //rust/...` and `bazel test //rust/dgraph-client/...` pass
- [x] 7.5 Confirm no `unsafe` anywhere in the crate
- [x] 7.6 Confirm every test file is registered in a `mod.rs` with `#[cfg(test)]` and every
      folder module is declared in `tests/BUILD.bazel`
- [x] 7.7 Crate-level docs covering the transaction lifecycle, the drop-without-commit
      warning, and the `RequireNoVerify` exposure
- [x] 7.8 Record in the crate docs which Go symbols were intentionally dropped and where
      each capability now lives

## 8. Integration test against a live Dgraph (optional, gated)

- [x] 8.1 Decide whether a live-Dgraph integration suite is in scope for this change or a
      follow-up; if in scope, tag it so the default `bazel test //...` sweep skips it
- [x] 8.2 If added, cover: login, upsert, concurrent-modification abort, namespace
      lifecycle, and schema drop
