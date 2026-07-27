## 0. Proposal tracking

- [x] 0.1 Create OpenSpec change `align-web-ng-with-marketing-design-system` (proposal, design, tasks, deltas).
- [x] 0.2 Review and approve this proposal before expanding beyond Phase 1.
- [x] 0.3 Run `openspec validate align-web-ng-with-marketing-design-system --strict`.
- [x] 0.4 Establish worktree branch `ui/web-ng-align-marketing` from `origin/staging`.

## 1. Design tokens (foundation)

- [x] 1.1 Port marketing/control `--sr-font-*`, color, radius, shadow, and z-index tokens into `elixir/web-ng/assets/css/app.css`.
- [x] 1.2 Expose tokens via Tailwind v4 `@theme inline` (`bg-sr-surface`, `text-sr-ink`, `rounded-sr-control`, …).
- [x] 1.3 Apply `font-family: var(--sr-font-sans)` on `html`/`body` and ops shell.
- [x] 1.4 Keep daisyUI + Nocturne theme vars intact for unmigrated components.
- [x] 1.5 Verify `bun`/`npm` CSS build succeeds with tokens present.

## 2. Phase 1 — Topbar & brand chrome

- [x] 2.1 Ops topbar: marketing brand mark tile, type scale/tracking, sticky min-height, brand asset.
- [x] 2.2 Ops profile menu: native `<details>` + token styles (no daisy `dropdown`/`menu`).
- [x] 2.3 Theme toggle: token borders/surfaces (no daisy `card`/`base-*` chrome).
- [x] 2.4 Public/standard shell topbar: sticky marketing-aligned brand + tagline; non-daisy mobile nav button.
- [x] 2.5 Add `priv/static/images/logo-animated.svg` for path parity with marketing/control.
- [x] 2.6 Update dashboard LiveView shell assertions (`#ops-topbar`, brand mark, profile menu).
- [ ] 2.7 Manual visual check: signed-in ops shell + signed-out login/public shell (light/dark/system).
- [ ] 2.8 Open PR (or stacked PR) for Phase 1 only if reviewers prefer small merges.

## 3. Phase 2 — Shared primitives

- [x] 3.1 Audit `ui_components.ex` / core inputs: list daisy class dependencies (`btn`, `input`, `select`, `badge`, …).
- [x] 3.2 Restyle `ui_button` on tokens (primary/ghost/soft/neutral/outline + sizes); all call sites inherit via component.
- [x] 3.3 Restyle form field chrome (`core_components` input/select/textarea/checkbox + auth entry pages).
- [ ] 3.4 Add/adjust component tests or LiveView assertions for button/focus rings (dashboard shell covered; expand later).
- [x] 3.5 Document primitive class/API in `elixir/web-ng/AGENTS.md`.

## 4. Phase 3 — Shell remainder

- [x] 4.1 Ops icon rail: existing token-oriented CSS retained (cyan active treatment preserved).
- [x] 4.2 Standard drawer sidebar brand restyled with public brand mark (menu items still use legacy `menu` until later pass).
- [x] 4.3 Breadcrumbs without daisy `breadcrumbs` dependency.
- [x] 4.4 Flash group chrome pass for contrast on `sr-canvas` / ops background.
- [x] 4.5 Layout regression tests for ops shell (dashboard assertions); standard shell covered by auth markup IDs.

## 5. Phase 4 — High-traffic pages

- [x] 5.1 Auth pages (login, local login, reset) on public tokens + non-daisy chrome.
- [x] 5.2 Dashboard hub / package / agents / camera relay / security / observability chrome → `ui_button`.
- [x] 5.3 Devices (filters, bulk modals/actions, import, MTR) + interface show + admin package indexes batch.
- [x] 5.4 Grep gate snapshot: safe HEEx codemod batch (~432 conversions). Remaining raw `btn` ~170 (mostly dynamic `class={[...]}` toggles).
- [x] 5.5 Settings surfaces bulk-converted (ansible, integrations, netflow, auth users, releases, etc.). Residual dynamic class lists next.
- [ ] 5.6 Convert remaining dynamic `class={[ "btn …", cond && "btn-primary" ]}` toggle patterns to `variant={if …}` / token classes.
- [ ] 5.7 Settings shell chrome (`settings/shell.ex`) off daisy leftovers.
- [x] 5.8 Retheme daisy primary + ops shell (topbar/sidebar/active nav) from cyan/blue Nocturne to marketing brand green.

## 6. Phase 5 — Remove daisyUI

- [ ] 6.1 Confirm remaining daisy usages are zero or isolated behind deprecated wrappers.
- [ ] 6.2 Remove `@plugin "../vendor/daisyui"` and vendor daisy assets if unused.
- [ ] 6.3 Delete or neutralize Nocturne daisy CSS vars that nothing references.
- [ ] 6.4 Full CSS build + targeted LiveView test suite for web-ng.
- [ ] 6.5 Update any remaining specs/docs that require daisyUI themes for web-ng shell.

## 7. Validation & ship

- [ ] 7.1 `openspec validate align-web-ng-with-marketing-design-system --strict` (green).
- [ ] 7.2 Run applicable web-ng quality path (project script or focused `mix test` for layout/dashboard).
- [ ] 7.3 Image publish via **Bazel/CI only** (no local arm64 Docker); roll demo/staging as usual.
- [ ] 7.4 Archive change after deploy; merge deltas into `openspec/specs/`.

## 8. Coordination

- [ ] 8.1 Note dependency for `redesign-settings-catalog-nav` (consume tokens; avoid new daisy shell).
- [ ] 8.2 Decide open question: ops primary accent cyan vs brand green post-migration.
