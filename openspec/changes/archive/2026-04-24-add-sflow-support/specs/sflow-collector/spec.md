## ADDED Requirements

### Requirement: sFlow v5 UDP ingestion
The sflow-collector SHALL listen on a configurable UDP address (default `0.0.0.0:6343`) and receive sFlow v5 datagrams. The collector SHALL parse each datagram using the `flowparser-sflow` crate and extract flow samples for conversion.

#### Scenario: Receive and parse sFlow datagram
- **WHEN** a valid sFlow v5 datagram arrives on the configured UDP port
- **THEN** the collector SHALL parse the datagram into an `SflowDatagram` with its contained samples
- **AND** the collector SHALL log the peer address and datagram size at debug level

#### Scenario: Malformed datagram handling
- **WHEN** an sFlow datagram fails to parse
- **THEN** the collector SHALL log a warning with the peer address and error
- **AND** the collector SHALL continue listening for subsequent datagrams

#### Scenario: DoS protection via sample limit
- **WHEN** the `max_samples_per_datagram` config option is set
- **THEN** the parser SHALL reject datagrams exceeding the configured sample count
- **AND** the collector SHALL log a warning for rejected datagrams

### Requirement: Flow sample to FlowMessage conversion
The collector SHALL convert each sFlow `FlowSample` into one `FlowMessage` protobuf by extracting fields from `SampledIpv4`, `SampledIpv6`, `ExtendedSwitch`, `ExtendedRouter`, and `ExtendedGateway` flow records within the sample.

#### Scenario: SampledIpv4 flow record conversion
- **WHEN** a flow sample contains a `SampledIpv4` record
- **THEN** the collector SHALL populate `FlowMessage` fields: `src_addr`, `dst_addr`, `src_port`, `dst_port`, `proto`, `tcp_flags`, `ip_tos`, and `bytes` from the record
- **AND** `FlowMessage.type` SHALL be set to `SFLOW_5`
- **AND** `FlowMessage.packets` SHALL be set to `1`
- **AND** `FlowMessage.etype` SHALL be set to `0x0800` (IPv4)

#### Scenario: SampledIpv6 flow record conversion
- **WHEN** a flow sample contains a `SampledIpv6` record
- **THEN** the collector SHALL populate `FlowMessage` fields: `src_addr`, `dst_addr`, `src_port`, `dst_port`, `proto`, `tcp_flags`, and `bytes` from the record
- **AND** `FlowMessage.etype` SHALL be set to `0x86DD` (IPv6)

#### Scenario: ExtendedSwitch enrichment
- **WHEN** a flow sample contains an `ExtendedSwitch` record
- **THEN** the collector SHALL set `FlowMessage.src_vlan` and `FlowMessage.dst_vlan` from the record

#### Scenario: ExtendedRouter enrichment
- **WHEN** a flow sample contains an `ExtendedRouter` record
- **THEN** the collector SHALL set `FlowMessage.next_hop`, `FlowMessage.src_net`, and `FlowMessage.dst_net` from the record

#### Scenario: ExtendedGateway enrichment
- **WHEN** a flow sample contains an `ExtendedGateway` record
- **THEN** the collector SHALL set `FlowMessage.src_as`, `FlowMessage.dst_as`, `FlowMessage.as_path`, `FlowMessage.bgp_communities`, and `FlowMessage.bgp_next_hop` from the record

#### Scenario: RawPacketHeader-only flow sample
- **WHEN** a flow sample contains only a `RawPacketHeader` record and no `SampledIpv4` or `SampledIpv6` record
- **THEN** the collector SHALL create a `FlowMessage` with `bytes` set from `frame_length` and `etype` from `header_protocol`
- **AND** the collector SHALL log a debug message noting the absence of typed IP records

#### Scenario: Flow sample metadata mapping
- **WHEN** a flow sample is converted
- **THEN** `FlowMessage.sampling_rate` SHALL be set from `FlowSample.sampling_rate`
- **AND** `FlowMessage.in_if` and `FlowMessage.out_if` SHALL be set from `FlowSample.input` and `FlowSample.output`
- **AND** `FlowMessage.sampler_address` SHALL be set from `SflowDatagram.agent_address`
- **AND** `FlowMessage.sequence_num` SHALL be set from `SflowDatagram.sequence_number`
- **AND** `FlowMessage.time_received_ns` SHALL be set from the system clock at packet receive time

#### Scenario: Degenerate flow filtering
- **WHEN** a converted `FlowMessage` has both `bytes == 0` and `packets == 0`
- **THEN** the collector SHALL drop the message
- **AND** the collector SHALL log a warning with the dropped record count

### Requirement: Counter sample handling
The collector SHALL skip `CounterSample` and `ExpandedCounter` samples without error. Counter ingestion is out of scope.

#### Scenario: Counter sample received
- **WHEN** a datagram contains counter samples
- **THEN** the collector SHALL skip them without logging an error
- **AND** the collector SHALL continue processing any flow samples in the same datagram

### Requirement: NATS JetStream publishing
The collector SHALL publish encoded `FlowMessage` protobuf bytes to NATS JetStream with configurable subject (default `flows.raw.sflow`), batch publishing, and exponential backoff reconnection.

#### Scenario: Batch publishing
- **WHEN** the internal channel accumulates messages up to `batch_size`
- **THEN** the publisher SHALL publish all messages in the batch to the configured NATS subject

#### Scenario: NATS connection failure with retry
- **WHEN** the NATS connection fails
- **THEN** the publisher SHALL retry with exponential backoff up to 60 attempts
- **AND** the publisher SHALL auto-create the JetStream stream if it does not exist

#### Scenario: Backpressure on channel full
- **WHEN** the mpsc channel between listener and publisher is full
- **THEN** the listener SHALL drop the message and log a warning
- **AND** the listener SHALL continue processing subsequent packets

### Requirement: JSON configuration
The collector SHALL load configuration from a JSON file with serde defaults. Required fields: `listen_addr`, `nats_url`, `stream_name`, `subject`. Optional fields with defaults: `buffer_size` (65536), `channel_size` (10000), `batch_size` (100), `publish_timeout_ms` (5000), `max_samples_per_datagram` (none), `drop_policy` (drop_oldest), `security`, `metrics_addr`.

#### Scenario: Valid config loads successfully
- **WHEN** the collector starts with a valid JSON config file
- **THEN** the collector SHALL parse and validate the config
- **AND** the collector SHALL log each config value at info level

#### Scenario: Missing required field
- **WHEN** the config file omits a required field (e.g., `nats_url`)
- **THEN** the collector SHALL exit with a descriptive error message

### Requirement: mTLS security
The collector SHALL support optional mTLS for NATS connections with configurable cert_dir, cert_file, key_file, and ca_file paths.

#### Scenario: mTLS enabled
- **WHEN** the security config specifies `mode: "mtls"` with valid certificate paths
- **THEN** the collector SHALL establish a TLS-secured NATS connection using the provided certificates

### Requirement: Observability metrics
The collector SHALL expose operational metrics (packets received, flows converted, flows dropped, parse errors) at a configurable metrics address.

#### Scenario: Metrics endpoint available
- **WHEN** `metrics_addr` is configured
- **THEN** the collector SHALL serve metrics at the specified address
- **AND** metrics SHALL include packet count, flow count, drop count, and error count
