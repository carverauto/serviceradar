"""In-repo inventory of first-party native agent add-ons (issue 3425).

Mirrors build/wasm_plugins/plugin_inventory.bzl. Each entry declares an add-on
bundle: the binary to package per architecture, the manifest files to ship, and
the target platforms. build/native_addons/defs.bzl loops this list to emit
per-arch binaries + a deterministic signed-able bundle (zip + sha256 +
metadata.json) per add-on, analogous to the Wasm plugin bundles.

Each entry's "language" selects how the per-arch binary is produced:
  - "go"   -> the go_binary is cross-compiled per arch via go_cross_binary.
  - "rust" -> the rust_binary is packaged directly (rules_rust has no
              go_cross_binary analogue wired in this repo yet), so every
              declared platform reuses the single configured-platform binary.
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
    },
]
