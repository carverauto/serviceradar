"""Helpers for publishing OCI images to GHCR."""

load("@rules_oci//oci:defs.bzl", "oci_push")
load("@aspect_bazel_lib//lib:expand_template.bzl", "expand_template")
load("//docker/images:container_tags.bzl", "immutable_push_tags")
load("@rules_multirun//:defs.bzl", "command", "multirun")

GHCR_PUSH_TARGETS = [
    {"image": "core_image_amd64", "repository": "ghcr.io/carverauto/serviceradar-core"},
    {"image": "agent_image_amd64", "repository": "ghcr.io/carverauto/serviceradar-agent"},
    {"image": "db_event_writer_image_amd64", "repository": "ghcr.io/carverauto/serviceradar-db-event-writer"},
    {"image": "mapper_image_amd64", "repository": "ghcr.io/carverauto/serviceradar-mapper"},
    {"image": "datasvc_image_amd64", "repository": "ghcr.io/carverauto/serviceradar-datasvc"},
    {"image": "flowgger_image_amd64", "repository": "ghcr.io/carverauto/serviceradar-flowgger"},
    {"image": "trapd_image_amd64", "repository": "ghcr.io/carverauto/serviceradar-trapd"},
    {"image": "otel_image_amd64", "repository": "ghcr.io/carverauto/serviceradar-otel"},
    {"image": "snmp_checker_image_amd64", "repository": "ghcr.io/carverauto/serviceradar-snmp-checker"},
    {"image": "rperf_client_image_amd64", "repository": "ghcr.io/carverauto/serviceradar-rperf-client"},
    {"image": "poller_image_amd64", "repository": "ghcr.io/carverauto/serviceradar-poller"},
    {"image": "sync_image_amd64", "repository": "ghcr.io/carverauto/serviceradar-sync"},
    {"image": "zen_image_amd64", "repository": "ghcr.io/carverauto/serviceradar-zen"},
    {"image": "config_updater_image_amd64", "repository": "ghcr.io/carverauto/serviceradar-config-updater"},
    {"image": "nginx_image_amd64", "repository": "ghcr.io/carverauto/serviceradar-nginx"},
    {"image": "web_image_amd64", "repository": "ghcr.io/carverauto/serviceradar-web", "digest_label": ":web_image_base_amd64.digest"},
    {"image": "srql_image_amd64", "repository": "ghcr.io/carverauto/serviceradar-srql"},
    {"image": "kong_config_image_amd64", "repository": "ghcr.io/carverauto/serviceradar-kong-config"},
    {"image": "cert_generator_image_amd64", "repository": "ghcr.io/carverauto/serviceradar-cert-generator"},
    {"image": "tools_image_amd64", "repository": "ghcr.io/carverauto/serviceradar-tools"},
    {
        "image": "cnpg_image_amd64",
        "repository": "ghcr.io/carverauto/serviceradar-cnpg",
        "static_tags": ["16.6.0-sr1"],
    },
]


def declare_ghcr_push_targets():
    """Registers oci_push targets and helper binaries for GHCR publishing."""

    push_command_targets = []

    for target in GHCR_PUSH_TARGETS:
        image = target["image"]
        repository = target["repository"]
        digest_label = target.get("digest_label", ":{}.digest".format(image))
        static_tags = ["latest"] + target.get("static_tags", [])
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
            static_tags = static_tags,
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
