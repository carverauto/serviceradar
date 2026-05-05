# Change: Improve dashboard SDK developer experience

## Why

The dashboard SDK is feature-complete from a runtime perspective — query state, frame ergonomics, indexed local filtering, map runtime, popups, npm publishing infrastructure, and an existing CLI at `bin/serviceradar-dashboard.js` with `build` / `manifest` / `dev` / `import` commands. But the path from "I want to build a custom ServiceRadar dashboard" to "my dashboard renders against sample data with hot reload" is still rough enough that a first-time author will probably give up.

This change **introduces `@serviceradar/cli`** as the canonical npm-distributed ServiceRadar developer CLI, shipping the `serviceradar-cli` bin. The `@serviceradar/dashboard-sdk` runtime library stays at its current name; dashboard projects continue to depend on it for the React hook surface (`useFrameRows`, `useDeckMap`, etc.).

**CLI lives in the ServiceRadar monorepo. SDK stays in its own repo.**

- `~/src/serviceradar-sdk-dashboard/` continues to ship `@serviceradar/dashboard-sdk` — the runtime React/JS surface that customer dashboard source imports (`useFrameRows`, `useDeckMap`, etc.). Declares `@serviceradar/cli` in `dependencies` so `npm install @serviceradar/dashboard-sdk` pulls the CLI into `node_modules/.bin/serviceradar-cli` automatically.
- `~/src/serviceradar/js/cli/` (new) is the home of `@serviceradar/cli` — a bin-only package containing `serviceradar-cli`, the dev harness, the scaffolder templates, the auth credentials store, and every subcommand under `dashboard` and `auth`. It lives inside the ServiceRadar monorepo at a new top-level `js/` directory (sibling to `go/`, `elixir/`, `rust/`) so it sits next to the Go CLI, the Elixir web-ng, the Rust SRQL, the Docker compose stack, and the OpenSpec proposals that drive its surface. Depends on `@serviceradar/dashboard-sdk` as a runtime dep so it knows the manifest schema and config shape.

Putting the CLI in the monorepo keeps it next to the proposals that drive its surface and lets it grow non-dashboard subcommand groups over time (auth today, future areas like plugin / observability / data) without going to a separate repo each time. The CLI's release cadence is independent of the rest of the monorepo because it publishes a single npm package with its own `package.json` version. Customers still see one `npm install` and one `npx serviceradar-cli`: the SDK's `dependencies` entry makes the CLI ride along automatically. During local development the SDK repo resolves the CLI via a `file:` link (`@serviceradar/cli: file:../serviceradar/js/cli`); once the CLI publishes to npm that link becomes a normal version range.

The Go ServiceRadar CLI at `go/cmd/cli` is intentionally **not** the canonical developer CLI: it stays the cluster-ops binary deployed onto the `tools` pod for TLS / JWT / NATS / edge-package workflows. Packaging a Go binary into an npm package would force platform-specific distribution channels and break the one-install promise that drives the rest of this design. The two CLIs cover orthogonal audiences.

**Subcommand groups.** `serviceradar-cli` is structured around groups so it can grow beyond dashboards over time:

- `serviceradar-cli auth <login|status|logout>` — device-code flow against a ServiceRadar instance, persists a long-lived token at `~/.config/serviceradar/credentials.json`. Becomes the default credential source for any instance-touching subcommand.
- `serviceradar-cli dashboard <init|build|dev|validate|manifest|publish|import>` — the dashboard package authoring loop, formerly under the standalone `serviceradar-dashboard` bin. The subcommand contracts that already shipped (build / manifest / dev / import) keep their current behavior at their new path; new subcommands (`init`, `validate`, `publish`) are additions.
- Future groups (e.g. `serviceradar-cli plugin`, `serviceradar-cli observability`) can land later without renaming the bin.

The pre-existing `serviceradar-dashboard` bin name is kept as a transitional alias for one minor version that delegates to `serviceradar-cli dashboard *`, so customer scripts that already invoke it do not break. The transitional alias is removed in the release after.

**Scaffolder flow.** `npm create @serviceradar/dashboard <name>` (or `npx serviceradar-cli init <name>` once the user has the CLI in `node_modules/.bin/` from any prior install) scaffolds a project that declares `@serviceradar/dashboard-sdk` in its `dependencies`. The follow-up `npm install` inside the new project pulls in the SDK plus the CLI as a transitive dep, so `npm run dev` resolves `serviceradar-cli` from `./node_modules/.bin/` automatically. The CLI never requires a global Go install, never requires a platform-specific binary download, and never asks the user to manage two CLIs.

