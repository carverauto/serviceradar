defmodule ServiceRadarWebNG.CameraTimelineAdmission do
  @moduledoc """
  ETS-backed bounded in-flight read admission for camera timeline playback
  (`D.3`, `D.4`, `D4`, `spec.md:629, 635-638`).

  Enforces two concurrent init/fragment read ceilings without queuing:
  - Per playback session (`{user_id, camera_source_id}`): default `4` concurrent reads.
  - Per `web-ng` node: default `64` concurrent reads.

  Uses atomic `:ets.update_counter/4` operations and `try ... after` release in
  `with_slot/4` so slots never leak even when a reader raises, exits, or times out.
  """

  use GenServer

  @default_table :camera_timeline_admission
  @default_max_per_session 4
  @default_max_per_node 64
  @node_key :node_inflight

  @type session_id :: {String.t(), String.t()}

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Acquires both node-wide and per-session (`{user_id, camera_source_id}`) slots,
  executes `fun.()`, and guarantees release in an `after` block.

  Returns `{:error, :playback_capacity_exhausted}` immediately when either bound
  is reached.
  """
  @spec with_slot(term(), term(), keyword(), (-> result)) ::
          result | {:error, :playback_capacity_exhausted}
        when result: var
  def with_slot(user_id, camera_source_id, opts \\ [], fun) when is_list(opts) and is_function(fun, 0) do
    case acquire(user_id, camera_source_id, opts) do
      {:ok, token} ->
        try do
          fun.()
        after
          release(token)
        end

      {:error, :playback_capacity_exhausted} = error ->
        error
    end
  end

  @doc """
  Atomically acquires one in-flight slot for `{user_id, camera_source_id}`.
  """
  @spec acquire(term(), term(), keyword()) ::
          {:ok, {:slot, atom() | :ets.tid(), {:session, String.t(), String.t()}}}
          | {:error, :playback_capacity_exhausted}
  def acquire(user_id, camera_source_id, opts \\ []) when is_list(opts) do
    config = merged_config(opts)
    table = ensure_table!(Keyword.get(config, :table, @default_table))
    max_per_session = Keyword.get(config, :max_per_session, @default_max_per_session)
    max_per_node = Keyword.get(config, :max_per_node, @default_max_per_node)

    session_key = {:session, to_string(user_id), to_string(camera_source_id)}

    if max_per_node <= 0 or max_per_session <= 0 do
      {:error, :playback_capacity_exhausted}
    else
      node_count = :ets.update_counter(table, @node_key, {2, 1}, {@node_key, 0})

      if node_count > max_per_node do
        _ = :ets.update_counter(table, @node_key, {2, -1}, {@node_key, 0})
        {:error, :playback_capacity_exhausted}
      else
        acquire_session_slot(table, session_key, max_per_session)
      end
    end
  end

  @doc """
  Releases an acquired slot token idempotently when paired with `acquire/3`.
  """
  @spec release({:slot, atom() | :ets.tid(), {:session, String.t(), String.t()}} | nil) :: :ok
  def release(nil), do: :ok

  def release({:slot, table, session_key}) do
    if table_alive?(table) do
      decrement_session(table, session_key)
      decrement_node(table)
    end

    :ok
  end

  @doc """
  Returns current `{session_inflight, node_inflight}` counts for observability and tests.
  """
  @spec counts(term(), term(), keyword()) :: %{session: non_neg_integer(), node: non_neg_integer()}
  def counts(user_id, camera_source_id, opts \\ []) when is_list(opts) do
    config = merged_config(opts)
    table = Keyword.get(config, :table, @default_table)
    session_key = {:session, to_string(user_id), to_string(camera_source_id)}

    if table_alive?(table) do
      %{
        session: lookup_count(table, session_key),
        node: lookup_count(table, @node_key)
      }
    else
      %{session: 0, node: 0}
    end
  end

  @doc """
  Creates a standalone public ETS table suitable for isolated `:db_free` tests.
  """
  @spec new_table(atom()) :: :ets.tid()
  def new_table(name \\ :camera_timeline_admission_test) when is_atom(name) do
    :ets.new(name, [
      :set,
      :public,
      {:read_concurrency, true},
      {:write_concurrency, true}
    ])
  end

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table, @default_table)
    table = create_named_table(table_name)
    {:ok, %{table: table}}
  end

  defp acquire_session_slot(table, session_key, max_per_session) do
    session_count = :ets.update_counter(table, session_key, {2, 1}, {session_key, 0})

    if session_count > max_per_session do
      decrement_session(table, session_key)
      decrement_node(table)
      {:error, :playback_capacity_exhausted}
    else
      {:ok, {:slot, table, session_key}}
    end
  end

  defp decrement_session(table, session_key) do
    case :ets.update_counter(table, session_key, {2, -1}, {session_key, 0}) do
      0 ->
        _ = :ets.delete_object(table, {session_key, 0})
        :ok

      count when count < 0 ->
        _ = :ets.delete_object(table, {session_key, count})
        :ok

      _ ->
        :ok
    end
  end

  defp decrement_node(table) do
    case :ets.update_counter(table, @node_key, {2, -1}, {@node_key, 0}) do
      count when count < 0 ->
        _ = :ets.insert(table, {@node_key, 0})
        :ok

      _ ->
        :ok
    end
  end

  defp lookup_count(table, key) do
    case :ets.lookup(table, key) do
      [{^key, count}] when is_integer(count) and count > 0 -> count
      _ -> 0
    end
  end

  defp merged_config(opts) do
    :serviceradar_web_ng
    |> Application.get_env(:camera_timeline_admission, [])
    |> Keyword.merge(opts)
  end

  defp ensure_table!(table) when is_reference(table), do: table

  defp ensure_table!(table) when is_atom(table) do
    case :ets.whereis(table) do
      :undefined -> create_named_table(table)
      tid -> tid
    end
  end

  defp create_named_table(table_name) when is_atom(table_name) do
    case :ets.whereis(table_name) do
      :undefined ->
        try do
          :ets.new(table_name, [
            :set,
            :public,
            :named_table,
            {:read_concurrency, true},
            {:write_concurrency, true}
          ])
        rescue
          ArgumentError -> :ets.whereis(table_name)
        end

      tid ->
        tid
    end
  end

  defp table_alive?(table) when is_reference(table), do: :ets.info(table) != :undefined
  defp table_alive?(table) when is_atom(table), do: :ets.whereis(table) != :undefined
  defp table_alive?(_), do: false
end
