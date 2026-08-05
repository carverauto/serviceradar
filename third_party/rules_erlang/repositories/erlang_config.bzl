load(
    "//:util.bzl",
    "msys2_path",
    "path_join",
)

ERLANG_HOME_ENV_VAR = "ERLANG_HOME"

_DEFAULT_EXTERNAL_ERLANG_PACKAGE_NAME = "external"
_ERLANG_VERSION_UNKNOWN = "UNKNOWN"

INSTALLATION_TYPE_EXTERNAL = "external"
INSTALLATION_TYPE_INTERNAL = "internal"

def _parse_maybe_semver(version_string):
    parts = version_string.split(".", 2)
    if len(parts) > 1:
        return (parts[0], parts[1])
    else:
        return (parts[0], _ERLANG_VERSION_UNKNOWN.lower())

def _to_string_list(strings):
    return "[%s]" % ",".join(['"%s"' % s.replace('"', '\\"') for s in strings])

def _impl(repository_ctx):
    rules_erlang_workspace = repository_ctx.attr.rules_erlang_workspace

    erlang_installations = _default_erlang_dict(repository_ctx)
    for name in repository_ctx.attr.types.keys():
        if name == _DEFAULT_EXTERNAL_ERLANG_PACKAGE_NAME:
            fail("'{}' is reserved as an erlang name".format(
                _DEFAULT_EXTERNAL_ERLANG_PACKAGE_NAME,
            ))
        version = repository_ctx.attr.versions[name]
        (major, minor) = _parse_maybe_semver(version)
        erlang_installations[name] = struct(
            type = repository_ctx.attr.types[name],
            version = version,
            major = major,
            minor = minor,
            url = repository_ctx.attr.urls.get(name, None),
            strip_prefix = repository_ctx.attr.strip_prefixs.get(name, None),
            sha256 = repository_ctx.attr.sha256s.get(name, None),
            erlang_home = repository_ctx.attr.erlang_homes.get(name, None),
            pre_configure_cmds = repository_ctx.attr.pre_configure_cmdss.get(name, []),
            extra_configure_opts = repository_ctx.attr.extra_configure_optss.get(name, []),
            post_configure_cmds = repository_ctx.attr.post_configure_cmdss.get(name, []),
            extra_make_opts = repository_ctx.attr.extra_make_optss.get(name, []),
        )

    # If we intentionally skipped probing a host-installed OTP, still provide
    # a default "external" entry so default toolchain registration succeeds.
    if _DEFAULT_EXTERNAL_ERLANG_PACKAGE_NAME not in erlang_installations and erlang_installations:
        erlang_installations[_DEFAULT_EXTERNAL_ERLANG_PACKAGE_NAME] = erlang_installations[list(erlang_installations.keys())[0]]

    for (name, props) in erlang_installations.items():
        if props.type == INSTALLATION_TYPE_EXTERNAL:
            repository_ctx.template(
                "{}/BUILD.bazel".format(name),
                Label("//repositories:BUILD_external.tpl"),
                {
                    "%{ERLANG_NAME}": name,
                    "%{ERLANG_HOME}": props.erlang_home,
                    "%{ERLANG_VERSION}": props.version,
                    "%{ERLANG_MAJOR}": props.major,
                    "%{ERLANG_MINOR}": props.minor,
                    "%{RULES_ERLANG_WORKSPACE}": rules_erlang_workspace,
                },
                False,
            )
        else:
            repository_ctx.template(
                "{}/BUILD.bazel".format(name),
                Label("//repositories:BUILD_internal.tpl"),
                {
                    "%{ERLANG_NAME}": name,
                    "%{ERLANG_VERSION}": props.version,
                    "%{URL}": props.url,
                    "%{STRIP_PREFIX}": props.strip_prefix or "",
                    "%{SHA_256}": props.sha256 or "",
                    "%{ERLANG_MAJOR}": props.major,
                    "%{ERLANG_MINOR}": props.minor,
                    "%{RULES_ERLANG_WORKSPACE}": rules_erlang_workspace,
                    "%{PRE_CONFIGURE_CMDS}": _to_string_list(props.pre_configure_cmds),
                    "%{EXTRA_CONFIGURE_OPTS}": _to_string_list(props.extra_configure_opts),
                    "%{POST_CONFIGURE_CMDS}": _to_string_list(props.post_configure_cmds),
                    "%{EXTRA_MAKE_OPTS}": _to_string_list(props.extra_make_opts),
                },
                False,
            )

    if len(erlang_installations) == 0:
        fail("No erlang installations configured")

    repository_ctx.file(
        "BUILD.bazel",
        _build_file_content(erlang_installations),
        False,
    )

    toolchains = []
    for name in erlang_installations.keys():
        toolchains.extend([
            "@{}//{}:toolchain_major".format(repository_ctx.name, name),
            "@{}//{}:toolchain_major_minor".format(repository_ctx.name, name),
        ])

    repository_ctx.template(
        "defaults.bzl",
        Label("//repositories:defaults.bzl.tpl"),
        {
            "%{TOOLCHAINS}": "\n".join([
                '        "%s",' % t
                for t in toolchains
            ]),
        },
        False,
    )

