## ADDED Requirements
### Requirement: Publish Phoenix + Rustler + CNPG architecture blog
ServiceRadar MUST publish a Docusaurus blog post titled "From Fragmented to Fluid: Simplifying ServiceRadar with Elixir, Rustler, and CloudNativePG" with slug `simplifying-observability-elixir-rustler-cnpg` that documents the staging move to a Phoenix LiveView UI embedding the SRQL engine via Rustler and targeting CNPG with TimescaleDB + Apache AGE.

#### Scenario: Blog metadata present
- **WHEN** `docs/blog/2025-12-16-simplifying-observability-elixir-rustler-cnpg.mdx` is built
- **THEN** the frontmatter includes `slug`, `title`, `date: 2025-12-16`, `authors: [mfreeman]`, and tags `[elixir, phoenix, rust, rustler, postgres, timescaledb, age, architecture]`.

#### Scenario: Content reflects shipped staging architecture
- **WHEN** a reader views the post
- **THEN** it states that Go remains the orchestration/poller core, Phoenix LiveView is the new UI layer, SRQL runs in-process via a Rustler NIF, and CNPG (Timescale hypertables + Apache AGE graph) is the unified data store, and it notes that `pg_notify`-driven streaming is implemented in staging and rolling into the next release.

#### Scenario: Data consolidation explained
- **WHEN** the post covers storage
- **THEN** it explains the migration from the prior Proton/ClickHouse path to CNPG, noting that Timescale handles metrics, AGE handles topology graphs, and standard Postgres handles relational inventory/RBAC in one cluster.
