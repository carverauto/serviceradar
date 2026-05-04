## 1. `defineDashboardConfig` Typed Helper
- [x] 1.1 Create `src/config.js` and `src/config.d.ts` exporting `defineDashboardConfig(config)` as identity-at-runtime + full TypeScript types covering `manifest`, `renderer`, `samples`, `fixtures`, `vite`, `build`, and `afterBuild`.
- [x] 1.2 Re-derive the manifest field types from the existing `dashboard-browser-module-v1` contract so the helper stays the canonical schema. (Manifest types are colocated in `config.d.ts` as `DashboardManifestSpec`/`DashboardFrameSpec`/`DashboardRendererManifestSpec`.)
- [x] 1.3 Add the `./config` subpath to `package.json#exports` and ship the generated `.d.ts` in the publish bundle.
- [x] 1.4 Update `loadConfig` in the CLI to recognize wrapped exports without behavior change for plain-object configs. (No code change required — `loadConfig` already returns `module.default || module.config || module.dashboard || {}` and `defineDashboardConfig` is identity-at-runtime, so wrapped and plain exports both pass through unchanged.)
- [x] 1.5 Add unit tests asserting the helper accepts valid configs. (`tests/config.test.mjs` — 3 tests covering identity semantics, nullish pass-through, and version pinning.)

## 2. `serviceradar-dashboard validate`
- [x] 2.1 Add the `validate` subcommand to `bin/serviceradar-dashboard.js`. No build, no network.
- [ ] 2.2 Validate the config shape against the JSON Schema shipped at `tools/dashboard-config.schema.json`. (Deferred — current implementation validates structurally via `normalizeManifest` and ad-hoc shape checks; introducing a dedicated JSON Schema validator is a follow-up that needs a single validator-dependency choice.)
- [x] 2.3 Synthesize the manifest with a placeholder digest and confirm every `dashboard-browser-module-v1` required field is present.
- [x] 2.4 Read each declared sample-frames file and verify the frame `id` matches a declared `data_frames[].id`, that `results` is an array. (Per-field type checking against declared `fields` is deferred until 2.2 lands.)
- [x] 2.5 Read the sample-settings file and validate against the manifest's `settings_schema` when declared. (Light-touch: surfaces missing top-level keys as notes; full JSON Schema enforcement deferred with 2.2.)
- [x] 2.6 Print a green check on success, or a list of failures with file paths and suggested fixes.
- [x] 2.7 Wire the `build` command to run `validate` first and refuse to write `dist/` on validation failure.
- [x] 2.8 Add unit tests for each validation branch using fixture configs. (`tests/cli.test.mjs` — 4 new tests covering clean validate, missing manifest field, sample-frames declared-but-missing, missing renderer entry.)

## 3. HMR Dev Loop
- [x] 3.1 Replace the static-server dev path with Vite middleware mode. (`devCommandHmr` in `bin/serviceradar-dashboard.js` runs `createViteServer({middlewareMode: true, root: projectDir, plugins: [react()]})`.)
- [x] 3.2 Serve a `serveHarnessHtml` shell at `/` that imports the project's renderer entry as a Vite module. (`renderDevHarnessHtml` interpolates the entry path into a script tag; the path defaults to `src/main.jsx` and reads from `renderer.entry`.)
- [x] 3.3 Implement an HMR client in the harness shell that calls `import.meta.hot.accept` on the renderer module, disposes the previous mount via the documented `destroy()` contract, and remounts against the same root with a fresh host API. (`tools/dashboard-wasm-harness/dev.js` — `bootstrap` → `replaceRenderer` invokes `mounted.destroy()` then re-mounts with a new host API.)
- [x] 3.4 Re-run `validate` when `dashboard.config.mjs`, the manifest, or any sample fixture changes; surface failures in the harness error overlay rather than crashing the dev server. (`watchProjectForValidation` polls config + samples + fixtures via `fs.watchFile` and prints validation failures on save. Pushing failures into the harness error overlay via a Vite WebSocket message is a follow-up; the dev server itself does not crash.)
- [x] 3.5 Add `--no-hmr` for the legacy build-once behavior; flag removal is scheduled for one minor version after the new default lands. (`devCommandStatic` retains the prior path; `BOOLEAN_FLAGS` set in `parseArgs` flips `options.hmr` correctly.)
- [x] 3.6 Add `--open` that opens the harness URL in the default browser when the server starts. (`openBrowser` shells out to `open`/`xdg-open`/`start` depending on platform; best-effort.)
- [ ] 3.7 Add an integration test that spins up `dev`, edits a renderer file 50 times, and asserts each edit results in a remount within 200 ms with no orphaned host-API listeners. (Deferred — needs Playwright, which is gated on user trigger per memorized preference.)

