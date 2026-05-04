## ADDED Requirements

### Requirement: Typed dashboard config helper
The dashboard SDK SHALL export a `defineDashboardConfig` helper that is identity-at-runtime and returns the same configuration object passed in, but ships TypeScript declarations covering every supported field — so editors complete and validate the shape of `manifest`, `renderer`, `samples`, `fixtures`, `vite`, `build`, and `afterBuild` without dashboard authors reading the SDK source.

#### Scenario: Author imports the helper and gets typed completion
- **GIVEN** a dashboard project with TypeScript or a JS editor backed by the bundled `.d.ts` files
- **WHEN** the author writes `import {defineDashboardConfig} from "@serviceradar/dashboard-sdk/config"` and starts a config object
- **THEN** the editor SHALL surface every required and optional field with inline documentation
- **AND** assigning a wrong type to any nested manifest field SHALL surface as a type error in the editor

#### Scenario: Plain-object configs continue to work
- **GIVEN** an existing dashboard project with `dashboard.config.mjs` exporting a plain object
- **WHEN** the project is built or served by the SDK CLI
- **THEN** the CLI SHALL accept the plain-object export unchanged
- **AND** the developer SHALL NOT be required to migrate to `defineDashboardConfig` to use any CLI feature

### Requirement: Static dashboard validation command
The dashboard SDK CLI SHALL provide a `validate` subcommand that statically checks dashboard config shape, manifest required fields after digest stamping, sample-frames against declared `data_frames`, and sample-settings against any declared `settings_schema`, without performing a build.

#### Scenario: Validate flags a missing manifest field
- **GIVEN** a dashboard config whose synthesized manifest would omit a required `dashboard-browser-module-v1` field
- **WHEN** the developer runs `serviceradar-dashboard validate`
- **THEN** the CLI SHALL print a failure that names the missing field and its declared location
- **AND** it SHALL exit with a non-zero status code

#### Scenario: Validate flags a sample-frames mismatch
- **GIVEN** a dashboard config that declares a `data_frames` entry whose `id` is not present in the sample-frames JSON
- **WHEN** the developer runs `serviceradar-dashboard validate`
- **THEN** the CLI SHALL print which frame is declared but missing from the sample data
- **AND** it SHALL include the file path of the sample-frames JSON

#### Scenario: Build refuses on validation failure
- **GIVEN** a dashboard project that fails `validate`
- **WHEN** the developer runs `serviceradar-dashboard build`
- **THEN** the CLI SHALL run validation as a first step and refuse to write `dist/` until validation passes

### Requirement: Hot-reload dev loop
The dashboard SDK CLI SHALL provide a `dev` command that boots a Vite dev server in middleware mode, serves the harness HTML, imports the project's renderer entry as a Vite module, and propagates source edits to the running renderer through HMR — so dashboard authors observe code changes within roughly 100 ms without a full page reload.

#### Scenario: HMR remounts the renderer on source edit
- **GIVEN** a dashboard project served by `serviceradar-dashboard dev`
- **WHEN** the developer edits a renderer source file and saves it
- **THEN** the harness SHALL receive an HMR update for the renderer module
- **AND** it SHALL invoke the previous mount's `destroy()` contract before mounting the new module
- **AND** the renderer SHALL remount against the same root element with a fresh host API
- **AND** the page SHALL NOT perform a full reload

#### Scenario: Validation failure during HMR surfaces in the error overlay
- **GIVEN** a dashboard project served by `serviceradar-dashboard dev`
- **WHEN** the developer edits the dashboard config or a sample fixture in a way that breaks validation
- **THEN** the harness SHALL display the failure inline in its error overlay
- **AND** it SHALL NOT crash the dev server

#### Scenario: `--no-hmr` falls back to the legacy build-once dev loop
- **GIVEN** an environment that cannot run Vite middleware mode
- **WHEN** the developer passes `--no-hmr` to `serviceradar-dashboard dev`
- **THEN** the CLI SHALL fall back to the prior behavior of running a one-shot build and serving `dist/` as static files

