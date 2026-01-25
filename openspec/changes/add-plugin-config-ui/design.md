## Context
Plugin authors need a way to describe configuration fields for their checks without embedding UI code. The web UI is Phoenix LiveView, so the safest approach is schema-driven form rendering.

## Goals / Non-Goals
- Goals:
  - Generate LiveView forms from a plugin-provided schema.
  - Validate and apply defaults server-side before assignments are saved.
  - Keep UI consistent and secure (no custom JS/HTML injection).
- Non-Goals:
  - Arbitrary custom UI code or custom JS per plugin.
  - Full JSON Schema draft support on day one (start with a supported subset).

## Decisions
- Decision: Use JSON Schema as the UI contract (`config_schema`) bundled with the plugin package.
  - Rationale: widely adopted, maps cleanly to forms, supports validation.
- Decision: Implement a supported schema subset and document it.
  - Initial subset: `type`, `title`, `description`, `default`, `enum`, `minimum`, `maximum`, `minLength`, `maxLength`, `pattern`, `format` (uri, email), `items` (arrays), `required`, `properties`, `additionalProperties: false`.
- Decision: Validate with `ex_json_schema` (or equivalent) on save; persist validated config JSON.

## Risks / Trade-offs
- Risk: Schema subset gaps frustrate plugin authors.
  - Mitigation: publish supported subset in docs and extend incrementally.
- Risk: Large/complex schemas impact render performance.
  - Mitigation: enforce max schema size and depth, paginate/accordion sections if needed.

## Migration Plan
- Existing plugin packages without a schema continue to use the generic key/value config editor.
- New packages can include `config_schema` to unlock dynamic UI.

## Open Questions
- Do we need a `ui_schema` (layout hints) alongside JSON Schema in a later phase?
- Should we version the schema support (e.g., `schema_version`) in manifests?
