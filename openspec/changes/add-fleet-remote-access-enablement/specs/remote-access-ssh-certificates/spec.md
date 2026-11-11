## ADDED Requirements

### Requirement: Certificate access rules are credential rules
The system SHALL represent every SSH certificate access grant as a `network_credential_rules` row with provider `ssh`, auth method `ssh_certificate` and purpose `remote_access` (an "access rule"), and SHALL NOT read certificate access policy from process environment, files, Helm values or Kubernetes Secrets.
An access rule is created, changed, enabled, disabled, previewed and deleted through the same Settings area, admin API and Terraform resource as every other credential rule, under the same permission (`settings.credentials.manage`), with the same version history. A change to an access rule takes effect for the next authorization decision without restarting any workload.

#### Scenario: Rule created in Settings takes effect without a restart
- **GIVEN** a device that no access rule covers
- **WHEN** an administrator creates and enables an access rule whose target query matches the device
- **THEN** the next certificate request for that device is evaluated against the new rule
- **AND** no workload is restarted

#### Scenario: Rule managed through the API and Terraform
- **WHEN** a client with `settings.credentials.manage` creates an access rule through the credential rule admin API or the `network_credential_rule` Terraform resource
- **THEN** the rule is stored and behaves exactly as one created in Settings

#### Scenario: Environment policy is not consulted
- **GIVEN** the one-time import has completed
- **AND** the workload still has a certificate policy file or environment variable
- **WHEN** a certificate is requested
- **THEN** the decision uses access rules only

### Requirement: Access rule content
The system SHALL reject an access rule unless it carries a target query, an edge scope, a reference to a user CA credential, an actor-use policy, between 1 and 16 Unix accounts and a certificate lifetime.
Each account has a name matching `^[a-z_][a-z0-9_-]{0,31}$`, never `root`, and a mode of `existing` or `managed`. No account name is defaulted by the product. The actor-use policy is the existing `serviceradar.credential_use_policy.v1` document (principals, roles, groups) and is deny-by-default. The certificate lifetime is at least 60 seconds and at most the deployment maximum. The rule's SSH host-key policy is `known_hosts`, which for an access rule means the central host-key store. A rule may set `allow_elevated_targets` (default false), whose effect is defined by the enrollment capability.

#### Scenario: Rule without an actor-use policy is rejected
- **WHEN** an administrator saves an access rule with no actor-use policy
- **THEN** the save is rejected with a message naming the missing policy

#### Scenario: Root account is rejected
- **WHEN** an administrator saves an access rule listing the account `root`
- **THEN** the save is rejected

#### Scenario: Host-key policy other than the central store is rejected
- **WHEN** an administrator saves an access rule with host-key policy `trust_on_first_use` or `skip_verify`
- **THEN** the save is rejected

### Requirement: Devices are matched by canonical identity only
The system SHALL decide whether an access rule covers a device only by evaluating the rule's target query for that device's canonical UID and the rule's edge scope against the agent that routes the session.
The membership test is exact for the one device asked about; it is never answered from a sampled or truncated result set. A hostname, an IP address or any other non-unique attribute is never a key that selects policy, although a target query may filter on such attributes like any other inventory query. The edge scope is satisfied when the routing agent is the scoped agent, belongs to the scoped gateway, or belongs to the scoped partition.

#### Scenario: Two devices share a hostname
- **GIVEN** two devices at different sites with the same hostname
- **AND** an access rule whose target query selects one of them by UID
- **WHEN** a certificate is requested for the other device
- **THEN** the rule does not cover it

#### Scenario: Inventory larger than any preview sample
- **GIVEN** an access rule whose target query matches more devices than the rule preview displays
- **WHEN** a certificate is requested for a matching device that the preview did not display
- **THEN** the rule covers the device

#### Scenario: Routing agent outside the rule scope
- **GIVEN** an access rule scoped to partition `SITE01`
- **WHEN** the session for a matching device is routed through an agent in partition `SITE02`
- **THEN** the rule does not cover the session

### Requirement: Deterministic rule selection
The system SHALL authorize a certificate request with the first enabled access rule, ordered by priority ascending and then creation time ascending, that covers the device and session, lists the requested account and admits the actor under its actor-use policy.
The selected rule supplies the certificate lifetime and is named in the audit record and in the certificate key ID. When no rule qualifies, the request is denied with the classified reason of the nearest miss (see "Classified certificate failures").

#### Scenario: Two rules admit the same request
- **GIVEN** two enabled access rules that both cover the device, list the account and admit the actor
- **WHEN** the actor requests a certificate
- **THEN** the rule with the lower priority value is selected
- **AND** the audit record names that rule

#### Scenario: Rule disabled between two requests
- **GIVEN** an actor who obtained a certificate under an access rule
- **WHEN** the rule is disabled and the actor requests another certificate
- **THEN** the request is evaluated without that rule

