# ADR: ServiceRadar KV Integration with NATS JetStream

## Status

Proposed

## Context

ServiceRadar currently relies on static JSON configuration files for target management, which presents limitations when scaling to handle large device inventories. As the number of devices that need to be monitored increases, several challenges emerge:

- Performance bottlenecks when parsing large JSON files
- Difficulties in maintaining synchronized states across components
- Limited ability to dynamically update targets without service restarts
- No clear path for integrating with large external device inventories

We need a solution that enables dynamic, scalable target management while maintaining ServiceRadar's existing architecture patterns and data flow, while minimizing changes to existing components.

## Decision

We will implement a key-value (KV) store using NATS JetStream as the backend, wrapped in a dedicated service called `serviceradar-kv`. Rather than directly modifying the SweepService to fetch from this KV store, we will leverage and extend the existing `pkg/config` package to support both file-based and KV-based configuration sources.

The solution will consist of:

1. A `serviceradar-kv` service providing a gRPC interface on port 50054 for KV operations
2. NATS JetStream as an embedded KV store for simplicity and performance
3. Extending `pkg/config` with a `ConfigLoader` interface that supports multiple sources
4. Implementing both file-based and KV-based loaders that implement this interface
5. Configuring the agent to use the appropriate loader, with automatic fallback to file-based configuration when the KV is unavailable

Additionally, we will create synchronization services that will:
1. Poll external APIs at configurable intervals
2. Update the KV store with device information
3. Push status updates back to external systems via the ServiceRadar core API

## Consequences

### Positive

- Enables dynamic updating of target configurations without service restarts
- Scales to support large device inventories
- Maintains the existing one-way data flow: agent → poller → core
- Provides a path for integration with external systems via the KV abstraction
- Uses consistent technology (gRPC) for all service communications
- Embedded NATS JetStream simplifies deployment with no external dependencies
- **Minimizes changes to existing components by extending `pkg/config` rather than modifying SweepService directly**
- **Provides a clean abstraction that maintains backward compatibility**
- **Allows for transparent switching between configuration sources**

### Negative

- Introduces new services that must be deployed and maintained
- Adds complexity to the overall architecture
- No synchronization between KV and JSON fallback configurations
- External API polling must handle pagination properly for large device sets

### Neutral

- The KVStore interface allows for future replacement of NATS JetStream with alternatives (MQTT, Kafka, etcd, Redis)
- Configuration will be split across multiple files
- The `ConfigLoader` interface provides flexibility for adding other configuration sources in the future

## Implementation Details

### KV Daemon (serviceradar-kv)

- **Interface**: Create a generic KVStore interface in `pkg/kv/interfaces.go`
- **Backend**: Implement NATS JetStream backend in `pkg/kv/nats.go`
- **API**: Define and implement gRPC service in `proto/kv.proto` and `pkg/kv/server.go`
- **Configuration**: Load from `/etc/serviceradar/kv.json`
- **Systemd**: Provide `serviceradar-kv.service` file

### Config Package Extensions

- **Interface**: Add a `ConfigLoader` interface to `pkg/config/loader.go`
- **File Loader**: Implement `FileConfigLoader` that wraps existing functionality
- **KV Loader**: Implement `KVConfigLoader` that fetches from KV store via gRPC
- **Factory**: Create a factory function that returns the appropriate loader based on configuration
- **Fallback**: Implement automatic fallback to file-based configuration when KV is unavailable

### Integration Sync Services

- **Sync Logic**: Implement in dedicated service packages
- **External API Integration**: Create in appropriate integration packages
- **Configuration**: Load from configuration files in `/etc/serviceradar/`
- **Systemd**: Provide service files for each sync service

### Agent Updates

- Modify agent initialization to use the new `ConfigLoader` factory
- Configuration remains loaded via `config.LoadAndValidate` with no changes to SweepService logic
- Add configuration options to specify whether to use KV or file-based configuration sources

## Testing Approach

- Unit tests for KVStore interface and NATS implementation
- Unit tests for both ConfigLoader implementations
- Integration tests for the full flow with simulated load
- Validation of fallback mechanism when KV is unavailable

## Security Considerations

- External API credentials must be securely stored
- Consider adding authentication to the KV gRPC service
- Evaluate data sensitivity and apply appropriate access controls

## Documentation Requirements

- Update `docs/docs/configuration.md` with new service configurations and loader options
- Revise `docs/docs/architecture.md` to include new components
- Update `docs/docs/installation.md` with installation instructions
- Add developer documentation for the `ConfigLoader` interface and how to implement new loaders