## Context

Three ServiceRadar UIs should feel like one product:

| Surface | Repo / path | Styling today |
|---------|-------------|---------------|
| Marketing | `serviceradar-web` | Tailwind v4, `sr-*` tokens, no daisyUI |
| Control | `serviceradar-control` | Same public token system; public topbar matched to marketing |
| Product | `elixir/web-ng` | Tailwind v4 + daisyUI plugin, Nocturne light/dark, `sr-ops-*` shell |

web-ng already has a strong **operations shell** (icon rail + sticky topbar + SRQL). This change does not replace that IA; it restyles and de-daisyUI’s the chrome and primitives so type, brand mark, and control surfaces match marketing/control.

## Goals / Non-Goals

### Goals

- Shared **semantic tokens** (`sr-color-*`, `sr-font-*`, radii, shadows) consumable as Tailwind theme keys (`bg-sr-surface`, `text-sr-ink`, …).
- Ops and public topbars use the **marketing brand mark** pattern (logo in bordered control tile, Avenir Next, tracking/weight parity).
- Shell chrome (topbar, theme toggle, profile menu, later nav buttons) does **not** depend on daisyUI component classes.
- Phased removal of `@plugin "../vendor/daisyui"` once call sites are migrated.
- Spec + task tracking for “what’s done / what’s next.”

### Non-Goals

- Pixel-clone marketing’s floating pill topbar onto the dense ops shell (ops stays full-width sticky bar for SRQL + actions).
- Replacing React dashboard host / map stack styling in this change.
- Changing auth, routes, or SRQL semantics.
- Building images locally on arm64; publish remains Bazel/CI.

## Decisions

### Decision: Tokens first, daisy last

Add marketing-aligned tokens **alongside** daisy/Nocturne. Shell CSS and new markup prefer tokens; pages keep daisy until primitives exist.

**Why:** ~300+ `btn` usages and many `menu`/`dropdown`/`drawer` call sites. Big-bang daisy removal is high risk.

### Decision: Ops keeps cyan density accents during migration

Active nav, KPI glows, and dark shell backgrounds stay Nocturne cyan-oriented. Brand **type and mark** match marketing; brand **green** is available via tokens for public/standard surfaces and CTAs as primitives migrate.

**Why:** Full green retheme of ops charts/maps is a separate product decision.

### Decision: Phoenix function components as the migration unit

Prefer upgrading `ui_button`, inputs, menus, and shell partials so pages inherit token styling without rewriting every LiveView at once.

### Decision: Native HTML for simple chrome

Use `<details>` / focus-visible patterns for profile and mobile menus (as marketing does) instead of daisy `dropdown` when possible.

### Decision: Source of truth for tokens

Copy values from marketing/control `app.css` (`--sr-font-sans`, light/dark color ramps, shadows). Do not invent a third palette. When marketing updates tokens, web-ng should follow in a small sync PR.

### Alternatives considered

| Option | Rejected because |
|--------|------------------|
| Keep daisyUI forever with theme overrides | Diverges permanently from marketing/control; Agents.md for marketing forbids daisy |
| Hard-cut remove daisy in one PR | Too many call sites; breaks settings/forms/tests |
| Import marketing CSS package | No shared npm package yet; Phoenix digests differ; premature |

## Migration Plan

```
Phase 0  Proposal + tasks + deltas (this change)
Phase 1  Tokens + ops/public topbar + theme toggle + profile menu
Phase 2  Shared primitives (button, input chrome, badge, card, menu)
Phase 3  Shell remainder (sidebar rail, standard drawer sidebar, breadcrumbs)
Phase 4  High-traffic pages off daisy classes (dashboard, devices, auth)
Phase 5  Remove daisy plugin; retune leftover base-* references; archive
```

Rollback: each phase is CSS/HEEx only; revert the branch or selective files. No data migrations.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Visual inconsistency mid-migration | Shell/token first; leave page interiors on daisy until primitives ready |
| Settings redesign concurrent work | Coordinate: settings shell should consume tokens from this change |
| Specs still mention daisyUI themes | Update requirements in this delta; page-level daisy mentions age out in Phase 4–5 |
| Test selectors break | Update layout/dashboard tests with stable IDs (`#ops-topbar`, `#ops-brand-logo`) |
| Asset digest / missing logo-animated | Ship `priv/static/images/logo-animated.svg`; covered by web-ng-build delta |

## Open Questions

- After Phase 5, should ops primary accent stay cyan or move fully to brand green?
- Should a shared `sr-design-tokens` package eventually live in the monorepo, or keep copy-synced CSS?
- Prefer one long-lived branch (`ui/web-ng-align-marketing`) with stacked PRs per phase, or one PR per phase from short-lived branches?
