# OpenText Network Automation Inventory

This plugin imports a complete device inventory snapshot from OpenText Network
Automation into ServiceRadar. DIRE reconciles each observation with devices
already discovered by other sources and records this plugin as an additional
discovery source.

## Credentials

Create a Network Credentials rule for the **OpenText Network Automation**
provider and assign it to the agent that runs the plugin. The rule uses a
username/password credential to obtain a short-lived bearer token. Secrets are
resolved by the agent and are not exposed to the Wasm guest.

## Configuration

The required settings are:

- `instance_id`: stable identifier for the Network Automation installation.
- `token_url`: HTTPS OAuth password-grant endpoint.
- `api_url`: HTTPS automation wrapper endpoint.

The default query collects devices with `type=Switch`. Operators can replace it
with up to eight named query sets using the allowlisted `list device` filters in
`config.schema.json`. The plugin always controls the command, pagination
cursor, and page size.

ServiceRadar provisions a daily producer schedule by default. Operators can
change the cadence within the package-declared bounds or trigger an on-demand
run from the credential rule.

## Published Metadata

The signed package declares the `opentext-network-automation` inventory source
and these provider-owned observation fields:

- `instance_id`
- `partition`
- `management_status`
- `exclude_from_poll`
- `collection_id`
- `last_observed_at`

Core ServiceRadar components discover the provider, configuration form,
schedule, documentation, and display fields from the signed plugin manifest.

## Pre-production Validation

Before enabling the daily schedule:

1. Run the focused Go tests and build
   `//build/wasm_plugins:opentext_network_automation_inventory_bundle` at the
   release commit. Publish it through ServiceRadar's protected first-party
   Wasm workflow.
2. Import and approve the signed package in a non-production partition. Create
   a disabled credential rule for one test agent and confirm the generated form
   matches this package's schema and default `type=Switch` query.
3. Use **Run Now** and compare the result with an OpenText Network Automation
   export produced with the same filters. Check total rows, device IDs,
   hostnames, addresses, vendor/model values, partitions, management status,
   and polling-exclusion state.
4. Read the `opentext-network-automation` source inventory through
   ServiceRadar and sample DIRE matches against devices discovered by another
   source. Source object and integration IDs must remain stable across a repeat
   collection, and the second delivery of the same collection must be
   idempotent.
5. Test invalid credentials, a provider timeout, and an oversized or malformed
   response. Each run must fail without activating a partial snapshot or
   replacing the previous complete inventory.
6. Inspect agent logs, command results, plugin results, source metadata, and
   audit events for usernames, passwords, authorization headers, and bearer
   tokens. None may be present.
7. Enable a shortened approved cadence for two successful collections, verify
   the same behavior through **Run Now**, then restore the daily cadence.

Rollback consists of disabling the schedule or revoking the package. Existing
source observations remain available for audit and canonical devices are not
deleted.
