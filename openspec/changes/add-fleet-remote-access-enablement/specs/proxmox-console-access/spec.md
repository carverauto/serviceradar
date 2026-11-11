## ADDED Requirements

### Requirement: Console rules cover targets through the stored virtualization relationship
The system SHALL decide whether a console credential rule covers a requested Proxmox console target from the virtualization relationship ServiceRadar stores (guest to owning host to integration and controller), and SHALL NOT depend on hand-set device metadata or on a sampled query result.
A rule with purpose `console_access` covers a requested device when the rule's integration and controller equal those of the device's stored relationship and the rule's target query matches the requested device or the device of its owning host. Each target-query test is exact for the one device asked about. A rule whose target query matches a host therefore covers that host and its guests, and a rule whose target query matches a single guest covers that guest only.

#### Scenario: Guest on a host matched by the rule
- **GIVEN** a console rule bound to an integration and controller whose target query matches a PVE host
- **WHEN** a console is requested for a guest that the stored relationship places on that host
- **THEN** the rule covers the request

#### Scenario: Rule for one guest
- **GIVEN** a console rule whose target query matches one guest and not its host
- **WHEN** a console is requested for another guest on the same host
- **THEN** the rule does not cover the request

#### Scenario: Deployment with more hosts than a preview sample
- **GIVEN** a console rule whose target query matches more devices than the rule preview displays
- **WHEN** a console is requested for a matching host the preview did not display
- **THEN** the rule covers the request

#### Scenario: Device carries no cluster metadata
- **GIVEN** a guest whose device metadata holds no Proxmox cluster field
- **AND** a stored relationship that identifies its host, integration and controller
- **THEN** rule coverage is decided as for any other guest

### Requirement: Console rule scope follows who reaches the PVE API
The system SHALL evaluate a console rule's edge scope against the agent that holds the active integration assignment for the rule's controller and will make the PVE API call, never against the agent that owns or reports the host or guest device.
The scope is satisfied when that agent is the scoped agent, belongs to the scoped gateway, or belongs to the scoped partition. Installing, replacing or removing a ServiceRadar agent on a PVE node or on a guest changes no console rule's coverage.

#### Scenario: Agent installed on a PVE node
- **GIVEN** a console rule scoped to the agent that polls the PVE API, under which consoles open
- **WHEN** a ServiceRadar agent is installed on one of the PVE nodes and becomes that host device's owning agent
- **THEN** consoles for that node and its guests still open under the same rule

#### Scenario: No agent in scope holds the assignment
- **WHEN** no agent within the rule's scope holds an active assignment for the controller
- **THEN** the request is denied with reason `scope_unreachable`

### Requirement: Dedicated console credential with a documented minimal privilege set
The system SHALL document the minimal Proxmox privilege set a console credential needs, per console target kind, and SHALL verify a console credential against that set on request and whenever a console rule is created or its credential changes.
The console credential is a Proxmox API token separate from the inventory token. The documented set is the privilege Proxmox requires to open a node console for host consoles and the privilege it requires to open a guest console for LXC and QEMU consoles, granted on the paths of the intended targets and on nothing else; the documentation gives the role definition and the commands to create the role, token and access-control entries. Verification reads the token's effective permissions through the PVE API by way of the agent in the rule's scope and reports each missing privilege and path. Verification never changes anything in Proxmox.

#### Scenario: Token lacks the guest console privilege
- **GIVEN** a console credential whose token lacks the guest console privilege on a guest's path
- **WHEN** the credential is verified
- **THEN** the result names the missing privilege and the path

#### Scenario: Inventory token bound to a console rule
- **WHEN** a read-only inventory token is bound to a console rule and verified
- **THEN** verification fails and names every missing console privilege

### Requirement: Classified console denial reasons
The system SHALL report every refused console request with one reason from a closed list and a remedy, chosen from the candidate rule that came closest to admitting the request.
The reasons are: `unsupported_target`, `owner_unresolved`, `owner_ambiguous`, `inventory_unavailable`, `no_console_rule` (no enabled console rule is bound to the target's integration and controller), `target_not_covered` (a bound rule exists but its target query matches neither the requested device nor its owning host), `scope_unreachable`, `actor_not_permitted` (the rule's actor-use policy does not admit the actor, or the actor lacks a console permission), `tls_not_verified`, `credential_privilege_missing`, `controller_endpoint_missing`, `agent_unavailable` and `provider_error`. Candidate rules are compared in the order the reasons are listed from `no_console_rule` onward, the rule that passes the most checks supplies the reason, and ties are broken by rule priority. A requester who cannot manage credentials sees the reason and remedy without rule names or target queries; an administrator also sees the rule that supplied the reason.

#### Scenario: Rule exists but does not admit the actor
- **GIVEN** a console rule that covers the target and whose actor-use policy does not list the actor
- **WHEN** the actor requests a console
- **THEN** the denial reason is `actor_not_permitted`
- **AND** the reason is not `no_console_rule`

#### Scenario: Rule bound to another controller only
- **GIVEN** console rules exist only for a different controller
- **WHEN** a console is requested
- **THEN** the denial reason is `no_console_rule`

#### Scenario: Requester without credential management permission
- **WHEN** a requester who cannot manage credentials is denied
- **THEN** the response contains the reason and remedy and no rule name or target query

### Requirement: Console readiness is visible per device
The system SHALL show, on the device surface of every Proxmox host and guest and before a console is opened, whether a console can be opened by the viewing actor, with the classified reason and remedy when it cannot.
The decision shown is produced by the same evaluation that admits a console request, without contacting Proxmox; the last credential verification result is included with its time. A credential whose last verification failed makes the target not ready with `credential_privilege_missing`; a verification that has not completed yet does not block. The data loads only after the LiveView is connected.

#### Scenario: Guest with no covering rule
- **WHEN** a permitted actor opens the device surface of a guest that no console rule covers
- **THEN** the surface states `target_not_covered` or `no_console_rule` with its remedy
- **AND** the console control is not offered

#### Scenario: Ready guest
- **WHEN** a console rule covers the guest and admits the actor, and the credential's last verification did not fail
- **THEN** the surface offers the console control
