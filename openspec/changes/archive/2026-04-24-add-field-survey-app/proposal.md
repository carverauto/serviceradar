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

## Current State & Progress (Update: Feb 2026)
Significant progress has been made on the standalone iOS application (`swift/FieldSurvey`):
- **Unified 3D Rendering Engine:** Built a `CompositeSurveyView` that fuses a first-person ARKit tracking camera with a God-View isometric Map camera. Both cameras seamlessly render an "Invisible RF Space" aesthetic using volumetric Gaussian decay shaders and continuous Exponential Moving Average (EMA) spatial convergence.
- **Physical Structure Modeling:** Real-time generation of room geometry (walls, doors, windows) directly from Apple's RoomPlan API, rendered with physically-based CAD lighting and smooth SLAM-drift transaction animations.
- **Data Pipeline:** Successfully implemented a zero-copy Apache Arrow IPC ingestion pipeline over persistent WebSockets, capable of flushing `SurveySample` records with `<10ms` latency directly into the backend.
- **Native Active Testing:** Built `RPerfClient`, a native Swift SPM package using `NWConnection`, to perform active throughput/bandwidth testing against the ServiceRadar backend without relying on heavy cross-compiled Rust binaries.
- **Subnet Polyfills & Stabilization:** Mitigated severe Apple iOS Wi-Fi sandbox limitations (lack of promiscuous mode/slow polling rates) by implementing multi-protocol subnet sweeping (mDNS, NetBIOS, SNMP, Ubiquiti UDP broadcasts) via raw POSIX sockets and BLE beacon ingestion to infer spatial AP locations dynamically. Included auto-recovery logic to prevent iOS daemon crashes during temporary VIO tracking failures.

## Hardware Evolution: The DIY Sidekick
While the iOS app currently utilizes the `NEHotspotHelper` enterprise entitlement, Apple strictly forbids putting internal iPhone Wi-Fi radios into Monitor Mode (promiscuous mode) for raw 802.11 spectrum analysis. This severely limits the ability to detect rogue APs, hidden networks, and non-Wi-Fi RF interference.

To build a true, enterprise-grade surveyor tool capable of replacing $3,000+ proprietary hardware (e.g., Ekahau Sidekick), the project roadmap will expand to include:
- **Compute Core:** A headless Raspberry Pi Zero 2 W (or Pi 4/5) powered by a USB battery bank.
- **Radios:** 1 or 2 external USB Wi-Fi adapters with chipsets known to support Linux Monitor Mode and Packet Injection (e.g., MediaTek MT7612U, Alfa AWUS036ACM).
- **Software Stack:** A lightweight Rust daemon (`libpcap` or `mac80211`) running on the Pi that continuously hops channels (1, 6, 11, 36, etc.) and parses raw 802.11 Beacon/Management frames.
- **iOS Bridge:** The Pi will stream the raw, high-frequency (60fps) RF spectrum data directly to the iOS FieldSurvey app over a local WebSocket or BLE GATT connection. The iOS app will continue to provide the ARKit/LiDAR spatial mapping, seamlessly fusing its physical coordinates with the Pi's raw spectrum data.

## Impact
- Affected code:
  - New `swift` directory for the iOS application.
  - `web-ng` God-View components (deck.gl rendering enhancements to overlay physical data).
  - `elixir/serviceradar_core` API ingestion and NATS JetStream pipeline integration.
  - `rust/*` NIF extensions for coordinate normalization, spatial joins, and processing Arrow IPC batches from mobile.
