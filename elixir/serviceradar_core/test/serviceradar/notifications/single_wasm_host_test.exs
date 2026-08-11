defmodule ServiceRadar.Notifications.SingleWasmHostTest do
  @moduledoc """
  There is exactly ONE Wasm host implementation in the product (tasks 3.3.3).

  This is not a style rule. A second host means reimplementing the entire guest
  ABI - 27 host functions exported into module `env`, the ptr/len guest-memory
  convention, the `pluginErr*` return codes, per-call capability gating,
  domain/port allowlists, redirect suppression on credential-bearing requests,
  TLS trust, and credential injection - and then keeping two implementations
  behaviourally identical forever. `AGENTS.md` bans exactly that
  parallel-implementation shape for the anomaly detector, and design.md
  ("Rejected: a second, server-side Wasm host in core") bans it here.

  It is also the reason the notification platform has a `:wasm_plugin` tier at
  all: `:control_plane` plugin execution dispatches `plugin.run_action` to the
  platform-resident `serviceradar-agent`, which already IS a central wazero
  host, so no NIF and no sidecar was needed. The moment a Rustler/wasmtime NIF
  or a second Go host appears, that reasoning is dead and this change's design
  needs revisiting - so the test fails loudly rather than letting the second
  host arrive quietly.

  ## What it checks

    1. No Elixir project declares a Wasm runtime dependency. This is the one an
       innocent-looking PR could add: `{:wasmex, "~> 0.9"}` in `serviceradar_core`
       would put a host in the same OS process as the dispatcher.
    2. No Rust crate declares one. `serviceradar-anomaly-core` and the add-ons
       are the crates most likely to reach for an embedded runtime.
    3. Exactly one Go package imports wazero, and it is `go/pkg/agent`.

  A legitimate second host - a test harness, say - is not silently accommodated:
  it is added to `@allowed_go_hosts` with a comment, which is a decision someone
  reviews rather than a diff nobody notices.
  """

  use ExUnit.Case, async: true

  # Needs a full checkout, so it cannot run in the Bazel sandbox.
  #
  # This walks the whole repository - every Go file, every mix.exs, every
  # Cargo.toml - to assert that exactly one Wasm host exists. `ex_unit_test`
  # stages only declared srcs and data, so under Bazel the walk sees a handful of
  # staged files and the guard becomes VACUOUS: "exactly one host" holds
  # trivially when nothing else is present. Declaring the repository as data to
  # fix that would make one architecture check an input to a unit-test target.
  #
  # So it is excluded from the sandboxed tier by tag rather than silently
  # passing there. That is a real weakness and worth saying plainly: nothing runs
  # it by default today. Run it deliberately from a full checkout with
  # `mix test --include external test/serviceradar/notifications/single_wasm_host_test.exs`,
  # and see task 4.4.7 for wiring it into a repo-scanning tier where it belongs.
  @moduletag :external

  @repo_root Path.expand("../../../../..", __DIR__)

  # Every embedded Wasm runtime a caller might plausibly reach for. Spelled as
  # dependency-declaration fragments rather than free text so a mention in a
  # comment or a moduledoc (this file's own prose, for instance) does not trip
  # the check.
  @elixir_runtime_deps ~w(:wasmex :wasmtime :wasmer :extism :wasm3 :wasmedge)
  @rust_runtime_crates ~w(wasmtime wasmer wasmi wasm3 wasmedge extism wasm-bridge)

  # go/pkg/agent is THE host. Anything else importing wazero is a second one.
  @allowed_go_hosts ["go/pkg/agent"]

  @wazero_import "github.com/tetratelabs/wazero"

  describe "no second host in Elixir" do
    test "no mix.exs declares a Wasm runtime dependency" do
      offenders =
        @repo_root
        |> Path.join("elixir/*/mix.exs")
        |> Path.wildcard()
        |> Enum.filter(&declares_elixir_runtime?/1)
        |> Enum.map(&relative/1)

      assert offenders == [],
             """
             #{Enum.join(offenders, ", ")} declares an embedded Wasm runtime.

             The product has exactly one Wasm host: wazero inside Go `package agent`.
             A second host must reimplement the whole 27-function guest ABI and stay
             behaviourally identical to the first forever. `:control_plane` plugin
             notifications reach the SAME host by dispatching plugin.run_action to the
             platform-resident serviceradar-agent; if that is not workable for a new
             requirement, change the design deliberately rather than adding a runtime.
             """
    end
  end

  describe "no second host in Rust" do
    test "no crate declares a Wasm runtime dependency" do
      offenders =
        cargo_manifests()
        |> Enum.filter(&declares_rust_runtime?/1)
        |> Enum.map(&relative/1)

      assert offenders == [],
             """
             #{Enum.join(offenders, ", ")} declares an embedded Wasm runtime.

             See the moduledoc: one host, in go/pkg/agent. A Rust host would also be a
             second implementation of the credential-injection and capability-gating
             rules that keep secrets out of guest memory.
             """
    end
  end

  describe "exactly one host in Go" do
    test "only go/pkg/agent imports wazero" do
      importers =
        @repo_root
        |> Path.join("go/**/*.go")
        |> Path.wildcard()
        |> Enum.filter(&imports_wazero?/1)
        |> Enum.map(&(&1 |> relative() |> Path.dirname()))
        |> Enum.uniq()
        |> Enum.sort()

      assert importers == @allowed_go_hosts,
             """
             Wasm host packages changed. Expected exactly #{inspect(@allowed_go_hosts)}, found #{inspect(importers)}.

             Adding a package here adds a second Wasm host unless it is a harness that
             deliberately shares the same runtime. Either way it is a decision: add it to
             @allowed_go_hosts with the reason, or remove the import.
             """
    end

    test "the one host is the one the notification dispatch path reaches" do
      # Cheap corroboration that @allowed_go_hosts names the real host rather
      # than an empty directory that happens to match: the capability gate and
      # the runtime instantiation both live there.
      agent = Path.join(@repo_root, "go/pkg/agent")

      assert File.exists?(Path.join(agent, "plugin_runtime_wazero.go"))
      assert File.exists?(Path.join(agent, "plugin_runtime_notify.go"))
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp declares_elixir_runtime?(path) do
    source = File.read!(path)

    Enum.any?(@elixir_runtime_deps, fn dep ->
      String.contains?(source, "{" <> dep <> ",")
    end)
  end

  defp cargo_manifests do
    ["Cargo.toml", "rust/*/Cargo.toml", "rust/*/*/Cargo.toml", "addons/*/Cargo.toml"]
    |> Enum.flat_map(&Path.wildcard(Path.join(@repo_root, &1)))
    |> Enum.reject(&String.contains?(&1, "/target/"))
    |> Enum.reject(&String.contains?(&1, "/third_party/"))
  end

  defp declares_rust_runtime?(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.any?(fn line ->
      Enum.any?(@rust_runtime_crates, fn crate ->
        String.starts_with?(line, crate <> " =") or String.starts_with?(line, crate <> "=") or
          String.starts_with?(line, "[dependencies." <> crate <> "]")
      end)
    end)
  end

  defp imports_wazero?(path) do
    path |> File.read!() |> String.contains?("\"" <> @wazero_import)
  end

  defp relative(path), do: Path.relative_to(path, @repo_root)
end
