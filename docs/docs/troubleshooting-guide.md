---
title: Troubleshooting Guide
---

# Troubleshooting Guide

Use this guide as a first stop when onboarding ServiceRadar or operating the demo cluster. Each section lists fast diagnostics, common failure modes, and references for deeper dives.

## Edge Agents

Edge agents are Go binaries that run on monitored hosts outside the Kubernetes cluster, communicating via gRPC with mTLS.

### Connection Issues

- **Agent not connecting**: Check agent logs (`journalctl -u serviceradar-agent -f`) for connection errors. Verify the gateway address in `/etc/serviceradar/agent.json`.
- **TLS handshake failures**: Ensure certificates are valid and the CA bundle is correct:
  ```bash
  openssl verify -CAfile /etc/serviceradar/certs/bundle.pem \
    /etc/serviceradar/certs/svid.pem
  ```
- **Firewall blocking**: Confirm port 50051 is open from the agent to the gateway:
  ```bash
  nc -zv <gateway-host> 50051
  ```

### Certificate Issues

- **Certificate expired**: Check expiry dates:
  ```bash
  openssl x509 -in /etc/serviceradar/certs/svid.pem -noout -dates
  ```
- **Wrong CN format**: Verify the CN matches `<agent_id>.<partition_id>.serviceradar`:
  ```bash
  openssl x509 -in /etc/serviceradar/certs/svid.pem -noout -subject
  ```
- **CA mismatch**: Ensure the agent's CA bundle matches the cluster's SPIRE trust domain.

### Registration Issues

- **Agent not appearing in UI**: Verify the agent is registered via the API:
  ```bash
  curl -H "Authorization: Bearer $TOKEN" \
    https://core.example.com/api/v2/agents/<agent-uid>
  ```
- **Status stuck at "connecting"**: Check gateway logs for gRPC errors. The agent may be connecting but failing health checks.
- **Wrong account**: Agent certificates are deployment-specific. Verify the certificate CN matches the expected deployment.

### gRPC Diagnostics

Test gRPC connectivity directly:
```bash
grpcurl -cert /etc/serviceradar/certs/svid.pem \
        -key /etc/serviceradar/certs/svid-key.pem \
        -cacert /etc/serviceradar/certs/bundle.pem \
        <gateway-host>:50053 list
```

For detailed edge agent documentation, see [Edge Agents](./edge-agents.md).

## Core Services

- **Check pod health**: `kubectl get pods -n demo` (or the equivalent Docker Compose status). Pods stuck in `CrashLoopBackOff` usually point to missing secrets or PVC mounts.
- **Verify API availability**: `curl -k https://<core-host>/healthz`. TLS errors tie back to mismatched certificates—reissue them with the [Self-Signed Certificates guide](./self-signed.md).
- **Configuration drift**: Reconcile changes with the [Configuration Basics](./configuration.md) checklist and update the on-disk configs.

## SNMP

- **Credential failures**: Review `gateway` logs for `snmp_auth_error`. Ensure v3 auth/privacy keys match the [SNMP ingest guide](./snmp.md) recommendations.
- **Packet loss**: Confirm firewall rules allow UDP 161/162 from gateways. Use `snmpwalk -v3 ...` from the gateway pod to validate.
- **Slow polls**: Trim OID lists or increase gateway replicas. Long runtimes delay alerting.

## Syslog

- **No events**: Ensure devices forward to the correct address and protocol (`UDP/TCP 514`). Validate listener status via `kubectl logs deploy/serviceradar-syslog -n demo`.
- **Parsing issues**: Update CNPG grok rules when new vendors join; refer to the [Syslog ingest guide](./syslog.md).
- **Clock drift**: Systems with unsynchronized NTP create out-of-order events; align to UTC.

## NetFlow

### Missing Flows

**Symptoms:**
- No flows appearing in database
- SRQL `in:flows` queries return empty results
- Web UI NetFlow dashboard shows no data

**Quick Diagnostics:**

