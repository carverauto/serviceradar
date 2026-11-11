## ADDED Requirements

### Requirement: Host keys are trusted centrally by device identity
The system SHALL verify the SSH host key of every remote-access SSH session and readiness probe to an inventory device against the trusted host keys stored for that device's canonical UID, and SHALL deliver those keys to the routing agent inside the authenticated session instruction.
The agent accepts the connection only when the offered key is one of the delivered keys, and negotiates only host-key algorithms for which a key was delivered. Trust does not depend on which agent routes the session or on the hostname or address dialed. The agent's local known-hosts file is not consulted, and is not written, for a session that carries delivered keys. A device may hold several trusted keys of different types.

#### Scenario: Second agent routes to an already trusted host
- **GIVEN** a device whose host key is trusted in the central store
- **WHEN** a session to the device is routed through an agent that has never connected to it
- **THEN** the host key is verified and the session proceeds without any trust prompt

#### Scenario: Same host dialed by address instead of name
- **GIVEN** a device with a trusted host key
- **WHEN** a session dials the device by a different address of the same device
- **THEN** the same trusted keys apply

### Requirement: Enrollment populates host-key trust
The system SHALL record the public host keys reported by an enrollment result as trusted keys of the enrolled device, with source `enrollment`, when the device has no trusted key.
The record names the enrollment attempt as evidence. An administrator with `settings.remote_access_host_keys.manage` can also trust a key that an agent observed, in Settings or through the API, for one device or for a selection of devices in one action. A user who approves an unknown key from the console prompt records it in the central store, and only a user holding that permission may do so.

#### Scenario: First enrollment of a host
- **GIVEN** a device with no trusted host key
- **WHEN** its enrollment result reports the host's public keys
- **THEN** those keys are trusted for the device
- **AND** the first session through any agent needs no trust prompt

#### Scenario: Console approval without the permission
- **WHEN** a user without `settings.remote_access_host_keys.manage` is shown an unknown host key
- **THEN** the user cannot approve it and is told who can

### Requirement: Unknown and changed host keys are refused and classified
The system SHALL refuse a connection, before any user authentication is attempted, when the device has no trusted host key or when the offered key is not among its trusted keys.
With no trusted key, the offered key is recorded as `pending` with source `agent_observed`, and the device's probe-eligible device accounts take readiness state `pending` with reason `host_key_unknown`. With trusted keys that do not include the offered key, the offered key is recorded as `conflict`, the device's probe-eligible device accounts take readiness state `drifted` with reason `host_key_changed`, and an audit event and an operator-visible event are written. A changed key is never trusted because it was observed, and never because an enrollment result reported it, unless a host-key change was authorized for that device.

#### Scenario: Host key changes unexpectedly
- **GIVEN** a device with a trusted host key
- **WHEN** an agent is offered a different key
- **THEN** the connection is refused before authentication
- **AND** the device's probe-eligible device accounts are `drifted` with reason `host_key_changed`

#### Scenario: Enrollment reports a different key without authorization
- **GIVEN** a device with a trusted host key and no authorized host-key change
- **WHEN** an enrollment result reports a different key
- **THEN** the reported key is recorded as `conflict` and is not trusted

### Requirement: Authorized host-key rotation
The system SHALL replace a device's trusted host keys only through an authorized host-key change: an administrator with `settings.remote_access_host_keys.manage` authorizes the change for one device or for the devices an access rule covers, for a bounded time, or resolves a recorded conflict directly.
While a change is authorized, the first enrollment result or agent observation for the device replaces the trusted keys: the new keys become trusted, the previous ones are marked rotated and linked to their replacements, and the authorization is consumed. An authorization that expires unused changes nothing. Every authorization, replacement and expiry is audited with the authorizing principal.

#### Scenario: Planned reinstall of many hosts
- **GIVEN** an administrator who authorized a host-key change for the devices an access rule covers
- **WHEN** those hosts are reinstalled and enrolled again within the authorized time
- **THEN** each device's new keys are trusted and its old keys are marked rotated
- **AND** no per-host or per-agent action was needed

#### Scenario: Authorization expires
- **WHEN** an authorized host-key change is not used within its time
- **THEN** the device's trusted keys are unchanged and a later different key is a conflict

### Requirement: Agents without central host-key support are identified
The system SHALL deliver trusted host keys only to agents that advertise support for them, and SHALL show in the device's readiness and in agent settings when the routing agent lacks that support.
A session or probe routed through such an agent keeps the agent's local known-hosts verification, so trust recorded centrally does not apply to it.

#### Scenario: Older agent
- **GIVEN** a routing agent that does not advertise central host-key support
- **WHEN** a permitted actor opens the device's remote-access surface
- **THEN** the surface states that the agent must be upgraded for central host-key trust

### Requirement: Host-key records follow device identity
The system SHALL move a merged-away device's host-key records to the surviving device in the same transaction as the merge, recording the originating device UID, and SHALL return them on unmerge.
When the two devices hold different trusted keys of the same type, both remain trusted and the pair is reported for review, because a merge asserts that the records describe one host.

#### Scenario: Merge of two records of one host
- **GIVEN** a trusted host key stored for a device that is merged into another
- **WHEN** the merge completes
- **THEN** the surviving device holds the trusted key
