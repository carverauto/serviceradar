---
title: OpenText NOM Inventory
---

# OpenText NOM Inventory

The `opentext-nom-inventory` Wasm plugin imports a complete device inventory
snapshot from OpenText Network Operations Management (NOM) into ServiceRadar.

Network Automation (formerly HPNA) is the inventory collector. NNMi is an
optional Layer-2 enrichment source in the same stack. DIRE reconciles each
observation with devices already discovered by other sources and records this
plugin as the `opentext-nom` discovery source.

OpenText Network Automation and NNMi authenticate with a **service-account
username and password**. They do not issue API keys. That password belongs on
**Settings -> Networks -> Credential Rules**, not on plugin-package approval
and not on **Assign to Agent**.

The general credential model is in [Credential Management](./credentials.md).

## Do not assign this plugin

This is the step operators miss.

| Page | What it is for |
| --- | --- |
| **Admin -> Plugin Packages** | Import and **approve** the signed package. That only publishes the credential profile and the form schema. It never takes a password. |
| **Admin -> Plugin Packages -> Assign to Agent** | **Do not use this** for OpenText NOM. The form still exists for other plugins. For this package it is the wrong path: there is nowhere to put the service account, and a hand-made assignment is not what the daily schedule binds to. |
| **Settings -> Networks -> Credential Rules** (`/settings/networks/credentials`) | Create the service-account **credential**, then a **rule**. The rule's **Scope Value** is the agent that runs the Wasm module. Saving the rule creates the assignment and the producer schedule. |

After the rule saves, open **Consumers** on that row. You should see a
policy-owned assignment for `opentext-nom-inventory` on the agent you picked.
**Run Now** on the same row is how you collect inventory on demand.

If **New Credential** or **New Rule** says "Import and approve an integration
package first", the package is not approved yet. Go back to Plugin Packages;
do not work around that by filling Assign to Agent.

## What to call

NOM is two hosts in the common (NNMi-integrated) layout, and one host when
Network Automation is standalone.

Substitute your Network Automation and NNMi hosts. These are examples, not
customer URLs.

| Purpose | Example | What you enter in ServiceRadar |
| --- | --- | --- |
| Network Automation UI (not used by the plugin) | `https://na.example.com/` | Nothing. The UI origin is not a plugin setting. |
| Automation wrapper (inventory POST) | `https://na.example.com/nom/api/automation/v1/wrapper` | **Automation wrapper URL** (`api_url`) |
| NNMi console origin | `https://nnm.example.com:443` | **NNMi origin URL** (`nnm_url`). Origin only: scheme, host, optional port. No path. |
| NNMi OAuth token (derived) | `https://nnm.example.com:443/idp/oauth2/token` | Leave **OAuth token URL** (`token_url`) blank. The plugin derives this from `nnm_url`. |
| Standalone NA OAuth token (derived) | `https://na.example.com/nom-na/idp/oauth2/token` | Used only when `nnm_url` is omitted. Leave `token_url` blank. |
| NNMi attached-switch-port lookup (optional) | `https://nnm.example.com:443/nnmi/api/disco/v1/attachedSwitchPort` | Not a form field. The plugin calls this when `nnm_url` is set **and** `l2_endpoints` is non-empty. |

The wrapper URL is easy to get wrong. It is not the NA web UI, not `/nom-na/`,
and not an NNMi URL. It is the Network Automation **automation wrapper** REST
endpoint. The plugin `POST`s JSON of the form:

```json
{
  "command": "list device",
  "parameters": {
    "type": "Switch",
    "limitcount": 1000
  }
}
```

The plugin always owns `command`, `startid`, and `limitcount`. Operators only
choose the allowlisted filters (the default is `type=Switch`).

### How to find the wrapper URL

1. Ask the NOM administrator for the Network Automation **REST automation
   wrapper**. In a default OpenText NOM install the path is
   `/nom/api/automation/v1/wrapper` on the NA host.
