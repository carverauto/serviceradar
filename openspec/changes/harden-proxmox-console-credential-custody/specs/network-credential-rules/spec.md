## ADDED Requirements

### Requirement: Proxmox console rules authorize credential use by the current actor
A Proxmox credential rule used for a console SHALL declare purpose `console_access` and an explicit credential-use policy for actor principals, roles, or groups. Rule scope over devices or agents SHALL NOT by itself authorize a user to consume the credential.

#### Scenario: Actor and target are allowed
- **GIVEN** an enabled Proxmox rule declares purpose `console_access`
- **AND** its target query includes the canonical device and exact v3 provider instance
- **AND** its use policy allows the current actor
- **WHEN** console authorization evaluates the rule
- **THEN** the rule MAY be selected for that actor, device, provider instance, and session
- **AND** the allow decision SHALL be bound into the broker grant

#### Scenario: Rule targets device but not actor
- **GIVEN** an enabled Proxmox rule targets the requested device
- **AND** the current actor is absent from or denied by the rule's credential-use policy
- **WHEN** the actor requests a console
- **THEN** rule selection SHALL fail before credential resolution
- **AND** a system actor SHALL NOT override the denial

#### Scenario: Inventory-purpose rule is offered for console
- **GIVEN** a Proxmox rule declares only `inventory_enrichment`
- **WHEN** it is considered for a console session
- **THEN** it SHALL be rejected
- **AND** the system SHALL NOT infer `console_access` from provider type, API-token auth method, device scope, or an earlier default

### Requirement: Credential-use policy migration denies implicit access
Existing Proxmox console-capable rules without an explicit actor-use policy SHALL migrate to a review-required deny state rather than implicitly allowing every user who can open a console.

#### Scenario: Legacy rule lacks actor-use policy
- **GIVEN** a legacy Proxmox rule has console purpose or was previously reused for console
- **AND** it has no explicit credential-use actor policy
- **WHEN** the rule is migrated or evaluated
- **THEN** brokered console use SHALL be denied until an operator reviews and saves an allow policy
- **AND** inventory use SHALL remain separately governed by its own purpose and assignment policy

#### Scenario: Operator previews policy
- **GIVEN** an operator can manage credential rules
- **WHEN** the operator previews a Proxmox console rule
- **THEN** the UI SHALL show the targeted devices/provider instances and allowed principals, roles, or groups
- **AND** it SHALL warn about ambiguous legacy identities and missing `devices.console.credentials.use` grants without revealing the secret
