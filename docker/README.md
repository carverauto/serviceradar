# ServiceRadar Docker Deployment

This directory contains Docker configurations for ServiceRadar components.

## Quick Start

### Option 1: Quick Start (Pre-built Images) - RECOMMENDED

1. **Copy environment configuration (optional):**
   ```bash
   cp .env.example .env
   # Edit .env as needed (all values have sensible defaults)
   ```

2. **Start with pre-built images:**
   ```bash
   docker-compose up
   ```
   This automatically:
   - Pulls pre-built images from GitHub Container Registry (GHCR)
   - Generates mTLS certificates
   - Starts Proton and Core services
   - Sets up networking and volumes

### Option 2: Development (Local Build)

1. **Build and start locally:**
   ```bash
   docker-compose -f docker-compose.dev.yml up
   ```
   This automatically:
   - Generates mTLS certificates
   - Builds Docker images from source
   - Starts Proton and Core services
   - Sets up networking and volumes

2. **Or use the Makefile shortcuts:**
   ```bash
   # Start core services (Proton + Core)
   make -f Makefile.docker up
   
   # Start all services including optional components
   make -f Makefile.docker up-full
   ```

4. **Check service health:**
   ```bash
   make -f Makefile.docker status
   make -f Makefile.docker test
   ```

5. **View logs:**
   ```bash
   make -f Makefile.docker logs
   ```

## Container Images

ServiceRadar provides pre-built multi-architecture (amd64/arm64) container images:

- **Core Service**: `ghcr.io/carverauto/serviceradar-core:latest`
- **Proton Database**: `ghcr.io/carverauto/serviceradar-proton:latest`  
- **Certificate Generator**: `ghcr.io/carverauto/serviceradar-cert-generator:latest`

Images are automatically built and published via GitHub Actions on every push to main/develop branches and tagged releases.

### Image Versioning

- `latest`: Latest stable release from main branch
- `develop`: Latest development build
- `v1.2.3`: Specific version tags
- `1.2`: Major.minor tags for compatibility

## Architecture

The Docker setup consists of:

- **Proton** (TimeBase): Time-series database based on ClickHouse with:
  - Automatic password generation
  - mTLS authentication
  - Proper ulimits and sysctls for performance
  - Required capabilities (NET_ADMIN, IPC_LOCK, SYS_NICE)
- **ServiceRadar Core**: Main service handling API, gRPC, and business logic
- **Optional Services**:
  - NATS: Messaging system (profile: full)

## Security Features

### mTLS (Mutual TLS)
All inter-service communication uses mTLS for authentication and encryption:
- Self-signed Root CA for development
- Individual certificates for each component
- Certificates valid for 10 years (development only)
- Proper SAN (Subject Alternative Names) for Docker networking
- **Core ↔ Proton**: Uses port 9440 (secure TCP) with client certificate verification
- **Proton**: Requires client certificates for secure connections
- **Core**: Configured with security mode "mtls" and proper certificate paths

### Database Security
- Proton password is auto-generated if not provided
- Password stored securely in container
- SHA256 password hashing
- Restricted file permissions (600) on sensitive files

### Container Security
- Non-root user execution (proton user)
- Minimal required capabilities
- Read-only volume mounts for configs
- Network isolation with dedicated subnet

## Configuration

ServiceRadar uses configuration files from `packaging/core/config/`:
- `core.docker.json` - Main configuration (Docker-specific with correct Proton connection)
- `api.env` - Environment variables for authentication and API settings

### Default Setup

The docker-compose.yml automatically mounts:
- `packaging/core/config/core.docker.json` as `/etc/serviceradar/core.json`
- `packaging/core/config/api.env` as `/etc/serviceradar/api.env`

### Customizing Configuration

1. **For local development**: Use the default `core.json`:
   ```yaml
   # docker-compose.override.yml
   services:
     core:
       volumes:
         - ./packaging/core/config/core.json:/etc/serviceradar/core.json:ro
   ```

2. **For custom configs**: Create your own config:
   ```yaml
   # docker-compose.override.yml
   services:
     core:
       volumes:
         - ./my-custom-config.json:/etc/serviceradar/core.json:ro
   ```

