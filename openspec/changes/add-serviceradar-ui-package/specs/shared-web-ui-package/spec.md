## ADDED Requirements

### Requirement: Shared UI package for ServiceRadar Phoenix applications
The repository SHALL provide `serviceradar_ui`, an Apache-2.0 Elixir package published to hex.pm. It SHALL contain:
- the `sr-*` design tokens and light/dark theming as CSS
- generic function components
- shell pieces
- server-rendered SVG charts
- a prebuilt bundle of LiveView hooks, including an offline world map

It SHALL support Phoenix 1.8 with LiveView 1.1 and 1.2. It SHALL NOT contain product-specific domain logic.

#### Scenario: New Phoenix application adopts the package
- **WHEN** a Phoenix 1.8 application on LiveView 1.1 adds the dependency, imports the package CSS, and registers its hooks
- **THEN** it renders the shared components, shell, charts, and world map with the ServiceRadar look in light and dark themes, without copying package code

### Requirement: Package output is safe under a strict content security policy
No component, chart, or hook in the package SHALL emit inline `style` attributes, inline scripts, or inline event-handler attributes. None SHALL require any third-party origin for scripts, styles, fonts, images, map tiles, or network requests. The world map SHALL render from topology data bundled with the package.

#### Scenario: Strict policy
- **WHEN** an application serves pages using every package component and hook under `default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'`
- **THEN** the browser reports no policy violations and the components render correctly

#### Scenario: Regression introduces an inline style
- **WHEN** a change makes a component render a `style=` attribute
- **THEN** the package test suite fails

### Requirement: web-ng consumes the shared package instead of local copies
`web-ng` SHALL consume `serviceradar_ui` for design tokens, generic primitives, and generic charts. Once the migration completes, it SHALL NOT keep duplicate implementations of them. Temporary delegating wrappers SHALL be removed within one release.

#### Scenario: Sparkline consolidation
- **WHEN** the migration completes
- **THEN** every web-ng sparkline renders through the package chart component, and no local sparkline implementation remains

### Requirement: Releases are tag-driven and gated
The package SHALL be published to hex.pm only by a `serviceradar_ui-vX.Y.Z` tag workflow. The workflow SHALL run the quality gate, the LiveView 1.1 and 1.2 test matrix, and a check that the committed hooks bundle matches a fresh build. Releases SHALL follow semantic versioning and SHALL be recorded in a changelog.

#### Scenario: Stale bundle
- **WHEN** a release tag is pushed while the committed hooks bundle differs from a fresh build
- **THEN** the workflow fails and nothing is published
