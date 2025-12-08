# ServiceRadar Docker Quick Start

This guide gets you started with ServiceRadar using Docker Compose in under 5 minutes.

## Prerequisites

- Docker Engine 20.10+ (or Podman 4.0+ with podman-compose)
- Docker Compose 2.0+ (or podman-compose)
- 8GB+ RAM
- 50GB+ disk space

## OS-Specific Setup

### AlmaLinux 9 / RHEL 9 / Rocky Linux 9

```bash
# Install Docker
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Enable and start Docker
sudo systemctl enable --now docker

# Add your user to the docker group
sudo usermod -aG docker $USER
newgrp docker

# Install Git (if needed)
sudo dnf install -y git
```

### Ubuntu / Debian

```bash
# Install Docker
curl -fsSL https://get.docker.com | sudo sh

# Add your user to the docker group
sudo usermod -aG docker $USER
newgrp docker
```

### macOS

Install [Docker Desktop](https://www.docker.com/products/docker-desktop/) and ensure it's running.

### Podman (Alternative to Docker)

Podman is a drop-in replacement for Docker available on most Linux distributions. ServiceRadar works with Podman but requires **rootful mode** due to privileged containers and low port bindings.

**AlmaLinux 9 / RHEL 9 / Rocky Linux 9:**
```bash
# Install Podman and compose
sudo dnf install -y podman podman-compose

# Enable Podman socket for compose compatibility
sudo systemctl enable --now podman.socket
```

**Ubuntu / Debian:**
```bash
sudo apt-get update
sudo apt-get install -y podman podman-compose
```

**Running ServiceRadar with Podman:**
```bash
# Must use sudo for privileged containers and port 80/514/162
sudo podman-compose up -d

# Or with podman compose (v4.7+)
sudo podman compose up -d

# View logs
sudo podman-compose logs config-updater | grep "Password:"
```

**Why rootful mode is required:**
- The `agent` service uses `privileged: true` for network scanning
- Ports 80, 514, and 162 require root to bind (< 1024)
- Some init containers run as `user: "0:0"`

**SELinux considerations (RHEL/AlmaLinux):**
```bash
# Allow container cgroup management
sudo setsebool -P container_manage_cgroup on
```

## Quick Start

1. **Clone and navigate**:
   ```bash
   git clone https://github.com/carverauto/serviceradar.git
   cd serviceradar
   ```

2. **Create environment file**:
   ```bash
   cp .env.example .env
   ```

3. **Pull the images**:
   ```bash
   docker compose pull
   ```

4. **Start ServiceRadar**:
   ```bash
   docker compose up -d
   ```

5. **Get your admin password**:
   ```bash
   docker compose logs config-updater | grep "Password:"
   ```

6. **Access ServiceRadar**:
   - Web Interface: http://localhost (nginx on port 80)
   - API via nginx: http://localhost/api/
   - Username: `admin`
   - Password: (from step 5)

## Startup Sequence

The stack automatically handles certificate generation and configuration:

1. **cert-generator** - Creates all mTLS certificates (one-shot)
2. **cnpg** - PostgreSQL with SSL enabled
3. **cert-permissions-fixer** - Sets proper certificate ownership (one-shot)
4. **nats** - Message broker with mTLS
5. **datasvc, core, poller, agent** - Core services
6. **checkers, web, etc.** - Additional services

## Test Your Setup

Run the included test script:
```bash
./test-docker-setup.sh
```

## What's Next?

- **Configure devices**: See [Device Configuration Guide](docs/docs/device-configuration.md)
- **Full documentation**: See [Docker Setup Guide](docs/docs/docker-setup.md)
- **Security**: See [TLS Security Guide](docs/docs/tls-security.md) - Change your admin password after first login

## Build Images Locally (Bazel)

ServiceRadar container images are built with Bazel. Load the agent image into your local Docker daemon before starting Compose:

```bash
bazel run //docker/images:agent_image_amd64_tar
```

To publish the agent image (and the rest of the stack) to GHCR using the same Bazel targets:

```bash
# Push just the agent image
bazel run //docker/images:agent_image_amd64_push

# Or push every image in one go
bazel run //docker/images:push_all
```

## Optional: Enable Kong Gateway (Community, DB-less + JWKS)

Run Kong OSS locally and proxy `/api/*` through it. A pre-start helper fetches Core's JWKS and generates a DB-less config, so keys are fresh each startup.

1) Generate DB-less config then start Kong (profile `kong`):
   ```bash
   docker compose --profile kong up -d kong-config kong
   ```

2) Point Nginx to Kong by setting API_UPSTREAM when starting Nginx (TLS terminates at Nginx; internal hop is HTTP):
   ```bash
   API_UPSTREAM=http://kong:8000 docker compose up -d nginx
   ```

3) Validate Admin API:
   ```bash
   curl -s http://localhost:8001/
   ```

4) Client HTTPS terminates at Nginx (optional):
   - If you map 443:443 and provide certs to Nginx, clients use HTTPS to Nginx.
   - Behind Nginx, Kong and Core communicate over HTTP only.

Notes:
- No license or Postgres required (community, DB-less).
- Override JWKS/service/route via env: `JWKS_URL`, `KONG_SERVICE_URL`, `KONG_ROUTE_PATH`.
- The default Nginx config proxies `/api/*` directly to Core. Set `API_UPSTREAM` to route via Kong.


## Common Commands

```bash
# View all service status
docker compose ps

# View logs for all services
docker compose logs

# View logs for specific service
docker compose logs core

# Follow logs in real-time
docker compose logs -f

# Stop all services
docker compose down

# Restart a service
docker compose restart core

# Update to a specific version
# Edit .env and set APP_TAG=v1.0.65, then:
docker compose pull
docker compose up -d
```

## Troubleshooting

If services fail to start:

1. **Check logs**: `docker compose logs [service-name]`
2. **Verify resources**: Ensure Docker has enough memory/CPU
3. **Check ports**: Ensure ports 80, 8090, 514, 162 are available
4. **Reset**: `docker compose down && docker volume prune && docker compose up -d`

### AlmaLinux 9 / RHEL 9 Specific Issues

**SELinux blocking containers**:
```bash
# Allow containers to manage cgroups
sudo setsebool -P container_manage_cgroup on

# Or temporarily disable SELinux (not recommended for production)
sudo setenforce 0
```

**Firewall blocking ports**:
```bash
sudo firewall-cmd --add-port=80/tcp --permanent    # Web UI (nginx)
sudo firewall-cmd --add-port=443/tcp --permanent   # Web UI HTTPS (optional)
sudo firewall-cmd --add-port=8090/tcp --permanent  # Core API (direct)
sudo firewall-cmd --reload
```

**Certificate permission issues**:
```bash
# Check cert-permissions-fixer ran successfully
docker compose logs cert-permissions-fixer
```

## Security Notice

On first startup, ServiceRadar generates:
- Random admin password
- API keys and JWT secrets
- mTLS certificates for all services

**Save your admin password** and delete the auto-generated password file:
```bash
docker compose exec core rm /etc/serviceradar/certs/password.txt
```

## Support

- [Complete Documentation](docs/docs/)
- [Report Issues](https://github.com/carverauto/serviceradar/issues)
- [Community Support](https://github.com/carverauto/serviceradar/discussions)
