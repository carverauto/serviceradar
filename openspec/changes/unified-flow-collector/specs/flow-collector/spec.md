## ADDED Requirements

### Requirement: Unified JSON configuration with listeners array
The flow-collector SHALL load a single JSON configuration file containing shared top-level settings and a `listeners` array. Each listener entry SHALL specify a `protocol` field (serde internally-tagged enum) that determines the protocol-specific options available. Shared top-level fields: `nats_url` (required), `stream_name` (required), `nats_creds_file` (optional), `stream_subjects` (optional), `stream_max_bytes` (default 10 GB), `partition` (default "default"), `channel_size` (default 10000), `batch_size` (default 100), `publish_timeout_ms` (default 5000), `drop_policy` (default drop_oldest), `security` (optional), `metrics_addr` (optional). Each listener entry SHALL contain: `protocol` (required, one of "sflow" or "netflow"), `listen_addr` (required), `subject` (required), `buffer_size` (default 65536), plus protocol-specific options.

#### Scenario: Valid config with multiple listeners
- **WHEN** the collector starts with a config containing two listeners (one sflow, one netflow)
- **THEN** the collector SHALL parse and validate the config
- **AND** the collector SHALL log all shared settings and each listener's configuration at info level

#### Scenario: Empty listeners array
- **WHEN** the config contains an empty `listeners` array
- **THEN** the collector SHALL exit with a descriptive error indicating at least one listener is required

#### Scenario: Missing required top-level field
- **WHEN** the config omits `nats_url` or `stream_name`
- **THEN** the collector SHALL exit with a descriptive error message

#### Scenario: Missing required listener field
- **WHEN** a listener entry omits `listen_addr`, `protocol`, or `subject`
- **THEN** the collector SHALL exit with a descriptive error identifying the listener index and missing field

#### Scenario: Duplicate listen addresses
- **WHEN** two listener entries specify the same `listen_addr`
- **THEN** the collector SHALL exit with a descriptive error indicating the duplicate address

#### Scenario: sFlow-specific listener options
- **WHEN** a listener has `protocol` set to "sflow"
- **THEN** the collector SHALL accept optional `max_samples_per_datagram` (u32, DoS protection)

#### Scenario: NetFlow-specific listener options
- **WHEN** a listener has `protocol` set to "netflow"
- **THEN** the collector SHALL accept optional `max_templates` (default 2000), `max_template_fields` (default 10000), and `pending_flows` (object with `max_pending_flows`, `max_entries_per_template`, `max_entry_size_bytes`, `ttl_secs`)

#### Scenario: NetFlow pending_flows validation
- **WHEN** a netflow listener specifies `pending_flows`
- **THEN** the collector SHALL validate: `max_pending_flows` in 1..=10000, `max_entries_per_template` in 1..=100000, `max_entry_size_bytes` in 1..=1048576, `ttl_secs` in 1..=3600

### Requirement: Multi-listener UDP ingestion
The flow-collector SHALL spawn one independent tokio task per configured listener entry. Each task SHALL bind a non-blocking UDP socket to its `listen_addr` and receive datagrams in a loop, delegating parsing to the protocol-specific `FlowHandler` implementation.

#### Scenario: Start multiple listeners
- **WHEN** the config defines N listener entries
- **THEN** the collector SHALL bind N UDP sockets and spawn N independent listener tasks
- **AND** the collector SHALL log the protocol type and listen address for each listener at info level

#### Scenario: Listener bind failure
- **WHEN** a listener fails to bind its UDP socket (e.g., port in use)
- **THEN** the collector SHALL exit with a descriptive error including the listen address

#### Scenario: Listener task isolation
- **WHEN** one listener task panics or encounters a fatal error
- **THEN** all other listener tasks SHALL continue operating
- **AND** the collector SHALL log the failure with the affected listener's protocol and address

### Requirement: FlowHandler protocol abstraction
The flow-collector SHALL define a `FlowHandler` trait with a `parse_datagram` method that accepts a raw UDP buffer, its length, and the peer address, and returns a `Vec<FlowMessage>`. Each supported protocol SHALL implement this trait.

