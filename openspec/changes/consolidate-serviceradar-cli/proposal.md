# Change: Consolidate the two `serviceradar-cli` tools

## Why

ServiceRadar ships **two different binaries that both answer to
`serviceradar-cli`**, and they share zero functionality:

- **Go CLI** (`go/cmd/cli` + `go/pkg/cli`, built as `serviceradar-cli`,
  shipped in the `.deb`/`.rpm` and Bazel image graph). It is the
  install/ops tool: bcrypt hashing, `generate-tls`, `generate-jwt-keys`,
  `spire-join-token`, `enroll`, `edge-package-*`, `nats-bootstrap`,
  `admin nats`, `update-config`/`update-gateway`. A single static,
  cross-platform binary with no runtime deps.
- **JS CLI** (`js/cli`, published as `@carverauto/serviceradar-cli`,
  `bin.serviceradar-cli` **and** `bin.serviceradar-dashboard`). It is the
  dashboard-SDK authoring tool: `auth login/status/logout`,
  `dashboard init/build/manifest/validate/dev/publish/import`, `doctor`.
  It requires Node >= 20 + npm + Vite.

The two tools **collide on the command name `serviceradar-cli`**, so which
tool a user gets depends entirely on how they installed it. Worse, the
richer authoring tool is gated behind an npm/Node toolchain that is
painful for operators — especially on Windows — who only need to
authenticate against an instance and drive the API.

Issue #4666 framed this as "port all the JS features to Go." A full port
is neither necessary nor possible: `dashboard build` and `dashboard dev`
literally invoke Vite + `@vitejs/plugin-react` to bundle an author's
**React/TSX renderer** into an ES module, and a React bundler cannot be
reimplemented in Go. Dashboard authoring is inherently a JS-ecosystem
job.

The real pain is narrower and fixable in two moves:

1. **The name collision** — kill it by renaming the JS tool to reflect
   what it actually is (a dashboard-SDK authoring tool), so it stops
   shadowing the native binary.
2. **The npm gate on authentication** — port the RFC 8628 device-code
   auth flow (plus the manual-token fallback) into the native Go
   `serviceradar-cli` so an operator can `serviceradar-cli auth login`
   and obtain a scoped token without ever installing Node. Both tools
   read and write the **same** credential store so a token minted by
   either is usable by the other.

The server side of device-code auth is covered by the separate
`add-cli-device-auth` change (the `POST /api/v1/cli/auth/device` and
`/api/v1/cli/auth/token` endpoints). This change is the **native Go
client** for that flow plus the tool-name separation.

## What Changes

### Rename the JS dashboard tool (remove the collision)
- **RENAME** the npm package `@carverauto/serviceradar-cli` to a
  dashboard-focused name (proposed: `@carverauto/serviceradar-dashboard`)
  and **drop the `serviceradar-cli` bin entry** so it no longer shadows
  the native binary. The `serviceradar-dashboard` bin stays. The tool
  keeps its full feature set (`init/build/dev/manifest/validate/publish/
  import/auth/doctor`) for React dashboard authors — nothing is removed
  from it.
- **UPDATE** every in-repo reference to the old bin/package name:
  `js/cli/package.json`, `js/cli/BUILD.bazel`, `js/cli/README.md`,
  `js/cli/CHANGELOG.md`, template `package.json` files under
  `js/cli/templates/`, help text that prints `serviceradar-cli`, and
  developer docs. Add a deprecation note to the CHANGELOG for the
  renamed package.
- **NOTE** the `serviceradar-cli` help text emitted by the JS tool is
  reworded to `serviceradar-dashboard`; a one-release transitional alias
  bin may be kept if npm consumers depend on the old name (Open Question).

### Port device-code auth into the Go CLI (`serviceradar-cli auth`)
- **ADD** an `auth` subcommand group to the Go CLI dispatch
  (`go/cmd/cli/main.go` + `go/pkg/cli`):
  - `auth login --instance <url> [--no-browser] [--token <existing>]
    [--scope <scope>]` — runs the OAuth 2.0 Device Authorization Grant
    (RFC 8628) against `POST /api/v1/cli/auth/device` then polls
    `POST /api/v1/cli/auth/token`, printing the verification URL + user
    code and (unless `--no-browser`) opening a browser. Falls back to
    manual-token paste when the device endpoint returns 404, matching the
    JS client so partially-deployed instances still work.
  - `auth status [--instance <url>]` — reports the stored credential
    (user, obtained-at, expires-at) for one or all instances.
  - `auth logout [--instance <url>]` — deletes the stored credential.
- **ADD** a credential store in Go that is **byte-compatible** with the
  JS tool's `~/.config/serviceradar/credentials.json`
  (XDG_CONFIG_HOME-aware; `%APPDATA%\serviceradar\credentials.json` on
  Windows; file mode `0600`; refuse group/world-writable parent dir;
  layout `{version:1, instances:{<normalized-url>:{token, user?,
  obtained_at?, expires_at?}}}`). A token written by the JS `auth login`
  MUST resolve in the Go tool and vice-versa.
- **ADD** a shared token-resolution helper with the JS precedence order:
  `--token` flag -> `SERVICERADAR_TOKEN` env -> stored credential for the
  requested instance.
- **REUSE** the existing Go `serviceradar-cli` HTTP client conventions
  and error surface; no new heavyweight dependency — device-code polling
  is `net/http` + `encoding/json`.

### Out of scope (explicit)
- `dashboard build` / `dashboard dev` stay in the (renamed) JS tool. The
  Go CLI does **not** shell out to Vite.
- `dashboard publish` is **not** ported in this change (the artifact it
  uploads is produced by the JS bundler); it stays in the JS tool, which
  now reads the shared credential store the Go `auth login` can populate.
  A follow-up may add `serviceradar-cli dashboard publish` in Go once the
  build artifact contract is stable — tracked as an Open Question.
- PKCE-with-localhost-callback (`--web`) is **not** ported; the Go client
  ships device-code + manual fallback only, matching the server rollout
  order in `add-cli-device-auth` (PKCE is a server-side follow-up).

## Impact

- **Affected specs**: NEW capability `serviceradar-cli-auth`.
- **Affected code**:
  - `go/cmd/cli/main.go` — dispatch `auth` group.
  - `go/pkg/cli/auth.go` (new) — device-code flow + status/logout.
  - `go/pkg/cli/credentials.go` (new) — credential store + token
    resolution, byte-compatible with the JS layout.
  - `go/pkg/cli/flags.go`, `help.go`, `types.go` — new flags/help.
  - `go/pkg/cli/*_test.go` — device-code polling, credential
    round-trip, JS-interop fixture, token precedence.
  - `js/cli/package.json`, `BUILD.bazel`, `README.md`, `CHANGELOG.md`,
    `templates/*/package.json`, help strings — rename.
  - `build/packaging/cli/**` — unchanged binary name (`serviceradar-cli`
    stays the Go tool); confirm no packaging references the JS bin.
  - Docs referencing either `serviceradar-cli` install path.
- **Compatibility**: The Go `serviceradar-cli` gains subcommands; all
  existing subcommands are untouched. The JS tool is renamed — an npm
  version bump + deprecation of the old package name. Credential files
  written by prior JS versions are read unchanged (same path + schema).
- **Dependencies**: consumes the server endpoints from
  `add-cli-device-auth`; does not block on it (manual-token fallback
  covers instances that have not deployed those endpoints yet).
