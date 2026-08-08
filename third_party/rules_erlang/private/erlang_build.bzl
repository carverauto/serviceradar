load(
    "@bazel_tools//tools/build_defs/hash:hash.bzl",
    "sha256",
    "tools",
)
load(
    "@bazel_skylib//rules:common_settings.bzl",
    "BuildSettingInfo",
)
load(
    "//:util.bzl",
    "BEGINS_WITH_FUN",
    "QUERY_ERL_VERSION",
    "path_join",
)

OtpInfo = provider(
    doc = "A Home directory of a built Erlang/OTP",
    fields = {
        "version": """The version that this build contains.
May be a prefix of the exact version found in the version_file.""",
        "release_dir_tar": """Directory containing a built erlang.
If this value is not None, it must be symlinked into
erlang_home and used from there, as erlang installations
are not relocatable.""",
        "install_path": """Directory to unpack the release_dir_tar into""",
        "erlang_home": """Absolute path to the erlang
installation""",
        "version_file": """A file containing the version of this
erlang, used to correctly invalidate the cache when an
external erlang is used""",
    },
)

DEFAULT_INSTALL_PREFIX = "/tmp/bazel/erlang"

def _install_root(install_prefix):
    (root_dir, _, _) = install_prefix.removeprefix("/").partition("/")
    return "/" + root_dir

def _erlang_build_impl(ctx):
    (_, _, filename) = ctx.attr.url.rpartition("/")
    downloaded_archive = ctx.actions.declare_file(filename)

    build_dir_tar = ctx.actions.declare_file(ctx.label.name + "_build.tar")
    build_log = ctx.actions.declare_file(ctx.label.name + "_build.log")
    release_dir_tar = ctx.actions.declare_file(ctx.label.name + "_release.tar")

    version_file = ctx.actions.declare_file(ctx.label.name + "_version")

    extra_configure_opts = " ".join(ctx.attr.extra_configure_opts)
    pre_configure_cmds = "\n".join(ctx.attr.pre_configure_cmds)
    post_configure_cmds = "\n".join(ctx.attr.post_configure_cmds)
    extra_make_opts = " ".join(ctx.attr.extra_make_opts)

    if not ctx.attr.install_prefix.startswith("/"):
        # otp installations are not relocatable, so the install_prefix
        # must be absolute to build a predictable location
        fail("install_prefix must be absolute")
    install_path = path_join(ctx.attr.install_prefix, ctx.label.name)
    install_root = _install_root(ctx.attr.install_prefix)

    # At one point this rule recevied the erlang sources as a
    # label_list attribute, which had been fetched with a repository
    # rule. This had the unfortunate side effect of stripping out
    # empty directories which are expected to be present by the
    # otp makefiles. Instead this rule fetches the sources directly,
    # which also avoids unnecessarily fetching sources when they are
    # unused (such as when "external" erlang is used).
    ctx.actions.run_shell(
        inputs = [],
        outputs = [downloaded_archive],
        command = """set -euo pipefail

curl -L "{archive_url}" -o {archive_path}
""".format(
            archive_url = ctx.attr.url,
            archive_path = downloaded_archive.path,
        ),
        mnemonic = "OTP",
        progress_message = "Downloading {}".format(ctx.attr.url),
    )

    sha256file = sha256(ctx, downloaded_archive)

    # zipper = ctx.executable._zipper

    # GNU tar's --transform is not available in the bsdtar that macOS ships, so express the
    # same thing with --strip-components, which both implementations support. Every archive
    # this rule handles wraps its contents in a single top-level directory (otp_src_28.1 for
    # OTP 28.1), so stripping one component is equivalent to removing that prefix.
    strip_components = "--strip-components=1" if ctx.attr.strip_prefix != "" else ""

    ctx.actions.run_shell(
        inputs = [downloaded_archive, sha256file],
        outputs = [
            build_dir_tar,
            build_log,
            release_dir_tar,
        ],
        command = """set -euo pipefail

if [ -n "{sha256}" ]; then
    if [ "{sha256}" != "$(cat "{sha256file}")" ]; then
        echo "ERROR: Checksum mismatch. $(basename "{archive_path}") $(cat "{sha256file}") != {sha256}"
        exit 1
    fi
fi

ABS_BUILD_DIR_TAR=$PWD/{build_path}
ABS_RELEASE_DIR_TAR=$PWD/{release_path}
ABS_LOG=$PWD/{build_log}

ABS_BUILD_DIR="$(mktemp -d)"
ABS_DEST_DIR="$(mktemp -d)"

tar --extract \\
    {strip_components} \\
    --file "{archive_path}" \\
    --directory "$ABS_BUILD_DIR"

echo "Building OTP $(cat $ABS_BUILD_DIR/OTP_VERSION) in $ABS_BUILD_DIR"

trap 'catch $?' EXIT
catch() {{
    [[ $1 == 0 ]] || tail -n 50 "$ABS_LOG"
    echo "    archiving build dir to: {build_path}"
    cd "$ABS_BUILD_DIR"
    tar --create \\
        --file "$ABS_BUILD_DIR_TAR" \\
        *
    echo "    build log: {build_log}"
}}

cd "$ABS_BUILD_DIR"
{pre_configure_cmds}
./configure --prefix={install_path} {extra_configure_opts} >> "$ABS_LOG" 2>&1
{post_configure_cmds}
echo "    configure finished"
${{MAKE:=make}} {extra_make_opts} >> "$ABS_LOG" 2>&1
echo "    make finished"
${{MAKE}} install DESTDIR="$ABS_DEST_DIR" >> "$ABS_LOG" 2>&1
echo "    make install finished"

cd "$ABS_DEST_DIR"/{install_path}
tar --create \\
    --file "$ABS_RELEASE_DIR_TAR" \\
    *
""".format(
            sha256 = ctx.attr.sha256v,
            sha256file = sha256file.path,
            archive_path = downloaded_archive.path,
            strip_components = strip_components,
            build_path = build_dir_tar.path,
            release_path = release_dir_tar.path,
            install_path = install_path,
            install_root = install_root,
            build_log = build_log.path,
            extra_configure_opts = extra_configure_opts,
            pre_configure_cmds = pre_configure_cmds,
            post_configure_cmds = post_configure_cmds,
            extra_make_opts = extra_make_opts,
        ),
        use_default_shell_env = True,
        mnemonic = "OTP",
        progress_message = "Compiling otp from source",
    )

    erlang_home = path_join(install_path, "lib", "erlang")

    ctx.actions.run_shell(
        inputs = [release_dir_tar],
        outputs = [version_file],
        command = """set -euo pipefail

mkdir -p "{install_path}"
tar --extract \\
    --directory "{install_path}" \\
    --file {erlang_release_tar}

{begins_with_fun}
V=$("{erlang_home}"/bin/{query_erlang_version})
if ! beginswith "{erlang_version}" "$V"; then
echo "Erlang version mismatch (Expected {erlang_version}, found $V)"
exit 1
fi

echo "$V" >> {version_file}
""".format(
            install_path = install_path,
            begins_with_fun = BEGINS_WITH_FUN,
            query_erlang_version = QUERY_ERL_VERSION,
            erlang_version = ctx.attr.version,
            erlang_home = erlang_home,
            erlang_release_tar = release_dir_tar.path,
            version_file = version_file.path,
        ),
        mnemonic = "OTP",
        progress_message = "Validating otp at {}".format(erlang_home),
    )

    return [
        DefaultInfo(
            files = depset([
                release_dir_tar,
                version_file,
            ]),
        ),
        OtpInfo(
            version = ctx.attr.version,
            release_dir_tar = release_dir_tar,
            install_path = install_path,
            erlang_home = erlang_home,
            version_file = version_file,
        ),
    ]