#### Scenario: FlowHandler dispatch
- **WHEN** a UDP datagram arrives on a listener
- **THEN** the listener SHALL invoke the protocol-specific `FlowHandler.parse_datagram()` implementation
- **AND** the listener SHALL send each returned `FlowMessage` through the shared mpsc channel

#### Scenario: Protocol name for logging
- **WHEN** a `FlowHandler` is queried for its protocol name
- **THEN** it SHALL return a static string identifying the protocol (e.g., "sflow", "netflow")

### Requirement: sFlow v5 datagram parsing
The sFlow handler SHALL parse each received UDP datagram using the `flowparser-sflow` crate and extract flow samples for conversion into `FlowMessage` protobufs.

#### Scenario: Receive and parse sFlow datagram
- **WHEN** a valid sFlow v5 datagram arrives on the configured UDP port
- **THEN** the handler SHALL parse the datagram into an `SflowDatagram` with its contained samples
- **AND** the handler SHALL log the peer address and datagram size at debug level

#### Scenario: Malformed sFlow datagram handling
- **WHEN** an sFlow datagram fails to parse
- **THEN** the handler SHALL log a warning with the peer address and error
- **AND** the handler SHALL return an empty `Vec<FlowMessage>` (listener continues)

#### Scenario: DoS protection via sample limit
- **WHEN** the `max_samples_per_datagram` config option is set
- **THEN** the parser SHALL reject datagrams exceeding the configured sample count
- **AND** the handler SHALL log a warning for rejected datagrams

### Requirement: sFlow FlowSample to FlowMessage conversion
The sFlow handler SHALL convert each `FlowSample` into one `FlowMessage` protobuf by extracting fields from `SampledIpv4`, `SampledIpv6`, `ExtendedSwitch`, `ExtendedRouter`, and `ExtendedGateway` flow records within the sample.

#### Scenario: SampledIpv4 flow record conversion
- **WHEN** a flow sample contains a `SampledIpv4` record
- **THEN** the handler SHALL populate `FlowMessage` fields: `src_addr`, `dst_addr`, `src_port`, `dst_port`, `proto`, `tcp_flags`, `ip_tos`, and `bytes` from the record
- **AND** `FlowMessage.type` SHALL be set to `SFLOW_5`
- **AND** `FlowMessage.packets` SHALL be set to `1`
- **AND** `FlowMessage.etype` SHALL be set to `0x0800` (IPv4)

#### Scenario: SampledIpv6 flow record conversion
- **WHEN** a flow sample contains a `SampledIpv6` record
- **THEN** the handler SHALL populate `FlowMessage` fields: `src_addr`, `dst_addr`, `src_port`, `dst_port`, `proto`, `tcp_flags`, and `bytes` from the record
- **AND** `FlowMessage.etype` SHALL be set to `0x86DD` (IPv6)

#### Scenario: ExtendedSwitch enrichment
- **WHEN** a flow sample contains an `ExtendedSwitch` record
- **THEN** the handler SHALL set `FlowMessage.src_vlan` and `FlowMessage.dst_vlan` from the record

#### Scenario: ExtendedRouter enrichment
- **WHEN** a flow sample contains an `ExtendedRouter` record
- **THEN** the handler SHALL set `FlowMessage.next_hop`, `FlowMessage.src_net`, and `FlowMessage.dst_net` from the record

#### Scenario: ExtendedGateway enrichment
- **WHEN** a flow sample contains an `ExtendedGateway` record
- **THEN** the handler SHALL set `FlowMessage.src_as`, `FlowMessage.dst_as`, `FlowMessage.as_path`, `FlowMessage.bgp_communities`, and `FlowMessage.bgp_next_hop` from the record