erlang_config = repository_rule(
    implementation = _impl,
    attrs = {
        "rules_erlang_workspace": attr.string(),
        "types": attr.string_dict(),
        "versions": attr.string_dict(),
        "urls": attr.string_dict(),
        "strip_prefixs": attr.string_dict(),
        "sha256s": attr.string_dict(),
        "erlang_homes": attr.string_dict(),
        "pre_configure_cmdss": attr.string_list_dict(),
        "extra_configure_optss": attr.string_list_dict(),
        "post_configure_cmdss": attr.string_list_dict(),
        "extra_make_optss": attr.string_list_dict(),
    },
    environ = [
        ERLANG_HOME_ENV_VAR,
        "PATH",
        "RULES_ERLANG_SKIP_SYSTEM",
    ],
    local = True,
)

def _erlang_home_from_erl_path(repository_ctx, erl_path):
    ehr = repository_ctx.execute(
        [
            erl_path,
            "-noshell",
            "-eval",
            'io:format("~s",[code:root_dir()]), halt().',
        ],
        timeout = 10,
    )
    if ehr.return_code == 0:
        erlang_home = ehr.stdout.strip("\n")
    else:
        erlang_home = str(erl_path.dirname.dirname)
    return erlang_home

def _is_windows(repository_ctx):
    return repository_ctx.os.name.lower().find("windows") != -1

def _default_erlang_dict(repository_ctx):
    # Allow consumers to opt out of discovering a host-installed Erlang/OTP
    # when they want fully hermetic builds (e.g. remote execution or CI).
    if repository_ctx.os.environ.get("RULES_ERLANG_SKIP_SYSTEM") == "1":
        return {}
    if _is_windows(repository_ctx):
        if ERLANG_HOME_ENV_VAR in repository_ctx.os.environ:
            erlang_home = repository_ctx.os.environ[ERLANG_HOME_ENV_VAR]
            erl_path = erlang_home + "\\bin\\erl.exe"
        else:
            erl_path = repository_ctx.which("erl.exe")
            if erl_path == None:
                erl_path = repository_ctx.path("C:/Program Files/Erlang OTP/bin/erl.exe")
            erlang_home = _erlang_home_from_erl_path(repository_ctx, erl_path)
        erlang_home = msys2_path(erlang_home)
    elif ERLANG_HOME_ENV_VAR in repository_ctx.os.environ:
        erlang_home = repository_ctx.os.environ[ERLANG_HOME_ENV_VAR]
        erl_path = path_join(erlang_home, "bin", "erl")
    else:
        erl_path = repository_ctx.which("erl")
        if erl_path == None:
            erl_path = repository_ctx.path("/usr/bin/erl")
        erlang_home = _erlang_home_from_erl_path(repository_ctx, erl_path)

    version = repository_ctx.execute(
        [
            erl_path,
            "-noshell",
            "-eval",
            '{ok, Version} = file:read_file(filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"])), io:fwrite(Version), halt().',
        ],
        timeout = 10,
    )
    if version.return_code == 0:
        version = version.stdout.strip("\n")
        (major, minor) = _parse_maybe_semver(version)
        return {
            _DEFAULT_EXTERNAL_ERLANG_PACKAGE_NAME: struct(
                type = INSTALLATION_TYPE_EXTERNAL,
                version = version,
                major = major,
                minor = minor,
                erlang_home = erlang_home,
            ),
        }
    else:
        return {
            _DEFAULT_EXTERNAL_ERLANG_PACKAGE_NAME: struct(
                type = INSTALLATION_TYPE_EXTERNAL,
                version = _ERLANG_VERSION_UNKNOWN,
                major = _ERLANG_VERSION_UNKNOWN.lower(),
                minor = _ERLANG_VERSION_UNKNOWN.lower(),
                erlang_home = erlang_home,
            ),
        }

def _build_file_content(erlang_installations):
    build_file_content = """\
package(
    default_visibility = ["//visibility:public"],
)

constraint_setting(
    name = "erlang_internal_external",
    default_constraint_value = ":erlang_external",
)

constraint_value(
    name = "erlang_external",
    constraint_setting = ":erlang_internal_external",
)

constraint_value(
    name = "erlang_internal",
    constraint_setting = ":erlang_internal_external",
)

"""

    # Prefer the first configured installation as the default instead of
    # assuming a host system OTP exists everywhere (e.g., on remote executors).
    default_installation = erlang_installations.values()[0]

    build_file_content += """\
constraint_setting(
    name = "erlang_version",
    default_constraint_value = ":erlang_{}_{}",
)

""".format(default_installation.major, default_installation.minor)

    major_by_minors = {}
    for (name, props) in erlang_installations.items():
        minors = major_by_minors.get(props.major, [])
        if props.minor not in minors:
            minors.append(props.minor)
        major_by_minors[props.major] = minors

    for (major, minors) in major_by_minors.items():
        build_file_content += """\
constraint_value(
    name = "erlang_{major}",
    constraint_setting = ":erlang_version",
)

platform(
    name = "erlang_{major}_platform",
    constraint_values = [
        ":erlang_{major}",
    ],
)

""".format(major = major)

        for minor in minors:
            build_file_content += """\
constraint_value(
    name = "erlang_{major}_{minor}",
    constraint_setting = ":erlang_version",
)

platform(
    name = "erlang_{major}_{minor}_platform",
    constraint_values = [
        ":erlang_{major}_{minor}",
    ],
)

""".format(major = major, minor = minor)

    return build_file_content
