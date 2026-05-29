"""In-repo inventory of first-party native agent add-ons (issue 3425).

Mirrors build/wasm_plugins/plugin_inventory.bzl. Each entry declares an add-on
bundle: the go_binary to cross-compile per architecture, the manifest files to
ship, and the target platforms. build/native_addons/defs.bzl loops this list to
emit per-arch binaries + a deterministic signed-able bundle (zip + sha256 +
metadata.json) per add-on, analogous to the Wasm plugin bundles.
"""

ADDON_BUNDLES = [
    {
        "name": "sample_addon_bundle",
        "addon_id": "sample",
        "repository_name": "serviceradar-addon-sample",
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
]
