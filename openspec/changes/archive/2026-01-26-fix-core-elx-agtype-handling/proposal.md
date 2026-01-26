# Change: Fix core-elx Apache AGE agtype handling

## Why

The `TopologyGraph` module in `core-elx` fails when executing Cypher queries against Apache AGE because Postgrex cannot decode the `agtype` custom type. This causes repeated errors and Postgrex connection disconnects:

```
Postgrex.QueryError: type `agtype` can not be handled by the types module Postgrex.DefaultTypes
```

## What Changes

- **Create shared `ServiceRadar.Graph` module** in `serviceradar_core` with:
  - `execute/2` - Execute Cypher for side effects (MERGE, CREATE, SET)
  - `query/2` - Execute Cypher and return parsed results
  - `escape/1` - Safely escape values for Cypher queries
  - Proper agtype-to-text conversion to avoid Postgrex errors

- **Update `TopologyGraph`** to use shared `ServiceRadar.Graph` module

- **Update `web-ng/Graph`** to delegate to shared `ServiceRadar.Graph` module
  - Eliminates code duplication between core-elx and web-ng

## Impact

- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/graph.ex` (new)
  - `elixir/serviceradar_core/lib/serviceradar/network_discovery/topology_graph.ex`
  - `web-ng/lib/serviceradar_web_ng/graph.ex`
- No breaking changes - existing API preserved in web-ng
- Single source of truth for AGE query execution

## Technical Approach

AGE queries return `agtype` which Postgrex cannot decode. The solution uses `ag_catalog.agtype_to_text()` to convert results to text before Postgrex processes them:

```sql
SELECT ag_catalog.agtype_to_text(v)
FROM ag_catalog.cypher('serviceradar', $cypher$...$cypher$) AS (v agtype)
```

The shared module also uses cryptographically random dollar-quote tags to safely embed Cypher queries without injection risks.

## References

- GitHub Issue: #2378
- [Postgrex Extension docs](https://hexdocs.pm/postgrex/Postgrex.Extension.html)
- [Apache AGE agtype docs](https://age.apache.org/age-manual/master/intro/types.html)
