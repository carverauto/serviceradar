defmodule Palisade.ConnectionLimiter do
  @moduledoc """
  Admits long-lived connections (LiveView mounts, websockets, streams)
  against caps on how many are active and how fast new ones arrive, both
  overall and per key.

  An admitted connection holds a slot until its owner process exits. The
  limiter monitors the owner, so a crashed or closed connection gives its
  slot back without any cleanup call. `release/2` frees a slot early.

  ## Starting it

  Add it to the consumer's supervision tree:

      children = [
        {Palisade.ConnectionLimiter,
         name: MyAppWeb.LiveLimiter, max_active: 5_000, max_active_per_key: 20}
      ]

  ## Admitting a LiveView

  A LiveView mounts twice: once for the disconnected HTTP render and again
  over the websocket. Only the connected mount is long-lived, so admit there:

      def mount(_params, _session, socket) do
        if connected?(socket) do
          ip = Palisade.ClientIP.from_connect_info(socket.private.connect_info, client_ip_opts())

          case Palisade.ConnectionLimiter.admit(MyAppWeb.LiveLimiter, ip) do
            :ok -> {:ok, socket}
            {:error, _reason} -> {:ok, redirect(socket, to: "/busy")}
          end
        else
          {:ok, socket}
        end
      end

  ## Options

    * `:name` - process name. Default `Palisade.ConnectionLimiter`.
    * `:max_active` - active connections overall. Default `10_000`.
    * `:max_active_per_key` - active connections per key. Default `20`.
    * `:max_admissions` - admissions overall per window, or `:infinity`
      (default).
    * `:max_admissions_per_key` - admissions per key per window, or
      `:infinity`. Default `30`.
    * `:window_ms` - admission-rate window. Default `60_000`.
    * `:max_tracked_keys` - the most distinct keys the admission-rate counter
      holds in one window. Admissions for new keys are refused when it is
      full. Default `100_000`.

  Admission is a `GenServer.call/3` to one process per limiter. It does only
  map updates, so it is cheap next to a mount, but every admission for a
  limiter is serialized.
  """

  use GenServer

  @defaults [
    name: __MODULE__,
    max_active: 10_000,
    max_active_per_key: 20,
    max_admissions: :infinity,
    max_admissions_per_key: 30,
    window_ms: 60_000,
    max_tracked_keys: 100_000
  ]

  @type reason ::
          :max_active
          | :max_active_per_key
          | :max_admissions
          | :max_admissions_per_key
          | :max_tracked_keys

  @doc false
  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    %{id: {__MODULE__, name}, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Starts a limiter. See the module documentation for options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = Keyword.merge(@defaults, opts)

    Enum.each(
      [:max_active, :max_active_per_key, :window_ms, :max_tracked_keys],
      &positive!(opts, &1)
    )

    Enum.each([:max_admissions, :max_admissions_per_key], &positive_or_infinity!(opts, &1))
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Admits `owner` (default: the caller) as a connection for `key`.

  Returns `:ok` and holds a slot until `owner` exits or `release/2` is
  called, or `{:error, reason}` naming the cap that refused it. Admitting an
  owner that already holds a slot for `key` returns `:ok` without taking a
  second slot.
  """
  @spec admit(GenServer.server(), term(), pid()) :: :ok | {:error, reason()}
  def admit(server, key, owner \\ self()) when is_pid(owner) do
    GenServer.call(server, {:admit, key, owner})
  end

  @doc "Frees every slot `owner` (default: the caller) holds."
  @spec release(GenServer.server(), pid()) :: :ok
  def release(server, owner \\ self()) when is_pid(owner) do
    GenServer.call(server, {:release, owner})
  end

  @doc "Returns the number of active connections overall."
  @spec active(GenServer.server()) :: non_neg_integer()
  def active(server), do: GenServer.call(server, :active)

  @doc "Returns the number of active connections for `key`."
  @spec active(GenServer.server(), term()) :: non_neg_integer()
  def active(server, key), do: GenServer.call(server, {:active, key})

  ## Server

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       limits: Map.new(opts),
       # {owner, key} => monitor ref
       slots: %{},
       # monitor ref => {owner, key}
       monitors: %{},
       active: 0,
       active_by_key: %{},
       window: nil,
       admitted: 0,
       admitted_by_key: %{}
     }}
  end

  @impl GenServer
  def handle_call({:admit, key, owner}, _from, state) do
    state = roll_window(state)

    if Map.has_key?(state.slots, {owner, key}) do
      {:reply, :ok, state}
    else
      case refusal(state, key) do
        nil -> {:reply, :ok, take_slot(state, key, owner)}
        reason -> {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:release, owner}, _from, state) do
    state =
      state.slots
      |> Enum.filter(fn {{slot_owner, _key}, _ref} -> slot_owner == owner end)
      |> Enum.reduce(state, fn {_slot, ref}, acc ->
        Process.demonitor(ref, [:flush])
        free_slot(acc, ref)
      end)

    {:reply, :ok, state}
  end

  def handle_call(:active, _from, state), do: {:reply, state.active, state}

  def handle_call({:active, key}, _from, state),
    do: {:reply, Map.get(state.active_by_key, key, 0), state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _owner, _reason}, state) do
    {:noreply, free_slot(state, ref)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp refusal(%{limits: limits} = state, key) do
    cond do
      state.active >= limits.max_active ->
        :max_active

      Map.get(state.active_by_key, key, 0) >= limits.max_active_per_key ->
        :max_active_per_key

      over?(state.admitted, limits.max_admissions) ->
        :max_admissions

      over?(Map.get(state.admitted_by_key, key, 0), limits.max_admissions_per_key) ->
        :max_admissions_per_key

      not Map.has_key?(state.admitted_by_key, key) and
          map_size(state.admitted_by_key) >= limits.max_tracked_keys ->
        :max_tracked_keys

      true ->
        nil
    end
  end

  defp over?(_count, :infinity), do: false
  defp over?(count, max), do: count >= max

  defp take_slot(state, key, owner) do
    ref = Process.monitor(owner)

    %{
      state
      | slots: Map.put(state.slots, {owner, key}, ref),
        monitors: Map.put(state.monitors, ref, {owner, key}),
        active: state.active + 1,
        active_by_key: Map.update(state.active_by_key, key, 1, &(&1 + 1)),
        admitted: state.admitted + 1,
        admitted_by_key: Map.update(state.admitted_by_key, key, 1, &(&1 + 1))
    }
  end

  defp free_slot(state, ref) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        state

      {{owner, key}, monitors} ->
        %{
          state
          | slots: Map.delete(state.slots, {owner, key}),
            monitors: monitors,
            active: state.active - 1,
            active_by_key: decrement(state.active_by_key, key)
        }
    end
  end

  defp decrement(counts, key) do
    case Map.fetch!(counts, key) do
      1 -> Map.delete(counts, key)
      count -> Map.put(counts, key, count - 1)
    end
  end

  # Admission rate uses fixed windows; a new window clears the counters, which
  # also bounds the per-key map to the keys seen in one window.
  defp roll_window(%{limits: %{window_ms: window_ms}} = state) do
    window = Integer.floor_div(System.monotonic_time(:millisecond), window_ms)

    if window == state.window do
      state
    else
      %{state | window: window, admitted: 0, admitted_by_key: %{}}
    end
  end

  defp positive!(opts, key) do
    value = Keyword.fetch!(opts, key)
    if !(is_integer(value) and value > 0), do: invalid!(key, value)
  end

  defp positive_or_infinity!(opts, key) do
    if Keyword.fetch!(opts, key) != :infinity, do: positive!(opts, key)
  end

  @spec invalid!(atom(), term()) :: no_return()
  defp invalid!(key, value) do
    raise ArgumentError, "invalid #{inspect(key)} for #{inspect(__MODULE__)}: #{inspect(value)}"
  end
end
