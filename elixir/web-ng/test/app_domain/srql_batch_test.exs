defmodule ServiceRadarWebNG.SRQL.BatchTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.SRQL.Batch

  @moduletag :db_free
  @metrics_scope %{permissions: MapSet.new(["observability.metrics.view"])}
  @queries [summary: "in:timeseries_metrics time:last_90d", cores: "in:cpu time:last_90d"]

  test "every member is authorized before translation or execution" do
    for queries <- [
          [summary: "in:timeseries_metrics", logs: "in:logs"],
          [logs: "in:logs", summary: "in:timeseries_metrics"]
        ] do
      assert {:error, :forbidden} =
               Batch.run(queries, @metrics_scope, &unexpected/1, &unexpected/1, &unexpected_shared/2)
    end

    assert {:error, :forbidden} = Batch.run(@queries, nil, &unexpected/1, &unexpected/1, &unexpected_shared/2)
  end

  test "invalid, duplicate, and oversized batches never reach translation" do
    for queries <- [
          nil,
          [],
          [summary: "in:cpu"],
          [summary: "in:cpu", summary: "in:memory"],
          [{1, "in:cpu"}, {:summary, "in:memory"}],
          [summary: nil, cores: "in:cpu"],
          for(index <- 1..5, do: {"metric-#{index}", "in:cpu"})
        ] do
      assert {:error, :invalid_srql_batch} =
               Batch.run(queries, @metrics_scope, &unexpected/1, &unexpected/1, &unexpected_shared/2)
    end
  end

  test "compatible members share one execution and preserve their query identity" do
    shared = %{"sql" => "shared", "dialect" => "duckdb"}
    lanes = [%{"sql" => "average"}, %{"sql" => "maximum"}]
    expected = %{summary: {:ok, %{"results" => []}}, cores: {:ok, %{"results" => []}}}

    translate = fn requests ->
      assert requests == Enum.map(@queries, fn {_key, query} -> %{"query" => query} end)
      send(self(), :translated)
      {:ok, %{"translation" => shared, "lanes" => lanes}}
    end

    execute_shared = fn actual, named_lanes ->
      assert actual == shared

      assert named_lanes ==
               Enum.zip_with(@queries, lanes, fn {key, query}, lane -> {key, Map.put(lane, "_query", query)} end)

      send(self(), :executed_shared)
      {:ok, expected}
    end

    assert {:ok, ^expected} = Batch.run(@queries, @metrics_scope, translate, &unexpected/1, execute_shared)
    assert_receive :translated
    assert_receive :executed_shared
    refute_received :executed_shared
  end

  test "translation failure or mismatched lane count prevents all execution" do
    for result <- [
          {:error, :incompatible_srql_batch},
          {:ok, %{"translation" => nil, "lanes" => [%{"sql" => "first"}]}}
        ] do
      translate = fn _requests -> result end

      assert {:error, _reason} =
               Batch.run(@queries, @metrics_scope, translate, &unexpected/1, &unexpected_shared/2)
    end
  end

  test "separate hot queries run only after translation succeeds and stop after the first failure" do
    queries = @queries ++ [memory: "in:memory", disk: "in:disk"]
    lanes = for index <- 0..3, do: %{"index" => index, "dialect" => "postgres"}

    translate = fn requests ->
      assert Enum.count(requests) == 4
      send(self(), :all_translated)
      {:ok, %{"translation" => nil, "lanes" => lanes}}
    end

    execute = fn
      %{"index" => 0} ->
        assert_received :all_translated
        {:ok, %{"results" => [%{"value" => 12.0}]}}

      %{"index" => 1} ->
        {:error, :deadline_exceeded}

      _ ->
        flunk("a failed batch must not start another scan")
    end

    assert {:ok,
            %{
              summary: {:ok, %{"results" => [%{"value" => 12.0}]}},
              cores: {:error, :deadline_exceeded},
              memory: {:error, :deadline_exceeded},
              disk: {:error, :deadline_exceeded}
            }} = Batch.run(queries, @metrics_scope, translate, execute, &unexpected_shared/2)
  end

  test "shared execution errors are returned without a separate-query retry" do
    translate = fn _ -> {:ok, %{"translation" => %{}, "lanes" => [%{}, %{}]}} end
    shared = fn _, _ -> {:error, :deadline_exceeded} end

    assert {:error, :deadline_exceeded} = Batch.run(@queries, @metrics_scope, translate, &unexpected/1, shared)
  end

  test "split keeps NULL values, empty series, row order, and empty member results" do
    first = ~U[2034-01-02 00:00:00Z]
    last = DateTime.add(first, 3600)
    lanes = [summary: %{"name" => "summary"}, cores: %{"name" => "cores"}, empty: %{"name" => "empty"}]

    result = %Postgrex.Result{
      columns: ["timestamp", "series", "value", "batch_index"],
      rows: [[first, "", nil, 1], [first, "cpu", 14.0, 0], [last, "", 0.0, 1]]
    }

    respond = fn lane, %Postgrex.Result{columns: ["timestamp", "series", "value"], rows: rows} ->
      %{name: lane["name"], rows: rows}
    end

    assert {:ok,
            %{
              summary: {:ok, %{name: "summary", rows: [[^first, "cpu", 14.0]]}},
              cores: {:ok, %{name: "cores", rows: [[^first, "", nil], [^last, "", +0.0]]}},
              empty: {:ok, %{name: "empty", rows: []}}
            }} = Batch.split(result, lanes, respond)

    assert {:ok, %{summary: {:ok, %{rows: []}}, cores: {:ok, %{rows: []}}, empty: {:ok, %{rows: []}}}} =
             Batch.split(%{result | rows: []}, lanes, respond)
  end

  test "invalid result indexes or row shapes never reach the response formatter" do
    result = %Postgrex.Result{columns: ["timestamp", "series", "value", "batch_index"]}
    lanes = [summary: %{}, cores: %{}]

    for rows <- [[[nil, "", 1.0, -1]], [[nil, "", 1.0, 2]], [[nil, "", 1.0, "0"]], [[nil, "", 1.0]]] do
      assert {:error, :invalid_srql_batch_result} = Batch.split(%{result | rows: rows}, lanes, &unexpected_shared/2)
    end

    assert {:error, :invalid_srql_batch_result} =
             Batch.split(
               %{result | columns: ["series", "timestamp", "value", "batch_index"], rows: []},
               lanes,
               &unexpected_shared/2
             )
  end

  defp unexpected(_value), do: flunk("unexpected translation or execution")
  defp unexpected_shared(_left, _right), do: flunk("unexpected shared execution or response formatting")
end
