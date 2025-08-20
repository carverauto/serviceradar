# Faker Service - Armis API Emulator

The faker service emulates the Armis API for testing and reproducing pipeline issues with large datasets.

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
go build -o faker cmd/faker/main.go

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

The faker service is included in the main docker-compose.yml:

```bash
# Start just the faker service
docker-compose up faker

# Or start the entire stack
docker-compose up
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

## Using with Sync Service

Configure your sync service to point to the faker service:

```json
{
  "sources": [
    {
      "type": "armis",
      "name": "faker-test",
      "endpoint": "http://faker:8080",  // or http://localhost:8080
      "agent_id": "test-agent",
      "poller_id": "test-poller",
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
  ]
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
2. Configure sync service to use faker as Armis endpoint
3. Run sync service to fetch all 25,000 devices
4. Monitor KV store writes for malformed sweep.json
5. Check agent's ability to read the sweep configuration

## Performance Characteristics

- Startup: ~1 second to generate 25,000 devices
- Memory: ~30MB for 25,000 devices in memory
- Response time: < 10ms for paginated queries
- Max page size: 1000 devices per request