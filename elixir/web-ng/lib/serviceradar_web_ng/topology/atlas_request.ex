defmodule ServiceRadarWebNG.Topology.AtlasRequest do
  @moduledoc "Validation shared by semantic level HTTP requests and channel watches."

  alias ServiceRadarWebNG.Topology.Atlas

  @max_levels 64
  @spec parse_levels(map()) :: {:ok, [String.t()]} | {:error, :invalid_levels}
  def parse_levels(params) when is_map(params) do
    case Map.get(params, "level_ids", ["global"]) do
      ids when is_list(ids) and length(ids) <= @max_levels -> normalize_levels(ids)
      _ -> {:error, :invalid_levels}
    end
  end

  def parse_levels(_params), do: {:error, :invalid_levels}

  @doc "Public error codes never include backend error details."
  def error_response(reason) do
    case reason do
      :unauthorized -> {401, %{error: "unauthorized"}}
      :forbidden -> {403, %{error: "forbidden"}}
      :god_view_disabled -> {404, %{error: "god_view_disabled"}}
      :invalid_level -> {400, %{error: "invalid_level"}}
      :invalid_levels -> {400, %{error: "invalid_levels"}}
      :invalid_mode -> {400, %{error: "invalid_mode"}}
      :invalid_revision -> {400, %{error: "invalid_revision"}}
      :not_found -> {404, %{error: "level_not_found"}}
      {:stale_revision, revision} -> {409, %{error: "stale_revision", current_revision: revision}}
      :source_changed -> {503, %{error: "source_changed"}}
      :not_ready -> {503, %{error: "atlas_not_ready"}}
      _ -> {503, %{error: "atlas_unavailable"}}
    end
  end

  defp normalize_levels(ids) do
    ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      case Atlas.normalize_level_id(id) do
        {:ok, canonical} -> {:cont, {:ok, [canonical | acc]}}
        {:error, _reason} -> {:halt, {:error, :invalid_levels}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, normalized |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end
end
