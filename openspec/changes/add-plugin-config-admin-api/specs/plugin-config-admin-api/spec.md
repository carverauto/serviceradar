## ADDED Requirements

### Requirement: Credential secret admin API
The system SHALL expose authenticated JSON endpoints under `/api/admin/network-credential-secrets` that list, get, create, update details of, and rotate reusable network credential secrets, using the same authentication pipeline as `/api/admin/plugin-assignments`.

List and get responses SHALL omit `secret_payload` and `encrypted_secret_payload`. Create SHALL accept `provider`, `auth_method`, and a descriptor-backed `values` map through `CredentialSecretBuilder`. Rotate SHALL accept a `values` map for the existing credential type through `CredentialRotation`. Managing these endpoints SHALL require the `settings.credentials.manage` permission.

#### Scenario: Operator creates a secret through the API
- **GIVEN** an authenticated caller with `settings.credentials.manage`
- **WHEN** they POST a Proxmox API-token secret with `provider`, `auth_method`, and `values`
- **THEN** the system SHALL persist an `internal_encrypted` secret
- **AND** the response SHALL include `id`, `name`, `provider`, and `public_fingerprint`
- **AND** the response SHALL NOT include the token secret

#### Scenario: Viewer cannot manage secrets
- **GIVEN** an authenticated caller without `settings.credentials.manage`
- **WHEN** they GET `/api/admin/network-credential-secrets`
- **THEN** the system SHALL respond 403

### Requirement: Credential rule admin API
The system SHALL expose authenticated JSON endpoints under `/api/admin/network-credential-rules` that list, get, create, update, enable, and disable credential rules, using the same authentication pipeline as `/api/admin/plugin-assignments`.

Create and update SHALL accept every field an operator can set in the Credential Rules UI, including `tls_policy`, `ca_bundle_pem`, `server_cert_fingerprint`, `ssh_host_key_policy`, `allowed_ports`, `target_query`, `scope_type`, `scope_value`, `secret_id`, `priority`, `enabled`, and `metadata`. Trust material SHALL be validated by the existing `TrustMaterial` validation. Managing these endpoints SHALL require `settings.credentials.manage`.

#### Scenario: Operator creates a Proxmox inventory rule with a CA bundle
- **GIVEN** an authenticated caller with `settings.credentials.manage` and an existing Proxmox secret
- **WHEN** they POST a rule with `tls_policy` `verify` and a PEM `ca_bundle_pem`
- **THEN** the system SHALL persist the rule
- **AND** a subsequent GET SHALL return the CA bundle and fingerprint fields

#### Scenario: Enable and disable are first-class
- **GIVEN** an existing credential rule
- **WHEN** an authorized caller POSTs `/api/admin/network-credential-rules/{id}/disable`
- **THEN** the rule SHALL be persisted with `enabled` false
- **AND** POST `/enable` SHALL set `enabled` true

### Requirement: Ansible controller admin API
The system SHALL expose authenticated JSON endpoints under `/api/admin/ansible-controllers` that list, get, create, update, enable, and disable AWX/AAP controllers, using the same authentication pipeline as `/api/admin/plugin-assignments`.

Create and update SHALL accept `name`, `base_url`, `agent_id`, purpose-specific `*_credential_secret_id` references, and sync intervals. Responses SHALL include secret ids and SHALL NOT include token plaintext. Managing these endpoints SHALL require `ansible.controllers.manage`.

#### Scenario: Operator registers an AWX controller by secret id
- **GIVEN** an authenticated caller with `ansible.controllers.manage` and an existing `awx` secret
- **WHEN** they POST a controller with `base_url`, `agent_id`, and `sync_credential_secret_id`
- **THEN** the system SHALL persist the controller
- **AND** the response SHALL include the secret id and SHALL NOT include the token

### Requirement: CLI plugin configuration commands
`serviceradar-cli` SHALL provide one operator story for plugin configuration: device-code (or stored/token) auth against the admin APIs above, without a parallel `srctl` command.

The CLI SHALL support listing and applying plugin assignments, credential secrets, credential rules, and Ansible controllers. `plugin apply --file` SHALL be idempotent: match secrets by `provider`+`name`, rules by `provider`+`scope_type`+`scope_value`+`name`, controllers by `name`, and assignments by `agent_uid`+`plugin_id`, then create or update.

A playbook file SHALL NOT contain secret values. New secret field values SHALL be read from environment variables named in the playbook (`values_from`). Matching stored secrets SHALL be reused without reading or rotating their values. Secret reference names SHALL be unique within a playbook.

#### Scenario: Apply is idempotent
- **GIVEN** a playbook that names a secret `demo-proxmox-readonly` and a matching rule
- **WHEN** `serviceradar-cli plugin apply --file playbooks/demo-plugins.yaml` runs twice against the same instance
- **THEN** the second run SHALL keep matching secrets and update existing rules, controllers, and assignments rather than creating duplicates

#### Scenario: Playbook refuses to embed secrets
- **GIVEN** a playbook whose secret `values_from` names `SERVICERADAR_DEMO_PROXMOX_TOKEN_SECRET`
- **WHEN** that environment variable is unset and no matching secret exists on the instance
- **THEN** apply SHALL fail with an error that names the missing variable
- **AND** SHALL NOT write a secret value into any file

### Requirement: Narrow CLI scope for plugin configuration
The CLI device-code flow SHALL accept a `plugins.manage` scope that reaches the plugin-assignment, credential-secret, credential-rule, and ansible-controller admin routes, plus read-only plugin and package routes needed to resolve assignments, for a token that holds only that scope.

Coarse OAuth client credentials (`admin`, `write`, `read`) and unscoped API keys SHALL continue to reach those routes when the caller's RBAC allows it. A `plugin.publish` token SHALL NOT reach assignment or credential routes.

#### Scenario: plugins.manage token can list rules
- **GIVEN** a device-code token whose only scope is `plugins.manage`
- **WHEN** it GET `/api/admin/network-credential-rules`
- **THEN** the request SHALL pass the narrow-scope gate
- **AND** still be authorized by `settings.credentials.manage` on the user

#### Scenario: plugin.publish token cannot create a rule
- **GIVEN** a device-code token whose only scope is `plugin.publish`
- **WHEN** it POST `/api/admin/network-credential-rules`
- **THEN** the system SHALL respond 403 `insufficient_scope`
