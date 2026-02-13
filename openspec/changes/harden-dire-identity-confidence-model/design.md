## Context
DIRE currently conflates discovery-time evidence with canonical identity in parts of the ingestion pipeline. Mapper interface data is particularly noisy: interface ordering can vary per poll, observed MACs can represent virtual/secondary interfaces, and neighbor-derived records can be indirect. Using these as immediate canonical keys causes fan-in merges and identity oscillation.

## Goals / Non-Goals
- Goals:
  - Prevent destructive merges from weak or indirect evidence.
  - Make device identity stable across repeated mapper/sweep runs.
  - Keep automatic reconciliation for truly strong identifiers.
  - Ensure behavior is observable and testable with deterministic outcomes.
- Non-Goals:
  - Full replacement of DIRE architecture.
  - Elimination of all false positives in one iteration.
  - Removing manual merge/unmerge tooling.

## Decisions
- Decision: Separate identity evidence from canonical identifiers.
  - Rationale: observations (interface MAC, neighbor hints) should not immediately mutate canonical identity.
- Decision: Require corroboration for promotion.
  - Rationale: repeated sightings plus independent stable evidence reduces merge risk.
- Decision: Block MAC-only auto-merges.
  - Rationale: MAC-only conflicts are too ambiguous in discovery-heavy environments.
- Decision: Keep mapper-created devices but mark/manage them as provisional until promoted.
  - Rationale: preserves discovery continuity without asserting canonical truth too early.
- Decision: Add explicit deterministic tie-breakers and conflict logs.
  - Rationale: avoids flip-flop and makes operator debugging possible.

## Alternatives considered
- Keep interface MAC registration as strong identifiers with confidence weighting only.
  - Rejected: still allows deterministic but wrong merges when evidence is noisy.
- Disable mapper-based device creation entirely.
  - Rejected: loses visibility and delays topology utility.
- Make merges fully manual.
  - Rejected: operationally expensive and regresses automation value.

## Risks / Trade-offs
- Risk: stricter promotion may increase short-term duplicate/provisional records.
  - Mitigation: scheduled reconciliation with stronger criteria and clear UI/state labeling.
- Risk: delayed canonicalization can affect downstream joins.
  - Mitigation: expose provisional state and keep deterministic correlation keys.
- Risk: migration complexity if new evidence state is persisted.
  - Mitigation: phased rollout with backfill and audit logging.

## Migration Plan
1. Introduce new evidence/promotion rules behind configuration guardrails.
2. Backfill existing identifiers/evidence into new classification where needed.
3. Enable strict merge gates in staging/demo and monitor merge_audit/identity drift metrics.
4. Roll out to production with rollback toggles for promotion thresholds.

## Open Questions
- Which exact corroboration set is mandatory for promotion in v1 (for example `agent_id`, serial, chassis-id, management-IP stability)?
- Should provisional devices be first-class in UI/API now or hidden by default?
- Do we need a dedicated `identity_evidence` table vs metadata on existing resources?
