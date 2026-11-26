# Change: Media digest feed, record relay, and device access for native add-ons

## Why

Native add-ons can receive local metrics (`metric-feed:v1`) and relay OTLP upstream
(`otlp-relay:v1`). They can't observe the media the agent relays, and they can't send their own
records upstream. Co-located add-ons that checksum or fingerprint relayed camera media, or that
produce compact signed records for a downstream consumer, need both. The capability must cost
the relay nothing, add no camera sessions, and never move frames. Some add-ons also need a
declared local device, such as a hardware security module or TPM, which the add-on framework
can't grant today.

## What Changes

- **`media-digest-feed:v1` (agent to add-on).**
  - The agent computes a SHA-256 digest of each relayed access unit's video-coding NAL payloads
    inline in the shared camera relay uploader, so native and Wasm sources are covered alike.
  - It streams only digests, with stream identifiers and PTS, to add-ons that advertise the
    capability. The stream uses a new `StreamMediaDigests` RPC, shaped like `StreamMetricFeed`.
  - The feed is bounded and never blocks relaying. Dropped digests are reported to the add-on as
    explicit gap markers.
  - Normalization is fixed and published with golden vectors.
- **`record-relay:v1` (add-on to agent to gateway).**
  - A new `RelayRecords` RPC, shaped like `RelayOtlp`, carries bounded opaque records from an
    add-on's durable spool into the agent edge spool, using cumulative acks.
  - A new edge-record contract, `serviceradar.addon.record` v1, is projected unmodified onto
    `addons.records.<addon_id>.v1` in a core-owned `ADDON_RECORDS` JetStream stream, with
    `Nats-Msg-Id` set to `<addon_id>:<instance>:<seq>`.
- **Declared device access.** An add-on manifest may declare local device nodes from an
  allowlist, initially `/dev/tpmrm0`, plus PC/SC access. Systemd-supervised add-ons get matching
  `DeviceAllow=` and supplementary groups. Undeclared or non-allowlisted devices are refused.
- **Record consumers.** Chart values name which NATS identities may consume which add-on record
  subjects (`addonRecords.consumers`). By default, nobody can.

## Impact

- **Affected specs:** new `native-addon-data-capabilities`.
- **Affected code:**
  - `proto/agent/addon/v1/addon.proto` (the two RPCs and their messages);
  - `go/pkg/agent`: the relay uploader digest hook, the feed pump, the record relay pump, and
    device access in the systemd and add-on manifest handling;
  - the Go and Rust add-on SDK helpers;
  - `elixir/serviceradar_core`: the edge contract catalog entry, the projector, and stream
    ownership;
  - `helm/serviceradar`: stream sizing and consumer grants.
- **Related:**
  - `add-native-addon-rust-sdk`;
  - `add-native-addon-delivery-models`;
  - `add-recording-and-audit-event-streams`;
  - the `camera-streaming` requirement that one relay uploader serves both native and Wasm
    sources.
