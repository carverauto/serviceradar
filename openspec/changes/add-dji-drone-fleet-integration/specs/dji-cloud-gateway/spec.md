## ADDED Requirements

### Requirement: Native DJI Cloud API gateway
The platform SHALL provide a native, long-lived `serviceradar-dji-gateway` service that acts as the platform peer of the DJI Cloud API for docks, O4 Ground Stations and DJI Pilot 2 gateways. It SHALL publish only existing product contracts over NATS JetStream and SHALL NOT write CNPG or StarRocks directly.

#### Scenario: Gateway publishes through JetStream only
- **WHEN** a connected dock reports OSD, state, topology or HMS messages
- **THEN** the gateway SHALL publish device discovery, metric, spatial observation and OCSF event records to JetStream subjects consumed by EventWriter
- **AND** the gateway SHALL hold no database credentials

#### Scenario: Gateway is not a Wasm plugin
- **WHEN** the integration is deployed
- **THEN** the DJI peer SHALL run as a chart-managed workload that accepts device connections at any time
- **AND** no Wasm plugin run SHALL be required to keep a device connected

### Requirement: Platform answers DJI device requests
The gateway MUST answer every DJI request the platform owns within the device's timeout. These requests are `config`, `airport_bind_status`, `airport_organization_get`, `airport_organization_bind`, `storage_config_get` and `sys/product/{gw}/status`. The gateway SHALL correlate every `services` call by `tid`/`bid` with a bounded timeout.

#### Scenario: Dock license configuration
- **WHEN** a dock connects and publishes a `config` request with `config_scope: product`
- **THEN** the gateway SHALL reply on `requests_reply` with the App ID, App Key and App License from the installation's DJI app credential, and the configured NTP server
- **AND** if no DJI app credential is configured, the gateway SHALL reply with an error, record a visible configuration fault, and not invent credentials

#### Scenario: Topology acknowledgement
- **WHEN** a gateway publishes `update_topo` on `sys/product/{gw}/status`
- **THEN** the gateway SHALL reply `{result: 0}` on `status_reply`
- **AND** SHALL treat the message as the complete sub-device set for that gateway

#### Scenario: Service call timeout
- **WHEN** a `services` call receives no `services_reply` within its timeout
- **THEN** the gateway SHALL report the call as timed out to its caller
- **AND** SHALL NOT retry a call that is not idempotent

### Requirement: Single-deployment organization binding
The gateway SHALL map DJI workspaces and organizations to the single ServiceRadar deployment. It SHALL bind devices only with a valid enrollment binding code. It MUST NOT introduce per-customer organizations or routing.

#### Scenario: Organization binding with a valid code
- **WHEN** a dock sends `airport_organization_bind` with a binding code that matches an active enrollment
- **THEN** the gateway SHALL bind the dock and its aircraft to the deployment organization and reply with success per device

#### Scenario: Unknown binding code
- **WHEN** a dock sends a binding code that matches no active enrollment
- **THEN** the gateway SHALL refuse the binding and record the attempt as an event without creating devices

### Requirement: Device-facing MQTT with per-gateway authorization
The platform SHALL accept DJI gateway MQTT connections on a dedicated TLS listener. Each gateway SHALL authenticate with an enrollment or Pilot session credential. Each connection SHALL be restricted, in an isolated account that cannot address platform subjects, to topics that name exact serials: its own gateway's uplink and downlink topics, plus `osd` and `state` topics for the sub-devices bound to that gateway. Wildcard serial grants SHALL NOT be issued. A binding change SHALL re-issue the grant.

#### Scenario: Enrolled dock connects
- **WHEN** a dock connects with a valid enrollment username and password
- **THEN** the session SHALL be admitted into the isolated DJI account
- **AND** SHALL be permitted to publish its own `thing/product/<gw>/...` uplink topics, `sys/product/<gw>/status`, and `osd`/`state` topics for its bound sub-devices only
- **AND** SHALL be permitted to subscribe only to its own downlink topics

#### Scenario: Aircraft paired after the dock connected
- **WHEN** a connected dock binds a newly paired aircraft
- **THEN** the session SHALL be re-admitted with a grant that includes the aircraft's serial
- **AND** the aircraft's telemetry SHALL then be accepted

#### Scenario: Forged telemetry for another gateway
- **WHEN** an enrolled gateway publishes `osd` or `state` on a topic naming another gateway or another gateway's sub-device
- **THEN** the publish SHALL be refused by the session's grant
- **AND** no inventory or camera profile SHALL change

#### Scenario: Enrollment binds to the first gateway serial
- **WHEN** a non-multi-gateway enrollment has authenticated one gateway serial and a different serial presents the same credential
- **THEN** the second connection SHALL be refused

#### Scenario: Revoked enrollment
- **WHEN** an operator revokes an enrollment
- **THEN** new connections with it SHALL be refused
- **AND** any live session using it SHALL be disconnected

