# Change: Add OCSF Finding Model

## Why
ServiceRadar currently treats security "findings" as rows in `ocsf_events`. That loses the OCSF distinction between a durable, stateful finding and the events that create or update it, which makes Falco, Trivy, endpoint inventory, and future security sources hard to deduplicate, close, correlate, and explain.

## What Changes
- **BREAKING**: Introduce `platform.ocsf_findings` as the canonical stateful security finding store and move `in:security_findings` to read findings instead of event-shaped rows.
- Keep `platform.ocsf_events` as the occurrence/activity stream; event rows that create, update, or close findings SHALL reference the finding via `finding_info.uid`.
- Model the OCSF 1.9.0-dev finding classes 2002 through 2007: vulnerability, compliance, detection, incident, data security, and application security posture findings.
- Map existing security producers to finding classes: Falco to detection findings, Trivy/advisory/package matches to vulnerability findings, stateful alert groups to incident findings, and future compliance/data/application posture sources to their native classes.
- Structure Falco MITRE ATT&CK tags into OCSF detection-finding `attacks` and evidence instead of keeping them only as raw diagnostic metadata.
- Update SRQL and the security dashboard so operators see deduplicated active findings with drilldown to related events.

## Impact
- Affected specs: `observability-signals`, `srql`, `build-web-ui`
- Affected code: Elixir migrations/Ash resources under `elixir/serviceradar_core`, event writer processors, Falco log promotion, Trivy and endpoint inventory ingestion, `rust/srql`, web-ng security dashboard and detail routes, tests/fixtures
- Data impact: new `platform` schema table/indexes and a backfill or forward-only migration decision for existing finding-shaped `ocsf_events`