### Requirement: Principals are generated per device account
The system SHALL generate and store one opaque certificate principal for each device account, where a device account is one canonical device paired with one Unix account that at least one enabled access rule lists for that device.
A principal is `srp_v1_` followed by 43 URL-safe base64 characters encoding 32 bytes from a cryptographic random source. It is unique across the deployment, is never derived from a device attribute, and is never accepted from a browser, an API client, an inventory file or a playbook input. The set of device accounts and their principals is the single source of truth from which both certificate issuance and host enrollment are derived.

#### Scenario: New device account receives a principal
- **GIVEN** an enabled access rule listing account `svc-ops`
- **WHEN** a device first matches the rule's target query
- **THEN** a device account exists for that device and `svc-ops` with a newly generated principal

#### Scenario: Principal is not shared between devices
- **GIVEN** two devices covered by the same access rule and account
- **THEN** their device accounts hold different principals

#### Scenario: Client-supplied principal is ignored
- **WHEN** a certificate request carries a principal or a principal mapping
- **THEN** the request is rejected

### Requirement: Certificates carry only the requested device account
The system SHALL issue a certificate that contains only the non-revoked principals of the one device account being accessed.
A device account has one current principal and, at most, one previous principal during a rotation and one imported legacy principal after migration. A certificate issued for one device account is therefore not accepted for another account on the same host or for any account on another host enrolled with generated principals.

#### Scenario: Certificate for one device is refused by another
- **GIVEN** two enrolled devices with generated principals
- **WHEN** a certificate issued for the first device is presented to the second
- **THEN** the second host rejects it

### Requirement: Principal rotation and revocation
The system SHALL rotate a device account's principal by generating a new current principal, keeping the replaced one as the previous principal until a readiness probe succeeds with the new principal alone, and then revoking the previous principal.
Rotation can be requested for one device account, for every device account an access rule covers, or for the whole deployment. Revoking a device account's principals stops issuance for them immediately and returns the device account to an unverified state until it is enrolled again. Removing an actor's access (rule change, actor-use policy change, account disabled) stops issuance at the next request; certificates already issued remain valid on the host until they expire, which is why the lifetime is bounded.

#### Scenario: Rotation does not interrupt access
- **GIVEN** a verified device account
- **WHEN** an administrator rotates its principal
- **THEN** certificates carry both the previous and the new principal until the host is enrolled with the new one and probed
- **AND** the previous principal is revoked after the probe succeeds with the new principal alone

#### Scenario: Revocation after suspected compromise
- **WHEN** an administrator revokes a device account's principals
- **THEN** no further certificate is issued for them
- **AND** the device account is no longer verified

### Requirement: Device identity changes keep access attached to the physical host
The system SHALL move the device accounts, principals, enrollment evidence and readiness state of a merged-away device to the surviving device in the same transaction as the merge, recording the originating device UID on every moved record.
When both devices hold a device account for the same Unix account, the survivor keeps its current principal and the other device's principal is retained as an additional valid principal until the next verified enrollment replaces it. An unmerge returns the records that originated from the recreated device. A deleted device's device accounts are removed and their principals are revoked; a later revival generates new principals rather than restoring revoked ones. An access rule stores no device identifier of its own, so a merge changes rule coverage only through the rule's target query; the system reports each access rule whose coverage lost the merged-away device without gaining the survivor.

#### Scenario: Duplicate records of one host are merged
- **GIVEN** an enrolled, verified device account on a device that is then merged into another device record
- **WHEN** the merge completes
- **THEN** the surviving device holds the device account and its principal
- **AND** a certificate for the surviving device is accepted by the host without re-enrollment

#### Scenario: Rule pinned to a merged-away UID
- **GIVEN** an access rule whose target query selects only the merged-away device's UID
- **WHEN** the merge completes
- **THEN** the rule is reported as no longer covering the host, with the surviving device named

#### Scenario: Deleted device is revived
- **GIVEN** a device whose principals were revoked when it was deleted
- **WHEN** the device is revived and matches an access rule again
- **THEN** new principals are generated

### Requirement: Identity required for certificate mode
The system SHALL issue user certificates only to an actor authenticated through a configured OIDC or SAML identity provider, unless the deployment's runtime setting for local certificate identity is enabled.
The setting is off by default, is changed in Settings or through the API by an administrator, is audited, and needs no restart. When it is on, a locally authenticated actor can obtain a certificate, and an actor-use policy admits that actor only through its principal and role selectors: a group selector is never satisfied by a locally authenticated actor. When it is off, a locally authenticated actor is denied with the classified reason `sso_identity_required`. System-initiated readiness probes are not user certificates and are governed by the enrollment capability.

#### Scenario: Deployment without an identity provider, setting off
- **WHEN** a locally authenticated actor requests a certificate
- **THEN** the request is denied with `sso_identity_required` and a remedy naming the setting and the identity-provider configuration

