# Coordination: in-flight AGE writers

New topology writes land on Dgraph (`ServiceRadar.Dgraph` / `dgraph-topology`
typed upserts). Do not add AGE Cypher for new graph projections.

In-flight changes that still mention AGE:

- `add-endpoint-sbom-inventory` — package/risk scalars already have
  `device.pkg_*` predicates. Continue that path; do not invent AGE vertex
  properties for SBOM.
- `fix-topology-evidence-pipeline-resilience` — evidence stays in CNPG
  (`mapper_topology_links`). Canonical rebuild already dual-writes Dgraph.
  New persist adapters go through `TopologyGraph.Persist` / `DgraphPersist`.
- `add-causal-engine` — may never ship inside ServiceRadar. The hydrator
  already switches `TOPOLOGY_EDGES_QUERY` on `GRAPH_READ`. Do not block this
  cutover on that change, and do not add AGE-only causal edge types
  (`CONTAINS`, reverse `MANAGES`) as Cypher; add Dgraph `topo.kind` values
  instead.

AGE `in:graph_cypher` remains until AGE is retired. Readers that need the
new store use `in:graph` / `in:graph_dql` or `GRAPH_READ=dgraph`.
