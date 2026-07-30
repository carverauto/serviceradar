/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

//! A safe, async Rust client for Dgraph.
//!
//! This is a clean-room implementation of the Dgraph v250 client protocol. It speaks the
//! same wire protocol as the official Go client (`dgraph-io/dgo`) but deliberately does
//! not reproduce its API.
//!
//! The crate contains no `unsafe` code, no public API can panic on caller input, and no
//! error is distinguished by matching on message text.
//!
//! # Connecting
//!
//! ```no_run
//! use dgraph_client::DgraphClient;
//!
//! # async fn example() -> Result<(), dgraph_client::DgraphError> {
//! let client = DgraphClient::connect("dgraph://localhost:9080").await?;
//! # Ok(())
//! # }
//! ```
//!
//! Connection strings take the form
//! `dgraph://[username:password@]host:port[?params]`, where `params` may set `sslmode`
//! (`disable`, `require`, `verify-ca`), `apikey`, `bearertoken`, and `namespace`. IPv6
//! literals are supported: `dgraph://[::1]:9080`.
//!
//! Connecting logs in when credentials are present, then probes the cluster, so a
//! misconfigured endpoint fails at construction rather than at some arbitrary later call.
//! A client is cheap to clone and is `Send + Sync`; clones share one set of channels and
//! one token cache.
//!
//! # Transactions
//!
//! Read-write and read-only transactions are separate types, so misuse is a compile error
//! rather than a runtime one:
//!
//! - [`Txn<ReadWrite>`] can query, mutate, commit, and discard.
//! - [`Txn<ReadOnly>`] can query, request best-effort reads, and discard. It has no
//!   `mutate` or `commit` method at all.
//!
//! [`Txn::commit`] and [`Txn::discard`] take `self`, so reusing a completed transaction
//! also does not compile.
//!
//! ```no_run
//! use dgraph_client::{DgraphClient, Mutation};
//!
//! # async fn example() -> Result<(), dgraph_client::DgraphError> {
//! # let client = DgraphClient::connect("dgraph://localhost:9080").await?;
//! let mut txn = client.new_txn();
//! txn.mutate(Mutation::new().set_json(br#"{"name":"alice"}"#.to_vec()))
//!     .await?;
//! txn.commit().await?;
//! # Ok(())
//! # }
//! ```
//!
//! ## Lifecycle rules worth knowing
//!
//! - **A failed mutation ends the transaction.** The transaction is discarded
//!   automatically and the original error is returned; every later operation on it fails
//!   with [`TransactionErrorEnum::Finished`]. A failed *query* does not do this, and the
//!   transaction stays usable.
//! - **Discard is free when nothing was mutated.** No RPC is issued.
//! - **Aborts are the caller's to retry.** A commit that loses a conflict returns
//!   [`TransactionErrorEnum::Aborted`], carrying the server's status code and message.
//!   Retrying requires a new transaction; this crate never retries an abort for you.
//!
//! ## Dropping without committing
//!
//! Dropping a transaction that mutated but was never committed or discarded issues **no
//! RPC**: `Drop` cannot run async code, and spawning hidden background work would need a
//! runtime handle and obscure cancellation. Server-side state therefore persists until the
//! cluster times the transaction out, and a warning is logged through `tracing`. Prefer an
//! explicit [`Txn::commit`] or [`Txn::discard`].
//!
//! # Errors
//!
//! Every failure is a typed variant. Errors follow the repo's wrapper pattern (see
//! `rust/README_RUST.md` section 6): a public tuple struct with a private field wrapping a
//! `#[non_exhaustive]` classification enum, reached through `kind()`. Adding a failure
//! mode is therefore not a breaking change.
//!
//! No public signature returns `Box<dyn Error>` or any trait object, and gRPC failures are
//! stored as a [`tonic::Code`] plus message rather than a `tonic::Status`, which keeps
//! transport types out of the public API and lets the error types derive `PartialEq`.
//!
//! Two conditions callers most often need are exposed as predicates so nobody has to match
//! on text: [`DgraphError::is_aborted`] and [`DgraphError::is_cluster_not_ready`].
//!
//! # A note on `sslmode=require`
//!
//! [`TlsMode::RequireNoVerify`] is named for what it does. `sslmode=require` encrypts the
//! connection but **disables certificate verification**, so the server is not
//! authenticated and the connection is not protected against an active attacker. It is
//! supported because existing connection strings use it, and selecting it logs a warning.
//! Prefer `sslmode=verify-ca`.
//!
//! # Differences from the Go client
//!
//! This crate is not a transliteration of `dgraph-io/dgo`. Deliberately **not** ported:
//!
//! | Go symbol | Why | Where the capability lives here |
//! |---|---|---|
//! | `NewDgraphClient` | Deprecated; accepts pre-built stubs and enables an empty-client panic | [`DgraphClient::from_config`] |
//! | `DialCloud` | Deprecated; bespoke Cloud URL munging | `dgraph://...?apikey=` with `sslmode=verify-ca` |
//! | `GetJwt` | Exposes raw credentials to callers | nothing, deliberately |
//! | `GetAPIClients` | Leaks generated stubs, defeating the abstraction | no equivalent; raw access is not a goal |
//! | `Close` | A no-op bug upstream: it iterates a slice the constructor never populates | channels drop with the last clone |
//!
//! Defects fixed rather than reproduced:
//!
//! 1. **Connection leak.** Go's `Close()` closes nothing, so every connection leaks. Rust
//!    releases channels on drop.
//! 2. **IPv6 rejected.** Go splits the authority on `:` and requires exactly two parts, so
//!    `[::1]:9080` fails to parse. This crate parses the authority properly.
//! 3. **Panics on caller input.** Go's `Txn.BestEffort()` panics on a read-write
//!    transaction, and its client picks a connection with `rand.Intn`, which panics on an
//!    empty list. Here the first is a compile error and the second is rejected at
//!    construction.
//! 4. **"Round robin" was random.** Go's `anyClient()` is `rand.Intn`. This crate really
//!    does round-robin, over an atomic cursor.
//! 5. **Expiry detected by string matching.** Go matches `"Token is expired"` against the
//!    whole error string. This crate checks the status code first and treats the message as
//!    a documented fallback.
//! 6. **Error context discarded on refresh.** When Go's relogin fails it drops the original
//!    error and surfaces only the login failure, often the useless "refresh jwt should not
//!    be empty". Here both are retained.
//!
//! Full rationale: `openspec/changes/add-rust-dgraph-client/design.md`.

mod errors;
mod types;

pub use crate::errors::auth_error::{AuthError, AuthErrorEnum};
pub use crate::errors::connect_error::{ConnectError, ConnectErrorEnum};
pub use crate::errors::connection_string_error::{
    ConnectionStringError, ConnectionStringErrorEnum,
};
pub use crate::errors::dgraph_error::{DgraphError, DgraphErrorEnum};
pub use crate::errors::transaction_error::{TransactionError, TransactionErrorEnum};
pub use crate::types::client_config::{ClientConfig, ClientConfigBuilder};
pub use crate::types::connection_string::ConnectionString;
pub use crate::types::dgraph_client::DgraphClient;
pub use crate::types::lease_range::LeaseRange;
pub use crate::types::mutation::Mutation;
pub use crate::types::read_only::ReadOnly;
pub use crate::types::read_write::ReadWrite;
pub use crate::types::response::Response;
pub use crate::types::secret::Secret;
pub use crate::types::tls_mode::TlsMode;
pub use crate::types::txn::Txn;
