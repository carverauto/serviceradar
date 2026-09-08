"""Bazel rules for building first-party native add-on bundles (issue 3425).

Mirrors build/wasm_plugins/defs.bzl but the per-bundle payload is a set of
per-architecture native binaries instead of a single Wasm module: Go add-ons are
cross-compiled with rules_go's go_cross_binary, Rust add-ons are rebuilt for the
matching musl platform via platform_transition_filegroup. Both paths yield
statically linked binaries with no glibc dependency. Each bundle assembles
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

load("@aspect_bazel_lib//lib:transitions.bzl", "platform_transition_filegroup")
load("@io_bazel_rules_go//go:def.bzl", "go_cross_binary")
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

# Rust add-on binaries are built against musl and statically linked, NOT against the
# executor image's glibc. Go add-ons already get this from --@io_bazel_rules_go//go/config:pure.
#
# Add-ons ship to customer machines whose glibc we do not control, so
# //build/native_addons:binary_portability_test enforces an EL9 baseline
# (MAX_GLIBC_VERSION = 2.34). The RBE executor is Ubuntu 24.04 with glibc 2.39, and a
# binary linked there picks up references no older glibc can satisfy -- concretely
# `__isoc23_sscanf` and `__isoc23_strtol` at GLIBC_2.38, which glibc's C23 headers bake
# in at COMPILE time. No linker or link-order change can remove them; ld.gold additionally
# left GLIBC_2.39 behind.
#
# That gate passed for a long time only because the add-on artifacts were remote-cache
# hits produced by the older oraclelinux:9 executor (glibc 2.34). Nothing had forced them
# to rebuild since the image moved to Ubuntu 24.04, so the gate was validating stale
# bytes; rebuilding at any commit -- including before the musl toolchain landed -- fails
# it. Building against musl removes the glibc baseline question entirely: the binaries
# report "no GLIBC symbol versions found" and run anywhere.
_MUSL_PLATFORMS = {
    ("linux", "amd64"): "//build/platforms:linux_x86_64_musl",
    ("linux", "arm64"): "//build/platforms:linux_aarch64_musl",
}

_ADDON_ARTIFACT_TYPE = "application/vnd.serviceradar.native-addon.bundle.v1+zip"
_BUNDLE_MEDIA_TYPE = "application/zip"
_UPLOAD_SIGNATURE_MEDIA_TYPE = "application/vnd.serviceradar.native-addon.upload-signature.v1+json"

def declare_native_addon_targets(addon_bundles):
    bundle_outputs = []
    metadata_outputs = []
    binary_outputs = []
    tarball_outputs = []
    push_targets = []

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

        # "go" (default) cross-compiles a go_binary per arch; "rust" rebuilds the
        # rules_rust rust_binary for the matching musl platform (see _MUSL_PLATFORMS).
        language = bundle.get("language", "go")

        for (os, arch) in bundle["platforms"]:
            if language == "rust":
                musl_platform = _MUSL_PLATFORMS.get((os, arch))
                if not musl_platform:
                    fail("no musl platform for ({}, {}) required by add-on bundle {}; add one to _MUSL_PLATFORMS".format(
                        os,
                        arch,
                        name,
                    ))

                # The transition is what makes the per-arch entry real. Before it, every
                # platform in a Rust bundle reused ONE binary label built for whatever the
                # ambient --platforms happened to be, so a bundle declaring both amd64 and
                # arm64 would have shipped the same binary twice under two arch paths.
                static_name = "{}_{}_{}_static".format(name, os, arch)
                platform_transition_filegroup(
                    name = static_name,
                    srcs = [bundle["binary"]],
                    target_platform = musl_platform,
                    visibility = ["//visibility:public"],
                )
                label = ":" + static_name
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

            # Labels are per-(os, arch) for both languages now, so this dedup is a
            # backstop rather than the load-bearing guard it was while Rust bundles
            # shared one binary label. A duplicate in filegroup srcs is a hard
            # package-load error, so keep it.
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

        # manifest_entries (addon.yaml + config schema), optional unit_entries (systemd
        # .service/.timer units), and optional data_entries (runtime data files such as the
        # netprobe eBPF object) ship in the zip bundle and, for a pushed-artifact tarball,
        # are extracted flat next to the binary.
        for (archive_path, label) in bundle["manifest_entries"] + bundle.get("unit_entries", []) + bundle.get("data_entries", []):
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

        # Publishes the OCI artifact: bundle zip + (per produce_tarball) each per-arch
        # tarball + its agent-release ed25519 signature. The bundle's integrity is
        # covered by the Cosign signature over the OCI artifact (no bundle-level
        # ed25519). Mirrors the wasm plugin _push targets.
        push_data = [
            ":{}_zip".format(name),
            ":{}_metadata".format(name),
            ":addon_artifact_signature_tool",
        ]
        if produce_tarball:
            push_data.append(":{}_tarballs".format(name))
        sh_binary(
            name = "{}_push".format(name),
            srcs = [":publish_addon.sh"],
            args = [
                "--bundle",
                "$(location :{}_zip)".format(name),
                "--metadata",
                "$(location :{}_metadata)".format(name),
                "--oras",
                "oras",
                "--artifact-signature-tool",
                "$(location :addon_artifact_signature_tool)",
            ],
            data = push_data,
            visibility = ["//visibility:public"],
        )
        push_targets.append(":{}_push".format(name))

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
        name = "all_push_targets",
        srcs = push_targets,
        visibility = ["//visibility:public"],
    )

    native.filegroup(
        name = "all_metadata",
        srcs = metadata_outputs,
        visibility = ["//visibility:public"],
    )
