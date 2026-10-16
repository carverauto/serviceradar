# Change: Retry only the uncommitted chunks of a retained plugin-result stream

Tracking issue: [#5642](https://github.com/carverauto/serviceradar/issues/5642) (follow-up).

## Why

The agent sends retained plugin results as one `StreamStatus` RPC of up to ten
chunks. When any chunk misses its durable acceptance boundary the gateway answers
`received: false`, and the agent resends the whole batch on its next cycle. Core
then re-runs the registered handlers for every chunk that already committed, and
one slow chunk keeps its siblings in the retry loop until a cycle happens to
succeed. The gateway already knows which chunks committed; the agent just never
hears about it.

## What Changes

- `GatewayStatusResponse` gains `repeated int32 committed_chunk_indexes = 3`. It is
  additive: older agents ignore it and older gateways leave it empty.
- For an agent-retained stream answered with `received: false`, the gateway lists
  the `chunk_index` of every chunk that committed. `received` keeps its RPC-wide
  meaning, and the negative acknowledgement still carries no directives.
- The agent drops the results behind those chunks from its pending plugin-result
  set and retries the rest in their original order. Each retained result keeps its
  own identity, so retrying a subset converges like retrying the whole set. With
  no indexes (an older gateway, or nothing committed) it retries the whole set as
  before. New results are still not drained until the retained remainder is
  acknowledged.

## Impact

- Affected specs: `edge-architecture`.
- Affected code: `proto/monitoring.proto` (+ Go and Elixir bindings),
  `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/agent_gateway_server.ex`,
  `go/pkg/agent/push_loop_status.go`.
- Compatibility: either side can be upgraded first. Until both are, behaviour is
  today's whole-set retry.
