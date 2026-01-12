## Context
The sweep target criteria builder currently models filters as a flat map, which only represents AND semantics. Users who need OR logic (for example "tags has any" across values or combining IP ranges) must write raw SRQL. The SRQL parser does not explicitly document OR group handling, and the builder's operator coverage is narrower than the SRQL language.

## Goals / Non-Goals
- Goals:
  - Support OR grouping in SRQL with clear, minimal syntax.
  - Keep the builder UI simple (no complex boolean editor).
  - Preserve existing criteria payloads without breaking stored data.
  - Align builder operators with SRQL capabilities for devices.
- Non-Goals:
  - Full boolean expression editing (arbitrary nesting UI).
  - Changing SRQL pipeline semantics (`|`) or existing query patterns.

## Decisions
- SRQL grouping syntax: use parentheses containing clauses separated by the `OR` keyword (case-insensitive). Whitespace between clauses outside parentheses continues to mean AND. Parentheses may be nested in the parser, but the builder will generate only one-level groups.
- Criteria payload: represent criteria as a list of groups, each with a `match` mode (`any` or `all`) and a list of rules. Existing flat criteria maps are normalized into a single `all` group on load.
- Builder UX: add a "Match any/all" toggle per group plus an "Add group" action. Default remains a single "Match all" group to preserve the existing UX for common cases.
- Field/operator catalog: the builder will use an explicit allowlist for device fields and operators (tags, IP CIDR/range, list membership, numeric comparisons) to generate SRQL safely.

## Risks / Trade-offs
- Adding OR grouping increases parser and planner complexity. Mitigation: keep the grammar narrow (parentheses + OR) and add targeted tests.
- Criteria migration could introduce ambiguity. Mitigation: treat existing maps as a single group and keep serialization deterministic.

## Migration Plan
1. Normalize existing criteria maps to grouped format in the UI when editing.
2. Persist grouped criteria going forward (while keeping backward-compatible parsing for existing configs).
3. Update SRQL examples in docs to show grouped OR usage.

## Open Questions
- Should OR outside parentheses be accepted, or rejected to avoid ambiguity?
- Do we want to allow nested groups in the builder UI later (parser can support it now)?
