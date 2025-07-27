# ServiceRadar Query Language (SRQL) - Language Reference

## Overview

ServiceRadar Query Language (SRQL) is a domain-specific query language designed for network monitoring and analysis. It provides an intuitive, SQL-like syntax for querying network entities including devices, flows, traps, connections, and various metrics.

## Entity Types

SRQL supports querying the following entity types:

### Core Network Entities
- **devices** - Network devices (routers, switches, servers, etc.)
- **flows** - Network flow records
- **traps** - SNMP trap records
- **connections** - Network connections
- **logs** - System and application logs
- **services** - Network services
- **interfaces** - Network interfaces
- **pollers** - Polling agents

### Stream Entities
- **device_updates** - Real-time device state changes
- **icmp_results** - ICMP ping test results
- **snmp_results** - SNMP polling results
- **events** - System events

### Metrics Entities
- **cpu_metrics** - CPU utilization metrics
- **disk_metrics** - Disk usage metrics
- **memory_metrics** - Memory utilization metrics
- **process_metrics** - Process-level metrics
- **snmp_metrics** - SNMP-based metrics

## Query Types

### 1. SHOW Statement
Displays all fields from specified entities with optional filtering.

**Syntax:**
```
SHOW <entity> [WHERE <condition>] [ORDER BY <field> [ASC|DESC]] [LIMIT <number>] [LATEST]
SHOW <function>(<args>) FROM <entity> [WHERE <condition>] [ORDER BY <field> [ASC|DESC]] [LIMIT <number>] [LATEST]
```

**Examples:**
```sql
SHOW devices
SHOW devices WHERE ip = '192.168.1.1'
SHOW devices WHERE os CONTAINS 'Linux' ORDER BY hostname ASC LIMIT 10
SHOW DISTINCT(service_name) FROM services WHERE port = 80
SHOW devices WHERE traps.severity = 'critical' LATEST
```

### 2. FIND Statement
Similar to SHOW but optimized for search operations.

**Syntax:**
```
FIND <entity> [WHERE <condition>] [ORDER BY <field> [ASC|DESC]] [LIMIT <number>] [LATEST]
```

**Examples:**
```sql
FIND flows WHERE bytes > 1000000
FIND devices WHERE os CONTAINS 'Windows' AND ip BETWEEN '192.168.1.1' AND '192.168.1.255'
FIND traps WHERE severity IN ('critical', 'high') ORDER BY timestamp DESC LIMIT 20
```

### 3. COUNT Statement
Returns the count of matching records.

**Syntax:**
```
COUNT <entity> [WHERE <condition>]
```

**Examples:**
```sql
COUNT devices
COUNT flows WHERE dst_port = 443
COUNT traps WHERE severity = 'critical' AND timestamp > '2024-01-01 00:00:00'
```

### 4. STREAM Statement
Advanced streaming queries with joins, windows, and aggregations.

**Syntax:**
```
STREAM [<select_list>]
FROM <data_source> [<join_clauses>]
[WHERE <condition>]
[GROUP BY <field_list>]
[HAVING <condition>]
[ORDER BY <field_list>]
[LIMIT <number>]
[EMIT <emit_clause>]
```

**Examples:**
```sql
STREAM device_id, COUNT(*) 
FROM flows 
WHERE dst_port = 80 
GROUP BY device_id 
EMIT PERIODIC 5M

STREAM * 
FROM TUMBLE(flows, event_time, 1H) 
WHERE bytes > 1000000
```

## Conditions and Operators

### Comparison Operators
- `=` or `==` - Equals
- `!=` or `<>` - Not equals
- `>` - Greater than
- `>=` - Greater than or equal
- `<` - Less than
- `<=` - Less than or equal
- `LIKE` - Pattern matching (SQL-style)

### Special Operators
- `CONTAINS` - String contains (case-insensitive)
- `IN` - Value in list
- `BETWEEN` - Value within range
- `IS NULL` / `IS NOT NULL` - Null checks

### Logical Operators
- `AND` - Logical AND
- `OR` - Logical OR
- Parentheses `()` for grouping conditions

