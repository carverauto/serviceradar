<div align=center>
  
[![Website](https://img.shields.io/website?up_message=SERVICERADAR&down_message=DOWN&url=https%3A%2F%2Fserviceradar.cloud&style=for-the-badge)](https://serviceradar.cloud)
[![Apache 2.0 License](https://img.shields.io/badge/license-Apache%202.0-blueviolet?style=for-the-badge)](https://www.apache.org/licenses/LICENSE-2.0)

</div>

# ServiceRadar

Active source development and releases now live at `https://code.carverauto.dev/carverauto/serviceradar`.

<img width="1470" height="836" alt="Screenshot 2025-12-16 at 10 09 19 PM" src="https://github.com/user-attachments/assets/e64ca26b-f4d8-42df-ab81-2de1d7941f92" />
<img width="1470" height="801" alt="Screenshot 2026-02-16 at 8 39 36 PM" src="https://github.com/user-attachments/assets/4f959217-4e53-487b-ae78-30c2fd3344b3" />
<img width="1470" height="804" alt="Screenshot 2026-02-16 at 8 36 26 PM" src="https://github.com/user-attachments/assets/bec3d2cb-c311-4a26-848d-2fece4a5af86" />
<img width="1470" height="801" alt="Screenshot 2026-02-16 at 8 37 08 PM" src="https://github.com/user-attachments/assets/0384520a-755f-4bdd-843a-a41f02d7c439" />


https://github.com/user-attachments/assets/1cf2b90a-06f4-4ba7-b229-79720b16e0aa

[![CNCF Landscape](https://img.shields.io/badge/CNCF%20Landscape-5699C6)](https://landscape.cncf.io/?item=observability-and-analysis--observability--serviceradar)
[![FOSSA Status](https://app.fossa.com/api/projects/custom%2B57999%2Fgit%40github.com%3Acarverauto%2Fserviceradar.git.svg?type=shield&issueType=security)](https://app.fossa.com/projects/custom%2B57999%2Fgit%40github.com%3Acarverauto%2Fserviceradar.git?ref=badge_shield&issueType=security)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/11310/badge)](https://www.bestpractices.dev/projects/11310)
<a href="https://cla-assistant.io/carverauto/serviceradar"><img src="https://cla-assistant.io/readme/badge/carverauto/serviceradar" alt="CLA assistant" /></a>
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/carverauto/serviceradar)

ServiceRadar is a distributed network monitoring system designed for infrastructure and services in hard-to-reach places or constrained environments. It provides real-time monitoring of internal services with cloud-based alerting to ensure you stay informed even during network or power outages.

Demo site available at https://demo.serviceradar.cloud login: `demo@localhost` password: `serviceradar`

## Features

- **Distributed Architecture**: Multi-component design (Agent, Gateway, Core) for flexible edge deployments.
- **WASM Plugin System**: Securely extend monitoring with custom checks in Go or Rust. Runs in a hardware-level sandbox with zero local dependencies and proxied networking.
- **Topology**: GPU-native topology engine capable of rendering millions of interactive nodes and edges at 60fps via [deck.gl](https://deck.gl/), [Apache Arrow](https://arrow.apache.org/) for zero-copy streaming, and WASM-native logic layer.
- **Causal Engine**: Real-time triage and isolation via [DeepCausality](https://github.com/deepcausality-rs) (Rust). Employs hybrid filtering and [roaring bitmaps](https://github.com/RoaringBitmap/roaring) to identify root causes and visually isolate an event's "blast radius" in microseconds.
- **SRQL**: intuitive key:value syntax for querying time-series and relational data.
- **Unified Data Layer**: Powered by CloudNativePG, TimescaleDB, and Apache AGE for relational, time-series, and graph topology data.
- **Observability**: Native support for OTEL, GELF, Syslog, SNMP (polling/traps), BGP ([BMP](https://github.com/carverauto/arancini)), and [NetFlow](https://github.com/mikemiles-dev/netflow_parser).
- **Graph Network Mapper**: Discovery engine that maps interfaces and topology relationships via SNMP/LLDP/CDP.
- **Security**: Hardened with mTLS (SPIFFE/SPIRE on Kubernetes), RBAC, and SSO integration.

## WASM-Based Extensibility

ServiceRadar replaces traditional "script-and-shell" plugins with a [modern WebAssembly runtime](https://github.com/wazero/wazero). This provides a generation leap in security and portability:

| Feature | ServiceRadar (WASM) | Traditional NMS (Nagios/Zabbix) | Enterprise (SolarWinds) |
| :--- | :--- | :--- | :--- |
| **Isolation** | **Hardware Sandbox** | None (OS Process) | None (User Session) |
| **Dependencies** | **Zero** (Static Binaries) | High (Local Libs/Python) | High (.NET/Runtimes) |
| **Security** | Capability-based (Proxy) | Sudo/Root access | Local Admin / WMI |
| **Portability** | Cross-platform WASM | Script-specific | Windows-centric |
| **Auditability** | Every network call logged | Invisible to Agent | Opaque |

**Why WASM?** Plugins are "FS-less" by default. They cannot access the host filesystem or raw sockets. Instead, they use a **Network Bridge** where the Agent proxies specific HTTP/TCP calls based on admin-approved allowlists.

### Plug-in SDK

**Go**: https://github.com/carverauto/serviceradar-sdk-go

**Rust**: https://github.com/carverauto/serviceradar-sdk-rust -- Coming Soon

## Quick Installation (Docker Compose)

Get ServiceRadar running in under 5 minutes:

```bash
# Optional - set these in your .env 
export SERVICERADAR_HOST=<my-vm-ip>
export GATEWAY_PUBLIC_BIND=0.0.0.0

git clone https://code.carverauto.dev/carverauto/serviceradar.git
cd serviceradar

docker compose up -d

# Get your admin password
docker compose logs config-updater
```

**Access:** http://localhost (login: `root@localhost`)

## Kubernetes / Helm Deployment

ServiceRadar provides an official Helm chart for Kubernetes deployments, published to Harbor as an OCI artifact.

```bash
# Inspect chart metadata and default values
helm show chart oci://registry.carverauto.dev/serviceradar/charts/serviceradar --version 1.1.1
helm show values oci://registry.carverauto.dev/serviceradar/charts/serviceradar --version 1.1.1 > values.yaml

# Install a pinned release (recommended)
helm upgrade --install serviceradar oci://registry.carverauto.dev/serviceradar/charts/serviceradar \
  --version 1.1.1 \
  -n serviceradar --create-namespace \
  --set global.imageTag="v1.1.1"

# Track mutable images (staging/dev): pulls :latest and forces re-pull
helm upgrade --install serviceradar oci://registry.carverauto.dev/serviceradar/charts/serviceradar \
  --version 1.1.1 \
  -n serviceradar --create-namespace \
  --set global.imageTag="latest" \
  --set global.imagePullPolicy="Always"

# Get password for 'root@localhost' user created by helm install
kubectl get secret serviceradar-secrets -n serviceradar \
    -o jsonpath='{.data.admin-password}' | base64 -d
```

Note: if you omit `global.imageTag`, the chart defaults to `latest`. Set `global.imagePullPolicy=Always` when you want to pick up new pushes on restart.

## Verifying Published Images

ServiceRadar publishes Cosign-signed images to Harbor. The public verification key is committed in [docs/cosign.pub](/Users/mfreeman/src/serviceradar/docs/cosign.pub).

For the self-hosted keyless migration path, keep custom Sigstore trust
material under [docs/sigstore/README.md](/home/mfreeman/src/serviceradar/docs/sigstore/README.md).
The release scripts now support both legacy key-based verification and
keyless verification against a custom trusted root.

Verify a released or immutable image tag with:

```bash
cosign verify \
  --experimental-oci11 \
  --key docs/cosign.pub \
  registry.carverauto.dev/serviceradar/serviceradar-core-elx:v1.2.10
```

For build-specific images, prefer the immutable `sha-<commit>` tags:

```bash
cosign verify \
  --experimental-oci11 \
  --key docs/cosign.pub \
  registry.carverauto.dev/serviceradar/serviceradar-core-elx:sha-ac23dc0ebcbee0d6a964dc8307826bf2a063536c
```

Successful verification proves the image was signed with the ServiceRadar release key and that the signature published in Harbor matches the requested image.

For self-hosted keyless verification, use the published trusted root and
certificate identity policy instead of `docs/cosign.pub`:

```bash
cosign verify \
  --experimental-oci11 \
  --trusted-root docs/sigstore/trusted-root.json \
  --certificate-identity-regexp '<issuer-specific SAN regex>' \
  --certificate-oidc-issuer https://issuer.example.com \
  registry.carverauto.dev/serviceradar/serviceradar-core-elx:sha-ac23dc0ebcbee0d6a964dc8307826bf2a063536c
```

Docker Compose notes:
- Set `APP_TAG` in `.env` to pin release images (example: `APP_TAG=v1.1.1`).
- Set `COMPOSE_FILE=docker-compose.yml:docker-compose.dev.yml` in `.env` to default to the dev overlay without `-f`.

**Chart URL:** `oci://registry.carverauto.dev/serviceradar/charts/serviceradar`

Notes:
- [Chart](helm/serviceradar/Chart.yaml) versions are like `1.1.1`; ServiceRadar image tags are like `v1.1.1`.
- If your cluster requires registry credentials, set `image.registryPullSecret` (default `registry-carverauto-dev-cred`).

For ArgoCD deployments, use `registry.carverauto.dev/serviceradar/charts` as the repository URL (without the `oci://` prefix):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: serviceradar
  namespace: argocd
spec:
  destination:
    server: https://kubernetes.default.svc
    namespace: serviceradar
  source:
    repoURL: registry.carverauto.dev/serviceradar/charts
    chart: serviceradar
    targetRevision: "1.1.1"
    helm:
      values: |
        global:
          imageTag: "v1.1.1"
```

## Architecture

1. **Agent**: Lightweight Go service on monitored hosts; manages WASM execution and local collection.
2. **Agent-Gateway**: Ingestion point that receives gRPC streams from edge agents.
3. **Core (core-elx)**: Control plane (Elixir/Phoenix/Ash) for orchestration, ERTS, and job scheduling (Oban).
4. **Web UI (web-ng)**: Real-time LiveView dashboard and APIs for configuration and visualization.
5. **NATS**: [NATS JetStream](https://docs.nats.io/nats-concepts/jetstream) message broker for bulk ingestion streams.
6. **Collectors**: Collect bulk data (netflow, logs, SNMP, etc.).

## Documentation

For detailed guides on setup, security, and WASM SDK usage, visit:
**[https://docs.serviceradar.cloud](https://docs.serviceradar.cloud)**

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request. Join our [Discord](https://discord.gg/dhaNgF9d3g)! 

## License

Apache 2.0 License - see the [LICENSE](LICENSE) file for details.
