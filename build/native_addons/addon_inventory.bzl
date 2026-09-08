"""In-repo inventory of first-party native agent add-ons (issue 3425).

Mirrors build/wasm_plugins/plugin_inventory.bzl. Each entry declares an add-on
bundle: the binary to package per architecture, the manifest files to ship, and
the target platforms. build/native_addons/defs.bzl loops this list to emit
per-arch binaries + a deterministic signed-able bundle (zip + sha256 +
metadata.json) per add-on, analogous to the Wasm plugin bundles.

Each entry's "language" selects how the per-arch binary is produced:
  - "go"   -> the go_binary is cross-compiled per arch via go_cross_binary.
  - "rust" -> the rust_binary is packaged directly (rules_rust has no
              go_cross_binary analogue wired in this repo yet). Rust production
              add-ons should declare only the configured release arch until
              real Rust cross-compilation is wired in.
"""

ADDON_BUNDLES = [
    # NOTE: the advisory-producer add-on was retired in
    # refactor-advisory-feeds-into-core. Advisory vulnerability feeds (CISA KEV,
    # VulnCheck KEV, VulnCheck nist-nvd2, NVD CVE 2.0) are now acquired, parsed,
    # and bulk-loaded by core-elx on an AshOban schedule (disk-staged on a PVC),
    # with no agent involvement.
    {
        # netprobe host-network-visibility add-on (migrate-netprobe-to-native-addon).
        # Carved out of the base serviceradar-agent package: the //rust/netprobe
        # binary is now packaged here as a signed per-arch pushed-artifact bundle
        # instead of being baked into the agent deb/rpm + release runtime archive.
        # The socket-lifecycle open question is resolved to systemd-service (netprobe
        # binds the IPC socket; the agent connects as a client — see addon.yaml), so the
        # bundle now ships the systemd unit via `unit_entries`. The unit installs verbatim
        # under the staged `current` dir; the agent-side assignment-gated activation is
        # migrate-netprobe task 2.2.
        "name": "netprobe_addon_bundle",
        "addon_id": "netprobe",
        "repository_name": "serviceradar-addon-netprobe",
        "language": "rust",
        "binary": "//rust/netprobe:netprobe",
        "binary_name": "serviceradar-netprobe",
        "platforms": [
            ("linux", "amd64"),
        ],
        "manifest_entries": [
            ("addon.yaml", "//addons/netprobe:addon.yaml"),
            ("config.schema.json", "//addons/netprobe:config.schema.json"),
        ],
        "unit_entries": [
            ("serviceradar-netprobe.service", "//addons/netprobe:serviceradar-netprobe.service"),
        ],
        # The compiled eBPF/AF_XDP object ships flat in the bundle next to the binary;
        # netprobe loads it via `--ebpf-object` (continuous capture requires it after the
        # Phase 3 eBPF cutover — see rust/netprobe/src/main.rs). It is arch-independent BPF
        # bytecode (CO-RE), so the same object serves both linux platforms.
        "data_entries": [
            ("netprobe_ebpf.o", "//rust/netprobe/ebpf:netprobe_ebpf_object"),
        ],
        "pushed_artifact_tarball": True,
    },
    {
        # PowerDNS protobuf telemetry add-on. Runs as an unprivileged go-plugin
        # agent-sidecar on DNS hosts, receives localhost PowerDNS protobuf frames,
        # and emits native-telemetry:v1 OCSF DNS Activity batches through the
        # authenticated agent path.
        "name": "powerdns_addon_bundle",
        "addon_id": "powerdns",
        "repository_name": "serviceradar-addon-powerdns",
        "language": "rust",
        "binary": "//rust/powerdns:serviceradar-powerdns-addon",
        "binary_name": "serviceradar-powerdns-addon",
        "platforms": [
            ("linux", "amd64"),
        ],
        "manifest_entries": [
            ("addon.yaml", "//addons/powerdns:addon.yaml"),
            ("config.schema.json", "//addons/powerdns:config.schema.json"),
            ("schemas/dns_activity.schema.json", "//addons/powerdns:schemas/dns_activity.schema.json"),
            ("display/dns_activity.display.json", "//addons/powerdns:display/dns_activity.display.json"),
        ],
        "pushed_artifact_tarball": True,
    },
    {
        # Workload identity collector add-on. Runs as a standalone ServiceRadar
        # host component that owns CRI/container runtime metadata discovery. Netprobe
        # is a later consumer of the upstream identity state, not the collector owner.
        "name": "workload_identity_addon_bundle",
        "addon_id": "workload-identity",
        "repository_name": "serviceradar-addon-workload-identity",
        "language": "rust",
        "binary": "//rust/workload-identity:workload_identity_daemon",
        "binary_name": "serviceradar-workload-identity",
        "platforms": [
            ("linux", "amd64"),
        ],
        "manifest_entries": [
            ("addon.yaml", "//addons/workload-identity:addon.yaml"),
            ("config.schema.json", "//addons/workload-identity:config.schema.json"),
        ],
        "unit_entries": [
            ("serviceradar-workload-identity.service", "//addons/workload-identity:serviceradar-workload-identity.service"),
        ],
        "data_entries": [
            ("workload-identity.json", "//addons/workload-identity:workload_identity_runtime_config"),
        ],
        "pushed_artifact_tarball": True,
    },
    {
        # Bumblebee exposure scanner add-on (migrate-bumblebee-to-native-addon).
        # Ships the root-owned scanner binary plus its systemd service/timer as a
        # signed pushed-artifact bundle. The non-root agent only stages the artifact
        # and asks agent-updater to install the bundled units; scanner findings still
        # flow through the sanitized /var/lib/serviceradar/bumblebee spool.
        "name": "bumblebee_scan_addon_bundle",
        "addon_id": "bumblebee",
        "repository_name": "serviceradar-addon-bumblebee-scan",
        "language": "go",
        "binary": "//go/cmd/bumblebee-scan:bumblebee_scan",
        "binary_name": "serviceradar-bumblebee-scan",
        "platforms": [
            ("linux", "amd64"),
            ("linux", "arm64"),
        ],
        "manifest_entries": [
            ("addon.yaml", "//addons/bumblebee-scan:addon.yaml"),
            ("config.schema.json", "//addons/bumblebee-scan:config.schema.json"),
        ],
        "unit_entries": [
            ("serviceradar-bumblebee-scan.service", "//addons/bumblebee-scan:serviceradar-bumblebee-scan.service"),
            ("serviceradar-bumblebee-scan.timer", "//addons/bumblebee-scan:serviceradar-bumblebee-scan.timer"),
        ],
        "data_entries": [
            ("bumblebee-scan.json", "//addons/bumblebee-scan:bumblebee-scan.json"),
        ],
        "pushed_artifact_tarball": True,
    },
    {
        # OSV ScaLibr-backed endpoint software inventory scanner add-on. This is
        # a scanner-specific package that still emits the generic endpoint
        # inventory spool and scanner:v1 metadata contracts; no agent/core
        # scanner branches are required.
        "name": "scalibr_endpoint_inventory_addon_bundle",
        "addon_id": "scalibr-endpoint-inventory",
        "repository_name": "serviceradar-addon-scalibr-endpoint-inventory",
        "language": "go",
        "binary": "//go/cmd/scalibr-endpoint-inventory:scalibr_endpoint_inventory",
        "binary_name": "serviceradar-scalibr-endpoint-inventory",
        "platforms": [
            ("linux", "amd64"),
            ("linux", "arm64"),
        ],
        "manifest_entries": [
            ("addon.yaml", "//addons/scalibr-endpoint-inventory:addon.yaml"),
            ("config.schema.json", "//addons/scalibr-endpoint-inventory:config.schema.json"),
        ],
        "unit_entries": [
            ("serviceradar-scalibr-endpoint-inventory.service", "//addons/scalibr-endpoint-inventory:serviceradar-scalibr-endpoint-inventory.service"),
            ("serviceradar-scalibr-endpoint-inventory.timer", "//addons/scalibr-endpoint-inventory:serviceradar-scalibr-endpoint-inventory.timer"),
        ],
        "data_entries": [
            ("scalibr-endpoint-inventory.json", "//addons/scalibr-endpoint-inventory:scalibr_endpoint_inventory_runtime_config"),
        ],
        "pushed_artifact_tarball": True,
    },
    {
        # RDP per-session helper add-on. This replaces the old RDP-flavored
        # managed-agent runtime archive: the base agent stays core-only, while
        # remote-access resolves this staged ephemeral helper on demand.
        "name": "rdp_adapter_addon_bundle",
        "addon_id": "rdp",
        "repository_name": "serviceradar-addon-rdp-adapter",
        "language": "rust",
        "binary": "//rust/rdp-adapter:rdp_adapter_ironrdp_connector_experimental",
        "binary_name": "serviceradar-rdp-adapter",
        "platforms": [
            ("linux", "amd64"),
        ],
        "manifest_entries": [
            ("addon.yaml", "//addons/rdp-adapter:addon.yaml"),
            ("config.schema.json", "//addons/rdp-adapter:config.schema.json"),
        ],
        "pushed_artifact_tarball": True,
    },
    {
        # Edge anomaly detection add-on (move-anomaly-detection-to-edge). Consumes
        # the agent's local metric feed (metric-feed:v1) and emits OCSF Detection
        # Finding verdicts (native-telemetry:v1) with a signal schema for display.
        "name": "anomaly_addon_bundle",
        "addon_id": "anomaly",
        "repository_name": "serviceradar-addon-anomaly",
        "language": "rust",
        "binary": "//rust/anomaly-addon:serviceradar-anomaly-addon",
        "binary_name": "serviceradar-anomaly-addon",
        "platforms": [
            ("linux", "amd64"),
        ],
        "manifest_entries": [
            ("addon.yaml", "//addons/anomaly-addon:addon.yaml"),
            ("config.schema.json", "//addons/anomaly-addon:config.schema.json"),
            ("schemas/detection_finding.schema.json", "//addons/anomaly-addon:schemas/detection_finding.schema.json"),
            ("display/detection_finding.display.json", "//addons/anomaly-addon:display/detection_finding.display.json"),
            ("schemas/capacity_shed.schema.json", "//addons/anomaly-addon:schemas/capacity_shed.schema.json"),
            ("display/capacity_shed.display.json", "//addons/anomaly-addon:display/capacity_shed.display.json"),
        ],
        "pushed_artifact_tarball": True,
    },
    {
        # Edge OTEL collector add-on (refactor-otel-signal-correlation edge-relay
        # plan). Runs as an unprivileged agent-sidecar (otlp-relay:v1): local
        # OTLP/gRPC + OTLP/HTTP listeners, durable on-disk relay spool, and the
        # acked AddonService.RelayOtlp stream to the supervising agent. The
        # //rust/otel-addon binary is packaged here as a signed per-arch
        # pushed-artifact bundle. No `unit_entries`/`data_entries`: the sidecar is
        # agent-supervised (not systemd) and ships no extra runtime files beyond
        # its manifest + config schema.
        "name": "otel_collector_addon_bundle",
        "addon_id": "otel-collector",
        "repository_name": "serviceradar-addon-otel-collector",
        "language": "rust",
        "binary": "//rust/otel-addon:serviceradar-otel-addon",
        "binary_name": "serviceradar-otel-addon",
        "platforms": [
            ("linux", "amd64"),
        ],
        "manifest_entries": [
            ("addon.yaml", "//addons/otel-collector:addon.yaml"),
            ("config.schema.json", "//addons/otel-collector:config.schema.json"),
        ],
        "pushed_artifact_tarball": True,
    },
]
