---
title: HPNA Inventory
---

# HPNA Inventory

ServiceRadar collects HP Network Automation (HPNA) device inventory through a
signed, action-only Wasm plugin running on a selected edge agent. Oban owns the
daily cadence and sends both scheduled and operator-initiated refreshes over the
agent command bus. The plugin does not schedule itself and never connects to
CNPG.

## Data Flow

1. An Oban producer schedule dispatches `hpna.inventory.refresh` to the selected
   agent.
2. The agent resolves a short-lived credential-broker grant and injects the
   service-account username and password only into the exact HTTPS token
   request.
3. The plugin exchanges those credentials for an HPNA bearer token and calls
   only the fixed `list device` wrapper command.
4. A complete bounded `serviceradar.device_discovery.v1` snapshot enters the
   standard plugin-result ingestion path.
5. DIRE reconciles each object with the canonical device inventory. A validated
   manufacturer-scoped hardware serial can merge an HPNA observation with an
   existing Armis or other device; hostname and IP alone cannot force a merge.
6. Source-observation rows retain HPNA object identity, current/absent state,
   collection identity, and freshness without deleting a canonical device that
   disappears from HPNA.

## Protected Publication

The external `serviceradar-plugin-hpna` repository runs build, test,
reproducibility, vulnerability, and SBOM checks without receiving ServiceRadar
signing material. After a release tag is merged into that repository's `main`,
dispatch **Publish External HPNA Wasm Plugin** from ServiceRadar `staging` or
`main` with the exact tag, such as `v0.1.0`.

ServiceRadar must configure two Forgejo tokens restricted to
`carverauto/serviceradar-plugin-hpna`:

- Repository secret `EXTERNAL_PLUGIN_FORGEJO_READ_TOKEN` with
  `read:repository`, used only by the pinned checkout action in the unprivileged
  build job.
- `release` environment secret `EXTERNAL_PLUGIN_FORGEJO_PUBLISH_TOKEN` with
  `write:repository`, used only by the protected signer to publish the verified
  import index.

Do not configure either token, the upload-signing key, Harbor credentials, or
OpenBao identity in the external repository.

The workflow proves the requested tag resolves to a commit reachable from the
external repository's `main`, rebuilds the Wasm module twice, and passes only
bundle data into `serviceradar-signing`. The protected job independently checks
the bundle path, digest, entry set, size limits, manifest identity, JSON schema,
and Wasm header before publishing, signing, verifying, and releasing it.

## Configuration

In **Settings > Plugins**, load
`https://code.carverauto.dev/carverauto/serviceradar-plugin-hpna` as the catalog
repository, import the signed `hpna-inventory` package from its versioned
release, review its requested capabilities, and approve it. The repository
selector is available only to operators with plugin staging permission and the
importer still enforces the trusted Forgejo host, upload signature, cosign
signature, OCI digest, and bundle identity.

After approval, open **Settings > Network Credential Rules**, select **HPNA
Inventory** and configure:

- An encrypted HPNA username/password credential.
- A stable instance ID, such as `example-automation-prod`.
- The absolute HTTPS OAuth token endpoint and automation-wrapper endpoint.
- One selected agent with network access to both endpoints.
- One to eight allowlisted query sets and bounded collection limits.
- Whether the recurring schedule is enabled and its cadence. The default is one
  day; allowed values are one hour through 30 days.

The default query is:

```json
[
  {
    "name": "switches",
    "parameters": {"type": "Switch"}
  }
]
```

Supported string filters are `software`, `vendor`, `type`, `model`, `family`,
`group`, `hierarchy`, `host`, `ip`, `realm`, `vtpdomain`, and `context`.
`disabled` and `pollexcluded` are booleans, and `ids` is a bounded array of
positive HPNA device IDs. `context` requires `ip`. The plugin owns `command`,
`startid`, and `limitcount`; attempts to configure those or unknown fields are
rejected.

Only one enabled HPNA inventory rule is supported in this iteration because the
package currently owns one producer-schedule row. Saving or enabling a second
rule fails explicitly instead of silently replacing the first assignment.

