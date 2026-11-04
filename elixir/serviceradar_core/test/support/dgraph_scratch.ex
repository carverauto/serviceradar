defmodule ServiceRadar.TestSupport.DgraphScratch do
  @moduledoc """
  Owned scratch Dgraph namespace for core integration tests.

  Ported topology projection tests need a real Dgraph whose contents they
  fully own. Elixir cannot allocate namespaces through the topology NIF, so
  this helper drives the test-only `//rust/dgraph-topology:dgraph_scratch_cli`
  binary, which shares `tests/support/fixture.rs` with the Rust live tests:
  same typed CI fixture (`dgraph-ci`), same verified-CA connections, same
  create / drop / verify-absence lifecycle. `create` also applies and
  verifies the topology schema before printing the connection URL.

  Gating follows the three-state form test/test_helper.exs prescribes for
  environment-dependent suites (see adhoc_scan_nats_e2e_test.exs):

      @moduletag skip: ServiceRadar.TestSupport.DgraphScratch.fixture_state() == :unconfigured

      setup_all do
        TestSupport.start_core!()
        ServiceRadar.TestSupport.DgraphScratch.setup_scratch()
      end

  `DGRAPH_TEST_HOST` unset (local dev) skips the module. With the host set,
  a missing admin secret runs it and `setup_scratch/0` raises naming the
  missing variables, so a lost CI secret can never masquerade as "no
  fixture". Fully configured allocates the namespace.

  The helper points `DGRAPH_URL` at the scratch namespace for the module and
  restores the previous value on exit, so modules using it must run
  `async: false` in a serial lane. The namespace is dropped (and its absence
  verified by the CLI) on exit even when a test fails; a cleanup failure
  raises, mirroring the Rust fixture's assertion. Every write a test makes
  lives and dies inside the namespace.
  """

  @cli_relative "rust/dgraph-topology/dgraph_scratch_cli"
  @host_var "DGRAPH_TEST_HOST"

  # The lane presents the fixture through these variables (buildbuddy.yaml
  # --test_env); the CLI revalidates the full typed identity itself.
  @fixture_vars [@host_var, "SERVICERADAR_SECRET_DGRAPH_ADMIN_PASSWORD"]

  @doc """
  Three-state fixture detection, evaluated when the test module loads:
  `:unconfigured` (skip), `:partial` (fail loudly), `:configured` (run).
  """
  @spec fixture_state() :: :unconfigured | :partial | :configured
  def fixture_state do
    cond do
      @host_var in missing_vars() -> :unconfigured
      missing_vars() == [] -> :configured
      true -> :partial
    end
  end

  @doc """
  `setup_all` callback: allocate the scratch namespace and point
  `DGRAPH_URL` at it. Raises on partial configuration or CLI failure; the
  unconfigured state never reaches here because the module is skipped.
  """
  @spec setup_scratch() :: :ok
  def setup_scratch do
    case fixture_state() do
      :configured ->
        cli = cli_path!()
        %{namespace: namespace, url: url, ca_path: ca_path} = run_create!(cli)
        previous_url = System.get_env("DGRAPH_URL")
        System.put_env("DGRAPH_URL", url)

        ExUnit.Callbacks.on_exit(fn ->
          restore_env("DGRAPH_URL", previous_url)
          run_drop!(cli, namespace)
          File.rm(ca_path)
        end)

        :ok

      :partial ->
        raise "Dgraph CI fixture partially configured; missing: " <>
                Enum.join(missing_vars(), ", ")

      :unconfigured ->
        raise "DgraphScratch.setup_scratch/0 ran without a configured fixture; " <>
                "gate the module with @moduletag skip: DgraphScratch.fixture_state() == :unconfigured"
    end
  end

  defp present_vars do
    Enum.filter(@fixture_vars, &(System.get_env(&1) not in [nil, ""]))
  end

  defp missing_vars, do: @fixture_vars -- present_vars()

  defp cli_path! do
    tmpdir =
      System.get_env("TEST_TMPDIR") ||
        raise "TEST_TMPDIR unset: #{@cli_relative} is staged by Bazel"

    path = Path.join(tmpdir, @cli_relative)

    if File.regular?(path) do
      path
    else
      raise "dgraph_scratch_cli not found at #{path}; " <>
              "the integration lane must stage //rust/dgraph-topology:dgraph_scratch_cli as data"
    end
  end

  defp run_create!(cli) do
    case System.cmd(cli, ["create"], stderr_to_stdout: true) do
      {output, 0} ->
        fields =
          output
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn line ->
            case String.split(line, "=", parts: 2) do
              [key, value] when key in ["namespace", "url", "ca_path"] -> [{key, value}]
              _ -> []
            end
          end)
          |> Map.new()

        %{
          namespace: fetch_field!(fields, "namespace"),
          url: fetch_field!(fields, "url"),
          ca_path: fetch_field!(fields, "ca_path")
        }

      {output, status} ->
        raise "dgraph_scratch_cli create exited #{status}: #{String.trim(output)}"
    end
  end

  defp run_drop!(cli, namespace) do
    case System.cmd(cli, ["drop", namespace], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        raise "dgraph scratch cleanup failed: drop of namespace #{namespace} exited " <>
                "#{status}: #{String.trim(output)}"
    end
  end

  defp fetch_field!(fields, key) do
    case fields do
      %{^key => value} when value != "" -> value
      _ -> raise "dgraph_scratch_cli create output missing #{key}="
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
