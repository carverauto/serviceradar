## ADDED Requirements

### Requirement: Shared ServiceRadar design tokens in web-ng

The web-ng application SHALL define semantic design tokens aligned with the marketing site and control plane, including at least:

- Font stacks: sans (`Avenir Next` system fallback chain) and mono
- Colors: canvas, surface, raised, subtle, control, ink, muted, line, brand, focus (light and dark)
- Radii: small, control, surface
- Shadows: control, surface, raised, nav
- Z-index roles for shell and menus

Tokens MUST be available both as CSS custom properties (`--sr-*`) and as Tailwind v4 theme utilities (e.g. `bg-sr-surface`, `text-sr-ink`, `rounded-sr-control`, `shadow-sr-nav`).

#### Scenario: Token utilities compile

- **WHEN** web-ng CSS is built with Tailwind v4
- **THEN** templates may use `text-sr-ink` and `bg-sr-surface` without undefined theme errors
- **AND** the compiled CSS defines `--sr-font-sans` and brand color custom properties for light and dark themes

#### Scenario: Typeface matches public brand

- **WHEN** an operator loads any web-ng page
- **THEN** the document body uses the shared ServiceRadar sans font stack
- **AND** the stack is the same family chain as marketing/control (Avenir Next / system UI fallbacks)

### Requirement: Operations topbar brand chrome

The authenticated operations shell topbar SHALL present a brand mark consistent with marketing and control:

- Logo inside a bordered control tile
- Product/brand label with semibold tracking-tight typography
- Sticky topbar with translucent surface and backdrop blur
- Stable DOM ids for tests (`#ops-topbar`, brand logo id)

The topbar MUST continue to host optional SRQL placement, theme toggle, alerts entry, and profile actions without requiring daisyUI `navbar`, `dropdown`, or `menu` classes for those chrome pieces.

#### Scenario: Ops topbar brand mark

- **WHEN** a signed-in user opens `/dashboard`
- **THEN** the operations topbar is present with id `ops-topbar`
- **AND** a brand mark container with class `sr-ops-brand-mark` contains the product logo
- **AND** the brand label is visible next to the mark

#### Scenario: Ops profile menu without daisy dropdown

- **WHEN** a signed-in user opens the profile control in the operations topbar
- **THEN** a menu offers Profile, API docs, and Log out
- **AND** the menu markup does not require daisyUI `dropdown-content` or `menu` classes

#### Scenario: Alerts affordance preserved

- **WHEN** a signed-in user views the operations topbar
- **THEN** an alerts control with class `sr-ops-topbar-icon` links to `/alerts` and exposes an accessible name for Alerts

### Requirement: Public and standard shell topbar brand chrome

Unauthenticated and standard-shell pages SHALL use sticky topbar chrome aligned with the marketing brand treatment: bordered logo mark, “ServiceRadar” wordmark, optional short tagline on larger breakpoints, and shared token colors for surface/line/ink.

#### Scenario: Public topbar brand

- **WHEN** an unauthenticated user loads a standard-shell page (e.g. login)
- **THEN** the topbar includes a brand link with logo mark and ServiceRadar name
- **AND** the topbar uses shared `sr-public-topbar` chrome styling rather than daisyUI `navbar` classes

### Requirement: Phased retirement of daisyUI for shell chrome

New or modified **application shell chrome** (operations topbar, public topbar, theme toggle chrome, profile menu) MUST be implemented with Tailwind utilities and/or shared CSS classes backed by `sr-*` tokens, not daisyUI component classes (`btn`, `navbar`, `menu`, `dropdown`, `card` for chrome).

Existing page-level daisyUI usage MAY remain until a later migration phase, but shell work MUST NOT introduce new daisy dependencies for chrome.

#### Scenario: Theme toggle chrome is token-based

- **WHEN** the theme toggle is rendered in the shell
- **THEN** its container uses shared line/surface token styling
- **AND** it does not rely on daisyUI `card` or `base-300` classes for its chrome

#### Scenario: Full daisyUI removal is sequenced

- **WHEN** shell and shared primitives no longer reference daisyUI component classes
- **THEN** a subsequent task MAY remove the daisyUI Tailwind plugin from web-ng assets
- **AND** page migrations MUST complete or use non-daisy primitives before that removal
