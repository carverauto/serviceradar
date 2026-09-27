"""Run the production world reader and Arrow encoder over declared invented input."""

load("@rules_elixir//private:elixir_toolchain.bzl", "elixir_dirs", "erlang_dirs", "erlang_preamble")
load("@rules_erlang//:erlang_app_info.bzl", "ErlangAppInfo", "flat_deps")
load("@rules_erlang//private:util.bzl", "erl_libs_contents")

def _impl(ctx):
    libs_name = ctx.label.name + "_deps"
    libs = erl_libs_contents(ctx, deps = flat_deps([ctx.attr.app]), headers = False, dir = libs_name)
    (_, release, erlang_files) = erlang_dirs(ctx)
    (elixir_home, elixir_files) = elixir_dirs(ctx)
    output = ctx.actions.declare_file(ctx.label.name + ".json")
    ctx.actions.run_shell(
        inputs = depset(
            ctx.files.srcs + libs + ([release] if release else []),
            transitive = [erlang_files.files, elixir_files.files],
        ),
        outputs = [output],
        command = erlang_preamble(ctx) + """
export PATH="$ABS_ERLANG_HOME/bin:$PWD/{elixir}/bin:$PATH"
export ERL_LIBS="$PWD/{libs}"
"{elixir}/bin/elixir" "$1" "$2" "$3"
""".format(elixir = elixir_home, libs = ctx.bin_dir.path + "/" + ctx.label.package + "/" + libs_name),
        arguments = [ctx.file.encoder.path, ctx.file.world.path, output.path],
        mnemonic = "TopologyWorldFixture",
        progress_message = "Encoding invented million-device world through production NIFs",
    )
    return [DefaultInfo(files = depset([output]))]

world_browser_fixture = rule(
    implementation = _impl,
    attrs = {
        "app": attr.label(mandatory = True, providers = [ErlangAppInfo]),
        "srcs": attr.label_list(allow_files = True),
        "encoder": attr.label(mandatory = True, allow_single_file = True),
        "world": attr.label(mandatory = True, allow_single_file = True),
    },
    toolchains = ["@rules_elixir//:toolchain_type"],
)
