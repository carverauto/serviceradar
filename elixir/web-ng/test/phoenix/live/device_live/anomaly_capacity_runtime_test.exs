defmodule ServiceRadarWebNGWeb.DeviceLive.AnomalyCapacityRuntimeTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias ServiceRadarWebNGWeb.DeviceLive.AnomalyCapacityRuntime

  @moduletag :db_free

  test "selects an already-loaded anomaly or capacity row by kind and index" do
    anomaly = %{"finding_uid" => "finding-1"}
    capacity = %{"resource_key" => "disk:/"}
    socket = socket_with_rows([anomaly], [capacity])

    socket =
      AnomalyCapacityRuntime.open_detail(socket, %{
        "kind" => "anomaly",
        "index" => "0"
      })

    assert socket.assigns.selected_anomaly_capacity_detail == %{kind: "anomaly", row: anomaly}

    socket =
      AnomalyCapacityRuntime.open_detail(socket, %{
        "kind" => "capacity",
        "index" => "0"
      })

    assert socket.assigns.selected_anomaly_capacity_detail == %{kind: "capacity", row: capacity}
    assert AnomalyCapacityRuntime.close_detail(socket).assigns.selected_anomaly_capacity_detail == nil
  end

  test "forged kind or index is a no-op" do
    socket = socket_with_rows([%{"finding_uid" => "finding-1"}], [])

    assert AnomalyCapacityRuntime.open_detail(socket, %{"kind" => "logs", "index" => "0"}).assigns ==
             socket.assigns

    assert AnomalyCapacityRuntime.open_detail(socket, %{"kind" => "anomaly", "index" => "-1"}).assigns ==
             socket.assigns

    assert AnomalyCapacityRuntime.open_detail(socket, %{"kind" => "anomaly", "index" => "100"}).assigns ==
             socket.assigns
  end

  defp socket_with_rows(anomaly_rows, capacity_rows) do
    %Socket{
      assigns: %{
        __changed__: %{},
        anomaly_capacity: %{anomaly_rows: anomaly_rows, capacity_rows: capacity_rows},
        selected_anomaly_capacity_detail: nil
      }
    }
  end
end
