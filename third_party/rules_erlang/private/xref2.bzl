load(
    "//:erlang_app_info.bzl",
    "ErlangAppInfo",
    "flat_deps",
)
load(
    "//:util.bzl",
    "path_join",
    "windows_path",
)
load(
    ":util.bzl",
    "erl_libs_contents",
    "to_erlang_atom_list",
    "to_erlang_string_list",
)
load(
    "//tools:erlang_toolchain.bzl",
    "erlang_dirs",
    "maybe_install_erlang",
)

def _replace_all(s, substitutions):
    for (p, r) in substitutions.items():
        s = s.replace(p, r)
    return s

def _expand_xref_erl(ctx, method = None, arg = None):
    for scope in ctx.attr.scopes:
        if not scope in ALLOWED_SCOPES:
            fail("scope {} is not one of {}", scope, ALLOWED_SCOPES)

    target_info = ctx.attr.target[ErlangAppInfo]

    erl_libs_dir = ctx.label.name + "_deps"
    erl_libs_files = erl_libs_contents(
        ctx,
        deps = flat_deps(target_info.deps) + ctx.attr.additional_libs + ctx.attr.extra_apps,
        dir = erl_libs_dir,
    )
    erl_libs_path = path_join(ctx.label.package, erl_libs_dir)

    extra_app_dirs = [
        path_join(erl_libs_dir, dep[ErlangAppInfo].app_name)
        for dep in ctx.attr.extra_apps
    ]

    # erlang.mk has a notion of deps and apps, which
    # is not explicit in rules_erlang, but approximately
    # corresponds to :erlang_app labels outside this
    # workspace, and within this workspace
    deps = []
    apps = []
    for app in target_info.deps:
        if app.label.workspace_root != "":
            deps.append(app)
        else:
            apps.append(app)

    deps_dirs = [
        path_join(erl_libs_path, dep[ErlangAppInfo].app_name)
        for dep in deps
    ]

    apps_dirs = [
        path_join(erl_libs_path, dep[ErlangAppInfo].app_name)
        for dep in apps
    ]

    extra_dirs = [f.short_path for f in ctx.files.extra_dirs]

    xref_erl = _replace_all(XREF_ERL, {
        SCOPE_PATTERN: to_erlang_atom_list(ctx.attr.scopes),
        EXTRA_APP_DIRS_PATTERN: to_erlang_string_list(extra_app_dirs),
        DEPS_DIRS_PATTERN: to_erlang_string_list(deps_dirs),
        APPS_DIRS_PATTERN: to_erlang_string_list(apps_dirs),
        TARGET_DIR_PATTERN: ".",
        EXTRA_DIRS_PATTERN: to_erlang_string_list(extra_dirs),
        IGNORE_CALLBACKS_PATTERN: ctx.attr.ignore_callbacks,
        IGNORE_PATTERN: to_erlang_atom_list(ctx.attr.ignore),
        "$1": method,
        "$2": arg,
    }).replace(
        '"',
        '\\"',
    ).replace(
        "\n",
        " ",
    )

    return (
        xref_erl,
        erl_libs_path,
        erl_libs_files,
    )

