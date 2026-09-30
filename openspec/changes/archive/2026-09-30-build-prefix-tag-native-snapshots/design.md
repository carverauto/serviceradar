## Context

`Store.put_rows/2` fingerprints rows before constructing an engine value and
publishes a versioned per-source handle. `Trie` currently uses one nested BEAM
map per address bit. Provider loading has an additional durable snapshot-token
shortcut; threat-intel loading groups members to preserve individual expiry.
The loader is shared by core and web releases. Peer joins already avoid
external-source rebuilds and must retain that behavior.

## Decisions

### 1. Packed native trie, separate construction and publication

Use contiguous node arenas with compressed edges and integer child indices,
with independent IPv4 and IPv6 roots. Nodes exist at prefix endpoints or
branching points, rather than at every address bit. Entries preserve the full
containing chain, reverse insertion order within one prefix, and VRF identity.
Same-prefix/same-VRF rows merge tags and structured metadata using the existing
Elixir semantics. IPv4-mapped IPv6 addresses resolve against the IPv4 arena.

The Rust trie core lives under
`elixir/serviceradar_core/native/prefix_tags_nif`. It has no database or BEAM
runtime dependency, allowing its semantics to run in ordinary Rust/Bazel tests.
The Rustler ABI is feature-gated in that crate.

A builder resource owns `Mutex<Option<Trie>>`; bounded append calls run on
DirtyCpu. Finalization moves the trie into an immutable resource and consumes
the builder. Appends after finalization fail. Lookups take no builder lock and
copy only matching entries to BEAM maps. A discarded or failed builder never
changes the active Store handle. Resource reference counting keeps readers of
an old snapshot safe through publication and reclamation.

The native lookup accepts a binary address, never a list of bits. The Elixir
adapter handles supported input forms and preserves optional-field omission,
DateTime precision, canonical prefix formatting, and invalid-input behavior.
The pure Elixir engine and optional bit-list callbacks remain available.

### 2. Bounded Elixir reads and skip-before-build

Keep every SQL statement, connection, and transaction in Elixir. Use a stable
repeatable-read transaction and deterministic row ordering. Stream in bounded
batches (initially 2,048 rows). For sources without an immutable snapshot token,
make a first streaming pass to compute the existing deterministic fingerprint;
only a changed fingerprint starts a second pass and native builder in the same
transaction. This trades a second sequential read for bounded BEAM memory and
zero native calls on unchanged content. An immutable provider snapshot token
can bypass both passes when its installed version is current.

Pin provider rows to the metadata snapshot ID to avoid a promotion racing
between metadata selection and row loading. Serialize publication per source
using the existing Registry lock. Install the completed resource, fingerprint,
and snapshot token coherently; report query/build errors while retaining the
last good snapshot. Authoritative empty snapshots remain distinguishable from
cleared or failed sources.

Threat-intel rows are ordered by prefix. Group across cursor batch boundaries
before applying the existing display-tag cap and per-member expiry aggregation;
do not accidentally cap each batch independently or lose member metadata.
Snapshot-backed sources, including manual, use the same bounded-build path.
Other-source snapshots continue to serve during a rebuild.

### 3. Core owns external materialization

Use an explicit release configuration for whether external tries may be built.
Guard the shared loader on all entry paths and external source reload entry
points, so a direct refresh cannot reconstruct a provider or threat-intel trie
on web. Keep `nodeup` restricted to snapshot-backed sources on all node roles.

Settings previews use the existing core-node discovery/RPC conventions and
retain authorization checks. An unavailable core cannot be presented as proof
that an IP has no external matches. Do not change stored-row readers into trie
clients. `FlowEnrichment` still enriches after JetStream and before persistence,
with existing batch caching and CNPG-or-StarRocks routing unchanged.

### 4. Panic containment is a build contract

Wrap native operations in `catch_unwind`, return tagged errors, and treat a
poisoned or partially mutated builder as failed. The workspace release profile
currently sets `panic = "abort"`; a catch alone is insufficient. The NIF's Cargo
and Bazel build must use an unwinding profile, including dependencies, and a
release-profile executable regression must demonstrate error conversion. Do
not change unrelated executables' panic strategy merely to enable this NIF.
Allocator aborts are not recoverable Rust panics.

## Validation

- Rust owner tests cover IPv4/IPv6 overlap, defaults, host routes, misses,
  canonicalization, mapped addresses, VRF variants, duplicate merges, and
  structured threat-intel fields. Compare randomized lookup sets to an
  independent flat containment oracle.
- Cross-engine ExUnit tests exercise the existing Trie contract, native error
  results, consumed builders, resource lifetime through concurrent swaps, and
  unchanged fingerprints without invoking native construction.
- Loader integration tests execute cursor reads, including rollback,
  batch-boundary groups, empty snapshots, and all web reload paths.
- A synthetic, mostly IPv6 dataset with hundreds of thousands of prefixes
  measures peak builder BEAM heap and build time and verifies an opaque resource
  handle. Never capture a real provider dataset.
- Exercise both authorized preview pages and unavailable-core behavior.
- Run Cargo formatting/clippy and focused Bazel targets, then `make test` and
  the no-mistakes review/push/PR pipeline before publication.

## Rollout and rollback

Land the trie core, NIF, streaming/role integration, and production default
together. No deployment is part of this work.
Keep an explicit engine override for tests and diagnosis. Falling back to the
large Elixir build automatically would reintroduce the memory spike, so native
load failure is surfaced instead. Roll back the engine change deliberately if
necessary; keep web external builds disabled.
