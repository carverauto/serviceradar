defmodule ServiceRadar.PrefixTags.Registry do
  @moduledoc """
  Supervised owner of the prefix-tag source-name ETS registry.

  The source tries and their registration state live together in
  `:persistent_term`; ETS is only the hot-path enumerable index. A small,
  persistent source-name catalog bounds recovery work to prefix-tag sources,
  so a Registry restart never has to scan every term in the VM. This lets a
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
  @source_catalog_key {__MODULE__, :source_catalog}
  @source_catalog_ready_key {__MODULE__, :source_catalog_ready}
  @source_lock_namespace {__MODULE__, :source}
  @source_catalog_lock {__MODULE__, :source_catalog}

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

    :global.trans(
      lock,
      fn ->
        # Remember the name before a Store mutation can publish its handle.
        # The catalog is append-only; active registration remains authoritative
        # in each source's atomic handle. This ordering makes recovery robust if
        # a writer exits between the catalog and handle updates.
        remember_source(source)
        fun.()
      end,
      [node()]
    )
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
    # One upgrade-time compatibility scan seeds the catalog for handles written
    # by versions that predate it. Runtime restart gaps only read the catalog.
    bootstrap_source_catalog()

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
    catalog = :persistent_term.get(@source_catalog_key, :missing)
    ready? = :persistent_term.get(@source_catalog_ready_key, false)

    case {catalog, ready?} do
      {sources, true} when is_list(sources) ->
        Enum.filter(sources, &registered_handle?/1)

      # Compatibility for deliberately unsupervised callers carrying handles
      # from a pre-catalog version. A supervised Registry marks the catalog
      # ready in init/1, so production restart gaps never take this scan path.
      {:missing, _ready?} ->
        legacy_persistent_sources()

      {sources, false} when is_list(sources) ->
        sources
        |> Kernel.++(legacy_persistent_sources())
        |> Enum.uniq()
        |> Enum.filter(&registered_handle?/1)
    end
  end

  defp remember_source(source) do
    if source not in :persistent_term.get(@source_catalog_key, []) do
      with_catalog_lock(fn ->
        # Recheck after taking the cross-source catalog lock so concurrent
        # first-time registrations cannot overwrite one another.
        sources = :persistent_term.get(@source_catalog_key, [])

        if source not in sources do
          :persistent_term.put(@source_catalog_key, [source | sources])
        end
      end)
    end

    :ok
  end

  defp bootstrap_source_catalog do
    with_catalog_lock(fn ->
      catalog = :persistent_term.get(@source_catalog_key, :missing)
      ready? = :persistent_term.get(@source_catalog_ready_key, false)

      if !(is_list(catalog) and ready?) do
        known_sources = if is_list(catalog), do: catalog, else: []

        sources =
          known_sources
          |> Kernel.++(legacy_persistent_sources())
          |> Enum.uniq()

        :persistent_term.put(@source_catalog_key, sources)
        :persistent_term.put(@source_catalog_ready_key, true)
      end
    end)
  end

  defp legacy_persistent_sources do
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

  defp with_catalog_lock(fun) do
    lock = {@source_catalog_lock, self()}
    :global.trans(lock, fun, [node()])
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
