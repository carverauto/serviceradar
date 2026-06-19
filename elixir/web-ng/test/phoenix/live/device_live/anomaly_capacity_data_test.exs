defmodule ServiceRadarWebNGWeb.DeviceLive.AnomalyCapacityDataTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.AnomalyCapacityData

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

  test "SNMP metric subclasses are grouped into the SNMP anomaly status bucket" do
    data = AnomalyCapacityData.load(FakeSRQL, %{device_uid: "router-1"}, nil)

    snmp = Enum.find(data.metric_statuses, &(&1.class == "snmp"))
    red = Enum.find(data.metric_statuses, &(&1.class == "red"))

    assert snmp.status == "active"
    assert snmp.count == 1
    assert red.status == "normal"
    assert red.count == 0
  end
end
