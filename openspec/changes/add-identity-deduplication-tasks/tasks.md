# Tasks

## 1. Tasks and assertions

- [x] 1.1 `DeduplicationTask` and `DistinctDeviceAssertion` resources and migration (platform
      schema; unique candidate key; sorted-pair check constraint).
- [x] 1.2 `Identity.Deduplication`: open or update one task per candidate set from identity
      decisions; skip sets whose every pair is asserted distinct.
- [x] 1.3 Operator actions: merge (administrative merge path), mark distinct (assertions for
      every pair, one transaction), dismiss, reopen; operator-only.
- [x] 1.4 `MergeEngine` guard `asserted_distinct` for every automatic merge.
- [x] 1.5 Duplicate sweep records ambiguous components as `component_block` decisions.
- [x] 1.6 Integration tests: each blocking path opens exactly one task; repeats count on it;
      mark distinct blocks every automatic merge reason including the backfill; merge, dismiss,
      reopen and authorization.

## 2. Follow-up

- [ ] 2.1 web-ng review queue for open tasks with the three operator actions.
- [ ] 2.2 SRQL entities for tasks and identity decisions, and MCP identity-diagnostics
      visibility.
