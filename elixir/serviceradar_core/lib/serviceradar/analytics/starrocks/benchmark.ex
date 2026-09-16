defmodule ServiceRadar.Analytics.StarRocks.Benchmark do
  @moduledoc """
  Synthetic StarRocks ingest/query matrix.

  Workloads are invented. A passing cell does not authorize cutover or a
  supported-capacity claim. Cells that are not executed are failed.
  """

  alias ServiceRadar.Analytics.StarRocks.Query
  alias ServiceRadar.Analytics.StarRocks.Rows
  alias ServiceRadar.Analytics.StarRocks.StreamLoad

  @table "ocsf_network_activity"
  @seed 495
  @synthetic_time "1999-06-15 12:00:00"

  @spec profile() :: map()
  def profile do
    %{
      starrocks: "3.5.21",
      operator: "1.11.7",
      topology: "shared-nothing 3FE+3BE",
      namespace: "starrocks",
      seed: @seed,
      cutover: false
    }
  end

  @spec matrix() :: [map()]
  def matrix do
    [
      %{id: "identities_1", kind: :identity_sweep, size: 1},
      %{id: "identities_100", kind: :identity_sweep, size: 100},
      %{id: "identities_1000", kind: :identity_sweep, size: 1_000},
      %{id: "identities_10000", kind: :identity_sweep, size: 10_000},
      %{id: "rate_10k", kind: :rate, target_fps: 10_000},
      %{id: "rate_50k", kind: :rate, target_fps: 50_000},
      %{id: "rate_100k", kind: :rate, target_fps: 100_000},
      %{id: "soak_1h", kind: :soak, duration_s: 3_600},
      %{id: "readers_1", kind: :readers, concurrency: 1},
      %{id: "readers_10", kind: :readers, concurrency: 10},
      %{id: "readers_50", kind: :readers, concurrency: 50}
    ]
  end

  @spec run_matrix(keyword()) :: [map()]
  def run_matrix(opts \\ []) do
    Enum.map(matrix(), &run_cell(&1, opts))
  end

  @spec synthetic_flows(pos_integer(), keyword()) :: [map()]
  def synthetic_flows(size, opts \\ []) when is_integer(size) and size > 0 do
    run_id = safe_run_id(Keyword.get(opts, :run_id, "unit"))
    exporters = Keyword.get(opts, :exporters, size)

    1..size
    |> Enum.map(fn n ->
      %{
        "id" => flow_id(run_id, n),
        "device_uid" => "device-bench-#{pad(rem(n - 1, exporters) + 1)}",
        "time" => @synthetic_time,
        "src_endpoint_ip" => "192.0.2.#{rem(n, 250) + 1}",
        "dst_endpoint_ip" => "198.51.100.#{rem(n, 250) + 1}",
        "bytes_in" => 1200,
        "bytes_out" => 80,
        "packets_in" => 10,
        "packets_out" => 2,
        "sampling_rate" => 1,
        "attribution_version" => 0
      }
    end)
    |> then(&Rows.encode(:flows, &1))
  end

  @spec format_report([map()]) :: String.t()
  def format_report(results) when is_list(results) do
    lines =
      Enum.map(results, fn cell ->
        "#{cell.id}\t#{cell.verdict}\t#{cell.reason}"
      end)

    Enum.join(["id\tverdict\treason" | lines], "\n") <> "\n"
  end

  defp run_cell(%{kind: :identity_sweep, size: size} = cell, opts) do
    max_identity = Keyword.get(opts, :max_identity, 100)

    if size > max_identity do
      fail(cell, "not executed: size #{size} exceeds max_identity #{max_identity}")
    else
      run_identity_sweep(cell, size, opts)
    end
  end

  defp run_cell(%{kind: :rate, target_fps: fps} = cell, opts) do
    if Keyword.get(opts, :allow_rate, false) do
      fail(cell, "rate #{fps} not implemented as a sustained generator")
    else
      fail(cell, "not executed: rate #{fps} fps would be a capacity claim")
    end
  end

  defp run_cell(%{kind: :soak, duration_s: seconds} = cell, opts) do
    if Keyword.get(opts, :allow_soak, false) do
      fail(cell, "soak #{seconds}s not implemented in this runner")
    else
      fail(cell, "not executed: #{seconds}s soak exceeds this lab budget")
    end
  end

  defp run_cell(%{kind: :readers, concurrency: n} = cell, opts) do
    max_readers = Keyword.get(opts, :max_readers, 1)

    if n > max_readers do
      fail(cell, "not executed: concurrency #{n} exceeds max_readers #{max_readers}")
    else
      run_readers(cell, n, opts)
    end
  end

  defp run_identity_sweep(cell, size, opts) do
    run_id = safe_run_id(Keyword.get(opts, :run_id, "unit"))
    rows = synthetic_flows(size, opts)
    started = System.monotonic_time(:millisecond)

    case StreamLoad.persist(@table, rows, client_opts(opts)) do
      {:ok, %{loaded: loaded}} when loaded == size ->
        case query_visible(run_id, size, opts) do
          {:ok, visible, bytes} ->
            elapsed = System.monotonic_time(:millisecond) - started
            expected_bytes = size * 1200

            cond do
              visible != size ->
                fail(cell, "visible #{visible} != loaded #{size}", elapsed)

              bytes != expected_bytes ->
                fail(cell, "bytes_in #{bytes} != #{expected_bytes}", elapsed)

              true ->
                pass(cell, "loaded=#{loaded} visible=#{visible} elapsed_ms=#{elapsed}", elapsed)
            end

          {:error, reason} ->
            fail(cell, "query #{inspect(reason)}")
        end

      {:ok, %{loaded: loaded}} ->
        fail(cell, "loaded #{loaded} != #{size}")

      other ->
        fail(cell, "stream_load #{inspect(other)}")
    end
  end

  defp run_readers(cell, n, opts) do
    run_id = safe_run_id(Keyword.get(opts, :run_id, "unit"))
    sql = visibility_sql(run_id)

    started = System.monotonic_time(:millisecond)

    results =
      1..n
      |> Task.async_stream(fn _i -> Query.execute(sql, client_opts(opts)) end,
        timeout: 15_000,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    elapsed = System.monotonic_time(:millisecond) - started

    failures =
      Enum.reject(results, fn
        {:ok, {:ok, %Postgrex.Result{}}} -> true
        _ -> false
      end)

    if failures == [] do
      pass(cell, "concurrency=#{n} elapsed_ms=#{elapsed}", elapsed)
    else
      fail(cell, "reader failures #{inspect(failures)}", elapsed)
    end
  end

  defp query_visible(run_id, _size, opts) do
    sql = visibility_sql(run_id)

    case Query.execute(sql, client_opts(opts)) do
      {:ok, %Postgrex.Result{rows: [[count, bytes] | _]}} ->
        {:ok, to_int(count), to_int(bytes)}

      {:ok, %Postgrex.Result{rows: rows}} ->
        {:error, {:unexpected_rows, rows}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp visibility_sql(run_id) do
    prefix = "flow-bench-#{run_id}-"

    "SELECT COUNT(*) AS c, SUM(bytes_in) AS b FROM serviceradar.ocsf_network_activity " <>
      "WHERE id LIKE '#{prefix}%'"
  end

  defp client_opts(opts) do
    []
    |> maybe_put(:http, Keyword.get(opts, :http))
    |> maybe_put(:mysql, Keyword.get(opts, :mysql))
    |> maybe_put(:config, Keyword.get(opts, :config))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp safe_run_id(run_id) when is_binary(run_id) do
    if run_id =~ ~r/^[A-Za-z0-9]+$/, do: run_id, else: "unit"
  end

  defp flow_id(run_id, n), do: "flow-bench-#{run_id}-#{pad(n)}"

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(6, "0")

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_float(value), do: round(value)
  defp to_int(value) when is_binary(value), do: String.to_integer(value)
  defp to_int(nil), do: 0

  defp pass(cell, reason, elapsed) do
    Map.merge(cell, %{verdict: :pass, reason: reason, elapsed_ms: elapsed})
  end

  defp fail(cell, reason, elapsed \\ 0) do
    Map.merge(cell, %{verdict: :fail, reason: reason, elapsed_ms: elapsed})
  end
end
