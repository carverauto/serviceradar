defmodule ServiceRadar.Bench.MetricFixtureCnpgInsert do
  @moduledoc false

  alias ServiceRadar.EventWriter.BulkInsert
  alias ServiceRadar.Observability.MetricEnvelope
  alias ServiceRadar.Repo

  @default_fixture_dir "tmp/metric-fixtures/demo-smoke-cli"
  @default_repeat 1
  @default_parallelism 1
  @default_strategy "insert_all"
  @copy_columns [
    :timestamp,
    :gateway_id,
    :agent_id,
    :metric_name,
    :metric_type,
    :device_id,
    :value,
    :unit,
    :tags,
    :partition,
    :scale,
    :is_delta,
    :target_device_ip,
    :if_index,
    :metadata,
    :created_at,
    :series_key
  ]

  def run do
    ensure_repo_started!()

    fixture_dir = env("METRIC_FIXTURE_PROFILE_DIR", @default_fixture_dir)
    repeat = env_int("METRIC_FIXTURE_PROFILE_REPEAT", @default_repeat)
    parallelism = env_int("METRIC_INSERT_PARALLELISM", @default_parallelism)
    strategy = env("METRIC_INSERT_STRATEGY", @default_strategy)
    run_id = env("METRIC_INSERT_RUN_ID", default_run_id())
    rollback? = env_bool("METRIC_INSERT_ROLLBACK", true)
    configure_logger()

    rows =
      fixture_dir
      |> fixture_paths()
      |> Enum.flat_map(&decode_rows!/1)
      |> repeat_rows(repeat)
      |> prepare_rows(run_id)

    IO.puts("Metric fixture CNPG insert benchmark")
    IO.puts("fixture_dir=#{fixture_dir}")
    IO.puts("strategy=#{strategy}")
    IO.puts("parallelism=#{parallelism}")
    IO.puts("run_id=#{run_id}")
    IO.puts("rollback=#{rollback?}")
    IO.puts("rows=#{length(rows)}")
    IO.puts("")

    result = benchmark_insert(rows, strategy, rollback?, parallelism)

    print_result(result)
  end

  defp fixture_paths(dir) do
    dir
    |> Path.expand()
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
  end

  defp decode_rows!(path) do
    payload =
      path
      |> File.read!()
      |> strip_raw_cli_newline()

    case MetricEnvelope.decode_rows_count(payload) do
      {:ok, rows, _count} -> rows
      {:error, reason} -> raise "failed to decode #{path}: #{inspect(reason)}"
    end
  end

  defp repeat_rows(rows, repeat) when repeat <= 1, do: rows

  defp repeat_rows(rows, repeat) do
    Enum.flat_map(1..repeat, fn _ -> rows end)
  end

  defp prepare_rows(rows, run_id) do
    base_time = DateTime.utc_now()

    rows
    |> Enum.with_index()
    |> Enum.map(fn {row, index} ->
      timestamp = DateTime.add(base_time, index, :microsecond)

      row
      |> Map.put(:timestamp, timestamp)
      |> Map.put(:created_at, timestamp)
      |> Map.update!(:series_key, &"bench:#{run_id}:#{index}:#{&1}")
      |> Map.update(
        :metadata,
        %{"bench_run_id" => run_id},
        &Map.put(&1 || %{}, "bench_run_id", run_id)
      )
    end)
  end

  defp rollback_benchmark(rows, strategy) do
    case Repo.transaction(
           fn ->
             "insert_all" = strategy
             result = insert_all_benchmark(rows)
             Repo.rollback({:benchmark_result, result})
           end,
           timeout: :infinity
         ) do
      {:error, {:benchmark_result, result}} -> result
      other -> raise "unexpected rollback benchmark result: #{inspect(other)}"
    end
  end

  defp benchmark_insert(rows, strategy, rollback?, parallelism) when parallelism <= 1 do
    benchmark_insert(rows, strategy, rollback?)
  end

  defp benchmark_insert(rows, strategy, rollback?, parallelism) do
    chunks = split_rows(rows, parallelism)

    {worker_results, elapsed_ns} =
      timed(fn ->
        chunks
        |> Task.async_stream(
          fn chunk -> benchmark_insert(chunk, strategy, rollback?) end,
          max_concurrency: parallelism,
          timeout: :infinity,
          ordered: false
        )
        |> Enum.map(fn
          {:ok, result} -> result
          {:exit, reason} -> raise "parallel insert worker exited: #{inspect(reason)}"
        end)
      end)

    inserted = Enum.sum(Enum.map(worker_results, & &1.inserted))

    %{
      strategy: "#{strategy}:parallel",
      rows: length(rows),
      inserted: inserted,
      elapsed_ns: elapsed_ns,
      rows_per_second: rows_per_second(inserted, elapsed_ns),
      worker_results: worker_results
    }
  end

  defp benchmark_insert(rows, "insert_all", true), do: rollback_benchmark(rows, "insert_all")
  defp benchmark_insert(rows, "insert_all", false), do: insert_all_benchmark(rows)

  defp benchmark_insert(rows, "copy_csv", rollback?) do
    copy_benchmark(rows, rollback?, &copy_sql/0, "copy_csv")
  end

  defp benchmark_insert(rows, "copy_stage", rollback?) do
    staged_copy_benchmark(rows, rollback?, false)
  end

  defp benchmark_insert(rows, "copy_stage_insert", rollback?) do
    staged_copy_benchmark(rows, rollback?, true)
  end

  defp benchmark_insert(_rows, strategy, _rollback?) do
    raise "unsupported METRIC_INSERT_STRATEGY=#{inspect(strategy)}; expected insert_all, copy_csv, copy_stage, or copy_stage_insert"
  end

  defp copy_benchmark(rows, rollback?, copy_sql_fun, strategy) do
    {:ok, conn} = Postgrex.start_link(postgrex_opts())

    try do
      case Postgrex.transaction(
             conn,
             fn tx_conn ->
               {count, elapsed_ns} =
                 timed(fn ->
                   tx_conn
                   |> Postgrex.stream(copy_sql_fun.(), [])
                   |> then(fn stream ->
                     Enum.into(rows, stream, &copy_row/1)
                   end)

                   length(rows)
                 end)

               result = {:benchmark_result, count, elapsed_ns}

               if rollback? do
                 Postgrex.rollback(tx_conn, result)
               else
                 result
               end
             end,
             timeout: :infinity
           ) do
        {:ok, {:benchmark_result, count, elapsed_ns}} ->
          %{
            strategy: strategy,
            rows: length(rows),
            inserted: count,
            elapsed_ns: elapsed_ns,
            rows_per_second: rows_per_second(count, elapsed_ns)
          }

        {:error, {:benchmark_result, count, elapsed_ns}} ->
          %{
            strategy: strategy,
            rows: length(rows),
            inserted: count,
            elapsed_ns: elapsed_ns,
            rows_per_second: rows_per_second(count, elapsed_ns)
          }

        other ->
          raise "unexpected copy benchmark result: #{inspect(other)}"
      end
    after
      Process.exit(conn, :normal)
    end
  end

  defp staged_copy_benchmark(rows, rollback?, insert_final?) do
    {:ok, conn} = Postgrex.start_link(postgrex_opts())

    try do
      case Postgrex.transaction(
             conn,
             fn tx_conn ->
               Postgrex.query!(tx_conn, stage_table_sql(), [], timeout: :infinity)

               {{inserted_count, phases}, total_elapsed_ns} =
                 timed(fn ->
                   {count, elapsed_ns} =
                     timed(fn ->
                       tx_conn
                       |> Postgrex.stream(stage_copy_sql(), [])
                       |> then(fn stream ->
                         Enum.into(rows, stream, &copy_row/1)
                       end)

                       length(rows)
                     end)

                   {inserted_count, insert_elapsed_ns} =
                     if insert_final? do
                       timed(fn ->
                         result =
                           Postgrex.query!(tx_conn, stage_insert_sql(), [], timeout: :infinity)

                         result.num_rows
                       end)
                     else
                       {count, 0}
                     end

                   {inserted_count,
                    %{copy_elapsed_ns: elapsed_ns, insert_elapsed_ns: insert_elapsed_ns}}
                 end)

               result =
                 {:benchmark_result, inserted_count, total_elapsed_ns, phases}

               if rollback? do
                 Postgrex.rollback(tx_conn, result)
               else
                 result
               end
             end,
             timeout: :infinity
           ) do
        {:ok, {:benchmark_result, inserted, elapsed_ns, phases}} ->
          staged_result(rows, insert_final?, inserted, elapsed_ns, phases)

        {:error, {:benchmark_result, inserted, elapsed_ns, phases}} ->
          staged_result(rows, insert_final?, inserted, elapsed_ns, phases)

        other ->
          raise "unexpected staged benchmark result: #{inspect(other)}"
      end
    after
      Process.exit(conn, :normal)
    end
  end

  defp staged_result(rows, insert_final?, inserted, elapsed_ns, phases) do
    %{
      strategy: if(insert_final?, do: "copy_stage_insert", else: "copy_stage"),
      rows: length(rows),
      inserted: inserted,
      elapsed_ns: elapsed_ns,
      rows_per_second: rows_per_second(inserted, elapsed_ns),
      phase_results: [
        %{phase: "copy_stage", elapsed_ns: phases.copy_elapsed_ns, rows: length(rows)},
        %{phase: "insert_final", elapsed_ns: phases.insert_elapsed_ns, rows: inserted}
      ]
    }
  end

  defp split_rows(rows, parallelism) do
    chunk_size = max(div(length(rows) + parallelism - 1, parallelism), 1)
    Enum.chunk_every(rows, chunk_size)
  end

  defp insert_all_benchmark(rows) do
    {count, elapsed_ns} =
      timed(fn ->
        {count, _} =
          BulkInsert.insert_all(
            "timeseries_metrics",
            rows,
            on_conflict: :nothing,
            returning: false
          )

        count
      end)

    %{
      strategy: "insert_all",
      rows: length(rows),
      inserted: count,
      elapsed_ns: elapsed_ns,
      rows_per_second: rows_per_second(count, elapsed_ns)
    }
  end

  defp postgrex_opts do
    Repo.config()
    |> Keyword.take([
      :url,
      :ssl,
      :hostname,
      :port,
      :username,
      :password,
      :database,
      :parameters,
      :types,
      :show_sensitive_data_on_connection_error
    ])
    |> Keyword.put(:timeout, :infinity)
  end

  defp copy_sql do
    columns = Enum.map_join(@copy_columns, ", ", &Atom.to_string/1)

    """
    COPY platform.timeseries_metrics (#{columns})
    FROM STDIN WITH (FORMAT csv, NULL '\\N')
    """
  end

  defp stage_copy_sql do
    columns = Enum.map_join(@copy_columns, ", ", &Atom.to_string/1)

    """
    COPY sr_metric_stage (#{columns})
    FROM STDIN WITH (FORMAT csv, NULL '\\N')
    """
  end

  defp stage_table_sql do
    """
    CREATE TEMP TABLE sr_metric_stage (
      timestamp        TIMESTAMPTZ NOT NULL,
      gateway_id       TEXT        NOT NULL,
      agent_id         TEXT,
      metric_name      TEXT        NOT NULL,
      metric_type      TEXT        NOT NULL,
      device_id        TEXT,
      value            FLOAT8      NOT NULL,
      unit             TEXT,
      tags             JSONB,
      partition        TEXT,
      scale            FLOAT8,
      is_delta         BOOLEAN,
      target_device_ip TEXT,
      if_index         INT,
      metadata         JSONB,
      created_at       TIMESTAMPTZ NOT NULL,
      series_key       TEXT        NOT NULL
    ) ON COMMIT DROP
    """
  end

  defp stage_insert_sql do
    columns = Enum.map_join(@copy_columns, ", ", &Atom.to_string/1)

    """
    INSERT INTO platform.timeseries_metrics (#{columns})
    SELECT #{columns}
    FROM sr_metric_stage
    ON CONFLICT DO NOTHING
    """
  end

  defp copy_row(row) do
    @copy_columns
    |> Enum.map_join(",", &csv_value(Map.get(row, &1)))
    |> Kernel.<>("\n")
  end

  defp csv_value(nil), do: "\\N"
  defp csv_value(%DateTime{} = value), do: csv_escape(DateTime.to_iso8601(value))
  defp csv_value(%NaiveDateTime{} = value), do: csv_escape(NaiveDateTime.to_iso8601(value))
  defp csv_value(value) when is_boolean(value), do: if(value, do: "true", else: "false")
  defp csv_value(value) when is_integer(value), do: Integer.to_string(value)

  defp csv_value(value) when is_float(value),
    do: :erlang.float_to_binary(value, [:compact, :short])

  defp csv_value(value) when is_binary(value), do: csv_escape(value)
  defp csv_value(value) when is_map(value), do: value |> Jason.encode!() |> csv_escape()
  defp csv_value(value), do: value |> to_string() |> csv_escape()

  defp csv_escape(value) do
    escaped = String.replace(value, "\"", "\"\"")
    "\"#{escaped}\""
  end

  defp timed(fun) do
    started = System.monotonic_time(:nanosecond)
    result = fun.()
    elapsed = System.monotonic_time(:nanosecond) - started
    {result, elapsed}
  end

  defp print_result(result) do
    IO.puts("Result")
    IO.puts("strategy=#{result.strategy}")
    IO.puts("attempted_rows=#{result.rows}")
    IO.puts("inserted_rows=#{result.inserted}")
    IO.puts("elapsed_ms=#{fmt(result.elapsed_ns / 1_000_000)}")
    IO.puts("rows_per_second=#{fmt(result.rows_per_second)}")

    if Map.has_key?(result, :worker_results) do
      IO.puts("")
      IO.puts("Workers")

      result.worker_results
      |> Enum.with_index(1)
      |> Enum.each(fn {worker_result, index} ->
        IO.puts(
          "worker=#{index} strategy=#{worker_result.strategy} rows=#{worker_result.rows} " <>
            "inserted=#{worker_result.inserted} elapsed_ms=#{fmt(worker_result.elapsed_ns / 1_000_000)} " <>
            "rows_per_second=#{fmt(worker_result.rows_per_second)}"
        )
      end)
    end

    if Map.has_key?(result, :phase_results) do
      IO.puts("")
      IO.puts("Phases")

      Enum.each(result.phase_results, fn phase_result ->
        IO.puts(
          "phase=#{phase_result.phase} rows=#{phase_result.rows} " <>
            "elapsed_ms=#{fmt(phase_result.elapsed_ns / 1_000_000)} " <>
            "rows_per_second=#{fmt(rows_per_second(phase_result.rows, phase_result.elapsed_ns))}"
        )
      end)
    end
  end

  defp rows_per_second(_rows, elapsed_ns) when elapsed_ns <= 0, do: 0.0
  defp rows_per_second(rows, elapsed_ns), do: rows / (elapsed_ns / 1_000_000_000)

  defp ensure_repo_started! do
    _ = Application.ensure_all_started(:telemetry)
    _ = Application.ensure_all_started(:db_connection)
    _ = Application.ensure_all_started(:postgrex)
    _ = Application.ensure_all_started(:ecto_sql)

    if is_nil(Process.whereis(Repo)) do
      case Repo.start_link() do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    else
      :ok
    end
  end

  defp strip_raw_cli_newline(payload) do
    case payload do
      <<body::binary-size(byte_size(payload) - 1), ?\n>> -> body
      _ -> payload
    end
  end

  defp env(name, default), do: System.get_env(name) || default

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> parse_int(value, default)
    end
  end

  defp env_bool(name, default) do
    case System.get_env(name) do
      nil -> default
      value when value in ["true", "1", "yes"] -> true
      value when value in ["false", "0", "no"] -> false
      _ -> default
    end
  end

  defp parse_int(value, default) do
    case Integer.parse(value) do
      {parsed, _} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp configure_logger do
    case System.get_env("METRIC_INSERT_LOG_LEVEL", "warning") do
      "" -> :ok
      "default" -> :ok
      level -> Logger.configure(level: String.to_existing_atom(level))
    end
  rescue
    ArgumentError -> Logger.configure(level: :warning)
  end

  defp default_run_id do
    "fixture_insert_#{System.system_time(:second)}_#{System.unique_integer([:positive])}"
  end

  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp fmt(value), do: to_string(value)
end

ServiceRadar.Bench.MetricFixtureCnpgInsert.run()
