---
sidebar_position: 4
title: Proton Configuration
---

# Proton Configuration

Timeplus Proton, based on ClickHouse, is a high-performance streaming database used by ServiceRadar for time-series data storage and analytics. Its configuration is managed via `/etc/proton-server/config.yaml`. This guide provides recommended configurations for small, medium, and large deployments, optimized for different hardware profiles and workloads. These configurations focus on memory usage, cache sizes, connection limits, and query performance to ensure stability and efficiency.

:::note
Always back up `/etc/proton-server/config.yaml` before making changes.

After modifying the configuration, restart the Proton service:
```bash
sudo systemctl restart serviceradar-proton
```
:::

## Deployment Profiles

The following configurations are tailored for different deployment sizes, based on typical hardware and workload characteristics. Adjust these settings based on your specific use case, such as query complexity, streaming data volume, or concurrent users.

### Small Deployment

**Target Environment:**

- **Hardware:** 2–4 GB RAM, 1–2 CPU cores, 50–100 GB SSD
- **Workload:** Light streaming (e.g., less than 10K events/sec), simple queries, few concurrent users (1–5)
- **Use Case:** Development, testing, or small-scale monitoring

**Recommended Configuration:**
```yaml
logger:
  level: debug
  log: /var/log/proton-server/proton-server.log
  errorlog: /var/log/proton-server/proton-server.err.log
  size: 500M
  count: 5

# Memory limits
max_server_memory_usage: 1600000000  # 1.6 GB
max_server_memory_usage_to_ram_ratio: 0.8
max_memory_usage: 1200000000  # 1.2 GB per query
max_memory_usage_for_all_queries: 1600000000  # 1.6 GB total
total_memory_profiler_step: 1048576  # 1 MB
total_memory_tracker_sample_probability: 0.01

# Cache sizes
uncompressed_cache_size: 536870912  # 512 MB
mark_cache_size: 268435456  # 256 MB
mmap_cache_size: 50
compiled_expression_cache_size: 33554432  # 32 MB

# Connection and query limits
max_connections: 50
max_concurrent_queries: 5
max_concurrent_insert_queries: 5
max_concurrent_select_queries: 5
keep_alive_timeout: 1

# MergeTree settings
merge_tree:
  merge_max_block_size: 512
  max_bytes_to_merge_at_max_space_in_pool: 536870912  # 512 MB
  number_of_free_entries_in_pool_to_lower_max_size_of_merge: 2

# Spill to disk
max_bytes_before_external_group_by: 50000000  # 50 MB
max_bytes_before_external_sort: 50000000  # 50 MB

# Streaming settings
cluster_settings:
  logstore:
    kafka:
      message_max_bytes: 500000  # 500 KB
      fetch_message_max_bytes: 524288  # 512 KB
      queue_buffering_max_messages: 5000
      queue_buffering_max_kbytes: 262144  # 256 MB
```

**Key Features:**

- **Memory:** Caps total usage at 1.6 GB (~80% of 2 GB RAM), with 1.2 GB per query.
- **Caches:** Minimal cache sizes to fit within memory constraints.
- **Connections/Queries:** Low limits to reduce overhead.
- **Streaming:** Reduced buffer sizes for Kafka/Redpanda integration.
- **Logging:** Debug level for troubleshooting, with smaller log files.

**Considerations:**

- Suitable for development or small-scale monitoring with light data streams.
- May require query optimization to avoid memory spikes.
- Monitor memory usage with `free -h` and `journalctl -u serviceradar-proton -f`.

### Medium Deployment

**Target Environment:**

- **Hardware:** 8–16 GB RAM, 4–8 CPU cores, 200–500 GB SSD
- **Workload:** Moderate streaming (e.g., 10K to 100K events/sec), complex queries, moderate concurrent users (5–20)
- **Use Case:** Production monitoring for small to medium organizations

**Recommended Configuration:**
```yaml
logger:
  level: information
  log: /var/log/proton-server/proton-server.log
  errorlog: /var/log/proton-server/proton-server.err.log
  size: 1000M
  count: 10

# Memory limits
max_server_memory_usage: 12000000000  # 12 GB
max_server_memory_usage_to_ram_ratio: 0.75
max_memory_usage: 8000000000  # 8 GB per query
max_memory_usage_for_all_queries: 10000000000  # 10 GB total
total_memory_profiler_step: 4194304  # 4 MB
total_memory_tracker_sample_probability: 0.01

# Cache sizes
uncompressed_cache_size: 4294967296  # 4 GB
mark_cache_size: 2147483648  # 2 GB
mmap_cache_size: 500
compiled_expression_cache_size: 134217728  # 128 MB

# Connection and query limits
max_connections: 200
max_concurrent_queries: 20
max_concurrent_insert_queries: 15
max_concurrent_select_queries: 15
keep_alive_timeout: 2

# MergeTree settings
merge_tree:
  merge_max_block_size: 4096
  max_bytes_to_merge_at_max_space_in_pool: 4294967296  # 4 GB
  number_of_free_entries_in_pool_to_lower_max_size_of_merge: 8

# Spill to disk
max_bytes_before_external_group_by: 200000000  # 200 MB
max_bytes_before_external_sort: 200000000  # 200 MB

# Streaming settings
cluster_settings:
  logstore:
    kafka:
      message_max_bytes: 1000000  # 1 MB
      fetch_message_max_bytes: 1048576  # 1 MB
      queue_buffering_max_messages: 20000
      queue_buffering_max_kbytes: 524288  # 512 MB
```

**Key Features:**

- **Memory:** Allows up to 12 GB (~75% of 16 GB RAM), with 8 GB per query.
- **Caches:** Balanced cache sizes for performance without excessive memory use.
- **Connections/Queries:** Moderate limits for concurrent users and operations.
- **Streaming:** Larger buffers for higher-throughput Kafka/Redpanda streams.
- **Logging:** Information level for production, with standard log rotation.

