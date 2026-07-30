## ADDED Requirements

### Requirement: Crate and build wiring

The `dgraph-client` crate SHALL live at `rust/dgraph-client`, expose the Rust crate name
`dgraph_client`, and build under both Cargo and Bazel. It SHALL depend on the in-repo
protobuf binding `//proto/dgraph:proto_dgraph_bindings` rather than generating its own
bindings. All dependency versions SHALL come from `[workspace.dependencies]` in the root
`Cargo.toml`; the crate SHALL NOT name a version locally.

#### Scenario: Both build systems agree

- **WHEN** `cargo check -p dgraph-client` and `bazel build //rust/dgraph-client/...` are run
- **THEN** both succeed, and the Bazel target resolves the proto binding through
  `//proto/dgraph:proto_dgraph_bindings` and its crates.io dependencies through
  `all_crate_deps`

#### Scenario: Dependency change re-vendors

- **WHEN** a dependency is added to `rust/dgraph-client/Cargo.toml`
- **THEN** `scripts/vendor.sh` is run so `//third_party/crates` contains it
- **AND** `bazel build //rust/dgraph-client/...` passes, since a green `cargo check` alone
  does not prove the Bazel build

### Requirement: Connection string parsing

The client SHALL accept connection strings of the form
`dgraph://[username:password@]host:port[?params]`, supporting the parameters `sslmode`,
`apikey`, `bearertoken`, and `namespace`. Parsing SHALL be implemented without adding a
new workspace dependency. Percent-encoded userinfo SHALL be decoded. Every distinct
validation failure SHALL produce a distinct typed `ConnectionStringError` variant, never
a bare string.

#### Scenario: Minimal connection string

- **WHEN** the caller supplies `dgraph://localhost:9080`
- **THEN** the client targets `localhost:9080` with `sslmode` defaulting to `disable`
  (plaintext) and no credentials

#### Scenario: Full connection string

- **WHEN** the caller supplies
  `dgraph://groot:password@alpha.example:9080?sslmode=verify-ca&namespace=3`
- **THEN** the client targets `alpha.example:9080` over TLS with system-CA verification
- **AND** logs in as `groot` into namespace `3` before returning

#### Scenario: Mutually exclusive auth parameters

- **WHEN** the connection string sets both `apikey` and `bearertoken`
- **THEN** parsing fails with `ConnectionStringError::ConflictingAuth`
- **AND** no connection is attempted

#### Scenario: Unknown sslmode

- **WHEN** the connection string sets `sslmode=verify-full`
- **THEN** parsing fails with `ConnectionStringError::UnknownSslMode`, naming the accepted
  values `disable`, `require`, and `verify-ca`

#### Scenario: Partial credentials

- **WHEN** the connection string supplies a username with no password, or a password with
  no username
- **THEN** parsing fails with `ConnectionStringError::IncompleteCredentials`

### Requirement: IPv6 endpoint support

The connection-string parser SHALL correctly parse bracketed IPv6 literal authorities.
It SHALL NOT determine the host/port split by counting colons.

#### Scenario: IPv6 literal endpoint

- **WHEN** the caller supplies `dgraph://[::1]:9080`
- **THEN** parsing succeeds with host `::1` and port `9080`

#### Scenario: Missing port

- **WHEN** the caller supplies `dgraph://localhost:` or `dgraph://localhost`
- **THEN** parsing fails with `ConnectionStringError::MissingPort`

### Requirement: TLS modes

The client SHALL support three transport modes: plaintext (`disable`), TLS without
certificate verification (`require`), and TLS with system-CA verification (`verify-ca`).
The unverified mode SHALL be named in Rust so that its weakness is evident at the call
site, and selecting it SHALL emit a warning through `tracing`.

#### Scenario: Unverified TLS is signposted

- **WHEN** a caller selects `sslmode=require`
- **THEN** the client connects over TLS with certificate verification disabled
- **AND** the corresponding Rust variant is named to indicate verification is skipped
- **AND** a warning is emitted at connect time

### Requirement: Credentials are never rendered

