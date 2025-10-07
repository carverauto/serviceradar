# Hybrid Configuration Architecture: JSON + KV Store

## Overview

ServiceRadar implements a hybrid configuration system that combines the security of file-based JSON configuration with the operational flexibility of Key-Value (KV) stores. This architecture ensures sensitive data like secrets and authentication keys remain securely stored in local files, while operational configuration can be dynamically managed through distributed KV stores.

## Architecture Components

### 1. Configuration Layer Separation

The system separates configuration into two distinct layers:

- **Security Layer (JSON Files)**: Contains sensitive data that never leaves the local filesystem
- **Operational Layer (KV Stores)**: Contains non-sensitive operational settings that can be shared and updated dynamically

### 2. Sensitive Field Detection

The system uses Go struct tags to automatically identify sensitive fields:

```go
type AuthConfig struct {
    JWTSecret    string `json:"jwt_secret" sensitive:"true"`     // Never stored in DB/KV
    LocalUsers   map[string]string `json:"local_users" sensitive:"true"` // Never stored in DB/KV
    SSOProviders map[string]SSOConfig `json:"sso_providers" sensitive:"true"` // Never stored in DB/KV
    RBAC         RBACConfig `json:"rbac"`                        // Safe for KV storage
}
```

### 3. Service Configuration Tracking

Services report their KV store usage through the protobuf communication layer:

```proto
message ServiceStatus {
    string service_name = 1;
    bool available = 2;
    bytes message = 3;
    string service_type = 4;
    int64 response_time = 5;
    string agent_id = 6;
    string poller_id = 7;
    string partition = 8;
    string source = 9;
    string kv_store_id = 10; // KV store identifier this service is using
}
```

## Implementation Details

### Sensitive Field Filtering

The `FilterSensitiveFields` function recursively filters out sensitive data:

```go
func FilterSensitiveFields(input interface{}) (map[string]interface{}, error) {
    // Recursively processes structs, arrays, and maps
    // Removes any field marked with `sensitive:"true"` tag
    // Returns safe data suitable for storage or transmission
}
```

### Safe Metadata Extraction

The `ExtractSafeConfigMetadata` function creates database-safe summaries:

```go
func ExtractSafeConfigMetadata(config interface{}) map[string]string {
    // Filters sensitive fields first
    // Converts complex data to simple key-value metadata
    // Returns string map suitable for database storage
}
```

### KV Store Integration

Services communicate their KV store usage to the core:

```go
func (s *Server) extractSafeKVMetadata(svc *proto.ServiceStatus) map[string]string {
    metadata := make(map[string]string)
    metadata["service_type"] = svc.ServiceType
    
    if svc.KvStoreId != "" {
        metadata["kv_store_id"] = svc.KvStoreId
        metadata["kv_enabled"] = "true"
        metadata["kv_configured"] = "true"
    } else {
        metadata["kv_enabled"] = "false"
        metadata["kv_configured"] = "false"
    }
    
    return metadata
}
```

## Security Model

### Data Classification

1. **Highly Sensitive**: Never stored outside local JSON files
   - JWT secrets
   - Database passwords
   - API keys
   - User credentials
   - Private keys

2. **Operationally Sensitive**: Can be stored in secure KV stores
   - Service endpoints
   - Timeouts and intervals
   - Feature flags
   - Non-sensitive configuration

3. **Metadata Only**: Safe for database storage
   - Service types
   - Configuration presence indicators
   - KV store identifiers (not contents)

### Admin Interface Security

The admin UI removes sensitive configuration fields:

```tsx
// JWT Secret is handled manually for security
<div>
  <label className="block text-sm font-medium mb-2">JWT Secret</label>
  <div className="p-2 bg-gray-100 dark:bg-gray-700 rounded-md border">
    <span className="text-sm text-gray-600 dark:text-gray-400 italic">
      Configured manually in JSON file for security
    </span>
  </div>
</div>
```

## Database Storage

### Service Configuration Tracking

The `services` table stores safe metadata about service configurations:

```sql
CREATE TABLE services (
    poller_id String,
    service_name String,
    service_type String,
    agent_id String,
    device_id String,
    partition String,
    timestamp DateTime64(3),
    config Map(String, String)  -- Safe metadata only
)
```

Example config metadata:
```json
{
  "service_type": "grpc",
  "kv_store_id": "redis-cluster-1",
  "kv_enabled": "true", 
  "kv_configured": "true",
  "rbac_configured": "true"
}
```

