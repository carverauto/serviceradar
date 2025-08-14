# 🚀 ServiceRadar Docker Quick Start

## One Command Setup - RECOMMENDED

```bash
docker-compose up
```

Uses pre-built images from GitHub Container Registry (GHCR). Fast, consistent, and production-ready.

## Development (Local Build)

```bash
docker-compose -f docker-compose.dev.yml up
```

Builds images locally from source. Best for development and testing changes.

## What happens with one command:
- ✅ Generate mTLS certificates automatically
- ✅ Pull/Build Docker images  
- ✅ Start Proton database with security
- ✅ Start ServiceRadar Core service
- ✅ Set up networking and persistent volumes

## Alternative Commands

```bash
# Production deployment with pre-built images (default)
docker-compose up

# Development with local builds  
docker-compose -f docker-compose.dev.yml up

# Using Makefile (uses pre-built images)
make -f Makefile.docker start

# All services including NATS, Redpanda
make -f Makefile.docker up-full
```

## Check Status

```bash
# View service status
make -f Makefile.docker status

# View logs
make -f Makefile.docker logs

# Test connectivity
make -f Makefile.docker test
```

## Access Services

- **Web UI**: http://localhost:8090
- **Core API**: http://localhost:8090/swagger  
- **Metrics**: http://localhost:9090/metrics
- **Proton HTTP**: http://localhost:8123
- **Proton Native**: localhost:8463 (insecure) / localhost:9440 (mTLS)

## Stop Services

```bash
docker-compose down
```

## Environment Variables (Optional)

Copy `.env.example` to `.env` to customize:
- Database passwords
- API keys
- Log levels
- Service configuration

All values have sensible defaults, so the `.env` file is optional.

## What's Running?

- **cert-generator**: One-time container that generates mTLS certificates
- **proton**: Time-series database with mTLS security
- **core**: ServiceRadar API and business logic

For full documentation, see [docker/README.md](docker/README.md).