#### Scenario: RawPacketHeader-only flow sample
- **WHEN** a flow sample contains only a `RawPacketHeader` record and no `SampledIpv4` or `SampledIpv6` record
- **THEN** the handler SHALL create a `FlowMessage` with `bytes` set from `frame_length` and `etype` from `header_protocol`
- **AND** the handler SHALL log a debug message noting the absence of typed IP records

#### Scenario: Flow sample metadata mapping
- **WHEN** a flow sample is converted
- **THEN** `FlowMessage.sampling_rate` SHALL be set from `FlowSample.sampling_rate`
- **AND** `FlowMessage.in_if` and `FlowMessage.out_if` SHALL be set from `FlowSample.input` and `FlowSample.output`
- **AND** `FlowMessage.sampler_address` SHALL be set from `SflowDatagram.agent_address`
- **AND** `FlowMessage.sequence_num` SHALL be set from `SflowDatagram.sequence_number`
- **AND** `FlowMessage.time_received_ns` SHALL be set from the system clock at packet receive time

### Requirement: sFlow counter sample handling
The sFlow handler SHALL skip `CounterSample` and `ExpandedCounter` samples without error. Counter ingestion is out of scope.

#### Scenario: Counter sample received
- **WHEN** a datagram contains counter samples
- **THEN** the handler SHALL skip them without logging an error
- **AND** the handler SHALL continue processing any flow samples in the same datagram

### Requirement: NetFlow datagram parsing
The NetFlow handler SHALL parse each received UDP datagram using the `netflow_parser` crate's `AutoScopedParser` and convert flow records into `FlowMessage` protobufs. The parser SHALL support NetFlow v5, v9, and IPFIX.

#### Scenario: Receive and parse NetFlow datagram
- **WHEN** a valid NetFlow datagram arrives on the configured UDP port
- **THEN** the handler SHALL parse the datagram using `iter_packets_from_source()` with the peer address as the scope key
- **AND** the handler SHALL convert each parsed flow record into a `FlowMessage`

#### Scenario: Malformed NetFlow datagram handling
- **WHEN** a NetFlow datagram fails to parse
- **THEN** the handler SHALL log a warning with the peer address and error
- **AND** the handler SHALL return an empty `Vec<FlowMessage>` (listener continues)

#### Scenario: Template cache configuration
- **WHEN** the listener config specifies `max_templates` and `max_template_fields`
- **THEN** the parser SHALL be initialized with those limits

#### Scenario: Template event logging
- **WHEN** a template event occurs (Learned, Collision, Evicted, Expired, MissingTemplate)
- **THEN** the handler SHALL log the event at debug level for observability

#### Scenario: Pending flows cache enabled
- **WHEN** the listener config specifies `pending_flows`
- **THEN** the parser SHALL buffer flows arriving before their template definition
- **AND** the parser SHALL replay buffered flows when the template arrives

#### Scenario: Missing template without pending flows
- **WHEN** a flow record references an unknown template and `pending_flows` is not configured
- **THEN** the handler SHALL log a warning that the flow was dropped due to a missing template

### Requirement: NetFlow FlowMessage conversion
The NetFlow handler SHALL convert parsed flow records into `FlowMessage` protobufs, supporting NetFlow v5 (fixed-format), v9 (template-based), and IPFIX (IANA-standard fields).

#### Scenario: NetFlow v5 record conversion
- **WHEN** a parsed record is NetFlow v5
- **THEN** the handler SHALL map fixed-format fields directly to `FlowMessage` fields
- **AND** `FlowMessage.type` SHALL be set to `NETFLOW_V5`

#### Scenario: NetFlow v9 record conversion
- **WHEN** a parsed record is NetFlow v9
- **THEN** the handler SHALL extract fields by template field type (IPv4/IPv6 addresses, ports, protocol, timestamps, VLANs, MACs, AS numbers)
- **AND** `FlowMessage.type` SHALL be set to `NETFLOW_V9`
- **AND** timestamps SHALL be converted from relative uptime to absolute nanoseconds