## 4. Auto-Mounting Harness with Side Panel
- [x] 4.1 Replace the form-field harness UI with an auto-mount layout that fills the renderer surface immediately when URL params resolve. (`renderDevHarnessHtml` auto-mounts on page load via the `<script type="module">` block at the bottom of the dev shell; no button required.)
- [x] 4.2 Add a collapsible side panel exposing: theme toggle (drives `host.theme`), Mapbox token input (writes to `localStorage`, re-applies to `host.mapbox()` without remount), fixture picker (lists `Object.keys(config.fixtures)`), and a "Reload renderer" button. (`tools/dashboard-wasm-harness/dev.js#wireSidePanel` + `dev.css` 320px side panel.)
- [x] 4.3 Add a status bar showing renderer mount state, last frame timestamp, and the most recent host-API call (SRQL update, navigation request, popup open). (`#sr-status-bar` + `appendCallLog`. Last-frame timestamp is wired through `onFrameUpdate`; explicit visualization could be enriched once consumers ask for it.)
- [x] 4.4 Add a runtime error overlay covering the renderer surface when the renderer throws on mount, with the stack trace inline. Vite's default overlay continues to handle syntax errors. (`[data-error-overlay]` + `showError`.)
- [x] 4.5 Preserve the legacy form-field harness at `/?advanced` for cases that test against a manually-built `dist/`. (Dev server short-circuits to the legacy `index.html` when `?advanced` is in the URL.)
- [x] 4.6 Wire the fixture picker to swap the active sample-frames URL and remount the renderer. (`swapFixture` re-fetches the JSON, broadcasts to `frameListeners` if the renderer subscribed via `onFrameUpdate`, otherwise re-imports + remounts via `replaceRenderer`.)
- [ ] 4.7 Add browser smoke tests for theme toggle, Mapbox token persistence, fixture swap, and error overlay. (Deferred — needs Playwright; gated on user trigger per memorized preference.)

## 5. Project Scaffolder
- [x] 5.1 Add `tools/templates/react-map/` containing a slimmed-down Example-style React dashboard project. (Demonstrates `useDeckMap` + `useDeckLayers` + `useFrameRows` + `useFilterState` + `useIndexedRows` + `useMapPopup`. Two fixtures: `all-regions` and `americas-only`.)
- [x] 5.2 Add `tools/templates/react-table/` containing a frame-driven table dashboard with a `useFrameRows` example and a paginated row renderer. (Search + status filter + 25-row page; two fixtures: `all-up` and `with-failures`.)
- [x] 5.3 Add `tools/templates/react-blank/` containing the minimum viable browser-module dashboard.
- [x] 5.4 Implement `serviceradar-dashboard init <name> [--template react-map|react-table|react-blank] [--package-id com.example.<name>] [--no-install]`. (`initCommand` + `copyTemplateTree` + `applyReplacements`. Refuses non-empty targets unless `--force`; runs `npm install` unless `--no-install`; prints a friendly next-steps banner with the npm scripts.)
- [ ] 5.5 Wire a `create-serviceradar-dashboard` bin (or co-located `bin/create.js` on the SDK package) so `npm create @serviceradar/dashboard <name>` works without an extra install step. (Deferred — needs a one-time naming decision tied to the npm publish moment; either a sibling `@serviceradar/create-dashboard` package or a renamed bin in the SDK package.)
- [x] 5.6 Add tests that scaffold each template and assert placeholder swizzling. (`tests/cli.test.mjs` — 4 init tests cover scaffold + swizzle, refuse non-empty target, react-map fixtures + entry shape, unknown-template rejection. End-to-end `validate` + `build` against a fully `npm install`-ed temp project is heavier than fast unit tests should be — track via `9.4`.)
- [ ] 5.7 Keep templates in sync with UAL's React shell layout; add a CI step that compares each template's structure against a reference checksum and fails on drift. (Deferred to CI work.)

