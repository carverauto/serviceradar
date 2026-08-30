# OpenText Network Operations Management Inventory

This plugin imports a complete device inventory snapshot from OpenText Network
Operations Management (NOM) into ServiceRadar. Network Automation (formerly
HPNA) is the inventory collector; NNMi is an optional Layer-2 enrichment source
in the same stack.

The operator guide on the ServiceRadar docs site is
https://docs.serviceradar.cloud/docs/opentext-nom

## Do not assign this plugin from Plugin Packages

OpenText NOM is provisioned from **Settings -> Networks -> Credential Rules**
(`/settings/networks/credentials`), not from **Admin -> Plugin Packages ->
Assign to Agent**.

| Page | Use it for |
| --- | --- |
| Plugin Packages | Import and approve the signed package. Approval does not take a password. |
| Plugin Packages -> Assign to Agent | Do not use this for OpenText NOM. The agent is selected on the credential rule. |
| Settings -> Networks -> Credential Rules | Create the service-account credential, then a rule. The rule Scope Value is the agent that runs this Wasm plugin. Saving the rule creates the assignment and the daily schedule. |

NA and NNMi authenticate with a service-account username and password. They do
not issue API keys. Put that password in **New Credential -> OpenText NOM ·
Username and password**. Package approval and the assignment form never receive
it. The agent host performs the OAuth password grant; the Wasm guest never sees
the secret.

You need the `settings.credentials.manage` permission to manage that page. If
**New Credential** reads "Import and approve an integration package first",
approve `opentext-nom-inventory` and come back. Do not work around an empty
menu by filling Assign to Agent.

## Endpoints

Substitute your Network Automation and NNMi hosts. These are examples, not
customer URLs.

| Purpose | Example | Form field |
| --- | --- | --- |
| Network Automation UI (not used) | `https://na.example.com/` | Do not enter this. |
| Automation wrapper (inventory POST) | `https://na.example.com/nom/api/automation/v1/wrapper` | Automation wrapper URL (`api_url`), required |
| NNMi console origin | `https://nnm.example.com:443` | NNMi origin URL (`nnm_url`). Origin only: no path. |
| NNMi OAuth token (derived) | `https://nnm.example.com:443/idp/oauth2/token` | Leave OAuth token URL (`token_url`) blank. |
| Standalone NA OAuth token (derived) | `https://na.example.com/nom-na/idp/oauth2/token` | Used when `nnm_url` is omitted. Leave `token_url` blank. |
| NNMi attached-switch-port (optional) | `https://nnm.example.com:443/nnmi/api/disco/v1/attachedSwitchPort` | Not a form field. Called only when `nnm_url` is set and `l2_endpoints` is non-empty. |

### Automation wrapper URL

This is the Network Automation REST **automation wrapper**, not the NA web UI
and not an NNMi URL. In a default NOM install the path is
`/nom/api/automation/v1/wrapper` on the NA host.

The plugin POSTs JSON. Operators never choose the command; it is always
`list device`. Pagination (`startid`, `limitcount`) is also plugin-owned.

```json
{
  "command": "list device",
  "parameters": {
    "type": "Switch",
    "limitcount": 1000
  }
}
```

How to confirm the URL:

```bash
curl -k -X POST 'https://na.example.com/nom/api/automation/v1/wrapper' \
  -H 'Authorization: Bearer <token>' \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  -d '{"command":"list device","parameters":{"type":"Switch","limitcount":1}}'
```

A JSON device list means the URL is right. HTML, a login page, SOAP, or 404
means you have the UI origin or the wrong path.

Rules for `api_url`:

- Must be `https`.
- Must include the wrapper path (not `/` and not a trailing slash).
- Must not contain credentials, query parameters, or a fragment.
- If NA is behind a reverse proxy, keep that prefix and still end with
  `/nom/api/automation/v1/wrapper`.

Wrong values: `https://na.example.com/`, `https://na.example.com/nom-na/`,
`https://nnm.example.com/`, `https://na.example.com/nom/api/automation/v1/wrapper/`.

### NNMi origin and token URL

Two supported authentication layouts:

**NNMi-integrated** (typical production). Set `nnm_url` to the NNMi HTTPS
origin, for example `https://nnm.example.com:443`. The plugin requests the
token from `{nnm_url}/idp/oauth2/token`, then calls `api_url`.

