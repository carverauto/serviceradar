defmodule ServiceRadar.Observability.MtrResultPublisherTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.MtrMetricsIngestor
  alias ServiceRadar.Observability.MtrResultPublisher

  defp capture do
    fn subject, body, opts ->
      send(self(), {:published, subject, Jason.decode!(body), opts})
      :ok
    end
  end

  defp assert_recent(%DateTime{} = time) do
    assert abs(DateTime.diff(DateTime.utc_now(), time, :second)) <= 5
  end

  defp result(target) do
    %{"target" => target, "trace" => %{"target_ip" => target, "hops" => []}}
  end

  test "publishes one message per result, each with its own trace id" do
    payload = %{"results" => [result("192.0.2.1"), result("192.0.2.2")]}
    status = %{agent_id: "agent-01", gateway_id: "gw-01", partition: "default"}

    assert :ok = MtrResultPublisher.publish(payload, status, publish: capture())

    assert_received {:published, "mtr.results.ingest", first, first_opts}
    assert_received {:published, "mtr.results.ingest", second, second_opts}

    [first_result] = first["payload"]["results"]
    [second_result] = second["payload"]["results"]

    assert first_result["target"] == "192.0.2.1"
    assert second_result["target"] == "192.0.2.2"
    assert {:ok, _} = Ecto.UUID.cast(first_result["trace_uuid"])
    assert first_result["trace_uuid"] != second_result["trace_uuid"]
    assert first_opts[:msg_id] == first_result["trace_uuid"]
    assert second_opts[:msg_id] == second_result["trace_uuid"]

    assert first["status"] == %{
             "agent_id" => "agent-01",
             "gateway_id" => "gw-01",
             "partition" => "default"
           }

    refute Map.has_key?(first, "broadcast")
  end

  test "attaches a broadcast, per result when given a function" do
    payload = %{"results" => [result("192.0.2.1")]}
    broadcast = fn r -> %{command_id: "cmd-1", target: r["target"], agent_id: "agent-01"} end
    opts = [broadcast: broadcast, publish: capture()]

    assert :ok = MtrResultPublisher.publish(payload, %{}, opts)

    assert_received {:published, _subject, message, _opts}

    assert message["broadcast"] == %{
             "command_id" => "cmd-1",
             "target" => "192.0.2.1",
             "agent_id" => "agent-01"
           }
  end

  test "stops at the first failed publish and returns its error" do
    publish = fn _subject, _body, _opts ->
      send(self(), :attempt)
      {:error, :timeout}
    end

    payload = %{"results" => [result("192.0.2.1"), result("192.0.2.2")]}

    assert {:error, :timeout} = MtrResultPublisher.publish(payload, %{}, publish: publish)
    assert_received :attempt
    refute_received :attempt
  end

  test "stamps a parseable timestamp on a result that has none" do
    payload = %{"results" => [result("192.0.2.1")]}

    assert :ok = MtrResultPublisher.publish(payload, %{}, publish: capture())

    assert_received {:published, _subject, message, _opts}
    [stamped] = message["payload"]["results"]
    assert_recent(MtrMetricsIngestor.trace_time(stamped))
  end

  test "stamps a result whose timestamps are unparseable" do
    unparseable = %{
      "target" => "192.0.2.1",
      "timestamp" => "yesterday",
      "trace" => %{"target_ip" => "192.0.2.1", "timestamp" => 0, "hops" => []}
    }

    payload = %{"results" => [unparseable]}

    assert :ok = MtrResultPublisher.publish(payload, %{}, publish: capture())

    assert_received {:published, _subject, message, _opts}
    [stamped] = message["payload"]["results"]
    assert_recent(MtrMetricsIngestor.trace_time(stamped))
  end

  test "keeps the timestamp a result already carries" do
    in_trace = put_in(result("192.0.2.1"), ["trace", "timestamp"], 1_700_000_000)
    top_level = Map.put(result("192.0.2.2"), "timestamp", 1_700_000_100)
    payload = %{"results" => [in_trace, top_level]}

    assert :ok = MtrResultPublisher.publish(payload, %{}, publish: capture())

    assert_received {:published, _subject, first, _opts}
    assert_received {:published, _subject, second, _opts}
    [first_result] = first["payload"]["results"]
    [second_result] = second["payload"]["results"]

    assert first_result["trace"]["timestamp"] == 1_700_000_000
    refute Map.has_key?(first_result, "timestamp")
    assert second_result["timestamp"] == 1_700_000_100

    assert DateTime.compare(
             MtrMetricsIngestor.trace_time(first_result),
             ~U[2023-11-14 22:13:20Z]
           ) == :eq
  end

  test "accepts the single-result shapes the ingestor accepts" do
    single = result("192.0.2.1")

    assert MtrResultPublisher.results(%{"result" => single}) == [single]
    assert MtrResultPublisher.results(single) == [single]
  end
end