## 6. `serviceradar-cli dashboard publish`
- [x] 6.1 Add a `publish --instance <url> [--route <slug>] [--token <bearer>] [--enable] [--yes]` subcommand that POSTs the manifest and renderer artifact to the ServiceRadar dashboard package import endpoint. (Multipart/form-data POST to `${instance}/api/v1/dashboard-packages` with `manifest`, `renderer`, and `route` form fields. `--enable` follows up with `POST /api/v1/dashboard-packages/<id>/enable`.)
- [x] 6.2 Accept the bearer token from `--token` flag, `SERVICERADAR_TOKEN` env, or stored credentials (resolved via `resolveCredentialToken`) — never persist tokens to disk in the publish path.
- [x] 6.3 Verify the manifest digest matches the renderer digest before uploading; reject publishing on mismatch with a clear "rebuild via `serviceradar-cli dashboard build`" hint.
- [x] 6.4 Print the resolved instance URL, dashboard route, package version, renderer digest, and credential source before transferring; require `--yes` for non-interactive runs (auto-confirm on non-TTY).
- [x] 6.5 If `--enable` is passed, follow up the import with the dashboard-instance enable API call so the dashboard is live without an admin step.
- [x] 6.6 Add tests against a stubbed import endpoint and document the expected ServiceRadar API contract. (`tests/cli.test.mjs` — three new tests: stub server captures POST, digest-mismatch refusal with helpful hint, missing-credential refusal pointing at `auth login`.)
- [ ] 6.7 Coordinate with the dashboard package import API team to confirm the endpoint shape (`POST /api/v1/dashboard-packages` multipart + `POST /api/v1/dashboard-packages/<id>/enable`). The CLI currently targets these endpoints by convention — if the API team specs different paths, only the URL constants in `publishCommand` need to update.

## 7. CLI Polish
- [x] 7.1 Add `--mapbox-token` flag to `dev` and respect `MAPBOX_TOKEN` env; surface the resolved value in the harness side panel. (Already shipped in Section 3.)
- [x] 7.2 Improve every error message that previously dead-ended a developer to include the suggested next command. (`missing dashboard config` suggests `init`, missing renderer entry suggests the `renderer.entry` field, digest mismatch suggests `dashboard build`, missing credential suggests `auth login`, unknown template lists choices, non-empty target suggests `--force` or a different name. Audit pass complete.)
- [x] 7.3 Add a `serviceradar-cli --version` flag for diagnosing version mismatches. (Top-level flag prints `@serviceradar/cli <version>` from the package.json.)
- [x] 7.4 Add a `serviceradar-cli doctor` subcommand that prints the resolved Node, npm, Vite, and SDK versions plus the project's config path, renderer entry, and stored credential summary. (`doctor` covers runtime info, CLI install paths, dashboard config resolution, and credentials path; surfaces actionable suggestions when pieces are missing.)

## 8. Documentation
- [x] 8.1 Update `~/src/developer/priv/content/docs/v2/dashboard-sdk.md` with a "Quickstart" section that walks through `npm create @serviceradar/dashboard` → `dev` → edit → publish. Also adds dedicated "Authenticating", "Publishing", "Local Harness" (rewritten around `serviceradar-cli dashboard dev`), and "CLI Diagnostics" sections.
- [x] 8.2 Document `defineDashboardConfig`, the dashboard config schema, and the validate / publish commands. (`defineDashboardConfig` example shown in Quickstart and Composed Example; `validate` + `publish` get full subsections.)
- [x] 8.3 Update `~/src/serviceradar-sdk-dashboard/README.md` with the install-pulls-CLI-transitively note + a CLI section that points at the developer portal as canonical. Existing example npm scripts now use `serviceradar-cli dashboard *` form.
- [ ] 8.4 Add a "Templates" reference page describing each scaffolder template with screenshots. (Deferred — the scaffolder section in the developer portal doc covers the templates inline; a dedicated screenshot tour is a follow-up once Example parity verification produces canonical screenshots.)
- [x] 8.5 Document the `--no-hmr` deprecation timeline in the SDK changelog. (`~/src/serviceradar/js/cli/CHANGELOG.md` 0.1.0 entry covers the rename, the alias bin removal schedule, and the auth-endpoint coordination note.)

## 9. TypeScript Migration of the CLI

