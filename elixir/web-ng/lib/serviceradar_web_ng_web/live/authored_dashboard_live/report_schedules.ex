defmodule ServiceRadarWebNGWeb.AuthoredDashboardLive.ReportSchedules do
  @moduledoc false

  def default_params do
    %{
      "name" => "Daily dashboard report",
      "cron" => "0 8 * * *",
      "timezone" => "UTC",
      "recipients" => ""
    }
  end

  def attrs(params, dashboard_id) do
    params
    |> Map.put("dashboard_id", dashboard_id)
    |> Map.put("recipients", recipients(params["recipients"]))
  end

  def toggle_attrs(%{enabled: true}), do: %{enabled: false}
  def toggle_attrs(%{enabled: false}), do: %{enabled: true}
  def toggle_attrs(_schedule), do: %{}

  defp recipients(value) when is_binary(value) do
    value
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp recipients(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp recipients(_value), do: []
end
