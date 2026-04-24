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
- Decision: Introduce explicit role inference (`router`, `ap_bridge`, `switch_l2`, `host`, `unknown`) for discovery alias policy.
  - Rationale: router interface IPs are often true self-owned aliases, while AP/bridge interface observations can include client artifacts that should not mutate canonical alias state.
- Decision: Apply alias policy by inferred role, with confidence thresholds.
  - Rationale: role-aware policy preserves valid router aliases and blocks AP/bridge alias pollution without requiring hard-coded vendor logic.
- Decision: Preserve filtered AP/bridge client-like IP observations as endpoint discovery candidates.
  - Rationale: filtered observations remain operationally useful for inventory discovery even when excluded from alias state.

## Role Inference Strategy
- Inputs (ordered by trust):
  - Stable interface pattern on the same management `device_ip`.
  - Interface type/kind mix (`if_type`, `interface_kind`, bridge/tunnel/virtual density).
  - SNMP metadata hints (`sys_object_id`, vendor/model keywords, routing capability hints).
  - Topology behavior (upstream/downstream neighbor characteristics where available).
- Scoring:
  - Compute per-role score (0-100) and select top role if score >= threshold.
  - Below threshold, classify as `unknown`.
  - Persist `device_role`, `device_role_confidence`, and `device_role_source`.
- Initial policy mapping:
  - `router`: allow self-interface `ip_addresses` alias promotion.
  - `ap_bridge`, `switch_l2`: management IP alias only; block client-like interface alias promotion.
  - `host`, `unknown`: conservative management-IP-first policy.

## Alias and Candidate Policy
- Alias promotion candidate set:
  - Restrict candidate extraction to records tied to selected management `device_ip`.
  - Deduplicate and validate IP format before alias evaluation.
- Router path:
  - Promote interface IP aliases that are consistently observed and tied to same management context.
- AP/bridge path:
  - Do not promote client-like interface IPs to aliases.
  - Emit those IPs to endpoint discovery candidate flow for normal dedup/creation.
- Safety:
  - Never let role-filtered alias evidence trigger alias-conflict merges by itself.

## Alternatives considered
- Keep interface MAC registration as strong identifiers with confidence weighting only.
  - Rejected: still allows deterministic but wrong merges when evidence is noisy.
- Disable mapper-based device creation entirely.
  - Rejected: loses visibility and delays topology utility.
- Make merges fully manual.
  - Rejected: operationally expensive and regresses automation value.
- Infer role from vendor/model only.
  - Rejected: too brittle and incomplete across heterogeneous networks.
- Drop filtered AP/bridge client observations.
  - Rejected: throws away useful discovery signal that should feed endpoint discovery.

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
5. Phase role-aware alias policy:
   - Phase A: classify and log only (no behavior changes).
   - Phase B: enforce role-aware alias promotion.
   - Phase C: enable candidate endpoint promotion for filtered AP/bridge IPs.

## Open Questions
- Which exact signals are mandatory for `router` confidence >= threshold in v1?
- What rate limits should apply to AP/bridge client candidate promotion to avoid flood during large scans?
- Should provisional devices be first-class in UI/API now or hidden by default?
- Do we need a dedicated `identity_evidence` table vs metadata on existing resources?
