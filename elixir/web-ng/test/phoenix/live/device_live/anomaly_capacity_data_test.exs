defmodule ServiceRadarWebNGWeb.DeviceLive.AnomalyCapacityDataTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadarWebNGWeb.DeviceLive.AnomalyCapacityData

  setup_all do
    if Process.whereis(ServiceRadarWebNG.TaskSupervisor) do
      :ok
    else
      start_supervised!({Task.Supervisor, name: ServiceRadarWebNG.TaskSupervisor})
      :ok
    end
  end

  defmodule FakeSRQL do
    @moduledoc false
    def query("in:events" <> _rest, _opts) do
      {:ok,
       %{
         "results" => [
           %{
             "metric_class" => "snmp.if_octets",
             "status" => "active",
             "time" => "2026-06-19T00:00:00Z"
           }
         ]
       }}
    end

    def query("in:capacity_forecasts" <> _rest, _opts), do: {:ok, %{"results" => []}}
  end

  defmodule RaisingSRQL do
    @moduledoc false

    def query("in:events" <> _rest, _opts), do: raise("boom")
    def query("in:capacity_forecasts" <> _rest, _opts), do: {:ok, %{"results" => []}}
  end

  defmodule SlowSRQL do
    @moduledoc false

    def query("in:events" <> _rest, _opts), do: Process.sleep(:infinity)
    def query("in:capacity_forecasts" <> _rest, _opts), do: {:ok, %{"results" => []}}
  end

  test "SNMP metric subclasses are grouped into the SNMP anomaly status bucket" do
    data = AnomalyCapacityData.load(FakeSRQL, %{device_uid: "router-1"}, nil)

    snmp = Enum.find(data.metric_statuses, &(&1.class == "snmp"))
    red = Enum.find(data.metric_statuses, &(&1.class == "red"))

    assert snmp.status == "active"
    assert snmp.count == 1
    assert red.status == "normal"
    assert red.count == 0
  end

  test "SRQL task crashes return an error result without raising" do
    {data, log} =
      with_log(fn ->
        AnomalyCapacityData.load(RaisingSRQL, %{device_uid: "router-1"}, nil)
      end)

    assert data.status == :error
    assert data.anomaly_rows == []
    assert data.anomaly_error =~ "anomaly SRQL task failed"
    assert log =~ "anomaly SRQL task failed"
  end

  test "SRQL task timeouts return an error result without hanging" do
    {data, log} =
      with_log(fn ->
        AnomalyCapacityData.load(SlowSRQL, %{device_uid: "router-1"}, nil)
      end)

    assert data.status == :error
    assert data.anomaly_rows == []
    assert data.anomaly_error =~ "anomaly SRQL query timed out"
    assert log =~ "anomaly SRQL query timed out"
  end
end
