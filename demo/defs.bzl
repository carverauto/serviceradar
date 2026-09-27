"""Build, bundle and publish macros for showcase demo plugins.

A demo plugin is a TinyGo module in the demo Go workspace (demo/go.work).
Its go.mod pins the released serviceradar-sdk-go tag and go.sum records the
checksum, as for first-party plugins; the external modules are vendored once
for the whole workspace (`go work vendor` into demo/vendor), so the build runs
with -mod=vendor and needs no proxy or network. In-repo modules (simkit,
pluginkit) resolve from their directories and are never copied. Go refuses a
vendored build whose vendor/modules.txt disagrees with any go.mod, so a stale
vendor tree fails the build. Nothing here is referenced by //build/wasm_plugins, the
Helm chart or release tooling (//demo/fence checks that).

Signing is deliberately NOT a build action: the demo-only private key must
never become an action input, so the bundle is signed at publish time by
`bazel run :<name>_publish` (see //demo/tools/demopublish).
"""

load("@io_bazel_rules_go//go:def.bzl", "go_binary")

_WASM_ARTIFACT_TYPE = "application/vnd.serviceradar.wasm-plugin.bundle.v1+zip"
_BUNDLE_MEDIA_TYPE = "application/zip"
_UPLOAD_SIGNATURE_MEDIA_TYPE = "application/vnd.serviceradar.wasm-plugin.upload-signature.v1+json"

def demo_wasm_plugin(
        name,
        main,
        srcs,
        manifest,
        config_schema,
        extra_entries = {},
        visibility = None):
    """Builds a demo plugin's Wasm binary and its upload bundle.

    Targets:
      :<name>_wasm        the TinyGo wasip1 binary (<name>.wasm)
      :<name>_bundle      <name>_bundle.zip, .sha256 and .metadata.json
      :<name>_bundle_zip  the zip alone, for publish targets and tests

    Args:
      name: target prefix.
      main: the file holding the exported entrypoint; its directory is the
        Go module that gets compiled.
      srcs: the plugin module's other non-test sources. go.mod, go.sum and
        the workspace (//demo:workspace_srcs) are added automatically.
      manifest: plugin.yaml.
      config_schema: config.schema.json.
      extra_entries: additional {archive path: label} bundle entries.
      visibility: visibility of the generated targets.
    """
    visibility = visibility or ["//demo:__subpackages__"]

    native.genrule(
        name = name + "_wasm",
        srcs = [main] + srcs + ["go.mod", "go.sum", "//demo:workspace_srcs"],
        outs = [name + ".wasm"],
        cmd = " ".join([
            # Workspace mode rejects -mod=mod; the script honours an exported
            # GOFLAGS over its own per-plugin vendor/ detection.
            "GOFLAGS=-mod=vendor",
            "$(location //build/wasm_plugins:build_wasm_binary.sh)",
            "--tinygo $(location //build/wasm_plugins:selected_tinygo)",
            "--go-bin $(location //build/wasm_plugins:selected_go)",
            "--main-go $(location {})".format(main),
            "--out $@",
        ]),
        tools = [
            "//build/wasm_plugins:build_wasm_binary.sh",
            "//build/wasm_plugins:selected_go",
            "//build/wasm_plugins:selected_tinygo",
            "//build/wasm_plugins:selected_tinygo_tree",
        ],
        visibility = visibility,
    )

    entries = [
        ("plugin.yaml", manifest),
        ("plugin.wasm", ":" + name + "_wasm"),
        ("config.schema.json", config_schema),
    ] + [(path, label) for path, label in extra_entries.items()]

    zip_out = name + "_bundle.zip"
    sha_out = name + "_bundle.sha256"
    metadata_out = name + "_bundle.metadata.json"
    copy_parts = []
    entry_args = []
    entry_srcs = []
    for index, (archive_path, label) in enumerate(entries):
        if label not in entry_srcs:
            entry_srcs.append(label)

        # Sandbox inputs are symlinks and the assembler rejects symlinks, so
        # stage dereferenced copies (the same approach //build/wasm_plugins uses).
        staged = "$(@D)/{}.entry-{}".format(name, index)
        copy_parts.append("cp -L $(location {}) {}".format(label, staged))
        entry_args.append("--entry {}={}".format(archive_path, staged))

    native.genrule(
        name = name + "_bundle",
        srcs = entry_srcs,
        outs = [zip_out, sha_out, metadata_out],
        cmd = " ".join([
            " && ".join(copy_parts),
            "&&",
            "$(location //build/wasm_plugins:assemble_bundle.py)",
            "--bundle-out $(location {})".format(zip_out),
            "--sha-out $(location {})".format(sha_out),
            "--metadata-out $(location {})".format(metadata_out),
            "--derive-from-manifest",
            "--artifact-type", _WASM_ARTIFACT_TYPE,
            "--bundle-media-type", _BUNDLE_MEDIA_TYPE,
            "--upload-signature-media-type", _UPLOAD_SIGNATURE_MEDIA_TYPE,
        ] + entry_args),
        tools = ["//build/wasm_plugins:assemble_bundle.py"],
        visibility = visibility,
    )

    native.filegroup(
        name = name + "_bundle_zip",
        srcs = [zip_out],
        visibility = visibility,
    )

def demo_publish(name, bundle, dashboard = None, visibility = None):
    """A `bazel run` target that publishes a demo to a ServiceRadar instance.

    The instance, operator token, signing key and agent come from the client
    environment and flags at run time, never from build inputs:

      SERVICERADAR_INSTANCE=https://demo.example.com \\
      SERVICERADAR_TOKEN=... \\
      PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY_FILE=~/.../demo-plugin-signing.key \\
      PLUGIN_UPLOAD_SIGNING_KEY_ID=serviceradar-demo-v1 \\
      bazel run //demo/<demo>:<name> -- --agent-uid <agent>

    Args:
      name: the run target name.
      bundle: the plugin bundle zip (a :<plugin>_bundle_zip target).
      dashboard: optional directory target holding a built dashboard's
        manifest.json and renderer.js.
      visibility: target visibility.
    """
    args = [
        "--bundle",
        "$(rootpath {})".format(bundle),
        "--signature-tool",
        "$(rootpath //build/wasm_plugins:upload_signature_tool)",
    ]
    data = [
        bundle,
        "//build/wasm_plugins:upload_signature_tool",
    ]
    if dashboard:
        args += ["--dashboard-dir", "$(rootpath {})".format(dashboard)]
        data.append(dashboard)

    go_binary(
        name = name,
        embed = ["//demo/tools/demopublish:demopublish_lib"],
        args = args,
        data = data,
        visibility = visibility or ["//demo:__subpackages__"],
    )
