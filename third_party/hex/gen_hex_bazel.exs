#!/usr/bin/env elixir
#
# Generate Bazel repository declarations and BUILD stubs from a mix.lock.
#
# Do not run this by hand -- it is the source of a Bazel target:
#   bazel run //third_party/hex:gen        regenerate in place
#   bazel test //third_party/hex:gen_test  fail if the checked-in tree is stale
#
# Usage (what those targets invoke):
#   elixir gen_hex_bazel.exs --out-dir <dir> elixir/*/mix.lock
#
# Pass every project's lock. Bazel repositories are global -- @hex_ecto can only be
# one version -- so the locks must already agree on a version for each package. This
# script asserts that rather than silently picking one.
#
# Writes, into --out-dir:
#   <pkg>.BUILD       one per Hex package
#   hex_packages.bzl  the closure as data, loaded by //third_party/hex:extensions.bzl
#
# Why generate rather than hand-write: mix.lock already carries everything Bazel
# needs -- version, outer tarball checksum, build tools, and the resolved dep
# graph including which deps are optional. Hand-maintaining 137 stubs against a
# lock file that changes is how the two drift apart. mix.lock is valid Elixir
# term syntax, so this reads it with Code.eval_file rather than a regex.

defmodule GenHexBazel do
  @default_out_dir "third_party/hex"

  # Packages that are NOT compiled from source by us. Nothing here yet; entries
  # get added with a reason as we hit packages Bazel cannot build.
  @skip %{}

  # First-party projects that override a Hex dependency via `path:` in mix.exs.
  # These never appear as mix.lock entries -- the override replaces the registry
  # resolution entirely -- but Hex packages still declare a dependency edge to
  # them (gnat -> connection). Without this map that edge is silently dropped and
  # the dependent fails with "module Connection is not loaded and could not be
  # found", which reads like a missing dep rather than a shadowed one.
  # Labels must be @serviceradar-qualified: these BUILD files are evaluated inside
  # the @hex_<pkg> external repositories, where a bare //elixir/... would resolve
  # against the Hex package rather than the main repo.
  @path_deps %{
    # Not a path dep, but the same problem: bundlex is pinned from git, so it is never a
    # Hex lock entry and the edge to it would be dropped. It is declared by hand as a
    # git_pkg in //third_party/hex:extensions.bzl, which puts it in the same extension
    # as the fetched packages -- that is why a sibling stub can still name it directly.
    "bundlex" => "@hex_bundlex//:erlang_app",
    "connection" => "@serviceradar//third_party/hex_vendored/connection:erlang_app",
    "elixir_uuid" => "@serviceradar//third_party/hex_vendored/elixir_uuid:erlang_app",
    "opentelemetry_oban" => "@serviceradar//third_party/hex_vendored/opentelemetry_oban:erlang_app",
    "serviceradar_srql" => "@serviceradar//elixir/serviceradar_srql:erlang_app"
  }

  def main(argv) do
    {opts, lock_paths} = OptionParser.parse!(argv, strict: [out_dir: :string])
    run(Keyword.get(opts, :out_dir, @default_out_dir), lock_paths)
  end

  def run(out_dir, lock_paths) when lock_paths != [] do
    lock = merge_locks(lock_paths)

    entries =
      lock
      |> Enum.map(fn {name, tuple} -> parse(name, tuple) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.name)

    non_hex =
      lock
      |> Enum.reject(fn {_, t} -> elem(t, 0) == :hex end)
      |> Enum.map(fn {n, t} -> "#{n} (#{elem(t, 0)})" end)

    if non_hex != [], do: warn("non-hex lock entries, declare by hand: #{Enum.join(non_hex, ", ")}")

    in_lock = MapSet.new(entries, & &1.name)

    File.mkdir_p!(out_dir)
    Enum.each(entries, &write_build(out_dir, &1, in_lock))
    write_packages_bzl(out_dir, entries)
    prune(out_dir, entries)

    by_tool = Enum.frequencies_by(entries, &tool/1)
    IO.puts("\ngenerated #{length(entries)} packages: #{inspect(by_tool)}")
  end

  def run(_out_dir, _),
    do: warn("usage: gen_hex_bazel.exs [--out-dir DIR] <path/to/mix.lock> [more locks...]")

  # Merge every project's lock into one map, resolving disagreements to the highest version.
  #
  # A Bazel repository name is global -- @hex_castore can only be one version -- so when the
  # projects disagree, something has to choose. Before this was explicit the choice was made
  # by whoever last pasted the generated block into MODULE.bazel, which is why the tree drifted
  # to versions no lock asked for. Highest-wins is the same rule Mix itself applies when one
  # project resolves a diamond, so the Bazel closure lands on a version at least one project
  # has already resolved against, rather than an arbitrary older one.
  #
  # Every resolution is reported, because a disagreement is still a lockfile bug: the project
  # on the losing side compiles against one version under Mix and another under Bazel.
  defp merge_locks(paths) do
    merged =
      paths
      |> Enum.reduce(%{}, fn path, acc ->
        {lock, _} = Code.eval_file(path)
        Enum.reduce(lock, acc, fn {name, tuple}, acc -> Map.update(acc, name, [{path, tuple}], &[{path, tuple} | &1]) end)
      end)
      |> Map.new(fn {name, candidates} -> {name, Enum.reverse(candidates)} end)

    for {name, candidates} <- Enum.sort(merged),
        distinct = candidates |> Enum.map(&describe_version(elem(&1, 1))) |> Enum.uniq(),
        length(distinct) > 1 do
      warn(
        "#{name} disagrees across locks, taking the highest:\n" <>
          Enum.map_join(candidates, "\n", fn {p, t} -> "    #{describe_version(t)}  #{p}" end)
      )
    end

    Map.new(merged, fn {name, candidates} -> {name, highest(candidates)} end)
  end

  # A non-hex entry (a git pin) has no comparable version; sort it below everything so a
  # real Hex version always wins, and it only survives when it is the sole candidate.
  @unversioned Version.parse!("0.0.0")

  defp highest(candidates) do
    candidates
    |> Enum.map(&elem(&1, 1))
    |> Enum.max_by(&comparable_version/1, Version)
  end

  defp comparable_version(tuple) do
    case version_of(tuple) do
      version when is_binary(version) ->
        case Version.parse(version) do
          {:ok, parsed} -> parsed
          :error -> @unversioned
        end

      _ ->
        @unversioned
    end
  end

  defp version_of({:hex, _pkg, version, _inner, _tools, _deps, _repo, _outer}), do: version
  defp version_of(_other), do: nil

  defp describe_version(tuple) do
    case version_of(tuple) do
      nil -> "#{elem(tuple, 0)} pin"
      version -> version
    end
  end

  # {:hex, :pkg, version, inner_checksum, build_tools, deps, "hexpm", outer_checksum}
  defp parse(name, {:hex, pkg, version, _inner, tools, deps, _repo, outer}) do
    name = to_string(name)

    if Map.has_key?(@skip, name) do
      nil
    else
      %{
        name: name,
        pkg: to_string(pkg),
        version: version,
        sha256: outer,
        tools: tools,
        deps:
          deps
          |> Enum.map(fn {dep, _req, opts} -> {to_string(dep), Keyword.get(opts, :optional, false)} end)
      }
    end
  end

  defp parse(_name, _other), do: nil

  # A package is built by Mix when :mix is among its build tools. Hex sometimes
  # records an empty tool list for Mix packages (phoenix 1.8.11, ex_sdp 1.2.0);
  # those still ship mix.exs and cannot be compiled as a bare erlang_app.
  # Rebar/erlang.mk packages always list :rebar3 or :make.
  defp tool(%{tools: tools}) do
    cond do
      :mix in tools -> :mix
      tools == [] -> :mix
      true -> :erlang
    end
  end

  # Optional deps that were never resolved into the lock are not real edges --
  # except where a first-party path override is why the dep is missing.
  defp resolved_deps(%{deps: deps}, in_lock) do
    deps
    |> Enum.filter(fn {dep, optional} ->
      (MapSet.member?(in_lock, dep) or Map.has_key?(@path_deps, dep)) and not skipped?(dep, optional)
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp skipped?(dep, _optional), do: Map.has_key?(@skip, dep)

  defp dep_label(dep), do: Map.get(@path_deps, dep, "@hex_#{dep}//:erlang_app")

  defp write_build(out_dir, entry, in_lock) do
    deps = resolved_deps(entry, in_lock)
    body = if tool(entry) == :mix, do: mix_build(entry, deps), else: erlang_build(entry, deps)
    File.write!(Path.join(out_dir, "#{entry.name}.BUILD"), body)
  end

  defp dep_labels(deps, indent) do
    Enum.map_join(deps, "", fn d -> "\n#{indent}\"#{dep_label(d)}\"," end)
  end

  defp mix_build(entry, deps) do
    all_deps = dep_labels(deps, "        ") <> "\n        \"@rules_elixir//elixir\","

    """
    load("@serviceradar//build:hex_compile_env.bzl", "HEX_COMPILE_ENV_CONFIG")
    load("@serviceradar//build:mix_app.bzl", "mix_app")

    package(default_visibility = ["//visibility:public"])

    # Generated by //third_party/hex:gen -- do not edit by hand.
    #
    # A Hex package is a Mix project. Compiling it with Mix -- rather than invoking
    # elixirc from the execroot -- is what makes mix.exs (elixirc_paths, :compilers),
    # Mix.Project introspection, and cwd-relative compile-time file reads work.
    # See //build:mix_app.bzl.
    filegroup(
        name = "sources",
        srcs = glob(
            ["**/*"],
            allow_empty = True,
        ),
    )

    mix_app(
        name = "erlang_app",
        app_name = "#{entry.name}",
        srcs = [":sources"],
        hdrs = glob(
            ["include/**/*.hrl"],
            allow_empty = True,
        ),
        # A dependency reading a key with Application.compile_env/3 records what it saw,
        # and the release refuses to boot if that disagrees with the sys.config it applies.
        # Each package compiles in its own sandbox here, so the root config has to be handed
        # to it explicitly. See //build:hex_compile_env.bzl.
        extra_config = HEX_COMPILE_ENV_CONFIG,
        deps = [#{all_deps}
        ],
    )
    """
  end

  defp erlang_build(entry, deps) do
    dep_attr = if deps == [], do: "", else: "\n    deps = [#{dep_labels(deps, "        ")}\n    ],"

    """
    load("@rules_erlang//:erlang_app.bzl", "DEFAULT_ERLC_OPTS", "erlang_app")
    load("@rules_erlang//:util.bzl", "without")

    package(default_visibility = ["//visibility:public"])

    # Generated by //third_party/hex:gen -- do not edit by hand.
    # Build tools: #{inspect(entry.tools)} -- compiled as an Erlang app, not via Mix.
    erlang_app(
        app_name = "#{entry.name}",
        # rules_erlang defaults to -Werror, which is right for first-party code and wrong
        # for a third-party package we do not control: opentelemetry ships an exported-from-
        # case warning that has nothing to do with us, and failing on it just means the
        # dependency cannot be built at all.
        erlc_opts = without("-Werror", DEFAULT_ERLC_OPTS),#{dep_attr}
    )
    """
  end

  # The closure as data, for //third_party/hex:extensions.bzl to hand to
  # @rules_erlang//bzlmod:hex_packages.bzl. This used to be a block of
  # hex_archive() calls pasted into MODULE.bazel by hand -- 2,167 lines of it,
  # and a paste step that nothing enforced. A tuple per package keeps the
  # generated file one line per package; extensions.bzl gives the fields names.
  defp write_packages_bzl(out_dir, entries) do
    rows =
      Enum.map_join(entries, "\n", fn e ->
        ~s|    ("#{e.name}", "#{e.pkg}", "#{e.version}", "#{e.sha256}"),|
      end)

    body = """
    \"\"\"The resolved Hex closure, generated by //third_party/hex:gen -- do not edit by hand.

    Regenerate with `bazel run //third_party/hex:gen`; `bazel test //third_party/hex:gen_test`
    fails when this disagrees with the mix.lock files.

    Each row is (app_name, hex_package_name, version, sha256). The two names differ where a
    package ships under another name on hex.pm -- chatterbox is published as ts_chatterbox.
    sha256 is the OUTER tarball checksum, the last field of a mix.lock entry, because that is
    what hex_archive downloads.
    \"\"\"

    HEX_PACKAGES = [
    #{rows}
    ]
    """

    File.write!(Path.join(out_dir, "hex_packages.bzl"), body)
  end

  # Drop stubs for packages that have left the closure. Only files carrying the generated
  # marker are eligible: bundlex's stub is hand-written precisely because the generator
  # cannot emit it, and deleting it would break every package that depends on it.
  @marker "do not edit by hand"

  defp prune(out_dir, entries) do
    keep = MapSet.new(entries, &"#{&1.name}.BUILD")

    out_dir
    |> Path.join("*.BUILD")
    |> Path.wildcard()
    |> Enum.reject(&MapSet.member?(keep, Path.basename(&1)))
    |> Enum.filter(&String.contains?(File.read!(&1), @marker))
    |> Enum.each(fn path ->
      IO.puts("pruned #{Path.basename(path)} -- no longer in any mix.lock")
      File.rm!(path)
    end)
  end

  defp warn(msg), do: IO.puts(:stderr, "WARNING: #{msg}")
end

GenHexBazel.main(System.argv())
