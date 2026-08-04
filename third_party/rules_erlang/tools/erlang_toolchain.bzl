load(
    "//private:erlang_build.bzl",
    "OtpInfo",
)

def _impl(ctx):
    otpinfo = ctx.attr.otp[OtpInfo]
    vars = {
        "OTP_VERSION": otpinfo.version,
        "ERLANG_HOME": otpinfo.erlang_home,
    }
    if otpinfo.release_dir_tar != None:
        vars["ERLANG_RELEASE_TAR_PATH"] = otpinfo.release_dir_tar.path
        vars["ERLANG_RELEASE_TAR_SHORT_PATH"] = otpinfo.release_dir_tar.short_path
    return [
        platform_common.ToolchainInfo(otpinfo = otpinfo),
        platform_common.TemplateVariableInfo(vars),
    ]

erlang_toolchain = rule(
    implementation = _impl,
    attrs = {
        "otp": attr.label(
            mandatory = True,
            providers = [OtpInfo],
        ),
    },
    provides = [
        platform_common.ToolchainInfo,
        # Instead of using this toolchain for a genrule,
        # since toolchain resolution won't yet have applied,
        # use @rules_erlang//tools:erlang_vars as a
        # toolchain for genrule rules
        platform_common.TemplateVariableInfo,
    ],
)

def _build_info(ctx):
    return ctx.toolchains["//tools:toolchain_type"].otpinfo

def erlang_dirs(ctx):
    info = _build_info(ctx)
    if info.release_dir_tar != None:
        runfiles = ctx.runfiles([
            info.release_dir_tar,
            info.version_file,
        ])
    else:
        runfiles = ctx.runfiles([
            info.version_file,
        ])
    return (info.erlang_home, info.release_dir_tar, runfiles)

def maybe_install_erlang(ctx, short_path = False):
    info = _build_info(ctx)
    release_dir_tar = info.release_dir_tar
    if release_dir_tar == None:
        return ""
    else:
        return """\
mkdir -p $(dirname "{install_path}")
if mkdir "{install_path}"; then
    tar --extract \\
        --directory "{install_path}" \\
        --file {release_tar}
fi\
""".format(
            release_tar = release_dir_tar.short_path if short_path else release_dir_tar.path,
            install_path = info.install_path,
        )

def version_file(ctx):
    info = _build_info(ctx)
    return info.version_file
