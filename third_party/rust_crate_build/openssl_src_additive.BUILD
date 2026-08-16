filegroup(
    name = "openssl_src_runfiles",
    srcs = glob(
        allow_empty = True,
        include = ["**"],
        exclude = [
            "**/* *",
            ".tmp_git_root/**/*",
            "BUILD",
            "BUILD.bazel",
            "WORKSPACE",
            "WORKSPACE.bazel",
        ],
    ),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "openssl_src_readme",
    srcs = ["README.md"],
    visibility = ["//visibility:public"],
)

# A single stable file INSIDE the openssl/ C-source dir. Its $(location) parent is
# the OpenSSL source root, which the patched source_dir() uses to locate the source.
filegroup(
    name = "openssl_src_version_marker",
    srcs = ["openssl/VERSION.dat"],
    visibility = ["//visibility:public"],
)
