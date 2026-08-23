## ADDED Requirements

### Requirement: Native Add-ons Deliver Payloads Through A Payload-Agnostic Agent Path

The agent SHALL forward a native add-on's telemetry payloads without interpreting them. Adding a new
payload type to an add-on SHALL NOT require any change to the agent, the gateway, or the add-on
transport protobuf. Payload types SHALL be identified by a `schema` **string** inside a
`DiscoveryEnvelope` carried under a single telemetry payload kind, not by a protobuf enum value per
type.

An add-on that is externally supervised (`supervision: systemd-service`) and therefore cannot be
launched by the agent SHALL still serve the generic `serviceradar.agent.addon.v1.AddonService`
contract on a socket the agent dials. Such an add-on's privileges, supervision and process lifetime
SHALL be unchanged by speaking that contract.

#### Scenario: A new payload type requires no agent change

- **GIVEN** an add-on already delivering payloads through the generic path
- **WHEN** the add-on begins emitting a payload with a new `schema` string
- **AND** the schema is registered in the control plane's discovery schema registry
- **THEN** the payload SHALL reach its consumer
- **AND** no change SHALL be required to the agent, the gateway, or the add-on transport protobuf

#### Scenario: Agent forwards an unrecognized payload without inspecting it

- **GIVEN** an add-on emits a telemetry batch whose payload the agent has no knowledge of
- **WHEN** the agent forwards it to the gateway
- **THEN** the agent SHALL forward the payload bytes unmodified
- **AND** the agent SHALL NOT decode, translate, or construct device identity from the payload

#### Scenario: Externally supervised add-on keeps its privileges

- **GIVEN** netprobe running as a root-started systemd unit that drops privileges via `--drop-user`
- **WHEN** it begins serving `AddonService` and the agent connects to it
- **THEN** netprobe SHALL continue to be started by systemd, not by the agent
- **AND** its capability set, socket ownership and process lifetime SHALL be unchanged
- **AND** it SHALL survive an agent restart

#### Scenario: Agent tolerates an add-on that is not serving the contract

- **GIVEN** an agent whose netprobe assignment is active
- **WHEN** the add-on socket is absent or the add-on is an older version that does not serve `AddonService`
- **THEN** the agent SHALL NOT fail its push cycle
- **AND** the agent SHALL continue operating on the legacy path until the add-on is upgraded

#### Scenario: Exactly one consumer during the cutover

- **GIVEN** an add-on emitting the same observations on both a legacy channel and the generic path
- **WHEN** the agent's generic client is connected
- **THEN** the agent SHALL consume the observations from exactly one channel
- **AND** the control plane SHALL NOT receive the same observation twice

### Requirement: Add-on Socket Peer Identity Is Verified

A socket over which an add-on serves `AddonService` SHALL verify the peer's identity before
accepting `Configure` or `RunCommand`, using `SO_PEERCRED` in addition to filesystem permissions.

#### Scenario: A same-uid process cannot reconfigure an add-on

- **GIVEN** an add-on serving `AddonService` on a Unix socket
- **WHEN** a process other than the agent connects and calls `Configure`
- **THEN** the call SHALL be refused

### Requirement: Add-on Health Carries Capability State

An add-on whose reported state feeds an agent capability decision SHALL expose that state through
`AddonService.Health`. Retiring a bespoke transport SHALL NOT remove capability state without an
equivalent carrier on the generic contract.

#### Scenario: Banner-grab capability still reports after the transport changes

- **GIVEN** the agent derives its banner-grab capability status from netprobe's privilege state and corpus revisions
- **WHEN** netprobe's bespoke IPC is retired
- **THEN** that state SHALL be available on `AddonService.Health`
- **AND** the reported banner-grab capability status SHALL be unchanged
