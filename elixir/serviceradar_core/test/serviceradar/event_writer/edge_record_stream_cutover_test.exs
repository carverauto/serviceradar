defmodule ServiceRadar.EventWriter.EdgeRecordStreamCutoverTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.EdgeRecordStreamCutover

  @moduletag :db_free

  # A fake JetStream API for one limits stream. `consumer_info` and `delete` are
  # lists of scripted replies consumed one per call (the last repeats). Every
  # request is recorded so the test can see whether the stream was unsealed.
  defp fake_request(stream_name, consumer_info, delete) do
    {:ok, agent} =
      Agent.start_link(fn -> %{consumer_info: consumer_info, delete: delete, calls: []} end)

    request = fn topic, payload ->
      Agent.get_and_update(agent, fn state ->
        state = %{state | calls: state.calls ++ [{topic, payload}]}

        cond do
          topic == "$JS.API.STREAM.INFO.#{stream_name}" ->
            {{:ok,
              %{
                "config" => %{"name" => stream_name, "retention" => "limits", "sealed" => false},
                "state" => %{"bytes" => 0}
              }}, state}

          topic == "$JS.API.STREAM.UPDATE.#{stream_name}" ->
            {{:ok, %{"config" => Jason.decode!(payload)}}, state}

          String.starts_with?(topic, "$JS.API.CONSUMER.INFO.#{stream_name}.") ->
            {reply, rest} = next(state.consumer_info)
            {reply, %{state | consumer_info: rest}}

          topic == "$JS.API.STREAM.DELETE.#{stream_name}" ->
            {reply, rest} = next(state.delete)
            {reply, %{state | delete: rest}}
        end
      end)
    end

    {request, fn -> Agent.get(agent, & &1.calls) end}
  end

  defp next([reply]), do: {reply, [reply]}
  defp next([reply | rest]), do: {reply, rest}

  defp sealed_updates(calls, stream_name) do
    for {"$JS.API.STREAM.UPDATE." <> ^stream_name, payload} <- calls,
        do: Map.fetch!(Jason.decode!(payload), "sealed")
  end

  defp config do
    %Config{
      enabled: true,
      producer_name: :cutover_test_producer,
      nats: %{},
      consumer_name: "synthetic-writer",
      max_ack_pending: 32,
      consumer_pull_batch_size: 4,
      workers: 1,
      retired_consumers: [],
      streams: []
    }
  end

  @drained {:ok, %{"num_pending" => 0, "num_ack_pending" => 0}}
  @deleted {:ok, %{"success" => true}}

  setup do
    stream = Config.edge_record_stream()
    %{stream: stream, stream_name: Config.jetstream_stream_name(stream)}
  end

  test "a poll that finds the durable behind returns at once and keeps the stream sealed",
       %{stream: stream, stream_name: stream_name} do
    behind = {:ok, %{"num_pending" => 5, "num_ack_pending" => 1}}
    {request, calls} = fake_request(stream_name, [behind, @drained], [@deleted])

    assert {:draining, cutover} = EdgeRecordStreamCutover.start(request, config(), stream)
    assert {:draining, cutover} = EdgeRecordStreamCutover.poll(request, cutover)

    capture_log(fn ->
      assert :cut_over = EdgeRecordStreamCutover.poll(request, cutover)
    end)

    assert sealed_updates(calls.(), stream_name) == [true]
  end

  test "a transient consumer info error after sealing is retried until the stream drains",
       %{stream: stream, stream_name: stream_name} do
    {request, calls} = fake_request(stream_name, [{:error, :timeout}, @drained], [@deleted])

    assert {:draining, cutover} = EdgeRecordStreamCutover.start(request, config(), stream)
    assert {:draining, cutover} = EdgeRecordStreamCutover.poll(request, cutover)

    capture_log(fn ->
      assert :cut_over = EdgeRecordStreamCutover.poll(request, cutover)
    end)

    assert sealed_updates(calls.(), stream_name) == [true]
  end

  test "consumer info that keeps failing past the deadline unseals the stream",
       %{stream: stream, stream_name: stream_name} do
    {request, calls} = fake_request(stream_name, [{:error, :timeout}], [@deleted])

    assert {:draining, cutover} =
             EdgeRecordStreamCutover.start(request, config(), stream, drain_timeout_ms: 0)

    capture_log(fn ->
      assert {:error, :drain_timeout} = EdgeRecordStreamCutover.poll(request, cutover)
    end)

    assert sealed_updates(calls.(), stream_name) == [true, false]

    refute Enum.any?(calls.(), fn {topic, _} ->
             topic == "$JS.API.STREAM.DELETE.#{stream_name}"
           end)
  end

  test "a failed delete after draining unseals the stream",
       %{stream: stream, stream_name: stream_name} do
    refused = {:ok, %{"error" => %{"code" => 500, "description" => "synthetic failure"}}}
    {request, calls} = fake_request(stream_name, [@drained], [refused])

    assert {:draining, cutover} = EdgeRecordStreamCutover.start(request, config(), stream)

    capture_log(fn ->
      assert {:error, %{"code" => 500}} = EdgeRecordStreamCutover.poll(request, cutover)
    end)

    assert sealed_updates(calls.(), stream_name) == [true, false]
  end

  test "abandoning a cutover unseals the stream without deleting it",
       %{stream: stream, stream_name: stream_name} do
    {request, calls} = fake_request(stream_name, [@drained], [@deleted])

    assert {:draining, cutover} = EdgeRecordStreamCutover.start(request, config(), stream)

    capture_log(fn ->
      assert {:error, :nats_reconnected} =
               EdgeRecordStreamCutover.abort(request, cutover, {:error, :nats_reconnected})
    end)

    assert sealed_updates(calls.(), stream_name) == [true, false]

    refute Enum.any?(calls.(), fn {topic, _} ->
             topic == "$JS.API.STREAM.DELETE.#{stream_name}"
           end)
  end
end