### Value Types
- **String**: `'single quotes'` or `"double quotes"`
- **Integer**: `123`, `1000000`
- **Float**: `123.45`, `0.99`
- **Boolean**: `TRUE`, `FALSE`
- **Timestamp**: `'2024-01-01 12:00:00'`
- **IP Address**: `192.168.1.1`
- **MAC Address**: `00:11:22:33:44:55`
- **Special**: `TODAY`, `YESTERDAY`

## Field References

Fields can be referenced in several ways:

### Simple Fields
```sql
WHERE hostname = 'server01'
WHERE bytes > 1000000
```

### Dotted Fields (Entity.Field)
```sql
WHERE devices.os CONTAINS 'Linux'
WHERE flows.dst_port = 443
```

### Nested Fields (Entity.Field.Subfield)
```sql
WHERE devices.interface.speed > 1000000000
WHERE traps.severity.level = 'critical'
```

## Functions

### Aggregate Functions
- `COUNT(*)` - Count all records
- `COUNT(field)` - Count non-null values
- `DISTINCT(field)` - Get unique values

### Window Functions (for STREAM queries)
- `TUMBLE(entity, time_field, duration)` - Tumbling window
- `HOP(entity, time_field, size, advance)` - Hopping window

## Advanced Features

### Time Windows (STREAM only)
```sql
-- 1-hour tumbling windows
FROM TUMBLE(flows, event_time, 1H)

-- 5-minute hopping windows, advancing every 1 minute
FROM HOP(flows, event_time, 5M, 1M)
```

### Joins (STREAM only)
```sql
STREAM d.hostname, f.bytes
FROM devices d
JOIN flows f ON d.device_id = f.device_id
WHERE f.dst_port = 80
```

### Emit Clauses (STREAM only)
```sql
-- Emit after window closes
EMIT AFTER WINDOW CLOSE

-- Emit after window closes with delay
EMIT AFTER WINDOW CLOSE WITH DELAY 30S

-- Emit periodically
EMIT PERIODIC 1M
```

### Time Units
- `S` - Seconds
- `M` - Minutes  
- `H` - Hours
- `D` - Days

## Common Query Patterns

### Device Discovery
```sql
-- Find all Windows devices
FIND devices WHERE os CONTAINS 'Windows'

-- Get device count by OS
STREAM os, COUNT(*) FROM devices GROUP BY os

-- Find devices with critical traps
SHOW devices WHERE traps.severity = 'critical'
```

### Network Flow Analysis
```sql
-- High bandwidth flows
FIND flows WHERE bytes > 10000000 ORDER BY bytes DESC LIMIT 10

-- Web traffic analysis
COUNT flows WHERE dst_port IN (80, 443, 8080, 8443)

-- Top talkers in last hour
STREAM src_ip, SUM(bytes) 
FROM TUMBLE(flows, event_time, 1H) 
GROUP BY src_ip 
ORDER BY SUM(bytes) DESC 
LIMIT 10
```

### Security Monitoring
```sql
-- Critical alerts
FIND traps WHERE severity = 'critical' AND timestamp > TODAY

-- Failed connections
SHOW connections WHERE status = 'failed' ORDER BY timestamp DESC

-- Unusual port activity
FIND flows WHERE dst_port NOT IN (80, 443, 22, 53) AND bytes > 1000000
```

### Performance Monitoring
```sql
-- High CPU usage
FIND cpu_metrics WHERE utilization > 90 ORDER BY timestamp DESC

-- Disk space alerts
SHOW disk_metrics WHERE free_space_percent < 10

-- Memory pressure
COUNT memory_metrics WHERE available_mb < 1000
```

## Best Practices

1. **Use LATEST modifier** for real-time queries on frequently updated entities
2. **Limit result sets** with LIMIT clause for performance
3. **Use specific conditions** to reduce query scope
4. **Index commonly queried fields** in your backend database
5. **Use STREAM queries** for real-time analytics and monitoring
6. **Group related conditions** with parentheses for clarity

## Error Handling

Common syntax errors and solutions:

- **Unrecognized entity**: Ensure entity name matches supported types
- **Invalid field reference**: Check field exists for the specified entity
- **Type mismatch**: Ensure value types match field expectations
- **Missing quotes**: String values must be quoted
- **Invalid timestamp format**: Use 'YYYY-MM-DD HH:MM:SS' format