"""Helpers for publishing OCI images to GHCR."""

load("@rules_oci//oci:defs.bzl", "oci_push")
load("@aspect_bazel_lib//lib:expand_template.bzl", "expand_template")
load("//docker/images:container_tags.bzl", "immutable_push_tags")
load("@rules_multirun//:defs.bzl", "command", "multirun")

GHCR_PUSH_TARGETS = [
    ("core_image_amd64", "ghcr.io/carverauto/serviceradar-core"),
    ("agent_image_amd64", "ghcr.io/carverauto/serviceradar-agent"),
    ("db_event_writer_image_amd64", "ghcr.io/carverauto/serviceradar-db-event-writer"),
    ("mapper_image_amd64", "ghcr.io/carverauto/serviceradar-mapper"),
    ("datasvc_image_amd64", "ghcr.io/carverauto/serviceradar-datasvc"),
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
    ("web_image_amd64", "ghcr.io/carverauto/serviceradar-web", ":web_image_base_amd64.digest"),
    ("srql_image_amd64", "ghcr.io/carverauto/serviceradar-srql"),
    ("kong_config_image_amd64", "ghcr.io/carverauto/serviceradar-kong-config"),
    ("cert_generator_image_amd64", "ghcr.io/carverauto/serviceradar-cert-generator"),
    ("tools_image_amd64", "ghcr.io/carverauto/serviceradar-tools"),
    ("proton_image_amd64", "ghcr.io/carverauto/serviceradar-proton"),
]


def declare_ghcr_push_targets():
    """Registers oci_push targets and helper binaries for GHCR publishing."""

    push_command_targets = []

    for target in GHCR_PUSH_TARGETS:
        if len(target) == 2:
            image, repository = target
            digest_label = ":{}.digest".format(image)
        else:
            image, repository, digest_label = target
        expand_template(
            name = "{}_commit_tag".format(image),
            template = ["sha-{{STABLE_COMMIT_SHA}}"],
            substitutions = {"{{STABLE_COMMIT_SHA}}": "dev"},
            stamp = 1,
            stamp_substitutions = {"{{STABLE_COMMIT_SHA}}": "{{STABLE_COMMIT_SHA}}"},
            out = "{}_commit_tag.txt".format(image),
        )

        immutable_push_tags(
            name = "{}_push_tags".format(image),
            digest = digest_label,
            commit_tags = ":{}_commit_tag".format(image),
            static_tags = ["latest"],
        )

        oci_push(
            name = "{}_push".format(image),
            image = ":{}".format(image),
            repository = repository,
            remote_tags = ":{}_push_tags".format(image),
            visibility = ["//visibility:public"],
        )

        command_name = "{}_push_cmd".format(image)
        command(
            name = command_name,
            command = ":{}_push".format(image),
            description = "Push {}".format(repository),
        )
        push_command_targets.append(":{}".format(command_name))

    multirun(
        name = "push_all",
        commands = push_command_targets,
        jobs = 0,
        visibility = ["//visibility:public"],
    )
