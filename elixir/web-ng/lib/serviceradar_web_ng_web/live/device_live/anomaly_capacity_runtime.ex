defmodule ServiceRadarWebNGWeb.DeviceLive.AnomalyCapacityRuntime do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  def open_detail(socket, %{"kind" => kind, "index" => index}) do
    case anomaly_capacity_detail(socket.assigns.anomaly_capacity, kind, index) do
      %{row: %{}} = detail -> assign(socket, :selected_anomaly_capacity_detail, detail)
      nil -> socket
    end
  end

  def open_detail(socket, _params), do: socket

  def close_detail(socket), do: assign(socket, :selected_anomaly_capacity_detail, nil)

  defp anomaly_capacity_detail(%{anomaly_rows: rows}, "anomaly", index), do: detail_from_rows("anomaly", rows, index)

  defp anomaly_capacity_detail(%{capacity_rows: rows}, "capacity", index), do: detail_from_rows("capacity", rows, index)

  defp anomaly_capacity_detail(_overview, _kind, _index), do: nil

  defp detail_from_rows(kind, rows, index) when is_list(rows) do
    with {index, ""} <- Integer.parse(to_string(index)),
         true <- index >= 0,
         %{} = row <- Enum.at(rows, index) do
      %{kind: kind, row: row}
    else
      _ -> nil
    end
  end

  defp detail_from_rows(_kind, _rows, _index), do: nil
end
