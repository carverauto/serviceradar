#!/usr/bin/env elixir
#
# Generate Bazel repository declarations and BUILD stubs from a mix.lock.
#
# Usage:
#   elixir scripts/gen_hex_bazel.exs elixir/*/mix.lock
#
# Pass every project's lock. Bazel repositories are global -- @hex_ecto can only be
# one version -- so the locks must already agree on a version for each package. This
# script asserts that rather than silently picking one.
#
# Writes:
#   third_party/hex/<pkg>.BUILD          one per Hex package
#   third_party/hex/hex_archives.MODULE  the hex_archive() block to paste into MODULE.bazel
#
# Why generate rather than hand-write: mix.lock already carries everything Bazel
# needs -- version, outer tarball checksum, build tools, and the resolved dep
# graph including which deps are optional. Hand-maintaining 137 stubs against a
# lock file that changes is how the two drift apart. mix.lock is valid Elixir
# term syntax, so this reads it with Code.eval_file rather than a regex.

defmodule GenHexBazel do
  @out_dir "third_party/hex"

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
    # Hex lock entry and the edge to it would be dropped. It is declared by hand in
    # MODULE.bazel; packages that name it need to resolve to that repo.
    "bundlex" => "@hex_bundlex//:erlang_app",
    "connection" => "@serviceradar//elixir/connection:erlang_app",
    "elixir_uuid" => "@serviceradar//elixir/elixir_uuid:erlang_app",
    "opentelemetry_oban" => "@serviceradar//elixir/vendor/opentelemetry_oban:erlang_app",
    "serviceradar_srql" => "@serviceradar//elixir/serviceradar_srql:erlang_app"
  }

  def run(lock_paths) when lock_paths != [] do
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

    File.mkdir_p!(@out_dir)
    Enum.each(entries, &write_build(&1, in_lock))
    write_module(entries)

    by_tool = Enum.frequencies_by(entries, &tool/1)
    IO.puts("\ngenerated #{length(entries)} packages: #{inspect(by_tool)}")
  end

  def run(_), do: warn("usage: gen_hex_bazel.exs <path/to/mix.lock> [more locks...]")

  # Merge every project's lock into one map, failing loudly on a version disagreement.
  # A Bazel repository name is global, so two projects wanting different versions of the
  # same package cannot both be satisfied; unify the lockfiles instead of guessing here.
  defp merge_locks(paths) do
    Enum.reduce(paths, %{}, fn path, acc ->
      {lock, _} = Code.eval_file(path)

      Enum.reduce(lock, acc, fn {name, tuple}, acc ->
        case Map.fetch(acc, name) do
          {:ok, existing} when existing != tuple ->
            raise """
            #{name} is locked at two different versions across projects:
              #{inspect(version_of(existing))} and #{inspect(version_of(tuple))} (#{path})
            Bazel repositories are global; unify the lockfiles first.
            """

          _ ->
            Map.put(acc, name, tuple)
        end
      end)
    end)
  end

  defp version_of({:hex, _pkg, version, _inner, _tools, _deps, _repo, _outer}), do: version
  defp version_of(other), do: other

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

  # A package is built by Mix when :mix is among its build tools; anything else
  # (rebar3, plain erlang.mk makefiles) compiles as an Erlang app.
  defp tool(%{tools: tools}), do: if(:mix in tools, do: :mix, else: :erlang)

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

  defp write_build(entry, in_lock) do
    deps = resolved_deps(entry, in_lock)
    body = if tool(entry) == :mix, do: mix_build(entry, deps), else: erlang_build(entry, deps)
    File.write!(Path.join(@out_dir, "#{entry.name}.BUILD"), body)
  end

  defp dep_labels(deps, indent) do
    Enum.map_join(deps, "", fn d -> "\n#{indent}\"#{dep_label(d)}\"," end)
  end

  defp mix_build(entry, deps) do
    all_deps = dep_labels(deps, "        ") <> "\n        \"@rules_elixir//elixir\","

    """
    load("@serviceradar//build:mix_app.bzl", "mix_app")

    package(default_visibility = ["//visibility:public"])

    # Generated by scripts/gen_hex_bazel.exs -- do not edit by hand.
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

    # Generated by scripts/gen_hex_bazel.exs -- do not edit by hand.
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

  defp write_module(entries) do
    block =
      Enum.map_join(entries, "\n", fn e ->
        """
        hex_archive(
            name = "hex_#{e.name}",
            build_file = "//third_party/hex:#{e.name}.BUILD",
            package_name = "#{e.pkg}",
            sha256 = "#{e.sha256}",
            version = "#{e.version}",
        )
        """
      end)

    File.write!(Path.join(@out_dir, "hex_archives.MODULE"), block)
  end

  defp warn(msg), do: IO.puts(:stderr, "WARNING: #{msg}")
end

GenHexBazel.run(System.argv())
