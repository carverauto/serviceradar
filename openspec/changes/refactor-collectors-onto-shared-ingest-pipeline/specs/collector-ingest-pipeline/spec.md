## ADDED Requirements

### Requirement: Collectors share one receive, rules and publish implementation
Each ServiceRadar collector SHALL use the shared crates it adopts for those functions, and SHALL NOT carry its own implementation of a function a shared crate it adopts provides. The log collector SHALL adopt the receive, rules and publish crates for syslog, and the rules and publish crates for OTLP logs. The SNMP trap daemon SHALL adopt the receive and publish crates and SHALL NOT use the rules crate. The BMP collector SHALL adopt the publish crate. The flow collector SHALL adopt the receive crate.

#### Scenario: A second collector follows rules
- **WHEN** a collector other than the syslog collector needs to follow a rule bundle
- **THEN** it uses the shared rules crate
- **AND** it does not carry its own fetch, watch, verify or compile code

#### Scenario: A collector publishes batches
- **WHEN** a collector that adopts the publish crate publishes records to NATS
- **THEN** the shared publish crate closes batches by record count, bytes or age
- **AND** a retried batch is sent with the same bytes and the same message identifier

#### Scenario: A shared crate is used alone
- **WHEN** a collector needs only one of receive, rules or publish
- **THEN** it can depend on that crate without the other two

### Requirement: Collectors publish binary batches without JSON re-encoding
The log collector, the SNMP trap daemon and the BMP collector SHALL publish records in a binary format that EventWriter or their consumer stores directly, and SHALL NOT encode records as JSON for core to decode and re-encode. The flow collector keeps its existing protobuf output.

#### Scenario: Syslog and OTLP logs
- **WHEN** the log collector receives syslog or OTLP logs
- **THEN** it publishes OTLP log batches
- **AND** rules configured for OTLP logs are applied in the collector, for protobuf as well as JSON input

#### Scenario: SNMP traps
- **WHEN** the trap daemon receives a trap
- **THEN** it emits the stored field values itself, without the rules crate or any rule engine
- **AND** it publishes them as binary batches through the publish crate, as a collector without a ruleset does under `collector-rule-distribution`
- **AND** the stored record does not contain the SNMP community string

#### Scenario: BGP monitoring updates
- **WHEN** the BMP collector publishes an update
- **THEN** it publishes a binary message through the publish crate, not JSON

#### Scenario: Stored rows do not change
- **WHEN** a collector moves from JSON to a binary format
- **THEN** shared test cases show the stored row is the same for the same input, except where this change states a difference

### Requirement: Accelerated receive is shared and optional
The shared receive crate SHALL provide a portable batched-socket backend that works without extra privileges, and SHALL offer io_uring and AF_XDP backends only as explicitly enabled options to every collector that adopts it.

#### Scenario: Default deployment
- **WHEN** a collector starts with no receive backend selected
- **THEN** it uses the portable backend and needs no additional kernel features or privileges

#### Scenario: An accelerated backend is selected but unavailable
- **WHEN** an operator selects io_uring or AF_XDP on a host that cannot provide it
- **THEN** the collector reports why and does not silently run a different backend than the one reported

#### Scenario: Another collector adopts accelerated receive
- **WHEN** the flow collector or the trap daemon adopts an accelerated backend
- **THEN** it uses the same receive crate as the syslog collector

### Requirement: Each collector migration is measured
Moving a collector onto the shared pipeline SHALL be accompanied by a recorded before-and-after measurement on synthetic input.

#### Scenario: A collector is moved
- **WHEN** a collector's migration is proposed for merge
- **THEN** the change records throughput and CPU for the old and new paths on the same synthetic input
- **AND** the measurement names what was not measured

#### Scenario: The trap daemon is moved
- **WHEN** the trap daemon's move to the receive or publish crate is proposed for merge
- **THEN** the change records CPU and the number of traps lost during a synthetic trap storm, for the old and new paths
