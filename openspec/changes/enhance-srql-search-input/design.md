# Design: Catalog-aware autocompletion and validation for the SRQL search input

## Context

The compact SRQL input (`srql_editor` with `compact={true}`) renders as a one-line `<input type="text">` followed by a `<datalist>` populated from `Catalog.completion_tokens/0`. Native `<datalist>` gives the user a passive dropdown with no cycling, no role-awareness, and no error feedback — typing `in:device` simply runs and returns an empty result.

The previous attempt (PR #3414) embedded Monaco in the navbar. Monaco's minimum visual footprint (gutter, multi-line viewport, scrollbar, completion list with its own theme) clashed with the navbar's compact, branded affordance. The team rolled it back to the plain input and kept Monaco for the rich editor where the editor *is* the page (dashboard panel SRQL authoring, MTR profile editor).

We want the catalog awareness without the visual takeover. The constraint is: the navbar input must remain visually indistinguishable from today's plain `<input>` at idle. All extra UI must be additive overlays anchored to it.

## Goals / Non-Goals

**Goals**

- Tab/Enter completion driven by the SRQL catalog, scoped to the slot the cursor sits in (entity / field / operator / value).
- Squiggly underline under any catalog-recognized token whose target value isn't a member of the catalog set for that slot.
- Click-to-edit: clicking any rendered token opens the slot-scoped picker for that token.
- Optional hint popover (description, allowed values preview) on hover/focus of a known token.
- Zero visual change at idle. Look-and-feel of the compact input must match the current `srql_editor` `compact` branch pixel-for-pixel until the user interacts with it.
- Pre-hook hydration must still produce a usable input (the `<datalist>` fallback path).

**Non-Goals**

- Full SRQL grammar validation in the browser. Grammar errors continue to surface through the existing server round-trip.
- Anything in the rich editor (Monaco). The rich path is untouched.
- A new editor abstraction shared with `<textarea>` mode. The hook attaches only to compact `<input>`s.
- Real-time cross-tenant catalog scoping; today's catalog is identical across tenants.

## Decisions

### Decision: Vanilla-JS Phoenix Hook layered over the existing `<input>`

We attach `phx-hook="SRQLInput"` to the compact `<input>` and inject a sibling `<div class="srql-input-overlay">` positioned absolutely behind the input. The overlay mirrors the input's text using the same font, padding, and line-height; squiggly underlines are rendered as `<span class="srql-token--unknown">` segments with a `text-decoration: wavy underline` style. The dropdown and hint popover are `position: absolute` siblings opened on demand.

**Why:** A Phoenix Hook is the established lightweight integration pattern in this codebase (existing `SRQLEditor`, `SRQLTimeCookie`, `DashboardBuilderCanvas` hooks). Vanilla JS keeps the navbar bundle small and avoids hydrating React on every page just to power one input. The "input + overlay mirror" technique is well-trodden (e.g., GitHub's mention autocomplete predates ContentEditable rewrites) and degrades gracefully to a plain input when JS fails.

**Alternatives considered**

- *Monaco everywhere*: rejected by PR #3414 — the original problem we're solving.
- *ContentEditable*: would let us render tokens as inline elements directly, but breaks `phx-change`, accessibility, and copy/paste semantics; also fights the browser's text selection model.
- *React component via phx-react-ng*: works but loads React into the navbar bundle for every authenticated page, costs ~40KB+ gzipped, and tempts feature creep. Reserved as the fallback if vanilla overlay rendering proves unmanageable for accessibility.
- *@floating-ui/dom for positioning*: ~5KB and would simplify collision/flip math, but a navbar input has a known anchor (always opens downward, never overflows the navbar horizontally). Stay vanilla; reach for floating-ui only if dropdown positioning becomes a real bug source.

### Decision: New `GET /api/srql/catalog` endpoint with ETag caching

Serves the structured catalog as JSON:

```json
{
  "entities": {
    "devices": {
      "fields": {
        "filter":   ["hostname", "ip", "mac", ...],
        "numeric":  ["latitude", "longitude"],
        "boolean":  ["is_available", "is_active"],
        "array":    ["discovery_sources", "tags"]
      }
    },
    "logs":  { "fields": { ... } },
    ...
  },
  "control_tokens": ["limit:", "sort:", "time:", "status:", "type:", "tag:", "site:", "where", "group:", "by:"],
  "operators": [":", ":contains", ":equals", ">", "<", ">=", "<="],
  "version": "sha256-of-catalog-bytes"
}
```

Response headers: `ETag: "<sha256>"`, `Cache-Control: private, max-age=300, must-revalidate`. The hook fetches on first navbar mount, stores the parsed catalog on `window.__srqlCatalog` keyed by ETag, and only re-fetches when a `srql:catalog-stale` LiveView push event fires (future-proofing) or the ETag changes on a conditional GET at next mount.

**Why:** The component currently serializes the full completion-token list into a `data-completions` attribute on every render. With per-slot completions, that JSON quadruples and ships on every page. An endpoint with ETag is cheaper on every page after the first, and gives the catalog a single canonical wire shape for any other consumer (the React JDM editor already needs it).

**Alternatives considered**

- *Inline data attribute (status quo, expanded)*: simplest, no endpoint, but loads catalog on every page including pages with no SRQL input.
- *Generated JS module at build time*: zero per-request cost but ties catalog changes to the asset pipeline build; awkward when catalog is data-driven in future.

### Decision: Tokenizer is a tiny pure JS module

`assets/js/lib/srql/tokenizer.js` exports `tokenize(query, cursor) → { tokens, activeToken, slot }`. A `Token` is `{ start, end, kind: 'control' | 'entity' | 'field' | 'value' | 'op' | 'unknown', text }`. `slot` describes what the cursor is currently inside, given the preceding tokens — that's how the hook knows whether to offer entity completions or field completions.

**Why:** Keeping the tokenizer pure makes it trivially unit-testable, reusable from a future React caller, and decoupled from DOM concerns. A property-based test (Erlang already uses StreamData) can fuzz it against the Rust NIF to confirm slot inference matches grammar.

### Decision: Click-token editing reuses the same dropdown primitive

Clicking inside a recognized token sets the cursor inside that token and opens the dropdown filtered to that slot's valid members. Picking a value replaces the token's text via `input.setRangeText(...)`. No separate "edit modal" — the dropdown is the editor.

**Why:** The user's only stated requirement is "click and get the other choices." Reusing the autocomplete dropdown means one rendering primitive, one keyboard model, one focus model.

### Decision: Squiggly underline is catalog-membership only

A token gets the squiggly treatment iff (a) we recognize its kind from the leading prefix or position AND (b) its value is not a member of the catalog set for that slot. No partial-string heuristics, no Levenshtein "did you mean" — out of scope for v1.

**Why:** Catalog membership is deterministic and cheap. Anything fancier risks false positives, and false positives in a search bar destroy trust faster than missing real errors.

## Risks / Trade-offs

- *Overlay-mirror drift*: if the input's font, padding, or line-height changes outside the overlay's CSS, the underline drifts off the token. **Mitigation:** colocate the overlay's style with the input style in `srql_components.ex` via shared CSS classes and snapshot-test the rendered HTML.
- *Catalog endpoint auth*: the catalog is not sensitive but the endpoint should still be auth-gated like the rest of `/api/`. **Mitigation:** mount under the existing authenticated pipeline; reject anonymous.
- *Mobile keyboard interaction*: virtual keyboards may steal focus or auto-correct tokens. **Mitigation:** set `autocorrect="off" autocapitalize="off" spellcheck="false"` on the compact input (some likely already there — verify) and test on iOS Safari.
- *Hydration flash*: if the overlay paints before the catalog loads, validation underlines flicker. **Mitigation:** the overlay renders only after the first catalog fetch resolves; before that, behavior matches today's plain input.
- *Bundle size regression*: a poorly-written tokenizer can balloon. **Mitigation:** size budget the hook + tokenizer + dropdown at ≤8KB minified ungzipped; CI asset-size check.

## Migration Plan

1. Land the catalog endpoint and structured JSON shape behind no feature flag (additive).
2. Land the tokenizer module + tests.
3. Land the hook, wired to the compact branch of `srql_editor`. Keep the `<datalist>` element in the DOM so non-JS fallback works.
4. Verify the navbar input still looks identical at idle on staging; verify rich editor untouched.
5. Once stable, document for plugin authors that the catalog endpoint is the canonical shape.

Rollback: remove the `phx-hook` attribute and the new overlay div from the compact branch. The `<datalist>` remains and the experience reverts to today's.

## Open Questions

- Should the catalog endpoint return entity-aware operator inventories (e.g. `is_available` only accepts `:`/`!=`)? v1 ships a single global operator list; per-field operator scoping is a likely follow-up but listed here so the JSON shape can leave room for it.
- Should the hint popover for control tokens (e.g. `time:`) preview the accepted human-readable forms (`last_24h`, `last_7d`)? Probably yes, but only after the v1 dropdown lands so we can size the popover real estate honestly.
