## ADDED Requirements

### Requirement: Media digest feed capability
The agent SHALL compute a `sr-au-v1` digest of each access unit passing through the shared camera relay uploader. This covers sources from both native readers and Wasm streaming plugins. The agent SHALL stream the digests to every add-on that advertises `media-digest-feed:v1`, using `StreamMediaDigests`. Each entry MUST carry the camera source, stream profile, relay session, PTS, codec and digest. The feed MUST NOT include media bytes.

#### Scenario: Add-on subscribed
- **WHEN** an add-on advertising `media-digest-feed:v1` is running while 50 streams are relayed
- **THEN** it receives digest entries for every access unit of all 50 streams, and no frames

#### Scenario: No subscriber
- **WHEN** no running add-on advertises the capability
- **THEN** the agent computes no digests

### Requirement: Digest normalization and published vectors
Digests SHALL cover only VCL NAL units (H.264 types 1-5, H.265 types 0-31), hashed as received without start codes or length prefixes. Parameter sets, SEI, AUD and filler data are excluded. The repository MUST publish golden vectors for H.264 and H.265, Annex B and AVCC input, and B-frame ordering.

#### Scenario: Parameter sets rewritten downstream
- **WHEN** a recorder rewrites SPS, PPS or SEI units but leaves VCL NAL units unchanged
- **THEN** digests computed from the recorded media equal the fed digests

### Requirement: Digest feed never blocks relaying
The digest feed SHALL be bounded per add-on, and MUST NOT block, slow or alter relaying. When an add-on falls behind the bound, the agent MUST drop digest entries for it and send a `gap` entry per affected stream with the dropped count. It MUST also send relay session start and stop entries.

#### Scenario: Slow add-on
- **WHEN** an add-on stops acknowledging feed frames
- **THEN** relaying continues unaffected, and when the add-on resumes it receives a `gap` entry per stream with the dropped counts

### Requirement: Record relay capability
For add-ons that advertise `record-relay:v1`, the agent SHALL pull frames through `RelayRecords` from the add-on's durable spool. It SHALL append them to the edge spool as `serviceradar.addon.record` v1 records of at most 256 KiB, and acknowledge cumulatively only after appending. Core SHALL publish each record's payload unmodified to `addons.records.<addon_id>.v1`, in the core-owned `ADDON_RECORDS` stream, with `Nats-Msg-Id` `<addon_id>:<instance>:<seq>`.

#### Scenario: Uplink outage
- **WHEN** the agent's uplink is down for 2 hours while an add-on produces records
- **THEN** the records remain in the add-on spool or the agent edge spool, and are published in order without duplicates once the uplink returns

#### Scenario: Payload passthrough
- **WHEN** a record is published
- **THEN** its payload bytes on `addons.records.<addon_id>.v1` are identical to the bytes the add-on produced

### Requirement: Declared device access for add-ons
An add-on manifest MAY declare device nodes from an allowlist, initially `/dev/tpmrm0` and PC/SC access. The agent SHALL grant only the declared, allowlisted devices to a systemd-supervised add-on, through `DeviceAllow=` and supplementary groups. It MUST refuse to activate an add-on that declares a device outside the allowlist.

#### Scenario: TPM declared
- **WHEN** an add-on declares `/dev/tpmrm0`
- **THEN** its unit can open `/dev/tpmrm0`, and no other device node

#### Scenario: Disallowed device
- **WHEN** an add-on declares `/dev/mem`
- **THEN** activation fails with a device-not-allowed error

### Requirement: Add-on record consumers are explicit
The chart SHALL let operators map NATS identities to the add-on IDs whose record subjects they may consume (`addonRecords.consumers`), and SHALL render consumer grants on `ADDON_RECORDS` limited to those subjects. Without an entry, no identity other than core MUST be able to consume the stream.

#### Scenario: Default chart
- **WHEN** the chart is rendered without `addonRecords.consumers`
- **THEN** the static user permissions test confirms that no external identity can consume `ADDON_RECORDS`
