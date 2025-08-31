# Querying Service Configuration in Proton/ClickHouse

With the JSON column type for the `config` field in the `services` stream, you can now perform powerful searches and analytics on service configuration metadata.

## Schema

```sql
CREATE STREAM services (
    timestamp         DateTime64(3),
    poller_id         string,
    agent_id          string,
    service_name      string,
    service_type      string,
    config            json,        -- JSON column for flexible querying
    partition         string
)
```

## Example Configuration Data

The `config` field contains safe metadata about service configuration:

```json
{
  "service_type": "grpc",
  "kv_store_id": "redis-cluster-1",
  "kv_enabled": "true",
  "kv_configured": "true",
  "rbac_configured": "true",
  "tls_configured": "true"
}
```

## Query Examples

### 1. Find All Services Using KV Stores

```sql
SELECT 
    service_name,
    poller_id,
    json_extract_string(config, 'kv_store_id') AS kv_store_id,
    json_extract_string(config, 'kv_enabled') AS kv_enabled
FROM services
WHERE json_extract_string(config, 'kv_enabled') = 'true'
ORDER BY timestamp DESC
LIMIT 100;
```

### 2. Find Services by Specific KV Store

```sql
SELECT 
    service_name,
    service_type,
    agent_id,
    timestamp
FROM services
WHERE json_extract_string(config, 'kv_store_id') = 'redis-cluster-1'
ORDER BY timestamp DESC;
```

### 3. Count Services by Configuration Type

```sql
SELECT 
    json_extract_string(config, 'kv_enabled') AS kv_enabled,
    count() AS service_count
FROM services
WHERE timestamp > now() - INTERVAL 1 HOUR
GROUP BY kv_enabled;
```

### 4. Find Services with RBAC Configured

```sql
SELECT 
    service_name,
    poller_id,
    json_extract_string(config, 'rbac_configured') AS rbac_configured,
    json_extract_string(config, 'tls_configured') AS tls_configured
FROM services
WHERE json_extract_string(config, 'rbac_configured') = 'true'
ORDER BY timestamp DESC;
```

### 5. Services Without KV Configuration

```sql
SELECT 
    service_name,
    service_type,
    agent_id,
    timestamp
FROM services
WHERE json_extract_string(config, 'kv_enabled') = 'false'
   OR json_extract_string(config, 'kv_enabled') IS NULL
ORDER BY timestamp DESC
LIMIT 100;
```

### 6. Aggregate KV Store Usage

```sql
SELECT 
    json_extract_string(config, 'kv_store_id') AS kv_store_id,
    count(DISTINCT service_name) AS unique_services,
    count(DISTINCT poller_id) AS unique_pollers,
    count() AS total_records
FROM services
WHERE json_extract_string(config, 'kv_enabled') = 'true'
  AND timestamp > now() - INTERVAL 24 HOURS
GROUP BY kv_store_id
ORDER BY unique_services DESC;
```

### 7. Service Configuration Changes Over Time

```sql
SELECT 
    service_name,
    window_start,
    window_end,
    any(json_extract_string(config, 'kv_store_id')) AS kv_store_id,
    count() AS config_updates
FROM tumble(services, timestamp, INTERVAL 1 HOUR)
WHERE service_name = 'auth-service'
GROUP BY service_name, window_start, window_end
ORDER BY window_start DESC
LIMIT 24;
```

### 8. Complex Configuration Analysis

```sql
WITH service_configs AS (
    SELECT 
        service_name,
        service_type,
        json_extract_string(config, 'kv_enabled') AS kv_enabled,
        json_extract_string(config, 'rbac_configured') AS rbac_configured,
        json_extract_string(config, 'tls_configured') AS tls_configured,
        timestamp
    FROM services
    WHERE timestamp > now() - INTERVAL 1 HOUR
)
SELECT 
    service_type,
    sum(if(kv_enabled = 'true', 1, 0)) AS kv_enabled_count,
    sum(if(rbac_configured = 'true', 1, 0)) AS rbac_enabled_count,
    sum(if(tls_configured = 'true', 1, 0)) AS tls_enabled_count,
    count() AS total_services
FROM service_configs
GROUP BY service_type
ORDER BY total_services DESC;
```

### 9. Find Configuration Drift

```sql
-- Find services with different KV stores across pollers
SELECT 
    service_name,
    count(DISTINCT json_extract_string(config, 'kv_store_id')) AS unique_kv_stores,
    array_agg(DISTINCT json_extract_string(config, 'kv_store_id')) AS kv_stores_list
FROM services
WHERE timestamp > now() - INTERVAL 1 HOUR
  AND json_extract_string(config, 'kv_enabled') = 'true'
GROUP BY service_name
HAVING unique_kv_stores > 1;
```

### 10. Service Discovery by Configuration

```sql
-- Find all gRPC services with both RBAC and TLS enabled
SELECT DISTINCT
    service_name,
    agent_id,
    poller_id,
    json_extract_string(config, 'kv_store_id') AS kv_store_id
FROM services
WHERE service_type = 'grpc'
  AND json_extract_string(config, 'rbac_configured') = 'true'
  AND json_extract_string(config, 'tls_configured') = 'true'
  AND timestamp > now() - INTERVAL 1 HOUR;
```

## JSON Path Expressions

Proton/ClickHouse supports various JSON functions:

- `json_extract_string(json, 'path')` - Extract string value
- `json_extract_int(json, 'path')` - Extract integer value
- `json_extract_bool(json, 'path')` - Extract boolean value
- `json_extract_float(json, 'path')` - Extract float value
- `json_extract_raw(json, 'path')` - Extract raw JSON value
- `json_has(json, 'path')` - Check if path exists
- `json_length(json, 'path')` - Get array/object length
- `json_keys(json)` - Get all keys in JSON object

## Performance Considerations

1. **Indexing**: JSON fields can be indexed using materialized columns:
   ```sql
   ALTER TABLE services 
   ADD COLUMN kv_enabled string 
   MATERIALIZED json_extract_string(config, 'kv_enabled');
   ```

2. **Filtering**: Always filter by timestamp first when possible to reduce scan range

3. **Aggregations**: Use tumbling/hopping windows for time-series aggregations

4. **Materialized Views**: Create views for frequently accessed JSON paths:
   ```sql
   CREATE MATERIALIZED VIEW services_kv_usage AS
   SELECT 
       timestamp,
       service_name,
       json_extract_string(config, 'kv_store_id') AS kv_store_id,
       json_extract_string(config, 'kv_enabled') AS kv_enabled
   FROM services
   WHERE json_extract_string(config, 'kv_enabled') = 'true';
   ```

## Security Notes

Remember that the `config` field contains only safe metadata - no secrets or sensitive data are stored here. The filtering happens at multiple levels before data reaches the database:

1. Struct tags mark sensitive fields (`sensitive:"true"`)
2. `FilterSensitiveFields()` removes marked fields
3. `ExtractSafeConfigMetadata()` creates safe summaries
4. Only metadata is stored in the database

This ensures that database queries can be safely executed without risk of exposing sensitive configuration data.