## Operations

Use **Run Now** on the credential-rule page for an immediate refresh. The same
RBAC, credential grant, command path, timeout, result ingestion, and audit path
apply to scheduled and manual runs. A second refresh for the same assignment is
rejected while the first is active; actions for unrelated assignments remain
eligible to run.

A collection is activated only after every configured query and page succeeds.
Authentication errors, malformed or non-advancing pages, row/byte limits, and
upstream failures leave the previous complete snapshot current. Re-ingesting an
identical collection is idempotent.

Search canonical devices with SRQL:

```srql
in:devices discovery_sources:(hpna)
```

```srql
in:devices discovery_sources:(hpna) metadata.hpna_instance_id:example-automation-prod metadata.hpna_partition:IAD
```

The device detail page shows all canonical discovery sources and a typed source
inventory table with HPNA instance, source object, current/absent state, last
observation, and collection.

## Source Inventory API

NCO and other read clients use:

```http
GET /api/v1/source-inventory?source=hpna&instance=example-automation-prod&partition=default&presence=present&limit=500
Authorization: Bearer <token>
```

The caller must be authenticated and have `devices.view`. Supported query
parameters are:

| Parameter | Behavior |
| --- | --- |
| `instance` | Required stable source instance ID. |
| `source` | Defaults to `hpna`. |
| `partition` | Defaults to `default`. |
| `presence` | `present` (default), `absent`, or `all`. |
| `collection` | Optional collection pin. |
| `limit` | 1 through 500; defaults to 100. |
| `cursor` | Opaque cursor returned by the previous page. |

A response contains the activated collection, normalized source rows joined to
bounded canonical device fields, and pagination metadata:

```json
{
  "api_version": "v1",
  "schema_version": "serviceradar.source_inventory.v1",
  "source": "hpna",
  "source_instance": "example-automation-prod",
  "partition": "default",
  "collection": {
    "id": "20260713T180000.000000000Z-deadbeef1234",
    "observed_at": "2026-07-13T18:00:00Z",
    "completed_at": "2026-07-13T18:00:05Z",
    "expected_present_count": 4200,
    "absent_count": 17,
    "complete": true
  },
  "rows": [],
  "pagination": {
    "limit": 500,
    "has_more": true,
    "next_cursor": "opaque"
  }
}
```

Always reuse `next_cursor` without modifying the other filters. If a new
snapshot activates during pagination, ServiceRadar returns HTTP `409` with
`source_collection_changed`; discard the partial client result and restart at
page one. Unknown filters, malformed cursors, and excessive limits return HTTP
`400`. The API never accepts SQL or arbitrary field projections.

## NCO Cutover

Create a ServiceRadar API credential with device-read permission and configure
NCO with:

```text
NCO_SERVICERADAR_HPNA_ENABLED=true
NCO_SERVICERADAR_HPNA_DEFAULT=true
NCO_SERVICERADAR_URL=https://serviceradar.example.internal
NCO_SERVICERADAR_HPNA_INSTANCE_ID=example-automation-prod
NCO_SERVICERADAR_PARTITION=default
```

Store `NCO_SERVICERADAR_TOKEN` in the NCO API/worker Kubernetes secret, not a
ConfigMap. Keep the existing HPNA spreadsheet upload available only as an
explicit transient compatibility source during validation. Compare counts and
sample device joins against the previous export before making ServiceRadar the
default source.

## Security Checks

- Long-lived credentials and tokens must not appear in assignment parameters,
  commands, plugin results, logs, audit rows, or device metadata.
- Token-form injection is restricted to the exact HTTPS host, port, path,
  method, and field names in the broker grant.
- Plugin query settings cannot override endpoints or issue arbitrary HPNA
  commands.
- Release bundles are built with pinned TinyGo, checked for byte-for-byte
  reproducibility, scanned, accompanied by an SPDX SBOM, and signed by the
  protected ServiceRadar release pipeline before import.
