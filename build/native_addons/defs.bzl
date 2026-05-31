"""Bazel rules for building first-party native add-on bundles (issue 3425).

Mirrors build/wasm_plugins/defs.bzl but the per-bundle payload is a set of
per-architecture native Go binaries (cross-compiled with rules_go's
go_cross_binary) instead of a single Wasm module. Each bundle assembles
{addon.yaml, config.schema.json, bin/<os>/<arch>/<binary>} into a deterministic
zip + sha256 + metadata.json (with a per-arch artifacts[] list) that the signing
and discovery-index tooling consumes, reusing the same signing key/infra as Wasm
plugins.

A bundle that sets "pushed_artifact_tarball": True additionally emits, per
platform, a deterministic gzip tarball ({name}.{os}.{arch}.tar.gz) that flattens
the binary (0755) plus the manifest/config and any "unit_entries" systemd units
(0644) into single-segment members. That tarball is the pushed-artifact payload
the agent fetches, verifies, and extracts under current/ (it auto-detects a gzip
tarball vs. a bare binary); its name + sha256 are recorded per-arch in
metadata.json alongside the bare-binary sha256.
"""

load("@io_bazel_rules_go//go:def.bzl", "go_cross_binary")

_ADDON_ARTIFACT_TYPE = "application/vnd.serviceradar.native-addon.bundle.v1+zip"
_BUNDLE_MEDIA_TYPE = "application/zip"
_UPLOAD_SIGNATURE_MEDIA_TYPE = "application/vnd.serviceradar.native-addon.upload-signature.v1+json"

def declare_native_addon_targets(addon_bundles):
    bundle_outputs = []
    metadata_outputs = []
    binary_outputs = []
    tarball_outputs = []

    for bundle in addon_bundles:
        name = bundle["name"]
        zip_out = "{}.zip".format(name)
        sha_out = "{}.sha256".format(name)
        metadata_out = "{}.metadata.json".format(name)

        srcs = []
        artifact_args = []
        tarball_args = []
        tarball_outs = []

        # When set, also emit a per-arch pushed-artifact gzip tarball (binary +
        # manifest/config + units) the agent fetches and extracts under current/.
        produce_tarball = bundle.get("pushed_artifact_tarball", False)

        # "go" (default) cross-compiles a go_binary per arch; "rust" packages the
        # rules_rust rust_binary directly (no go_cross_binary analogue), reusing
        # the single configured-platform binary for each declared platform path.
        language = bundle.get("language", "go")

        for (os, arch) in bundle["platforms"]:
            if language == "rust":
                label = bundle["binary"]
            else:
                cross_name = "{}_{}_{}".format(name, os, arch)
                go_cross_binary(
                    name = cross_name,
                    target = bundle["binary"],
                    platform = "@io_bazel_rules_go//go/toolchain:{}_{}".format(os, arch),
                    visibility = ["//visibility:public"],
                )
                label = ":" + cross_name

            if label not in srcs:
                srcs.append(label)

            # rust bundles reuse one binary label across every declared platform, so
            # dedup before aggregating into the `all_binaries` filegroup (a duplicate
            # label in filegroup srcs is a hard package-load error).
            if label not in binary_outputs:
                binary_outputs.append(label)
            archive_path = "bin/{}/{}/{}".format(os, arch, bundle["binary_name"])
            artifact_args.append(
                "--artifact {}/{}={}=$(location {})".format(os, arch, archive_path, label),
            )
            if produce_tarball:
                tarball_out = "{}.{}.{}.tar.gz".format(name, os, arch)
                tarball_outs.append(tarball_out)
                tarball_args.append(
                    "--tarball {}/{}=$(location {})".format(os, arch, tarball_out),
                )

        entry_args = []

        # manifest_entries (addon.yaml + config schema) plus optional unit_entries
        # (systemd .service/.timer units) ship in the zip bundle and, for a
        # pushed-artifact tarball, are extracted flat next to the binary.
        for (archive_path, label) in bundle["manifest_entries"] + bundle.get("unit_entries", []):
            if label not in srcs:
                srcs.append(label)
            entry_args.append("--entry {}=$(location {})".format(archive_path, label))

        native.genrule(
            name = name,
            srcs = srcs,
            outs = [zip_out, sha_out, metadata_out] + tarball_outs,
            cmd = " ".join([
                "$(location :assemble_addon_bundle.py)",
                "--bundle-out",
                "$(location {})".format(zip_out),
                "--sha-out",
                "$(location {})".format(sha_out),
                "--metadata-out",
                "$(location {})".format(metadata_out),
                "--addon-id",
                bundle["addon_id"],
                "--repository-name",
                bundle["repository_name"],
                "--artifact-type",
                _ADDON_ARTIFACT_TYPE,
                "--bundle-media-type",
                _BUNDLE_MEDIA_TYPE,
                "--upload-signature-media-type",
                _UPLOAD_SIGNATURE_MEDIA_TYPE,
            ] + artifact_args + entry_args + tarball_args),
            local = True,
            tags = [
                "no-remote",
                "no-sandbox",
            ],
            tools = [":assemble_addon_bundle.py"],
            visibility = ["//visibility:public"],
        )

        native.filegroup(
            name = "{}_zip".format(name),
            srcs = [zip_out],
            visibility = ["//visibility:public"],
        )
        native.filegroup(
            name = "{}_sha256".format(name),
            srcs = [sha_out],
            visibility = ["//visibility:public"],
        )
        native.filegroup(
            name = "{}_metadata".format(name),
            srcs = [metadata_out],
            visibility = ["//visibility:public"],
        )

        bundle_outputs.append(":{}_zip".format(name))
        metadata_outputs.append(":{}_metadata".format(name))

        if produce_tarball:
            native.filegroup(
                name = "{}_tarballs".format(name),
                srcs = tarball_outs,
                visibility = ["//visibility:public"],
            )
            tarball_outputs.append(":{}_tarballs".format(name))

    native.filegroup(
        name = "all_binaries",
        srcs = binary_outputs,
        visibility = ["//visibility:public"],
    )

    native.filegroup(
        name = "all_bundles",
        srcs = bundle_outputs,
        visibility = ["//visibility:public"],
    )

    native.filegroup(
        name = "all_tarballs",
        srcs = tarball_outputs,
        visibility = ["//visibility:public"],
    )

    native.filegroup(
        name = "all_metadata",
        srcs = metadata_outputs,
        visibility = ["//visibility:public"],
    )