#### Scenario: MQTT listener owner follows the protocol spike
- **WHEN** the hardware spike shows that every supported gateway connects with MQTT 3.1.1
- **THEN** the NATS server's MQTT listener SHALL serve devices
- **AND** otherwise the gateway SHALL host an MQTT 5 broker with the same topic mapping and per-gateway grants

### Requirement: Inbound device credentials are minted and stored hashed
The platform SHALL mint device enrollment credentials and source-initiated stream keys, SHALL show each plaintext value exactly once, and MUST store only a salted hash. DJI app credentials and the DJI Open API key SHALL be stored as integration credentials in the unified CNPG credential model and delivered to the gateway through broker grants, never through Helm values or environment.

#### Scenario: Operator creates an enrollment
- **WHEN** an operator creates a dock enrollment in settings
- **THEN** the UI SHALL display the MQTT host, port, username, password and binding code once
- **AND** only the hash SHALL be persisted

#### Scenario: DJI app credential source
- **WHEN** the gateway needs the App License to answer a `config` request
- **THEN** it SHALL obtain it from a credential broker grant for the `dji_cloud_api` integration credential

### Requirement: S3-compatible media and log intake
The gateway SHALL provide an S3-compatible intake endpoint for DJI media, flight records and device logs. It SHALL hand devices only short-lived credentials limited to one object key prefix and to upload operations, and SHALL stream accepted objects into the installation's configured object storage.

#### Scenario: Dock requests storage credentials
- **WHEN** a dock sends `storage_config_get`
- **THEN** the gateway SHALL reply with the intake endpoint, bucket, prefix and credentials that expire within the configured lifetime
- **AND** those credentials SHALL NOT permit reading, listing or deleting objects

#### Scenario: Upload callback is cataloged
- **WHEN** a dock sends `file_upload_callback` for an uploaded object
- **THEN** the platform SHALL record the object key, flight id, model keys, shoot position, altitudes and capture time in the drone media catalog

### Requirement: Device log retrieval on operator request
The platform SHALL let an authorized operator list and pull dock and aircraft logs through `fileupload_list` and `fileupload_start`. It SHALL store retrieved logs in the intake storage and report progress from `fileupload_progress`.

#### Scenario: Operator pulls aircraft logs
- **WHEN** an operator with the drone log permission requests logs for selected boot indexes
- **THEN** the gateway SHALL issue `fileupload_start` with intake credentials
- **AND** the UI SHALL show progress and offer the stored archive for download

### Requirement: Flight records are parsed through DJI's sanctioned keychain path
The platform SHALL parse DJI flight records with a decoder that uses DJI's keychain API and the installation's Open API key. It SHALL cache keychains for offline re-parsing and MUST NOT ship a reverse-engineered decryption of DJI formats.

#### Scenario: Imported flight record
- **WHEN** an operator imports a supported flight record, or Dock 4 uploads one
- **THEN** the platform SHALL resolve the aircraft identity by serial, emit the track as spatial observations sourced from the flight record, and emit a flight summary event

#### Scenario: Unsupported record format
- **WHEN** a flight record's format is not supported by the decoder
- **THEN** the platform SHALL store the record unparsed and report it as unsupported rather than failing the import

### Requirement: DJI Pilot 2 cloud access
The platform SHALL serve a DJI Pilot 2 H5 login page. The page SHALL verify the installation's DJI license, authenticate a ServiceRadar user holding the pilot-connect permission, and issue short-lived Pilot session and MQTT credentials. The gateway SHALL serve the storage, media, topology and WebSocket endpoints that Pilot 2 requires.

#### Scenario: Pilot connects to the deployment
- **WHEN** an authorized user opens the deployment's Pilot URL in DJI Pilot 2 and signs in
- **THEN** the page SHALL load the thing, api, ws, liveshare and media modules with credentials scoped to that Pilot session
- **AND** the controller and aircraft SHALL appear in inventory once topology is reported

#### Scenario: Unauthorized pilot user
- **WHEN** a user without the pilot-connect permission signs in on the Pilot page
- **THEN** no MQTT or API credentials SHALL be issued

### Requirement: DJI integration enablement is a product runtime setting
The DJI integration SHALL be switched on and off by a CNPG-backed product runtime setting that defaults to disabled. Chart values SHALL provide only plumbing: workloads, listeners, routes and certificates. The settings page SHALL display the exact MQTT and RTMP endpoints that the installation publishes.

#### Scenario: Setting disabled
- **WHEN** the DJI setting is disabled
- **THEN** the gateway SHALL refuse device connections and the ingest SHALL refuse DJI pushes
- **AND** no Helm change SHALL be required to disable the integration

#### Scenario: Hosted tenant endpoints
- **WHEN** a hosted tenant is entitled and the chart renders the DJI listeners
- **THEN** the published runtime contract SHALL include the MQTT and RTMP host and port
- **AND** the settings page SHALL show them to operators
