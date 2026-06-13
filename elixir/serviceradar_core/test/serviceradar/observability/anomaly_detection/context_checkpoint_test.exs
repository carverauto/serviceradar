defmodule ServiceRadar.Observability.AnomalyDetection.ContextCheckpointTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Observability.AnomalyDetection.ContextCheckpoint
  alias ServiceRadar.Observability.AnomalyDetection.ContextCheckpointTest.Stats

  setup do
    start_supervised!(%{
      id: Stats,
      start:
        {Agent, :start_link,
         [
           fn ->
             %{
               stream_info_calls: 0,
               request_calls: 0,
               requests: [],
               get_message_calls: 0
             }
           end,
           [name: Stats]
         ]}
    })

    :ok
  end

  test "bucket existence is cached after the first successful ensure" do
    bucket = "serviceradar_anomaly_context_test_#{System.unique_integer([:positive])}"

    opts = [
      enabled: true,
      bucket: bucket,
      connection: __MODULE__.Connection,
      stream_api: __MODULE__.StreamAPI,
      kv: __MODULE__.KV,
      request_api: __MODULE__.RequestAPI
    ]

    assert {:ok, 1} = ContextCheckpoint.save("series-1", %{version: 1}, opts)
    assert {:ok, 2} = ContextCheckpoint.save("series-1", %{version: 2}, opts)

    assert %{stream_info_calls: 1, request_calls: 2} = stats()
  end

  test "save sends expected revision as JetStream subject sequence header" do
    bucket = "serviceradar_anomaly_context_test_#{System.unique_integer([:positive])}"

    opts = [
      enabled: true,
      bucket: bucket,
      connection: __MODULE__.Connection,
      stream_api: __MODULE__.StreamAPI,
      kv: __MODULE__.KV,
      request_api: __MODULE__.RequestAPI,
      expected_revision: 7
    ]

    assert {:ok, 1} = ContextCheckpoint.save("series-1", %{version: 1}, opts)

    assert [%{opts: request_opts}] = stats().requests

    assert {"Nats-Expected-Last-Subject-Sequence", "7"} in Keyword.fetch!(
             request_opts,
             :headers
           )
  end

  test "load attaches the current JetStream revision to the decoded checkpoint" do
    bucket = "serviceradar_anomaly_context_test_#{System.unique_integer([:positive])}"

    Agent.update(Stats, &Map.put(&1, :checkpoint_revision, 42))

    opts = [
      enabled: true,
      bucket: bucket,
      connection: __MODULE__.Connection,
      stream_api: __MODULE__.StreamAPI,
      kv: __MODULE__.KV
    ]

    assert {:ok, checkpoint} = ContextCheckpoint.load("series-1", opts)

    assert checkpoint["version"] == 1
    assert checkpoint[:__checkpoint_revision__] == 42
  end

  test "save reports revision conflicts from JetStream expected sequence failures" do
    bucket = "serviceradar_anomaly_context_test_#{System.unique_integer([:positive])}"

    opts = [
      enabled: true,
      bucket: bucket,
      connection: __MODULE__.Connection,
      stream_api: __MODULE__.StreamAPI,
      kv: __MODULE__.KV,
      request_api: __MODULE__.ConflictRequestAPI,
      expected_revision: 7
    ]

    assert {:error, :checkpoint_revision_conflict} =
             ContextCheckpoint.save("series-1", %{version: 1}, opts)
  end

  test "save logs seq-less JetStream pub acks" do
    bucket = "serviceradar_anomaly_context_test_#{System.unique_integer([:positive])}"

    opts = [
      enabled: true,
      bucket: bucket,
      connection: __MODULE__.Connection,
      stream_api: __MODULE__.StreamAPI,
      kv: __MODULE__.KV,
      request_api: __MODULE__.SeqlessRequestAPI
    ]

    log =
      capture_log(fn ->
        assert :ok = ContextCheckpoint.save("series-1", %{version: 1}, opts)
      end)

    assert log =~ "anomaly context checkpoint PubAck missing sequence"
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

    def get_message(:conn, _stream, _method) do
      revision =
        Agent.get_and_update(@stats, fn state ->
          revision = Map.get(state, :checkpoint_revision, 1)

          {revision,
           state
           |> Map.update!(:get_message_calls, &(&1 + 1))
           |> Map.put(:checkpoint_revision, revision)}
        end)

      {:ok, %{data: Jason.encode!(%{version: 1}), seq: revision}}
    end
  end

  defmodule KV do
    @moduledoc false
    def create_bucket(:conn, _bucket, _opts), do: {:ok, %{}}
  end

  defmodule RequestAPI do
    @moduledoc false
    @stats Stats

    def request(:conn, subject, body, opts) do
      revision =
        Agent.get_and_update(@stats, fn state ->
          revision = state.request_calls + 1

          {revision,
           %{
             state
             | request_calls: revision,
               requests: [%{subject: subject, body: body, opts: opts} | state.requests]
           }}
        end)

      {:ok, %{body: Jason.encode!(%{"stream" => "KV_test", "seq" => revision})}}
    end
  end

  defmodule ConflictRequestAPI do
    @moduledoc false

    def request(:conn, _subject, _body, _opts) do
      {:ok,
       %{
         status: "409",
         description: "wrong last sequence",
         body: Jason.encode!(%{"error" => %{"description" => "wrong last sequence"}})
       }}
    end
  end

  defmodule SeqlessRequestAPI do
    @moduledoc false

    def request(:conn, _subject, _body, _opts) do
      {:ok, %{body: Jason.encode!(%{"stream" => "KV_test"})}}
    end
  end

  defp stats do
    Agent.get(__MODULE__.Stats, & &1)
  end
end
