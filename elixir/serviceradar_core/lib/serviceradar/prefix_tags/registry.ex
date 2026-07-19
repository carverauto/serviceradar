defmodule ServiceRadar.PrefixTags.Registry do
  @moduledoc """
  Long-lived owner of the prefix-tag source-name ETS registry.

  `Store` previously created the public named ETS table in whichever process
  first called `put_trie/2` or `sources/0`. That process owned the table, so its
  exit deleted the registry while per-source tries remained in `:persistent_term`
  — aggregate `lookup/1` then silently dropped every source.

  This GenServer owns the table for the life of the node (including when the
  Loader is disabled).
  """

  use GenServer

  @table ServiceRadar.PrefixTags.Store.Sources

  @doc false
  def table_name, do: @table

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Ensure the registry table exists under this process.

  Safe to call from any process; creates via the owner when the table is missing.
  """
  @spec ensure!() :: :ok
  def ensure! do
    case :ets.whereis(@table) do
      :undefined ->
        pid = ensure_owner_started()
        GenServer.call(pid, :ensure_table)

      _tid ->
        :ok
    end
  end

  defp ensure_owner_started do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        pid

      nil ->
        # Unit tests / partial boot: start an *unlinked* owner so the table is
        # never owned by an ephemeral materializer or exiting test process.
        # Production starts this under Application supervision via start_link/1.
        case GenServer.start(__MODULE__, [], name: __MODULE__) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  @impl true
  def init(_opts) do
    _ = create_table()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:ensure_table, _from, state) do
    _ = create_table()
    {:reply, :ok, state}
  end

  defp create_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :set,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: true
        ])

        :ok

      _tid ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end
end
