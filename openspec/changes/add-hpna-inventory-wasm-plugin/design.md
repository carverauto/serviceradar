## Context
NCO needs HPNA host name, management IP, vendor, model, partition/site, device type, management status, and source identity to enrich NAC device lists. The HPNA HTTP wrapper exposes those fields through the fixed `list device` command and supports filters such as `type`, `vendor`, `host`, and `group`.

ServiceRadar is the intended inventory source of truth. Agents already execute signed Wasm plugins, host HTTP calls are policy checked, package manifests can declare producer schedules, and plugin device discovery flows through agent, gateway, core, and DIRE. The design extends those contracts rather than adding a direct database writer or a scheduler inside the plugin.

## Goals
- Poll one HPNA instance from the reachable `example-namespace` edge agent once per day and on demand.
- Make HPNA `list device` filters operator-configurable without allowing arbitrary HPNA commands.
- Reconcile HPNA observations with existing canonical devices and retain all source provenance.
- Provide a current, indexed, authenticated inventory surface that NCO can query.
- Fail closed on incomplete retrieval, unsafe identity evidence, oversized results, or unavailable credentials.

## Non-Goals
- Executing HPNA configuration changes, snapshots, change plans, or arbitrary wrapper commands.
- Scheduling inside the Wasm module.
- Giving the plugin direct CNPG, NATS, filesystem, or raw socket access.
- Deleting a canonical device because it disappears from one HPNA snapshot.
- Merging devices from hostname or IP evidence alone when strong identities conflict.
- Moving NCO to ServiceRadar in this change; that is owned by the linked NCO proposal.

## Decisions

### Separate plugin repository and existing platform contracts
The customer-owned plugin lives at `/Users/v161400/src/serviceradar-plugin-hpna` and imports `serviceradar-sdk-go`. It builds a WASI Preview 1 module and an importable signed bundle containing:

- `plugin.yaml`
- `plugin.wasm`
- `config.schema.json`
- fixtures and package metadata needed by the standard import validator

The ServiceRadar repository owns only reusable platform work, the OpenSpec contract, provider registration, tests, deployment wiring, and any SDK additions. The plugin emits `serviceradar.plugin_result.v1` with `serviceradar.device_discovery.v1`; it does not call ServiceRadar or CNPG directly.

### Effective plugin configuration
Credential rules and assignment settings compile an effective config similar to:

```json
{
  "instance_id": "example-automation-prod",
  "token_url": "https://hpna-nnm.example.internal/idp/oauth2/token",
  "api_url": "https://hpna-api.example.internal/nom/api/automation/v1/wrapper",
  "queries": [
    {
      "name": "switches",
      "parameters": {
        "type": "Switch"
      }
    }
  ],
  "page_size": 1000,
  "max_rows": 25000,
  "request_timeout_seconds": 30
}
```

`instance_id` is a required stable operator identifier for one HPNA installation. Endpoint renames or credential rotation do not change source identity. `token_url` and `api_url` are public operator-owned rule/schedule metadata because HPNA deployments may use separate NNM and automation-wrapper hosts. Both must be absolute HTTPS URLs without userinfo, query parameters, or fragments; neither is request supplied.

If `queries` is omitted, the plugin uses one query named `switches` with `{"type": "Switch"}`. Multiple query blocks are supported so an operator can add another HPNA class, such as `L3Switch`, without changing code. Results are deduplicated by HPNA `deviceID`.

The only accepted parameter names are:

- string filters: `software`, `vendor`, `type`, `model`, `family`, `group`, `hierarchy`, `host`, `ip`, `realm`, and `vtpdomain`
- boolean filters: `disabled` and `pollexcluded`
- structured filters: `ids` as a bounded array of positive integer device IDs, and `context` only when `ip` is present

The plugin owns `command=list device`, `startid`, and `limitcount`. Those keys, unknown parameters, nested command data, URL overrides, credential values, excessive query counts, oversized values, or invalid combinations are rejected before any HTTP call. The plugin serializes structured values into the HPNA wrapper format.

### Pagination and complete snapshots
For each query, the plugin calls `list device` with bounded `limitcount` and advances `startid` from the greatest valid `deviceID` in the previous full page. It rejects non-list responses, missing/non-advancing IDs on a full page, duplicate rows with conflicting content, row-limit exhaustion, and serialized results above the approved plugin-result budget.

