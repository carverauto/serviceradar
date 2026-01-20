# Change: Fix core-elx Apache AGE agtype handling

## Why

The `TopologyGraph` module in `core-elx` fails when executing Cypher queries against Apache AGE because Postgrex cannot decode the `agtype` custom type. This causes repeated errors and Postgrex connection disconnects:

```
Postgrex.QueryError: type `agtype` can not be handled by the types module Postgrex.DefaultTypes
```

## What Changes

- Update `TopologyGraph.upsert_interface_payload/1` and `TopologyGraph.upsert_link_payload/1` to handle AGE queries correctly
- Two approaches available:
  1. **Preferred**: Cast results to text using `ag_catalog.agtype_to_text()` (pattern already used in `web-ng/lib/serviceradar_web_ng/graph.ex`)
  2. **Alternative**: Change queries to not return agtype columns (since MERGE operations don't need results)

## Impact

- Affected code: `elixir/serviceradar_core/lib/serviceradar/network_discovery/topology_graph.ex`
- No spec changes required - this is a bug fix restoring intended behavior
- No breaking changes

## Root Cause Analysis

The queries in `TopologyGraph` use:
```sql
SELECT * FROM ag_catalog.cypher('serviceradar', $$...$$) AS (v agtype);
```

The `AS (v agtype)` clause tells PostgreSQL to expect an `agtype` column, which Postgrex cannot decode. The `web-ng` codebase solves this by:
1. Loading the AGE extension: `LOAD 'age'`
2. Setting search_path to include `ag_catalog`
3. Using `ag_catalog.agtype_to_text(result)` to convert to text

## References

- GitHub Issue: #2378
- Working pattern: `web-ng/lib/serviceradar_web_ng/graph.ex:25`
- [Postgrex Extension docs](https://hexdocs.pm/postgrex/Postgrex.Extension.html)
- [Apache AGE agtype docs](https://age.apache.org/age-manual/master/intro/types.html)