3. **Override authentication**: Use environment variables:
   ```bash
   # .env file
   AUTH_ENABLED=true
   API_KEY=my-secret-key
   JWT_SECRET=my-jwt-secret
   ```

## Kubernetes Migration Path

The Docker setup is designed for easy migration to Kubernetes:

### ConfigMap for Large Configs

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: serviceradar-config
data:
  core.json: |
    {
      "listen_addr": ":8090",
      "database": {
        "host": "proton-service",
        ...
      }
    }
```

### Secret for Sensitive Data

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: serviceradar-secrets
stringData:
  DATABASE_PASSWORD: "your-password"
  API_KEY: "your-api-key"
```

### Deployment Example

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: serviceradar-core
spec:
  replicas: 3
  template:
    spec:
      containers:
      - name: core
        image: serviceradar/core:latest
        env:
        - name: CONFIG_SOURCE
          value: "env"
        - name: SERVICERADAR_DATABASE_PASSWORD
          valueFrom:
            secretKeyRef:
              name: serviceradar-secrets
              key: DATABASE_PASSWORD
        volumeMounts:
        - name: config
          mountPath: /etc/serviceradar
          readOnly: true
      volumes:
      - name: config
        configMap:
          name: serviceradar-config
```

## Directory Structure

```
docker/
├── compose/           # Docker Compose specific files
│   ├── Dockerfile.core
│   └── entrypoint-core.sh
├── deb/              # Debian package building
├── rpm/              # RPM package building
└── README.md         # This file
```

## Networking

Services communicate on a dedicated bridge network `serviceradar-net` with subnet `172.28.0.0/16`.

### Port Mappings

| Service | Internal Port | External Port | Purpose |
|---------|--------------|---------------|---------|
| Core | 8090 | 8090 | HTTP API |
| Core | 50051 | 50051 | gRPC |
| Core | 9090 | 9090 | Metrics |
| Proton | 8123 | 8123 | HTTP/JDBC |
| Proton | 8463 | 8463 | Native TCP |
| Redpanda | 9092 | 19092 | Kafka API |
| NATS | 4222 | 4222 | Client connections |

## Health Checks

All services include health checks:

- **Core**: `GET /health` endpoint
- **Proton**: `GET /ping` endpoint
- Services won't start dependent services until health checks pass

## Volumes

Persistent data is stored in named volumes:

- `proton-data`: Proton database files
- `core-data`: ServiceRadar persistent data
- `redpanda-data`: Redpanda streaming data
- `nats-data`: NATS message store

## Development

### Building Images

```bash
# Build with custom version
VERSION=1.2.3 BUILD_ID=custom make -f Makefile.docker build

# Development build with live reload
make -f Makefile.docker dev
```

### Debugging

```bash
# Shell into containers
make -f Makefile.docker shell      # Core container
make -f Makefile.docker db-shell   # Proton database

# View specific service logs
docker-compose logs -f core
docker-compose logs -f proton
```

## Production Considerations

1. **Security**:
   - Use secrets management for sensitive data
   - Enable TLS for all services
   - Use non-root users in containers
   - Implement proper authentication

2. **Performance**:
   - Tune Proton for your workload
   - Configure appropriate resource limits
   - Use connection pooling
   - Enable write buffering

3. **Monitoring**:
   - Scrape metrics endpoint with Prometheus
   - Set up log aggregation
   - Implement distributed tracing
   - Configure alerting

4. **High Availability**:
   - Run multiple Core replicas
   - Use Proton cluster mode
   - Implement proper load balancing
   - Configure automatic failover

## Troubleshooting

### Services not starting

Check logs:
```bash
docker-compose logs core
docker-compose logs proton
```

### Database connection issues

Verify Proton is healthy:
```bash
curl http://localhost:8123/ping
```

### Configuration not loading

Check CONFIG_SOURCE and verify:
```bash
docker-compose exec core env | grep CONFIG
```

### Clean restart

```bash
make -f Makefile.docker clean
make -f Makefile.docker up
```