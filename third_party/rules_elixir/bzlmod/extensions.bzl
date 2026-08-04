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
