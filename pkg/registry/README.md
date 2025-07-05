# Device Registry (`pkg/registry`)

This package provides the single, authoritative service for device registration, correlation, and enrichment.

## Core Concepts

The registry is designed to solve the complex problem of device deduplication and data merging from multiple asynchronous discovery sources. It operates on a simple principle:

1.  **Single Input Type**: All discovery events from any source (`mapper`, `sweep`, `netbox`, etc.) are normalized into a `models.SweepResult`, which is treated as a "device sighting".
2.  **Centralized Processing**: All sightings are funneled through the `registry.Manager`. There is no other path for device data to enter the system.
3.  **Deterministic Correlation**: When a new sighting arrives, the registry looks for existing devices that share *any* IP address with the sighting.
4.  **Stable Canonicalization**: If multiple existing devices are found (a merge scenario), the one with the earliest `FirstSeen` timestamp is chosen as the canonical device. This is a stable, deterministic rule that prevents "device flapping".
5.  **Data Enrichment**: All data (IPs, metadata, sources) from the sighting and all related devices are merged. The incoming sighting is then "enriched" with this complete data set. Its `DeviceID` is updated to the canonical ID.
6.  **Authoritative Persistence**: The final, enriched sighting is published to the database. A materialized view in the database uses this stream of authoritative events to construct and maintain the `unified_devices` table.

This approach eliminates the need for scattered logic and periodic cleanup jobs, resulting in a more robust and maintainable system.