Passwords, API keys, bearer tokens, and JWTs SHALL NOT appear in any `Debug` or `Display`
output, nor in any error message, from any type in the crate.

#### Scenario: Debug output is redacted

- **WHEN** a configuration or error value holding a password, API key, bearer token, or
  JWT is formatted with `{:?}` or `{}`
- **THEN** the secret is replaced by a redaction marker
- **AND** the surrounding non-secret fields remain visible

#### Scenario: Parse failure does not echo the string

- **WHEN** parsing a connection string containing credentials fails
- **THEN** the returned error does not contain the password or token

### Requirement: ACL login and JWT lifecycle

The client SHALL support logging in with a user id and password, optionally into a given
namespace, and SHALL cache the resulting access and refresh tokens. It SHALL attach the
access token to outgoing requests as gRPC metadata. When a request fails because the
access token expired, the client SHALL refresh the token once and reissue that request
exactly once.

#### Scenario: Login attaches credentials

- **WHEN** a client has logged in successfully
- **THEN** every subsequent RPC carries the cached access token as request metadata

#### Scenario: Expired token is refreshed once

- **WHEN** an RPC fails because the access token has expired
- **THEN** the client refreshes using the cached refresh token and reissues that RPC once
- **AND** does not retry a second time if the reissued RPC also fails

#### Scenario: Refresh without a refresh token

- **WHEN** a refresh is required but no refresh token is cached
- **THEN** the client returns `AuthError::NoRefreshToken`
- **AND** the error preserves the originating request failure as context

#### Scenario: Concurrent refresh is single-flight

- **WHEN** several concurrent requests observe an expired token at the same time
- **THEN** exactly one refresh RPC is issued and the others use its result

### Requirement: Retry policy is single-shot with no backoff

The client SHALL retry only for token expiry, and only once per request. It SHALL NOT
apply backoff, jitter, sleeps, or an attempt cap, and SHALL NOT retry on transport-level
failures such as `UNAVAILABLE` or `DEADLINE_EXCEEDED`.

#### Scenario: Transport failure is not retried

- **WHEN** an RPC fails with `UNAVAILABLE`
- **THEN** the error is returned to the caller without any retry

### Requirement: Read-write and read-only transactions are distinct types

The crate SHALL expose read-write and read-only transactions as separate types such that
mutating or committing a read-only transaction is a compile error, and requesting
best-effort reads on a read-write transaction is a compile error. No public API SHALL
panic on caller input.

#### Scenario: Mutation on a read-only transaction

- **WHEN** a caller attempts to mutate through a read-only transaction handle
- **THEN** the program fails to compile

#### Scenario: Best-effort on a read-write transaction

- **WHEN** a caller attempts to request best-effort reads on a read-write transaction
- **THEN** the program fails to compile

#### Scenario: Best-effort on a read-only transaction

- **WHEN** a caller requests best-effort reads on a read-only transaction
- **THEN** the request is sent with both the read-only and best-effort flags set

### Requirement: Transaction completion consumes the handle

`commit` and `discard` SHALL consume the transaction so that reuse after completion is a
compile error. `discard` SHALL be safe to call on a transaction that performed no
mutations, and SHALL NOT issue an RPC in that case.

#### Scenario: Reuse after commit

- **WHEN** a caller attempts to query a transaction after calling `commit` on it
- **THEN** the program fails to compile

#### Scenario: Discarding a query-only transaction

- **WHEN** a transaction that issued only queries is discarded
- **THEN** no `CommitOrAbort` RPC is sent and the call succeeds

### Requirement: A failed mutation poisons its transaction

When a request carrying mutations fails, the client SHALL discard the transaction and
SHALL surface the original request error rather than any error from the discard. Further
operations on that transaction SHALL fail with `TransactionError::Finished`.

#### Scenario: Mutation failure discards

- **WHEN** a request carrying mutations fails
- **THEN** the transaction is discarded, the original error is returned, and any error
  from the discard is suppressed

#### Scenario: Operating on a poisoned transaction

- **WHEN** a caller issues a further operation on a transaction whose mutation failed
- **THEN** the call returns `TransactionError::Finished` without issuing an RPC

