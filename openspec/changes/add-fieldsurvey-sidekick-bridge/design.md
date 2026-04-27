# Design: FieldSurvey Sidekick Bridge

## Context
The existing FieldSurvey app already captures ARKit/RoomPlan geometry, maintains Wi-Fi heatmap samples, writes offline session snapshots, and encodes samples as Apache Arrow IPC to `/v1/stream/:session_id`. The backend already has `platform.survey_samples`, pgvector columns, an Ash `SurveySample` resource, and a Rust NIF decoder for the current Arrow schema.

The missing piece is high-quality RF observation. The iPhone cannot scan all visible BSSIDs at survey cadence or enter monitor mode, so the Sidekick must collect RF data and hand observations to the phone for spatial fusion.

## Goals
- Capture beacon/probe-response observations from one or more Linux monitor-mode radios.
- Stream low-latency RF observations to FieldSurvey over an IP link that can run over USB tethering, USB gadget Ethernet, or a local Pi access point.
- Let iOS remain the source of truth for pose, session identity, backend auth, Arrow encoding, offline storage, and visualization.
- Provide a local configuration API for pairing, Pi Wi-Fi uplink settings, country/channel plan, capture interfaces, and daemon status.
- Keep the first implementation testable on the existing Raspberry Pi at `192.168.1.74`.

## Non-Goals
- Do not make the Pi upload directly to ServiceRadar in the MVP.
- Do not require Kismet in the production path.
- Do not attempt arbitrary iOS USB serial or MFi ExternalAccessory integration.
- Do not replace controller/AP-side discovery; controller polling remains complementary data.

## Architecture

### Pi daemon
Create `serviceradar-fieldsurvey-sidekick`, a Rust daemon with these internal modules:

- `radio`: discovers USB Wi-Fi adapters, verifies monitor-mode support, configures monitor interfaces through `nl80211`/`iw`, and applies regulatory country settings.
- `capture`: opens Linux `AF_PACKET`/`TPACKET_V3` mmap rings for monitor
  interfaces, parses radiotap and 802.11 management frames, and emits
  normalized observations with packet-level kernel timestamps.
- `spectrum`: captures receive-only SDR sweeps from HackRF through
  `hackrf_sweep` first, with RX amp and antenna power disabled by default.
  These observations are channel-energy/interference data, not BSSID/SSID
  identity data. `hackrf_sweep` already produces FFT-derived power bins, so it
  remains the broad-survey path for 2.4/5 GHz waterfall and interference
  rasters. A focused raw-IQ mode can be evaluated later for one channel/band
  when classification requires raw samples instead of sweep bins; do not add
  that dependency to the broad-survey path prematurely.
- `hopper`: coordinates channel dwell schedules across radios. With two
  dongles, one can cover 2.4 GHz dwell while the other rotates 5/6 GHz
  channels, or both can follow configured survey plans. The golden survey mode
  is adaptive and daemon-owned: HackRF spectrum summaries prioritize noisy or
  active channels, decoded Wi-Fi observations confirm BSSID/SSID/RSSI identity,
  and the hopper weights dwell toward known AP channels while still performing
  periodic full passes to discover newly visible APs.
- `api`: serves local HTTP/WebSocket endpoints for pairing, status, configuration, and observation streaming.
- `state`: stores paired device keys and safe daemon config under `/var/lib/serviceradar/fieldsurvey-sidekick`.

The daemon should listen on loopback plus explicitly configured local interfaces by default. It should not expose unauthenticated configuration endpoints on arbitrary LAN interfaces.

### iOS app
Add a Sidekick client layer instead of expanding `RealWiFiScanner` directly:

- `SidekickClient`: discovers `_serviceradar-fieldsurvey._tcp` via Bonjour/mDNS, connects to a configured host, pairs with a token, and maintains the observation WebSocket.
- `SidekickObservation`: decodes daemon observations and normalizes units.
- `SidekickScannerAdapter`: fuses each observation with the latest ARKit pose and inserts/updates `SurveySample` plus heatmap points.
- Settings: add connection status, pairing, host override, capture controls, and Pi Wi-Fi/uplink configuration.

`RealWiFiScanner` should become an aggregator of sources: native iOS current-network/BLE/subnet polyfills plus Sidekick observations. That keeps current views and the existing Arrow streamer working.

### Link strategy
Treat "USB" as an IP transport, not a raw accessory protocol:

1. Preferred: iPhone and Pi see each other over USB networking, either iPhone Personal Hotspot USB tethering or Pi USB gadget Ethernet where hardware supports it.
2. Fallback: Pi soft AP with a captive setup page/API.
3. Discovery: mDNS service plus manual host override.
4. BLE is acceptable for discovery or rescue pairing, but not for high-rate RF data.

### Local protocol
Use HTTP/JSON for low-rate configuration and status only. The RF observation
data plane should use binary WebSocket frames containing Apache Arrow IPC record
batches. That keeps the Sidekick-to-phone format aligned with the ServiceRadar
ingestion path and avoids a JSON decode/re-encode loop for high-rate survey
data.
SDR spectrum observations should use the same binary Arrow IPC framing on a
separate WebSocket, because spectrum bins have different cardinality and
semantics from Wi-Fi management-frame observations.

