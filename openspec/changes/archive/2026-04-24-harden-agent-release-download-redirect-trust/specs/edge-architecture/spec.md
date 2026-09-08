## ADDED Requirements

### Requirement: Agent release downloads preserve the initial trusted origin
The agent SHALL download release artifacts only from the initial trusted HTTPS origin selected for that release fetch. The agent MAY follow redirects only when the redirect target preserves the original scheme, host, and effective port. The agent SHALL reject redirects that change origin.

#### Scenario: Same-origin HTTPS redirect is allowed
- **GIVEN** the agent begins a release download from `https://releases.example.com/downloads/v1.2.3/agent`
- **AND** that endpoint redirects to `https://releases.example.com/artifacts/v1.2.3/agent`
- **WHEN** the agent follows the redirect
- **THEN** the redirect is accepted
- **AND** the agent continues verification of the signed manifest and artifact digest before staging the release

#### Scenario: Cross-origin redirect from a signed artifact URL is rejected
- **GIVEN** the agent begins a release download from a signed artifact URL on `https://releases.example.com`
- **AND** that endpoint redirects to `https://objects.example-cdn.com/agent`
- **WHEN** the agent evaluates the redirect
- **THEN** the redirect is rejected
- **AND** the release download fails closed

#### Scenario: Gateway-served artifact delivery cannot leave the gateway origin
- **GIVEN** the agent begins a managed release download through the gateway artifact transport on `https://gateway.example.internal`
- **AND** the gateway response attempts to redirect the download to `https://downloads.example.net/agent`
- **WHEN** the agent evaluates the redirect
- **THEN** the redirect is rejected
- **AND** the agent does not continue the release download outside the gateway origin
