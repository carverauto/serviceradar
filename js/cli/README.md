# `@serviceradar/cli`

The ServiceRadar developer CLI. Lives inside the ServiceRadar monorepo at
`~/src/serviceradar/js/cli/` and ships independently to npm as
`@serviceradar/cli`. Companion to `@serviceradar/dashboard-sdk` (the runtime
React/JS surface customer dashboards depend on).

## Subcommand groups

```text
serviceradar-cli auth      <login|status|logout>
serviceradar-cli dashboard <init|build|dev|validate|manifest|publish|import>
```

Help for either group:

```bash
serviceradar-cli help
serviceradar-cli auth help
serviceradar-cli dashboard --help     # delegates through to the dashboard subgroup
```

## Single install for developers

`@serviceradar/dashboard-sdk` declares `@serviceradar/cli` in its
`dependencies`, so a customer building a dashboard runs only:

```bash
npm install @serviceradar/dashboard-sdk
```

…and the CLI bin lands in `./node_modules/.bin/serviceradar-cli`. Project npm
scripts (`"dev": "serviceradar-cli dashboard dev"`) resolve it from the local
`.bin/`. For ad-hoc invocation: `npx serviceradar-cli ...`.

The legacy `serviceradar-dashboard` bin name is preserved as a transitional
alias that prints a deprecation notice and delegates to
`serviceradar-cli dashboard *`. Removal scheduled for the release after.

## Authoring loop

```bash
npm create @serviceradar/dashboard my-dashboard
cd my-dashboard
npm run dev          # SDK harness with HMR
npm run validate     # static check
npm run build        # write dist/ for publish
serviceradar-cli auth login --instance https://serviceradar.example.com
serviceradar-cli dashboard publish --instance https://serviceradar.example.com --route my-dashboard
```

## Auth

`serviceradar-cli auth login --instance <url>` runs the OAuth 2.0 Device
Authorization Grant flow (RFC 8628) against `/api/v1/cli/auth/device` and
`/api/v1/cli/auth/token`. Until those endpoints land on the ServiceRadar
side, the CLI falls back to manual token paste. Tokens persist to
`~/.config/serviceradar/credentials.json` (mode 0600), keyed by instance URL.

`auth status` prints the resolved identity without leaking the token.
`auth logout` removes a credential entry.

## Repository structure

```text
js/cli/
├── bin/
│   ├── serviceradar-cli.js          # canonical entry
│   └── serviceradar-dashboard.js    # transitional alias
├── harness/                         # browser-side dev harness
│   ├── index.html                   # legacy form-field harness (preserved at /?advanced)
│   ├── harness.js
│   ├── dev.js                       # HMR runtime
│   └── dev.css
├── templates/                       # scaffolder templates
│   ├── react-map/
│   ├── react-table/
│   └── react-blank/
├── tests/
└── package.json
```

## Development

This package depends on `@serviceradar/dashboard-sdk` via `file:` link during
local development. To work on it, run `npm install` here first; the SDK
should already be checked out at `~/src/serviceradar-sdk-dashboard/`.

## Documentation

The canonical Dashboard SDK + CLI reference lives on the developer portal:
[`developer.serviceradar.cloud/docs/v2/dashboard-sdk`](https://developer.serviceradar.cloud/docs/v2/dashboard-sdk).