2. If NA sits behind a reverse proxy, keep that proxy prefix **and** the
   `/nom/api/automation/v1/wrapper` suffix. Example:
   `https://tools.example.com/na/nom/api/automation/v1/wrapper`.
3. Confirm with a token you already have (the plugin will obtain its own later):

```bash
curl -k -X POST 'https://na.example.com/nom/api/automation/v1/wrapper' \
  -H 'Authorization: Bearer <token>' \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  -d '{"command":"list device","parameters":{"type":"Switch","limitcount":1}}'
```

A JSON device list (or an empty `result` array) means the URL is right. HTML
from the NA UI, SOAP, a 404, or a login page means you have the UI origin or
the wrong path.

`api_url` must be `https`, must include that exact path, and must **not** end
with a slash.

### How to find the NNMi token URL

NNMi-integrated NOM (the usual production layout) issues the bearer token from
NNMi, then the plugin calls the NA wrapper with that token.

1. Take the NNMi HTTPS console origin. Example: `https://nnm.example.com` or
   `https://nnm.example.com:443`.
2. Put that origin in **NNMi origin URL**. Do not append `/nnmi`, `/idp`, or
   `/console`.
3. The plugin requests the token from `{nnm_url}/idp/oauth2/token`. You do not
   enter that URL unless you are overriding it.

Confirm the token endpoint with the same service account you will store:

```bash
curl -k -X POST 'https://nnm.example.com:443/idp/oauth2/token' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -H 'Accept: application/json' \
  -d 'grant_type=password&username=nom-svc&password=<password>'
```

A JSON body with `access_token` means NNMi password-grant is the right layout.
Do not paste that token into ServiceRadar.

Standalone Network Automation (no NNMi) omits `nnm_url`. The plugin then posts
to `{api_url origin}/nom-na/idp/oauth2/token` and includes OpenText's documented
NA OAuth `client_id` / `client_secret` form fields (`id1` / `secret1`). Those
are not ServiceRadar credentials; the service-account username and password
still go in the credential secret.

When both `nnm_url` and `token_url` are set, they must describe the same NNMi
token endpoint. Leave `token_url` blank unless you have a reason to override
it.

## Create the credential

You need `settings.credentials.manage`.

1. Import and approve `opentext-nom-inventory` under **Admin -> Plugin Packages**.
2. Open **Settings -> Networks -> Credential Rules**
   (`/settings/networks/credentials`).
3. **New Credential -> OpenText NOM · Username and password**.
4. Name it for the environment (`nom-prod-svc`, not `opentext`).
5. Username and password are the NOM service account. The password is encrypted
   and never rendered back.

There is no API-token auth method for this provider. That is correct for NA and
NNMi.

## Create the rule (this is also how you pick the agent)

**New Rule -> OpenText NOM**.

| Field | What to put |
| --- | --- |
| Name | Site plus purpose, for example `nom-prod-inventory` |
| Provider | `opentext-nom` |
| Secret | The username/password credential you just saved |
| Auth method | `username_password` |
| Purpose | `device_inventory` |
| **Scope Value** | The **agent** that can reach both the wrapper host and NNMi. This is the agent that executes the Wasm plugin. |
| OpenText NOM instance ID | Stable identifier for this NOM install, for example `nom-prod`. It becomes part of source object IDs. Do not rename it later. |
| Automation wrapper URL | `https://na.example.com/nom/api/automation/v1/wrapper` |
| NNMi origin URL | `https://nnm.example.com:443` for NNMi-integrated NOM; leave blank for standalone NA |
| OAuth token URL | Leave blank |
| NNMi L2 endpoints | Leave empty on the first import |
| Skip TLS verification | Off unless NA/NNMi present untrusted certificates on a path that agent already trusts |
| Cadence (seconds) | `86400` (daily). Minimum `3600`. |
| Enable recurring inventory refresh | Off until a **Run Now** succeeds |

Scope type is forced to `agent` for this provider. One rule is one agent. Two
agents that can both reach NOM need two rules.