def _impl(ctx):
    (xref_erl, erl_libs_path, erl_libs_files) = _expand_xref_erl(
        ctx,
        method = "check",
        arg = to_erlang_atom_list(ctx.attr.checks),
    )

    (erlang_home, _, runfiles) = erlang_dirs(ctx)

    if not ctx.attr.is_windows:
        output = ctx.actions.declare_file(ctx.label.name)
        script = """\
#!/usr/bin/env bash
set -euo pipefail

{maybe_install_erlang}

export HOME=${{TEST_TMPDIR}}
export ERL_LIBS=$TEST_SRCDIR/$TEST_WORKSPACE/{erl_libs_path}

if [ -n "{package}" ]; then
    cd {package}
fi

"{erlang_home}"/bin/erl \\
    -noshell \\
    -eval "{xref_erl}" \\
    -pa ebin/
""".format(
            maybe_install_erlang = maybe_install_erlang(ctx, short_path = True),
            erlang_home = erlang_home,
            erl_libs_path = erl_libs_path,
            package = ctx.label.package,
            xref_erl = xref_erl,
        )
    else:
        output = ctx.actions.declare_file(ctx.label.name + ".bat")
        script = """@echo off

set ERL_LIBS=%TEST_SRCDIR%/%TEST_WORKSPACE%/{erl_libs_path}
set ERL_LIBS=%ERL_LIBS:/=\\%

if NOT [{package}] == [] cd {package}

"{erlang_home}\\bin\\erl" ^
    -noshell ^
    -eval "{xref_erl}" ^
    -pa ebin/
""".format(
            erlang_home = windows_path(erlang_home),
            erl_libs_path = erl_libs_path,
            xref_erl = xref_erl,
            package = ctx.label.package,
        ).replace("\n", "\r\n")

    ctx.actions.write(
        output = output,
        content = script,
    )

    runfiles = runfiles.merge(
        ctx.runfiles(ctx.attr.target[ErlangAppInfo].beam + erl_libs_files + ctx.files.extra_dirs),
    )

    return [DefaultInfo(
        runfiles = runfiles,
        executable = output,
    )]

ALLOWED_SCOPES = ["app", "apps", "deps", "otp"]

_XREF_ATTRS = {
    "is_windows": attr.bool(mandatory = True),
    "target": attr.label(
        providers = [ErlangAppInfo],
        mandatory = True,
    ),
    "checks": attr.string_list(
        default = ["undefined_function_calls"],
    ),
    "scopes": attr.string_list(
        default = ["app"],
    ),
    "extra_apps": attr.label_list(
        providers = [ErlangAppInfo],
    ),
    "extra_dirs": attr.label_list(
        allow_files = True,
    ),
    "ignore": attr.string_list(),
    "ignore_callbacks": attr.string(),
    "additional_libs": attr.label_list(
        providers = [ErlangAppInfo],
    ),
}

xref_test = rule(
    implementation = _impl,
    attrs = _XREF_ATTRS,
    toolchains = ["//tools:toolchain_type"],
    test = True,
)

def _query_impl(ctx):
    (xref_erl, erl_libs_path, erl_libs_files) = _expand_xref_erl(
        ctx,
        method = "query",
        arg = "\"$QUERY\"",
    )

    (erlang_home, _, runfiles) = erlang_dirs(ctx)

    if not ctx.attr.is_windows:
        output = ctx.actions.declare_file(ctx.label.name)
        script = """\
#!/usr/bin/env bash
set -euo pipefail

{maybe_install_erlang}

export ERL_LIBS=$PWD/{erl_libs_path}

if [ -n "{package}" ]; then
    cd {package}
fi

export QUERY="$1"

"{erlang_home}"/bin/erl \\
    -noshell \\
    -eval "{xref_erl}" \\
    -pa ebin/
""".format(
            maybe_install_erlang = maybe_install_erlang(ctx, short_path = True),
            erlang_home = erlang_home,
            erl_libs_path = erl_libs_path,
            package = ctx.label.package,
            xref_erl = xref_erl,
        )
    else:
        output = ctx.actions.declare_file(ctx.label.name + ".bat")
        script = """@echo off

set ERL_LIBS=%cd%/{erl_libs_path}

if NOT [{package}] == [] cd {package}

set QUERY=%1%

"{erlang_home}\\bin\\erl" ^
    -noshell ^
    -eval "{xref_erl}" ^
    -pa ebin/
""".format(
            erlang_home = windows_path(erlang_home),
            erl_libs_path = windows_path(erl_libs_path),
            package = ctx.label.package,
            xref_erl = xref_erl,
        ).replace("\n", "\r\n")

    ctx.actions.write(
        output = output,
        content = script,
    )

    runfiles = runfiles.merge(
        ctx.runfiles(ctx.attr.target[ErlangAppInfo].beam + erl_libs_files + ctx.files.extra_dirs),
    )

    return [DefaultInfo(
        runfiles = runfiles,
        executable = output,
    )]