### Requirement: Auto-mounting harness with developer side panel
The dashboard SDK harness SHALL auto-mount the configured renderer when URL parameters are valid, expose a side panel for theme toggle, Mapbox token entry, and fixture selection, and surface host API activity (SRQL updates, navigation, popup opens) in a status bar — so the harness functions as a real development surface rather than a debugging form.

#### Scenario: Renderer mounts immediately when URL params are valid
- **GIVEN** a harness URL with valid `manifest`, `renderer`, `frames`, and `settings` parameters
- **WHEN** the harness loads
- **THEN** the renderer SHALL mount immediately
- **AND** there SHALL NOT be a "Run Renderer" button required to start the renderer

#### Scenario: Fixture picker swaps active sample frames
- **GIVEN** a dashboard config that declares fixtures with `{"den-drilled": "fixtures/den.json", "all-healthy": "fixtures/healthy.json"}`
- **WHEN** the developer selects a fixture from the side panel picker
- **THEN** the harness SHALL load the selected fixture as the active sample frames
- **AND** it SHALL remount the renderer against the new frames without a full page reload

#### Scenario: Mapbox token entered in the side panel applies to the host API
- **GIVEN** a dashboard project mounted in the harness
- **WHEN** the developer pastes a Mapbox token into the side panel input
- **THEN** the harness SHALL persist the token to localStorage
- **AND** subsequent calls to `host.mapbox()` SHALL return the new token without requiring a page reload

#### Scenario: Renderer crash surfaces in the error overlay
- **GIVEN** a renderer that throws during mount
- **WHEN** the harness attempts to mount the renderer
- **THEN** the harness SHALL display the error and stack trace inline in a runtime error overlay
- **AND** the dev server SHALL keep running so the developer can fix and save without restarting

#### Scenario: Legacy form-field harness remains available at `/?advanced`
- **GIVEN** a developer running `serviceradar-dashboard dev`
- **WHEN** they navigate to the harness URL with `?advanced` appended
- **THEN** the harness SHALL serve the prior form-field UI for testing manually-built `dist/` artifacts

### Requirement: Project scaffolder
The dashboard SDK SHALL provide a project scaffolder runnable as `npm create @serviceradar/dashboard <name>` (or `serviceradar-dashboard init <name>`) that copies a chosen template, swizzles project name and identifier placeholders, runs `npm install`, and prints next-step instructions — so a new dashboard project goes from "empty directory" to "running dev loop" in one command.

#### Scenario: Scaffolder creates a working project from the default template
- **GIVEN** an empty directory and a registered npm install of the SDK
- **WHEN** the developer runs `npm create @serviceradar/dashboard my-map`
- **THEN** the CLI SHALL copy the `react-map` template into `./my-map`
- **AND** it SHALL replace `__PACKAGE_ID__`, `__PACKAGE_NAME__`, and `__DASHBOARD_TITLE__` with developer-supplied or derived values
- **AND** it SHALL run `npm install` in the new directory unless `--no-install` is passed
- **AND** it SHALL print next-step instructions that call out `serviceradar-dashboard dev`

#### Scenario: Scaffolder offers multiple templates
- **GIVEN** a developer with a dashboard idea
- **WHEN** they run `npm create @serviceradar/dashboard my-table --template react-table`
- **THEN** the CLI SHALL copy the `react-table` template instead of `react-map`
- **AND** it SHALL accept `react-blank` as the minimum-viable template choice

#### Scenario: Scaffolder rejects targets that already exist
- **GIVEN** a directory that already contains files
- **WHEN** the developer runs `npm create @serviceradar/dashboard <existing-dir>`
- **THEN** the CLI SHALL refuse to overwrite the existing directory
- **AND** it SHALL print a clear error suggesting `--force` for overwrite or a different name

### Requirement: First-class publish command
The dashboard SDK CLI SHALL provide a `publish` subcommand that uploads the manifest and renderer artifact to a ServiceRadar instance over the dashboard package import API, accepting authentication through `SERVICERADAR_TOKEN` env or `--token` and never persisting credentials to disk — so customers do not need to write a project-supplied import script to deploy from local dev to a real ServiceRadar deployment.