#### Scenario: Query failure does not poison

- **WHEN** a request carrying only queries fails
- **THEN** the transaction remains usable and a subsequent query on it can succeed

### Requirement: Aborted transactions are reported distinctly

When the server aborts a transaction carrying mutations, the client SHALL return
`TransactionError::Aborted` and SHALL retain the originating gRPC status code and message. The client
SHALL NOT retry an aborted transaction automatically; retrying is the caller's decision.

#### Scenario: Concurrent modification aborts

- **WHEN** a commit fails because a concurrent transaction modified the same data
- **THEN** the client returns `TransactionError::Aborted` carrying the server status code and message
- **AND** performs no automatic retry

### Requirement: Queries support DQL, RDF, and variables

The client SHALL support queries returning JSON and queries returning RDF, each with an
optional map of query variables, both inside a transaction and through the transaction-less
DQL entry point.

#### Scenario: Query with variables

- **WHEN** a caller runs a query with a variable map
- **THEN** the variables are sent with the request rather than interpolated into the query
  text

#### Scenario: RDF response format

- **WHEN** a caller requests the RDF response format
- **THEN** the request carries the RDF format flag and the RDF payload is returned

### Requirement: Mutations and upserts

The client SHALL support setting and deleting data as JSON or as RDF N-Quads, SHALL
support combining a query with one or more mutations in a single upsert request, and SHALL
support committing a mutation in the same round trip.

#### Scenario: Commit-now mutation

- **WHEN** a caller submits a mutation flagged to commit immediately
- **THEN** the mutation and commit occur in one request
- **AND** the transaction is complete and cannot be reused

#### Scenario: Upsert

- **WHEN** a caller submits a request containing both a query and mutations
- **THEN** both are sent in a single request and the response reflects the upsert

#### Scenario: Deleting all edges for predicates

- **WHEN** a caller asks to delete the edges of given predicates for a subject uid
- **THEN** the built mutation deletes those predicates for that subject
- **AND** no RPC is issued until the mutation is submitted

### Requirement: Transaction context is merged across requests

The client SHALL carry the transaction start timestamp and hash across requests within a
transaction, and SHALL accumulate the returned keys and predicates for use at commit. If
the server returns a start timestamp that conflicts with the one already established, the
client SHALL fail with `TransactionError::StartTsMismatch` and SHALL retain the response
that accompanied the conflict.

#### Scenario: Start timestamp is established once

- **WHEN** the first request of a transaction returns a start timestamp
- **THEN** that timestamp is reused for every later request in the transaction

#### Scenario: Conflicting start timestamp

- **WHEN** a response carries a start timestamp different from the established one
- **THEN** the client returns `TransactionError::StartTsMismatch` carrying the response

#### Scenario: Keys and predicates accumulate

- **WHEN** several mutating requests occur in one transaction
- **THEN** the commit carries the union of all keys and predicates returned by those
  requests

### Requirement: Schema operations

The client SHALL support setting the schema, dropping all data and schema, dropping data
only, dropping a single predicate, and dropping a single type.

#### Scenario: Set schema

- **WHEN** a caller sets a schema definition
- **THEN** the schema is applied and the call succeeds

#### Scenario: Drop a predicate

- **WHEN** a caller drops a named predicate
- **THEN** only that predicate is dropped and other data is unaffected

### Requirement: Namespace operations

The client SHALL support creating a namespace, dropping a namespace by id, and listing
namespaces.

#### Scenario: Create and list

- **WHEN** a caller creates a namespace and then lists namespaces
- **THEN** the newly created namespace id appears in the listing

### Requirement: Lease allocation

The client SHALL support allocating ranges of UIDs, timestamps, and namespace ids,
returning the inclusive start and exclusive end of each allocated range.

#### Scenario: Allocate UIDs

- **WHEN** a caller requests allocation of `n` UIDs
- **THEN** a range is returned whose end minus start is at least `n`
- **AND** the range is documented as start-inclusive and end-exclusive

### Requirement: Errors are typed and matchable without string comparison