### No Secrets in Database

The system ensures that:
- No sensitive data is ever stored in the database
- Only safe metadata and configuration summaries are persisted
- KV store identifiers are tracked, not their contents
- Sensitive fields are automatically filtered at multiple layers

## Operational Benefits

### 1. Dynamic Configuration

- Services can update operational settings without restarts
- Configuration changes can be propagated across distributed systems
- Feature flags and operational parameters can be managed centrally

### 2. Security Boundaries

- Secrets remain on local filesystems with appropriate access controls
- No risk of exposing sensitive data through database breaches
- Clear separation between configuration types

### 3. Observability

- Administrators can see which services use KV stores
- Configuration drift and compliance can be monitored
- Service dependencies on external configuration sources are visible

### 4. Flexibility

- Services can gradually migrate to KV-based configuration
- Legacy services continue working with JSON-only configuration
- Mixed deployment scenarios are supported

## Implementation Example

### Service Configuration

A typical service might have this configuration structure:

```go
type ServiceConfig struct {
    // Sensitive: stays in JSON file
    DatabaseURL string `json:"database_url" sensitive:"true"`
    APIKey      string `json:"api_key" sensitive:"true"`
    
    // Operational: can be moved to KV
    Timeout        time.Duration `json:"timeout"`
    RetryAttempts  int          `json:"retry_attempts"`
    EnableFeatureX bool         `json:"enable_feature_x"`
    
    // Metadata: tracked in database
    ServiceName string `json:"service_name"`
    Version     string `json:"version"`
}
```

### Service Startup Process

1. **Load JSON Configuration**: Read sensitive and default settings from local files
2. **Connect to KV Store**: If configured, connect to distributed KV store
3. **Merge Configuration**: Override JSON defaults with KV values for operational settings
4. **Report KV Usage**: Inform core service about KV store usage via protobuf

### Configuration Precedence

1. **Command-line arguments** (highest priority)
2. **Environment variables**
3. **KV store values** (operational settings only)
4. **JSON file values** (default and sensitive settings)
5. **Compiled defaults** (lowest priority)

## Migration Strategy

### Phase 1: Enhanced JSON (Current)
- All configuration in JSON files
- Sensitive field filtering implemented
- Database tracking of safe metadata

### Phase 2: Hybrid Implementation  
- Operational settings moved to KV stores
- Sensitive data remains in JSON
- Services report KV usage

### Phase 3: Full Integration
- Dynamic configuration updates
- Admin UI integration with KV management
- Advanced monitoring and alerting

## Testing Strategy

The system includes comprehensive tests for:

### Unit Tests
- `FilterSensitiveFields`: Ensures sensitive data is properly removed
- `ExtractSafeConfigMetadata`: Validates safe metadata generation
- `extractSafeKVMetadata`: Tests KV metadata extraction

### Integration Tests
- End-to-end configuration flow from service to database
- Service registration with KV metadata
- Cross-service configuration scenarios

### Security Tests
- Verification that no sensitive data reaches the database
- Confirmation that filtering works at all levels
- Edge cases and error conditions

## Best Practices

### For Developers

1. **Mark Sensitive Fields**: Always use `sensitive:"true"` for confidential data
2. **Test Configuration**: Verify sensitive fields don't appear in logs or databases
3. **Document KV Usage**: Clearly specify which settings can use KV stores
4. **Validate Sources**: Ensure configuration comes from expected sources

### For Operators

1. **Secure JSON Files**: Apply appropriate filesystem permissions
2. **Monitor KV Usage**: Track which services depend on KV stores
3. **Backup Strategy**: Include both JSON files and KV data in backups
4. **Access Control**: Implement proper RBAC for configuration management

### For Security Teams

1. **Regular Audits**: Review sensitive field classifications
2. **Database Monitoring**: Ensure no sensitive data appears in storage
3. **Access Logging**: Track configuration access and modifications
4. **Incident Response**: Plan for configuration compromise scenarios

## Conclusion

The hybrid configuration architecture provides a robust foundation for managing both security and operational requirements in distributed systems. By clearly separating sensitive data from operational settings, the system maintains strong security boundaries while enabling the flexibility needed for modern cloud-native applications.

This approach scales from small single-instance deployments to large distributed systems, providing a migration path that doesn't compromise security while enabling advanced operational capabilities.