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
    {
        "name": "sample_addon_bundle",
        "addon_id": "sample",
        "repository_name": "serviceradar-addon-sample",
        "language": "go",
        "binary": "//go/cmd/serviceradar-sample-addon:serviceradar-sample-addon",
        "binary_name": "serviceradar-sample-addon",
        "platforms": [
            ("linux", "amd64"),
            ("linux", "arm64"),
        ],
        "manifest_entries": [
            ("addon.yaml", "//addons/sample-addon:addon.yaml"),
            ("config.schema.json", "//addons/sample-addon:config.schema.json"),
        ],
        # Also emit the per-arch pushed-artifact gzip tarball (binary + manifest +
        # config schema) the agent fetches/verifies/extracts. unit_entries would add
        # systemd units here for a systemd-supervised add-on (e.g. netprobe).
        "pushed_artifact_tarball": True,
    },
    {
        # Rust reference add-on (issue 3425). Proves the framework's polyglot
        # claim: a Rust binary built with rust/addon-sdk, supervised by the same
        # agent go-plugin client and packaged/signed identically to the Go
        # sample. The manifest's id/capabilities/binary match the values the
        # binary reports from its own Info() RPC.
        "name": "rust_sample_addon_bundle",
        "addon_id": "rust-sample",
        "repository_name": "serviceradar-addon-rust-sample",
        "language": "rust",
        "binary": "//rust/addon-sdk:serviceradar-rust-sample-addon",
        "binary_name": "serviceradar-rust-sample-addon",
        "platforms": [
            ("linux", "amd64"),
            ("linux", "arm64"),
        ],
        "manifest_entries": [
            ("addon.yaml", "//addons/rust-sample-addon:addon.yaml"),
            ("config.schema.json", "//addons/rust-sample-addon:config.schema.json"),
        ],
        "pushed_artifact_tarball": True,
    },
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
        # Endpoint software inventory add-on. Ships the root-owned package
        # inventory collector plus a systemd timer; the non-root agent ingests
        # only the sanitized CycloneDX spool payload.
        "name": "endpoint_inventory_addon_bundle",
        "addon_id": "endpoint-inventory",
        "repository_name": "serviceradar-addon-endpoint-inventory",
        "language": "go",
        "binary": "//go/cmd/endpoint-inventory:endpoint_inventory",
        "binary_name": "serviceradar-endpoint-inventory",
        "platforms": [
            ("linux", "amd64"),
            ("linux", "arm64"),
        ],
        "manifest_entries": [
            ("addon.yaml", "//addons/endpoint-inventory:addon.yaml"),
            ("config.schema.json", "//addons/endpoint-inventory:config.schema.json"),
        ],
        "unit_entries": [
            ("serviceradar-endpoint-inventory.service", "//addons/endpoint-inventory:serviceradar-endpoint-inventory.service"),
            ("serviceradar-endpoint-inventory.timer", "//addons/endpoint-inventory:serviceradar-endpoint-inventory.timer"),
        ],
        "data_entries": [
            ("endpoint-inventory.json", "//addons/endpoint-inventory:endpoint-inventory.json"),
        ],
        "pushed_artifact_tarball": True,
    },
]
