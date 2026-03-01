# Design: FieldSurvey Backend Pipeline & Spatial Integration

## Context
Fusing logical network topology (SNMP/WLC/Flows) with physical cyber-spatial reality (LiDAR/RF RSSI/ARKit) requires a massive, high-performance IPC (Arrow/Rust) pipeline. The architecture must store, process, and serve this data efficiently using the existing CNPG (CloudNativePG) + Timescale + Apache AGE + `deck.gl` stack.

## Architecture & Data Flow

### 1. Spatial Processing (PostGIS)
Since the iOS app collects X, Y, Z coordinates via ARKit/LiDAR localization, the logical graph must extend into 3D space.
- **Requirement:** PostGIS is required to natively support 3D geometries (e.g., `geometry(PointZ, SRID)`).
- **Execution:** The Rust engine performs a "Spatial Join" to determine if a rogue AP is inside a specific room. This relies on PostGIS to execute 3D bounding box intersections (`&&&` operator) and 3D distance calculations (`ST_3DDistance`).

### 2. 3D Mesh Storage (S3 / Object Store)
Relational databases are not optimized for streaming gigabytes of raw mesh data to a frontend.
- **Requirement:** Do NOT store raw LiDAR meshes or Point Clouds in Postgres (even with `pgpointcloud`).
- **Execution:** When the iOS app finishes a RoomPlan/LiDAR scan, serialize the 3D map/point cloud and upload it directly to an S3-compatible Object Store (MinIO/AWS S3).
- **Metadata:** Store a reference to that object in Postgres via PostGIS.

```sql
-- Example Schema for DB Metadata
CREATE TABLE physical_zones (
    id UUID PRIMARY KEY,
    zone_name TEXT,
    bounding_box geometry(POLYGONZ, 3857), -- PostGIS 3D boundary
    point_cloud_url TEXT,                  -- S3 link for Deck.gl
    usdz_url TEXT                          -- S3 link for iOS AR mapping
);
```

### 3. High-Velocity Telemetry Storage (TimescaleDB)
The app generates thousands of samples `[Timestamp, BSSID, RSSI, Frequency, X, Y, Z]` per minute.
- **Requirement:** Shred the incoming Apache Arrow RecordBatch and bulk-insert it into a Timescale Hypertable.
- **Execution:** 
```sql
CREATE TABLE wifi_samples (
    time TIMESTAMPTZ NOT NULL,
    scanner_device_id UUID,
    bssid MACADDR,
    rssi INT,
    freq_band INT,
    location geometry(PointZ, 3857) -- Where the iPhone was when it heard the ping
);
SELECT create_hypertable('wifi_samples', 'time');
```

### 4. Rust Multilateration Engine (The Compute)
- **Requirement:** Triangulate the actual physical location of the Access Point.
- **Execution:** The Rust backend asynchronously queries the `wifi_samples` Hypertable, groups by `bssid`, examines varying `rssi` values from different `(X,Y,Z)` iPhone positions, and applies the Log-Distance Path Loss model.

### 5. Apache AGE (Graph Fusion)
- **Requirement:** Fuse the logical graph to the physical map.
- **Execution:** Once the Rust engine calculates the AP's physical location, it updates the Apache AGE graph.
```cypher
MATCH (ap:AccessPoint {mac: "00:1A:2B:3C:4D:5E"})
MERGE (loc:PhysicalLocation {x: $calc_x, y: $calc_y, z: $calc_z})
MERGE (ap)-[:PHYSICALLY_LOCATED_AT]->(loc)
```

### 6. Frontend Mapping (`deck.gl`)
- **PointCloudLayer:** `deck.gl` streams the point cloud data directly from Object Storage to the client's GPU, completely bypassing the database bottleneck.
- **HexagonLayer / ScatterplotLayer:** Fetches the aggregated PostGIS AP locations and signal coverage as Apache Arrow tables to render glowing spheres over the point cloud.

### 7. Future Investigation: RF Fingerprinting (`pgvector`)
GPS is useless indoors. We can track where a user is based solely on their Wi-Fi environment by treating a moment in time as an embedding vector.
- **Execution:** If an iPhone hears: `[AP1: -40dB, AP2: -65dB, AP3: -80dB]`, that is a vector `[-40, -65, -80]`.
- **KNN:** By storing these vectors using `pgvector`, the backend can use K-Nearest Neighbors (KNN) to instantly calculate a user's real-time physical location by matching their current "RF Vector" against the mapped vectors in the database.