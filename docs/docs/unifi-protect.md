---
title: UniFi Protect
---

# UniFi Protect

ServiceRadar talks to UniFi Protect through two first-party Wasm plugins:

- `unifi-protect-camera` - inventory and events
- `unifi-protect-camera-stream` - live media relay

Credentials never go on the plugin assignment form. Create a credential and a
credential rule under **Settings -> Networks -> Credential Rules**
(`/settings/networks/credentials`), then assign the plugin to an agent that rule
covers. The general model -- credentials, rules, scopes, TLS policy, and how a
rule reaches a plugin -- is in [Credential Management](./credentials.md).

## What to call

The plugin talks to **UniFi OS** (Dream Machine, Cloud Gateway, or a UniFi OS
console), not to each camera. Cameras are enumerated from Protect after login.

Typical endpoints, substituting the controller host:

| Purpose | URL / port |
| --- | --- |
| UniFi OS login | `https://<controller>/api/auth/login` |
| Protect bootstrap | `https://<controller>/proxy/protect/api/bootstrap` |
| RTSP / RTSPS relay | port `7447` (some controllers use `7441`) |
| HTTPS API | port `443` |

`<controller>` is a hostname or LAN IP such as `unifi.lan` or `192.168.1.1`.
A full URL is fine; ServiceRadar keeps the host.

The controller is almost always on private address space, and the sandbox does
not let a domain wildcard expand to an IP literal: `allowed_domains` is a claim
about DNS names, so a literal-IP destination falls through to `allowed_networks`
instead.

:::caution Not in 1.4.46
The `unifi-protect` manifest declares no `allowed_networks` in 1.4.46, so a
controller addressed by IP is denied before a socket is opened, and no rule
setting changes that. Merged work adds RFC1918 plus CGNAT `100.64.0.0/10` to the
UniFi Protect, Axis, OpenText and AWX manifests.

Until it ships, give the controller a hostname the agent resolves so the request
matches `allowed_domains: ["*"]`. First release containing the declaration:
`<first-release>`.
:::

## Create the credential

1. In UniFi OS open **Settings -> Control Plane -> Integrations** and create an
   API key. API key is preferred over a local admin password.
2. In ServiceRadar open **Settings -> Networks -> Credential Rules**
   (`/settings/networks/credentials`).
3. **New Credential -> UniFi Protect - API key**. Name it and paste the key. The
   provider and auth method are fixed by the menu entry you pick.

A local UniFi OS account works as **New Credential -> UniFi Protect - Username
and password** if you cannot use an API key.

## Create the rule

**New Rule -> UniFi Protect**.

| Field | What to put |
| --- | --- |
| Secret | The API key (or username/password) you just saved |
| Auth method | `api_key` (or `username_password`) |
| Purpose | `camera_inventory` and `camera_stream` |
| UniFi Protect controller host | The UniFi OS address (Dream Machine, Cloud Gateway, or UniFi OS console), not a camera IP. Required unless the target query already resolves that device. |
| Target query | Devices this rule applies to. Start with `in:devices vendor:"Ubiquiti"`. |
| Allowed ports | `443, 7447` |
| TLS policy | `verify` when the agent can chain the controller certificate and it is valid for the address dialled; otherwise `skip_verify` |

:::caution Not in 1.4.46
**The TLS Policy control does not render for UniFi Protect in 1.4.46, and the
rule cannot be saved.** The provider declares `rule_controls.transport: true` but
neither auth method declares a `tls_policies` list, and through 1.4.46 the
control was drawn only when that list was non-empty -- while the save path
required a valid `tls_policy` regardless. The browser submits nothing and every
save fails with `Invalid TLS policy`. Axis has the same shape and the same
symptom.

There is no workaround: the Credential Rules page is the only route to the
resource. Merged work renders the control whenever the provider declares
transport controls, offering the full policy set when the auth method does not
narrow it. First release containing the fix: `<first-release>`.
:::

Once it renders, both `verify` and `skip_verify` are offered, because neither
auth method narrows the list. Prefer `verify`, and make it succeed by adding the
controller certificate's issuing CA to `plugin_http_trusted_ca_files` in the
agent's `agent.json` (Helm: `agent.pluginHTTPTrustedCAFiles`). `skip_verify` is
defensible for a factory self-signed certificate on a segment the agent already
sits on; unlike Proxmox, the UniFi grant is resolved at the control plane, so a
`skip_verify` rule does relax the plugin's own transport.

The controller field is the Protect console. The target query is inventory
scope. If the controller is not in inventory yet, keep a seed query that
matches at least one in-scope device and set the controller field to the
UniFi OS IP. The plugin calls that host, not the seed row IP.

## Assign the plugin

On **Admin -> Plugins**, assign `unifi-protect-camera` (and the stream package
if you want live video) to the agent that can reach the controller. Do not
paste the password or API key into Configuration. If the form still shows
those fields, you are on an old imported schema; the assignment UI now hides
them, and a matching credential rule is what supplies auth. Delivery detail is
in [Credential Management](./credentials.md#how-a-rule-reaches-a-plugin).

## Example (lab / demo)

A working lab rule looks like:

- Controller: `192.168.1.1`
- Target query: `in:devices vendor:"Ubiquiti"` (or a seed device IP)
- Agent scope: the on-site agent
- TLS: `verify` once the controller certificate's issuing CA is trusted by the
  agent; `skip_verify` while UniFi OS still uses its default certificate and the
  agent is on the same trusted segment
- Ports: `443, 7447`

## Troubleshooting

- **`UniFi Protect: 0 cameras, 0 streams` with `details.collection_error`
  reading `host error -2 (http_request)`**: the sandbox denied egress to the
  controller, not an auth failure. `-2` is the host's permission-denied code.
  Expected on 1.4.46 when the controller is addressed by IP. See
  [Credential Management: 0 cameras, 0 streams](./credentials.md#unifi-protect-reports-0-cameras-0-streams).
- **`Invalid TLS policy` when saving the rule**: expected on 1.4.46 and earlier.
  The form does not render the TLS Policy control for this provider while still
  requiring the value, so the rule cannot be saved and nothing you change on it
  helps. The fix is merged but unreleased; see
  [Credential Management: Invalid TLS policy](./credentials.md#invalid-tls-policy-when-saving-a-rule).
- **configuration error: host is required**: no enabled UniFi Protect rule
  covers that agent, or the rule has neither a controller host nor a target
  that resolves a host.
- **Login or bootstrap 401 / 403**: wrong API key or local account. Save a new
  credential value; do not edit the plugin assignment params.
- **TLS errors**: prefer `verify` with the controller's issuing CA added to the
  agent's `plugin_http_trusted_ca_files`. Use `skip_verify` only for the factory
  self-signed cert.
- **Streams fail after inventory works**: confirm port `7447`/`7441` is
  allowed and that the rule purpose includes `camera_stream`.
