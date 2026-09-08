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

- The plugin can execute only the fixed OpenText Network Automation `list device`
  command.
- Query parameters are validated against a strict allowlist.
- Username and password are injected into the OAuth form by the ServiceRadar
  agent host and are never exposed to Wasm.
- The short-lived bearer token exists only for the current plugin execution.
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

## Supply Chain

ServiceRadar CI runs the plugin tests and the shared first-party Wasm build
gates. The generic `wasm-plugins.yml` release workflow rebuilds every registered
first-party bundle with repository-pinned tooling, publishes immutable OCI
artifacts, signs them in the protected `serviceradar-signing` environment, and
generates the ServiceRadar import index. The plugin has no dedicated workflow
or access to signing material.