**Considerations:**

- Suitable for production environments with moderate data volumes.
- Monitor query performance using `SELECT * FROM system.metrics WHERE metric LIKE '%Memory%'`.
- Adjust cache sizes based on workload (e.g., increase for heavy aggregations).

### Large Deployment

**Target Environment:**

- **Hardware:** 32–64 GB RAM, 8–16 CPU cores, 1–2 TB SSD/NVMe
- **Workload:** Heavy streaming (e.g., more than 100K events/sec), complex queries, high concurrent users (20–100)
- **Use Case:** Enterprise-scale monitoring or analytics

**Recommended Configuration:**
```yaml
logger:
  level: information
  log: /var/log/proton-server/proton-server.log
  errorlog: /var/log/proton-server/proton-server.err.log
  size: 2000M
  count: 20

# Memory limits
max_server_memory_usage: 48000000000  # 48 GB
max_server_memory_usage_to_ram_ratio: 0.75
max_memory_usage: 32000000000  # 32 GB per query
max_memory_usage_for_all_queries: 40000000000  # 40 GB total
total_memory_profiler_step: 8388608  # 8 MB
total_memory_tracker_sample_probability: 0.01

# Cache sizes
uncompressed_cache_size: 17179869184  # 16 GB
mark_cache_size: 8589934592  # 8 GB
mmap_cache_size: 1000
compiled_expression_cache_size: 268435456  # 256 MB

# Connection and query limits
max_connections: 1000
max_concurrent_queries: 50
max_concurrent_insert_queries: 30
max_concurrent_select_queries: 30
keep_alive_timeout: 3

# MergeTree settings
merge_tree:
  merge_max_block_size: 8192
  max_bytes_to_merge_at_max_space_in_pool: 17179869184  # 16 GB
  number_of_free_entries_in_pool_to_lower_max_size_of_merge: 16

# Spill to disk
max_bytes_before_external_group_by: 1000000000  # 1 GB
max_bytes_before_external_sort: 1000000000  # 1 GB

# Streaming settings
cluster_settings:
  logstore:
    kafka:
      message_max_bytes: 2000000  # 2 MB
      fetch_message_max_bytes: 2097152  # 2 MB
      queue_buffering_max_messages: 50000
      queue_buffering_max_kbytes: 1048576  # 1 GB
```

**Key Features:**

- **Memory:** Allows up to 48 GB (~75% of 64 GB RAM), with 32 GB per query.
- **Caches:** Large cache sizes for high-performance analytics.
- **Connections/Queries:** High limits for concurrent users and heavy workloads.
- **Streaming:** Large buffers for high-throughput streaming.
- **Logging:** Information level with increased log retention for enterprise use.

**Considerations:**

- Ideal for large-scale monitoring or analytics with high data volumes.
- Use Prometheus metrics (`/metrics` endpoint on port 9363) to monitor memory and query performance.
- Consider replication or sharding for high availability (see `zookeeper` and `macros` settings).

## Configuration Best Practices

### Memory Management

- Always set `max_server_memory_usage` to ~75–80% of total RAM to leave headroom for the OS and other processes.
- Use `max_memory_usage` and `max_memory_usage_for_all_queries` to prevent individual queries from consuming excessive memory.
- Enable `total_memory_tracker_sample_probability` to monitor memory usage in `system.trace_log`.

### Cache Optimization

- Adjust `uncompressed_cache_size` and `mark_cache_size` based on available RAM and query patterns. Smaller caches reduce memory usage but may slow down queries.
- Disable uncompressed cache (`use_uncompressed_cache=0` in user settings) for streaming-heavy workloads to save memory.

### Connection and Query Limits

- Set `max_connections` and `max_concurrent_queries` based on expected user load and CPU cores.
- Use `keep_alive_timeout` to balance connection persistence and resource usage.

### Streaming Optimization

- For Kafka/Redpanda integration, adjust `message_max_bytes` and `queue_buffering_max_messages` based on data throughput.
- Monitor `system.metrics` for streaming performance (`ExternalStream*` metrics).

### Logging and Monitoring

- Use debug logging for troubleshooting, but switch to information for production to reduce log overhead.
- Enable Prometheus metrics and query `system.metrics`/`system.asynchronous_metrics` for real-time monitoring.

### OOM Protection

- Set `OOMScoreAdjust=-500` in the systemd service to protect proton-server from the OOM killer:
```bash
sudo systemctl edit serviceradar-proton
```

Add:
```ini
[Service]
OOMScoreAdjust=-500
```

### Validation

- Test configuration changes in a non-production environment.
- Monitor logs (`/var/log/proton-server/proton-server.log`) and system memory (`free -h`) after applying changes.

## Next Steps

### Apply Configuration

- Update `/etc/proton-server/config.yaml` with the appropriate profile.
- Restart the service:
```bash
sudo systemctl restart serviceradar-proton
```

### Monitor Performance

- Check memory usage:
```bash
free -h
ps -eo pid,ppid,%mem,%cpu,cmd --sort=-%mem | head -n 10
```

- Query system metrics:
```sql
SELECT * FROM system.metrics WHERE metric LIKE '%Memory%';
```

### Secure Proton

- Review TLS Security to enable mTLS for Proton's network interfaces.
- Update `/etc/proton-server/users.yaml` to restrict user access and enforce strong passwords.

### Scale as Needed

- For high availability, configure replication using `zookeeper` settings.
- For large datasets, consider sharding with `macros` settings.

For more details on Proton's configuration options, refer to the Timeplus Proton documentation or the ClickHouse documentation.