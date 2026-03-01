## Context
Issue #2835 proposes an iOS companion app to perform Wi-Fi surveys and LiDAR scans of physical environments, creating a Digital Twin that integrates with the ServiceRadar "God-View" Topology engine. The application needs to collect high-velocity RF samples, map them to absolute coordinates using iOS RoomPlan/LiDAR, and stream them to the ServiceRadar backend for spatial analysis and rendering.

### The Problem with iOS Networking Constraints
Apple tightly controls access to the internal Wi-Fi radios on iOS. Even with the highly restrictive `com.apple.developer.networking.HotspotHelper` enterprise entitlement, third-party apps are prohibited from enabling Monitor Mode (promiscuous mode) for raw 802.11 spectrum analysis, and iOS limits Wi-Fi polling to roughly once every 5 seconds. To build a true, high-fidelity Enterprise survey tool (capable of identifying rogue APs, hidden networks, and non-Wi-Fi RF interference), the iOS application must either rely on massive subnet polyfills (mDNS/SNMP/NetBIOS/BLE) to infer AP positioning, or bridge to external Linux hardware via WebSocket/BLE GATT.

### Topological Data Analysis (TDA) Constraints
Calculating true "Coverage Holes" or "Dead Zones" requires moving beyond $\mathbb{R}^3$ Euclidean path-loss models into Topological Data Analysis (TDA). Fusing continuous scalar fields (RKHS) onto a Riemannian Manifold and generating a Vietoris-Rips/Čech Complex to calculate Betti numbers ($\beta_0, \beta_1, \beta_2$) is an $O(N^3)$ computational problem. This math cannot run on the mobile device without causing immediate thermal throttling, VIO tracking failure, and battery exhaustion. TDA must run globally on the backend GPU cluster.

## Goals / Non-Goals
- **Goals:**
  - Build a standalone SwiftUI iOS app in the `swift/` directory that uses RealityKit/SceneKit for real-time 3D visualization.
  - Architect a highly efficient data pipeline mirroring the existing Topology engine (Apache Arrow, Roaring Bitmaps, `deck.gl`).
  - Support both real-time streaming of survey data and offline/batch uploads when connectivity is limited.
  - Maintain absolute position tracking with $<10cm$ variance.
  - Integrate with the God-View using WebGPU and `deck.gl` point-cloud/hexagon layers for RF visualization.
  - Mitigate iOS Wi-Fi sandbox limits using raw POSIX UDP subnet sweeping and BLE Beacon discovery.
- **Non-Goals:**
  - Replacing the core logical network discovery with physical scans (physical surveys are complementary).
  - Processing raw LiDAR point clouds on the backend; the backend will use normalized coordinate spaces and processed 3D meshes (USDZ) alongside Arrow IPC RF data.
  - Running $O(N^3)$ Algebraic Topology math on the iOS device itself.

## Architecture: The Best Possible Data Pipeline

### 1. Data Generation & In-Memory Layout (iOS App)
Consistent with the ServiceRadar high-performance standard, the app will *not* serialize JSON.
- **Data Structure:** Survey samples (Timestamp, BSSID, SSID, RSSI, Frequency, Coordinates X/Y/Z, Signal Uncertainty, Logical Hostname/IP) are immediately serialized into **Apache Arrow RecordBatches** on the device using Swift bindings for Arrow.
- **Why Arrow?** Zero-copy deserialization. Arrow's columnar memory layout allows the Rust backend to process thousands of samples in sub-milliseconds without parsing overhead, avoiding battery drain on the mobile device.

### 2. Transport Layer (Real-time vs Offline)
A Field Engineer needs flexibility to walk around with or without connectivity.
- **Real-Time Streaming (Primary):** **gRPC Bi-Directional Streaming** or **NATS JetStream (via MQTT/WebSockets)**. A gRPC stream is ideal for pumping small Arrow IPC frames directly to the Elixir/Rust ingestor at high frequency (every 1-2 seconds).
- **Batch / Offline Sync (Fallback):** If the engineer loses connectivity or prefers to save data, the Arrow frames are compressed (`lzfse` / `zstd`) on the device and saved locally. Upon completion, a bulk HTTP/2 upload pushes the `.arrow` file to the backend.

### 3. Backend Ingestion & Spatial Join (Elixir + Rust + GPU)
Once the data reaches the ServiceRadar backend:
- **Elixir Orchestration:** Elixir terminates the gRPC/WebSocket connection, unwrapping the Arrow IPC payload, and passing the binary buffer directly to a Rust NIF.
- **Topological Data Analysis (TDA):** A dedicated Rust microservice deployed to GPU-enabled k8s nodes will process the Arrow stream. It will first voxelize the raw $\mathbb{R}^3$ points in PostGIS to drastically reduce simplex count, and then use cuSPARSE (CUDA) to perform matrix reduction and calculate Betti numbers for automated dead-zone alerting.
- **Rustler Spatial Engine:** The Rust NIF performs a **Spatial Join** to match logical nodes (from the existing AGE graph) to physical coordinates.
- **Roaring Bitmaps:** The backend uses **Roaring Bitmaps** to index regions of space or classes of devices (e.g., `causal.rogue_ap`, `causal.5ghz_band`). When the UI queries a bounding box or specific RF layer, Roaring Bitmaps allow lightning-fast intersection to filter the Arrow tables.

### 4. Visualization Engine (`deck.gl` Integration)
The iOS app visualizes data natively using ARKit/SceneKit, but the "God-View" must render this data for the NOC operator.
- **Renderer:** `deck.gl` running in WebGPU mode within the `web-ng` interface.
- **Physical Context:** The USDZ floorplan (generated by iOS RoomPlan) is converted or rendered as a mesh layer (`ScenegraphLayer` or custom WebGL/WebGPU mesh).
- **RF Telemetry:** Wi-Fi strength and access point locations are streamed as Arrow buffers to the browser. `deck.gl` layers such as `PointCloudLayer` or `HexagonLayer` are utilized to visualize signal strength and node density, replicating a "flight simulator quality" cyber-physical experience.

## Hardware Roadmap: The "ServiceRadar Sidekick"
To bypass Apple's stringent Wi-Fi restrictions and build a high-fidelity $150 replacement for proprietary enterprise hardware (e.g., Ekahau Sidekick):
- A headless Linux OS (e.g., Raspberry Pi Zero 2 W) powered by an Anker USB battery pack will serve as the compute core.
- The Pi will bridge to 1-2 dual-band USB Wi-Fi adapters (MediaTek MT7612U, Alfa AWUS036ACM, Panda PAU09) explicitly designed for Linux `mac80211` Monitor Mode and Packet Injection.
- A native Rust daemon (`libpcap` or `gopacket`) running on the Pi will continuously perform aggressive channel-hopping and raw 802.11 spectrum analysis.
- The Pi will broadcast a local Wi-Fi Hotspot or BLE GATT characteristic, instantly pushing high-frequency (60fps) RF spectrum data to the `DIYHardwareScanner.swift` ingestion layer inside the iOS FieldSurvey app.
- The iOS device continues to own the ARKit/LiDAR physical spatial mapping, seamlessly fusing the raw Pi RF stream with its own 3D topology.

## Open Questions & Next Steps
- Finalize the specific `deck.gl` layers (Point Cloud vs Hexagon vs customized translucent volumetric spheres) for rendering Wi-Fi signal density in the web UI.
- Establish the exact Kubernetes GPU node affinities and CUDA base images required to run the `arrayfire`/`cuSPARSE` Rust TDA worker pod without melting the production cluster.
