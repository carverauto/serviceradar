---
title: ServiceRadar CLI
---

# ServiceRadar CLI

The `serviceradar` command-line tool bundles the day-to-day administrative
operations for a ServiceRadar deployment: hashing admin passwords, generating
certificates and JWT keys, managing edge onboarding packages, and bootstrapping
NATS.

## Where the binary lives

The CLI ships as the **`serviceradar-cli`** package and installs the binary at
`/usr/local/bin/serviceradar-cli`. In Kubernetes deployments it is available in
the ServiceRadar **tools pod**. On standalone hosts (core, gateway, agent), it
is installed alongside the service it administers.

Examples in this page use `serviceradar` as the command name; on a host where
only the package binary is present, invoke it as `serviceradar-cli`.

Run with no subcommand and no arguments to launch an interactive TUI; run with
`-help` for the built-in usage summary.

## Default mode: bcrypt password hashing

With no subcommand, the CLI generates a **bcrypt** hash, used for the admin
password in `core.json`. Bcrypt cost defaults to `12`.

```bash
# Hash a password passed as an argument
serviceradar mypassword

# Hash a password read from stdin
echo mypassword | serviceradar

# Launch the interactive TUI (no args, attached terminal)
serviceradar
```

When input is piped or an argument is supplied, the CLI runs non-interactively
and prints the hash. Feed the result into `update-config`.

## `update-config`

Writes a new admin password hash into `core.json`.

```bash
serviceradar update-config \
  -file /etc/serviceradar/core.json \
  -admin-hash '$2a$12$...'
```

| Flag | Description |
|------|-------------|
| `-file` | Path to the `core.json` config file. |
| `-admin-hash` | Bcrypt hash for the admin user. |

## `update-gateway`

Adds or removes service checks in `gateway.json`.

```bash
# Add a checker
serviceradar update-gateway -file /etc/serviceradar/gateway.json -type sysmon

# Remove a checker
serviceradar update-gateway -file /etc/serviceradar/gateway.json -action remove -type sysmon

# Enable all standard checkers
serviceradar update-gateway -file /etc/serviceradar/gateway.json -enable-all
```

| Flag | Description |
|------|-------------|
| `-file` | Path to `gateway.json`. |
| `-action` | `add` or `remove` (default `add`). |
| `-agent` | Agent name in `gateway.json` (default `local-agent`). |
| `-type` | Service type (e.g. `sysmon`, `rperf-checker`, `snmp`). |
| `-name` | Service name (defaults to the service type). |
| `-details` | Service details, e.g. `IP:port` for gRPC checkers. |
| `-enable-all` | Enable all standard checkers. |

## `generate-tls`

Generates the mTLS certificate set used by ServiceRadar services.

```bash
serviceradar generate-tls -ip 192.168.1.10,10.0.0.5
serviceradar generate-tls --non-interactive          # uses 127.0.0.1
serviceradar generate-tls --add-ips -ip 10.0.0.5     # extend existing certs
```

| Flag | Description |
|------|-------------|
| `-ip` | Comma-separated IP addresses to include in the certificates. |
| `-cert-dir` | Output directory (default `/etc/serviceradar/certs`). |
| `-add-ips` | Add IPs to existing certificates instead of regenerating. |
| `-non-interactive` | Run unattended using `127.0.0.1`. |

## `generate-jwt-keys`

Generates an RS256 keypair for signing API JWTs and updates `core.json`.

| Flag | Description |
|------|-------------|
| `-file` | Path to `core.json` (default `/etc/serviceradar/config/core.json`). |
| `-kid` | Key ID embedded in the JWT header (auto-derived by default). |
| `-bits` | RSA key size in bits (default `2048`). |
| `-force` | Overwrite existing RS256 keys if present. |

## `spire-join-token`

Requests a SPIRE join token from the core API, and optionally registers a
downstream (nested) SPIRE server entry.

```bash
serviceradar spire-join-token \
  -core-url https://core.example.serviceradar.cloud \
  -api-key "$SERVICERADAR_API_KEY" \
  -downstream-spiffe-id spiffe://example.dev/ns/demo/gateway-nested-spire \
  -selector unix:uid:0 -selector unix:gid:0
```

| Flag | Description |
|------|-------------|
| `-core-url` | Core API base URL (default `http://localhost:8090`). |
| `-api-key` / `-bearer` | Credentials for authenticating with core. |
| `-ttl` | Join token TTL in seconds. |
| `-agent-spiffe-id` | Optional alias SPIFFE ID for the agent. |
| `-no-downstream` | Skip registering a downstream entry. |
| `-downstream-spiffe-id` | SPIFFE ID for the downstream gateway SPIRE server. |
| `-selector` | Downstream selector; repeatable. |
| `-x509-ttl` / `-jwt-ttl` | Downstream SVID TTLs in seconds. |
| `-dns-name` / `-federates-with` | Downstream DNS names / federated trust domains; repeatable. |
| `-output` | Write the response JSON to a file. |

## `enroll`

