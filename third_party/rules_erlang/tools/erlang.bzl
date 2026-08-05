load(
    "//private:erlang_build.bzl",
    "erlang_build",
    "erlang_external",
)
load(
    ":erlang_toolchain.bzl",
    "erlang_toolchain",
)

DEFAULT_ERLANG_VERSION = "26.0"
DEFAULT_ERLANG_SHA256 = "3ff3c53d7ef9a45b5720e95b8756269c1a1b58eb51accc992ca97522fdb234d4"

def erlang_toolchain_external():
    erlang_constraint = Label("@rules_erlang//platforms:erlang_external")

    erlang_external(
        name = "otp_external",
        target_compatible_with = [
            erlang_constraint,
        ],
    )

    erlang_toolchain(
        name = "erlang_external",
        otp = ":otp_external",
        visibility = ["//visibility:public"],
    )

    native.toolchain(
        name = "erlang_toolchain_external",
        exec_compatible_with = [
            erlang_constraint,
        ],
        target_compatible_with = [
            erlang_constraint,
        ],
        toolchain = ":erlang_external",
        toolchain_type = Label("@rules_erlang//tools:toolchain_type"),
        visibility = ["//visibility:public"],
    )

    return erlang_constraint

def erlang_toolchain_from_http_archive(
        name_suffix = "",
        version = "UNKNOWN",
        url = None,
        strip_prefix = None,
        sha256 = None,
        extra_configure_opts = [],
        erlang_constraint = None):
    erlang_build(
        name = "otp{}".format(name_suffix),
        version = version,
        url = url,
        strip_prefix = strip_prefix,
        sha256v = sha256,
        extra_configure_opts = extra_configure_opts,
        target_compatible_with = [
            erlang_constraint,
        ],
    )

    erlang_toolchain(
        name = "erlang{}".format(name_suffix),
        otp = ":otp{}".format(name_suffix),
        visibility = ["//visibility:public"],
    )

    native.toolchain(
        name = "erlang_toolchain{}".format(name_suffix),
        exec_compatible_with = [
            erlang_constraint,
        ],
        target_compatible_with = [
            erlang_constraint,
        ],
        toolchain = "erlang{}".format(name_suffix),
        toolchain_type = Label("@rules_erlang//tools:toolchain_type"),
        visibility = ["//visibility:public"],
    )

def erlang_toolchain_from_github_release(
        name_suffix = "_default",
        version = DEFAULT_ERLANG_VERSION,
        sha256 = DEFAULT_ERLANG_SHA256,
        extra_configure_opts = []):
    (major, _, _) = version.partition(".")
    erlang_constraint = Label("@rules_erlang//platforms:erlang_{}".format(major))
    url = "https://github.com/erlang/otp/releases/download/OTP-{v}/otp_src_{v}.tar.gz".format(
        v = version,
    )
    erlang_toolchain_from_http_archive(
        name_suffix = name_suffix,
        version = version,
        url = url,
        strip_prefix = "otp_src_{}".format(version),
        sha256 = sha256,
        extra_configure_opts = extra_configure_opts,
        erlang_constraint = erlang_constraint,
    )
    return erlang_constraint
