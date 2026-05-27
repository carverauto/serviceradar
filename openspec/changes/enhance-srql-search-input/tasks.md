## 1. Catalog endpoint

- [x] 1.1 Add `Catalog.structured/0` in `lib/serviceradar_web_ng_web/srql/catalog.ex` returning entities → categorized field lists, control tokens, and operators
- [x] 1.2 Derive a stable ETag (sha256 of canonical JSON) and memoize per BEAM-process via `:persistent_term`
- [x] 1.3 Add `SrqlCatalogController.show/2` returning JSON with `ETag` + `Cache-Control: private, max-age=300, must-revalidate` and 304 on conditional `If-None-Match`
- [x] 1.4 Mount `GET /api/srql/catalog` under the authenticated API pipeline in the router
- [x] 1.5 Tests: controller test for 200 + ETag, conditional 304, 401 unauthenticated, ETag-changes-when-catalog-changes

## 2. Tokenizer

- [x] 2.1 Add `assets/js/lib/srql/tokenizer.js` exporting `tokenize(query, cursor) → { tokens, activeToken, slot }`
- [x] 2.2 Define `Token { start, end, kind, text }` where `kind ∈ {control, entity, field, value, op, unknown}`
- [x] 2.3 Define `slot ∈ {entity, field, op, value, control, none}` derived from preceding tokens
- [x] 2.4 Jest/vitest unit tests covering: empty input, `in:` slot, `where ` field slot, value slot, quoted values, mid-token cursor, trailing whitespace, multi-clause `in:devices hostname:srv ip:10.`
- [ ] 2.5 Property test (StreamData-driven Elixir test that shells out, or pure JS fast-check) confirming the tokenizer's slot inference matches the Rust NIF parser for known-good inputs

## 3. Phoenix Hook + overlay

- [x] 3.1 Add `assets/js/hooks/srql_input.js` exporting an `SRQLInput` hook
- [x] 3.2 On `mounted()`: fetch `/api/srql/catalog` (respecting `window.__srqlCatalog` cache keyed by ETag), wire input listeners (`input`, `keydown`, `click`, `blur`)
- [x] 3.3 Render a sibling overlay `<div>` with class `srql-input-overlay` positioned over the input, painting `<span class="srql-token--unknown">` segments for catalog-unknown tokens
- [x] 3.4 Render a dropdown `<ul>` positioned below the input on the active token's slot
- [x] 3.5 Implement keyboard handlers: Tab/Enter completes the highlighted candidate; ArrowUp/Down cycle; Esc dismisses; clicking a candidate selects it
- [x] 3.6 Implement click-token editing: clicking inside an existing token preselects it and opens the slot-scoped dropdown
- [x] 3.7 Implement hint popover for the focused token (shown on focus-within of a recognized token; lists role + accepted values when enumerable)
- [x] 3.8 Register `SRQLInput` in `assets/js/app.js` alongside the existing `SRQLEditor` hook (do not replace it)
- [ ] 3.9 Asset size budget: hook + tokenizer + dropdown styles ≤ 8 KB minified ungzipped (add to existing asset-size check)

## 4. Component wiring

- [x] 4.1 In `lib/serviceradar_web_ng_web/components/srql_components.ex`, attach `phx-hook="SRQLInput"` and the overlay wrapper to the compact branch only
- [x] 4.2 Keep the existing `<datalist>` element intact for pre-hydration fallback
- [x] 4.3 Ensure `autocorrect="off" autocapitalize="off" spellcheck="false"` are set on the compact input
- [x] 4.4 Verify rich branch (`@rich={true}` and non-compact textarea branch) is unchanged

## 5. Styling

- [x] 5.1 Add CSS for `.srql-input-overlay` mirroring the compact input's font, padding, line-height (colocated with the input class so they cannot drift)
- [x] 5.2 Add `.srql-token--unknown { text-decoration: wavy underline; text-decoration-color: var(--color-error); text-underline-offset: 2px; }`
- [x] 5.3 Add `.srql-dropdown` styles consistent with existing DaisyUI menu/dropdown look
- [ ] 5.4 Verify idle navbar input is pixel-identical to current implementation (visual diff snapshot)

## 6. Tests

- [x] 6.1 Playwright test: navbar input opens dropdown on Tab in `in:dev`, completes to `in:devices`
- [x] 6.2 Playwright test: typing `in:device` renders the `device` substring with class `srql-token--unknown`
- [x] 6.3 Playwright test: clicking on `devices` in `in:devices` opens the dropdown listing entities
- [x] 6.4 Regression test: rich mode (`@rich={true}`) still renders Monaco
- [x] 6.5 Visual regression / snapshot test: idle navbar input geometry matches baseline

## 7. Documentation

- [x] 7.1 Document the `/api/srql/catalog` endpoint shape in API docs; final spec update remains part of OpenSpec archive
- [x] 7.2 Add a short note to plugin/dashboard authoring docs that the catalog JSON is the canonical client-side reference