The Sidekick observation Arrow schema is not identical to the final
`platform.survey_samples` schema because the Pi does not have the iPhone's
ARKit pose. The Sidekick should emit RF observation batches with stable column
names and metadata; the iPhone or backend then performs pose association. If we
want the fewest copies and the cleanest persistence model, add a backend raw RF
observation ingest path/table and store iPhone pose samples separately, then
fuse by timestamp/session in the database.

Observation fields should include:

- daemon/device identity: `sidekick_id`, `radio_id`, `interface_name`
- RF identity: `bssid`, `ssid`, `hidden_ssid`, `frame_type`
- RF measurement: `rssi_dbm`, `noise_floor_dbm`, `snr_db`, `frequency_mhz`, `channel`, `channel_width_mhz`
- timing: packet-level daemon wall-clock nanoseconds plus monotonic nanoseconds
  derived from a sampled realtime-to-monotonic clock bridge
- quality: parser confidence, dropped-frame counters, channel dwell sequence
- security/capabilities: privacy bit, parsed WPA/RSN summary when present

Spectrum fields should include:

- daemon/SDR identity: `sidekick_id`, `sdr_id`, `device_kind`, `serial_number`
- sweep identity: `sweep_id`, `started_at_unix_nanos`, `captured_at_unix_nanos`
- frequency geometry: `start_frequency_hz`, `stop_frequency_hz`, `bin_width_hz`
- measurement: `sample_count`, `power_bins_dbm`

iOS may decode a small preview/downsample for live heatmaps, but the primary RF
data stream should remain Arrow IPC bytes. The golden persistence path stores
Sidekick RF observations and iPhone pose/trajectory samples separately, then
fuses by session and timestamp in the backend/database. A short pose ring buffer
and clock offset calibration can still be used on-device for live visualization.

Do not prioritize `io_uring` for the first capture path. The low-copy Linux
primitive that matters most for monitor-mode packet capture is an mmap-backed
packet capture ring (`AF_PACKET`/`TPACKET_V3`, or libpcap using the same class
of mechanism), plus batching into Arrow arrays. `io_uring` can be evaluated
later for network/file I/O, but it does not remove the Wi-Fi driver/radiotap
copy boundary and adds operational complexity for little MVP benefit.

### Backend contract
The current Arrow/backend flow handles final spatial survey samples: BSSID,
SSID, RSSI, frequency, vectors, coordinates, and uncertainty. Those rows require
pose, so the Sidekick cannot produce them by itself.

Add a new raw RF observation Arrow ingest contract and
`platform.survey_rf_observations` table, a pose/trajectory stream keyed by
session and timestamp, and `platform.survey_spectrum_observations` for SDR
sweeps. Database-side or backend-side fusion can then produce final survey
samples/materialized views without forcing the iPhone to decode and rebuild
every RF observation. The final survey sample schema may still preserve source
metadata, but the raw RF table is the source of truth for channel, noise, radio
assignment, frame type, and packet timestamp data. The spectrum table is the
source of truth for interference/channel-energy overlays.

Backend review surfaces should derive and persist two independent rasters:

- `wifi_rssi`: AP/BSSID RSSI coverage, generated from fused Sidekick RF and
  iPhone pose rows.
- `rf_interference`: HackRF energy/noise, generated from spectrum rows fused to
  the same pose timeline.

Spectrum review must also expose a waterfall/spectrogram matrix built from the
last N sweep rows. Frequency is X, time is Y, and power is colorized. The first
version uses downsampled `power_bins_dbm` from `hackrf_sweep`; no extra FFT is
required until the focused raw-IQ path is enabled. Interference scores should
use local noise-floor baselines and session/channel medians instead of raw dBm
alone, and channel conflict scoring should correlate Wi-Fi AP channel
observations with HackRF energy on the same channels.

Schema changes must be implemented through Elixir migrations under `elixir/serviceradar_core/priv/repo/migrations/` and stay in the `platform` schema.

## Language choice
Rust is the right daemon default:

- It matches existing ServiceRadar Rust collectors and workspace tooling.
- Packet parsing and async streams benefit from Rust's safety model.
- The daemon can use libpcap and nl80211 bindings while keeping unsafe FFI contained.
- C/C++ is only justified if a required driver/library has no practical Rust binding; even then, wrap the narrow interface rather than building the daemon in C/C++.

## Milestones
1. Pi proof of life: detect radios, enter monitor mode, capture beacon frames, expose `/status` and a local observation stream.
2. iOS proof of life: pair/connect to Sidekick, display Sidekick status, convert observations into current `SurveySample` and heatmap data.
3. Survey MVP: walk with LiDAR and Sidekick active, save offline bundle, stream raw RF, pose, and spectrum batches to ServiceRadar, and verify rows in `platform.survey_rf_observations`, `platform.survey_pose_samples`, `platform.survey_spectrum_observations`, and the `platform.survey_rf_pose_matches` fusion view.
4. Fidelity pass: add materialized heatmap/query surfaces over the raw/fused tables, refine pose-time alignment, tune dual-radio hopper controls, and expand operator docs.

## Open Questions
- Which physical USB topology will be used first on the current iPhone/Pi pair: iPhone USB tethering, Pi USB gadget Ethernet, or Pi soft AP?
- What exact chipsets are attached to the Pi, and do they expose stable monitor mode plus radiotap RSSI on the current kernel?
- What clock-sync calibration do we need between iOS mach-continuous time and
  Sidekick monotonic time to support sub-sample pose interpolation during fast
  walking surveys?
