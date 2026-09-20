## 1. Shared client and migrator

- [x] 1.1 Pin `dgraph-client` from `marvin-hansen/dgraph-rs` in the root
      `Cargo.toml` `[workspace.dependencies]` (crates.io version if published,
      otherwise a git `crate.spec` with the scrith `protoc` annotation). Do not
      recreate `rust/dgraph-client`.
- [x] 1.2 Extract the generic schema runner from scrith (`verify` / `apply` /
      scoped `remove` / `connect` / env resolution / `Outcome`) into
      `dgraph-migrate`. Schema string and predicate/type lists are parameters.
      Never `drop_all`.
- [x] 1.3 Consume `dgraph-migrate` from ServiceRadar and leave scrith's SMDB
      schema in scrith. Document the split in `rust/README_RUST.md`.
- [x] 1.4 Run `bazel run //third_party/crate_mirror:sync` if the pin is a
      crates.io version. Verify `cargo check -p dgraph-topology` standalone
      **and** `bazel build` of the new targets. Git pin: crate_mirror skipped.

## 2. Topology schema and Rust library

- [x] 2.1 Add `rust/dgraph-topology` (crate `dgraph_topology`): DQL schema with
      namespaced predicates (`device.*`, `iface.*`, `hop.*`, `collector.*`,
      `topo.*`, `prefix.*`, `change.*`), types `Device`, `Interface`,
      `HopNode`, `Collector`, `Service`, `TopologyEdge`, `Prefix`, `Change`.
      `device.id`, `topo.link_key`, `prefix.cidr`, and `change.id` carry
      `@upsert`.
- [x] 2.2 Reify property-rich edges as `TopologyEdge` nodes (`topo.src` /
      `topo.dst` `[uid] @reverse`, `topo.kind`, directional telemetry,
      confidence, `capacity_bps`, `telemetry_eligible`). Plain
      `device.interfaces` MAY stay a `[uid] @reverse` until it grows
      properties.
- [x] 2.3 Implement typed JSON mutations (not RDF): upsert device, interface,
      prefix, change, canonical edge, mapper evidence edge, config-declared
      edge, MTR path; prune stale; rebuild canonical. Treat a skipped `@if`
      as failure by reading named query blocks.
- [x] 2.4 Implement typed reads that return the canonical directional edge
      shape God View already consumes (`source`, `target`, `if_index_ab` /
      `if_index_ba`, directional flow, `capacity_bps`, `telemetry_eligible`,
      evidence metadata).
- [x] 2.5 Schema tests: apply is idempotent; verify reports missing
      predicates; remove drops only named predicates; a second apply after
      remove restores the schema. Fixture is `DgraphInstance::acquire()`
      (local Docker on Linux) or `DGRAPH_TEST_STRATEGY=existing` (`dgraph-ci`).
      The product instance lives in the `demo` namespace.

## 3. Elixir NIF

- [x] 3.1 Add `elixir/serviceradar_core/native/dgraph_nif` wrapping
      `dgraph_topology`. Typed `NifMap` / `NifTaggedEnum` ABI, not JSON.
      Dedicated `tokio` runtime; NIFs scheduled `DirtyIo`; `catch_unwind` per
      call.
- [x] 3.2 Add `ServiceRadar.Dgraph` as the Elixir facade. Writes go through
      typed functions. Read-only DQL escape hatch refuses mutations.
- [x] 3.3 Connection string, ACL, namespace, and TLS mode come from runtime
      config / env (`dgraph://...`), not from `network_credential_secrets`.
- [x] 3.4 Unit tests for the ABI (ok/error atoms, mutation refusal, panic
      isolation) without a live cluster; integration tests tagged and pointed
      at `dgraph-ci` or `DgraphInstance::acquire()`.

## 4. Cluster wiring

- [x] 4.1 Docker Compose: Dgraph service (ACL on, TLS off, `sslmode=disable`),
      generated ACL secret on first boot, schema one-shot using the Bazel
      migrator image. `docker compose up -d` reaches healthy without manual
      Dgraph steps.
