# WiFi Map Local Compose Validation

Use this workflow for proprietary WiFi-map seed data. Do not load customer CSVs
into the shared Kubernetes demo or staging namespaces.

## Inputs

The CSV seed directory should contain the generated POC files:

- `sites.csv` - required site/map rows.
- `search_index.csv` - AP and WLC search/device rows.
- `history.csv` - fleet AP-family history.
- `overrides.csv` - manual non-airport site coordinates.
- `meta.json` - optional collection/build timestamps.

The same seed directory may also include raw collector outputs. These are
preferred when available because they preserve better AP, WLC, and RADIUS
lineage:

- `ap-database-current.csv`
- `switchinfo-current.csv` or `wlc-database-current.csv`
- `radius-groups-current.csv`

Airport/site reference data is expected to remain CSV-backed. In production, the
customer-owned plugin can ship those files as package assets from its private
Git repository and emit the same `csv_seed` batch contract.

## Start Compose Without Faker

The root `docker-compose.yml` stack does not include faker by default. If using
`docker-compose.dev.yml`, faker is behind the `faker` profile and should not be
enabled while validating WiFi-map density or inventory counts.

```bash
docker compose up -d cnpg core-elx web-ng agent-gateway
```

If an older local stack has faker running, stop it before validating:

```bash
docker compose stop faker
```

## Dry Run the Seed Payload

Run the dry run from the core app. The summary contains file hashes and row
counts, not the proprietary row contents.

```bash
cd elixir/serviceradar_core
mix serviceradar.wifi_map.seed --dir ../../tmp/wifi-map --dry-run
```

## Ingest Into Local Compose CNPG

Copy the generated Compose workstation certificates once if they are not already
available outside Docker:

```bash
mkdir -p .local-dev-certs
sudo cp /var/lib/docker/volumes/serviceradar_cert-data/_data/{root.pem,db-client.pem,db-client-key.pem} .local-dev-certs/
sudo chown -R "$USER:$USER" .local-dev-certs
```

Point the core Mix task at the Compose CNPG port and ingest the batch locally.
Compose CNPG rejects non-TLS connections, so use the client certificate bundle:

```bash
cd elixir/serviceradar_core
CNPG_PASSWORD="$(docker run --rm -v serviceradar_cnpg-credentials:/creds:ro alpine cat /creds/serviceradar-password)"
DATABASE_URL="postgresql://serviceradar:${CNPG_PASSWORD}@localhost:5455/serviceradar" \
  CNPG_SSL_MODE=verify-full CNPG_TLS_SERVER_NAME=cnpg \
  CNPG_CERT_DIR="$PWD/../../.local-dev-certs" \
  mix serviceradar.wifi_map.seed --dir ../../tmp/wifi-map --partition local
```

Use `--skip-device-sync` only when testing WiFi-map tables without updating
`ocsf_devices`; normal validation should leave device sync enabled.

## Smoke Queries

After ingestion, verify the local database has map rows:

```sql
SELECT COUNT(*) FROM platform.wifi_sites;
SELECT COUNT(*) FROM platform.wifi_site_snapshots;
SELECT COUNT(*) FROM platform.wifi_access_point_observations;
SELECT COUNT(*) FROM platform.wifi_controller_observations;
SELECT COUNT(*) FROM platform.ocsf_devices
WHERE metadata->>'integration_type' = 'wifi_map';
```

The map view is not a built-in ServiceRadar product route. After seeding, import
and enable the customer dashboard package from its own repository, then open the
enabled dashboard instance route, for example:

```text
/dashboards/ual-network-map
```

The dashboard package route is authenticated, driven by the package SRQL data
frames, and uses ServiceRadar-owned Mapbox settings for the basemap.
