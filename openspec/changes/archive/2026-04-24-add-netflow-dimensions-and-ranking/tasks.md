## 1. Spec And Design
- [x] 1.1 Define supported dimension list for v1 (flows fields + derived fields)
- [x] 1.2 Define how multi-dimension behaves (time-series uses first dim only, sankey uses first 2-3)

## 2. Visualize State
- [x] 2.1 Extend `nf` state handling in UI to edit `dims`, `limit`, `limit_type`, truncation
- [x] 2.2 Add/extend unit tests for state round-trip with new fields

## 3. Visualize UI
- [x] 3.1 Dimensions selector (multi-select)
- [x] 3.2 Ordering controls (up/down)
- [x] 3.3 Top-N limit + ranking mode controls
- [x] 3.4 Truncation controls for v4/v6

## 4. Dataset Construction
- [x] 4.1 Compute top-N series by limitType and bucket rest into `Other`
- [x] 4.2 Apply dimension selection to downsample `series:` field
- [x] 4.3 Apply dimension selection to Sankey group-by (best-effort)

## 5. Validation
- [x] 5.1 Run `openspec validate add-netflow-dimensions-and-ranking --strict`
- [x] 5.2 Run repo checks (`make lint`, `make test`)