The plugin emits no inventory snapshot when any query or page is incomplete. A successful result contains:

- source `hpna` and stable `instance_id`
- unique `collection_id`, observed time, normalized content hash, query hash, row/page counts, and `snapshot_complete=true`
- one bounded device record per HPNA `deviceID`

The first iteration stays below the existing 15 MiB gateway plugin-result limit with a lower explicit serialization budget. Exceeding the budget is a failed run requiring narrower query sets or a separately specified chunking/object-store extension; partial inventory is never activated.

### Brokered HPNA authentication
An HPNA credential rule uses provider `hpna`, purpose `device_inventory`, and auth method `username_password`. It is scoped to the assigned agent and exact token and wrapper endpoints. The producer-schedule grant derives its host, port, and path ACL from the validated operator-owned `token_url` and `api_url` settings; request payloads cannot override those URLs.

HPNA exchanges the service account for a short-lived token using a form-encoded POST. The Wasm host gains a generic `form_urlencoded` credential injection mode that:

- is allowed only by an issued broker grant for an exact HTTPS host, port, method, and token path
- overwrites only grant-declared field names such as `username` and `password`
- supplies fixed non-secret fields such as `grant_type=password` from approved config
- never returns the long-lived username/password to Wasm
- rejects insecure TLS, redirects outside the approved host, caller-supplied secret fields, expired grants, and unsupported content types

The short-lived HPNA bearer token exists only in the bounded plugin execution and is used for the wrapper request. Tokens, credentials, request bodies, raw responses, and authorization headers are excluded from logs, command results, inventory metadata, and audit payloads.

### Oban owns cadence; command bus owns execution
The package declares an assignment-scoped producer schedule:

- schedule/action id `hpna.inventory.refresh`
- command type `plugin.run_action`
- default cadence 86,400 seconds with bounded operator overrides and jitter
- bounded timeout and redaction metadata

Core materializes the contract as operator state. The existing AshOban producer scheduler dispatches due runs to the selected agent through the agent command bus. The settings Run Now action creates the same command and passes through the same RBAC, audit, uniqueness, timeout, credential, and result handling.

The plugin has no timer. Schedule dispatch is idempotent by schedule/run key, and only one active refresh is allowed per HPNA instance. Retries may repeat a collection, so ingestion deduplicates by source instance, collection ID, and content hash.

### Inventory-producing action results enter normal ingestion
Current action mode captures a plugin result for the command response but does not enqueue it through the normal plugin-result pipeline. The manifest/schedule contract gains an approved result disposition for inventory producers. When enabled:

1. the agent validates the captured payload as `serviceradar.plugin_result.v1`;
2. the full payload is enqueued through the ordinary plugin-result channel exactly as a scheduled check result;
3. the command response contains only status, counts, collection ID, hash, and a safe error code;
4. retries remain idempotent at ingestion.

Unapproved packages cannot request this disposition at runtime, and callers cannot toggle it in an ad hoc command payload.

### HPNA field mapping
The plugin maps only approved fields:

- `deviceID` -> stable HPNA source object ID
- `hostName` -> hostname
- `primaryIPAddress` -> primary IP
- `serialNumber` -> hardware serial evidence
- `vendor` -> vendor name
- `model` -> model
- `deviceType` -> device type
- `siteName` -> HPNA partition/site metadata
- `managementStatus` and `excludeFromPoll` -> source management metadata
- selected firmware/driver timestamps only when explicitly added to the schema

The plugin does not forward the raw HPNA row. Empty or malformed identity values are omitted and counted.

### DIRE convergence and source-authoritative identity
Every HPNA object receives a stable source integration identifier:

```text
hpna:v1:<instance_id>:device:<deviceID>
```

This identifier is source-authoritative across polls and credential/endpoint rotation. It is not sufficient by itself to prove equality with an Armis object.

Cross-source convergence uses shared strong hardware evidence:

- a valid globally unique MAC when HPNA provides one; or
- a validated manufacturer-scoped hardware serial derived from canonical vendor plus normalized serial.