erlang_build = rule(
    implementation = _erlang_build_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "url": attr.string(mandatory = True),
        "strip_prefix": attr.string(),
        "sha256v": attr.string(),
        "install_prefix": attr.string(default = DEFAULT_INSTALL_PREFIX),
        "pre_configure_cmds": attr.string_list(),
        "extra_configure_opts": attr.string_list(),
        "post_configure_cmds": attr.string_list(),
        "extra_make_opts": attr.string_list(),
        "sha256": tools["sha256"],
    },
)

def _erlang_external_impl(ctx):
    erlang_home = ctx.attr.erlang_home
    if erlang_home == "":
        erlang_home = ctx.attr._erlang_home[BuildSettingInfo].value

    erlang_version = ctx.attr.erlang_version
    if erlang_version == "":
        erlang_version = ctx.attr._erlang_version[BuildSettingInfo].value

    version_file = ctx.actions.declare_file(ctx.label.name + "_version")

    ctx.actions.run_shell(
        inputs = [],
        outputs = [version_file],
        command = """set -euo pipefail

{begins_with_fun}
V=$("{erlang_home}"/bin/{query_erlang_version})
if ! beginswith "{erlang_version}" "$V"; then
echo "Erlang version mismatch (Expected {erlang_version}, found $V)"
exit 1
fi

echo "$V" >> {version_file}
""".format(
            begins_with_fun = BEGINS_WITH_FUN,
            query_erlang_version = QUERY_ERL_VERSION,
            erlang_version = erlang_version,
            erlang_home = erlang_home,
            version_file = version_file.path,
        ),
        mnemonic = "OTP",
        progress_message = "Validating otp at {}".format(erlang_home),
    )

    return [
        DefaultInfo(
            files = depset([version_file]),
        ),
        OtpInfo(
            version = erlang_version,
            release_dir_tar = None,
            install_path = None,
            erlang_home = erlang_home,
            version_file = version_file,
        ),
    ]

erlang_external = rule(
    implementation = _erlang_external_impl,
    attrs = {
        "_erlang_home": attr.label(default = Label("//:erlang_home")),
        "_erlang_version": attr.label(default = Label("//:erlang_version")),
        "erlang_home": attr.string(),
        "erlang_version": attr.string(),
    },
)
