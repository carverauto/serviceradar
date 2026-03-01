# Change: Fix AGE graph schema permissions

## Why
core-elx topology graph upserts are failing with schema permission errors when executing AGE Cypher queries. The graph name is hard-coded to `serviceradar`, which creates an ungoverned schema and requires explicit grants that are not reliably applied. AGE also requires the caller to own the label tables, which breaks MERGE/DDL when the graph was created by a superuser. This blocks mapper topology projection.

## What Changes
- Standardize on a single canonical AGE graph name for topology projections in a dedicated schema and use it across core-elx and SRQL.
- Ensure the canonical graph is created during migrations and that the application role has USAGE/CREATE/ALL privileges on the AGE graph schema.
- Ensure the application role owns the AGE graph schema and label tables so Cypher MERGE operations succeed.
- Leave legacy graph names in place (no destructive drops) and converge reads/writes on the canonical graph.
- Add configuration hooks and tests to keep graph name usage consistent across services.

## Impact
- Affected specs: `age-graph`
- Affected code: `elixir/serviceradar_core/lib/serviceradar/graph.ex`, `elixir/serviceradar_core/lib/serviceradar/network_discovery/topology_graph.ex`, `elixir/serviceradar_core/lib/serviceradar/cluster/startup_migrations.ex`, `elixir/serviceradar_core/priv/repo/migrations/*`, `rust/srql/src/query/graph_cypher.rs`, SRQL fixtures/tests
