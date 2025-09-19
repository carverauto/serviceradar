"""Module extension to download Perl sources for hermetic builds."""

def _perl_repo_impl(module_ctx):
    repo = module_ctx.new_repo(name = "perl_src")
    repo.download_and_extract(
        url = "https://www.cpan.org/src/5.0/perl-5.40.0.tar.xz",
        integrity = "sha256-1TJTAK0mdiTLC31RLP3810+n/gDEVcW1GmvVPl4Znvk=",
        strip_prefix = "perl-5.40.0",
    )

    repo.file(
        "BUILD.bazel",
        """
filegroup(
    name = "all_sources",
    srcs = glob(["**"], exclude = ["BUILD", "BUILD.bazel"]),
    visibility = ["//visibility:public"],
)
""",
    )

perl = module_extension(
    implementation = _perl_repo_impl,
)
