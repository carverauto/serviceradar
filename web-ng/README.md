# ServiceRadarWebNG

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## Connecting to the existing CNPG (Docker/K8s)

This app is intended to run against the existing ServiceRadar CNPG/AGE database (TimescaleDB + Apache AGE).

### Docker (CNPG running on the docker host)

The repo’s `docker-compose.yml` publishes CNPG on `${CNPG_PUBLIC_BIND:-127.0.0.1}:${CNPG_PUBLIC_PORT:-5455}` on the docker host.

1. On the docker host, ensure CNPG’s server cert allows IP-based clients (example IP: `192.168.2.134`):
   - Set `CNPG_CERT_EXTRA_IPS=192.168.2.134` and (re)run `docker compose up cert-generator` so `cnpg.pem` includes that SAN.
   - Set `CNPG_PUBLIC_BIND=0.0.0.0` (or a specific LAN interface IP) so the published port is reachable from your workstation (put it in `.env` or export it before running compose).
   - Restart the `cnpg` container after regenerating `cnpg.pem`.

2. Export client certs from the docker host and copy them to your workstation (keep them out of the repo):
   - Find the cert volume: `docker volume ls | rg 'cert-data'`
   - Copy out `root.pem`, `workstation.pem`, `workstation-key.pem` from that volume.

3. On your workstation, point `web-ng/` at CNPG:

```bash
cd web-ng
export CNPG_HOST=192.168.2.134
export CNPG_PORT=5455
export CNPG_DATABASE=serviceradar
export CNPG_USERNAME=serviceradar
export CNPG_PASSWORD=serviceradar
export CNPG_SSL_MODE=verify-full
export CNPG_CERT_DIR=/path/to/private/serviceradar-certs
mix graph.ready
mix phx.server
```

If you are using `CNPG_SSL_MODE=verify-full` with an IP `CNPG_HOST`, the CNPG server cert must include that IP in its SAN (use `CNPG_CERT_EXTRA_IPS` as above).

### Kubernetes

Use `kubectl port-forward` to expose Postgres locally, then set `CNPG_HOST=localhost` and `CNPG_PORT=<forwarded-port>` (and the same TLS env vars if your cluster requires them).

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
