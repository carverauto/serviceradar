# ServiceRadar Docker Quick Start

This guide gets you started with ServiceRadar using Docker Compose in under 5 minutes.

## Prerequisites

- Docker Engine 20.10+
- Docker Compose 2.0+
- 8GB+ RAM
- 50GB+ disk space

## Quick Start

1. **Clone and navigate**:
   ```bash
   git clone https://github.com/carverauto/serviceradar.git
   cd serviceradar
   ```

2. **Start ServiceRadar**:
   ```bash
   SERVICERADAR_VERSION=latest docker-compose up -d
   ```

3. **Get your admin password**:
   ```bash
   docker-compose logs config-updater | grep "Password:"
   ```

4. **Access ServiceRadar**:
   - Web Interface: http://localhost
   - Username: `admin`
   - Password: (from step 3)

## Test Your Setup

Run the included test script:
```bash
./test-docker-setup.sh
```

## What's Next?

- **Configure devices**: See [Device Configuration Guide](docs/docs/device-configuration.md)
- **Full documentation**: See [Docker Setup Guide](docs/docs/docker-setup.md)
- **Security**: Change your admin password after first login

## Optional: Enable Kong Gateway (Community, DB-less + JWKS)

Run Kong OSS locally and proxy `/api/*` through it. A pre-start helper fetches Core's JWKS and generates a DB-less config, so keys are fresh each startup.

1) Generate DB-less config then start Kong (profile `kong`):
   docker-compose --profile kong up -d kong-config kong

2) Point Nginx to Kong by setting API_UPSTREAM when starting Nginx:
   API_UPSTREAM=http://kong:8000 docker-compose up -d nginx

3) Validate Admin API:
   curl -s http://localhost:8001/

Notes:
- No license or Postgres required (community, DB-less).
- Override JWKS/service/route via env: `JWKS_URL`, `KONG_SERVICE_URL`, `KONG_ROUTE_PATH`.
- The default Nginx config proxies `/api/*` directly to Core. Set `API_UPSTREAM` to route via Kong.


## Common Commands

```bash
# View all service status
docker-compose ps

# View logs for all services
docker-compose logs

# View logs for specific service
docker-compose logs core

# Stop all services
docker-compose down

# Restart a service
docker-compose restart core

# Update to latest version
SERVICERADAR_VERSION=latest docker-compose pull
docker-compose up -d
```

## Troubleshooting

If services fail to start:

1. **Check logs**: `docker-compose logs [service-name]`
2. **Verify resources**: Ensure Docker has enough memory/CPU
3. **Check ports**: Ensure ports 80, 8090, 514, 162 are available
4. **Reset**: `docker-compose down && docker volume prune && docker-compose up -d`

## Security Notice

🔐 **Important**: On first startup, ServiceRadar generates:
- Random admin password
- API keys and JWT secrets
- mTLS certificates

**Save your admin password** and delete the auto-generated password file:
```bash
docker-compose exec core rm /etc/serviceradar/certs/password.txt
```

## Support

- 📚 [Complete Documentation](docs/docs/)
- 🐛 [Report Issues](https://github.com/carverauto/serviceradar/issues)
- 💬 [Community Support](https://github.com/carverauto/serviceradar/discussions)
