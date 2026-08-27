ExUnit.start()

defmodule ServiceRadar.IntegrationSelectionEquivalenceTest do
  use ExUnit.Case, async: true

  @moduletag timeout: 180_000

  @identity_prefix "SERVICERADAR_SELECTION_IDENTITY|"
  @selected_runners_env "SERVICERADAR_SELECTION_SELECTED_RUNNERS"
  @load_only_runners_env "SERVICERADAR_SELECTION_LOAD_ONLY_RUNNERS"
  @dispositions "elixir/serviceradar_core/test/INTEGRATION_SOURCE_DISPOSITIONS.tsv"
  @projection "build/integration_test_dispositions.bzl"
  @header "source\tmodule\tcase_kind\tmode\treason\tevidence"
  @database_env ~w(
    DATABASE_URL
    PG_DATABASE_URL
    SRQL_TEST_DATABASE_URL
    SERVICERADAR_TEST_DATABASE_URL
    SRQL_TEST_DATABASE_URL_FILE
    SERVICERADAR_TEST_DATABASE_URL_FILE
  )

  test "all-source and pruned runs select identical tests and match disposition modules" do
    selected_runners = runner_names!(@selected_runners_env)

    load_only_runners = runner_names!(@load_only_runners_env)

    results = run_manifests!(selected_runners ++ load_only_runners)

    selected =
      Enum.reduce(selected_runners, MapSet.new(), fn runner, identities ->
        MapSet.union(identities, Map.fetch!(results, runner))
      end)

    all_source =
      Enum.reduce(selected_runners ++ load_only_runners, MapSet.new(), fn runner, identities ->
        MapSet.union(identities, Map.fetch!(results, runner))
      end)

    refute MapSet.size(all_source) == 0, "all-source control unexpectedly selected no tests"

    missing = all_source |> MapSet.difference(selected) |> Enum.sort()
    additional = selected |> MapSet.difference(all_source) |> Enum.sort()

    assert missing == [] and additional == [], """
    pruned-source ExUnit test identities differ from the all-source control

    missing from pruned-source run:
    #{format_identities(missing)}

    additional in pruned-source run:
    #{format_identities(additional)}
    """

    selected_modules =
      MapSet.new(selected, fn {source, module, _test_name} -> {source, module} end)

    expected_modules = disposition_module_identities!()
    missing_modules = expected_modules |> MapSet.difference(selected_modules) |> Enum.sort()
    additional_modules = selected_modules |> MapSet.difference(expected_modules) |> Enum.sort()

    assert missing_modules == [] and additional_modules == [], """
    selected-source ExUnit modules differ from the disposition inventory

    missing selected modules:
    #{format_module_identities(missing_modules)}

    additional selected modules:
    #{format_module_identities(additional_modules)}
    """

    serial_sources = disposition_sources!("serial")

    selected_serial_counts =
      selected
      |> Enum.frequencies_by(fn {source, _module, _test_name} -> source end)
      |> Map.take(serial_sources)

    assert projected_serial_test_counts!() == selected_serial_counts,
           "checked-in serial selected-test counts differ from the real ExUnit selection manifest"

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

  defp disposition_module_identities! do
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

  defp disposition_sources!(mode) do
    path = runfile_path!(@dispositions)
    [header | rows] = path |> File.read!() |> String.split("\n", trim: true)

    if header != @header do
      raise "unexpected integration disposition header: #{inspect(header)}"
    end

    rows
    |> Enum.flat_map(fn row ->
      case String.split(row, "\t", parts: 6) do
        [source, _module, _case_kind, ^mode, _reason, _evidence] -> [source]
        [_source, _module, _case_kind, _other_mode, _reason, _evidence] -> []
        fields -> raise "invalid integration disposition row: #{inspect(fields)}"
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp projected_serial_test_counts! do
    projection = @projection |> runfile_path!() |> File.read!()

    entries =
      case Regex.run(
             ~r/SERIAL_INTEGRATION_SELECTED_TEST_COUNTS = \{\n(.*?)\n\}/s,
             projection,
             capture: :all_but_first
           ) do
        [entries] -> entries
        nil -> raise "SERIAL_INTEGRATION_SELECTED_TEST_COUNTS is missing from #{@projection}"
      end

    counts =
      ~r/^    "([^"]+)": ([0-9]+),$/m
      |> Regex.scan(entries, capture: :all_but_first)
      |> Map.new(fn [source, count] -> {source, String.to_integer(count)} end)

    if map_size(counts) == 0 do
      raise "SERIAL_INTEGRATION_SELECTED_TEST_COUNTS contains no entries"
    end

    counts
  end

  defp runfile_path!(relative_path) do
    Path.join([
      System.fetch_env!("TEST_SRCDIR"),
      System.fetch_env!("TEST_WORKSPACE"),
      relative_path
    ])
  end

  defp parse_identity!(@identity_prefix <> encoded) do
    case String.split(encoded, "|", parts: 3) do
      [source, module, test_name] ->
        decoded =
          Enum.map([source, module, test_name], &Base.url_decode64!(&1, padding: false))

        case decoded do
          [source, module, test_name]
          when source != "" and module != "" and test_name != "" ->
            {source, module, test_name}

          _ ->
            raise ArgumentError,
                  "empty integration selection identity component: #{inspect(decoded)}"
        end

      _ ->
        raise ArgumentError, "malformed integration selection identity: #{inspect(encoded)}"
    end
  end

  defp format_identities([]), do: "  (none)"

  defp format_identities(identities) do
    Enum.map_join(identities, "\n", fn {source, module, test_name} ->
      "  #{source} | #{module} | #{test_name}"
    end)
  end

  defp format_module_identities([]), do: "  (none)"

  defp format_module_identities(identities) do
    Enum.map_join(identities, "\n", fn {source, module} -> "  #{source} | #{module}" end)
  end

  defp format_load_only_leaks([]), do: "  (none)"

  defp format_load_only_leaks(leaks) do
    Enum.map_join(leaks, "\n", fn {runner, identities} ->
      "  #{runner}:\n#{format_identities(identities)}"
    end)
  end
end
