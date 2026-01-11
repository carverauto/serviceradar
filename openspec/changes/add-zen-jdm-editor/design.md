## Context
Zen rules are currently built via template + builder_config and a modal-driven UI. Users cannot see or edit the rule JSON (JDM) that powers GoRules, and “presets” are a separate editor that doesn’t represent the real rule. We want a direct editor for Zen rules with canvas + JSON, embedded in Phoenix LiveView via React.

## Goals / Non-Goals
- Goals:
  - Provide a canvas + JSON editor for Zen rules that edits the actual JDM stored per rule.
  - Allow users to create new rules and new rule types (library items) from scratch.
  - Keep rules tenant-scoped and respect RBAC (operator/admin write access).
  - Preserve existing default rules and migrate them into editable JDM definitions.
- Non-Goals:
  - Extending the editor to promotion/stateful rules in this change.
  - Building a full visual rule library manager beyond the minimum UX to create/edit/clone rule definitions.

## Decisions
- **React embedding**: Use `phoenix_react_server` to render the GoRules JDM editor and hydrate it on the client. This keeps React isolated in assets while letting LiveView own routing/auth/tenant scope.
- **Data model**: Store the JDM definition on Zen rules as a first-class JSON field (new attribute, e.g. `definition`/`jdm`). Existing `compiled_jdm` becomes the synced KV payload; when a JDM definition is present it is validated and used directly.
- **Rule library**: Keep a tenant-scoped library of reusable rule types (renamed from “templates” in the UI). Each library item stores JDM JSON and metadata. Rules can be created from scratch or cloned from a library item.
- **UI layout**: Replace modal editors with a two-pane screen: left list of rules + library, right editor workspace with canvas/JSON toggle and metadata form.

## Alternatives considered
- **Keep templates/presets UI**: rejected; doesn’t expose real rule JSON and hides rule composition.
- **JSON-only editor**: rejected; harder to understand and less approachable for operators.
- **LiveView-only canvas**: rejected; the GoRules editor already exists and should be reused.

## Risks / Trade-offs
- **React integration complexity**: requires asset bundling and hydration; mitigated by using phoenix_react_server and isolating the React mount.
- **Migration correctness**: existing template-based rules must map cleanly into JDM; mitigated by compiling the existing template + builder_config into a JDM definition and validating before writing.
- **RBAC confusion**: editor must clearly separate read-only vs edit mode; mitigated by role checks in LiveView and API.

## Migration Plan
1. Add a new `jdm_definition` (or similar) attribute to ZenRule and ZenRuleTemplate (library) resources.
2. Backfill JDM definitions by compiling existing template + builder_config into JDM.
3. Update sync: KV uses `jdm_definition` if present; fall back to compiled output while migrating.
4. Update UI to read/write `jdm_definition` and remove preset modals.

## Open Questions
- Final attribute naming (`jdm_definition` vs `definition`) and whether `compiled_jdm` remains stored.
- Whether “rule types” should be stored as a separate resource or as tagged Zen rules.
