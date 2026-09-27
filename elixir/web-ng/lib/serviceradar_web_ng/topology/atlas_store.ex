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
  @max_level_id_bytes 2_048

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

  @doc "Reads one level, optionally requiring its exact content revision."
  def fetch(level_id \\ "global", revision \\ nil, server \\ __MODULE__) do
    if valid_level_id?(level_id) do
      GenServer.call(server, {:fetch, level_id, revision})
    else
      {:error, :invalid_level}
    end
  end

  @doc "Returns current revisions for the bounded set of levels held by one client."
  def revisions(level_ids, server \\ __MODULE__) do
    if is_list(level_ids) and length(level_ids) <= @max_watched_levels and
         Enum.all?(level_ids, &valid_level_id?/1) do
      GenServer.call(server, {:revisions, Enum.uniq(level_ids)})
    else
      {:error, :invalid_levels}
    end
  end

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_call({:publish, index}, _from, _previous), do: {:reply, :ok, index}

  def handle_call(_request, _from, nil), do: {:reply, {:error, :not_ready}, nil}

  def handle_call({:fetch, level_id, revision}, _from, index) do
    {:reply, Atlas.fetch(index, level_id, revision), index}
  end

  def handle_call({:revisions, level_ids}, _from, index) do
    revisions = Map.new(level_ids, &level_revision(index, &1))
    {:reply, {:ok, %{canonical_revision: index.revision, levels: revisions}}, index}
  end

  defp level_revision(index, level_id) do
    case Atlas.fetch(index, level_id) do
      {:ok, level} ->
        {level_id, %{revision: level.revision, structure_revision: level.structure_revision}}

      {:error, _reason} ->
        {level_id, nil}
    end
  end

  defp valid_level_id?(level_id) do
    is_binary(level_id) and byte_size(level_id) > 0 and byte_size(level_id) <= @max_level_id_bytes
  end
end
