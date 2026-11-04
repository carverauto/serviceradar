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

  No fixture variables at all (local dev) skips the module. A partial set
  runs it and `setup_scratch/0` raises naming the missing variables, so a
  lost CI secret can never masquerade as "no fixture". Fully configured
  allocates the namespace.

  The helper points `DGRAPH_URL` at the scratch namespace for the module and
  restores the previous value on exit, so modules using it must run
  `async: false` in a serial lane. The namespace is dropped (and its absence
  verified by the CLI) on exit even when a test fails; a cleanup failure
  raises, mirroring the Rust fixture's assertion. Every write a test makes
  lives and dies inside the namespace.
  """

  @cli_env "SERVICERADAR_DGRAPH_SCRATCH_CLI"
  @cli_runfile "rust/dgraph-topology/dgraph_scratch_cli"

  # The lane presents the fixture through these variables (buildbuddy.yaml
  # --test_env); the CLI revalidates the full typed identity itself.
  @fixture_vars ["DGRAPH_TEST_HOST", "SERVICERADAR_SECRET_DGRAPH_ADMIN_PASSWORD"]

  @doc """
  Three-state fixture detection, evaluated when the test module loads:
  `:unconfigured` (skip), `:partial` (fail loudly), `:configured` (run).
  """
  @spec fixture_state() :: :unconfigured | :partial | :configured
  def fixture_state do
    case {present_vars(), missing_vars()} do
      {[], _missing} -> :unconfigured
      {_present, []} -> :configured
      {_present, _missing} -> :partial
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
    candidates = Enum.reject([System.get_env(@cli_env), runfiles_path()], &is_nil/1)

    case Enum.find(candidates, &File.regular?/1) do
      nil ->
        raise "dgraph_scratch_cli not found (#{@cli_env} unset and no runfile at #{@cli_runfile}); " <>
                "the integration lane must stage //rust/dgraph-topology:dgraph_scratch_cli as data"

      path ->
        path
    end
  end

  defp runfiles_path do
    case System.get_env("RUNFILES_DIR") do
      dir when is_binary(dir) and dir != "" ->
        Path.join([dir, "serviceradar", @cli_runfile])

      _ ->
        nil
    end
  end

  defp run_create!(cli) do
    case System.cmd(cli, ["create"], stderr_to_stdout: false) do
      {output, 0} ->
        fields =
          output
          |> String.split("\n", trim: true)
          |> Map.new(fn line ->
            case String.split(line, "=", parts: 2) do
              [key, value] -> {key, value}
              _ -> raise "unexpected dgraph_scratch_cli create output line: #{inspect(line)}"
            end
          end)

        %{
          namespace: fetch_field!(fields, "namespace"),
          url: fetch_field!(fields, "url"),
          ca_path: fetch_field!(fields, "ca_path")
        }

      {_output, status} ->
        raise "dgraph_scratch_cli create exited #{status}"
    end
  end

  defp run_drop!(cli, namespace) do
    case System.cmd(cli, ["drop", namespace], stderr_to_stdout: false) do
      {_output, 0} ->
        :ok

      {_output, status} ->
        raise "dgraph scratch cleanup failed: drop of namespace #{namespace} exited #{status}"
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
