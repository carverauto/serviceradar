WASM_BUILD_TARGETS = [
    {
        "name": "hello_wasm",
        "srcs": ["//go/tools/wasm-plugin-harness:srcs"],
        "main_go": "//go/tools/wasm-plugin-harness:main.go",
        "tags": ["tinygo"],
    },
    {
        "name": "axis_camera",
        "srcs": ["//go/cmd/wasm-plugins/axis:srcs"],
        "main_go": "//go/cmd/wasm-plugins/axis:main.go",
        "tags": [],
    },
    {
        "name": "unifi_protect_camera",
        "srcs": ["//go/cmd/wasm-plugins/unifi-protect:srcs"],
        "main_go": "//go/cmd/wasm-plugins/unifi-protect:main.go",
        "tags": [],
    },
    {
        "name": "dusk_checker",
        "srcs": ["//go/cmd/wasm-plugins/dusk-checker:srcs"],
        "main_go": "//go/cmd/wasm-plugins/dusk-checker:main.go",
        "tags": [],
    },
]

WASM_PLUGIN_BUNDLES = [
    {
        "name": "hello_wasm_bundle",
        "plugin_id": "hello-wasm",
        "repository_name": "wasm-plugin-hello-wasm",
        "wasm_target": ":hello_wasm_wasm",
        "entries": [
            ("plugin.yaml", "//go/tools/wasm-plugin-harness:plugin.yaml"),
            ("plugin.wasm", ":hello_wasm_wasm"),
            ("config.schema.json", "//go/tools/wasm-plugin-harness:config.schema.json"),
            ("display_contract.json", "//go/tools/wasm-plugin-harness:display_contract.json"),
        ],
    },
    {
        "name": "axis_camera_bundle",
        "plugin_id": "axis-camera",
        "repository_name": "wasm-plugin-axis-camera",
        "wasm_target": ":axis_camera_wasm",
        "entries": [
            ("plugin.yaml", "//go/cmd/wasm-plugins/axis:plugin.yaml"),
            ("plugin.wasm", ":axis_camera_wasm"),
            ("config.schema.json", "//go/cmd/wasm-plugins/axis:config.schema.json"),
        ],
    },
    {
        "name": "axis_camera_stream_bundle",
        "plugin_id": "axis-camera-stream",
        "repository_name": "wasm-plugin-axis-camera-stream",
        "wasm_target": ":axis_camera_wasm",
        "entries": [
            ("plugin.yaml", "//go/cmd/wasm-plugins/axis:plugin.stream.yaml"),
            ("plugin.wasm", ":axis_camera_wasm"),
            ("config.schema.json", "//go/cmd/wasm-plugins/axis:config.stream.schema.json"),
        ],
    },
    {
        "name": "unifi_protect_camera_bundle",
        "plugin_id": "unifi-protect-camera",
        "repository_name": "wasm-plugin-unifi-protect-camera",
        "wasm_target": ":unifi_protect_camera_wasm",
        "entries": [
            ("plugin.yaml", "//go/cmd/wasm-plugins/unifi-protect:plugin.yaml"),
            ("plugin.wasm", ":unifi_protect_camera_wasm"),
            ("config.schema.json", "//go/cmd/wasm-plugins/unifi-protect:config.schema.json"),
        ],
    },
    {
        "name": "unifi_protect_camera_stream_bundle",
        "plugin_id": "unifi-protect-camera-stream",
        "repository_name": "wasm-plugin-unifi-protect-camera-stream",
        "wasm_target": ":unifi_protect_camera_wasm",
        "entries": [
            ("plugin.yaml", "//go/cmd/wasm-plugins/unifi-protect:plugin.stream.yaml"),
            ("plugin.wasm", ":unifi_protect_camera_wasm"),
            ("config.schema.json", "//go/cmd/wasm-plugins/unifi-protect:config.stream.schema.json"),
        ],
    },
    {
        "name": "dusk_checker_bundle",
        "plugin_id": "dusk-checker",
        "repository_name": "wasm-plugin-dusk-checker",
        "wasm_target": ":dusk_checker_wasm",
        "entries": [
            ("plugin.yaml", "//go/cmd/wasm-plugins/dusk-checker:plugin.yaml"),
            ("plugin.wasm", ":dusk_checker_wasm"),
            ("config.schema.json", "//go/cmd/wasm-plugins/dusk-checker:config.schema.json"),
        ],
    },
]