After save, Runtime moves from `Pending` to `On demand` (schedule created,
recurring off) or `Scheduled` (recurring on). **Consumers** lists the
assignment the rule materialized. If that panel is empty, reconciliation has
not run yet; wait and refresh before using **Run Now**.

### Worked example (NNMi-integrated)

- Credential: `nom-prod-svc` / username+password service account
- Rule name: `nom-prod-inventory`
- Scope Value: `edge-agent-01` (the agent that routes to NA and NNMi)
- `instance_id`: `nom-prod`
- `api_url`: `https://na.example.com/nom/api/automation/v1/wrapper`
- `nnm_url`: `https://nnm.example.com:443`
- `token_url`: blank
- cadence: `86400`
- recurring: off
- **Run Now**, then enable recurring after the first complete snapshot

### Worked example (standalone Network Automation)

Same as above, except omit `nnm_url`. The plugin authenticates to
`https://na.example.com/nom-na/idp/oauth2/token` and still POSTs inventory to
the wrapper URL.

## TLS

`insecure_skip_verify` is off by default. Turn it on only when Network
Automation and NNMi present certificates the assigned agent does not trust,
on a network path you already trust. The agent host then skips TLS verification
for the OAuth token request and for the inventory / L2 HTTPS calls.

Prefer installing the issuing CA on the agent
(`plugin_http_trusted_ca_files` / Helm `agent.pluginHTTPTrustedCAFiles`) and
leaving skip-verify off. Skip-verify is not a substitute for a real CA.

The credential rule's TLS policy control is hidden for this provider. Use the
plugin-config checkbox, not a rule TLS policy.

## What a successful run looks like

- **Run Now** dispatches `plugin.run_action` to the rule's agent.
- The agent obtains a short-lived bearer token and POSTs `list device` to the
  wrapper. The Wasm guest never sees the password.
- Devices appear with `source=opentext-nom`. Canonical fields include hostname,
  IP, first chassis serial, vendor, model, and type. Provider metadata includes
  partition, management status, and polling-exclusion.
- Repeat collections are idempotent. A later complete snapshot may mark omitted
  observations absent; it does not delete canonical devices.
- Agent logs, command results, plugin results, and audit events must not contain
  usernames, passwords, authorization headers, or bearer tokens.

Leave `l2_endpoints` empty until switch inventory is healthy. Layer-2
attached-switch-port lookups against NNMi are a second pass and are ignored
when `nnm_url` is omitted.

When sources disagree on switch port or VLAN, the rule form's **When sources
disagree, this source wins** toggles set operator authority for this instance.
That is independent of Armis or other sources; see the canonical device-facts
behavior on the device itself.

## Rollback

Disable the rule or uncheck recurring refresh. Revoking the package disables
further dispatch. Existing source observations remain for audit; canonical
devices are not deleted.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| New Credential menu is empty / "Import and approve an integration package first" | `opentext-nom-inventory` is not imported and approved. |
| Assign to Agent looks like the place to paste URLs | It is not. Use the credential rule. The assignment form for this package is not the provisioning path. |
| Runtime stays `Pending` | Reconciliation has not written the assignment yet. Wait, then check **Consumers**. |
| **Run Now** disabled | The producer schedule is not bound yet (`Pending`). |
| TLS / certificate errors | NA or NNMi presents an untrusted certificate. Install the CA on the agent, or set **Skip TLS verification** on the rule's plugin config. |
| `opentext_nom_auth_failed` | Wrong service-account password, or the token URL layout does not match the install (NNMi-integrated vs standalone NA). |
| `opentext_nom_api_unavailable` / HTML response | `api_url` is the UI origin or the wrong path. It must be the automation wrapper, with no trailing slash. |
| Wrapper URL rejected by the browser | The URL must be `https` with a non-root path and no trailing slash. Example: `https://na.example.com/nom/api/automation/v1/wrapper`. |
| Plugin runs on the wrong agent | Change **Scope Value** on the rule, not an assignment on Plugin Packages. One rule is one agent. |
| Password in plugin assignment Raw Params | Remove it. Store it as a credential secret. Rotate the NOM account if it was pasted into params or logs. |
