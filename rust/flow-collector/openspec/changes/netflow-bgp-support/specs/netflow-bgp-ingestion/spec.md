## ADDED Requirements

### Requirement: Subscribe to raw NetFlow NATS subject
The EventWriter MUST subscribe to the `flows.raw.netflow` NATS JetStream subject to receive FlowMessage protobuf messages from the Rust NetFlow collector.

#### Scenario: NATS subscription established
- **WHEN** EventWriter starts with NETFLOW_RAW stream configuration
- **THEN** Producer creates a NATS JetStream pull consumer for `flows.raw.netflow` subject
- **THEN** Messages are routed to the `netflow_raw` batcher

#### Scenario: NATS connection failure
- **WHEN** NATS server is unavailable during EventWriter startup
- **THEN** EventWriter logs connection error and retries with exponential backoff
- **THEN** No messages are lost (JetStream retains messages until consumer reconnects)

### Requirement: Decode FlowMessage protobuf
The NetFlowMetrics processor MUST decode binary FlowMessage protobuf payloads from NATS messages into Elixir structs.

#### Scenario: Valid FlowMessage decoded
- **WHEN** NetFlowMetrics processor receives a message with valid FlowMessage protobuf data
- **THEN** Message is decoded into a `Flowpb.FlowMessage` struct
- **THEN** All fields are accessible as Elixir map keys

#### Scenario: Invalid protobuf data
- **WHEN** NetFlowMetrics processor receives a message with malformed protobuf data
- **THEN** Decoder returns an error
- **THEN** Message is logged as failed and NACK'd for potential retry
- **THEN** Processing continues with next message (no crash)

### Requirement: Extract BGP fields from FlowMessage
The NetFlowMetrics processor MUST extract BGP routing information from FlowMessage protobuf fields including AS path and BGP communities.

#### Scenario: AS path extraction
- **WHEN** FlowMessage contains `as_path` field with values `[64512, 64515]`
- **THEN** Processor extracts AS path as an Elixir list of integers
- **THEN** Values are converted from uint32 (protobuf) to int32 (PostgreSQL) by capping at 2,147,483,647

#### Scenario: BGP communities extraction
- **WHEN** FlowMessage contains `bgp_communities` field with values `[4259840100]`
- **THEN** Processor extracts BGP communities as an Elixir list of integers
- **THEN** Values are converted from uint32 to int32 by capping at 2,147,483,647

#### Scenario: Empty BGP fields
- **WHEN** FlowMessage has empty or nil `as_path` field
- **THEN** Processor sets `as_path` to `nil` in database row
- **THEN** Processing continues normally (BGP fields are optional)

### Requirement: Convert IP addresses from binary format
The NetFlowMetrics processor MUST convert binary IP addresses from FlowMessage into Postgrex.INET format for PostgreSQL storage.

#### Scenario: IPv4 address conversion
- **WHEN** FlowMessage contains 4-byte `src_addr` field (e.g., <<10, 1, 0, 100>>)
- **THEN** Processor converts to `%Postgrex.INET{address: {10, 1, 0, 100}, netmask: 32}`

#### Scenario: IPv6 address conversion
- **WHEN** FlowMessage contains 16-byte `dst_addr` field
- **THEN** Processor converts to `%Postgrex.INET{address: {a, b, c, d, e, f, g, h}, netmask: 128}` tuple

#### Scenario: Invalid IP address length
- **WHEN** FlowMessage contains IP address field with invalid byte length (not 4 or 16)
- **THEN** Processor logs a debug warning
- **THEN** IP address field is set to `nil` in database row
- **THEN** Processing continues with other fields

### Requirement: Extract timestamp from FlowMessage
The NetFlowMetrics processor MUST determine the flow timestamp from FlowMessage fields, preferring flow start time over received time.

#### Scenario: Use flow start time
- **WHEN** FlowMessage has `time_flow_start_ns` > 0
- **THEN** Processor converts nanoseconds to DateTime and uses as timestamp

#### Scenario: Fallback to received time
- **WHEN** FlowMessage has `time_flow_start_ns` = 0 and `time_received_ns` > 0
- **THEN** Processor uses `time_received_ns` as timestamp

#### Scenario: Fallback to current time
- **WHEN** FlowMessage has both timestamp fields = 0
- **THEN** Processor uses `DateTime.utc_now()` as timestamp

### Requirement: Build metadata JSON from unmapped fields
The NetFlowMetrics processor MUST collect unmapped FlowMessage fields into a `metadata` JSONB column for future extensibility.

#### Scenario: Include interface information
- **WHEN** FlowMessage has `in_if` = 10 and `out_if` = 20
- **THEN** Processor includes `{"in_if": 10, "out_if": 20}` in metadata JSON

#### Scenario: Include sampling rate
- **WHEN** FlowMessage has `sampling_rate` = 100
- **THEN** Processor includes `{"sampling_rate": 100}` in metadata JSON

#### Scenario: Empty metadata
- **WHEN** FlowMessage has no unmapped fields with values > 0
- **THEN** Processor sets `metadata` to `nil` (not empty JSON object)

### Requirement: Route messages to netflow_raw batcher
The EventWriter Pipeline MUST route messages with subject `flows.raw.netflow` to the `netflow_raw` batcher for batch processing.

#### Scenario: Subject-based routing
- **WHEN** Pipeline receives message with subject `flows.raw.netflow`
- **THEN** Message is routed to `:netflow_raw` batcher
- **THEN** Batcher collects messages until batch_size (50) or batch_timeout (500ms)

#### Scenario: Batcher calls NetFlowMetrics processor
- **WHEN** `netflow_raw` batcher reaches batch size or timeout
- **THEN** Pipeline calls `NetFlowMetrics.process_batch/1` with batch of messages
- **THEN** Processor returns `{:ok, count}` on success
