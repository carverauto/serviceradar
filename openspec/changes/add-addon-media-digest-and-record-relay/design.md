# Design: media digest feed, record relay, and device access for native add-ons

## Decisions

### D1. Digests are computed in the shared relay uploader
Both native readers and Wasm streaming plugins go through the shared uploader, so it sees every
relayed access unit. Hashing happens there, inline:
1. Split the Annex B or length-prefixed payload into NAL units.
2. Keep the VCL NAL units: H.264 types 1-5, and H.265 types 0-31.
3. Hash each kept unit's bytes as received, including emulation-prevention bytes, but without
   start codes or length prefixes, in order:
   `digest = SHA-256("sr-au-v1" || codec || n || len_1 || nal_1 || ...)`.

Parameter sets, SEI, AUD and filler are excluded, because recorders may rewrite them. The cost
is a SHA-256 pass over payload slices, with no copies. Golden vectors (H.264 and H.265, Annex B
and AVCC, B-frames) live in `go/pkg/agent/testdata/media_digest/`.

### D2. Feed semantics
`StreamMediaDigests(stream MediaDigestFrame) returns (stream MediaDigestAck)`. The agent is the
client and the producer, as with `StreamMetricFeed`.
- **Frames.** Each frame carries a batch of entries: `camera_source_id`, `stream_profile_id`,
  `relay_session_id`, `pts`, `codec` and `digest`.
- **Flow control.** The agent bounds the unacked frames per add-on. On overflow it drops entries
  and sends a `gap` entry with the count per stream instead. It never blocks or slows the relay.
- **Session events.** Relay session start and stop are sent as entries too, so a consumer can
  tell a stream ending from a stream being lost.

### D3. Record relay semantics
`RelayRecords(stream RecordRelayAck) returns (stream AddonRecordFrame)`, shaped like `RelayOtlp`.
- **Durability.** The add-on owns a durable spool. The agent appends frames to its edge spool as
  `serviceradar.addon.record` v1 records, and acks cumulatively only after appending.
- **Size.** A record is at most 256 KiB.
- **Grant.** A standing grant for the `serviceradar.addon.record` package controls access.
- **Projection.** Core's projector publishes the payload bytes unmodified to
  `addons.records.<addon_id>.v1`. It adds headers for agent ID, add-on ID, add-on version and
  instance, and sets `Nats-Msg-Id`.
- **Stream.** `ADDON_RECORDS` is core-owned, with file storage, a 7-day default `max_age`, and a
  finite `max_bytes` counted in the render-time budget.

### D4. Device access
An add-on manifest field, `devices`, lists required device nodes. The agent checks each against
an allowlist: `/dev/tpmrm0` and the PC/SC socket to start. For systemd-supervised add-ons, the
agent renders `DeviceAllow=` and supplementary groups (`tss`, plus the PC/SC group). An add-on
that declares any other device is refused activation. An add-on that declares nothing gets no
devices.

### D5. Consumers
`addonRecords.consumers` in chart values maps NATS identities to the add-on IDs whose subjects
they may consume. The chart renders consumer-create grants on `ADDON_RECORDS`, filtered to those
subjects. With no entries, only core can read the stream.

## Risks / Trade-offs

- **Normalization mismatch with recorders.** Golden vectors pin the agent's behavior, and
  consumers validate the recorded media against them.
- **Device access widens the add-on surface.** This is limited to an allowlist and to explicit
  manifest declarations. Add-on artifacts are already signed, so the declarations can be audited.
