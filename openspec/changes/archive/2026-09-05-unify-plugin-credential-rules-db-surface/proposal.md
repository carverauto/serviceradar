# Credential Rules As The DB-Backed Credential Surface

## Why

Operator directive: proxmox, AWX, and UniFi Protect credentials must live in the
ServiceRadar database and be fully manageable from settings/credential-rules —
not from k8s secrets, not hardcoded, and not requiring RPC/DB seeding. Today the
credential-rules UI (`network_credential_rules_live.ex`) only exposes
`proxmox_api_token`/`ssh_private_key`/`username_password`/`certificate`/`opaque`
auth and `inventory_enrichment`/`console_access`/`discovery`/`generic` purposes;
it has no `api_key` auth, no `camera_inventory`/`camera_stream` purposes, no
api_key secret form, and no controller-host metadata field. AWX credentials are
seeded via RPC into a `NetworkCredentialSecret` referenced by
`AnsibleController.credential_secret_id`. The operator wants entering/editing a
credential to be a single action on the rule.

## What Changes

- Add `api_key` (and AWX OAuth token) auth methods, `camera_inventory`/
  `camera_stream` purposes, and a controller-host / static-host metadata field to
  the credential-rules UI and rule model.
- Make AWX controllers manageable as credential rules (drop the RPC-seeded-secret
  requirement); a UniFi Protect api_key + host is a first-class rule.
- Keep credential material DB-backed + encrypted (AshCloak), resolved just-in-
  time via the credential broker — never a k8s secret or hardcoded value.

## Impact

- Affected specs: `network-credentials`.
- Affected code: `elixir/web-ng/.../settings/network_credential_rules_live.ex`,
  `network_credential_secret.ex`, provider profiles (proxmox/unifi/awx),
  `ansible/controller.ex`.
- Unblocks UniFi streams (api_key rule) and cleans up AWX controller onboarding.
