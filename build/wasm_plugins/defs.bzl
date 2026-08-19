load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

_WASM_ARTIFACT_TYPE = "application/vnd.serviceradar.wasm-plugin.bundle.v1+zip"
_BUNDLE_MEDIA_TYPE = "application/zip"
_UPLOAD_SIGNATURE_MEDIA_TYPE = "application/vnd.serviceradar.wasm-plugin.upload-signature.v1+json"


def declare_wasm_targets(build_targets, plugin_bundles):
    wasm_outputs = []
    metadata_outputs = []
    bundle_outputs = []
    push_targets = []

    for build in build_targets:
        wasm_out = "{}.wasm".format(build["name"])
        cmd_parts = [
            "$(location :build_wasm_binary.sh)",
            # One toolchain, already selected for the exec platform by the aliases in this
            # package. build_wasm_binary.sh prefers an explicit --tinygo/--go-bin over its own
            # uname dispatch, so passing these two retires the eight per-platform flags without
            # touching the script.
            "--tinygo",
            "$(location //build/wasm_plugins:selected_tinygo)",
            "--go-bin",
            "$(location //build/wasm_plugins:selected_go)",
            "--main-go",
            "$(location {})".format(build["main_go"]),
            "--out",
            "$@",
        ]
        if build["tags"]:
            cmd_parts.extend([
                "--tags",
                "\"{}\"".format(",".join(build["tags"])),
            ])
        native.genrule(
            name = "{}_wasm".format(build["name"]),
            srcs = build["srcs"] + [build["main_go"]],
            outs = [wasm_out],
            cmd = " ".join(cmd_parts),
            tools = [
                ":build_wasm_binary.sh",
                "//build/wasm_plugins:selected_tinygo",
                "//build/wasm_plugins:selected_go",
                "//build/wasm_plugins:selected_tinygo_tree",
            ],
            visibility = ["//visibility:public"],
        )
        native.filegroup(
            name = "{}_wasm_file".format(build["name"]),
            srcs = [":{}_wasm".format(build["name"])],
            visibility = ["//visibility:public"],
        )
        wasm_outputs.append(":{}_wasm".format(build["name"]))

    for bundle in plugin_bundles:
        zip_out = "{}.zip".format(bundle["name"])
        sha_out = "{}.sha256".format(bundle["name"])
        metadata_out = "{}.metadata.json".format(bundle["name"])

        srcs = []
        entry_args = []
        copy_parts = []
        entry_index = 0
        for archive_path, label in bundle["entries"]:
            if label not in srcs:
                srcs.append(label)

            # Bazel represents source inputs as sandbox symlinks. Stage a
            # dereferenced copy so the assembler can retain its explicit
            # rejection of arbitrary symlink inputs outside Bazel.
            staged_entry = "$(@D)/{}.entry-{}".format(bundle["name"], entry_index)
            copy_parts.append("cp -L $(location {}) {}".format(label, staged_entry))
            entry_args.append("--entry {}={}".format(archive_path, staged_entry))
            entry_index += 1

        native.genrule(
            name = bundle["name"],
            srcs = srcs,
            outs = [zip_out, sha_out, metadata_out],
            cmd = " ".join([
                " && ".join(copy_parts),
                "&&",
                "$(location :assemble_bundle.py)",
                "--bundle-out", "$(location {})".format(zip_out),
                "--sha-out", "$(location {})".format(sha_out),
                "--metadata-out", "$(location {})".format(metadata_out),
                "--plugin-id", bundle["plugin_id"],
                "--repository-name", bundle["repository_name"],
                "--artifact-type", _WASM_ARTIFACT_TYPE,
                "--bundle-media-type", _BUNDLE_MEDIA_TYPE,
                "--upload-signature-media-type", _UPLOAD_SIGNATURE_MEDIA_TYPE,
            ] + entry_args),
            tools = [":assemble_bundle.py"],
            visibility = ["//visibility:public"],
        )

        native.filegroup(
            name = "{}_zip".format(bundle["name"]),
            srcs = [zip_out],
            visibility = ["//visibility:public"],
        )
        native.filegroup(
            name = "{}_sha256".format(bundle["name"]),
            srcs = [sha_out],
            visibility = ["//visibility:public"],
        )
        native.filegroup(
            name = "{}_metadata".format(bundle["name"]),
            srcs = [metadata_out],
            visibility = ["//visibility:public"],
        )

        sh_binary(
            name = "{}_push".format(bundle["name"]),
            srcs = [":publish_plugin.sh"],
            args = [
                "--bundle",
                "$(location :{}_zip)".format(bundle["name"]),
                "--metadata",
                "$(location :{}_metadata)".format(bundle["name"]),
                "--oras",
                "oras",
                "--upload-signature-tool",
                "$(location :upload_signature_tool)",
            ],
            data = [
                ":{}_zip".format(bundle["name"]),
                ":{}_metadata".format(bundle["name"]),
                ":upload_signature_tool",
            ],
            visibility = ["//visibility:public"],
        )

        bundle_outputs.append(":{}_zip".format(bundle["name"]))
        metadata_outputs.append(":{}_metadata".format(bundle["name"]))
        push_targets.append(":{}_push".format(bundle["name"]))

    native.filegroup(
        name = "all_wasm_binaries",
        srcs = wasm_outputs,
        visibility = ["//visibility:public"],
    )

    native.filegroup(
        name = "all_bundles",
        srcs = bundle_outputs,
        visibility = ["//visibility:public"],
    )

    native.filegroup(
        name = "all_metadata",
        srcs = metadata_outputs,
        visibility = ["//visibility:public"],
    )

    native.filegroup(
        name = "all_push_targets",
        srcs = push_targets,
        visibility = ["//visibility:public"],
    )