xref_query = rule(
    implementation = _query_impl,
    attrs = _XREF_ATTRS,
    toolchains = ["//tools:toolchain_type"],
    executable = True,
)

# XREF_ERL is copied from erlang.mk
# https://github.com/ninenines/erlang.mk/blob/bf7a194b0b473186d14193eefdab9b65fa927443/plugins/xref.mk#L64-L210
XREF_ERL = """
{ok, Xref} = xref:start([]),
Scope = [$(call comma_list,$(XREF_SCOPE))],
AppDirs0 = [$(call comma_list,$(foreach d,$(XREF_EXTRA_APP_DIRS),"$d"))],
AppDirs1 = case lists:member(otp, Scope) of
    false -> AppDirs0;
    true ->
        RootDir = code:root_dir(),
        AppDirs0 ++ [filename:dirname(P) || P <- code:get_path(), lists:prefix(RootDir, P)]
end,
AppDirs2 = case lists:member(deps, Scope) of
    false -> AppDirs1;
    true -> [$(call comma_list,$(foreach d,$(ALL_DEPS_DIRS),"$d"))] ++ AppDirs1
end,
AppDirs3 = case lists:member(apps, Scope) of
    false -> AppDirs2;
    true -> [$(call comma_list,$(foreach d,$(ALL_APPS_DIRS),"$d"))] ++ AppDirs2
end,
AppDirs = case lists:member(app, Scope) of
    false -> AppDirs3;
    true -> ["../$(notdir $(CURDIR))"|AppDirs3]
end,
[{ok, _} = xref:add_application(Xref, AppDir, [{builtins, true}]) || AppDir <- AppDirs],
ExtraDirs = [$(call comma_list,$(foreach d,$(XREF_EXTRA_DIRS),"$d"))],
[{ok, _} = xref:add_directory(Xref, ExtraDir, [{builtins, true}]) || ExtraDir <- ExtraDirs],
ok = xref:set_library_path(Xref, code:get_path() -- (["ebin", "."] ++ AppDirs ++ ExtraDirs)),
Checks = case {$1, is_list($2)} of
    {check, true} -> $2;
    {check, false} -> [$2];
    {query, _} -> [$2]
end,
FinalRes = [begin
    IsInformational = case $1 of
        query -> true;
        check ->
            is_tuple(Check) andalso
                lists:member(element(1, Check),
                    [call, use, module_call, module_use, application_call, application_use])
    end,
    {ok, Res0} = case $1 of
        check -> xref:analyze(Xref, Check);
        query -> xref:q(Xref, Check)
    end,
    Res = case IsInformational of
        true -> Res0;
        false ->
            lists:filter(fun(R) ->
                {Mod, InMFA, MFA} = case R of
                    {InMFA0 = {M, _, _}, MFA0} -> {M, InMFA0, MFA0};
                    {M, _, _} -> {M, R, R}
                end,
                Attrs = try
                    Mod:module_info(attributes)
                catch error:undef ->
                    []
                end,
                InlineIgnores = lists:flatten([
                    [case V of
                        M when is_atom(M) -> {M, '_', '_'};
                        {F, A} -> {Mod, F, A};
                        _ -> V
                    end || V <- Values]
                || {ignore_xref, Values} <- Attrs]),
                BuiltinIgnores = [
                    {eunit_test, wrapper_test_exported_, 0}
                ],
                DoCallbackIgnores = case {Check, "$(strip $(XREF_IGNORE_CALLBACKS))"} of
                    {exports_not_used, ""} -> true;
                    {_, "0"} -> false;
                    _ -> true
                end,
                CallbackIgnores = case DoCallbackIgnores of
                    false -> [];
                    true ->
                        Behaviors = lists:flatten([
                            [BL || {behavior, BL} <- Attrs],
                            [BL || {behaviour, BL} <- Attrs]
                        ]),
                        [{Mod, CF, CA} || B <- Behaviors, {CF, CA} <- B:behaviour_info(callbacks)]
                end,
                WideIgnores = if
                    is_list($(XREF_IGNORE)) ->
                        [if is_atom(I) -> {I, '_', '_'}; true -> I end
                            || I <- $(XREF_IGNORE)];
                    true -> [$(XREF_IGNORE)]
                end,
                Ignores = InlineIgnores ++ BuiltinIgnores ++ CallbackIgnores ++ WideIgnores,
                not (lists:member(InMFA, Ignores)
                orelse lists:member(MFA, Ignores)
                orelse lists:member({Mod, '_', '_'}, Ignores))
            end, Res0)
    end,
    case Res of
        [] -> ok;
        _ when IsInformational ->
            case Check of
                {call, {CM, CF, CA}} ->
                    io:format("Functions that ~s:~s/~b calls:~n", [CM, CF, CA]);
                {use, {CM, CF, CA}} ->
                    io:format("Function ~s:~s/~b is called by:~n", [CM, CF, CA]);
                {module_call, CMod} ->
                    io:format("Modules that ~s calls:~n", [CMod]);
                {module_use, CMod} ->
                    io:format("Module ~s is used by:~n", [CMod]);
                {application_call, CApp} ->
                    io:format("Applications that ~s calls:~n", [CApp]);
                {application_use, CApp} ->
                    io:format("Application ~s is used by:~n", [CApp]);
                _ when $1 =:= query ->
                    io:format("Query ~s returned:~n", [Check])
            end,
            [case R of
                {{InM, InF, InA}, {M, F, A}} ->
                    io:format("- ~s:~s/~b called by ~s:~s/~b~n",
                        [M, F, A, InM, InF, InA]);
                {M, F, A} ->
                    io:format("- ~s:~s/~b~n", [M, F, A]);
                ModOrApp ->
                    io:format("- ~s~n", [ModOrApp])
            end || R <- Res],
            ok;
        _ ->
            [case {Check, R} of
                {undefined_function_calls, {{InM, InF, InA}, {M, F, A}}} ->
                    io:format("Undefined function ~s:~s/~b called by ~s:~s/~b~n",
                        [M, F, A, InM, InF, InA]);
                {undefined_functions, {M, F, A}} ->
                    io:format("Undefined function ~s:~s/~b~n", [M, F, A]);
                {locals_not_used, {M, F, A}} ->
                    io:format("Unused local function ~s:~s/~b~n", [M, F, A]);
                {exports_not_used, {M, F, A}} ->
                    io:format("Unused exported function ~s:~s/~b~n", [M, F, A]);
                {deprecated_function_calls, {{InM, InF, InA}, {M, F, A}}} ->
                    io:format("Deprecated function ~s:~s/~b called by ~s:~s/~b~n",
                        [M, F, A, InM, InF, InA]);
                {deprecated_functions, {M, F, A}} ->
                    io:format("Deprecated function ~s:~s/~b~n", [M, F, A]);
                _ ->
                    io:format("~p: ~p~n", [Check, R])
            end || R <- Res],
            error
    end
end || Check <- Checks],
stopped = xref:stop(Xref),
case lists:usort(FinalRes) of
    [ok] -> halt(0);
    _ -> halt(1)
end
"""

SCOPE_PATTERN = """[$(call comma_list,$(XREF_SCOPE))]"""
EXTRA_APP_DIRS_PATTERN = """[$(call comma_list,$(foreach d,$(XREF_EXTRA_APP_DIRS),"$d"))]"""
DEPS_DIRS_PATTERN = """[$(call comma_list,$(foreach d,$(ALL_DEPS_DIRS),"$d"))]"""
APPS_DIRS_PATTERN = """[$(call comma_list,$(foreach d,$(ALL_APPS_DIRS),"$d"))]"""
TARGET_DIR_PATTERN = """../$(notdir $(CURDIR))"""
EXTRA_DIRS_PATTERN = """[$(call comma_list,$(foreach d,$(XREF_EXTRA_DIRS),"$d"))]"""
IGNORE_CALLBACKS_PATTERN = """$(strip $(XREF_IGNORE_CALLBACKS))"""
IGNORE_PATTERN = """$(XREF_IGNORE)"""
