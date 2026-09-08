## Context

We have a dedicated `/netflow` Visualize page and a D3 chart suite. Next we need the dimension system to drive meaningful exploration.

## Decisions

### Decision: Single-Series Dimension For Time-Series Charts (v1)

SRQL downsample currently produces one `series` column. To avoid SRQL engine changes, time-series charts will use the first selected dimension as the `series:` field. Additional selected dimensions are ignored for time-series in v1 and will be implemented later (either via SRQL enhancements or a structured series key).

### Decision: Ranking Computed Server-Side (Initially)

We will compute top-N selection from downsample results in the LiveView layer:
- `avg`: rank by sum over window
- `max`: rank by maximum bucket value
- `last`: rank by value in the last bucket

This avoids SRQL changes for ranking while still using SRQL as the data source.

### Decision: IP Truncation Uses SRQL `src_cidr:`/`dst_cidr:` For Sankey

For Sankey grouping, IP truncation is represented as `src_cidr:<prefix>` and `dst_cidr:<prefix>` in the SRQL stats group-by expression.

## Rollout

1. Add UI controls and persist them in `nf` state.
2. Update dataset construction (top-N + Other) and Sankey query generation.
3. Add tests for state + ranking behavior.
