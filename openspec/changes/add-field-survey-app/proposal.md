# Change: Add FieldSurvey iOS App

## Why
Currently, ServiceRadar relies on logical polling (SNMP, NetFlow) to build the topology graph. However, this misses physical reality—the actual layout of the building, physical obstructions causing Wi-Fi issues, and unauthorized/rogue access points that are not on the wired network. Issue #2835 proposes an iOS companion app ("FieldSurvey") to provide "Eyes on the Ground," utilizing LiDAR and Wi-Fi scanning to generate a cyber-physical Digital Twin of the network environment.

## What Changes
- Create a new self-contained SwiftUI iOS app in the `swift` directory.
- Implement continuous Wi-Fi (SSID, BSSID, RSSI, Frequency) and BLE scanning within the app.
- Utilize iOS RoomPlan and LiDAR to generate a 3D physical model and localize RF samples to absolute coordinates.
- Architect a high-performance ingestion pipeline using Apache Arrow IPC payloads and NATS JetStream/gRPC to stream survey data to the ServiceRadar backend in real-time or via batched offline syncs.
- Enhance the God-View topology rendering engine to incorporate the physical USDZ model and project RF data using `deck.gl` (e.g., point cloud or hexagon layers).
- Integrate backend spatial processing in Rust (using Roaring Bitmaps) to correlate physical findings with the existing logical graph.

## Impact
- Affected code:
  - New `swift` directory for the iOS application.
  - `web-ng` God-View components (deck.gl rendering enhancements to overlay physical data).
  - `elixir/serviceradar_core` API ingestion and NATS JetStream pipeline integration.
  - `rust/*` NIF extensions for coordinate normalization, spatial joins, and processing Arrow IPC batches from mobile.
