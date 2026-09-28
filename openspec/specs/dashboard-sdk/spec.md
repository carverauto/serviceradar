# dashboard-sdk Specification

## Purpose
The contract between a ServiceRadar dashboard package and the tooling that builds
and ships it: `@carverauto/serviceradar-dashboard-sdk` (the renderer runtime a
dashboard imports) and `@carverauto/serviceradar-cli` (the `dashboard` authoring
loop — `init`, `dev`, `build`, `validate`, `manifest`, `publish`, `import` — plus
`doctor`).

ServiceRadar owns the package loader, the SRQL data provider, and the
`dashboard-browser-module-v1` ABI; a dashboard package owns its renderer. These
requirements cover what an author can rely on from the SDK and CLI regardless of
how their project is laid out on disk or which install topology placed its
dependencies.

## Requirements

### Requirement: Project dependencies resolved through Node resolution
The dashboard CLI SHALL resolve packages it needs from the dashboard project (`react`, `react-dom`, and `@carverauto/serviceradar-dashboard-sdk`) using Node's module resolution anchored at the project directory, rather than by joining a literal `<projectDir>/node_modules/<package>` path — so a package found by `node --input-type=module -e "import.meta.resolve(...)"` from the project is found by the CLI, whatever install layout put it there.

#### Scenario: Dependencies hoisted to a workspace root
- **GIVEN** a dashboard project inside an npm-workspaces monorepo, where `react`, `react-dom`, and the SDK are hoisted to the workspace root and the project has no `node_modules` of its own
- **WHEN** the author runs `serviceradar-cli dashboard build` or `serviceradar-cli dashboard dev`
- **THEN** the CLI SHALL resolve each package from the workspace root
- **AND** the build SHALL emit a renderer artifact, and the dev server SHALL serve the renderer entry without a module-resolution error

#### Scenario: Dependencies installed in the project itself
- **GIVEN** a standalone dashboard repo with `react`, `react-dom`, and the SDK in its own `node_modules`
- **WHEN** the author runs `serviceradar-cli dashboard build` or `serviceradar-cli dashboard dev`
- **THEN** the CLI SHALL resolve the project-local copies
- **AND** the emitted artifact SHALL be unchanged from the artifact produced before this change, so no working project regresses

#### Scenario: React alias points at a package directory
- **GIVEN** a dashboard whose renderer is compiled by `@vitejs/plugin-react` in automatic JSX mode, so the module graph contains `react/jsx-runtime`
- **WHEN** the CLI builds the vite `resolve.alias` entry for `react`
- **THEN** the replacement SHALL be the React package **directory**, not a resolved entry file
- **AND** `react/jsx-runtime` SHALL resolve to the runtime inside that directory rather than to a subpath of an entry file

#### Scenario: A genuinely missing dependency reports an actionable error
- **GIVEN** a dashboard project where `react` is not installed in any location reachable from the project
- **WHEN** the author runs `serviceradar-cli dashboard build`
- **THEN** the CLI SHALL fail with a message naming the unresolvable package and suggesting the install command
- **AND** it SHALL NOT surface only a raw filesystem path from esbuild or vite
- **AND** it SHALL exit with a non-zero status code

### Requirement: Doctor reports dependency versions from the project's resolution
`serviceradar-cli doctor` SHALL report the version of `@carverauto/serviceradar-dashboard-sdk` that the dashboard project would actually load, resolving it from the project directory — so a correctly installed but hoisted SDK is never reported as missing.

#### Scenario: Doctor finds a hoisted SDK
- **GIVEN** a dashboard project in a workspace whose SDK is hoisted to the workspace root
- **WHEN** the author runs `serviceradar-cli doctor` from the project directory
- **THEN** the output SHALL show the resolved SDK version
- **AND** it SHALL NOT report the SDK as "not resolvable from this project"

#### Scenario: Doctor still reports a genuinely absent SDK
- **GIVEN** a dashboard project with no reachable `@carverauto/serviceradar-dashboard-sdk` installation
- **WHEN** the author runs `serviceradar-cli doctor`
- **THEN** the output SHALL report the SDK as not resolvable
- **AND** it SHALL suggest the install command

### Requirement: Author-supplied vite aliases take precedence in every command
A `vite.resolve.alias` entry supplied from `dashboard.config.mjs` SHALL override the CLI's own alias for the same specifier in **both** `dashboard build` and `dashboard dev`, so the config means the same thing in both commands.

#### Scenario: A config alias overrides the CLI default in dev
- **GIVEN** a `dashboard.config.mjs` that sets `vite.resolve.alias.react` to a specific directory
- **WHEN** the author runs `serviceradar-cli dashboard dev`
- **THEN** the renderer SHALL be served with React resolved to the author's directory
- **AND** the CLI's own `react` alias SHALL NOT shadow it

#### Scenario: A config alias overrides the CLI default in build
- **GIVEN** the same config
- **WHEN** the author runs `serviceradar-cli dashboard build`
- **THEN** the emitted artifact SHALL be built against the author's directory
- **AND** the behavior SHALL match `dev` for the same config

#### Scenario: CLI-bundled aliases remain in effect when not overridden
- **GIVEN** a dashboard config that supplies no alias for `mapbox-gl` or `@deck.gl/*`
- **WHEN** the author runs `serviceradar-cli dashboard dev`
- **THEN** those specifiers SHALL still resolve to the copies bundled with the CLI
