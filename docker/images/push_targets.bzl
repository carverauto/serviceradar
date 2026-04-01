"""Helpers for publishing OCI images to the configured registry."""

load("@rules_oci//oci:defs.bzl", "oci_push")
load("@aspect_bazel_lib//lib:expand_template.bzl", "expand_template")
load("//docker/images:container_tags.bzl", "immutable_push_tags")
load("//docker/images:image_inventory.bzl", "PUBLISHABLE_IMAGES")
load("@rules_multirun//:defs.bzl", "command", "multirun")


def declare_ghcr_push_targets():
    """Registers oci_push targets and helper binaries for OCI publishing."""

    push_command_targets = []

    for target in PUBLISHABLE_IMAGES:
        image = target["image"]
        push_image = target.get("push_image", image)
        repository = target["repository"]
        digest_label = target.get("digest_label", ":{}.digest".format(push_image))
        static_tags = ["latest"] + target.get("static_tags", [])

        # Generate commit SHA tag (sha-<commit>)
        expand_template(
            name = "{}_commit_tag".format(image),
            template = ["sha-{{STABLE_COMMIT_SHA}}"],
            substitutions = {"{{STABLE_COMMIT_SHA}}": "dev"},
            stamp = 1,
            stamp_substitutions = {"{{STABLE_COMMIT_SHA}}": "{{STABLE_COMMIT_SHA}}"},
            out = "{}_commit_tag.txt".format(image),
        )

        # Generate semantic version tag (v<VERSION>) from VERSION file via workspace status
        expand_template(
            name = "{}_version_tag".format(image),
            template = ["v{{STABLE_VERSION}}"],
            substitutions = {"{{STABLE_VERSION}}": "dev"},
            stamp = 1,
            stamp_substitutions = {"{{STABLE_VERSION}}": "{{STABLE_VERSION}}"},
            out = "{}_version_tag.txt".format(image),
        )

        immutable_push_tags(
            name = "{}_push_tags".format(image),
            digest = digest_label,
            commit_tags = ":{}_commit_tag".format(image),
            version_tags = ":{}_version_tag".format(image),
            static_tags = static_tags,
        )

        oci_push(
            name = "{}_push".format(image),
            image = ":{}".format(push_image),
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
