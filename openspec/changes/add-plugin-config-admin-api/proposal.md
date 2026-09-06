# Change: Add an admin API and CLI playbook for plugin configuration

## Why

Operators can assign plugins through `/api/admin/plugin-assignments` and list
packages through `/api/admin/plugins`, but the rest of the configuration an
operator sets in the UI is LiveView-only:

- credential secrets and rules at `/settings/networks/credentials`
- CA/TLS material on those rules (`ca_bundle_pem`, `server_cert_fingerprint`,
  `tls_policy`)
- AWX/AAP controllers at `/settings/ansible`

That blocks gitops-style demo spin-up. The credential-backed plugins still
failing on demo Services (AWX/AAP Bridge, NetBox Inventory Sync, UniFi Protect
Camera, Proxmox Inventory) plus the rest of the set in
https://github.com/carverauto/serviceradar/issues/4209 cannot be applied from a
checked-in playbook because the playbook has nowhere authenticated to write.

Issue 4209 owns runtime delivery (Wasm egress, TLS-policy form save, Proxmox CA
ingest, NetBox credential profile, AWX `action-only:v1`). This change consumes
that schema and does not re-fix those ingest paths.

## What Changes

- Add authenticated admin JSON APIs for network credential secrets, credential
  rules (including TLS policy and CA trust material), and Ansible controllers,
  on the same `:api_key_auth` pipeline and RBAC as the existing plugin
  assignment APIs.
- Expose `GET /api/admin/plugin-assignments/{id}` and include `plugin_id` on
  assignment JSON so a playbook can match by plugin identity.
- Add a narrow CLI device-code scope `plugins.manage` so `serviceradar-cli`
  (device-code auth) can manage those surfaces without a second control plane.
- Extend `serviceradar-cli plugin` with assignment, secret, rule, controller,
  and idempotent `apply` commands. Playbooks talk to the API; secret values
  come from environment variables for new secrets; existing secrets are reused
  by provider and name, never copied into git.
- Check in a non-secret demo playbook that configures the credential-backed
  demo plugin set through that API.

## Impact

- Affected specs: `plugin-config-admin-api` (new), `wasm-plugin-system`
- Affected code: `elixir/web-ng` admin API, `elixir/serviceradar_core`
  authorization settings default, `js/cli`, `docs/docs/credentials.md`
- Security impact: secret payloads are write-only; list/get responses never
  include ciphertext or plaintext. CA bundles and fingerprints are public trust
  material already stored on rules. The new CLI scope is requestable only; RBAC
  (`settings.credentials.manage`, `plugins.assign`, `ansible.controllers.manage`)
  still authorizes each call.

## Non-Goals

- No runtime/CA ingest, Wasm egress, or NetBox credential-profile work from
  issue 4209. A sibling ship owns making those cards green.
- No parallel `srctl` command.
- No new orchestrator. Apply is idempotent HTTP against the existing admin API.
- No secrets, tokens, hostnames, or live demo addresses in git.
- Architecture diagrams are not needed: this is a REST resource plus a playbook.

## Gitops

The API contract and CLI live in this repository. `carverauto/gitops` can later
invoke `serviceradar-cli plugin apply --file playbooks/demo-plugins.yaml`
against an instance; it should not grow a second plugin-config control plane.
