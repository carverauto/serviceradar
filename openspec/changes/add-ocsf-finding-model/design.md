## Context
OCSF 1.9.0-dev defines finding classes under category `2` with create/update/close activities and a stable `finding_info` identity. ServiceRadar currently stores finding-like records as occurrences in `platform.ocsf_events`, so a repeated Falco rule or vulnerability match creates another event-shaped pseudo-finding instead of updating one durable finding.

The live OCSF schema API was checked for the six finding classes on 2026-06-12
using `https://schema.ocsf.io/api/1.9.0-dev/classes/<class>`. The implementation
must re-check these schemas before coding because `1.9.0-dev` can drift.

Use the official schema API directly when refreshing the snapshot:

```bash
for class in vulnerability_finding compliance_finding detection_finding incident_finding data_security_finding application_security_posture_finding; do
  curl -fsSL "https://schema.ocsf.io/api/1.9.0-dev/classes/$class" \
    | jq -r '[.attributes // {} | to_entries[] | select(.value.requirement == "required") | .key] | sort'
done
```

For recommended fields, use the same command with
`select(.value.requirement == "recommended")`. The required attribute list below
is the exact 2026-06-12 API output; the recommended column is the subset most
relevant to ServiceRadar's first implementation and should be refreshed against
the full live output before coding.

| Class | Required attributes | Implementation-relevant recommended attributes |
| --- | --- | --- |
| `vulnerability_finding` | `activity_id`, `category_uid`, `class_uid`, `cloud`, `finding_info`, `metadata`, `osint`, `severity_id`, `time`, `type_uid`, `vulnerabilities` | `confidence_id`, `impact`, `impact_score`, `is_alert`, `message`, `observables`, `resource`, `resources`, `src_url`, `status_id`, `verdict_id` |
| `compliance_finding` | `activity_id`, `category_uid`, `class_uid`, `cloud`, `compliance`, `finding_info`, `metadata`, `osint`, `severity_id`, `time`, `type_uid` | `confidence_id`, `impact`, `impact_score`, `is_alert`, `message`, `observables`, `remediation`, `resource`, `resources`, `src_url`, `status_id`, `verdict_id` |
| `detection_finding` | `activity_id`, `category_uid`, `class_uid`, `cloud`, `finding_info`, `metadata`, `osint`, `severity_id`, `time`, `type_uid` | `attacks`, `confidence_id`, `evidences`, `is_alert`, `message`, `observables`, `resources`, `src_url`, `status_id`, `verdict_id` |
| `incident_finding` | `activity_id`, `category_uid`, `class_uid`, `cloud`, `finding_info_list`, `metadata`, `osint`, `severity_id`, `status_id`, `time`, `type_uid` | `confidence_id`, `desc`, `device`, `impact`, `impact_score`, `is_alert`, `message`, `observables`, `src_url`, `status`, `verdict_id` |
| `data_security_finding` | `activity_id`, `category_uid`, `class_uid`, `cloud`, `finding_info`, `metadata`, `osint`, `severity_id`, `time`, `type_uid` | `actor`, `confidence_id`, `data_security`, `database`, `databucket`, `device`, `dst_endpoint`, `file`, `message`, `observables`, `resources`, `src_endpoint`, `status_id`, `table` |
| `application_security_posture_finding` | `activity_id`, `category_uid`, `class_uid`, `cloud`, `finding_info`, `metadata`, `osint`, `severity_id`, `time`, `type_uid` | `application`, `compliance`, `confidence_id`, `impact`, `impact_score`, `is_alert`, `message`, `observables`, `remediation`, `resources`, `src_url`, `status_id`, `vulnerabilities` |

## Goals
- Represent OCSF findings as durable state, not only event occurrences.
- Preserve the event stream for timelines, provenance, alerting, and audit trails.
- Deduplicate repeat observations deterministically using `finding_info.uid`.
- Keep queryable common columns for dashboard/SRQL performance while preserving full OCSF payload fidelity.
- Make source-specific mappings explicit enough to avoid another pseudo-finding path.

## Non-Goals
- Replacing `ocsf_events` for logs, DNS activity, scan activity, causal predictions, job lifecycle events, or other non-finding activity.
- Requiring every existing historical event to be perfectly backfilled before deployment if a documented forward-only transition is safer.
- Creating custom app-level multitenancy controls; all objects remain in the deployment `platform` schema.

## Decisions
- Decision: Use one `platform.ocsf_findings` table with common indexed columns and class-specific JSONB.
  Rationale: The six finding classes share enough shape for common filtering (`uid`, `class_uid`, `status_id`, `severity_id`, `confidence_id`, `risk_score`, `source`, `entity`, timestamps), while class-specific payloads differ and will evolve with OCSF. A single table avoids six parallel SRQL entities and keeps cross-class dashboard queries simple.

- Decision: Store canonical `finding_info.uid` as the logical primary key and keep a UUID surrogate only if local Ash patterns require it.
  Rationale: The OCSF identity is the stable deduplication key operators and events need. A surrogate can help Ash internals, but it must not become the public correlation key.

- Decision: Keep `ocsf_events` as append-only occurrence history and add a finding reference.
  Rationale: Events answer "what happened at time T"; findings answer "what is the current state of this logical security issue." Both are needed for timelines, stateful alerting, and audit.

- Decision: Compute finding identity per source from class plus stable dimensions.
  Rationale: Falco should key on rule/source/device/container dimensions; vulnerabilities should key on CVE/package/entity; incidents should key on the grouped constituent findings. This prevents both over-aggregation and duplicate churn.

- Decision: Map Falco MITRE tags into structured detection-finding `attacks` entries and supporting evidence.
  Rationale: OCSF 1.9.0-dev exposes both `attacks` and `evidences` on `detection_finding`; retaining ATT&CK IDs only in raw metadata prevents SRQL/UI filtering by tactic or technique.

## Migration Plan
1. Add the `ocsf_findings` schema and Ash resource in the `platform` schema.
2. Add a nullable finding reference to new finding-producing `ocsf_events` writes.
3. Refactor finding-producing processors to upsert a finding first, then emit an event referencing it.
4. Decide and document backfill strategy: derive findings from recent Falco/Trivy/endpoint-inventory events where the source payload is sufficient, or run forward-only with dashboard compatibility during retention.
5. Move SRQL `in:security_findings` to `ocsf_findings` and keep event drilldown through finding references.
6. Update web-ng dashboard frames and detail links in the same deployment as the SRQL cutover.

## Risks
- Breaking dashboard consumers of the current event-shaped `in:security_findings` payload.
  Mitigation: define a compact finding payload with compatibility aliases for the fields the current dashboard displays, and update dashboard code in lockstep.

- Overlap with pending Security page/dashboard proposals that introduce event-shaped security finding queries before this model lands.
  Mitigation: treat this change as the canonical follow-up that adds `in:security_findings` to the archived SRQL spec if it is still absent, then reconcile any pending dashboard query contracts during implementation.

- Incorrect deduplication can hide distinct security issues.
  Mitigation: source-specific identity builders must be covered by tests with repeated and distinct observations.

- OCSF schema drift in 1.9.0-dev.
  Mitigation: preserve full source/class payload JSONB and isolate OCSF builders so field changes are localized.

## Open Questions
- Should the initial migration backfill only the current retention window or run forward-only?
- Should closed findings remain in `ocsf_findings` indefinitely with retention on related events, or should findings have a separate retention policy?
- Should `trivy_findings` remain as a producer-specific raw table after vulnerability findings become canonical, or become implementation detail/history only?
