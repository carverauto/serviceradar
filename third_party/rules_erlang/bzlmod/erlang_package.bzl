load(
    "@bazel_tools//tools/build_defs/repo:git.bzl",
    "git_repository",
    "new_git_repository",
)
load(
    "//:hex_archive.bzl",
    "hex_archive",
)
load(
    ":hex_pm.bzl",
    "hex_release_info",
)

HexPackage = provider(fields = [
    "module",
    "name",
    "pkg",
    "version",
    "sha256",
    "build_file",
    "build_file_content",
    "patches",
    "patch_args",
    "patch_cmds",
    "testonly",
    "deps",
    "requirements",
    "f_fetch",
])

GitPackage = provider(fields = [
    "module",
    "name",
    "version",
    "remote",
    "repository",
    "branch",
    "tag",
    "commit",
    "build_file",
    "build_file_content",
    "patch_cmds",
    "testonly",
    "f_fetch",
])

def log(ctx, msg):
    ctx.execute(["echo", "RULES_ERLANG: " + msg], timeout = 1, quiet = False)

def hex_tree(
        ctx,
        module = None,
        name = None,
        pkg = None,
        version = None):
    log(ctx, "Fetching release info for {}@{} from hex.pm".format(name, version))
    release_info = hex_release_info(ctx, name, version)

    sha256 = release_info["checksum"]

    deps = []
    requirements = []
    for (_, props) in release_info["requirements"].items():
        if not props["optional"]:
            deps.append(props["app"])
            requirements.append(props)

    return HexPackage(
        module = module,
        name = name,
        pkg = pkg,
        version = version,
        sha256 = sha256,
        build_file_content = "",
        patches = [],
        patch_args = ["-p0"],
        patch_cmds = [],
        testonly = False,
        deps = deps,
        requirements = requirements,
        f_fetch = _hex_package_repo,
    )

def hex_package(
        _ctx,
        module = None,
        name = None,
        pkg = None,
        version = None,
        sha256 = None,
        build_file = None,
        build_file_content = None,
        patches = [],
        patch_args = ["-p0"],
        patch_cmds = None,
        testonly = False):
    return HexPackage(
        module = module,
        name = name,
        pkg = pkg,
        version = version,
        sha256 = sha256,
        build_file = build_file,
        build_file_content = build_file_content,
        patches = patches,
        patch_args = patch_args,
        patch_cmds = patch_cmds,
        testonly = testonly,
        deps = None,
        requirements = [],
        f_fetch = _hex_package_repo,
    )

def _infer_app_name(remote):
    (_, _, repo) = remote.rpartition("/")
    if repo == remote:
        fail("Could not extract erlang app name from {}".format(remote))
    if not repo.endswith(".git"):
        fail("Could not extract erlang app name from {}".format(remote))
    return repo[0:-4]

def git_package(
        _ctx,
        module = None,
        dep = None):
    if dep.remote != "" and dep.repository != "":
        fail("'remote' and 'repository' are mutually exclusive options")

    if dep.repository != "":
        remote = "https://github.com/{}.git".format(dep.repository)
    elif dep.remote != "":
        remote = dep.remote
    else:
        fail("either 'remote' or 'repository' are required")

    if dep.name != "":
        name = dep.name
    else:
        name = _infer_app_name(remote)

    if dep.commit != "":
        version = dep.commit
    elif dep.tag != "":
        version = dep.tag
    else:
        version = dep.branch

    return GitPackage(
        module = module,
        name = name,
        version = version,
        remote = remote,
        branch = dep.branch,
        tag = dep.tag,
        commit = dep.commit,
        build_file = dep.build_file,
        build_file_content = dep.build_file_content,
        patch_cmds = dep.patch_cmds,
        testonly = dep.testonly,
        f_fetch = _git_package_repo,
    )

def without_requirement(name, package):
    requirements = getattr(package, "requirements", [])
    if len(requirements) == 0:
        return package
    else:
        # currently only HexPackage has "requirements", so we
        # can always return one
        new_requirements = []
        for r in requirements:
            if r["app"] != name:
                new_requirements.append(r)

        return HexPackage(
            module = package.module,
            name = package.name,
            version = package.version,
            sha256 = package.sha256,
            build_file = package.build_file,
            build_file_content = package.build_file_content,
            patches = package.patches,
            patch_args = package.patch_args,
            patch_cmds = package.patch_cmds,
            testonly = package.testonly,
            deps = package.deps,
            requirements = new_requirements,
            f_fetch = package.f_fetch,
        )

def _hex_package_repo(hex_package):
    package_name = hex_package.pkg if hex_package.pkg != "" else hex_package.name
    if hex_package.build_file != None:
        hex_archive(
            name = hex_package.name,
            package_name = package_name,
            version = hex_package.version,
            sha256 = hex_package.sha256,
            build_file = hex_package.build_file,
            patches = hex_package.patches,
            patch_args = hex_package.patch_args,
            patch_cmds = hex_package.patch_cmds,
        )
    elif hex_package.build_file_content != "":
        hex_archive(
            name = hex_package.name,
            package_name = package_name,
            version = hex_package.version,
            sha256 = hex_package.sha256,
            build_file_content = hex_package.build_file_content,
            patches = hex_package.patches,
            patch_args = hex_package.patch_args,
            patch_cmds = hex_package.patch_cmds,
        )
    else:
        if hex_package.deps != None:
            deps = ["@{}//:erlang_app".format(d) for d in hex_package.deps]
        else:
            deps = ""

        hex_archive(
            name = hex_package.name,
            package_name = package_name,
            version = hex_package.version,
            sha256 = hex_package.sha256,
            patches = hex_package.patches,
            patch_args = hex_package.patch_args,
            patch_cmds = hex_package.patch_cmds + [PATCH_AUTO_BUILD_BAZEL.format(
                name = hex_package.name,
                version = hex_package.version,
                deps = deps,
                testonly = hex_package.testonly,
            )],
        )

