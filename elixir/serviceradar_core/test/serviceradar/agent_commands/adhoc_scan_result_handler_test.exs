defmodule ServiceRadar.AgentCommands.AdhocScanResultHandlerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.AgentCommands.AdhocScanResultHandler

  @moduletag :db_free

  @scan_run_id "1f2e3d4c-5b6a-4798-8a7b-6c5d4e3f2a1b"

  defp payload(results), do: %{"scan_run_id" => @scan_run_id, "results" => results}

  defp command(extra \\ %{}) do
    Map.merge(%{agent_id: "agent-01", gateway_id: "gateway-01", partition: "default"}, extra)
  end

  test "each result row is published to the scan's subject and waits for the PubAck" do
    test_pid = self()

    publish = fn subject, body, opts ->
      send(test_pid, {:published, subject, Jason.decode!(body), opts})
      :ok
    end

    rows = [
      %{"target" => "192.0.2.10", "mode" => "icmp", "available" => true},
      %{"target_ip" => "192.0.2.11", "mode" => "tcp", "port" => 443, "agent_id" => "agent-02"}
    ]

    assert :ok = AdhocScanResultHandler.publish_rows(payload(rows), command(), publish: publish)

    subject = "scans.results.#{@scan_run_id}"

    assert_received {:published, ^subject, first, [timeout: 1_500]}
    assert first["scan_run_id"] == @scan_run_id
    assert first["target_ip"] == "192.0.2.10"
    assert first["agent_id"] == "agent-01"
    assert first["gateway_id"] == "gateway-01"

    assert_received {:published, ^subject, second, [timeout: 1_500]}
    assert second["agent_id"] == "agent-02"
    assert second["target_ip"] == "192.0.2.11"
  end

  test "a row no stream stored is logged, and the remaining rows are still published" do
    test_pid = self()

    publish = fn _subject, body, _opts ->
      case Jason.decode!(body) do
        %{"target" => "192.0.2.20"} ->
          {:error, {:jetstream, %{"code" => 503, "description" => "no responders"}}}

        row ->
          send(test_pid, {:published, row["target"]})
          :ok
      end
    end

    rows = [%{"target" => "192.0.2.20"}, %{"target" => "192.0.2.21"}]

    log =
      capture_log(fn ->
        assert :ok =
                 AdhocScanResultHandler.publish_rows(payload(rows), command(), publish: publish)
      end)

    assert log =~ "Ad-hoc scan row not stored on JetStream scans.results.#{@scan_run_id}"
    assert log =~ "no responders"
    assert_received {:published, "192.0.2.21"}
  end

  test "a payload without a scan run publishes nothing" do
    publish = fn _subject, _body, _opts -> flunk("nothing to publish") end

    assert :ok =
             AdhocScanResultHandler.publish_rows(%{"results" => [%{}]}, command(),
               publish: publish
             )
  end
end
