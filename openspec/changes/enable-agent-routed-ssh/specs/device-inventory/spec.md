## ADDED Requirements

### Requirement: Device SSH actions require authoritative live readiness
Device details SHALL expose agent-ephemeral SSH only when the master deployment
policy is enabled and one current registered SSH target, selected connected
route, effective agent capability, fresh reachability proof, approved host key,
matching target enrollment policy, healthy signer/CA revision, local-account
mapping, actor permission, and hold state are all ready. Operating-system or
vendor labels alone MUST NOT make SSH available.

#### Scenario: Registered Linux target is ready
- **WHEN** the target, route, capability, trust, enrollment, signer, actor, and proof intersection is current
- **THEN** device details exposes an SSH action bound to those server-selected values

#### Scenario: Host key is unknown or changed
- **WHEN** the route observes no approved host key or a key that conflicts with approved trust
- **THEN** SSH remains unavailable with a sanitized trust reason until an authorized operator reviews it

#### Scenario: Browser submits another endpoint or route
- **WHEN** a browser supplies a host, port, agent, gateway, local account, trust mode, or credential mode different from readiness
- **THEN** session creation rejects the request before ticket or certificate issuance

