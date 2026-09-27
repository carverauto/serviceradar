defmodule ServiceRadarWebNG.Topology.AtlasStore do
  @moduledoc """
  Owns the latest semantic topology index and returns bounded levels to readers.

  RuntimeGraph builds replacement indexes outside this process. Publication is
  atomic, so requests keep reading the previous index while discovery refreshes.
  Keeping the index here avoids copying the canonical graph into each HTTP or
  channel process. Only a bounded level or revision list crosses the boundary.
  """

  use GenServer

  alias ServiceRadarWebNG.Topology.Atlas

  @max_watched_levels 64

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, nil, Keyword.take(opts, [:name]))
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [Keyword.put_new(opts, :name, __MODULE__)]}
    }
  end

  @doc "Publishes an already-built index without doing source IO in the reader process."
  def publish(index, server \\ __MODULE__), do: GenServer.call(server, {:publish, index})

  @doc "Reads one bounded selection; client revision checks belong to AtlasReader after enrichment."
  def fetch(level_id \\ "global", server \\ __MODULE__) do
    with {:ok, level_id} <- Atlas.normalize_level_id(level_id) do
      GenServer.call(server, {:fetch, level_id})
    end
  end

  @doc "Selects bounded levels atomically from one canonical generation; absent levels are nil."
  def fetch_many(level_ids, server \\ __MODULE__) do
    with {:ok, level_ids} <- normalize_level_ids(level_ids) do
      GenServer.call(server, {:fetch_many, level_ids})
    end
  end

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_call({:publish, index}, _from, _previous), do: {:reply, :ok, index}

  def handle_call(_request, _from, nil), do: {:reply, {:error, :not_ready}, nil}

  def handle_call({:fetch, level_id}, _from, index) do
    result =
      with {:ok, level} <- Atlas.fetch(index, level_id) do
        {:ok, Map.put(level, :canonical_revision, index.revision)}
      end

    {:reply, result, index}
  end

  def handle_call({:fetch_many, level_ids}, _from, index) do
    levels = Map.new(level_ids, &{&1, selected_level(index, &1)})
    {:reply, {:ok, %{canonical_revision: index.revision, levels: levels}}, index}
  end

  defp selected_level(index, level_id) do
    case Atlas.fetch(index, level_id) do
      {:ok, level} -> Map.put(level, :canonical_revision, index.revision)
      {:error, :not_found} -> nil
    end
  end

  defp normalize_level_ids(level_ids) when is_list(level_ids) and length(level_ids) <= @max_watched_levels do
    level_ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      case Atlas.normalize_level_id(id) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, :invalid_level} -> {:halt, {:error, :invalid_levels}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.uniq(ids)}
      error -> error
    end
  end

  defp normalize_level_ids(_level_ids), do: {:error, :invalid_levels}
end
