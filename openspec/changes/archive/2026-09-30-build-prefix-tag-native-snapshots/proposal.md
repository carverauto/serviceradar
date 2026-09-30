# Change: Build prefix-tag snapshots in native memory

## Why

Building nested BEAM maps for large prefix snapshots creates a transient memory
spike, amplified when the finished tree is copied into `:persistent_term`.
Web nodes also build external datasets despite not owning flow ingestion.
[GitHub issue #4845](https://github.com/carverauto/serviceradar/issues/4845)
sets the implementation direction: a mutable packed Rust trie, published as an
opaque resource, with database access remaining in Elixir.

## What Changes

- Add a Rustler engine with a packed, path-compressed IPv4/IPv6 trie, bounded
  DirtyCpu batch appends, and immutable resource publication.
- Stream provider, threat-intel, and snapshot-backed rows from CNPG in Elixir.
  Fingerprint unchanged snapshots before calling native construction.
- Make the native engine the production default while retaining the pure Elixir
  engine for behavior tests and its small benchmark.
- Prevent web nodes from building provider and threat-intel tries on boot,
  retries, invalidation, or explicit reload. Keep authorized IP previews working
  by querying a core node; expose unavailability rather than a false empty match.
- Preserve full containing chains, same-prefix VRF variants, duplicate merging,
  threat-intel member metadata, and ingest-time enrichment semantics.
- Verify panic containment with unwinding enabled in the actual NIF build.

## Impact

- Affected capability: `prefix-tagging`, currently defined by the pending
  `add-flow-prefix-tag-enrichment` change. Its overlapping requirements are
  updated alongside this delta to avoid restoring obsolete replication and
  local-preview contracts when it is archived.
- Affected code: PrefixTags engine, Store, loaders, core Rustler build inputs,
  workspace manifests, web configuration, and authorized settings previews.
- No schema migration, database driver, telemetry routing change, memory-limit
  increase, collector change, or MMDB import.
- Implementation is authorized by the request to write this proposal and get
  started, following the decisions already recorded in #4845.