### Phase 1 — type-checked JS (this commit)
- [x] 9.1.1 Add `tsconfig.json` with `allowJs: true`, `checkJs: true`, `noEmit: true` so the existing JS gets type-checked without a full source rewrite.
- [x] 9.1.2 Add `typescript` and `@types/node` as dev deps; ship a `npm run typecheck` script gated on `tsc --noEmit`.
- [x] 9.1.3 Annotate the public CLI surface with JSDoc typedefs: `CredentialEntry`, `CredentialStore`, `ResolvedCredential`, `ValidationFailure`, `ValidationResult`. `resolveCredentialToken` and `validateProject` are fully typed.
- [x] 9.1.4 Wire `npm run ci` to run `typecheck` before `test` + `pack:check` so the type-check is enforced.
- [x] 9.1.5 Confirm `npm run typecheck` passes against the existing JS source.

### Phase 2 — full TS source rewrite (deferred)
- [ ] 9.2.1 Convert `bin/serviceradar-cli.js` and split into TypeScript modules under `src/{cli,args,config,manifest,validation,doctor,utils}.ts` plus `src/auth/{credentials,login,status,logout,index}.ts` and `src/dashboard/{init,build,manifest,validate,dev,publish,import,index}.ts`.
- [ ] 9.2.2 Add a `tsc` (or `tsup`) compile step that emits the runnable artifacts to `dist/` shipped in the publish bundle.
- [ ] 9.2.3 Rewrite `bin/serviceradar-cli.js` and `bin/serviceradar-dashboard.js` as thin shebang re-exports from the compiled `dist/`.
- [ ] 9.2.4 Update `package.json#bin` and `package.json#files` so the published artifacts include compiled JS plus source maps; the `.ts` source stays out of the tarball.
- [ ] 9.2.5 Confirm `npm pack --dry-run` does not ship the `src/*.ts` source in the tarball.
- [ ] 9.2.6 Confirm the existing `node --test tests/*.test.mjs` suite continues to pass against the compiled output.
- [ ] 9.2.7 Document the CLI build flow (compile-on-publish, source-only-in-repo) in the CLI contributor section of `README.md`.

## 11. Move CLI to ServiceRadar Monorepo (`~/src/serviceradar/js/cli/`)
- [x] 11.1 Create the `~/src/serviceradar/js/` top-level directory (sibling to `go/`, `elixir/`, `rust/`) and scaffold `js/cli/` as the home of `@serviceradar/cli`. (`bin/`, `harness/`, `templates/`, `tests/`, `package.json`, `README.md` written.)
- [x] 11.2 Move the existing CLI source from `~/src/serviceradar-sdk-dashboard/bin/serviceradar-cli.js` to `~/src/serviceradar/js/cli/bin/serviceradar-cli.js`. (TypeScript-source migration tracked in Section 9; the move itself is complete and the CLI runs from its new home.)
- [x] 11.3 Move the dev harness assets (`~/src/serviceradar-sdk-dashboard/tools/dashboard-wasm-harness/`) to `~/src/serviceradar/js/cli/harness/`. The CLI's `HARNESS_DIR` constant points at the new location.
- [x] 11.4 Move the scaffolder templates (`~/src/serviceradar-sdk-dashboard/tools/templates/`) to `~/src/serviceradar/js/cli/templates/`. The CLI's new `TEMPLATES_DIR` constant points at the new location.
- [x] 11.5 Author `js/cli/package.json` as `@serviceradar/cli`, ship the `serviceradar-cli` bin and a transitional `serviceradar-dashboard` alias bin, declare `@serviceradar/dashboard-sdk` as a runtime dep (`file:../../../serviceradar-sdk-dashboard` for local dev), and own the Vite + `@vitejs/plugin-react` deps that previously lived in the SDK.
- [x] 11.6 Drop both bin entries from `~/src/serviceradar-sdk-dashboard/package.json`; remove `bin/`, `tools/`, and `tests/cli.test.mjs` from the SDK repo; add `@serviceradar/cli` to SDK `dependencies` so `npm install @serviceradar/dashboard-sdk` pulls the CLI bin into `node_modules/.bin/serviceradar-cli` for customers; drop Vite + `@vitejs/plugin-react` from SDK `dependencies`.
- [x] 11.7 Restructure CLI dispatch into subcommand groups: `serviceradar-cli auth <login|status|logout>`, `serviceradar-cli dashboard <init|build|dev|validate|manifest|publish|import>`. (`dispatchAuth` + `dispatchDashboard` in `bin/serviceradar-cli.js`. The further split into `src/auth/*` and `src/dashboard/*` modules tracks with the TypeScript migration in Section 9.)
- [x] 11.8 Ship the transitional `serviceradar-dashboard` bin inside `@serviceradar/cli` that prints a deprecation notice and delegates to `serviceradar-cli dashboard *`. (`bin/serviceradar-dashboard.js`.)
- [x] 11.9 Update the scaffolder templates so `package.json#scripts` invoke `serviceradar-cli dashboard <command>` rather than the legacy `serviceradar-dashboard *` form.
- [x] 11.10 Move CLI tests (`tests/cli.test.mjs`) to `js/cli/tests/` and update them to call the new bin path via the new subcommand syntax. (10/10 pass in the new home; SDK runtime suite still 59/59 in its own repo.)
- [ ] 11.11 Add `js/cli/` to the monorepo root build configuration (Bazel `BUILD.bazel`, CI workflows) so the CLI ships as part of the same release surface but with its own published `package.json` version. Coordinate with the existing CHANGELOG / RELEASE_PUBLISHING flow used elsewhere in the monorepo. (Deferred — CLI builds and tests pass via `node --test` standalone today; Bazel + CI integration is its own follow-up.)