#### Scenario: Publish uploads a verified manifest and renderer
- **GIVEN** a dashboard project with a built `dist/` whose manifest digest matches the renderer artifact
- **WHEN** the developer runs `serviceradar-dashboard publish --instance https://serviceradar.example.com --route my-dashboard --token $SERVICERADAR_TOKEN`
- **THEN** the CLI SHALL re-verify the manifest digest matches the renderer artifact
- **AND** it SHALL POST the manifest and renderer to the ServiceRadar dashboard package import endpoint with bearer authentication
- **AND** it SHALL print the resolved instance URL, route, and version before transferring

#### Scenario: Publish refuses on digest mismatch
- **GIVEN** a dashboard project whose manifest digest does not match the renderer artifact
- **WHEN** the developer runs `serviceradar-dashboard publish`
- **THEN** the CLI SHALL refuse to publish
- **AND** it SHALL print which digest mismatched and which `build` command would resolve it

#### Scenario: Publish never persists tokens to disk
- **GIVEN** a `serviceradar-dashboard publish` invocation with `--token $SERVICERADAR_TOKEN` or with the env variable set
- **WHEN** the publish completes or fails for any reason
- **THEN** the CLI SHALL NOT write the token to any file
- **AND** it SHALL NOT log the token to stdout or stderr

#### Scenario: Publish optionally enables the dashboard
- **GIVEN** a dashboard project being published with `--enable`
- **WHEN** the publish upload succeeds
- **THEN** the CLI SHALL follow up with the existing dashboard-instance enable API call against the same instance
- **AND** the dashboard SHALL be live at the configured route without an admin step

### Requirement: Dev-time Mapbox token configuration
The dashboard SDK CLI SHALL accept a Mapbox access token from a `--mapbox-token` flag or `MAPBOX_TOKEN` environment variable, surface the resolved value through the harness side panel, and pass it to the host API's `mapbox()` accessor — so dashboard authors do not need to edit `sample-settings.json` to render a Mapbox basemap during local development.

#### Scenario: Dev command picks up a token from the environment
- **GIVEN** a developer environment with `MAPBOX_TOKEN` set to a valid public token
- **WHEN** the developer runs `serviceradar-dashboard dev`
- **THEN** the harness SHALL surface the token in its side panel
- **AND** the host API's `mapbox()` accessor SHALL return the token to the renderer

#### Scenario: `--mapbox-token` flag overrides the environment
- **GIVEN** a developer environment with both `MAPBOX_TOKEN` set and a different token passed as `--mapbox-token pk.foo`
- **WHEN** the developer runs `serviceradar-dashboard dev --mapbox-token pk.foo`
- **THEN** the CLI SHALL prefer the flag value
- **AND** the harness SHALL display the flag-supplied token in its side panel

### Requirement: Actionable CLI error messages
The dashboard SDK CLI SHALL include the suggested next command in every error message that previously dead-ended a developer — for example "missing dashboard config; create dashboard.config.mjs or run `serviceradar-dashboard init`" — so authors are guided toward the next step rather than left to read the SDK source.

#### Scenario: Missing config error suggests the scaffolder
- **GIVEN** a directory without `dashboard.config.mjs` or `package.json#serviceradarDashboard`
- **WHEN** the developer runs `serviceradar-dashboard build`
- **THEN** the CLI SHALL print an error that names what is missing
- **AND** it SHALL suggest running `serviceradar-dashboard init` or creating `dashboard.config.mjs`

#### Scenario: Missing renderer entry suggests the configuration field
- **GIVEN** a dashboard config whose `renderer.entry` points at a path that does not exist
- **WHEN** the developer runs `serviceradar-dashboard build`
- **THEN** the CLI SHALL print the resolved path that was missing
- **AND** it SHALL suggest the `renderer.entry` field as the place to update

### Requirement: Canonical `serviceradar-cli` umbrella with subcommand groups
The dashboard SDK SHALL ship its developer CLI as `serviceradar-cli` packaged in `@serviceradar/cli`, structured around named subcommand groups so the binary can grow beyond dashboards. `@serviceradar/dashboard-sdk` SHALL declare `@serviceradar/cli` as a runtime dependency so installing the SDK pulls the CLI bin into the project's `node_modules/.bin/` automatically.

