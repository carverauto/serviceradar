## ADDED Requirements

### Requirement: Membership review in Ansible settings
The Ansible settings UI SHALL list current AWX inventory memberships per controller and inventory and SHALL let a human user holding `ansible.controllers.manage` approve a proposed membership by submitting exactly the evidence tuple the page displayed.

The list SHALL show host name, address, AWX host ID, link disposition, enabled state, the proposed canonical device with a link to its device page, link-evidence kind and match count, and last-seen time. It SHALL offer a needs-review filter and SHALL show how many proposals await review in each inventory. The approval request SHALL contain the controller ID, inventory ID, AWX host ID, canonical device UID, source generation, source fingerprint, and link-evidence digest shown in the review panel and nothing else.

#### Scenario: Operator approves a displayed proposal
- **WHEN** the operator opens the review panel for a current, enabled, unambiguous proposal and approves it
- **THEN** the page SHALL submit the exact tuple shown in the panel through the same membership approval service the API uses, as the logged-in user
- **AND** the membership SHALL be listed as approved after the service accepts it

#### Scenario: Proposal changed after it was displayed
- **WHEN** the approval service rejects the submitted tuple because the proposal's identity, generation, fingerprint, evidence, or currency changed
- **THEN** the page SHALL NOT resubmit the request
- **AND** it SHALL reload the membership and show the current evidence for a new review

#### Scenario: Membership cannot be approved
- **WHEN** a membership is unlinked, quarantined, disabled, already approved, or its evidence is not a single unambiguous match
- **THEN** the page SHALL show the reason it cannot be approved
- **AND** it SHALL NOT offer approval or any way to force a device link

### Requirement: Template binding review in Ansible settings
The Ansible settings UI SHALL list template binding versions per controller and job template and SHALL let a human user holding `ansible.controllers.manage` prepare a binding review, create a binding only from a prepared review's digest, and revoke a current approved version after typing its exact identifier.

The version list SHALL show state, approval expiry, inventory policy and inventories, project and SCM revision, content hash, and supported modes. The prepared review SHALL show the broker-observed inventory policy, project and SCM revision, execution environment, credential IDs and kinds, machine credential, prompt-on-launch flags, run and check support, inventory groups, input schema and classifications, and the review digest. The page SHALL NOT render credential material and SHALL NOT add brokered AWX reads beyond the existing prepare and create services. It MAY suggest identifiers from approved memberships and AWX-sourced catalog rows, and SHALL label the content SHA-256 and review ticket as values the reviewer attests.

#### Scenario: Create requires a prepared review
- **WHEN** no review has been prepared for the current request
- **THEN** the page SHALL NOT call the create service
- **AND** after preparation it SHALL submit the prepared request unchanged with `expected_review_digest` set to the displayed digest

#### Scenario: Review changed before create
- **WHEN** the create service reports that the broker-observed review no longer matches the expected digest
- **THEN** no binding SHALL be created
- **AND** the page SHALL prepare the same request again and show the new review and digest for inspection before any further create

#### Scenario: Editing the request discards the review
- **WHEN** the operator changes any request field after a review was prepared
- **THEN** the prepared review SHALL be discarded and Create SHALL be unavailable until a new review is prepared

#### Scenario: Revocation needs typed confirmation
- **WHEN** the operator submits a revocation without typing the exact binding identifier
- **THEN** the page SHALL NOT call the revoke service

### Requirement: Settings review preserves the API authority gate
Membership approval and binding prepare, create, and revoke from the settings UI SHALL use the same `ServiceRadarWebNG.AnsibleAutomation` entry points as the authenticated API with the session user's scope, and every such event SHALL re-check `ansible.controllers.manage` against current persisted authority before calling them.

The review tabs SHALL be hidden from users without `ansible.controllers.manage`; their lists SHALL be read with the session user's scope and therefore also require `ansible.runs.view` for memberships and `ansible.catalog.view` for bindings. The UI SHALL NOT approve or bind as a system actor, SHALL NOT relax the API's rejection of OAuth-client principals, and SHALL NOT introduce a token type.

#### Scenario: Authority removed while a review is open
- **WHEN** a user whose `ansible.controllers.manage` permission was removed sends an approve, create, or revoke event directly
- **THEN** the page SHALL refuse the event without calling the domain service
- **AND** the domain services SHALL continue to enforce the human-principal and current-authority checks independently

#### Scenario: Disconnected mount is inert
- **WHEN** the settings page performs its disconnected mount
- **THEN** the review tabs SHALL initialize empty state without reading memberships, bindings, or catalog rows