```bash
# 1. Check collector is running
docker ps | grep netflow-collector
kubectl get pods -l app=netflow-collector

# 2. Check if packets are arriving
sudo tcpdump -i any -n port 2055
# Should see: IP <router-ip>.12345 > <collector-ip>.2055: UDP, length 1480

# 3. Check collector logs
docker logs netflow-collector | grep "Received.*bytes from"
kubectl logs -l app=netflow-collector | grep "Received.*bytes from"

# 4. Check NATS stream
nats stream info events

# 5. Query database directly
psql -c "SELECT COUNT(*) FROM ocsf_network_activity WHERE time > NOW() - INTERVAL '5 minutes';"
```

**Common Causes:**

1. **Device not configured**: Router/switch/firewall must export NetFlow to collector IP and port 2055
   - Verify: Check device NetFlow configuration
   - Fix: Configure device per [NetFlow ingest guide](./netflow.md#device-configuration)

2. **Firewall blocking UDP 2055**: Network firewall or host firewall blocks UDP
   - Verify: `sudo iptables -L | grep 2055` or cloud security group rules
   - Fix: Allow UDP 2055 from exporter IPs to collector

3. **Wrong collector IP**: Device sending to old/wrong collector address
   - Verify: Check device config shows current collector IP
   - Fix: Update device NetFlow destination address

4. **Collector not listening**: Process crashed or misconfigured
   - Verify: `netstat -ulnp | grep 2055` shows listener
   - Fix: Check logs for startup errors, verify config file

5. **NATS unavailable**: Collector can't publish to NATS JetStream
   - Verify: Check collector logs for NATS connection errors
   - Fix: Verify NATS URL in config, check NATS health

### Template Errors

**Symptoms:**
- Log warnings: "Missing template - ID: 256, Protocol: V9"
- Flows from certain routers not appearing
- Intermittent flow data

**Understanding Templates:**

NetFlow v9 and IPFIX use **template-based flow encoding**:
1. Router sends **template definition** (which fields are in flows)
2. Router sends **flow data** using template ID
3. Collector must receive template before data

Templates can be:
- **Lost in transit** (UDP is unreliable)
- **Arrive after data** (out of order)
- **Cleared on router reboot** (but collector still has old version)
- **Expired** (per TTL)

**Quick Diagnostics:**

```bash
# Check for missing template warnings
docker logs netflow-collector | grep "Missing template"

# Check for template learned events
docker logs netflow-collector | grep "Template learned"

# Check template cache stats
docker logs netflow-collector | grep "Template Cache"
```

**Solutions:**

1. **Wait 60 seconds**: Routers re-send templates periodically (default: 60s)
   - Most "missing template" warnings resolve automatically
   - Check logs to see if template arrives

2. **Restart collector if persistent**: Clears corrupted template cache
   ```bash
   docker restart netflow-collector
   # or
   kubectl rollout restart deployment/netflow-collector
   ```

3. **Reboot router** (last resort): Clears router's template state
   - Only if problem persists after collector restart
   - Router will send fresh templates on startup

4. **Check template cache size**: May need larger cache for many routers
   - Verify: Check "Template Cache" logs show size near max
   - Fix: Increase `max_templates` in config (default: 2000)

### Template Collisions (Pre-0.8.0)

**Note:** This issue is **fixed in 0.8.0** with AutoScopedParser. If you see template collisions on 0.8.0+, report as a bug.

**Symptoms (legacy):**
- Flows from Router A misinterpreted when Router B sends data
- Wrong fields showing in database
- Log warnings: "Template collision - ID: 256"

**Why it happened (pre-0.8.0):**
- Router A uses template ID 256 for: [SRC_IP, DST_IP, BYTES]
- Router B uses template ID 256 for: [SRC_IP, DST_IP, PACKETS, PROTOCOL]
- Collector couldn't distinguish which router sent which template
- Router B's definition overwrites Router A's → data corruption

**Solution:**
- **Upgrade to 0.8.0+**: AutoScopedParser isolates templates per source IP
- Each router maintains independent template cache
- Template ID 256 from 192.168.1.1 ≠ template ID 256 from 192.168.1.2

### High CPU Usage

**Symptoms:**
- Collector using >80% CPU
- System load high
- Slow flow processing

**Causes:**

1. **Very high flow rate** (>50,000 flows/sec)
   - Check: Look at flow ingestion rate in logs
   - Fix: Enable sampling on routers (1:100 or 1:1000)

2. **Complex templates** (many fields)
   - Check: Look at template learned events for field counts
   - Fix: Simplify flow records on routers

3. **Insufficient batching**
   - Check: `batch_size` in config
   - Fix: Increase from 100 to 500-1000

4. **Too many concurrent parsers**
   - Fix: Ensure only one collector instance per host

**Tuning:**

```json
{
  "batch_size": 500,          // Increase from 100
  "channel_size": 50000,      // Increase from 10000
  "publish_timeout_ms": 10000 // Increase from 5000
}
```

### Dropped Flows

**Symptoms:**
- Log warnings: "Publisher channel full, dropping flow message"
- Flow counts lower than expected
- Gaps in flow data

**Causes:**

1. **NATS JetStream slow or unavailable**
   - Check: NATS JetStream health and latency
   - Fix: Scale NATS cluster, check network latency

2. **Channel too small for burst traffic**
   - Check: Warnings appear during traffic spikes
   - Fix: Increase `channel_size` to 50,000+

3. **Batch publish taking too long**
   - Check: NATS publish latency in logs
   - Fix: Reduce `batch_size` or improve NATS performance

**Solutions:**

```json
{
  "channel_size": 50000,  // Up from 10000
  "batch_size": 200,      // Balance between throughput and latency
  "drop_policy": "drop_oldest"  // Or "drop_newest" or "block"
}
```

**Drop Policies:**
- `drop_oldest`: Drop old flows when channel full (default)
- `drop_newest`: Drop new flows when channel full
- `block`: Block listener until space available (can cause UDP drops)

### Low Template Cache Hit Ratio

**Symptoms:**
- Cache stats show hit ratio < 90%
- Many cache misses in logs
- Performance degradation

**Example Log:**
```
V9 Template Cache [192.168.1.1:2055] - Templates: 1850/2000, Data: 950/2000,
  Template Hits/Misses: 5000/800
```

Hit ratio = 5000 / (5000 + 800) = 86% (unhealthy)

**Causes:**

1. **Cache too small**: Not enough room for all templates
   - Check: `current_size` near `max_size`
   - Fix: Increase `max_templates`

2. **Templates expiring too quickly**
   - Check: Many "Template expired" events
   - Fix: Increase router template refresh rate

3. **Too many unique flows**: Data cache evicting frequently
   - Check: Data cache size near max
   - Fix: Increase `max_templates` (affects both caches)

**Solutions:**

```json
{
  "max_templates": 5000  // Up from 2000
}
```

For 10+ sources:
```json
{
  "max_templates": 10000  // 1000 per source
}
```

### Memory Usage Higher Than Expected

**Symptoms:**
- Collector using more memory than before 0.8.0
- OOM (Out of Memory) errors

**Expected Memory Usage (0.8.0+):**
- **Base**: ~500MB
- **Per Source**: ~50MB per active exporter
- **10 sources**: ~1GB total
- **100 sources**: ~5.5GB total

**Comparison to 0.7.1:**
- 0.7.1: ~500MB regardless of source count (single global cache)
- 0.8.0: ~500MB + (50MB × num_sources) (per-source caches)

**This is expected** due to AutoScopedParser's per-source isolation.

**If memory exceeds expectations:**

1. **Check active source count**: May have more exporters than expected
   ```bash
   # Count unique sources in logs
   grep "Template learned" /var/log/netflow-collector.log | \
     grep -oP '\d+\.\d+\.\d+\.\d+:\d+' | sort -u | wc -l
   ```

2. **Identify rogue sources**: Unexpected devices exporting
   ```bash
   # List all sources
   grep "Template Cache" /var/log/netflow-collector.log | \
     grep -oP '\[.*?\]' | sort -u
   ```

3. **Reduce cache size if needed**: Trade-off with hit ratio
   ```json
   {
     "max_templates": 1000  // From 2000
   }
   ```

4. **Filter unwanted sources**: Firewall rules to block unauthorized exporters

### NATS Connection Failures

**Symptoms:**
- Log errors: "Failed to connect to NATS"
- Log errors: "NATS publish failed"
- Flows not reaching database

**Quick Diagnostics:**

```bash
# Check NATS is running
docker ps | grep nats
kubectl get pods -l app=nats

# Check NATS health
nats account info

# Test connection from collector host
telnet <nats-host> 4222
```

**Solutions:**

1. **NATS not running**: Start NATS
   ```bash
   docker-compose up -d nats
   kubectl scale deployment/nats --replicas=1
   ```

2. **Wrong NATS URL in config**: Verify URL
   ```json
   {
     "nats_url": "nats://nats:4222"  // Check host and port
   }
   ```

3. **mTLS certificate issues**: Check certificates
   - Verify cert files exist and are readable
   - Check cert expiration: `openssl x509 -in netflow-client.crt -noout -dates`
   - Verify CA matches

4. **Network isolation**: NATS not reachable from collector
   - Check network policies (Kubernetes)
   - Check Docker networks (Docker Compose)
   - Verify firewall rules

### Monitoring Template Cache Health

**Healthy Cache Indicators:**

```
V9 Template Cache [192.168.1.1:2055] - Templates: 15/2000, Data: 8/2000,
  Template Hits/Misses: 12500/150, Data Hits/Misses: 84200/80
```

✅ Good indicators:
- Template hit ratio: 12500/(12500+150) = 98.8% (>95%)
- Data hit ratio: 84200/(84200+80) = 99.9% (>95%)
- Size: 15/2000 = 0.75% (<50% is healthy)
- Few evictions

**Unhealthy Cache Indicators:**

```
V9 Template Cache [192.168.1.1:2055] - Templates: 1950/2000, Data: 1980/2000,
  Template Hits/Misses: 5000/2000, Data Hits/Misses: 10000/5000
```

❌ Bad indicators:
- Template hit ratio: 5000/(5000+2000) = 71.4% (<90%)
- Data hit ratio: 10000/(10000+5000) = 66.7% (<90%)
- Size: 1950/2000 = 97.5% (near max)
- Likely many evictions

**Action:** Increase `max_templates` to 5000+

### Device Configuration Validation

**Quick checklist for router/switch/firewall:**

```bash
# Cisco IOS: Verify NetFlow config
show flow exporter SERVICERADAR-COLLECTOR
show flow monitor SERVICERADAR-MONITOR
show flow interface

# Cisco NXOS: Verify NetFlow config
show flow exporter SERVICERADAR
show flow monitor SERVICERADAR-MONITOR

# Juniper: Verify IPFIX config
show services flow-monitoring
show forwarding-options sampling instance SERVICERADAR-INSTANCE
```

**Expected output:**
- Destination IP matches collector
- Port is 2055
- Interfaces are enabled
- Template refresh configured
- No error messages

See [Device Configuration](./netflow.md#device-configuration) for full examples.

### Performance Degradation

**Symptoms:**
- Flows taking longer to appear in database
- High latency from UDP receipt to database write

**Measurement:**

Enable debug logging and measure:
1. UDP receipt → parse complete
2. Parse complete → NATS publish
3. NATS publish → Zen processing
4. Zen processing → database write

**Bottleneck Identification:**

```bash
# Check NATS JetStream lag
nats stream info events

# Check Zen consumer lag
docker logs zen | grep "Processing message"

# Check db-event-writer throughput
docker logs db-event-writer | grep "Batch write"
```

**Solutions:**

- **Collector bottleneck**: Increase `batch_size`, more CPU
- **NATS bottleneck**: Scale NATS cluster, check disk I/O
- **Zen bottleneck**: Scale Zen replicas
- **Database bottleneck**: Scale CNPG, optimize indexes, partition tables

### Still Having Issues?

**Collect diagnostics:**

```bash
# Collector logs (last 1000 lines)
docker logs --tail 1000 netflow-collector > netflow-collector.log

# Collector stats
docker stats netflow-collector

# NATS stream info
nats stream info events > nats-stream-info.txt

# Database flow count
psql -c "SELECT
  DATE_TRUNC('hour', time) as hour,
  COUNT(*) as flow_count,
  COUNT(DISTINCT src_endpoint_ip) as unique_sources
FROM ocsf_network_activity
WHERE time > NOW() - INTERVAL '24 hours'
GROUP BY hour
ORDER BY hour DESC;" > flow-stats.txt

# Network capture (30 seconds)
sudo timeout 30 tcpdump -i any -n port 2055 -w netflow-capture.pcap
```

**Report issue with:**
- Collector version (check logs for startup message)
- Router/switch vendor and model
- Number of exporters
- Approximate flow rate
- Logs and diagnostics collected above

**References:**
- [NetFlow Ingest Guide](./netflow.md) - Full configuration guide
- [CHANGELOG](../../rust/netflow-collector/CHANGELOG.md) - Version-specific changes
- [TESTING.md](../../rust/netflow-collector/TESTING.md) - Testing procedures

## OTEL

- **TLS failures**: Double-check the OTLP gateway certificate bundle. Clients should trust the CA described in [Self-Signed Certificates](./self-signed.md).
- **Backpressure**: Inspect the gateway metrics; enable batching in exporters. Follow the [OTEL guide](./otel.md) for tuning tips.
- **Missing spans**: Ensure `service.name` and other attributes are populated—SRQL filters rely on them.

## Discovery

- **Empty results**: Confirm discovery jobs exist and are scoped correctly in the admin UI or API. Reconcile job ownership using the [Discovery guide](./discovery.md).
- **Mapper stalled**: Tail `serviceradar-agent` logs for mapper scheduler messages. Confirm the discovery job is enabled, scoped to the right partition/agent, and that credentials cover the target CIDRs.
- **Missing interfaces/topology**: Confirm the mapper job `discovery_type` includes interfaces/topology and that results are flowing through agent-gateway into core.
- **Duplicate devices**: Enable canonical matching in the embedded sync runtime so NetBox and Armis merges succeed.
- **Sweep failures**: Check gateway network reachability and throttling limits.

## Network Sweeps

- **No devices match**: Confirm target criteria in Settings > Networks and verify tags exist on devices.
- **Sweep never runs**: Ensure the group is enabled and has a valid schedule (interval or cron).
- **No results arriving**: Check agent logs for sweep execution, and gateway logs for streaming/forwarding errors.
- **Unexpected targets**: Review static targets and criteria operators (especially `has_any` vs `has_all`).
- **Stale availability**: Confirm agents are polling for new configs and that the gateway is reachable.

## Integrations

### Armis

- Refresh client secrets and inspect `serviceradar-agent` logs. The [Armis integration doc](./armis.md) covers faker resets and pagination tuning.
- Compare Faker vs. production counts to spot ingestion gaps.

### NetBox

- Verify API token scopes and rate limits. See the [NetBox integration guide](./netbox.md) for advanced settings.
- Check that prefixes are importing as expected; toggle `expand_subnets` if sweep jobs look incomplete.

## Dashboards and UI

- **Login problems**: Ensure local users exist (`admin` role) and JWT secrets are configured as described in [Authentication configuration](./auth-configuration.md).
- **Missing charts**: Import default dashboards from the [Web UI configuration](./web-ui.md) and double-check CNPG retention windows.
- **SRQL errors**: Reference the [SRQL language guide](./srql-language-reference.md) when writing complex joins.

## Still Stuck?

- Review the operational runbooks in [Agents & Demo Operations](./agents.md) for environment resets.
- Capture failing commands, logs, and SRQL queries before escalating to the core team.
- File follow-up work items in Beads (`bd`) so the broader team can track remediations.