def _git_package_repo(git_package):
    if git_package.build_file != None:
        new_git_repository(
            name = git_package.name,
            remote = git_package.remote,
            branch = git_package.branch,
            tag = git_package.tag,
            commit = git_package.commit,
            build_file = git_package.build_file,
            patch_cmds = git_package.patch_cmds,
        )
    elif git_package.build_file_content != "":
        new_git_repository(
            name = git_package.name,
            remote = git_package.remote,
            branch = git_package.branch,
            tag = git_package.tag,
            commit = git_package.commit,
            build_file_content = git_package.build_file_content,
            patch_cmds = git_package.patch_cmds,
        )
    else:
        git_repository(
            name = git_package.name,
            remote = git_package.remote,
            branch = git_package.branch,
            tag = git_package.tag,
            commit = git_package.commit,
            patch_cmds = git_package.patch_cmds + [PATCH_AUTO_BUILD_BAZEL.format(
                name = git_package.name,
                version = "",
                deps = [],
                testonly = git_package.testonly,
            )],
        )

PATCH_AUTO_BUILD_BAZEL = """set -euo pipefail

echo "Generating BUILD.bazel for {name}..."

# if there is a Makefile and erlang.mk, use make to infer
# the version and deps, error on name mismatch, and error
# if the deps mismatch
if [ ! -f BUILD.bazel ]; then
    if [ -f Makefile ]; then
        if [ -f erlang.mk ]; then
            if [ -n "${{MAKE:=make}}" ]; then
                echo "\tAttempting auto-configure from erlang.mk files..."

                cat << 'MK' > bazel-autobuild.mk
comma:= ,
project:= $(lastword $(subst ., ,$(PROJECT)))
ifnappsrc:= $(if $(wildcard src/$(project).app.src),,$1)

define BUILD_FILE_CONTENT
load("@rules_erlang//:erlang_app.bzl", "erlang_app")

erlang_app(
    app_name = "$(project)",
    $(call ifnappsrc,$(if $(PROJECT_DESCRIPTION),app_description = \"""$(PROJECT_DESCRIPTION)\"""$(comma)))
    $(call ifnappsrc,app_version = "$(PROJECT_VERSION)"$(comma))
    $(call ifnappsrc,app_env = \"""$(PROJECT_ENV)\"""$(comma))
    $(call ifnappsrc,$(if $(PROJECT_APP_EXTRA_KEYS),app_extra = \"""$(PROJECT_APP_EXTRA_KEYS)\"""$(comma)))
    $(if $(LOCAL_DEPS),extra_apps = [$(foreach dep,$(LOCAL_DEPS),\n        "$(dep)",)\n    ]$(comma))
    $(if $(BUILD_DEPS),build_deps = [$(foreach dep,$(BUILD_DEPS),\n        "@$(dep)//:erlang_app",)\n    ]$(comma))
    $(if $(DEPS),deps = [$(foreach dep,$(DEPS),\n        "@$(dep)//:erlang_app",)\n    ]$(comma))
    erlc_opts = select({{
        "@rules_erlang//:debug_build": ["+debug_info"],
        "//conditions:default": ["+deterministic", "+debug_info"],
    }}),
    stamp = 0,
    testonly = {testonly},
)
endef

export BUILD_FILE_CONTENT

BUILD.bazel:
	echo "$$BUILD_FILE_CONTENT" >> $@
MK
                cat bazel-autobuild.mk
                ${{MAKE}} -f Makefile -f bazel-autobuild.mk BUILD.bazel
            else
                echo "Skipping erlang.mk import as make is unavailable"
            fi
        fi
    fi
fi

# fallback to BUILD file with just the name, version & deps
if [ ! -f BUILD.bazel ]; then
    if [ -n "{version}" ]; then
        if [ -n "{deps}" ]; then
            cat << EOF > BUILD.bazel
load("@rules_erlang//:erlang_app.bzl", "erlang_app")

erlang_app(
    app_name = "{name}",
    app_version = "{version}",
    erlc_opts = select({{
        "@rules_erlang//:debug_build": ["+debug_info"],
        "//conditions:default": ["+deterministic", "+debug_info"],
    }}),
    deps = {deps},
    stamp = 0,
    testonly = {testonly},
)
EOF
        fi
    fi
fi

# fallback to BUILD file with just the name and version
if [ ! -f BUILD.bazel ]; then
    if [ -n "{version}" ]; then
        cat << EOF > BUILD.bazel
load("@rules_erlang//:erlang_app.bzl", "erlang_app")

erlang_app(
    app_name = "{name}",
    app_version = "{version}",
    erlc_opts = select({{
        "@rules_erlang//:debug_build": ["+debug_info"],
        "//conditions:default": ["+deterministic", "+debug_info"],
    }}),
    stamp = 0,
    testonly = {testonly},
)
EOF
    fi
fi

# fallback to BUILD file with just the name
if [ ! -f BUILD.bazel ]; then
    cat << EOF > BUILD.bazel
load("@rules_erlang//:erlang_app.bzl", "erlang_app")

erlang_app(
    app_name = "{name}",
    erlc_opts = select({{
        "@rules_erlang//:debug_build": ["+debug_info"],
        "//conditions:default": ["+deterministic", "+debug_info"],
    }}),
    stamp = 0,
    testonly = {testonly},
)
EOF
fi
"""
