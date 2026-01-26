## Context
Plugin authors need a way to describe configuration fields for their checks without embedding UI code. The web UI is Phoenix LiveView, so the safest approach is schema-driven form rendering.

## Goals / Non-Goals
- Goals:
  - Generate LiveView forms from a plugin-provided schema.
  - Validate and apply defaults server-side before assignments are saved.
  - Keep UI consistent and secure (no custom JS/HTML injection).
  - Render plugin-specific result views on the Services page without custom JS/HTML.
  - Allow plugins to declare UI schema versions for forward compatibility.
- Non-Goals:
  - Arbitrary custom UI code or custom JS per plugin.
  - Full JSON Schema draft support on day one (start with a supported subset).

## Decisions
- Decision: Use JSON Schema as the UI contract (`config_schema`) bundled with the plugin package.
  - Rationale: widely adopted, maps cleanly to forms, supports validation.
- Decision: Implement a supported schema subset and document it.
  - Initial subset: `type`, `title`, `description`, `default`, `enum`, `minimum`, `maximum`, `minLength`, `maxLength`, `pattern`, `format` (uri, email), `items` (arrays), `required`, `properties`, `additionalProperties: false`.
- Decision: Validate with `ex_json_schema` (or equivalent) on save; persist validated config JSON.
- Decision: Store `config_schema` on the plugin package/version as a `:map` and validate via Ash changes or calculations before save.
- Decision: Define a plugin result display contract (schema + widget hints) used by LiveView to render custom results.
  - Rationale: lets plugins enrich the Services view while preserving security and UI consistency.
- Decision: Use a “widget instruction” model backed by a server-side component registry.
  - Rationale: plugins send UI intent, not HTML/JS, preventing XSS and keeping styling consistent.
- Decision: Treat unknown/unsupported widgets as no-ops and log a warning.
- Decision: Start with a minimal widget set: status badge, stat card, table, markdown (sanitized), sparkline.
- Decision: Support a simple `layout` hint per widget instruction (e.g., `full`, `half`) instead of a full `ui_schema`.
- Decision: Add `schema_version` in plugin manifests to version the UI contract.

## Risks / Trade-offs
- Risk: Schema subset gaps frustrate plugin authors.
  - Mitigation: publish supported subset in docs and extend incrementally.
- Risk: Large/complex schemas impact render performance.
  - Mitigation: enforce max schema size and depth, paginate/accordion sections if needed.
- Risk: Result rendering contract becomes too rigid for some plugins.
  - Mitigation: ship a small set of common widgets (table, list, stat, status) and extend as needed.
- Risk: Accidental rendering of unsafe content.
  - Mitigation: never use raw HTML, enforce CSP, and sanitize any optional markdown/links before rendering.

## Migration Plan
- Existing plugin packages without a schema continue to use the generic key/value config editor.
- New packages can include `config_schema` to unlock dynamic UI.
- Services page falls back to the generic result view if no plugin display contract is provided.

## Open Questions
- Do we need a `ui_schema` (layout hints) alongside JSON Schema in a later phase?
- Should we version the schema support (e.g., `schema_version`) in manifests?
- What is the minimal widget set to support initial plugin result rendering?
- Which CSP enforcement mechanism should we standardize on (`put_secure_browser_headers` vs `plug_csp`)?
- Do we need a separate `display_schema` vs `display_instructions` for results, or can we reuse a single contract?
