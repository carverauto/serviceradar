ExUnit.start()

defmodule ServiceRadar.IntegrationSelectionEquivalenceTest do
  use ExUnit.Case, async: true

  @moduletag timeout: 180_000

  @identity_prefix "SERVICERADAR_SELECTION_IDENTITY|"
  @selected_runners_env "SERVICERADAR_SELECTION_SELECTED_RUNNERS"
  @load_only_runners_env "SERVICERADAR_SELECTION_LOAD_ONLY_RUNNERS"
  @dispositions "elixir/serviceradar_core/test/INTEGRATION_SOURCE_DISPOSITIONS.tsv"
  @header "source\tmodule\tcase_kind\tmode\treason\tevidence"
  @database_env ~w(
    DATABASE_URL
    PG_DATABASE_URL
    SRQL_TEST_DATABASE_URL
    SERVICERADAR_TEST_DATABASE_URL
    SRQL_TEST_DATABASE_URL_FILE
    SERVICERADAR_TEST_DATABASE_URL_FILE
  )

  test "selected sources match the disposition identities and load-only sources select nothing" do
    selected_runners = runner_names!(@selected_runners_env)

    load_only_runners = runner_names!(@load_only_runners_env)

    results = run_manifests!(selected_runners ++ load_only_runners)

    selected =
      Enum.reduce(selected_runners, MapSet.new(), fn runner, identities ->
        MapSet.union(identities, Map.fetch!(results, runner))
      end)

    expected = disposition_identities!()

    refute MapSet.size(expected) == 0, "disposition inventory unexpectedly selected no modules"

    missing = expected |> MapSet.difference(selected) |> Enum.sort()
    additional = selected |> MapSet.difference(expected) |> Enum.sort()

    assert missing == [] and additional == [], """
    selected-source ExUnit identities differ from the disposition inventory

    missing from selected-source run:
    #{format_identities(missing)}

    additional in selected-source run:
    #{format_identities(additional)}
    """

    leaking_load_only =
      for runner <- load_only_runners,
          identities = Map.fetch!(results, runner),
          MapSet.size(identities) > 0,
          do: {runner, Enum.sort(identities)}

    assert leaking_load_only == [], """
    a source classified load_only contains modules selected by the real ExUnit filters:
    #{format_load_only_leaks(leaking_load_only)}
    """
  end

  defp run_manifests!(tool_names) do
    tool_names
    |> Task.async_stream(&run_manifest!/1,
      max_concurrency: length(tool_names),
      ordered: false,
      timeout: 150_000
    )
    |> Map.new(fn
      {:ok, result} -> result
      {:exit, reason} -> flunk("integration selection loader failed: #{inspect(reason)}")
    end)
  end

  defp runner_names!(env) do
    case env |> System.fetch_env!() |> String.split(",", trim: true) do
      [] -> raise "#{env} must name at least one selection runner"
      runners -> runners
    end
  end

  defp run_manifest!(tool_name) do
    runfiles_root =
      Path.join([System.fetch_env!("TEST_SRCDIR"), System.fetch_env!("TEST_WORKSPACE")])

    tool = Path.join([runfiles_root, "elixir/serviceradar_core", tool_name])
    tool_tmp = Path.join(System.fetch_env!("TEST_TMPDIR"), tool_name)
    File.mkdir_p!(tool_tmp)

    # Each loader compiles with at most four workers. Give its BEAM the same scheduler budget so
    # the concurrent loaders do not oversubscribe one Bazel executor with hundreds of schedulers.
    env = [
      {"ELIXIR_ERL_OPTIONS", "+S 4:4 +fnu"},
      {"TEST_TMPDIR", tool_tmp}
      | Enum.map(@database_env, &{&1, ""})
    ]

    {output, status} =
      System.cmd(tool, [], cd: runfiles_root, env: env, stderr_to_stdout: true)

    if status != 0 do
      raise "#{tool_name} failed with status #{status}:\n#{output}"
    end

    identities =
      output
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, @identity_prefix))
      |> MapSet.new(&parse_identity!/1)

    {tool_name, identities}
  end

  defp disposition_identities! do
    path =
      Path.join([
        System.fetch_env!("TEST_SRCDIR"),
        System.fetch_env!("TEST_WORKSPACE"),
        @dispositions
      ])

    [header | rows] = path |> File.read!() |> String.split("\n", trim: true)

    if header != @header do
      raise "unexpected integration disposition header: #{inspect(header)}"
    end

    Enum.reduce(rows, MapSet.new(), fn row, identities ->
      case String.split(row, "\t", parts: 6) do
        [source, module, _case_kind, mode, _reason, _evidence]
        when mode in ["async", "serial"] and module != "-" ->
          MapSet.put(identities, {source, module})

        [_source, "-", _case_kind, "load_only", _reason, _evidence] ->
          identities

        fields ->
          raise "invalid integration disposition row: #{inspect(fields)}"
      end
    end)
  end

  defp parse_identity!(@identity_prefix <> encoded) do
    case String.split(encoded, "|", parts: 2) do
      [source, module] when source != "" and module != "" -> {source, module}
      _ -> raise ArgumentError, "malformed integration selection identity: #{inspect(encoded)}"
    end
  end

  defp format_identities([]), do: "  (none)"

  defp format_identities(identities) do
    Enum.map_join(identities, "\n", fn {source, module} -> "  #{source} | #{module}" end)
  end

  defp format_load_only_leaks([]), do: "  (none)"

  defp format_load_only_leaks(leaks) do
    Enum.map_join(leaks, "\n", fn {runner, identities} ->
      "  #{runner}:\n#{format_identities(identities)}"
    end)
  end
end
