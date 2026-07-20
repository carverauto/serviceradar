## Context
The device page renders a fast shell and then loads supplemental data concurrently. A missing result in that bounded batch currently has the same representation as a definitive empty result. Same-device tab changes also invoke interface and flow queries synchronously in the LiveView process. Anomaly episode rows retain the last producer payload, whose title and reason often describe the opening transition even after the episode record is cleared.

## Goals / Non-Goals
- Goals: stable tab navigation, non-blocking tab loads, bounded flow queries, truthful query errors, and clear episode lifecycle copy.
- Non-Goals: change interface discovery semantics, redesign flow analytics, or alter the anomaly detector's statistical decisions.

## Decisions
- Model tab availability as `checking`, `available`, `unavailable`, or `unknown`; only a completed negative probe may hide a tab.
- Keep inventory and metric loading independent so an expensive favorite-interface chart cannot delay the interface table.
- Use the existing 24-hour device-flow window consistently for presence, inventory, and analytics queries.
- Preserve opening and resolution reasons as separate projected fields. For a resolved episode, the resolution reason is the primary operator message.

## Risks / Trade-offs
- An inconclusive availability probe can leave a tab visible even when it is empty. The tab will explain the failed check and allow a retry, which is safer than hiding operator data.
- Multiple async results can arrive out of order. Per-device request references discard stale results.

## Migration Plan
No database migration is required. The change is reversible at the web-ng deployment level.