## 12. Auth Flow
- [x] 12.1 Add a `serviceradar-cli auth` subcommand group (`auth login` / `auth status` / `auth logout`).
- [x] 12.2 Implement `auth login --instance <url> [--no-browser]` running RFC 8628 device-code flow against the instance's `/api/v1/cli/auth/device` endpoint: request a device + user code, print the `verification_uri` and code, optionally open the browser, poll `/api/v1/cli/auth/token` with the device code until the user completes login or times out.
- [x] 12.3 Persist the issued long-lived token plus user identity to `~/.config/serviceradar/credentials.json` (Windows: `%APPDATA%\\serviceradar\\credentials.json`), keyed by instance URL, file mode `0600`, refusing group/world-writable parent directories. (`writeCredentials` opens with `mode: 0o600`; `ensureSafeDir` rejects parent dirs with mode bits 0o022 set.)
- [x] 12.4 Implement `auth status [--instance <url>]` printing the resolved instance, user, obtained-at, and expires-at — without leaking the token to stdout. (Test 17 asserts the `secret-token-do-not-leak` value never appears in stdout.)
- [x] 12.5 Implement `auth logout [--instance <url>]` removing the entry; with no instance flag, list existing entries and ask which to remove. (Test 18 covers the targeted-remove path.)
- [x] 12.6 Add a manual-token paste fallback that activates when the device-code endpoints return 404 or aren't yet shipped. (Test 16 spins up a 404 stub, verifies the CLI prints the fallback notice and persists the manually-provided token to the credential store.)
- [x] 12.7 Update `serviceradar-cli dashboard publish` (and any future instance-touching command) to resolve credentials in the order `--token` flag → `SERVICERADAR_TOKEN` env → stored credential matched by `--instance`. (`resolveCredentialToken` exported from the CLI core; `publish` consumes it.)
- [ ] 12.8 Reserve a `--web` flag (deferred default: device-code) for the PKCE-with-localhost-callback variant. (Deferred — not yet wired; flag name should not be reused.)
- [x] 12.9 Add CLI unit tests for credentials read/write, manual-token fallback, status non-leakage, and logout. (Tests 16, 17, 18; resolve-order coverage via the publish tests in Section 6.)
- [ ] 12.10 Document the auth flow in the developer portal alongside the publish walkthrough; include the expected ServiceRadar device-code endpoint contract so the API team can implement against it. (Section 8 docs work.)
- [ ] 12.11 Coordinate with the ServiceRadar API team on the `/api/v1/cli/auth/device` and `/api/v1/cli/auth/token` endpoint shapes (RFC 8628 conventions). (Coordination ticket; CLI side is ready and falls back to manual-token paste until the endpoints land.)

## 13. Validation
- [x] 13.1 Run `openspec validate improve-dashboard-sdk-developer-experience --strict`.
- [ ] 13.2 Add SDK unit tests for `defineDashboardConfig`, `validate`, the scaffolder, and `publish`.
- [ ] 13.3 Add browser integration tests for HMR (50-cycle remount), theme toggle, fixture picker, and error overlay.
- [ ] 13.4 Run `npx serviceradar-cli dashboard init` against each template in CI and confirm the resulting project builds, validates, and serves the dev harness.
- [ ] 13.5 Run a `serviceradar-cli dashboard publish` dry-run against a stubbed ServiceRadar import endpoint in CI.
- [ ] 13.6 Capture a "first dashboard in five minutes" walkthrough video or asciinema recording for the developer portal.
