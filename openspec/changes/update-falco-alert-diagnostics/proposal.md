# Change: Improve Falco alert diagnostics

Tracking issue: #3193

## Why
Falco-derived critical alerts currently preserve enough metadata to prove that a stateful rule fired, but not enough context for an operator to quickly decide whether the alert is an active compromise, expected CI/build activity, or another benign workload pattern. During incident triage for event `742fcf7a-599a-4d80-a314-3e148c0ada85`, the alert showed the rule, host, and aggregate count, but the useful diagnosis required manual database and Kubernetes correlation to recover process, command, container, CI job, and window details.

## What Changes
- Preserve normalized Falco runtime diagnostic context from `output_fields` on the runtime security occurrence: process identity, command line, cwd, executable path, parent process, user, executable flags, container identity, Kubernetes identity when available, host, and Falco rule metadata. Per-occurrence OCSF promotion and raw-record storage are owned by `add-falco-runtime-findings` (`runtime_security_occurrences`). This change does not require an OCSF event per Falco log.
- Enrich lifecycle alerts on `runtime_security.finding.*` with diagnostic summaries, including rule id/name, grouping keys, threshold/window/cooldown/renotify values, occurrence count, first/last seen times, representative source occurrence ids, top process/container/workload samples, and a provenance chain back to those occurrences. Alerting stays lifecycle-only, as specified by `add-falco-runtime-findings`.
- Add fallback correlation behavior for nested container runtimes where Falco lacks Kubernetes pod names, preserving container id prefixes and surfacing that Kubernetes workload attribution is unavailable or inferred.
- Update observability event and alert detail views to show the enriched diagnostic context without requiring raw JSON inspection.
- Add tests and fixtures for Falco occurrence diagnostics, lifecycle alert summaries, and UI detail rendering.

## Impact
- Affected specs: `observability-signals`, `build-web-ui`
- Affected code: Falco occurrence diagnostic fields and lifecycle alert summaries (`add-falco-runtime-findings` owns `runtime_security_occurrences` and `runtime_security.finding.*` alerting), `ServiceRadar.Observability.StatefulAlertEngine`, alert query APIs, web-ng detail views, tests/fixtures
- Operational impact: improves incident triage fidelity without changing Falco detection semantics or default alert thresholds