Enrolls an edge agent or collector against core using an onboarding token
(`edgepkg-v3` or `collectorpkg-v2`). This writes the agent/collector config and
fetches certificates.

```bash
serviceradar enroll -token "<onboarding-token>"
```

| Flag | Description |
|------|-------------|
| `-token` | Enrollment token. |
| `-core-url` | Explicit HTTPS Core API base URL. When supplied, it overrides the URL embedded in the signed token; otherwise the embedded URL is used. |
| `-host-ip` | Override the detected host IP (agent enrollment). |
| `-config` | Agent config path (default `/etc/serviceradar/agent.json`). |
| `-config-dir` / `-config-file` | Collector config directory / filename. |
| `-cert-dir` | Certificate directory (default `/etc/serviceradar/certs`). |
| `-creds-dir` | Collector credentials directory (default `/etc/serviceradar/creds`). |
| `-force` | Overwrite existing config/certs. |
| `-ca-file` | CA bundle for verifying the core API TLS certificate. |

See [Edge Agent Onboarding](./edge-agent-onboarding.md) for the end-to-end flow.

## `edge package` — onboarding package management

The `edge package` command group manages onboarding packages issued by core.
These packages produce the tokens consumed by `enroll`.

```bash
serviceradar edge package create --label "site-a-gateway" --component-type gateway
serviceradar edge package list
serviceradar edge package show --id <package-id>
serviceradar edge package download --id <package-id> --download-token <token>
serviceradar edge package revoke --id <package-id>
serviceradar edge package token --id <package-id> --download-token <token>
serviceradar edge package mtls --label "macbook-01"
```

| Subcommand | Purpose |
|------------|---------|
| `create` | Issue a new onboarding package and emit the structured token. |
| `list` | List packages, with filters for status, component type, gateway, etc. |
| `show` | Display detailed information for a package. |
| `download` | Download onboarding artifacts as `tar.gz` or JSON. |
| `revoke` | Revoke a package and its downstream entry. |
| `token` | Emit a signed `edgepkg-v3` token for an existing package. |
| `mtls` | Shorthand for `create` with `checker:sysmon-osx` and mTLS defaults. |

All `edge package` subcommands accept `--core-url`, `--api-key`/`--bearer` for
authentication, and `--output text|json`. Key flags for `create`:

| Flag | Description |
|------|-------------|
| `--label` | Display label for the package (required). |
| `--component-type` | `gateway`, `agent`, or `checker[:kind]` (default `gateway`). |
| `--component-id` | Optional component identifier override. |
| `--parent-type` / `--parent-id` | Parent component type and identifier. |
| `--gateway-id` | Gateway identifier override. |
| `--site` | Site/location note. |
| `--metadata-json` / `--metadata-file` | Metadata JSON payload. |
| `--selector` | SPIRE selector; repeatable. |
| `--join-ttl` / `--download-ttl` | Token TTLs (e.g. `30m`, `24h`). |
| `--checker-kind` / `--checker-config-json` | Checker kind and config (for `component-type checker`). |
| `--datasvc-endpoint` | Datasvc/KV gRPC endpoint override. |

> The hyphenated aliases `edge-package-download`, `edge-package-token`, and
> `edge-package-revoke` are equivalent to the corresponding `edge package`
> subcommands and are kept for backward compatibility.

## `nats-bootstrap`

Bootstraps NATS for a deployment: generates the operator, accounts, and creds
files used by ServiceRadar's messaging layer.

```bash
serviceradar nats-bootstrap --token "<platform-bootstrap-token>"
serviceradar nats-bootstrap --local            # offline, no core API
serviceradar nats-bootstrap --verify --config /etc/nats/nats.conf
```

| Flag | Description |
|------|-------------|
| `-core-url` | Core base URL. |
| `-api-key` / `-bearer` / `-token` | Authentication and platform bootstrap token. |
| `-output-dir` | Where to write NATS config files (default `/etc/nats`). |
| `-operator-name` | NATS operator name (default `serviceradar`). |
| `-import-operator-seed` | Import an existing operator seed instead of generating one. |
| `-local` | Generate operator and accounts locally without the core API. |
| `-jetstream` / `-jetstream-dir` | Enable JetStream and set its storage directory. |
| `-tls-cert` / `-tls-key` / `-tls-ca` / `-no-tls` | TLS settings for the NATS server. |
| `-verify` / `-config` | Verify an existing NATS bootstrap against a `nats.conf`. |
| `-output` | Output format: `text` or `json`. |

## `admin nats`

Inspects and manages NATS state through the core API.

```bash
serviceradar admin nats status
serviceradar admin nats accounts
serviceradar admin nats generate-bootstrap-token
```

| Subcommand | Purpose |
|------------|---------|
| `status` | Show the current NATS bootstrap status. |
| `accounts` | List NATS accounts. |
| `generate-bootstrap-token` | Generate a platform bootstrap token for `nats-bootstrap`. |

These subcommands accept `--core-url` and `--api-key`/`--bearer` for
authentication, and support `--output json`.