#### Scenario: Deployment without an identity provider, setting on
- **GIVEN** an access rule whose actor-use policy lists the actor's role
- **WHEN** the locally authenticated actor requests a certificate
- **THEN** the certificate is issued

#### Scenario: Group selector and a local actor
- **GIVEN** an access rule whose actor-use policy lists only groups
- **WHEN** a locally authenticated actor requests a certificate with the setting on
- **THEN** the request is denied

### Requirement: User CA is a managed credential
The system SHALL hold each SSH user CA as a credential record of kind `ssh_user_ca` that access rules reference, and SHALL let an administrator create the first CA from Settings or the API without editing deployment values.
A CA record always exposes its public key and fingerprint. Its signing key is either generated by ServiceRadar and stored encrypted in the unified credential store, or held by an external command signer that the record references. A CA record cannot be deleted while an access rule references it. CA records in an active or overlap state are the CA keys that host enrollment distributes.

#### Scenario: First CA on a new installation
- **GIVEN** an installation with no CA
- **WHEN** an administrator with `settings.credentials.manage` creates a CA in Settings
- **THEN** access rules can reference it and certificates can be signed without a deployment change

#### Scenario: CA in use cannot be deleted
- **WHEN** an administrator deletes a CA record that an access rule references
- **THEN** the deletion is refused and the referencing rules are listed

### Requirement: Classified certificate failures
The system SHALL report every refused certificate request and every failed certificate session with one reason from a closed list and a remedy, and SHALL NOT show a transport or library error string to the requesting user.
The reasons are: `no_access_rule` (no enabled access rule covers the device), `account_not_granted` (a rule covers the device but not the requested account), `actor_not_permitted` (a rule covers the device and account but not the actor), `scope_not_satisfied` (a rule would qualify but the routing agent is outside its scope), `sso_identity_required`, `not_ready` (the enrollment capability's issuance gate refused the device account; the readiness state and reason are attached), `certificate_rejected` (the host refused the certificate), `host_key_unknown`, `host_key_changed`, `target_unreachable`, `agent_unavailable` and `signer_unavailable`. The original error text is kept in the audit record for administrators.

#### Scenario: Host refuses the certificate
- **WHEN** the host rejects certificate authentication
- **THEN** the user sees `certificate_rejected` with the remedy for the device account's readiness state
- **AND** the user does not see the handshake error text

#### Scenario: Covered device, account not granted
- **WHEN** an actor requests an account that no covering rule lists
- **THEN** the denial reason is `account_not_granted`

### Requirement: Certificate access audit
The system SHALL record an audit event for every access rule change, CA change, principal generation, rotation and revocation, identity-setting change, certificate issuance and certificate denial.
An issuance or denial event names the actor, the device UID, the Unix account, the selected rule or the denial reason, and the routing agent. No audit event, log line, API response or UI surface other than the enrollment bundle and its manual-channel rendering contains a principal.

#### Scenario: Denial is audited with its reason
- **WHEN** a certificate request is denied
- **THEN** an audit event records the actor, device, account and classified reason

### Requirement: One-time import of the file-based policy
The system SHALL import a certificate policy supplied through the legacy environment variable or file into access rules exactly once, record the import with the policy's digest, and ignore the legacy policy from then on.
The import converts as follows. A top-level `accounts` list becomes an enabled access rule covering all devices and is flagged in the import report as deployment-wide. A `targets` entry keyed by a device UID becomes an enabled rule whose target query selects that UID. A `targets` entry keyed by a hostname or IP address is resolved against inventory: exactly one matching device yields an enabled UID-selecting rule, more than one yields a disabled rule that lists the candidates, and none yields a report entry only. A principal mapping with source `groups` becomes a group selector in the rule's actor-use policy; a mapping with source `email`, `email_domain` or `claim` is listed in the report as not converted, and a rule whose only mappings were not converted is imported disabled. Each principal named by a converted mapping is attached as the legacy principal of every device account the imported rule creates. Imported rules reference a CA record created from the configured CA public key.

#### Scenario: Hostname key matching two devices
- **GIVEN** a legacy policy with a `targets` entry keyed by a hostname that two devices share
- **WHEN** the import runs
- **THEN** a disabled access rule is created listing both devices as candidates
- **AND** neither device is granted access by the import

#### Scenario: Import does not repeat
- **GIVEN** a completed import
- **WHEN** the workload restarts with the same legacy policy present
- **THEN** no rule is created or changed

#### Scenario: Already-enrolled host keeps working after import
- **GIVEN** a host enrolled by hand with a principal named in the legacy policy
- **WHEN** the import has run and the readiness probe succeeds with the legacy principal
- **THEN** certificates for that device account carry the legacy principal and are accepted by the host
