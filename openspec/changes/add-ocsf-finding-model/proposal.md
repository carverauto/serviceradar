# Change: Add OCSF Finding Model

## Why
ServiceRadar currently treats security "findings" as rows in `ocsf_events`. That loses the OCSF distinction between a durable, stateful finding and the events that create or update it, which makes Falco, Trivy, endpoint inventory, and future security sources hard to deduplicate, close, correlate, and explain.

## What Changes
- **BREAKING**: Introduce `platform.ocsf_findings` as the canonical stateful security finding store and move `in:security_findings` to read findings instead of event-shaped rows.
- Keep `platform.ocsf_events` as the occurrence/activity stream for finding producers other than Falco; event rows that create, update, or close findings SHALL reference the finding via `finding_info.uid`. Falco occurrence storage is owned by `add-falco-runtime-findings`.
- Model the OCSF 1.9.0-dev finding classes 2002 through 2007: vulnerability, compliance, detection, incident, data security, and application security posture findings.
- Map existing security producers to finding classes: Falco to detection findings, Trivy/advisory/package matches to vulnerability findings, stateful alert groups to incident findings, and future compliance/data/application posture sources to their native classes.
- Structure Falco MITRE ATT&CK tags into OCSF detection-finding `attacks` and evidence instead of keeping them only as raw diagnostic metadata.
- Update SRQL and the security dashboard so operators see deduplicated active findings with drilldown to related occurrences.

## Impact
- Affected specs: `observability-signals`, `srql`, `build-web-ui`
- Affected code: Elixir migrations/Ash resources under `elixir/serviceradar_core`, event writer processors, Falco log promotion, Trivy and endpoint inventory ingestion, `rust/srql`, web-ng security dashboard and detail routes, tests/fixtures
- Data impact: new `platform` schema table/indexes and a backfill or forward-only migration decision for existing finding-shaped `ocsf_events`. Falco is forward-only.

## Coordination
- `add-falco-runtime-findings` lands first and creates `platform.ocsf_findings` (and `finding_info_uid` on `ocsf_events`) using this change's planned schema, so neither change blocks the other. This change then adds its remaining producers (Trivy, advisory and endpoint-inventory vulnerability findings, incident findings, Bumblebee) and the `in:security_findings` move onto the existing table instead of creating it.
- The Falco mapping (shared decomposition, ATT&CK `attacks`, detection findings) is delivered by `add-falco-runtime-findings`, which keys Falco findings on (subject entity, rule) rather than container dimensions.
- Falco occurrences are stored in `runtime_security_occurrences`, not as per-occurrence `ocsf_events` or `logs` rows. Only lifecycle transitions are Falco rows in `ocsf_events`. This change's backfill decision does not include Falco.