**Standalone Network Automation**. Omit `nnm_url`. The plugin requests the
token from `{api_url origin}/nom-na/idp/oauth2/token` and includes OpenText's
documented NA OAuth `client_id` / `client_secret` form fields (`id1` /
`secret1`). Those are not ServiceRadar credentials. The service-account
username and password still go in the credential secret.

Leave `token_url` blank unless you must override the derived endpoint. When
both `nnm_url` and `token_url` are set, they must describe the same NNMi token
endpoint.

Confirm an NNMi token endpoint:

```bash
curl -k -X POST 'https://nnm.example.com:443/idp/oauth2/token' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -H 'Accept: application/json' \
  -d 'grant_type=password&username=nom-svc&password=<password>'
```

A JSON body with `access_token` means password-grant against NNMi is the right
layout. Do not paste that token into ServiceRadar.

`nnm_url` is an origin: `https://nnm.example.com:443`, not
`https://nnm.example.com/nnmi` and not the token path.

## Create the credential and rule

1. Import and approve this package.
2. **New Credential -> OpenText NOM · Username and password**. Store the NOM
   service account. Name it for the environment (`nom-prod-svc`).
3. **New Rule -> OpenText NOM**:
   - Secret: that credential
   - Auth method: `username_password`
   - Purpose: `device_inventory`
   - Scope Value: the agent that can reach the wrapper host and NNMi. **This
     is the agent that executes the plugin.**
   - `instance_id`: stable identifier such as `nom-prod` (do not rename later)
   - `api_url`: wrapper URL from the table above
   - `nnm_url`: NNMi origin, or blank for standalone NA
   - `token_url`: blank
   - `l2_endpoints`: empty on the first import
   - cadence: `86400` (minimum `3600`)
   - leave recurring refresh off until **Run Now** succeeds

One rule is one agent. Two agents need two rules. After save, **Consumers**
must show a policy-owned `opentext-nom-inventory` assignment on that agent
before **Run Now** will dispatch.

## TLS

`insecure_skip_verify` is off by default. Turn it on only when Network
Automation and NNMi present untrusted certificates on a path the assigned
agent already trusts. The host then skips TLS verification for the OAuth token
request and the inventory / L2 HTTPS calls. Prefer installing a real CA on the
agent (`plugin_http_trusted_ca_files`) instead.

## Queries, schedule, and metadata

The default query collects devices with `type=Switch`. Operators can replace
it with up to eight named query sets using the allowlisted `list device`
filters in `config.schema.json`. The plugin always controls the command,
pagination cursor, and page size.

ServiceRadar provisions a daily producer schedule (`86400` seconds, 15-minute
timeout). Operators change cadence on the credential rule, within the package
bounds, or trigger **Run Now** from that rule.

The signed package declares the `opentext-nom` inventory source and these
provider-owned observation fields:

- `instance_id`
- `partition`
- `management_status`
- `exclude_from_poll`
- `collection_id`
- `last_observed_at`
- `software_version`
- `firmware_version`
- `driver_name`
- `geographical_location`
- `chassis_serials`

Canonical device fields are emitted on the discovery record: hostname, IP,
first chassis serial, vendor, model, type, managed status, availability, site
name, OS name/version, hardware info (memory, processor, port counts, stacked
chassis serials), and owner/contact. DIRE uses the first chassis serial as the
identity serial; stacked serials stay in `hw_info`.

On the credential rule, **When sources disagree, this source wins** sets
operator authority for `switch_port_attachment` and `vlan_uid` for this
instance.

## Pre-production validation

Before enabling the daily schedule:

1. Run the focused Go tests and build
   `//build/wasm_plugins:opentext_nom_inventory_bundle` at the release commit.
   Publish it through ServiceRadar's protected first-party Wasm workflow.
2. Import and approve the signed package. Create a disabled credential rule
   for one test agent and confirm the generated form matches this package's
   schema and default `type=Switch` query. Confirm Assign to Agent is not how
   the package is enabled.
3. Use **Run Now** and compare the result with an OpenText Network Automation
   export produced with the same filters. Check total rows, device IDs,
   hostnames, addresses, vendor/model values, partitions, management status,
   and polling-exclusion state.
4. Read the `opentext-nom` source inventory through ServiceRadar and sample
   DIRE matches against devices discovered by another source. Source object
   and integration IDs must remain stable across a repeat collection, and the
   second delivery of the same collection must be idempotent.
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