**Dev loop.** The `dev` subcommand changes from one-shot build + static-serve to Vite middleware mode + HMR; `--no-hmr` preserves the prior behavior for one minor version. The harness URL contract (`?manifest=&wasm=&frames=&settings=`) is preserved at `/?advanced` so any external scripts that already point at the manual harness keep functioning.

**TypeScript first.** The CLI package is authored in TypeScript (`bin/*.ts` and `src/*.ts` inside `@serviceradar/cli`), compiled to JS at publish time so consumers continue to see pre-compiled `.js` artifacts in their `node_modules/`. The TypeScript compile step is internal build hygiene and does not change the consumer install experience. The `@serviceradar/dashboard-sdk` runtime library continues to ship pre-compiled `.js` + `.d.ts` artifacts in the same shape it does today.

**Auth coordination.** The device-code login flow (`auth login`) is **new ServiceRadar API work**: the instance needs `/api/v1/cli/auth/device` (issue device + user code) and `/api/v1/cli/auth/token` (poll until login completes) following RFC 8628 conventions. The CLI ships ahead of those endpoints with a manual-token paste fallback so the credential store is exercised end-to-end against existing token issuance. The CLI changelog flags the device-code login as "lights up once the instance ships the device-code endpoints"; once they ship, no CLI-side change is required beyond a feature-flag flip.

No customer scripts that depend on the existing dashboard SDK CLI break.

Specifically: there is no project scaffolder (a new dashboard starts from `mkdir foo && npm init` and copying `tools/dashboard-wasm-harness/examples/react-dashboard/` by hand), the `dev` command runs a one-shot Vite production build and serves static — every code change is a Ctrl-C + re-run + page reload + click "Run Renderer" cycle of roughly ten seconds, the harness still has a "Run Renderer" button inherited from the WASM era, the `dashboard.config.mjs` schema is implicit in `bin/serviceradar-dashboard.js` with no TypeScript types, sample-frames JSON has no schema or generator, and there is no `validate` command for catching configuration errors before a build. Each of these is a small papercut on its own; together they make the SDK feel like an internal tool rather than something a customer would gladly adopt.

This change closes the developer-experience gap. The audience is the customer building their first dashboard package against a documented `@serviceradar/dashboard-sdk` install, not the ServiceRadar team. Every fix is judged against the question: would a developer who installed `@serviceradar/dashboard-sdk` for the first time today get to a working dev loop in under five minutes without reading the SDK source?

## What Changes

