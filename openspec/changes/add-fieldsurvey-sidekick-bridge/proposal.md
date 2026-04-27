# Change: Add FieldSurvey Sidekick Bridge

## Why
iOS cannot provide monitor-mode Wi-Fi scans or high-rate RSSI/channel metadata from the built-in radio, which makes the current FieldSurvey app unsuitable for reliable Wi-Fi survey output. FieldSurvey needs an external Linux RF collector that streams raw observations to the iOS app while the iOS app continues to own LiDAR, ARKit pose tracking, visualization, offline bundles, and ServiceRadar upload.

## What Changes
- Add a Raspberry Pi "Sidekick" architecture for FieldSurvey with two USB Wi-Fi adapters in monitor mode.
- Add a Rust daemon on the Pi to configure radios, hop channels, parse 802.11 management frames, and expose a paired local control/data API to iOS.
- Keep RF scheduling daemon-owned: the Sidekick uses HackRF channel energy plus decoded per-BSSID observations to adapt channel dwell while still doing periodic full passes.
- Update the iOS FieldSurvey app plan so `RealWiFiScanner` can ingest Sidekick observations over a USB or local IP link and map them into existing `SurveySample`/Arrow upload flows.
- Extend the survey data contract to carry external-radio metadata such as source, radio ID, channel, observed timestamp, noise floor, and frame type.
- Persist backend-derived Wi-Fi RSSI and RF interference rasters, expose spectrum/waterfall review surfaces, and keep LiDAR/floorplan artifacts linked to surveys for 2D/3D review.
- Keep Kismet optional for lab verification, not as the production daemon dependency.

## Impact
- Affected specs: field-survey-sidekick
- Affected code:
  - `swift/FieldSurvey/**` for Sidekick discovery, pairing, settings, and observation ingestion.
  - `rust/fieldsurvey-sidekick/**` for the Pi daemon.
  - `Cargo.toml`, Bazel/container packaging if the daemon is built with the repo toolchain.
  - `elixir/serviceradar_core/**` and `elixir/web-ng/native/god_view_nif/**` if the Arrow/database schema is extended beyond the current sample columns.
  - `docs/docs/**` for hardware setup and operator runbooks.

## Notes
- The preferred daemon language is Rust. It fits the repository, gives memory safety for packet parsing and async networking, and can use `pcap`/`radiotap`/`nl80211` bindings without writing unsafe C/C++ control loops.
- Kismet may remain useful as a diagnostic oracle while validating adapter behavior, channel plans, and capture fidelity, but embedding or depending on Kismet would make the product path heavier than necessary.
