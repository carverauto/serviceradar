# Change: Refactor mapper discovery pipeline boundaries

## Why
`prop2.md` identifies deferred-but-important mapper refactors: reducing god-function flow, isolating identity from topology phases, and removing expensive per-target behaviors that create instability and operational drag.

## What Changes
- Refactor mapper worker execution into explicit staged boundaries (prepare, identity, enrichment, topology, finalize).
- Replace per-target expensive host checks with shared worker-safe services.
- Replace ambiguous raw discovery payload dumping with structured contracts.
- Preserve identity-before-topology sequencing as a hard invariant.

## Impact
- Affected specs:
  - `network-discovery`
- Expected code areas:
  - `pkg/mapper/discovery.go`
  - `pkg/mapper/snmp_polling.go`
  - `pkg/mapper/types.go`
