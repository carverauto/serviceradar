defmodule ServiceRadar.EventWriter.Processors.AdhocScanTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.Processors.AdhocScan
  alias ServiceRadar.Scans.ScanResult

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  defp msg(map), do: %{data: Jason.encode!(map), metadata: %{}}

  test "persists icmp and tcp result rows into adhoc_scan_results" do
    scan_run_id = Ecto.UUID.generate()
    now = System.system_time(:millisecond)

    messages = [
      msg(%{
        "scan_run_id" => scan_run_id,
        "agent_id" => "agent-1",
        "target_ip" => "10.0.0.1",
        "mode" => "icmp",
        "available" => true,
        "response_ms" => 1.5,
        "timestamp_ms" => now
      }),
      msg(%{
        "scan_run_id" => scan_run_id,
        "agent_id" => "agent-1",
        "target_ip" => "10.0.0.1",
        "mode" => "tcp",
        "port" => 443,
        "available" => true,
        "response_ms" => 3.2,
        "service" => "https",
        "timestamp_ms" => now
      })
    ]

    assert {:ok, 2} = AdhocScan.process_batch(messages)

    {:ok, rows} = ScanResult.by_scan_run(scan_run_id, actor: SystemActor.system(:adhoc_scan_test))
    assert length(rows) == 2

    tcp = Enum.find(rows, &(&1.mode == "tcp"))
    assert tcp.port == 443
    assert tcp.available == true
    assert tcp.service == "https"

    icmp = Enum.find(rows, &(&1.mode == "icmp"))
    assert icmp.port == nil
    assert_in_delta icmp.response_ms, 1.5, 0.001
  end

  test "ignores non-JSON messages without crashing" do
    assert {:ok, 0} = AdhocScan.process_batch([%{data: "not json", metadata: %{}}])
  end
end