Hardware serial normalization rejects blank, placeholder, all-zero, overlong, multi-value, and known non-unique values. Vendor aliases are canonicalized before constructing the identifier. A serial without a trustworthy vendor namespace remains display metadata and cannot independently merge devices.

Armis and other integration updates already carrying valid serial/vendor metadata register the same hardware-serial identifier. A bounded preflight/backfill registers only unique, valid existing identifiers; duplicate/conflicting serials are reported and skipped. When HPNA later presents the same identifier, DIRE resolves the existing canonical UID, attaches the HPNA integration identifier to it, and records merge/rebind audit evidence.

IP and normalized hostname may corroborate a strong match but cannot independently move an HPNA identifier onto an Armis device with different strong identity. Conflicts remain separate and produce an actionable identity diagnostic. This preserves the source-authoritative and anti-overmerge rules already ratified for DIRE.

### Multi-source provenance and currentness
Canonical devices continue to union `discovery_sources`; a converged record contains both `armis` and `hpna`. HPNA ingestion also stores source-specific, non-secret fields such as:

- `hpna_instance_id`
- `hpna_device_id`
- `hpna_partition`
- `hpna_device_type`
- `hpna_management_status`
- `hpna_serial_number`
- `hpna_collection_id`
- `hpna_last_observed_at`
- `hpna_present`

Generic plugin `integration_type` or `integration_id` metadata must not overwrite an existing Armis source's metadata. Source identity belongs in typed identifier/source-observation records, while source-specific display fields use namespaced keys.

A generic indexed source-observation record, keyed by partition, source, source instance, and source object ID, tracks the canonical device UID, first/last observation, current collection, presence, and bounded source metadata. After a complete snapshot is ingested, observations not present in that collection become `present=false`; canonical devices are not deleted or deactivated because another source may still observe them. Merge operations reassign observations to the winning canonical UID.

### Search and NCO read boundary
ServiceRadar exposes:

- SRQL discovery-source and HPNA metadata filters for operator browsing
- device details provenance showing HPNA alongside every other integration
- an authenticated, RBAC-scoped, cursor-paginated source-inventory API filtered by source, instance, presence, and collection

The API returns canonical UID plus the normalized HPNA fields NCO needs and a snapshot/collection identity. It never accepts SQL, exposes credential metadata, or returns absent records by default. Indexes cover source/instance/presence, source object ID, canonical UID, and the common HPNA lookup fields.

### Operational behavior
Each run records safe counts and timings: pages, received rows, unique devices, invalid rows, deduplicated rows, reconciled existing devices, new devices, identity conflicts, absent observations, duration, collection ID, and content hash.

Authentication, authorization, malformed response, incomplete pagination, payload budget, and identity conflict errors use stable safe codes. Detailed upstream bodies are neither persisted nor returned.

## Risks / Trade-offs
- Manufacturer serials can be dirty or reused. Strict validation, vendor scoping, duplicate preflight, confidence rules, and fail-safe conflicts prevent broad over-merges.
- The HPNA token exchange needs a new host injection mode. Exact grants, TLS enforcement, field allowlists, and tests keep this generic capability narrow.
- Action results are not currently ingested as plugin results. A package-approved result disposition avoids HPNA-specific command handling and prevents large payload duplication.
- A complete snapshot may exceed current message limits. The first release uses explicit row/byte caps and fails without activating partial data.
- If HPNA omits all shared strong identity, DIRE may temporarily retain a separate HPNA device. That is safer than merging on reused IP or hostname; later strong evidence can converge it.

## Migration Plan
1. Land generic SDK/runtime, credential, source-observation, and DIRE behavior behind no active HPNA assignment.
2. Build, test, sign, import, and approve the external HPNA plugin package.
3. Create the HPNA credential rule, assignment, and disabled producer schedule for the selected `example-namespace` agent.
4. Run credential diagnostics and a manual dry run; review counts, serial conflicts, and DIRE merge samples.
5. Run one full ingestion, verify Armis+HPNA convergence and API/SRQL output, then enable daily cadence.
6. Enable the linked NCO ServiceRadar source after the ServiceRadar API and current snapshot are healthy.

Rollback disables the producer schedule and assignment. Existing canonical devices and source observations remain auditable; no NCO-local HPNA database is required.
