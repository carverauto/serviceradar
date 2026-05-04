## 1. Event Enrichment
- [ ] 1.1 Add Falco fixture coverage for `Drop and execute new binary in container` events with process, container, host, and missing Kubernetes fields.
- [ ] 1.2 Normalize Falco `output_fields` into structured event metadata for process, parent process, user, executable flags, container, Kubernetes, host, and attribution status.
- [ ] 1.3 Preserve raw Falco payloads and source log provenance while exposing normalized fields through event queries.

## 2. Stateful Alert Diagnostics
- [ ] 2.1 Extend stateful alert evaluation to build bounded diagnostic summaries for the firing window.
- [ ] 2.2 Include rule id/name, group keys, threshold/window settings, occurrence counts, first/last seen, representative event ids, and top process/container samples in generated alert events.
- [ ] 2.3 Add tests that a Falco critical event burst creates one diagnostic-rich incident instead of requiring raw JSON or SQL correlation.

## 3. UI/API Surfaces
- [ ] 3.1 Update event detail APIs and serializers to expose normalized Falco diagnostics.
- [ ] 3.2 Update alert detail APIs and serializers to expose stateful diagnostic summaries and source provenance.
- [ ] 3.3 Update web-ng event and alert detail views to show process, command, cwd, executable flags, host, container/workload attribution, rule/window summary, and source samples.
- [ ] 3.4 Render partial/missing Kubernetes attribution explicitly so nested container runtime alerts are not misread as host-only or unknown.

## 4. Validation
- [ ] 4.1 Add focused Elixir tests for promotion, stateful aggregation, and serializers.
- [ ] 4.2 Add focused web-ng tests or LiveView component tests for enriched event/alert details.
- [ ] 4.3 Run `./scripts/elixir_quality.sh --project elixir/serviceradar_core` for core changes.
- [ ] 4.4 Run `./scripts/elixir_quality.sh --project elixir/web-ng --phoenix` for web-ng changes.
