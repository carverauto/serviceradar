# Faker Service - Armis API Emulator + BGP/BMP Simulator

The faker service emulates the Armis API for testing and reproducing pipeline issues with large datasets.
It can also simulate FRR-like BGP activity and export BMP to an Arancini collector for end-to-end ingest testing.

## Features

- Generates 25,000 fake devices with unique IPs and metadata
- Emulates Armis API endpoints (`/api/v1/access_token/` and `/api/v1/search/`)
- Each device has:
  - Unique IP address from different ranges (10.0.x.x, 10.1.x.x, 172.16.x.x, 172.17.x.x, 192.168.x.x)
  - Variable number of MAC addresses (1-50, with most having 1-10)
  - Armis device metadata (ID, name, type, OS, manufacturer, etc.)
- Supports pagination for large dataset testing
- Consistent responses for reproducible testing

## Running Locally

```bash
# Build
go build -o faker ./cmd/faker

# Run
./faker
# Server starts on :8080
```

## Running with Docker

```bash
# Build the image
docker build -f cmd/faker/Dockerfile -t serviceradar-faker .

# Run the container
docker run -p 8080:8080 serviceradar-faker
```

## Running with Docker Compose

The faker service is defined in `docker-compose.dev.yml` (dev-only stack):

```bash
# Start faker with the dev compose file
docker compose -f docker-compose.dev.yml up faker

# Or start all dev services
docker compose -f docker-compose.dev.yml up
```

## API Endpoints

### Get Access Token
```bash
curl -X POST http://localhost:8080/api/v1/access_token/
```

### Search Devices
```bash
# Get first 100 devices
curl "http://localhost:8080/api/v1/search/?aql=in:devices&length=100&from=0"

# Get next page
curl "http://localhost:8080/api/v1/search/?aql=in:devices&length=100&from=100"
```

## BGP/BMP Simulation (Arancini Path)

This mode is disabled by default and is intended for demo/test environments.

Prerequisites:
- `gobgpd` and `gobgp` must be in `PATH`.
- Arancini BMP collector must be reachable at `simulation.bgp.bmp_collector_address`.

Enable by setting `simulation.bgp.enabled=true` in `cmd/faker/config.json` (or your deployed config).

Key config fields:
- `simulation.bgp.bmp_collector_address` (example: `127.0.0.1:11019`)
- `simulation.bgp.manage_daemon` (`true`: faker starts/stops `gobgpd`, `false`: faker controls external `gobgpd`)
- `simulation.bgp.gobgp_api_address` (example: `serviceradar-gobgp:50051` for external daemon control)
- `simulation.bgp.local_asn` and `simulation.bgp.router_id`
- `simulation.bgp.peers` (FRR-like defaults are included)
- `simulation.bgp.advertised_prefixes` (defaults: `23.138.124.0/24`, `2602:f678::/48`)
- `simulation.bgp.publish_interval`, `outage_interval`, `outage_duration_min`, `outage_duration_max`

Smoke test flow:
1. Start Arancini collector with BMP listen enabled.
2. Start faker with BGP simulation enabled.
3. Confirm faker logs show route announce/withdraw events and periodic outage windows.
4. Confirm Arancini collector logs show incoming BMP session/messages from faker's GoBGP daemon.

## Using with Embedded Sync (Agent)

Configure an Armis integration source to point to the faker service:

```json
{
  "sources": {
    "faker-test": {
      "type": "armis",
      "endpoint": "http://faker:8080",
      "partition": "test",
      "credentials": {
        "username": "test",
        "password": "test"
      },
      "queries": [
        {
          "label": "all-devices",
          "query": "in:devices",
          "sweep_modes": ["icmp", "tcp"]
        }
      ],
      "page_size": 1000
    }
  }
}
```

## Testing Large Datasets

The faker service is designed to help reproduce issues with large datasets:

1. **Memory Usage**: With 25,000 devices, the service uses approximately 20-30MB of memory
2. **Pagination**: Test pagination with different page sizes (100, 500, 1000)
3. **MAC Address Arrays**: Devices have varying numbers of MAC addresses to test array handling
4. **Consistent Data**: Device data is generated deterministically at startup for consistent testing

## Debugging Pipeline Issues

To reproduce the sweep.json malformation issue:

1. Start the faker service
2. Configure the embedded sync runtime (via Integrations UI) to use faker as the Armis endpoint
3. Ensure the agent is running so it can fetch all 25,000 devices
4. Monitor KV store writes for malformed sweep.json
5. Check agent's ability to read the sweep configuration

## Performance Characteristics

- Startup: ~1 second to generate 25,000 devices
- Memory: ~30MB for 25,000 devices in memory
- Response time: < 10ms for paginated queries
- Max page size: 1000 devices per request
