defmodule ServiceRadarWebNGWeb.DashboardLive.Data.VulnerableAssets do
  @moduledoc false

  import Ecto.Query

  alias ServiceRadar.Inventory.DeviceRiskReducer
  alias ServiceRadarWebNG.Repo
  alias ServiceRadarWebNGWeb.DeviceLive.IndexPath

  @limit 5

  def empty, do: []

  def load do
    query_top_assets()
  rescue
    _ -> []
  end

  def present_row(row) when is_list(row), do: present_row(List.to_tuple(row))

  def present_row({uid, hostname, name, ip, type, score, risk_level, available}) do
    score = clamp_score(score)
    level = risk_level_label(risk_level, score)

    %{
      uid: uid,
      name: first_present([hostname, name, ip, uid]) || "Unknown device",
      type: first_present([type]) || "Device",
      risk_score: score,
      risk_level: level,
      available?: available == true,
      href: IndexPath.show_path(uid, tab: "software")
    }
  end

  def present_row(_row), do: nil

  defp query_top_assets do
    from(d in "ocsf_devices",
      where:
        is_nil(field(d, :deleted_at)) and field(d, :is_active) == true and
          not is_nil(field(d, :risk_score)) and field(d, :risk_score) > 0,
      order_by: [desc: field(d, :risk_score), asc: field(d, :hostname)],
      limit: @limit,
      select: {
        field(d, :uid),
        field(d, :hostname),
        field(d, :name),
        field(d, :ip),
        field(d, :type),
        field(d, :risk_score),
        field(d, :risk_level),
        field(d, :is_available)
      }
    )
    |> Repo.all()
    |> Enum.map(&present_row/1)
    |> Enum.reject(&is_nil/1)
  end

  defp risk_level_label(level, score) when is_binary(level) do
    trimmed = String.trim(level)

    if trimmed == "" do
      score_level(score)
    else
      trimmed
    end
  end

  defp risk_level_label(_level, score), do: score_level(score)

  defp score_level(score) do
    case DeviceRiskReducer.risk_level_for_score(score) do
      {_id, label} -> label
      _ -> "Info"
    end
  end

  defp first_present(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end)
  end

  defp clamp_score(score) when is_integer(score), do: min(max(score, 0), 100)
  defp clamp_score(score) when is_float(score), do: clamp_score(round(score))

  defp clamp_score(score) when is_binary(score) do
    case Integer.parse(String.trim(score)) do
      {number, _} -> clamp_score(number)
      :error -> 0
    end
  end

  defp clamp_score(_score), do: 0
end
