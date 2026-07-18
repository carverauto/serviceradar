## ADDED Requirements

### Requirement: Authenticated partition provenance in assignment UI
The plugin package assignment UI SHALL show the current authenticated partition state for the selected agent and explain that the value is derived from the live server-observed mTLS control session. The UI SHALL NOT render an editable partition selector or submit an operator-selected partition value.

#### Scenario: Selected online agent has a current partition
- **GIVEN** an operator with plugin assignment permission selects an online agent
- **AND** the server resolves current control-session evidence for partition `default`
- **WHEN** the assignment form renders its agent context
- **THEN** the UI displays `Authenticated partition: default`
- **AND** it explains that the value will be rechecked on save
- **AND** no editable partition input is present

#### Scenario: Selected agent has no trustworthy partition evidence
- **GIVEN** an operator selects an offline agent or an agent without matching control-session evidence
- **WHEN** the assignment form renders its agent context
- **THEN** the UI identifies the authenticated partition as unavailable
- **AND** it does not imply that a saved or default partition will be used
- **AND** it prevents or clearly fails the assignment action until evidence is available

### Requirement: Legacy assignment recovery UX
The plugin configuration UI SHALL identify disabled assignments with no partition as requiring reapproval and distinguish manual ownership from policy ownership. It SHALL guide the operator to the safe recovery action appropriate to that ownership model, show only a tenant-scoped and secret-safe policy-recovery status, and prevent the UI from implying authority that the server will deny.

#### Scenario: Manual legacy assignment is presented for reapproval
- **GIVEN** a package details view includes a disabled manual assignment with no partition
- **WHEN** an authorized operator views the assignment
- **THEN** the UI labels it as an unbound legacy assignment requiring reapproval
- **AND** shows the non-secret configuration compatibility state and authenticated-agent context
- **AND** offers an explicit confirmation action to create a replacement rather than a generic update action

#### Scenario: Policy-owned legacy assignment is presented for reconciliation
- **GIVEN** a package details view includes a disabled policy-owned assignment with no partition
- **WHEN** an authorized operator views the assignment
- **THEN** the UI identifies the owning policy or credential rule when available
- **AND** does not offer a manual clone or editable recovery form
- **AND** offers an authorized reconciliation action or explains why the policy cannot currently recover it

#### Scenario: Credential-rule recovery requires credential authority in the UI
- **GIVEN** a disabled unbound policy assignment is owned by a credential rule
- **AND** an operator has plugin-assignment permission but lacks credential-management permission
- **WHEN** the operator views the package details
- **THEN** the reconciliation action is disabled with an explanation that credential permission is required
- **AND** the UI does not submit a request that purports to elevate that operator
- **AND** the control plane remains responsible for the final current-owner authorization

#### Scenario: Policy reconciliation status refreshes without disclosing request data
- **GIVEN** an authorized operator has requested reconciliation for a policy-owned legacy assignment in the current tenant
- **WHEN** the package details view refreshes while the request is queued or running
- **THEN** the UI shows a secret-safe queued or running status and refreshes the assignment until a terminal status is available
- **AND** a terminal status shows safe remediation and, when reconciled, only the replacement count
- **AND** the UI does not render request parameters, principal information, owner identifiers, raw credential material, or replacement identifiers

#### Scenario: Recovery result is actionable and secret-safe
- **GIVEN** an operator requests a legacy assignment recovery
- **WHEN** the request succeeds, conflicts, lacks evidence, is denied, or fails schema validation
- **THEN** the UI displays the outcome and any safe remediation
- **AND** it SHALL NOT render raw secret values in the result, error, or audit detail

### Requirement: Legacy recovery candidate review
The plugin configuration UI SHALL provide a tenant-scoped review list for legacy unbound assignments. The list SHALL show the affected agent UID, plugin package reference, recovery kind, redacted recovery status, and a route to review the corresponding package details. It SHALL NOT provide a bulk re-enable operation, infer a partition, or present a global recovery-request queue.

#### Scenario: Authorized operator reviews tenant recovery candidates
- **GIVEN** the current tenant has one or more disabled unbound legacy assignments
- **WHEN** an operator with plugin-assignment permission opens the Plugins index
- **THEN** the UI lists only candidates visible in that tenant with their safe review metadata
- **AND** each candidate links to its package details for an explicit manual reapproval or policy reconciliation
- **AND** the list does not assume the `default` partition or offer a bulk recovery action

#### Scenario: No cross-tenant candidate metadata is rendered
- **GIVEN** another tenant has legacy recovery candidates
- **WHEN** an operator opens the Plugins index in the current tenant
- **THEN** the UI does not render the other tenant's agent, package, status, or recovery-request existence