#### Scenario: IPFIX record conversion
- **WHEN** a parsed record is IPFIX
- **THEN** the handler SHALL extract fields by IANA field identifiers
- **AND** `FlowMessage.type` SHALL be set to `IPFIX`
- **AND** delta byte/packet counts SHALL take precedence over total counts when both are present

### Requirement: Degenerate flow filtering
All protocol handlers SHALL filter out degenerate `FlowMessage` records before returning them from `parse_datagram`.

#### Scenario: Degenerate flow dropped
- **WHEN** a converted `FlowMessage` has both `bytes == 0` and `packets == 0`
- **THEN** the handler SHALL drop the message
- **AND** the handler SHALL increment the flows_dropped metric counter

### Requirement: Shared NATS JetStream publishing
The flow-collector SHALL create a single `Publisher` instance that receives encoded `FlowMessage` protobuf bytes from all listeners via a shared mpsc channel and publishes to NATS JetStream. The publisher's stream SHALL be configured with subjects merged from all listener entries.

#### Scenario: Batch publishing
- **WHEN** the internal channel accumulates messages up to `batch_size`
- **THEN** the publisher SHALL publish all messages in the batch to the per-message NATS subject

#### Scenario: Partial batch on timeout
- **WHEN** the channel has messages but fewer than `batch_size` and `publish_timeout_ms` elapses
- **THEN** the publisher SHALL publish the partial batch

#### Scenario: NATS connection failure with retry
- **WHEN** the NATS connection fails
- **THEN** the publisher SHALL retry with exponential backoff (500ms initial, 30s max) up to 60 attempts
- **AND** the publisher SHALL auto-create the JetStream stream if it does not exist

#### Scenario: Stream subject merging
- **WHEN** the collector starts with multiple listeners each specifying different subjects
- **THEN** the publisher SHALL configure the NATS stream with the union of all listener subjects (plus any `stream_subjects`), deduplicated and sorted

#### Scenario: Backpressure on channel full
- **WHEN** the shared mpsc channel is full
- **THEN** the listener SHALL drop the message and increment the flows_dropped metric
- **AND** the listener SHALL log a warning and continue processing

### Requirement: mTLS security
The flow-collector SHALL support optional mTLS for NATS connections with configurable cert_dir, cert_file, key_file, and ca_file paths at the top level of the config.

#### Scenario: mTLS enabled
- **WHEN** the security config specifies `mode: "mtls"` with valid certificate paths
- **THEN** the collector SHALL establish a TLS-secured NATS connection using the provided certificates

#### Scenario: Credentials file authentication
- **WHEN** the config specifies `nats_creds_file`
- **THEN** the collector SHALL authenticate to NATS using the provided credentials file

### Requirement: Per-listener observability metrics
Each listener SHALL independently track operational metrics using atomic counters: packets_received, flows_converted, flows_dropped, parse_errors. The metrics reporter SHALL iterate all listeners and log each listener's metrics with a protocol and address label every 30 seconds.

#### Scenario: Per-listener metrics logging
- **WHEN** the 30-second metrics interval elapses
- **THEN** the reporter SHALL log each listener's counters prefixed with its protocol name and listen address

#### Scenario: Metrics endpoint
- **WHEN** `metrics_addr` is configured
- **THEN** the collector SHALL serve aggregated metrics at the specified address

### Requirement: Process lifecycle
The flow-collector SHALL orchestrate startup and shutdown of all listeners and the publisher. If the publisher task exits, the process SHALL exit. Individual listener failures SHALL be logged but SHALL NOT terminate the process.

#### Scenario: Graceful startup
- **WHEN** the collector starts
- **THEN** it SHALL initialize the NATS publisher, spawn all listener tasks, spawn the metrics reporter, and log "flow collector started successfully"

#### Scenario: Publisher failure terminates process
- **WHEN** the publisher task exits or panics
- **THEN** the collector SHALL log the error and exit the process

#### Scenario: Single listener failure
- **WHEN** one listener task exits or panics
- **THEN** the collector SHALL log the failure with protocol and address context
- **AND** all other listener tasks and the publisher SHALL continue operating
