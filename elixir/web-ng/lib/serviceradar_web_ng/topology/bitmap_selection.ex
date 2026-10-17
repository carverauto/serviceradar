defmodule ServiceRadarWebNG.Topology.BitmapSelection do
  @moduledoc "Current query membership checks at existing topology search and picking boundaries."

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.DeviceFleetOrdinal
  alias ServiceRadarWebNG.Topology.BitmapQueries
  alias ServiceRadarWebNG.Topology.Native

  require Ash.Query

  @actor SystemActor.system(:topology_bitmap_dictionary)

  def authorize(scope, params, ids) do
    with {:ok, expression} <- expression(params) do
      if is_nil(expression), do: :ok, else: membership(scope, expression, ids)
    end
  end

  def details(scope, params, %{details: details}) do
    case Map.get(params, "kind") do
      "device" -> authorize(scope, params, [details.device.id])
      "relation" -> authorize(scope, params, Enum.map(details.endpoints, & &1.id))
      _ -> unfiltered_only(params)
    end
  end

  @doc "Filtered member paging requires a native intersection page, not filtering an unfiltered page."
  def unfiltered_only(params) do
    if Map.has_key?(params, "query"), do: {:error, :filtered_detail_unavailable}, else: :ok
  end

  defp expression(%{"query" => value}) when is_binary(value) and byte_size(value) <= 16_384 do
    case Jason.decode(value) do
      {:ok, expression} when is_map(expression) -> {:ok, expression}
      _ -> {:error, :invalid_query}
    end
  end

  defp expression(%{"query" => _}), do: {:error, :invalid_query}
  defp expression(_), do: {:ok, nil}

  defp membership(scope, expression, ids) when is_list(ids) and length(ids) in 1..2 do
    ids = Enum.uniq(ids)

    case BitmapQueries.with_query(scope, expression, &contains(&1, ids)) do
      {:ok, {_fence, true}} -> :ok
      {:ok, {_fence, false}} -> {:error, :not_found}
      error -> error
    end
  end

  defp membership(_scope, _expression, _ids), do: {:error, :not_found}

  defp contains(context, ids) do
    with {:ok, budget} <- BitmapQueries.remaining(context),
         {:ok, rows} <-
           DeviceFleetOrdinal
           |> Ash.Query.for_read(:read, %{}, actor: @actor)
           |> Ash.Query.filter(uid in ^ids and tombstoned == false)
           |> Ash.Query.select([:uid, :ordinal])
           |> Ash.read(timeout: budget) do
      if length(rows) == length(ids), do: native_contains(context, Enum.map(rows, & &1.ordinal)), else: {:ok, false}
    end
  end

  defp native_contains(context, ordinals) do
    with {:ok, budget} <- BitmapQueries.remaining(context),
         {:ok, {mask, _causal, _availability, _counts}} <-
           Native.bitmap_query_row_overlay(
             context.ref,
             context.authority,
             context.dictionary_epoch,
             context.index_epoch,
             :device,
             Enum.map(ordinals, &{:leaf, &1}),
             budget
           ) do
      {:ok, mask == :binary.copy(<<1>>, length(ordinals))}
    end
  end
end
