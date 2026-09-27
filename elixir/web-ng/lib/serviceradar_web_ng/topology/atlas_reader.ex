defmodule ServiceRadarWebNG.Topology.AtlasReader do
  @moduledoc """
  Reads final semantic levels using bounded, scope-authorized inventory queries.

  AtlasStore admits the level before any inventory IO. Revisions use one union
  of the admitted device IDs, capped by 64 watched levels of at most 128 nodes.
  No inventory timestamp or lossy notification feed is treated as a validator.
  The canonical generation is rechecked after enrichment so a concurrent graph
  publication cannot publish a result prepared from a retired selection.
  """

  alias ServiceRadarWebNG.Topology.AtlasLevel
  alias ServiceRadarWebNG.Topology.AtlasStore
  alias ServiceRadarWebNG.Topology.GodViewStream

  @max_devices 64 * 128

  @spec fetch(term(), String.t(), non_neg_integer() | nil) :: {:ok, map()} | {:error, term()}
  def fetch(scope, level_id \\ "global", requested_revision \\ nil) do
    with {:ok, selected} <- store_call(fn -> AtlasStore.fetch(level_id) end),
         {:ok, devices} <- read_devices(scope, [selected]),
         {:ok, level} <- AtlasLevel.enrich(selected, devices),
         :ok <- current_generation(selected.canonical_revision),
         :ok <- check_revision(requested_revision, level.revision) do
      {:ok, level}
    end
  end

  @spec revisions(term(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def revisions(scope, level_ids) do
    with {:ok, selected} <- store_call(fn -> AtlasStore.fetch_many(level_ids) end),
         {:ok, devices} <- read_devices(scope, Map.values(selected.levels)),
         {:ok, revisions} <- enrich_revisions(selected.levels, devices),
         :ok <- current_generation(selected.canonical_revision) do
      {:ok, %{canonical_revision: selected.canonical_revision, levels: revisions}}
    end
  end

  defp read_devices(scope, levels) do
    ids =
      levels
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(& &1.nodes)
      |> Enum.reject(&Map.get(&1, :aggregate, false))
      |> Enum.map(& &1.id)
      |> Enum.uniq()
      |> Enum.sort()

    if length(ids) <= @max_devices do
      case GodViewStream.fetch_devices_for_scope(scope, ids) do
        {:ok, devices} -> {:ok, Map.new(devices, &{&1.uid, &1})}
        {:error, %Ash.Error.Forbidden{}} -> {:error, :forbidden}
        {:error, _reason} = error -> error
      end
    else
      {:error, :invalid_levels}
    end
  end

  defp enrich_revisions(levels, devices) do
    Enum.reduce_while(levels, {:ok, %{}}, fn
      {id, nil}, {:ok, revisions} ->
        {:cont, {:ok, Map.put(revisions, id, nil)}}

      {id, level}, {:ok, revisions} ->
        case AtlasLevel.enrich(level, devices) do
          {:ok, enriched} ->
            revision = Map.take(enriched, [:revision, :structure_revision])
            {:cont, {:ok, Map.put(revisions, id, revision)}}

          {:error, _reason} = error ->
            {:halt, error}
        end
    end)
  end

  defp current_generation(expected) do
    case store_call(fn -> AtlasStore.fetch_many([]) end) do
      {:ok, %{canonical_revision: ^expected}} -> :ok
      {:ok, _changed} -> {:error, :source_changed}
      {:error, _reason} = error -> error
    end
  end

  defp check_revision(nil, _current), do: :ok
  defp check_revision(revision, revision), do: :ok
  defp check_revision(_requested, current), do: {:error, {:stale_revision, current}}

  defp store_call(fun) do
    fun.()
  catch
    :exit, {:noproc, _call} -> {:error, :unavailable}
    :exit, {:timeout, _call} -> {:error, :unavailable}
    :exit, {:normal, _call} -> {:error, :unavailable}
    :exit, {:shutdown, _call} -> {:error, :unavailable}
    :exit, {{:shutdown, _reason}, _call} -> {:error, :unavailable}
    :exit, {:killed, _call} -> {:error, :unavailable}
  end
end
