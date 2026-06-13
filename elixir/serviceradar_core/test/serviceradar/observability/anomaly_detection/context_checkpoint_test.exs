defmodule ServiceRadar.Observability.AnomalyDetection.ContextCheckpointTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.AnomalyDetection.ContextCheckpoint
  alias ServiceRadar.Observability.AnomalyDetection.ContextCheckpointTest.Stats

  test "bucket existence is cached after the first successful ensure" do
    bucket = "serviceradar_anomaly_context_test_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: __MODULE__.Stats,
      start:
        {Agent, :start_link,
         [fn -> %{stream_info_calls: 0, put_value_calls: 0} end, [name: __MODULE__.Stats]]}
    })

    opts = [
      enabled: true,
      bucket: bucket,
      connection: __MODULE__.Connection,
      stream_api: __MODULE__.StreamAPI,
      kv: __MODULE__.KV
    ]

    assert :ok = ContextCheckpoint.save("series-1", %{version: 1}, opts)
    assert :ok = ContextCheckpoint.save("series-1", %{version: 2}, opts)

    assert stats() == %{stream_info_calls: 1, put_value_calls: 2}
  end

  defmodule Connection do
    @moduledoc false
    def get, do: {:ok, :conn}
  end

  defmodule StreamAPI do
    @moduledoc false
    @stats Stats

    def info(:conn, _stream) do
      Agent.update(
        @stats,
        &Map.update!(&1, :stream_info_calls, fn count ->
          count + 1
        end)
      )

      {:ok, %{}}
    end
  end

  defmodule KV do
    @moduledoc false
    @stats Stats

    def put_value(:conn, _bucket, _key, _encoded, _opts) do
      Agent.update(
        @stats,
        &Map.update!(&1, :put_value_calls, fn count ->
          count + 1
        end)
      )

      :ok
    end
  end

  defp stats do
    Agent.get(__MODULE__.Stats, & &1)
  end
end