#### Scenario: One install brings in both runtime and CLI
- **GIVEN** an empty Node project
- **WHEN** the developer runs `npm install @serviceradar/dashboard-sdk`
- **THEN** `serviceradar-cli` SHALL appear in `./node_modules/.bin/` without a separate install command
- **AND** the developer SHALL be able to run `npx serviceradar-cli --help` immediately

#### Scenario: Subcommand groups dispatch to the correct command
- **GIVEN** an installed `serviceradar-cli`
- **WHEN** the developer runs `serviceradar-cli dashboard build`
- **THEN** the CLI SHALL invoke the dashboard build pipeline
- **AND** when the developer runs `serviceradar-cli auth login`
- **AND** the CLI SHALL invoke the device-code auth flow

#### Scenario: Transitional `serviceradar-dashboard` bin still works
- **GIVEN** a customer script that already invokes `serviceradar-dashboard build`
- **WHEN** that script runs after the CLI restructuring lands
- **THEN** the CLI SHALL print a deprecation notice
- **AND** it SHALL delegate to `serviceradar-cli dashboard build` and exit with the same status the new command produces

### Requirement: Device-code auth flow with on-disk credential store
The `serviceradar-cli auth` subcommand group SHALL implement an OAuth 2.0 Device Authorization Grant (RFC 8628) flow against the configured ServiceRadar instance, persist the issued long-lived token to a per-user credential store at `~/.config/serviceradar/credentials.json` keyed by instance URL, and become the default credential source for any CLI command that requires instance authentication.

#### Scenario: `auth login` runs the device-code flow
- **GIVEN** the developer runs `serviceradar-cli auth login --instance https://serviceradar.example.com`
- **WHEN** the CLI receives a `device_code`, `user_code`, and `verification_uri` from `/api/v1/cli/auth/device`
- **THEN** the CLI SHALL print the verification URI and code
- **AND** it SHALL optionally open the verification URI in the user's browser unless `--no-browser` is passed
- **AND** it SHALL poll `/api/v1/cli/auth/token` at the server-suggested interval until the user completes login or the device code expires
- **AND** on success it SHALL persist the issued token, user identity, obtained-at, and expires-at to `~/.config/serviceradar/credentials.json` with file mode `0600`

#### Scenario: Manual-token fallback covers ServiceRadar instances that lack device-code endpoints
- **GIVEN** a ServiceRadar instance that has not yet shipped the `/api/v1/cli/auth/device` endpoint
- **WHEN** the developer runs `serviceradar-cli auth login --instance <url>` and the device-code request returns 404
- **THEN** the CLI SHALL fall back to prompting the developer to paste a long-lived token from the ServiceRadar UI
- **AND** it SHALL persist that token to the same credential store with the same shape

#### Scenario: `auth status` prints the resolved identity without leaking the token
- **GIVEN** a credential entry exists for the requested instance
- **WHEN** the developer runs `serviceradar-cli auth status [--instance <url>]`
- **THEN** the CLI SHALL print the instance URL, the authenticated user identity, the obtained-at, and the expires-at
- **AND** it SHALL NOT print the token to stdout, stderr, or any log

#### Scenario: `auth logout` removes the credential entry
- **GIVEN** a credential entry exists for the requested instance
- **WHEN** the developer runs `serviceradar-cli auth logout --instance <url>`
- **THEN** the CLI SHALL remove the entry from the credential store
- **AND** the credential file SHALL be rewritten with file mode `0600`

#### Scenario: Credential resolution order is deterministic
- **GIVEN** a `serviceradar-cli dashboard publish` invocation against an instance with a stored credential
- **WHEN** the developer also passes `--token` and has `SERVICERADAR_TOKEN` set in the environment
- **THEN** the CLI SHALL resolve credentials in the order `--token` flag → `SERVICERADAR_TOKEN` env → stored credential
- **AND** when no source resolves, it SHALL print "run `serviceradar-cli auth login --instance <url>` first" and exit non-zero

#### Scenario: Credential file refuses unsafe parent directory
- **GIVEN** the credential directory `~/.config/serviceradar/` exists but is group- or world-writable
- **WHEN** the CLI attempts to write a credential file
- **THEN** it SHALL refuse the write
- **AND** it SHALL print which permission bits are unsafe and how to fix them
