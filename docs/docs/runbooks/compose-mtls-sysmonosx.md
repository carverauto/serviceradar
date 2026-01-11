# Compose mTLS sysmon-osx onboarding (Docker Compose)

Use this runbook to bring a macOS arm64 or Linux sysmon-osx checker online against the mTLS Compose stack without SPIRE. It relies on the Compose CA, edgepkg-v1 tokens, and the sysmon-osx `--mtls` bootstrap path.

## Prerequisites
- The Docker Compose stack is running (`docker compose up -d`).
- You can read generated secrets from the `cert-data` volume (`/etc/serviceradar/certs` in core/web).
- `serviceradar-cli` is available (`./serviceradar-cli` from the repo root is fine).
- Know the gateway endpoint reachable from the edge host (e.g., `192.168.2.134:50053`).

## 1) Fetch admin auth + API key from Compose
```bash
# Admin password + API key (from the generated cert volume)
ADMIN_PASS=$(docker exec serviceradar-core-mtls cat /etc/serviceradar/certs/admin-password)
API_KEY=$(docker exec serviceradar-core-mtls cat /etc/serviceradar/certs/api-key)

# Get a bearer token from core via caddy (localhost)
ACCESS_TOKEN=$(curl -s http://localhost/api/auth/login \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"${ADMIN_PASS}\"}" \
  | python -c "import sys,json;print(json.load(sys.stdin)['access_token'])")
```

## 2) Issue an mTLS sysmon-osx package (edgepkg-v1 token)
```bash
CORE_URL=http://localhost:8090

# Create a sysmon-osx mTLS package (uses metadata.security_mode=mtls)
./serviceradar-cli edge package mtls \
  --core-url "${CORE_URL}" \
  --auth-token "${ACCESS_TOKEN}" \
  --api-key "${API_KEY}" \
  --label sysmonosx-darwin \
  --gateway-id docker-gateway \
  --checker-kind sysmon \
  --metadata '{"security_mode":"mtls","checker":{"gateway_endpoint":"192.168.2.134:50053"}}' \
  --output json

# Emit the edgepkg-v1 token (base64url payload with pkg/download token/core api)
./serviceradar-cli edge package token \
  --core-url "${CORE_URL}" \
  --auth-token "${ACCESS_TOKEN}" \
  --api-key "${API_KEY}" \
  --id <PACKAGE_ID_FROM_CREATE> \
  --download-token <DOWNLOAD_TOKEN_FROM_CREATE> \
  > edgepkg.token
```

Token semantics (locked for mTLS):
- Format: `edgepkg-v1:<base64url-json>`
- Fields: `pkg` (package id), `dl` (download token), `api` (core URL, optional if `--host` is supplied to the client)
- TTLs: defaults seeded by `edge_onboarding` config (`join_token_ttl=15m`, `download_token_ttl=10m` from `docker/compose/update-config.sh`).

The deliver response includes an `mtls_bundle` with `ca_cert_pem`, `client_cert_pem`, `client_key_pem`, optional `server_name`, and `endpoints`.

## 3) Bootstrap sysmon-osx on the edge host (online)
```bash
EDGE_TOKEN=$(cat edgepkg.token)

serviceradar-sysmon-osx \
  --mtls \
  --token "${EDGE_TOKEN}" \
  --host http://192.168.2.134:8090 \
  --gateway-endpoint 192.168.2.134:50053 \
  --cert-dir /etc/serviceradar/certs
```
- `--host` is only needed if the token omits `api`.
- Certs install to `/etc/serviceradar/certs` (writes `root.pem`, `sysmon-osx.pem`, `sysmon-osx-key.pem`). Server name defaults to the bundle value if not provided.
- The gateway will accept the connection because the client cert chains to the Compose CA.

## 4) Offline / pre-fetched bundle flow
```bash
# On a connected machine, pull a JSON bundle (contains mtls_bundle)
./serviceradar-cli edge package download \
  --core-url "${CORE_URL}" \
  --auth-token "${ACCESS_TOKEN}" \
  --api-key "${API_KEY}" \
  --id <PACKAGE_ID> \
  --download-token <DOWNLOAD_TOKEN> \
  --format json \
  --output edge-package.json

# On the edge host (air-gapped), copy edge-package.json and run:
serviceradar-sysmon-osx \
  --mtls \
  --bundle /path/to/edge-package.json \
  --gateway-endpoint 192.168.2.134:50053 \
  --cert-dir /etc/serviceradar/certs
```
`--bundle` also accepts a tar.gz archive or a directory containing `mtls/ca.pem`, `client.pem`, and `client-key.pem`.

## 5) Rotation and retries
- Reissue a download token without recreating the package: `./serviceradar-cli edge package show --reissue-token --id <pkg> --download-token <new-token>`.
- Revocation: `./serviceradar-cli edge package revoke --core-url "${CORE_URL}" --auth-token "${ACCESS_TOKEN}" --id <pkg>`.
- To rotate certs on the edge, re-run sysmon-osx with a freshly issued token (writes new pem/key over the existing files).
