---
title: Credential Management
---

# Credential Management

Every integration credential ServiceRadar holds lives in the database, encrypted,
and reaches a plugin only as a short-lived scoped grant. There is one place to
put it: **Settings -> Networks -> Credential Rules** (`/settings/networks/credentials`),
under the Settings **Discovery** group. Managing anything on that page requires the
`settings.credentials.manage` permission.

No integration credential is read from an environment variable, a Kubernetes
Secret, or a config file. The one remaining exception is the agent's SNMP file
path, documented under [SNMP](#snmp).

:::note Not everything on this page has shipped yet
The current release is **1.4.49**. Four mechanisms described below are merged
work that has not appeared in a release yet, and each one is marked in place
with a `:::caution` box:

- the TLS Policy control rendering for UniFi Protect and Axis
  ([TLS policy](#tls-policy))
- `ca_bundle_pem` and `server_cert_fingerprint` on a credential rule
  ([CA trust material](#ca-trust-material))
- the `netbox` credential profile and its `inventory_sync` purpose
  ([NetBox](#netbox))
- removal of the VulnCheck environment-variable fallback
  ([VulnCheck](#vulncheck))

Two mechanisms this page originally listed as unreleased have shipped since, in
**1.4.48**: `allowed_networks` on the UniFi Protect, Axis, OpenText and AWX
plugin manifests
([0 cameras, 0 streams](#unifi-protect-reports-0-cameras-0-streams)), and
`action-only:v1` on the AWX manifest
([AWX api_token is required](#awx-configuration-invalid-api_token-is-required-resolved-from-credential-broker-grant)).

Replace `<first-release>` in the remaining boxes with the version that ships
them once it is cut. If you are reading this on a deployment running 1.4.49 or
earlier, the behaviour described in a marked box is not present and the
workaround in that box is the current answer.
:::

## Two objects: the credential and the rule

The page holds two different things, and most confusion comes from treating them
as one.

| | What it is | What it decides |
| --- | --- | --- |
| **Credential** (`network_credential_secrets`) | The material: an API token, a password, an SSH private key. Encrypted at rest; the secret half is never rendered back. | Nothing. It is inert until a rule or a form binds it. |
| **Rule** (`network_credential_rules`) | A binding: this credential, for this provider and purpose, against these targets, delivered to this edge scope. | Which agent may use it, against which devices, over what transport. |

A credential can be `internal_encrypted` (ServiceRadar holds the ciphertext,
the default) or an `external_reference` (ServiceRadar holds a pointer into an
external secret provider and resolves it at use time). Both look the same to a
rule.

This external-reference foundation does not imply Delinea support or public
provider/reference CRUD. The broker includes OpenBao and a Vault alias; Delinea
remains an unimplemented adapter placeholder. The current Terraform and public
credential creation surface accepts internal encrypted material only. Consumer
migration and UI/API coverage remain partial. See
[Declarative environments](./declarative-environments.md#future-delinea-secret-server-integration)
for the proposed runtime integration and the separate runner credential handoff.

Not every provider takes a rule. A provider's descriptor declares
`supports_rules`, and three of the providers on this page are credential-only:

| Provider | Rule? | Where the credential is bound instead |
| --- | --- | --- |
| Proxmox, UniFi Protect, Axis, OpenText | Yes | The rule itself |
| NetBox | Yes, from `<first-release>` | The rule itself. Through 1.4.49 there is no `netbox` provider on this page and the token is a plugin assignment parameter -- see [NetBox](#netbox) |
| AWX / AAP | No | **Settings -> Ansible -> Controllers**, per controller and purpose |
| VulnCheck | No | **Settings -> Security -> Vulnerability Feeds**, per feed |
| SNMP | No | **Settings -> SNMP Profiles**, per profile or target |

## Broker grant logs and history

Routine broker grant transitions (`issue`, `activate`, and `consume`) produce
debug logs only; they do not create new `ocsf_events` rows or appear as new
events in the observability UI. Enable debug logging when diagnosing these
transitions. Denial, revocation, and expiry continue to produce OCSF events.

Grant history remains recorded separately through AshPaperTrail in
`credential_broker_grant_versions`. This change does not remove previously
stored events. The `credential_resolution_audit_success_events` setting controls
secret-resolution events, not broker grant lifecycle logging.

## Providers come from packages, not from the UI

The provider list, the auth methods, the credential fields, the purposes, and the
form's defaults are all read from approved, signed plugin package manifests
(`integrations.credential_profiles`), merged with two descriptors the platform
owns because they have no package: SNMP and VulnCheck.

Nothing is hardcoded in the web UI. If a provider is missing from the **New Rule**
dropdown, either its package is not imported and approved yet -- see
[Wasm Plugins](./wasm-plugins.md) -- or it declares `supports_rules: false` and is
credential-only. An empty **New Rule** menu reads "No approved integration
descriptors"; an empty **New Credential** menu reads "Import and approve an
integration package first".

## Create a credential

1. **New Credential** -> pick `<provider> - <auth method>`, for example
   `Proxmox VE - API token`. The choice fixes the provider and the auth method;
   there is no free-text provider field.
2. Fill in the fields the descriptor declared. They differ per method: an API
   token is one password box, a Proxmox token is user/realm/token ID/token secret,
   an SSH key is username/private key/passphrase.
3. Name it something you will recognise in a select box six months from now.
   `pve-iad-readonly` beats `proxmox`.
4. Save.

Public fields (a username, a Proxmox token user) are stored in the clear and shown
back to you. Secret fields are encrypted and never re-rendered; to change one, save
a new value over it.

## Create a rule

**New Rule** -> pick the provider. The form is prefilled from the manifest's
`rule_defaults`, and only the controls the manifest declares in `rule_controls`
are shown -- a provider that does not let you set allowed ports has no allowed
ports box.

A worked Proxmox example, which exercises most of the fields:

| Field | Value | Why |
| --- | --- | --- |
| Name | `pve-iad-inventory` | Site plus purpose. It appears in the Consumers panel and in audit records. |
| Provider | `proxmox` | |
| Priority | `100` | The default. Lower wins; see [Priority](#priority). |
| Secret | `pve-iad-readonly` | Only credentials matching this provider and auth method are offered. |
| Auth method | `proxmox_api_token` | |
| Purpose | `inventory_enrichment` | Not `console_access`; see [Purposes](#purposes). |
| Scope type / value | `agent` / `agent-iad-01` | The agent that can reach the PVE management network. |
| Target query | `in:devices metadata.proxmox_candidate:true` | The manifest default. |
| TLS policy | `verify` | Proxmox inventory enrichment refuses anything else. |
| Allowed ports | `8006` | |

Save. The rule is enabled by default and materialises within a reconciliation
cycle.

Nothing on this form makes `verify` succeed against a node whose certificate the
agent does not trust. That is agent-side configuration, and for Proxmox it also
depends on the node certificate's SAN list -- see
[CA trust material](#ca-trust-material) and
[Proxmox: TLS Verification and Node Certificates](./proxmox.md#tls-verification-and-node-certificates).

### Purposes

A purpose is what the credential is allowed to be used *for*. Purposes are
declared per provider by the package, not chosen from a global list:

| Provider | Purposes |
| --- | --- |
| `proxmox` | `inventory_enrichment`, `console_access` |
| `unifi-protect` | `camera_inventory`, `camera_stream` |
| `axis` | `camera_inventory`, `camera_stream` |
| `opentext-nom` | `device_inventory` |
| `netbox` | `inventory_sync` (from `<first-release>`; see [NetBox](#netbox)) |
| `awx` | `automation_execution` |
| `vulncheck` | `vulnerability_feed_download` |
| `snmp` | `snmp_monitoring` |

A rule can carry more than one purpose, and each purpose materialises its own
plugin assignment with its own grant. Ticking `camera_inventory` and
`camera_stream` on one UniFi rule produces two assignments, one per plugin.

Keep purposes separate when the access they imply is different. A read-only
Proxmox API token belongs on an `inventory_enrichment` rule; SSH shell access
belongs on a separate `console_access` rule with its own credential. Selecting
`console_access` reveals a **Console credential users** fieldset -- at least one
role, user/IdP subject, or IdP group must be named, and ServiceRadar rechecks
those selectors when the console stream attaches.

### Scope type and scope value

Scope answers "which edge path may hold this grant". It is the blast radius.

| Scope type | Scope value | Use when |
| --- | --- | --- |
| `agent` | an agent ID (offered as a dropdown when agents are known) | The normal case. One agent reaches the appliance. |
| `gateway` | a gateway ID | Several agents behind one gateway may need it. |
| `partition` | a partition name | A whole partition legitimately shares the credential. |

Which scope types are offered comes from the provider descriptor. SNMP, for
example, declares `agent` only.

Scope is enforced independently of the target query. A device that matches the
query but is assigned to an agent outside the scope gets no grant -- the Preview
panel's **Matched** and **In Scope** counts are exactly this difference.

### Target query and the Runtime column

The target query is SRQL. It selects the devices the rule applies to, and the
selection is re-evaluated -- a device that starts matching tomorrow is covered
tomorrow.

The **Runtime** column on the rules table reports how the rule finds its targets.
It shows one of five values:

| Badge | Meaning |
| --- | --- |
| `SRQL` | The rule's own target query selects the targets. This is the normal case. |
| `Auto` | The rule additionally has **Allow auto-discovery credential trials** ticked (`metadata.auto_discovery_enabled`). |
| `Scheduled` | A `producer_schedule` provider whose recurring refresh is enabled. |
| `On demand` | A `producer_schedule` provider whose schedule exists but is not enabled. Use **Run Now**. |
| `Pending` | A `producer_schedule` provider whose schedule has not been provisioned yet. Wait for credential reconciliation. |

OpenText NOM is the only `producer_schedule` provider shipped today, so the last
three badges only appear on an `opentext-nom` rule.

`Auto` is Proxmox-specific today and worth understanding before ticking it. An
enabled Proxmox `inventory_enrichment` rule with auto-discovery on makes the
mapper compile `proxmox_candidate_probe_enabled` into its job options. The mapper
then runs an **unauthenticated** HTTPS fingerprint against port `8006` on
reachable hosts and stamps anything that answers like a PVE web UI with
`metadata.proxmox_candidate=true` (plus `proxmox_candidate_source`,
`_evidence`, `_observed_at`, `_port`, `_service`, `_title`). Because the Proxmox
manifest's default target query is
`in:devices metadata.proxmox_candidate:true`, those devices then become rule
targets and receive credentialed collection.

So `Auto` widens the target set from "devices you named" to "devices that
answered a probe". The fingerprint itself sends no credential, but the
credentialed collection that follows does. Leave it off unless the rule's scope
can only reach the intended PVE network and the token is read-only.

### Priority

Rules are ordered per provider by priority, **lowest value wins**, with insertion
order breaking a tie. Priority only matters where two enabled rules of the same
provider match the same device in the same scope; the Preview panel lists those
overlaps under **Credential Conflicts** with the count of shared devices.

Use it deliberately: a narrow site-specific rule at `50` overriding a broad
fallback at `100` is the pattern. Two rules at the same priority matching the
same device is not a configuration, it is a coin flip.

### TLS policy

`verify` (the default) or `skip_verify`.

:::caution Not in 1.4.49
**The TLS Policy control renders whenever the provider declares transport rule
controls and the selected auth method is not an SSH one.** Through 1.4.49 the
control was rendered only when the selected auth method also declared a
non-empty `tls_policies` list, while the save path required a valid `tls_policy`
unconditionally. UniFi Protect and Axis declare `rule_controls.transport: true`
but no per-method `tls_policies`, so on those two providers the input was never
drawn, the browser submitted nothing, and every save failed with
`Invalid TLS policy`. There is no way to save such a rule on 1.4.49 or earlier
-- see [Invalid TLS policy](#invalid-tls-policy-when-saving-a-rule).

The merged fix keys the control on `rule_controls.transport` plus the auth
method declaring no `ssh_host_key_policies`, so an SSH transport -- which has no
TLS policy to choose -- keeps the SSH Host Key Policy control instead. An auth
method that declares no `tls_policies` is offered the full set, and a
`tls_policy` that is absent on submit falls back to the resource default
(`verify`) rather than failing the save.

First release containing the fix: `<first-release>`.
:::

When the selected auth method narrows the permitted policies, only those are
offered. An auth method that declares no `tls_policies` narrows nothing, and
every policy stays on offer -- which is how core has always read an absent list.

Some methods narrow it to nothing else. Proxmox's `proxmox_api_token` declares
`tls_policies: [verify]`, so the select offers only `verify`, and
`inventory_enrichment` is additionally checked at resolution time -- a
`skip_verify` rule fails closed with `proxmox_tls_verification_required` and no
grant is ever minted.

`skip_verify` is appropriate for an appliance whose certificate you cannot
replace and whose network path you already trust -- a camera on an isolated VLAN
reached by an agent on that VLAN. It is not appropriate anywhere the credential
being sent is worth more than the appliance: Proxmox inventory enrichment writes
into device identity, so a machine-in-the-middle there is an identity-forgery
primitive, which is why the check refuses rather than warns.

Where you want verification and the appliance has a private or self-signed
certificate, do not reach for `skip_verify`. Give the agent the trust anchor
instead.

### CA trust material

**On 1.4.49, trust for plugin HTTP is configured on the agent, not on the rule.**
The agent builds one host-owned HTTP client for every Wasm plugin call. Its trust
roots are the operating system pool plus every PEM bundle listed in
`plugin_http_trusted_ca_files` in `agent.json` (Helm:
`agent.pluginHTTPTrustedCAFiles`, which already includes the ServiceRadar runtime
CA). Those roots **augment** the system pool -- they widen what the agent will
accept, they do not restrict it to your CA.

Three properties of that client decide every question below:

- Wasm modules never see the bundle contents and cannot select or replace the
  roots.
- If a configured path is unreadable, oversized, or holds no certificate, the
  agent disables outbound plugin HTTP entirely rather than falling back.
- Hostname verification is normal Go TLS verification against the URL the agent
  actually dials. When that URL has an IP literal for a host, the certificate
  must carry that address as an `IP Address` SAN; a `DNS` SAN never matches an IP
  literal.

Restart the agent after changing the bundle.

:::caution Not in 1.4.49
**`ca_bundle_pem` and `server_cert_fingerprint` on a credential rule.** A rule
carries two optional, mutually exclusive columns:

- `ca_bundle_pem` -- a PEM chain, rejected at save time if it does not parse as
  unencrypted `CERTIFICATE` blocks or if any certificate in it has expired.
- `server_cert_fingerprint` -- a leaf pin, `sha256:` followed by 64 lowercase hex
  characters.

Both are validated when the rule is saved rather than at first use, and supplying
both is rejected by an Ash validation and by a database check constraint. They
are stored in the clear: a CA certificate and a fingerprint are trust anchors,
not authenticators, so an operator can read back what a rule trusts and the
values never go through the credential broker.

The Credential Rules form renders both fields wherever a provider declares
transport controls. The Proxmox manifest passes the selected trust material as
`$source: rule` into the agent's host-authority binding. Unlike
`plugin_http_trusted_ca_files` above, a rule's trust material **replaces** the
system trust store for that rule's destinations rather than widening it: a rule
pinning a private CA is asking for that anchor, and keeping the public roots
would still accept any publicly-trusted certificate for the same origin. The
bundle or fingerprint never reaches the Wasm guest. A bundle retains normal
certificate-chain and hostname verification; a fingerprint instead accepts only
the exact leaf certificate whose SHA-256 digest matches the pin, without chain,
hostname, or expiry verification.

Proxmox is the case that forced this. Inventory enrichment mandates `verify`, the
controller origin is always an IP literal, and a binding carrying
`insecure_skip_verify` is rejected outright. Pinning the cluster CA allows normal
TLS verification against that private CA. See the Proxmox provider section for the
procedure.

First release containing these: `<first-release>`.
:::

### Allowed ports

A comma- or space-separated list of ports (1-65535) the grant may be used
against. The manifest supplies a default: `8006` for Proxmox, `443, 7447` for
UniFi Protect, `443, 554` for Axis, and (from `<first-release>`) `443, 8443` for
NetBox. Narrow it, do not widen it -- a rule that
allows `443` and nothing else cannot be redirected at an SSH daemon.

### SSH host key policy

Shown only for auth methods that declare host key policies (today, Proxmox's
`ssh_private_key`). `known_hosts` when the agent has a managed known-hosts file,
`trust_on_first_use` for first-connection pinning, `skip_verify` only for
temporary testing.

## How a rule reaches a plugin

Nothing about this path hands raw secret material to the sandboxed plugin.

1. **Materialisation.** A reconciliation worker resolves the rule's target query
   and scope, and writes one `plugin_assignments` row per purpose per eligible
   agent. Each row is stamped
   `policy_id: network-credential-rule:<rule id>[:<purpose>]`, which is how the
   Consumers panel answers "what is this rule doing" from the assignments table
   alone.
2. **The params template.** The assignment's `params` are rendered from the
   manifest's `provisioning.consumers[].params` template. It carries a
   `credential_broker` grant envelope -- grant type, credential rule ID, secret
   reference, consumer, target, resolution location, TTL, the header to inject,
   and an allow-list of methods and paths -- plus a `<field>_secret_ref`
   placeholder such as `api_token_secret_ref`. No secret value is in the row.
3. **Delivery.** At agent config generation, core checks the embedded grant is
   still fresh, re-mints it through the broker if not, resolves
   `<field>_secret_ref` to `<field>` for host-brokered paths, and writes an audit
   row for the resolution.
4. **Use.** The Wasm guest calls out through the host, which applies the grant's
   injection and allow-list and the manifest's egress permissions. For
   host-brokered paths the guest never sees the material.

Grants are short-lived (300 seconds for the providers above) and pinned to one
host, port, method set, and path set. There is no catch-all grant.

## Row actions

Each rule row on the table offers:

| Action | What it does |
| --- | --- |
| **Preview** | Opens the target preview. Shown for every provider except `producer_schedule` ones, which get **Run Now** instead. |
| **Run Now** | Dispatches an immediate refresh. Shown for `producer_schedule` providers only, and disabled until the schedule is provisioned. |
| **Consumers** | Expands an inline panel listing the assignments this rule currently materialises: agent, plugin, purpose, enabled, last materialised. |
| **Edit** | Opens the rule form. |
| **Enable** / **Disable** | Flips `enabled`. A disabled rule matches nothing and mints no grants; existing grants expire on their own TTL. |

**Preview** is the one to use before enabling anything. It shows:

- **Matched** -- devices the target query returns.
- **In Scope** -- of those, the ones whose agent falls inside the rule scope.
  This is the number that matters. Matched high and In Scope zero means the query
  is fine and the scope is wrong.
- **Agents** -- per-agent device distribution, so you can see which edge agent
  would receive the grant.
- **Conflicts** -- other rules of the same provider that also match these
  devices, with priority and overlap count.
- **Effective Inputs (dry run)** -- the rendered params template per purpose,
  including the plugin ID, the policy ID, the interval, and the timeout. Secret
  references are shown as references; secret material is never resolved or
  displayed here.

## Managing credentials from the API

Credential secrets, rules, and AWX/AAP controller registrations can be managed
through the authenticated admin API. See the instance's `/api/admin/openapi`
for resource paths and methods, and the
[CLI playbook guide](https://github.com/carverauto/serviceradar/blob/staging/js/cli/README.md#plugin-configuration-playbooks)
for repeatable apply usage.

Secret creation requires `name`, `provider`, `auth_method`, and a `values` map
whose keys match the provider's credential descriptor. Secret updates edit
`name` and `description`; rotation accepts a new `values` map for the existing
credential type. Responses omit secret payloads and ciphertext.

Rule create/update accepts TLS policy, `ca_bundle_pem`,
`server_cert_fingerprint`, allowed ports, and `metadata`. Put controller hosts
in `metadata.host` and plugin settings in `metadata.plugin_config`; the API
does not accept top-level convenience fields for these. A supplied `metadata`
map replaces the previous map, so merge existing keys before PATCHing it.
Explicit JSON `null` clears `ca_bundle_pem` or `server_cert_fingerprint`;
omitting them preserves their values.

AWX/AAP controller creation requires `name`, `base_url`, `agent_id`, and
`sync_credential_secret_id`. Optional execution and callback bindings use
`execution_credential_secret_id` and `callback_credential_secret_id`; PATCH
with JSON `null` clears either optional binding. Tokens are never echoed back.

Assignment responses include `plugin_id` for identity matching. Assignment
PATCH accepts `plugin_package_id` to select an approved package version.

CLI device-code tokens request `plugins.manage` for these calls
(`serviceradar-cli auth login --scope plugins.manage`). Existing authorization
policies are preserved on upgrade: an administrator must add `plugins.manage`
to the allowed scopes in **Settings -> CLI authentication**
(`/settings/cli-auth`) before login can request it. New policy rows include it
by default. The scope permits configuration calls and plugin/package reads;
each endpoint still checks RBAC: `settings.credentials.manage` for secrets and
rules, `ansible.controllers.manage` for controllers, `plugins.view` for plugin
reads, and `plugins.assign` for assignment writes.

## Provider setup

### Proxmox VE

Proxmox inventory enrichment mandates `verify`, and ServiceRadar always dials a
PVE node at `https://<ip>:8006`, so the certificate work is not optional and it
is not satisfied by "signed by a CA we trust" alone. The full procedure, with the
commands and the reasoning, is
[Proxmox: TLS Verification and Node Certificates](./proxmox.md#tls-verification-and-node-certificates).
The short form:

1. **Create a least-privilege PVE token.** See
   [Proxmox: Least-Privilege Role](./proxmox.md#least-privilege-role). Record the
   user, realm, token ID, and token secret.
2. **Make the node certificate verifiable from the agent, for the IP the agent
   uses.** Two independent conditions, both required: the chain must reach a root
   the agent trusts (add the PVE cluster CA to `plugin_http_trusted_ca_files`),
   and the node certificate's SAN list must contain
   `IP Address:<that address>`. Inspect the SAN list before assuming;
   [proxmox.md](./proxmox.md#step-2-inspect-the-node-certificate-sans) gives the
   command and how to read its output.
3. **Create the credential.** **New Credential** ->
   `Proxmox VE - API token`. Stored public identity is `<user>@<realm>!<token_id>`;
   the token secret is encrypted.
4. **Create the rule.** Provider `proxmox`, auth method `proxmox_api_token`,
   purpose `inventory_enrichment`, TLS `verify`, allowed ports `8006`, scope the
   agent that reaches the PVE management network. Target query: start from
   `in:devices metadata.proxmox_candidate:true`, or name the hosts explicitly if
   you are not using auto-discovery.
5. **Preview, then enable.** Confirm In Scope is non-zero and the agent shown is
   the one you expect.

Console access is a separate rule with a separate credential -- see
[Proxmox: Console Access](./proxmox.md#console-access).

### UniFi Protect

The plugin talks to the **UniFi OS controller** (Dream Machine, Cloud Gateway, or
a UniFi OS console), not to each camera. Cameras are enumerated from Protect after
login. Full detail in [UniFi Protect](./unifi-protect.md).

1. **Create an API key in UniFi OS** under **Settings -> Control Plane ->
   Integrations**. Prefer this over a local admin account.
2. **Create the credential.** **New Credential** -> `UniFi Protect - API key`.
   (`UniFi Protect - Username and password` also exists if you cannot use a key.)
3. **Create the rule.** Provider `unifi-protect`, purposes `camera_inventory` and
   `camera_stream`, allowed ports `443, 7447`, target query
   `in:devices vendor:"Ubiquiti"`.
4. **Set the controller field.** The **UniFi OS / Protect controller** box
   (relabelled **UniFi Protect controller host** from `<first-release>`, when the
   control stops being UniFi-specific) takes the controller address -- hostname,
   IP, or a full URL, from which ServiceRadar keeps the host. The controller is
   almost always reached by a private IP such as `192.168.1.1`. Leave it blank
   only when the target query already resolves the controller device itself; the
   plugin calls that host, not a seed row's IP.
5. **TLS.** `verify` if the controller presents a certificate the agent can
   chain to and that is valid for the address the agent dials -- add the issuing
   CA to `plugin_http_trusted_ca_files` (see
   [CA trust material](#ca-trust-material)). `skip_verify` is defensible here when
   the controller still has its factory certificate and the agent is on the same
   trusted segment; unlike Proxmox, the UniFi grant is resolved at the control
   plane, so a `skip_verify` rule does relax the plugin's own transport.

Because the controller is on private address space, the plugin manifest must
declare `allowed_networks` covering it. A wildcard in `allowed_domains` does not
cover an IP literal by design. See the
[egress troubleshooting entry](#unifi-protect-reports-0-cameras-0-streams) for
which releases carry that declaration.

### Axis

Axis cameras are addressed directly over VAPIX; there is no controller.

1. **Create a dedicated camera account** on the cameras -- viewer or operator
   level, not root.
2. **Create the credential.** **New Credential** ->
   `Axis (VAPIX) - Username and password`.
3. **Create the rule.** Provider `axis`, auth method `username_password`,
   purposes `camera_inventory` and `camera_stream`, allowed ports `443, 554`,
   target query `in:devices vendor:"Axis"`, scope the agent on the camera VLAN.
4. **TLS.** `verify` if the fleet has a managed CA you can add to
   `plugin_http_trusted_ca_files`. Axis cameras normally present a self-signed
   certificate issued per camera, which no shared anchor covers -- for a fleet,
   either install CA-signed certificates on the cameras or use `skip_verify` on
   an isolated segment.

Axis, like UniFi Protect, is reached by private IP and needs the manifest's
`allowed_networks` declaration -- see
[0 cameras, 0 streams](#unifi-protect-reports-0-cameras-0-streams) for which
releases carry it.

### OpenText NOM

OpenText Network Automation and NNMi authenticate with a **service-account
username and password**. They do not issue API keys. Full endpoint examples
(wrapper URL, NNMi origin, derived token URLs) are in
[OpenText NOM Inventory](./opentext-nom.md).

This provider is `producer_schedule`. The credential rule **is** the assignment:
the rule's **Scope Value** is the agent that runs the Wasm plugin. Do **not**
use **Admin -> Plugin Packages -> Assign to Agent**, and do **not** put the
password on package approval.

1. **Import and approve** `opentext-nom-inventory`. Until that is done, this
   page's **New Credential** / **New Rule** menus will not offer OpenText NOM.
2. **Create the credential.** **New Credential** ->
   `OpenText NOM - Username and password`. Store the NOM service account.
3. **Create the rule.** Provider `opentext-nom`, auth method
   `username_password`, purpose `device_inventory`, scope **agent** = the agent
   that can reach both Network Automation and NNMi.
4. **Fill plugin config on the same rule form**, not on Assign to Agent:
   `instance_id`, automation wrapper URL
   (`https://na.example.com/nom/api/automation/v1/wrapper`), and for
   NNMi-integrated installs the NNMi origin
   (`https://nnm.example.com:443`). Leave `token_url` blank; the plugin derives
   `{nnm_url}/idp/oauth2/token`.
5. Leave recurring refresh off. Use **Run Now** once **Consumers** shows the
   materialized assignment, then enable the daily cadence (`86400`).

The password stays in `network_credential_secrets`. The assignment row the rule
creates carries only a grant envelope. Runtime badges `Pending` / `On demand` /
`Scheduled` on this page apply to OpenText NOM; see
[Target query and the Runtime column](#target-query-and-the-runtime-column).

### AWX / AAP

AWX is **credential-only**: its descriptor sets `supports_rules: false`, so an AWX
token is a credential, bound to an Ansible Controller record. There is no AWX
credential rule, and the AWX bridge is a command bridge -- each dispatch carries
its own grant. Full detail in [Ansible Integration](./ansible.md).

1. **Create three purpose-scoped AWX tokens** in AWX, per
   [Ansible: store purpose-scoped tokens](./ansible.md#1-store-purpose-scoped-awx-api-tokens-in-the-credential-broker):
   a sync token, an execution token, and (for callback-enabled playbooks) a
   callback token.
2. **Create one credential per token.** **New Credential** ->
   `AWX / AAP - API token`. Name them for the purpose: `awx-prod-sync`,
   `awx-prod-exec`, `awx-prod-callback`.
3. **Bind them on the controller.** **Settings -> Ansible -> Controllers** ->
   add or edit a controller and select each credential in the Sync, Execution,
   and Callback fields.

Do not create an AWX credential rule. It will not appear in the **New Rule**
dropdown, and the AWX bridge does not read one.

### NetBox

NetBox has two independent paths, and they take their credentials differently:

- **Device inventory sync** (`netbox-inventory` Wasm plugin) reads its token
  from the plugin assignment's `sources[].api_token`, under **Admin ->
  Plugins** (`/settings/agents/plugins`). The plugin fails a source outright
  when that value is blank.
- **IPAM prefix tag import** (a core Oban worker) uses the NetBox source under
  **Settings -> Integrations**. It is not a credential-rule path and is not
  changed by the box below.

Setup for both is in [NetBox Integration](./netbox.md).

:::caution Not in 1.4.49
**The `netbox` credential profile.** Merged work adds an
`integrations.credential_profiles` block to
`go/cmd/wasm-plugins/netbox/plugin.yaml`, which makes NetBox a credential-rule
provider on this page. What the manifest declares:

| Field | Declared value |
| --- | --- |
| Provider / label | `netbox` / `NetBox`, `supports_rules: true` |
| Auth method | one: `api_token` ("API token"), credential kind `api_token`, a single required secret `api_token` password field, TLS policies `verify` and `skip_verify` |
| Purpose | `inventory_sync` |
| Scope types | `agent`, and nothing else |
| Rule controls | allowed ports, controller host, target query, transport |
| Rule defaults | target query `in:devices sort:uid:asc limit:1`, scope type `agent`, allowed ports `443, 8443`, TLS policy `verify` |
| Provisioning | `target_policy`, consumer `netbox-inventory` declared `target_cardinality: single`, grant type `netbox_api_token` resolved at the control plane with a 300 second TTL |

Delivery follows the ordinary path in
[How a rule reaches a plugin](#how-a-rule-reaches-a-plugin): the stored
assignment row carries `api_token_secret_ref`, `credential_rule_id` and the
grant envelope rather than the token, and because the grant's resolution
location is the control plane, config delivery resolves that reference into
`api_token` in the config the agent hands the plugin. `base_url` is injected
from the rule's controller host -- the template reads rule metadata `base_url`,
then `host`, then `controller_host`, so an operator-set `base_url` wins and a
BASE_PATH deployment (`https://tools.example.com/netbox`) can be expressed.
`insecure_skip_verify` is derived from the rule's TLS policy being
`skip_verify`, and `page_size` / `timeout_ms` default to `100` / `30000`.

Four things to know before planning against it.

**The target set is only a delivery gate.** A NetBox instance is the rule's
controller host, not a resolved device: the sync walks the instance named by the
rule and ignores `inputs[].items[]`. The consumer is declared
`target_cardinality: single`, so the planner never chunks it: however many
devices the query matches, they arrive as one un-chunked assignment, and a
target set too large for one payload is an error telling you to narrow the
target query rather than a split into several assignments that would each
re-walk the whole instance. The default is a query that resolves one stable
device for that reason, `in:devices sort:uid:asc limit:1`; narrow it to the
NetBox host's own device record (for example `in:devices ip:10.0.0.5`) when you
want the targets to name the instance.

**The scope is `agent`, and the profile may not offer anything else.** Not
chunking the targets is only half of "one sync per instance". The other half is
that the materializer reconciles every agent a scope admits *separately*, so a
`gateway`- or `partition`-scoped rule would hand that same whole-instance job to
each agent underneath it: every one of them would walk the same
`/api/dcim/devices/` listing and emit another complete `snapshot_complete`
snapshot under the same `source_instance`. One assignment per `(rule, agent)`
pair is the intended emission; what has to be avoided is a rule that names
*many* agents, so the manifest declares `scope_types: [agent]` and
`IntegrationDescriptor` enforces it:
`validate_single_cardinality_scope_types/4` rejects any profile that pairs a
`target_cardinality: single` consumer with a wider scope list, and the rule form
draws its scope options from that same list. Core does not elect a runner
instead, because whether an agent can reach the NetBox host is an operator fact.
A rule that carries a wider scope anyway -- written before that validation, or
by something other than the rule form -- is skipped rather than delivered, and
the reconcile reports it as `single_target_rule_not_agent_scoped`.

**Give each NetBox rule a distinct target query.** Two `netbox` rules matching
the same devices in the same scope are a [priority](#priority) conflict and only
the winning rule materialises, so two instances behind one query means only one
of them syncs.

**A rule renders the plugin's flat single-source fields, not a `sources[]`
entry.** The plugin reads `sources[]` first and falls back to the flat fields
only when it is absent, so an assignment that still has a non-empty `sources[]`
ignores everything the rule delivers. Clear `sources[]` when you move a
single-source assignment onto a rule, and keep multi-source assignments on
hand-entered parameters.

An earlier revision of this profile defaulted to
`in:devices metadata.netbox_candidate:true`. Nothing in the tree writes that key
-- unlike `proxmox_candidate`, which the mapper stamps -- so every rule left on
that default matched zero devices and materialised nothing, silently. It has
been replaced by the default above; older notes describing it still say
`netbox_candidate`.

On 1.4.49 there is no `NetBox` entry under **New Credential** or **New Rule**,
no `netbox` provider, and no `inventory_sync` purpose -- the token is a plugin
assignment parameter and there is no rule to move it to.

First release containing the profile: `<first-release>`.
:::

### VulnCheck

VulnCheck is credential-only. Core downloads the KEV and nist-nvd2 feeds itself;
there is no plugin package and no rule.

1. **Create the credential.** **New Credential** -> `VulnCheck - API token`.
2. **Select it on the feed.** **Settings -> Security -> Vulnerability Feeds**
   (`/settings/security/vulnerability-feeds`) -> pick the credential in the feed's
   credential select.

The feed row's `credential_ref` is the only source. There is no environment or
application-config fallback: `VULNCHECK_API_TOKEN`, `SERVICERADAR_VULNCHECK_TOKEN`,
and `:vulncheck_token` are unread. A feed with no credential reference fails with
a message naming both halves of the job -- create a `vulncheck` API token
credential at `/settings/networks/credentials`, then select it on the
`vulncheck-kev` or `nist-nvd2` row at `/settings/security/vulnerability-feeds`.
The message is recorded, inside the inspected error tuple, in the feed row's
`last_error`, and core logs the same warning at boot.

Attach the credential *before* upgrading a deployment that still relied on the
old environment variables: after the upgrade those variables are read by nothing,
and the feed fails until a credential is selected.

### SNMP

SNMP is a protocol ServiceRadar speaks itself, so its descriptor is
platform-owned rather than package-published. It is credential-only, scoped to
agents, with one purpose (`snmp_monitoring`) and two auth methods:

- `community` -- a community string, for v1/v2c.
- `v3` -- username, auth protocol and password, optional privacy protocol and
  password.

1. **Create the credential.** **New Credential** ->
   `SNMP - Community string (v1 / v2c)` or `SNMP - SNMPv3 user`.
2. **Bind it on a profile.** **Settings -> SNMP Profiles** (`/settings/snmp`) ->
   pick the credential instead of "Store on this profile (encrypted here)". A
   profile form can also tick "save as reusable" to promote the values typed there
   into a shared credential and bind to it.

Only credentials of kind `snmp` are offered on an SNMP profile; the resolver
cannot read any other payload shape.

**The one remaining file-based credential path.** The Go agent still reads SNMP
community strings and v3 passwords from a local file when one is present:

```text
/etc/serviceradar/snmp.json            # Linux
/usr/local/etc/serviceradar/snmp.json  # macOS
```

This predates the credential store and is the only supported non-database
credential source left. Migrate it by creating the equivalent SNMP credential
above, binding it to the profile that covers those targets, and then removing the
credentials from the file. Do not add new deployments to this path.

## Troubleshooting

### UniFi Protect reports "0 cameras, 0 streams"

**Symptom.** A `CRITICAL` plugin result whose summary is a bare count, with
`details.collection_error` reading `host error -2 (http_request)`.

**Cause.** Egress denial, not a credential problem. `-2` is the host's
permission-denied code. The sandbox refuses to let an `allowed_domains: ["*"]`
wildcard expand to an IP literal -- a wildcard is a claim about DNS names, and
private address space is a much more sensitive reachability claim -- so a
literal-IP destination falls through to `allowed_networks`. If the manifest does
not declare the network the controller is on, the request is denied before a
socket is opened.

**Fix.** The plugin manifest must declare `allowed_networks` covering private
address space.

:::note Fixed in 1.4.48
**`allowed_networks` on the UniFi Protect, Axis, OpenText and AWX manifests.**
1.4.48 declares RFC1918 plus CGNAT `100.64.0.0/10` on all four (link-local
`169.254.0.0/16` is deliberately excluded: no controller is deliberately
addressed there). Through 1.4.47 those four manifests declared no
`allowed_networks` at all, so every literal-IP destination was denied and no rule
setting changed it.

The `netbox-inventory` manifest was never affected -- it has declared RFC1918
`allowed_networks` since 1.4.46, without CGNAT. `proxmox` is deliberately left
alone: its destinations are authorised by the host-authority binding, which
checks the manifest's allowed ports but not its host or network allow-lists.

On a release before 1.4.48 the only in-product workaround is to give the
controller a hostname that resolves for the agent, so the request matches
`allowed_domains: ["*"]` instead of falling through to `allowed_networks`.
:::

Publishing a manifest change is not enough on its own: assignments point at a
specific package version, so publish, register, and re-materialise the updated
package. Confirm with a **fresh** `service_status` row timestamped after the
rollout, not with a successful build.

### "Invalid TLS policy" when saving a rule

**Symptom.** Saving a UniFi Protect or Axis rule fails every time with
`Invalid TLS policy`, and there is no TLS policy control on the form.

**Cause.** The control was rendered only when the selected auth method declared a
non-empty `tls_policies` list, while validation required a valid `tls_policy`
unconditionally. Neither manifest declares the key, so the input was never
rendered, the browser submitted nothing, and the save could not succeed. Core
never agreed with the form here: an undeclared list already means "any policy
permitted" everywhere else.

:::caution Not in 1.4.49
The fix makes the control render whenever the provider declares transport rule
controls and the auth method declares no SSH host key policies, defaulting to the
full policy set when the auth method does not narrow it, and makes an absent
`tls_policy` on submit fall back to the resource default instead of failing the
save. It is merged but unreleased.

First release containing it: `<first-release>`.
:::

**On affected older versions.** The Credential Rules form cannot save a UniFi
Protect or Axis rule because it cannot submit the required policy. Releases
with the [credential admin API](#managing-credentials-from-the-api) allow the
rule to be created with an explicit TLS policy through that API. Earlier
releases without this API require an upgrade.

### "AWX configuration invalid: api_token is required (resolved from credential broker grant)"

**Symptom.** An AWX assignment fails on a 60-second cadence, forever, with that
message -- while `awx.ping` reports the controller reachable.

**Cause.** The AWX package is a command bridge: its token arrives per dispatch,
inside the grant that dispatch carries. Its assignment params hold no token by
design. An assignment without the `action-only:v1` capability also gets a periodic
runner, and that scheduled run invokes `run_check` with the assignment's own
params, which can never satisfy the check.

**Fix.** The failure is not a missing credential -- do not go looking for one.

:::note Fixed in 1.4.48
**`action-only:v1` on the AWX manifest.** 1.4.48 adds that capability to
`go/cmd/wasm-plugins/awx/plugin.yaml`, so the assignment is addressable through
`AgentCommandBus` without a periodic runner and the recurring failure stops.
Republish, register, and re-materialise the package after upgrading -- an
existing assignment points at the old package version and keeps its runner, so
the message survives the upgrade until the assignment is re-materialised.

Before 1.4.48 the message repeats on the assignment's cadence and is cosmetic:
dispatched AWX commands still carry their own grant and still work. Judge AWX
health from `awx.ping` and from an actual dispatch, not from this result.
:::

### "NetBox inventory_sync has no sources configured"

**Symptom.** The `netbox-inventory` assignment reports `UNKNOWN` with that
message. On builds carrying the credential profile the wording is longer and the
condition behind it is narrower:

```text
NetBox inventory_sync has no source configured: set base_url and api_token, or attach a NetBox credential rule
```

**Cause.** The assignment named no source at all. The plugin reads `sources[]`
from the assignment params and falls back to the flat single-source fields only
when `sources` is absent. Through 1.4.49 that fallback engages only when
`base_url` is non-empty, so a half-configured flat source is reported as having
no sources; from `<first-release>` it engages as soon as any of `base_url`,
`api_token`, `source_id` or `source_name` is set, and a half-configured source is
then reported by the field it is missing instead.

**Fix.** Fill in `sources[]` on the plugin assignment under **Admin ->
Plugins**, with `source_id`, `base_url`, and `api_token` per source. See
[NetBox: Configuration](./netbox.md#configuration).

Related messages, all `UNKNOWN`, all naming the source that is short a field:

| Message | Meaning |
| --- | --- |
| `NetBox source <id> has no api_token configured` | The source entry exists, its token is blank. |
| `NetBox source <id> has an invalid base_url` | The base URL is blank or does not parse. From `<first-release>` a blank one is reported separately as `NetBox source <id> has no base_url configured`, and a malformed one appends the reason -- `NetBox source <id> has an invalid base_url: base url must be http or https`. |

Two more `UNKNOWN` results are about the configuration as a whole rather than one
source. `NetBox configuration could not be loaded` means the host returned no
configuration for the assignment. `NetBox configuration could not be parsed`,
from `<first-release>`, means it returned one the plugin cannot decode -- a flat
config with a mistyped field, or a `serviceradar.plugin_inputs.v1` envelope with
a malformed `template`.

On 1.4.49 there is no NetBox credential rule to configure any of this from, and
an API token in assignment params is the placement the credential model exists to
remove. Merged work adds the `netbox` credential profile -- see
[NetBox](#netbox) above for what it declares and what it does not fix.

### "proxmox_tls_verification_required"

**Symptom.** Proxmox inventory enrichment resolves no scope and mints no grant;
the error is `proxmox_tls_verification_required`.

**Cause.** The rule's TLS policy is `skip_verify`, and Proxmox
`inventory_enrichment` requires exactly `proxmox_api_token` with `verify`. The
check is fail-closed on purpose: Proxmox enrichment writes into device identity.

**Fix.** Set the rule's TLS policy to `verify`, then make `verify` succeed: add
the PVE cluster CA to the agent's `plugin_http_trusted_ca_files`, and confirm the
node certificate carries the agent's IP as an `IP Address` SAN. See
[Proxmox: TLS Verification and Node Certificates](./proxmox.md#tls-verification-and-node-certificates)
for the commands. Do not weaken the rule to `skip_verify`; that path is rejected
at resolution regardless of what the form accepted, and it would not relax the
plugin's transport anyway -- the agent refuses to inject a Proxmox grant into a
request that skips verification.

The same requirement applies to `console_access` when the auth method is
`proxmox_api_token`. SSH-backed console rules are checked against the SSH host key
policy instead, and fail with `proxmox_ssh_host_key_verification_required`.

### A rule saves but nothing happens

Work through Preview first:

| Preview says | Meaning |
| --- | --- |
| Matched 0 | The target query returns nothing. Test it on the Devices page. |
| Matched > 0, In Scope 0 | The scope is wrong -- the matched devices belong to a different agent, gateway, or partition. |
| In Scope > 0, no consumers | Materialisation has not run yet, or no approved package provides that purpose. The dry run flags `no approved package`. |
| Conflicts listed | Another rule at the same or lower priority is winning. |

If Consumers lists assignments but the plugin still fails, the problem is past the
rule: check the plugin result's `details` and the agent log for the paired HTTP
host-call entries.

## Related pages

- [Proxmox VE Integration](./proxmox.md)
- [UniFi Protect](./unifi-protect.md)
- [NetBox Integration](./netbox.md)
- [Ansible Integration](./ansible.md)
- [SNMP Ingest Guide](./snmp.md)
- [Wasm Plugins](./wasm-plugins.md)
- [RBAC and Roles](./rbac-and-roles.md)
- [TLS Security](./tls-security.md)
