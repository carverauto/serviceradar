# ServiceRadar OpenText Network Operations Management Inventory Plugin

This directory contains the ServiceRadar Go/TinyGo Wasm plugin that collects a
complete, bounded device inventory from OpenText Network Automation's
automation wrapper. ServiceRadar schedules the plugin once per day and on
demand, then reconciles its `serviceradar.device_discovery.v1` output through
DIRE.

The implementation follows the approved ServiceRadar OpenSpec change
`add-external-inventory-wasm-plugin-contract` and the linked NCO change
`source-nac-opentext-network-automation-inventory-from-serviceradar`.

## Security Boundary

- The plugin can execute only fixed, read-only OpenText Network Automation
  commands: `list device` for inventory, `list config` then
  `show config -mask` for the `opentext-nom.config.retrieve` action, and
  `show configlet` for the `opentext-nom.interface.check` schedule. Operators
  cannot choose the command. The plugin reads configs NA already stored and
  never opens a device session.
- Interface config checks return verdicts only (compliant, non-compliant or
  unknown, plus the missing patterns); the interface configuration text is not
  placed in results. See [docs/configuration.md](docs/configuration.md).
- A retrieved config is masked by NA (passwords and SNMP communities become
  `xxx`) and staged only as a plugin artifact. It is never written into the
  result details, because status details are readable by viewers.
- Query parameters are validated against a strict allowlist.
- Username and password are injected into the OAuth form by the ServiceRadar
  agent host and are never exposed to Wasm.
- The short-lived bearer token is held only in agent memory (and, for the local
  host, in process memory) and reused for at most 15 minutes; see the OAuth
  token cache notes in `docs/configuration.md`.
- Partial or oversized inventory snapshots are rejected rather than emitted.

## Development

```sh
go test ./...
go vet ./...
cd ../../../..
bazel build //build/wasm_plugins:opentext_nom_inventory_bundle
```

The focused Go commands run from this directory. The Bazel command runs from
the ServiceRadar repository root and uses the repository-pinned Go and TinyGo
toolchains to build the WASI module and deterministic signed-package input. The
bundle contains `plugin.yaml`, `config.schema.json`, `plugin.wasm`, and the
provider-owned configuration guide.

### Source-native integration test

The non-TinyGo entry point runs the normal config loader, collector, host HTTP,
and result builder without building or deploying Wasm. Put public endpoint and
query settings in a local config file, then keep credentials in `.env` or the
process environment:

```dotenv
SERVICERADAR_PLUGIN_CONFIG_FILE=testdata/local-config.json
SERVICERADAR_CREDENTIAL_USERNAME=local-user
SERVICERADAR_CREDENTIAL_PASSWORD=local-password
```

```sh
go run .
```

Set `SERVICERADAR_PLUGIN_ACTION_FILE` when testing a producer action. Its JSON
is inserted as `action_invocation`, and `input_values` are handled by the same
runtime config path as an agent-dispatched action. Process variables override
values in `.env`. The local host performs the OAuth exchange and bearer
injection, rejects redirects and mismatched endpoints, and prints only the
submitted plugin result. It does not grant package approval or production
authorization.

The `opentext-nom.config.retrieve` action stages the NA-stored config as an
artifact, so it also needs a directory for the local host to write it to. Keep
it outside the repository: the file holds the device's full configuration, and
NA masking does not cover everything.

```dotenv
SERVICERADAR_PLUGIN_ACTION_FILE=/path/outside/repo/retrieve.json
SERVICERADAR_LOCAL_ARTIFACT_DIR=/path/outside/repo/artifacts
```

```json
{"action_id":"opentext-nom.config.retrieve","input_values":{"device_id":"<NA device ID>","device_uid":"sr:<device uid>"}}
```

The run prints the result JSON (which carries only the artifact reference) and
reports each staged artifact's path on stderr.

## Configuration

Operators configure this plugin from **Settings -> Networks -> Credential
Rules**, not from Plugin Packages -> Assign to Agent. The rule's Scope Value is
the agent that executes the Wasm module. Service-account username and password
go in a credential secret; the wrapper and NNMi URLs go on that same rule form.
See [docs/configuration.md](docs/configuration.md) and
[OpenText NOM Inventory](https://docs.serviceradar.cloud/docs/opentext-nom).

ServiceRadar owns scheduling and credential delivery. The plugin receives only
public endpoint/query settings and short-lived host-mediated credential grants.
The default query is:

```json
{
  "name": "switches",
  "parameters": {"type": "Switch"}
}
```

Operators may configure up to eight query sets using the allowlisted network automation list
filters in `config.schema.json`. The plugin always owns `command=list device`,
`startid`, and `limitcount`; those values cannot be supplied by an operator.
The config retrieve action sends `list config` with the device ID, picks the
newest `configuration` revision by `createDate` (NA lists oldest first), then
sends `show config` with that revision's ID and the `mask` flag. A valueless
CLI flag such as `mask` is sent as an empty string.

## Supply Chain

ServiceRadar CI runs the plugin tests and the shared first-party Wasm build
gates. The generic `wasm-plugins.yml` release workflow rebuilds every registered
first-party bundle with repository-pinned tooling, publishes immutable OCI
artifacts, signs them in the protected `serviceradar-signing` environment, and
generates the ServiceRadar import index. The plugin has no dedicated workflow
or access to signing material.
