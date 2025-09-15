APISIX Packaging for Bare Metal (RHEL/Debian)

Overview

- Use Apache APISIX as the edge gateway for ServiceRadar.
- APISIX validates JWTs (RS256) via ServiceRadar Core’s JWKS.
- Local auth and OAuth (goth) continue to be served by Core under /auth/*.

Supported setups

1) Native APISIX packages (recommended)
   - RHEL/CentOS: Use official APISIX RPM repo
   - Debian/Ubuntu: Use official APISIX DEB repo

2) Containerized APISIX
   - Run `apache/apisix` via Docker/Podman with `APISIX_STAND_ALONE=true`

Requirements

- ServiceRadar Core reachable by APISIX, e.g. http://core:8090 or https://core.example.com
- Core configured for RS256 and serving:
  - `/.well-known/openid-configuration`
  - `/auth/jwks.json`

Install (Native)

Follow Apache APISIX docs to install APISIX and dependencies (OpenResty, etc.). Then place the provided `apisix.yaml` into `/usr/local/apisix/conf/apisix.yaml` and enable standalone mode.

Standalone mode (no etcd):

In `/usr/local/apisix/conf/config.yaml`:

deployment:
  role: data_plane
  role_data_plane:
    config_provider: yaml

Restart APISIX.

Config example

See `packaging/apisix/apisix.yaml` as a starting point. Replace upstreams with the reachable addresses for your environment:

- `core:8090` => your core API address
- `web:3000`  => your web UI address (or an external URL via `proxy-rewrite`)

Routes included

- `/api/*` → Core (protected with `openid-connect` using discovery/JWKS)
- `/auth/*` → Core (public, for login/refresh and OAuth callbacks)
- `/*` → Web UI (public; app relies on API for auth)

Systemd template (containerized via Podman)

[Unit]
Description=APISIX (container)
After=network-online.target
Wants=network-online.target

[Service]
Restart=always
ExecStart=/usr/bin/podman run --rm \
  -e APISIX_STAND_ALONE=true \
  -p 9080:9080 -p 9443:9443 \
  -v /etc/serviceradar/apisix.yaml:/usr/local/apisix/conf/apisix.yaml:ro \
  --network host \
  --name apisix apache/apisix:3.9.1-debian
ExecStop=/usr/bin/podman stop apisix

[Install]
WantedBy=multi-user.target

Testing

- Use `scripts/test-apisix.sh` as a reference. For bare metal, replace `localhost:9080` with your APISIX listener and ensure Core is reachable.

Notes

- Local auth (username/password) and SSO (OAuth via goth) remain on Core under `/auth/*`.
- APISIX only validates Bearer tokens for `/api/*` and forwards claims when configured.
- To pass individual claims to upstreams, add `request-transformer` to map `X-Userinfo` JSON claims into explicit headers.

