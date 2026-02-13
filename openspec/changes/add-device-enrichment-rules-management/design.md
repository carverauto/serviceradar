## Context
Device classification quality depends on heterogeneous SNMP behavior. In production data, `sysObjectID` can be ambiguous for Ubiquiti and `ipForwarding` is not always a strict discriminator. We need a stable default classifier and a safe operator override path.

## Goals / Non-Goals
- Goals:
- Provide a deterministic rules engine for vendor/type enrichment.
- Support user override rules via mounted YAML files.
- Surface rule management in Settings UI with validation and preview.
- Persist classification provenance for audit/debug.
- Non-Goals:
- Implement full MIB-to-semantic inference for all vendors in this change.
- Add hot-reload without restart (initial release uses startup load + optional manual reload action).

## Decisions
- Decision: Layered rule sources.
- Built-in defaults ship with core (read-only). User rules load from `/var/lib/serviceradar/rules/device-enrichment/*.yaml`.
- Alternatives considered: DB-only rules first; rejected for bootstrap complexity and harder GitOps-style ops.

- Decision: Deterministic merge by `rule_id` and `priority`.
- Merge order is built-in then filesystem overrides; same `rule_id` in override replaces built-in.
- Alternatives considered: append-only merge; rejected because operators need to modify/disable defaults safely.

- Decision: Rules output normalized OCSF fields + provenance.
- Rule actions set `vendor_name`, `model`, `type`, `type_id`, and metadata fields:
  - `classification_source`
  - `classification_rule_id`
  - `classification_confidence`
  - `classification_reason`
- Alternatives considered: deriving provenance from logs only; rejected due to poor UI/debug visibility.

- Decision: UI writes managed rule files and validates server-side before activation.
- UI operations produce YAML under the configured rules directory and require successful validation before save.
- Alternatives considered: client-side-only validation; rejected due to drift from runtime parser.

## Risks / Trade-offs
- Risk: Bad user rule can over-classify devices.
- Mitigation: schema validation, dry-run preview, confidence floors, and rule simulation on sample payloads.

- Risk: File permissions/mount semantics differ across Docker/K8s.
- Mitigation: documented mount contract, startup diagnostics, and fallback to built-ins.

- Risk: Restart-required behavior slows tuning loops.
- Mitigation: include an admin-triggered reload action as optional phase-2 task.

## Migration Plan
1. Introduce loader + validator and built-in default rule pack.
2. Wire rules engine into ingestion, preserving current heuristics as default rules.
3. Add provenance metadata fields and UI rendering.
4. Add Settings UI management + import/export.
5. Document Helm/Compose mount setup and rollout guidance.

## Open Questions
- Should UI-edited rules persist to filesystem only, DB only, or dual-write with filesystem export?
- Should reload remain restart-only in v1, or include a guarded runtime reload endpoint immediately?
