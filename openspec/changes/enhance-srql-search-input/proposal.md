# Change: Add catalog-aware autocompletion and inline validation to the shared SRQL search input

## Why

The shared `srql_query_bar` in the navbar (and every reuse of compact `srql_editor`) is a plain `<input>` backed only by a `<datalist>`. Users get no real autocomplete cycling, no inline feedback when they mistype `in:device` instead of `in:devices`, and no way to discover the valid values behind a token they've already typed. The catalog at `lib/serviceradar_web_ng_web/srql/catalog.ex` already knows every entity, field, and control token — that knowledge is currently invisible at the point of typing.

PR #3414 (`fix-srql-dashboard-authoring-ux`, merged 2026-05-26) tried to solve this by mounting Monaco in the navbar. The result hijacked the input's visual affordance — turning a single-line search bar into a multi-line code editor — and was rolled back so Monaco is only used in opt-in rich mode (dashboard panel authoring, MTR profile editor). The navbar deliberately fell back to plain `<input>` + `<datalist>`, leaving the original UX gap unsolved.

We need search-bar intelligence without breaking the search-bar look.

## What Changes

- **Add a catalog-aware autocomplete overlay** to compact `srql_editor`, driven by a Phoenix Hook + vanilla JS (no Monaco, no React in the navbar bundle). Tab/Enter accept, Esc dismisses, arrows navigate. The underlying `<input>` keeps its current geometry, font, and DaisyUI styling — the dropdown is an absolutely-positioned sibling.
- **Add inline catalog validation** that draws a squiggly underline under any catalog-recognized token whose value isn't in the catalog (e.g. `in:device` flagged, `in:devices` clean). Rendered via an overlay `<div>` mirroring the input's text — the input itself stays a plain `<input>` for accessibility and copy/paste.
- **Add click-token editing**: clicking on an already-typed token (e.g. the `devices` in `in:devices`) opens the same autocomplete dropdown scoped to valid alternatives for that token's role (entity slot, field slot, operator slot, value slot).
- **Add a token-role-aware tokenizer** in JS so the hook knows whether the cursor sits in an entity slot (after `in:`), a field slot (after `where ` / standalone), an operator slot, or a value slot — and filters completions accordingly.
- **Add `GET /api/srql/catalog`** that serves a structured JSON catalog (entities, per-entity fields with categories, control tokens, operator inventory) with ETag-based caching so the hook doesn't carry the catalog on every page render and updates transparently when `catalog.ex` changes.
- **Add a lightweight popover for token help** (description, valid values preview) anchored to the focused token — same overlay primitive as the dropdown, no extra positioning library by default.
- **Keep Monaco exactly where it is** in rich mode (`@rich=true` editor, self-authored dashboards, MTR profiles). No changes to the rich path.
- **Preserve the existing `<datalist>` fallback** so pre-hook hydration and non-JS contexts still work.

## Impact

- **Affected specs:**
  - `srql` — new requirements covering the search input's autocomplete, validation, click-edit interaction, and the `/api/srql/catalog` JSON contract.
  - `build-web-ui` — new requirement constraining the compact SRQL input's visual contract (look-and-feel preservation) so future PRs can't regress what #3414 just unwound.
- **Affected code:**
  - `elixir/web-ng/lib/serviceradar_web_ng_web/components/srql_components.ex` — compact branch wires the new hook and a sibling overlay div; rich branch unchanged.
  - `elixir/web-ng/lib/serviceradar_web_ng_web/srql/catalog.ex` — new public functions exporting the structured catalog (entities → fields-by-category, control tokens, operators) for the JSON endpoint.
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/srql_catalog_controller.ex` (new) + router entry — serves `/api/srql/catalog` with ETag.
  - `elixir/web-ng/assets/js/hooks/srql_input.js` (new) — vanilla-JS Phoenix Hook implementing tokenizer, dropdown, squiggly overlay, click-edit.
  - `elixir/web-ng/assets/js/lib/srql/tokenizer.js` (new) — pure tokenizer reused by hook and any future caller.
  - `elixir/web-ng/assets/js/app.js` — register the new hook.
  - Tests: a property test for the tokenizer; a Playwright smoke test for the hook behavior in the navbar.
- **Non-goals:**
  - Server-side SRQL grammar validation (the existing Rust NIF still owns query parsing; the hook only does catalog-level token validation).
  - Replacing Monaco anywhere it already runs.
  - Cross-tenant catalog filtering — the catalog is the same shape across tenants today; multi-tenant catalog scoping is a separate proposal.
