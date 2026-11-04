# Coordination: in-flight AGE writers

New topology writes land on Dgraph (`ServiceRadar.Dgraph` / `dgraph-topology`
typed upserts). Do not add AGE Cypher for new graph projections.

In-flight changes that still mention AGE:

- `add-endpoint-sbom-inventory` — package/risk scalars already have
  `device.pkg_*` predicates. Continue that path; do not invent AGE vertex
  properties for SBOM.
- `fix-topology-evidence-pipeline-resilience` — evidence stays in CNPG
  (`mapper_topology_links`). Canonical rebuild runs on Dgraph only.
  New persist adapters go through `DgraphPersist`.
- `add-causal-engine` — may never ship inside ServiceRadar. The hydrator
  reads `TOPOLOGY_EDGES_QUERY` from Dgraph through `in:graph`. Do not block this
  cutover on that change, and do not add AGE-only causal edge types
  (`CONTAINS`, reverse `MANAGES`) as Cypher; add Dgraph `topo.kind` values
  instead.

AGE is retired (section 14): `in:graph_cypher`, `GRAPH_BACKEND` and
`GRAPH_READ` are gone. Readers use `in:graph` / `in:graph_dql`,
`in:device_graph`, or the typed `ServiceRadar.Dgraph` reads.
