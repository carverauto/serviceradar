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

### Requirement: Frames carry the identity a client needs to detect change
Every data frame delivered to a dashboard package SHALL carry enough identity for a
client to tell a refreshed frame from the one it already holds, without inspecting
row data. Specifically each frame that carries its own freshly-run rows SHALL carry
`refreshed_at` (when those rows were produced) and `content_hash` (derived from the
rows or payload), and every delivered frame SHALL carry `checked_at` (when the host
last evaluated the query, whether or not the result changed).

#### Scenario: A refreshed frame is distinguishable from its predecessor
- **GIVEN** a dashboard with a `json_rows` frame whose row values have changed since the last delivery, while its row count, id, encoding, status and query are unchanged
- **WHEN** the host re-runs the frame and delivers it
- **THEN** the delivered frame SHALL carry a `refreshed_at` later than the previous delivery's, and a `content_hash` different from the previous delivery's
- **AND** a client comparing only frame metadata SHALL conclude the frame changed

#### Scenario: An unchanged frame is still reported as checked
- **GIVEN** a dashboard frame whose query returns identical results on consecutive evaluations
- **WHEN** the host re-evaluates it
- **THEN** the client SHALL learn that the data was checked, via a `checked_at` later than the previous one
- **AND** `refreshed_at` SHALL NOT advance, because the data did not change

#### Scenario: Preserved stale rows are not reported as fresh
- **GIVEN** a frame whose re-run failed, and for which the host preserves the previous successful rows rather than showing nothing
- **WHEN** that frame is delivered
- **THEN** it SHALL carry forward the `refreshed_at` of the rows it actually contains, not the time of the failed attempt
- **AND** it SHALL carry a `checked_at` reflecting the failed attempt
- **AND** a client SHALL therefore be able to render the true age of the data it is showing

#### Scenario: Change detection does not depend on row data
- **GIVEN** a frame carrying a large `arrow_ipc` payload
- **WHEN** a client decides whether to re-decode it
- **THEN** the decision SHALL be possible from frame metadata alone
- **AND** the client SHALL NOT be required to decode or hash the payload to detect a change

### Requirement: Adding freshness metadata does not amplify delivery
Timestamp and identity fields added to a frame SHALL NOT cause the host to deliver
frames it would otherwise have suppressed. The host's decision to push SHALL be
based on whether the data changed, not on whether a timestamp advanced.

#### Scenario: An unchanged frame is not re-pushed every tick
- **GIVEN** a dashboard whose frames' data is unchanged across several refresh ticks
- **WHEN** those ticks occur
- **THEN** the host SHALL NOT push a full frame replacement for them
- **AND** it SHALL NOT re-send any associated binary payloads
- **AND** any liveness signal it sends instead SHALL NOT carry frame rows

#### Scenario: A changed frame is still pushed promptly
- **GIVEN** the same dashboard, whose frame data then changes
- **WHEN** the next refresh tick evaluates it
- **THEN** the host SHALL deliver the updated frame

### Requirement: A request the host cannot service reports failure
When a dashboard package asks the host to refresh or page a frame and the host
cannot act on the request, the host SHALL reply with an error identifying why. It
SHALL NOT reply with success having done nothing.

#### Scenario: Paging while a refresh is in flight
- **GIVEN** a dashboard package requesting the next page of a frame at a moment when the host is already running a refresh
- **WHEN** the request is received
- **THEN** the host SHALL either service the request or reply with an error
- **AND** it SHALL NOT reply with success while discarding the request

#### Scenario: Forcing a refresh does not destroy paging position
- **GIVEN** a dashboard package that has paged a frame away from its first page
- **WHEN** the package requests a refresh
- **THEN** the frame's paging position SHALL be preserved
- **AND** the request SHALL either be serviced or reported as failed

### Requirement: Cursor direction is honoured
When a dashboard package pages a frame, the host SHALL honour the direction of the
request, so that requesting the previous page returns the previous page.

#### Scenario: Paging backward returns the previous page
- **GIVEN** a dashboard package that has advanced a frame to its second page
- **WHEN** it requests the previous page
- **THEN** the host SHALL deliver the first page
- **AND** it SHALL NOT deliver the third page or repeat the second
