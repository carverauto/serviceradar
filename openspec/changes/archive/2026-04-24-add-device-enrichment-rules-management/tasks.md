## 1. Core Rules Engine
- [x] 1.1 Add built-in default enrichment rules (including Ubiquiti router/switch/AP cases observed in production).
- [x] 1.2 Implement YAML schema + parser for filesystem rules under `/var/lib/serviceradar/rules/device-enrichment/`.
- [x] 1.3 Implement deterministic merge/precedence (`builtin` then `filesystem`, override by `rule_id`, then `priority`).
- [x] 1.4 Implement strict validation with actionable error messages and startup diagnostics.
- [x] 1.5 Add unit tests for parser, matcher, precedence, and invalid rule handling.

## 2. Ingestion Integration
- [x] 2.1 Replace hardcoded enrichment branches in sync ingestion with rule-engine evaluation.
- [x] 2.2 Populate classification provenance metadata (`classification_source`, `classification_rule_id`, `classification_confidence`, `classification_reason`).
- [x] 2.3 Preserve safe fallback to built-in defaults when filesystem rules are unavailable or invalid.
- [x] 2.4 Add integration tests covering Ubiquiti ambiguous sysObjectID cases (`.1.3.6.1.4.1.8072.3.2.10`) and `sys_name`/`sys_descr` disambiguation.

## 3. Settings UI
- [x] 3.1 Add Settings page for Device Enrichment Rules list/detail.
- [x] 3.2 Add create/edit/delete/enable/disable and priority ordering controls.
- [x] 3.3 Add server-side validation preview and effective-match simulation for sample payload input.
- [x] 3.4 Add import/export of rules as YAML and rule provenance display in device detail/list views.
- [x] 3.5 Add LiveView tests for management workflows and permission checks.

## 4. Deployment & Ops
- [x] 4.1 Document Docker Compose bind-mount pattern for rules path.
- [x] 4.2 Document Helm/Kubernetes mount patterns (ConfigMap/Secret/PVC) for rules path.
- [x] 4.3 Add startup health/logging messages that report loaded rule count and source.
- [x] 4.4 Define and document rollback procedure (disable override mount to return to built-ins).
