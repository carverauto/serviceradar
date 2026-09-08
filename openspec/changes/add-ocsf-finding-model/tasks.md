## 1. Schema And Resources
- [ ] 1.1 Add an Elixir migration for `platform.ocsf_findings` with common indexed columns, full OCSF payload JSONB, class-specific JSONB, and source/entity references.
- [ ] 1.2 Add `finding_info_uid` or equivalent reference columns/indexes for finding-producing `platform.ocsf_events` rows.
- [ ] 1.3 Add Ash resource/domain support for findings without introducing app-level multitenancy bypasses.
- [ ] 1.4 Add schema tests for required indexes, constraints, and `platform` prefix usage.

## 2. OCSF Builders
- [ ] 2.1 Add OCSF finding builders for classes 2002, 2003, 2004, 2005, 2006, and 2007 using OCSF 1.9.0-dev required/recommended fields.
- [ ] 2.2 Add deterministic finding identity builders per source and class.
- [ ] 2.3 Extract shared Falco decomposition used by direct processing and log promotion.
- [ ] 2.4 Structure Falco MITRE tags into ATT&CK tactic/technique `attacks` and supporting evidence on detection findings.

## 3. Producer Mapping
- [ ] 3.1 Make Falco warning-and-higher signals upsert detection findings and emit referencing events.
- [ ] 3.2 Make Trivy findings upsert vulnerability findings and emit referencing events.
- [ ] 3.3 Make endpoint-inventory vulnerability matches upsert vulnerability findings and emit referencing events.
- [ ] 3.4 Audit Bumblebee outputs and map each producer path to detection or vulnerability findings with tests.
- [ ] 3.5 Keep DNS activity, scan activity, health events, and job lifecycle events as events, not findings.

## 4. Migration And Compatibility
- [ ] 4.1 Choose and document the historical migration strategy: bounded backfill or forward-only.
- [ ] 4.2 Implement the chosen migration path and dashboard compatibility window.
- [ ] 4.3 Add regression coverage for repeat observations updating an existing finding instead of creating duplicate active findings.

## 5. SRQL And UI
- [ ] 5.1 Move SRQL `in:security_findings` to the canonical findings table and expose filtering by class, source, severity, status, entity, and time.
- [ ] 5.2 Add a drilldown query/path for events related to one finding.
- [ ] 5.3 Update the web-ng security dashboard frames and detail links for finding-shaped rows.
- [ ] 5.4 Add tests covering Falco detection, vulnerability finding, incident grouping, and related-event drilldowns.

## 6. Validation
- [x] 6.1 Run `openspec validate add-ocsf-finding-model --strict`.
- [ ] 6.2 Run focused Elixir, SRQL, and web-ng tests for touched implementation files after proposal approval and implementation.
- [ ] 6.3 Update this checklist only after each implementation task is actually complete.