- [x] 4.2 Helm: embed Dgraph in `helm/serviceradar` (official chart
      dependency or in-tree templates), enabled by default. Pin Harbor
      `v25.4.0` (or the current mirrored tag). Generate ACL Secret;
      wire TLS; wait Ready; run schema Job. `single` and `ha` value
      profiles from `k8s/dgraph`. No new `scripts/` installer.
- [x] 4.3 `dgraph.enabled=false` plus external endpoint for CI
      (`dgraph-ci`) and one-time cutover from the standalone demo
      cluster. Documented install path is the embedded chart.
- [x] 4.4 CI crate tests may use `dgraph-ci` with
      `DGRAPH_TEST_STRATEGY=existing` or `DgraphInstance::acquire()`
      locally. Product-install tests template the embedded chart.

## 5. Dual-write adapters

- [x] 5.1 Add `GRAPH_BACKEND=age|dual|dgraph` and `GRAPH_READ=age|dgraph`
      (Helm values + env). Default during rollout: backend `dual`, read `age`.
- [x] 5.2 Point `TopologyGraph` writers (links, interfaces, canonical rebuild,
      pruning, risk-summary scalars, MTR paths) at `ServiceRadar.Dgraph` when
      backend is `dual` or `dgraph`. Keep AGE writes when backend is `age` or
      `dual`.
- [x] 5.3 Stop interpolating Cypher for Dgraph writes. AGE Cypher stays inside
      `ServiceRadar.Graph` until AGE writes stop.
- [x] 5.4 Arbitration, confidence gating, and stale-TTL stay in the existing
      modules; only the persist/query adapter changes. Idempotent upsert on
      `topo.link_key`.

## 6. Readers

- [x] 6.1 God View snapshot fetch uses Dgraph when `GRAPH_READ=dgraph`, AGE
      otherwise. Snapshot Arrow contract is unchanged.
- [x] 6.2 SRQL: add `in:graph` / `in:graph_dql` executing read-only DQL and
      returning the same `{nodes, edges}` wrapper as `graph_cypher`. Refuse
      mutations.
- [x] 6.3 Keep `in:graph_cypher` working against AGE until AGE is retired.
- [x] 6.4 Causal hydrator `TOPOLOGY_EDGES_QUERY` switches to `in:graph` when
      `GRAPH_READ=dgraph`.

## 7. AGE-to-Dgraph migrator

- [x] 7.1 Add `rust/age-to-dgraph` Bazel `rust_binary` with modes `rebuild`
      (default: canonical rebuild from evidence into Dgraph) and `checksum`
      (compare AGE vs Dgraph counts + canonical-edge content hash).
- [x] 7.2 Optional dump-and-load path for lab graphs with no evidence tables.
      Fixtures are synthetic. Live dumps never enter the repository.
- [x] 7.3 Helm Job / compose one-shot invoke the binary. Checksum failure
      fails the Job and MUST NOT flip `GRAPH_READ`.
- [x] 7.4 Operator-safe reset: documented rebuild-from-evidence against
      Dgraph, with pre/post counts, matching the existing AGE reset contract.

## 8. Cutover and tests

- [x] 8.1 Integration: dual-write a synthetic topology, checksum passes,
      `GRAPH_READ=dgraph` serves God View and SRQL, flipping back to AGE still
      serves the shadow graph.
- [x] 8.2 Idempotence: re-running rebuild and schema migrate is a no-op on a
      current cluster.
- [x] 8.3 Stale-edge TTL and MTR path prune behave the same on Dgraph as on
      AGE for the synthetic fixture.
- [ ] 8.4 Demo cutover: checksum Job green, `GRAPH_READ=dgraph`, then
      `GRAPH_BACKEND=dgraph`. Record rollback as `GRAPH_READ=age`.
- [x] 8.5 Do not remove AGE from the CNPG image in this change.

## 9. Coordination

- [x] 9.1 Note on in-flight AGE writers (`add-endpoint-sbom-inventory`,
      `fix-topology-evidence-pipeline-resilience`, and any remaining
      `add-causal-engine` graph projection) that new graph writes target
      Dgraph, not new AGE Cypher. Do not depend on `add-causal-engine`
      shipping inside ServiceRadar.
