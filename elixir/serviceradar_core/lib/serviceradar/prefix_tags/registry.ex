defmodule ServiceRadar.PrefixTags.Registry do
  @moduledoc """
  Supervised owner of the prefix-tag source-name ETS registry.

  The source tries and their registration state live together in
  `:persistent_term`; ETS is only the hot-path enumerable index. This lets a
  restarted Registry rebuild the index without reloading snapshots and lets
  `Store` continue to work in `--no-start` unit tests without creating an
  unmanaged, globally named process.

  Source mutations use a node-local `:global` lock. The lock serializes a
  source's persistent handle and ETS membership changes while allowing
  different sources to swap independently.
  """

  use GenServer

  @table ServiceRadar.PrefixTags.Store.Sources
  @ready_marker {__MODULE__, :ready}
  @active_handle_key_prefix {ServiceRadar.PrefixTags.Store, :active_handle}
  @source_lock_namespace {__MODULE__, :source}

  @type source :: String.t()

  @doc false
  def table_name, do: @table

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  @spec with_source_lock(source(), (-> result)) :: result when result: var
  def with_source_lock(source, fun) when is_binary(source) and is_function(fun, 0) do
    lock = {{@source_lock_namespace, source}, self()}
    :global.trans(lock, fun, [node()])
  end

  @doc false
  @spec sync_source(source(), boolean()) :: :ok
  def sync_source(source, registered?) when is_binary(source) and is_boolean(registered?) do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _tid when registered? ->
        true = :ets.insert(@table, {source})
        :ok

      _tid ->
        :ets.delete(@table, source)
        :ok
    end
  rescue
    # The table owner may have died between whereis/1 and insert/delete. Its
    # supervised replacement will rehydrate from the persistent handles.
    ArgumentError -> :ok
  end

  @doc false
  @spec sources() :: [source()]
  def sources do
    case :ets.whereis(@table) do
      :undefined ->
        persistent_sources()

      _tid ->
        case :ets.lookup(@table, @ready_marker) do
          [{@ready_marker}] ->
            @table
            |> :ets.tab2list()
            |> Enum.flat_map(fn
              {source} when is_binary(source) -> [source]
              _marker -> []
            end)

          [] ->
            # A newly created named table is visible before init/1 finishes.
            # Keep serving from the authoritative handles until rehydration is
            # complete instead of exposing an empty or partially rebuilt set.
            persistent_sources()
        end
    end
  rescue
    # A restart can remove the table after whereis/1. The fallback is slower,
    # but only runs during that short gap or in deliberately unsupervised tests.
    ArgumentError -> persistent_sources()
  end

  @impl true
  def init(_opts) do
    _tid =
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    rehydrate_sources()
    true = :ets.insert(@table, {@ready_marker})
    {:ok, %{}}
  end

  defp rehydrate_sources do
    # Recheck every discovered source while holding the same lock as Store
    # mutations. This closes both init/install and init/clear races.
    Enum.each(persistent_sources(), fn source ->
      with_source_lock(source, fn ->
        sync_source(source, registered_handle?(source))
      end)
    end)
  end

  defp persistent_sources do
    :persistent_term.get()
    |> Enum.flat_map(fn
      {{@active_handle_key_prefix, source}, {_version, _trie, :registered}}
      when is_binary(source) ->
        [source]

      # Handles created before registration state was embedded were active.
      {{@active_handle_key_prefix, source}, {_version, _trie}} when is_binary(source) ->
        [source]

      _other ->
        []
    end)
    |> Enum.uniq()
  end

  defp registered_handle?(source) do
    case :persistent_term.get(active_handle_key(source), nil) do
      {_version, _trie, :registered} -> true
      {_version, _trie} -> true
      _other -> false
    end
  rescue
    ArgumentError -> false
  end

  defp active_handle_key(source), do: {@active_handle_key_prefix, source}
end
