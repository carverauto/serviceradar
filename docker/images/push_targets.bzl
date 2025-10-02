"""Helpers for publishing OCI images to GHCR."""

load("@rules_oci//oci:defs.bzl", "oci_push")
load("@aspect_bazel_lib//lib:expand_template.bzl", "expand_template")
load("@bazel_skylib//rules:write_file.bzl", "write_file")

GHCR_PUSH_TARGETS = [
    ("core_image_amd64", "ghcr.io/carverauto/serviceradar-core"),
    ("agent_image_amd64", "ghcr.io/carverauto/serviceradar-agent"),
    ("db_event_writer_image_amd64", "ghcr.io/carverauto/serviceradar-db-event-writer"),
    ("mapper_image_amd64", "ghcr.io/carverauto/serviceradar-mapper"),
    ("kv_image_amd64", "ghcr.io/carverauto/serviceradar-kv"),
    ("flowgger_image_amd64", "ghcr.io/carverauto/serviceradar-flowgger"),
    ("trapd_image_amd64", "ghcr.io/carverauto/serviceradar-trapd"),
    ("otel_image_amd64", "ghcr.io/carverauto/serviceradar-otel"),
    ("snmp_checker_image_amd64", "ghcr.io/carverauto/serviceradar-snmp-checker"),
    ("rperf_client_image_amd64", "ghcr.io/carverauto/serviceradar-rperf-client"),
    ("poller_image_amd64", "ghcr.io/carverauto/serviceradar-poller"),
    ("sync_image_amd64", "ghcr.io/carverauto/serviceradar-sync"),
    ("zen_image_amd64", "ghcr.io/carverauto/serviceradar-zen"),
    ("config_updater_image_amd64", "ghcr.io/carverauto/serviceradar-config-updater"),
    ("nginx_image_amd64", "ghcr.io/carverauto/serviceradar-nginx"),
    ("web_image_amd64", "ghcr.io/carverauto/serviceradar-web"),
    ("srql_image_amd64", "ghcr.io/carverauto/serviceradar-srql"),
    ("kong_config_image_amd64", "ghcr.io/carverauto/serviceradar-kong-config"),
    ("cert_generator_image_amd64", "ghcr.io/carverauto/serviceradar-cert-generator"),
    ("tools_image_amd64", "ghcr.io/carverauto/serviceradar-tools"),
    ("proton_image_amd64", "ghcr.io/carverauto/serviceradar-proton"),
]


def declare_ghcr_push_targets():
    """Registers oci_push targets and helper binaries for GHCR publishing."""

    for image, repository in GHCR_PUSH_TARGETS:
        expand_template(
            name = "{}_push_tags".format(image),
            template = [
                "latest",
                "sha-{{STABLE_COMMIT_SHA}}",
            ],
            substitutions = {"{{STABLE_COMMIT_SHA}}": "dev"},
            stamp = 1,
            stamp_substitutions = {"{{STABLE_COMMIT_SHA}}": "{{STABLE_COMMIT_SHA}}"},
            out = "{}_push_tags.txt".format(image),
        )

        oci_push(
            name = "{}_push".format(image),
            image = ":{}".format(image),
            repository = repository,
            remote_tags = ":{}_push_tags".format(image),
            visibility = ["//visibility:public"],
        )

    write_file(
        name = "ghcr_push_targets",
        out = "ghcr_push_targets.txt",
        content = [
            "serviceradar/docker/images/{}_push".format(image)
            for image, _ in GHCR_PUSH_TARGETS
        ],
    )

    native.sh_binary(
        name = "push_all",
        srcs = ["push_all.sh"],
        data = [
            ":ghcr_push_targets",
        ] + [
            ":{}_push".format(image)
            for image, _ in GHCR_PUSH_TARGETS
        ],
        visibility = ["//visibility:public"],
    )