- Add a `npm create @serviceradar/dashboard <name>` project scaffolder (backed by `serviceradar-cli init`) using `tools/templates/<name>/` template directories (default `react-map`, plus `react-table` and `react-blank` to start). The scaffolder copies the template, swizzles project name and identifier, runs `npm install`, and prints a "next steps" message pointing at `serviceradar-cli dashboard dev`.
- Replace the one-shot build + static-server `dev` command with a Vite-middleware-mode dev server that serves the harness HTML and the project's renderer entry through Vite's module graph, so file edits propagate via Vite HMR and the renderer remounts in roughly 100 ms instead of 10 s. The CLI gains a `--no-hmr` fallback for environments that need the legacy build-once behavior.
- Replace the form-field harness UI with an auto-mounting harness that mounts the renderer immediately when URL params are present and exposes a side panel for theme toggle, sample-frames fixture picker (lists `fixtures/*.json` from the project), Mapbox token field (persists to `localStorage`), and a "reload renderer" button. The harness uses `import.meta.hot.accept` against the Vite module so HMR propagates without a full page reload.
- Add a `defineDashboardConfig({...})` helper exported from `@serviceradar/dashboard-sdk/config` with full TypeScript types covering `manifest`, `renderer`, `samples`, `vite`, and `build` so editors give field-level intellisense; existing plain-object configs continue to work.
- Add a `serviceradar-cli dashboard validate` command that statically checks the dashboard config shape, manifest required fields after digest stamping, sample-frames against declared `data_frames`, and sample-settings against any declared `settings_schema` — without running a build.
- Add a `serviceradar-dashboard auth` subcommand group (`auth login` / `auth status` / `auth logout`) that runs an OAuth device-code-style flow against the configured ServiceRadar instance: the CLI opens a browser (or prints a verification URL + user code that can be pasted into one), the developer logs in through the ServiceRadar UI, and the CLI stores the issued long-lived token under `~/.config/serviceradar/credentials.json` (keyed by instance URL). Subsequent CLI invocations pick up the stored token automatically, so `publish` and similar instance-touching commands do not require `--token` or `SERVICERADAR_TOKEN` once the developer has logged in. The credential file is per-user, never written to project source, never committed by the scaffolder, and is documented as the supported way to authenticate from a developer machine.
- Add a `serviceradar-dashboard publish --instance <url>` first-class deploy path that uploads the manifest and renderer artifact to a ServiceRadar instance over the existing dashboard package import API. The credential resolution order is: `--token` flag → `SERVICERADAR_TOKEN` env → stored credentials from `auth login`. Customers no longer need to write a project-supplied import script to push their dashboard from local dev to a real ServiceRadar deployment.
- Add a `--mapbox-token` flag (and `MAPBOX_TOKEN` env fallback) to `dev` so the token can come from outside `sample-settings.json`, and surface the same value in the harness side panel.
- Add an `--open` flag to `dev` that opens the harness URL in the default browser when the server starts.
- Improve every CLI error message that previously dead-ended a developer to include the suggested next command (e.g. "missing dashboard config; run `serviceradar-dashboard init` or create `dashboard.config.mjs`").
- Document the full developer flow on `developer.serviceradar.cloud/docs/v2/dashboard-sdk` and the SDK README: scaffold → dev with HMR → swap fixtures → validate → publish.

## Impact

- Affected specs: dashboard-sdk
- Affected code:
  - `/home/mfreeman/src/serviceradar/js/cli/` (new monorepo directory at a fresh top-level `js/`) — home of `@serviceradar/cli`. Owns:
    - `bin/serviceradar-cli.ts` (TypeScript source) plus `bin/serviceradar-dashboard.ts` (transitional alias delegating to `serviceradar-cli dashboard *`).
    - `src/auth/*` (credentials store, device-code flow client, manual-token fallback).
    - `src/dashboard/*` (relocated `build`, `manifest`, `dev`, `import`, `validate`, plus new `init` and `publish`).
    - `harness/*` (relocated dev harness HTML/CSS/JS, formerly `tools/dashboard-wasm-harness/`).
    - `templates/{react-map,react-table,react-blank}/` (relocated scaffolder templates).
    - `tests/*` (relocated CLI tests).
    - `package.json`, `tsconfig.json`, build scripts. Compiles to JS at publish time.
  - `/home/mfreeman/src/serviceradar-sdk-dashboard/src/config.{js,d.ts}` (new — `defineDashboardConfig` helper, ships in the runtime SDK so customer dashboards can `import {defineDashboardConfig} from "@serviceradar/dashboard-sdk/config"`).
  - `/home/mfreeman/src/serviceradar-sdk-dashboard/package.json` — drops the `serviceradar-dashboard` bin entry; adds `@serviceradar/cli` to `dependencies` so installing the SDK still pulls the CLI bin into the customer's `node_modules/.bin/`.
  - `/home/mfreeman/src/serviceradar-sdk-dashboard/bin/` and `/home/mfreeman/src/serviceradar-sdk-dashboard/tools/` — emptied; CLI source and harness assets move into the monorepo.
  - `/home/mfreeman/src/developer/priv/content/docs/v2/dashboard-sdk.md` (documentation walkthroughs for the new `serviceradar-cli` flow; scaffold → auth → dev with HMR → validate → publish).
  - **ServiceRadar API (new endpoints, separate change ticket):** `/api/v1/cli/auth/device` and `/api/v1/cli/auth/token` following RFC 8628 conventions. The CLI ships ahead of these endpoints with a manual-token paste fallback.
- Follow-up validation: SDK unit tests for the config helper and validate command, CLI unit tests for the auth credentials store + device-code flow + manual-token fallback, integration tests that scaffold a project from each template and run the dev / build / validate / publish flow, browser-side tests that exercise HMR on file change, end-to-end manual verification of `auth login` + `publish` against a local ServiceRadar instance once the device-code endpoints land.