Every failure mode SHALL be expressible as a matchable variant. No public function
signature SHALL return `Box<dyn Error>` or any trait object, in keeping with the
static-dispatch rule. Callers SHALL NOT need to inspect error text to distinguish
failures, including cluster-not-ready and token-expiry conditions.

#### Scenario: Cluster not ready

- **WHEN** connecting fails because the cluster is not yet accepting requests
- **THEN** the caller can detect this from a typed variant or predicate without matching
  on message text

#### Scenario: No trait objects in the public API

- **WHEN** the crate's public API is inspected
- **THEN** no public signature returns `Box<dyn Error>` or any other trait object

### Requirement: Error types are forward-compatible

Each public error type SHALL be a tuple struct with a private field wrapping a
`#[non_exhaustive]` classification enum. Each SHALL expose a `kind()` accessor returning
the classification, and one associated constructor per variant. `Display` and
`std::error::Error` SHALL be implemented by hand rather than derived, each in its own
module file. Adding a new failure mode SHALL NOT be a breaking change for callers.

#### Scenario: Callers branch on classification

- **WHEN** a caller needs to distinguish two failure modes of the same error type
- **THEN** the caller matches on the value returned by `kind()`
- **AND** does not access the wrapped enum through a public field

#### Scenario: New variant is not a breaking change

- **WHEN** a new variant is added to an error's classification enum
- **THEN** existing callers that match on `kind()` continue to compile, because the enum
  is `#[non_exhaustive]` and the wrapper's field is private

#### Scenario: Errors carry status codes, not transport types

- **WHEN** an error records a gRPC failure
- **THEN** it stores the status code and message rather than a `tonic::Status`
- **AND** the error type can therefore derive `PartialEq`, and `Eq`/`Hash` where its
  payloads permit

### Requirement: Concurrency and cancellation safety

The client handle SHALL be cheaply cloneable and safe to share across tasks, satisfying
`Send + Sync`. Dropping the future of any async operation SHALL NOT leave client state
inconsistent, and no lock SHALL be observable as poisoned by a cancelled request.

#### Scenario: Shared across tasks

- **WHEN** a client is cloned into several concurrent tasks issuing requests
- **THEN** all requests proceed without data races and without external synchronization

#### Scenario: Cancelled request

- **WHEN** the future of an in-flight request is dropped before completion
- **THEN** the client remains usable for subsequent requests

### Requirement: Dropping an uncommitted transaction is diagnosable

Dropping a transaction that performed mutations without committing or discarding SHALL NOT
perform I/O, and SHALL emit a warning identifying the leaked transaction. This behavior
SHALL be documented on the transaction type.

#### Scenario: Mutated transaction dropped

- **WHEN** a transaction that performed mutations is dropped without commit or discard
- **THEN** no RPC is issued during drop
- **AND** a warning is emitted noting that server-side state persists until the server
  times it out

### Requirement: Crate structure follows the repo convention

The crate SHALL follow the layout in `rust/README_RUST.md` section 6: one error, trait, or
type per module under `src/errors/`, `src/traits/`, and `src/types/`; complex types as
folder modules with per-trait implementation files; `tests/` mirroring `src/` with a
`_tests` suffix; shared test helpers under `src/utils_tests/`; all public items re-exported
from `src/lib.rs`; and no prelude module.

#### Scenario: Test tree mirrors source tree

- **WHEN** a source file `src/errors/connection_string_error.rs` exists
- **THEN** its tests live at `tests/errors/connection_string_error_tests.rs`
- **AND** that file is registered in its `mod.rs` under `#[cfg(test)]`, which is in turn
  registered with its parent module

#### Scenario: Shared helpers are reachable by Bazel

- **WHEN** tests need shared helper code
- **THEN** the helpers live under `src/utils_tests/` rather than `tests/`, so Bazel can
  reach them, and they are themselves covered by tests

#### Scenario: Public surface is re-exported from the crate root

- **WHEN** another crate imports from `dgraph_client`
- **THEN** it imports from the crate root rather than a nested module path
- **AND** internal modules are not reachable from outside the crate
