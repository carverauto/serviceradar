# Change: Edge onboarding commands in the ServiceRadar JS CLI

Tracking: carverauto/serviceradar-control#154 (tenant edge connectivity launch validation).

## Why

An operator bringing an edge Linux host (Oracle Linux 9, Node 20) onto a hosted tenant has to use
the web UI today. They create the agent package there, copy the enrollment command, create the
collector, download its bundle, and assemble the NATS leaf by hand. `@carverauto/serviceradar-cli`
(`js/cli`) already handles device-code login, per-instance credentials and TLS CA handling, but it
has no edge commands. Its device login only requests `dashboard.publish`, so its tokens cannot
reach the edge APIs.

The server side is mostly in place. `EdgeController` (`/api/admin/edge-packages`),
`CollectorController` (`/api/admin/collectors`, `/api/admin/nats/account`) and the token-gated
bundle routes are live. The control-plane change behind #154 adds the `edge.manage` narrow CLI
scope and a new `EdgeSiteController` (`/api/admin/edge-sites`) whose bundle carries a site's NATS
leaf configuration.

Edge hosts also hit a naming collision. The `serviceradar-agent` package ships
`/usr/local/bin/serviceradar-cli` as a deprecated `srctl` alias, and npm's global prefix on Linux
is `/usr/local`, so the agent package and this npm package overwrite each other's bin.

## What Changes

- `auth login` requests `dashboard.publish edge.manage` by default. `--scope` still overrides,
  and comma-separated values are normalised to the space-separated form the server confines on.
  A server policy that refuses the scope (`invalid_scope`) is reported with a remedy rather than
  falling back silently.
- `auth login --web` fails with "not supported by this server, use the device flow" when
  `/api/v1/cli/auth/authorize` is not routed. It no longer drops to manual token paste. The flag
  stays.
- New commands, each with `--json` output, human tables by default, and 401/403 errors that name
  the fix (re-run `auth login` for a missing `edge.manage` scope or a rejected token, and the
  `settings.edge.manage` permission for an RBAC denial):
  - `agent list`
  - `edge package create|list|show|revoke|download`
  - `edge site create|list|show|bundle [--wait]`
  - `collector create|list|show|revoke|download`
  - `nats account status`
- Edge-host install helpers `edge install agent|leaf|collector`. They need root, print every
  action before taking it, and support `--dry-run`. Each one downloads the matching release
  RPM/deb for `--version` from GitHub releases, installs it with dnf (or apt-get), then runs
  `srctl enroll --core-url <instance> --token <t>` for an agent, or applies the leaf bundle
  (`setup.sh`) or collector bundle (`update.sh`). The server exposes no version endpoint, so
  `--version` is required.
- New `srcloud` bin alias. The README documents the `serviceradar-cli` collision and adds an
  end-to-end edge onboarding walkthrough.
- Package version 0.1.10 → 0.2.0. Publishing to npm stays with the owner.

## Impact

- Affected specs: new capability `cli-edge-onboarding`.
- Affected code: `js/cli/src/edge/*` (new), `js/cli/src/auth/login.ts`, `js/cli/src/args.ts`,
  `js/cli/src/cli.ts`, `js/cli/package.json`, `js/cli/README.md`, `js/cli/tests/edge.test.mjs`.
- Server contract the CLI relies on (delivered by the control-plane/web-ng side of #154):
  - `edge.manage` accepted by the CLI device flow (including on existing
    `authorization_settings` rows) and allowlisted in `NarrowScopes` for the routes above.
  - `POST /api/admin/edge-packages` returns the signed `edgepkg-v3` token as `onboarding_token`.
    Today only the UI mints it. Without it the CLI warns and points at the UI.
  - `POST /api/admin/collectors` mints an enrollment token and returns it as
    `enrollment_token`. Today the API create path sets no token hash, so its bundle cannot be
    downloaded.
  - Agents: `GET /api/admin/agents` (`{data:[{uid,...}]}`) or `GET /api/v2/agents` reachable by
    `edge.manage`. The CLI tries the former and falls back to the latter on 404.
