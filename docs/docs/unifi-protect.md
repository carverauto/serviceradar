---
title: UniFi Protect
---

# UniFi Protect

ServiceRadar talks to UniFi Protect through two first-party Wasm plugins:

- `unifi-protect-camera` - inventory and events
- `unifi-protect-camera-stream` - live media relay

Credentials never go on the plugin assignment form. Create a secret and a
credential rule, then assign the plugin to an agent that rule covers.

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

## Create the secret

1. In UniFi OS open **Settings -> Control Plane -> Integrations** and create an
   API key. API key is preferred over a local admin password.
2. In ServiceRadar open **Settings -> Networks -> Credentials**.
3. **New Secret -> API Key**. Name it, set provider to `unifi-protect`, paste
   the key.

A local UniFi OS account works as **New Secret -> Username & Password** if you
cannot use an API key.

## Create the rule

**New Rule -> UniFi Protect**.

| Field | What to put |
| --- | --- |
| Secret | The API key (or username/password) you just saved |
| Auth method | `api_key` (or `username_password`) |
| Purpose | `camera_inventory` and `camera_stream` |
| UniFi OS / Protect controller | The UniFi OS address. Required unless the target query already resolves that device. |
| Target query | Devices this rule applies to. Start with `in:devices vendor:"Ubiquiti"`. |
| Allowed ports | `443, 7447` |
| TLS policy | `verify` when the controller has a trusted cert; `skip_verify` for the factory self-signed cert |

The controller field is the Protect console. The target query is inventory
scope. If the controller is not in inventory yet, keep a seed query that
matches at least one in-scope device and set the controller field to the
UniFi OS IP. The plugin calls that host, not the seed row IP.

## Assign the plugin

On **Admin -> Plugins**, assign `unifi-protect-camera` (and the stream package
if you want live video) to the agent that can reach the controller. Do not
paste the password or API key into Configuration. If the form still shows
those fields, you are on an old imported schema; the assignment UI now hides
them, and a matching credential rule is what supplies auth.

## Example (lab / demo)

A working lab rule looks like:

- Controller: `192.168.1.1`
- Target query: `in:devices vendor:"Ubiquiti"` (or a seed device IP)
- Agent scope: the on-site agent
- TLS: `skip_verify` when UniFi OS still uses its default certificate
- Ports: `443, 7447`

## Troubleshooting

- **configuration error: host is required**: no enabled UniFi Protect rule
  covers that agent, or the rule has neither a controller host nor a target
  that resolves a host.
- **Login or bootstrap 401 / 403**: wrong API key or local account. Recreate
  the secret; do not edit the plugin assignment params.
- **TLS errors**: set the rule TLS policy to `skip_verify` only for the
  factory self-signed cert.
- **Streams fail after inventory works**: confirm port `7447`/`7441` is
  allowed and that the rule purpose includes `camera_stream`.
