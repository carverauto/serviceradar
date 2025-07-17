# Device Registry (`pkg/registry`)

This package provides the single, authoritative service for device registration, correlation, and enrichment.

## Core Concepts

The registry is designed to solve the complex problem of device deduplication and data merging from multiple asynchronous discovery sources. It operates on a simple principle:

1.  **Single Input Type**: All discovery events from any source (`mapper`, `sweep`, `netbox`, etc.) are normalized into a `models.DeviceUpdate`, which is treated as a "device sighting".
2.  **Centralized Processing**: All sightings are funneled through the `registry.Manager`. There is no other path for device data to enter the system.
3.  **Authoritative Persistence**: The `DeviceUpdate` sightings are passed directly to the database persistence layer. The database is responsible for using this stream of authoritative events to perform correlation, merge data, and maintain the final state in the `unified_devices` table, likely via a materialized view or similar mechanism.

This approach centralizes the business logic of what constitutes a device sighting and delegates the complex stateful merging operations to the database, where it can be handled most efficiently.