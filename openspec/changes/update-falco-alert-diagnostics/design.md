## Context
ServiceRadar ingests Falco logs, promotes critical detections into OCSF events, and escalates repeated events through stateful alert rules. The current incident alert includes stateful rule metadata such as `rule_id`, `group_key`, `window_count`, and `source_event_id`, but the details that operators need most are left in raw Falco payloads or require manual correlation:

- Falco `output_fields` such as `proc.name`, `proc.cmdline`, `proc.cwd`, `proc.exe`, `proc.pname`, `evt.arg.flags`, `container.id`, `k8s.pod.name`, and `k8s.ns.name`.
- Aggregated window context such as first/last seen, representative examples, and top process/container summaries.
- Runtime attribution gaps, such as nested Docker/Forgejo runner containers where Falco reports a container id but cannot directly map to a Kubernetes pod.

The incident that motivated this change was ultimately traced to a Forgejo Actions lint job running Go compiler/assembler processes inside a nested container. That conclusion was not visible from the alert itself.

## Goals
- Make event and alert details actionable from the UI/API without requiring direct SQL or cluster access.
- Preserve normalized fields for machine use while retaining raw Falco payloads for audit/debugging.
- Make stateful alerts explain why they fired and what representative source events contributed.
- Handle partial attribution explicitly instead of presenting empty Kubernetes fields as if no workload context exists.

## Non-Goals
- Changing Falco rule logic or severity mapping.
- Suppressing CI/build detections by default.
- Building a full forensic timeline or host process recorder.
- Performing expensive live Kubernetes/container runtime lookups on every alert detail request.

## Decisions
- Normalize Falco runtime context at promotion time into stable OCSF metadata/unmapped substructures. This keeps later stateful alert evaluation independent of raw string parsing.
- Store stateful alert diagnostic summaries on the generated alert event. The summary is bounded and sample-based, not a complete copy of every source event in the window.
- Use explicit attribution status fields, for example `attribution.status = "resolved" | "partial" | "missing" | "inferred"`, so the UI can distinguish known Kubernetes context from nested-runtime gaps.
- Prefer source event ids and aggregate samples over large raw payload blobs in alert metadata. Raw source records remain queryable through the existing observability storage path.

## Risks / Trade-offs
- More metadata increases event row size. Mitigation: store bounded summaries and short samples, not full windows.
- Falco output fields can vary by rule and version. Mitigation: normalize known fields opportunistically and preserve the original payload.
- Nested runtime attribution may be incomplete. Mitigation: expose the container id, host, cwd, command, and an attribution status rather than silently dropping context.

## Migration Plan
- New events and alerts receive enriched metadata after implementation.
- Existing historical alerts continue to render with a fallback raw metadata view.
- No database backfill is required for the initial change.

## Open Questions
- Should CI/build namespaces get an explicit default annotation or rule policy to classify expected build-tool executions as lower-priority after this diagnostic work lands?
- Should operator-facing exports include the full contributing event id list, or only bounded representative samples plus counts?
