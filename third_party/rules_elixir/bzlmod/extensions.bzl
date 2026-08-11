load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load(
    "//repositories:elixir_config.bzl",
    "INSTALLATION_TYPE_EXTERNAL",
    "INSTALLATION_TYPE_INTERNAL",
    _elixir_config_rule = "elixir_config",
)

DEFAULT_ELIXIR_VERSION = "1.15.0"
DEFAULT_ELIXIR_SHA256 = "0f4df7574a5f300b5c66f54906222cd46dac0df7233ded165bc8e80fd9ffeb7a"

def _elixir_config(ctx):
    types = {}
    versions = {}
    urls = {}
    strip_prefixs = {}
    sha256s = {}
    elixir_homes = {}

    for mod in ctx.modules:
        for elixir in mod.tags.external_elixir_from_path:
            types[elixir.name] = INSTALLATION_TYPE_EXTERNAL
            versions[elixir.name] = elixir.version
            elixir_homes[elixir.name] = elixir.elixir_home

        for elixir in mod.tags.internal_elixir_from_http_archive:
            types[elixir.name] = INSTALLATION_TYPE_INTERNAL
            versions[elixir.name] = elixir.version
            urls[elixir.name] = elixir.url
            strip_prefixs[elixir.name] = elixir.strip_prefix
            sha256s[elixir.name] = elixir.sha256

        for elixir in mod.tags.internal_elixir_from_github_release:
            url = "https://github.com/elixir-lang/elixir/archive/refs/tags/v{}.tar.gz".format(
                elixir.version,
            )
            strip_prefix = "elixir-{}".format(elixir.version)

            types[elixir.name] = INSTALLATION_TYPE_INTERNAL
            versions[elixir.name] = elixir.version
            urls[elixir.name] = url
            strip_prefixs[elixir.name] = strip_prefix
            sha256s[elixir.name] = elixir.sha256

    _elixir_config_rule(
        name = "elixir_config",
        types = types,
        versions = versions,
        urls = urls,
        strip_prefixs = strip_prefixs,
        sha256s = sha256s,
        elixir_homes = elixir_homes,
    )

external_elixir_from_path = tag_class(attrs = {
    "name": attr.string(),
    "version": attr.string(),
    "elixir_home": attr.string(),
})

internal_elixir_from_http_archive = tag_class(attrs = {
    "name": attr.string(),
    "version": attr.string(),
    "url": attr.string(),
    "strip_prefix": attr.string(),
    "sha256": attr.string(),
})

internal_elixir_from_github_release = tag_class(attrs = {
    "name": attr.string(
        default = "internal",
    ),
    "version": attr.string(
        default = DEFAULT_ELIXIR_VERSION,
    ),
    "sha256": attr.string(
        default = DEFAULT_ELIXIR_SHA256,
    ),
})

elixir_config = module_extension(
    implementation = _elixir_config,
    tag_classes = {
        "external_elixir_from_path": external_elixir_from_path,
        "internal_elixir_from_http_archive": internal_elixir_from_http_archive,
        "internal_elixir_from_github_release": internal_elixir_from_github_release,
    },
)

# Hex, the package manager, built from source as a Mix archive.
#
# Not for fetching anything. Mix needs Hex installed as an archive before it can resolve a
# project at all: without it, `{:dep, "~> x.y"}` in a mix.exs aborts with "Could not find an
# SCM for dependency", even for a dev-only dep that would never be compiled. A build that
# supplies every dependency from Bazel and runs `mix --no-deps-check` still trips over this.
#
# Hex has no dependencies of its own, so it bootstraps through mix_archive_build with an
# empty dep graph -- which is why this can live here rather than in the consuming module.
DEFAULT_HEX_VERSION = "2.5.1"

DEFAULT_HEX_SHA256 = "dabd99ea48ba8064c32bc2e97d59ab1b1055a38a1dd178c5389d95c35e985d2d"

_HEX_BUILD_FILE = """\
load("@rules_elixir//:mix_archive_build.bzl", "mix_archive_build")

# Consumed via `mix archive.install`, not as an ERL_LIBS dependency, so it has to be a .ez.
mix_archive_build(
    name = "archive",
    srcs = ["mix.exs"] + glob(["lib/**/*"]),
    out = "hex.ez",
    visibility = ["//visibility:public"],
)
"""

def _hex(ctx):
    version = DEFAULT_HEX_VERSION
    sha256 = DEFAULT_HEX_SHA256

    # Last tag wins, and the root module's tags are evaluated last, so a consumer can pin a
    # version without every dependency in the graph having to agree on one.
    for mod in ctx.modules:
        for hex in mod.tags.from_github_release:
            version = hex.version
            sha256 = hex.sha256

    http_archive(
        name = "hex",
        build_file_content = _HEX_BUILD_FILE,
        sha256 = sha256,
        strip_prefix = "hex-{}".format(version),
        urls = ["https://github.com/hexpm/hex/archive/refs/tags/v{}.zip".format(version)],
    )

    return ctx.extension_metadata(
        root_module_direct_deps = ["hex"],
        root_module_direct_dev_deps = [],
        reproducible = True,
    )

from_github_release = tag_class(attrs = {
    "version": attr.string(
        default = DEFAULT_HEX_VERSION,
    ),
    "sha256": attr.string(
        default = DEFAULT_HEX_SHA256,
    ),
})

hex = module_extension(
    implementation = _hex,
    tag_classes = {
        "from_github_release": from_github_release,
    },
)