- [x] 9.2 Mark `add-rust-dgraph-client` as superseded by `dgraph-rs`; do not
      land `rust/dgraph-client` in this repo.

## 10. Network config facts (CNPG)

- [x] 10.1 Ash resource + migration `network_config_revisions` in `platform`:
      device_uid, source, config_kind (`running` | `startup`), retrieved_at,
      content_hash, body, parser_version. `migrate?: false` if the table needs
      a raw SQL migration; attributes must match.
- [x] 10.2 Ash resource + migration `network_config_interface_facts`:
      revision_id, device_uid, if_name, ipv4_prefix, ipv6_prefix, vlan,
      description, shutdown, vrf. Unique on `(revision_id, if_name)`.
- [x] 10.3 Downparser (Rust, Bazel-tested) that reads a revision body and
      writes interface facts. V1 extracts name, prefixes, description, VLAN,
      shutdown from invented IOS-like fixtures. Live dumps never enter git.
- [x] 10.4 Projector: turn interface facts into `TopologyGraph` payloads with
      `ingestor=network_config_v1`, `evidence_class=config-declared`,
      `protocol=config`. Upsert Prefix nodes and `iface.prefixes`. Do not
      overwrite `direct-physical` backbone edges.

## 11. Change impact

- [ ] 11.1 Ash resource + migration `network_changes`: external id, source,
      kind (`upgrade` | `config` | `other`), window_start, window_end,
      status, selector (device uids, IPs, CIDRs). Graph projection creates
      the `Change` node and `change.affects` edges to Device / Prefix.
- [ ] 11.2 Typed NIF `downstream_of(from_ids, to_ids)` returning the graph
      fact (reachable / disjoint) over canonical topology after Prefix
      expansion. This is a Spaceoid hydrator, not a product verdict.
- [ ] 11.3 Synthetic fixture: Change A affects `192.0.2.0/24`, Change B
      affects `198.51.100.0/24`, B's prefix is downstream of `192.0.2.1`.
      `downstream_of` is true. Inverse (disjoint topology, non-overlapping
      windows stored only on the CNPG row) is false. Do not return
      postpone/sequence from ServiceRadar.
- [ ] 11.4 Do not materialize `change.blocks` edges in v1.
- [ ] 11.5 Freeze the NMS extension snapshot + ChangeImpact contract in
      `specs/scrith-causal-integration` (separate Dgraphs, NMS-neutral
      snapshot, SR as reference plugin). Implement the ServiceRadar
      snapshot surface only. Do not implement scrith core, the extension
      host, or causaloids in this repo.

## 12. OpenText config retrieve

- [ ] 12.1 New plugin action on `opentext-nom` (or a sibling package) that
      retrieves running-config for a device and submits it as an artifact.
      Do not parse inside Wasm. Do not fold this into `list device`.
- [ ] 12.2 Core ingest path: artifact → `network_config_revisions` →
      downparser job. Credentials stay on the unified credential rule;
      nothing new in Helm/env for the NA password.

## 13. Topology provenance

- [ ] 13.1 Define live, snapshot, and scratch Dgraph namespace roles.
      Ash `topology_graph_snapshots` catalog: `as_of`, reason
      (`scheduled`|`change_window`|`manual`|`dry_run`), namespace id,
      fingerprint, retention. ACL required (namespaces do not isolate
      without it).
- [ ] 13.2 Snapshot job: copy or rebuild-from-evidence into a new
      namespace, apply the same topology schema, record the catalog row.
      Do not snapshot on unchanged heartbeats. GC expired namespaces with
      scoped remove, never `drop_all`.
- [ ] 13.3 Dry-run projector writes a proposed graph into a scratch
      namespace only. Live is unchanged. Same canonical-edge DQL works
      against scratch. Optional thin `topology_graph_mutations` index
      (`evidence_refs`) for "which link_keys cite revision R".
- [ ] 13.4 Tests with invented fixtures: live vs snapshot namespaces
      return different neighbourhoods; dry-run scratch differs from live
      on a prefix change; GC of scratch does not touch live; no DQL
      spans two namespaces.
