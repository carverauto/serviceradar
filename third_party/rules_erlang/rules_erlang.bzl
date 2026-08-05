load(":hex_archive.bzl", "hex_archive")
load(
    "//repositories:erlang_config.bzl",
    "INSTALLATION_TYPE_INTERNAL",
    _erlang_config = "erlang_config",
)
load(
    "//tools:erlang.bzl",
    "DEFAULT_ERLANG_SHA256",
    "DEFAULT_ERLANG_VERSION",
)

def rules_erlang_dependencies():
    xref_runner_sources()

def xref_runner_sources():
    hex_archive(
        name = "getopt_src",
        package_name = "getopt",
        version = "1.0.1",
        sha256 = "53e1ab83b9ceb65c9672d3e7a35b8092e9bdc9b3ee80721471a161c10c59959c",
        build_file_content = """filegroup(
    name = "app_src",
    srcs = glob(["src/*.app.src"]),
    visibility = ["//visibility:public"],
)
filegroup(
    name = "srcs",
    srcs = glob(["src/**/*.erl"]),
    visibility = ["//visibility:public"],
)
""",
    )
    hex_archive(
        name = "xref_runner_src",
        package_name = "xref_runner",
        version = "1.2.0",
        sha256 = "22d4bb466b1bf8b206f03d1f43f01233b547f8b81351f29af2c6d668e0734ffc",
        build_file_content = """filegroup(
    name = "app_src",
    srcs = glob(["src/*.app.src"]),
    visibility = ["//visibility:public"],
)
filegroup(
    name = "srcs",
    srcs = glob(["src/**/*.erl"]),
    visibility = ["//visibility:public"],
)
""",
    )

# Generates the @erlang_config repository, which contains erlang
# toolchains and platform defintions
def erlang_config(
        rules_erlang_workspace = "@rules_erlang",
        internal_erlang_configs = []):
    types = {c.name: INSTALLATION_TYPE_INTERNAL for c in internal_erlang_configs}
    versions = {c.name: c.version for c in internal_erlang_configs}
    urls = {c.name: c.url for c in internal_erlang_configs}
    strip_prefixs = {c.name: c.strip_prefix for c in internal_erlang_configs if c.strip_prefix}
    sha256s = {c.name: c.sha256 for c in internal_erlang_configs if c.sha256}
    pre_configure_cmdss = {c.name: c.pre_configure_cmds for c in internal_erlang_configs if c.pre_configure_cmds}
    extra_configure_optss = {c.name: c.extra_configure_opts for c in internal_erlang_configs if c.extra_configure_opts}
    post_configure_cmdss = {c.name: c.post_configure_cmds for c in internal_erlang_configs if c.post_configure_cmds}

    _erlang_config(
        name = "erlang_config",
        rules_erlang_workspace = rules_erlang_workspace,
        types = types,
        versions = versions,
        urls = urls,
        strip_prefixs = strip_prefixs,
        sha256s = sha256s,
        pre_configure_cmdss = pre_configure_cmdss,
        extra_configure_optss = extra_configure_optss,
        post_configure_cmdss = post_configure_cmdss,
    )

def internal_erlang_from_http_archive(
        name = None,
        version = None,
        url = None,
        strip_prefix = None,
        sha256 = None,
        pre_configure_cmds = None,
        extra_configure_opts = None,
        post_configure_cmds = None):
    return struct(
        name = name,
        version = version,
        url = url,
        strip_prefix = strip_prefix,
        sha256 = sha256,
        pre_configure_cmds = pre_configure_cmds,
        extra_configure_opts = extra_configure_opts,
        post_configure_cmds = post_configure_cmds,
    )

def internal_erlang_from_github_release(
        name = "internal",
        version = DEFAULT_ERLANG_VERSION,
        sha256 = None,
        pre_configure_cmds = None,
        extra_configure_opts = None,
        post_configure_cmds = None):
    url = "https://github.com/erlang/otp/releases/download/OTP-{v}/otp_src_{v}.tar.gz".format(
        v = version,
    )

    if version == DEFAULT_ERLANG_VERSION and sha256 == None:
        sha256 = DEFAULT_ERLANG_SHA256

    return internal_erlang_from_http_archive(
        name = name,
        version = version,
        url = url,
        strip_prefix = "otp_src_{}".format(version),
        sha256 = sha256,
        pre_configure_cmds = pre_configure_cmds,
        extra_configure_opts = extra_configure_opts,
        post_configure_cmds = post_configure_cmds,
    )
