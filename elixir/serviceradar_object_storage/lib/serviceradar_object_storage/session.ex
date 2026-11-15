defmodule ServiceRadarObjectStorage.Session do
  @moduledoc """
  Supervised Longshore client owner that correlates asynchronous NIF replies.

  Submitting `put`, `head`, and `get` from inside this `GenServer` ensures
  `{:longshore_reply, reference, result, {queue_us, operation_us}}` messages
  always arrive at the supervised owner rather than an ephemeral caller. Caller
  timeouts or exits never strand late multi-MiB response binaries in caller
  mailboxes, and optional `owner_token` drain notifications let higher-level
  admission controllers hold capacity until in-flight native I/O physically
  completes.
  """

  use GenServer

  alias ServiceRadarObjectStorage, as: Storage

  @default_drain_timeout_ms 30_000
  @shutdown_margin_ms 5_000

  def child_spec(opts) when is_list(opts) do
    drain_timeout_ms = Keyword.get(opts, :drain_timeout_ms, @default_drain_timeout_ms)

    %{
      id: Keyword.get(opts, :name) || __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: drain_timeout_ms + @shutdown_margin_ms
    }
  end

  def start_link(opts) when is_list(opts) do
    config = Keyword.fetch!(opts, :config)
    drain_timeout_ms = Keyword.get(opts, :drain_timeout_ms, @default_drain_timeout_ms)

    case Keyword.fetch(opts, :name) do
      {:ok, name} when not is_nil(name) ->
        GenServer.start_link(__MODULE__, {config, drain_timeout_ms}, name: name)

      _ ->
        GenServer.start_link(__MODULE__, {config, drain_timeout_ms})
    end
  end

  def put(server, key, bytes, options, opts \\ []) do
    call_submit(server, {:put, key, bytes, options}, opts)
  end

  def head(server, key, expect, opts \\ []) do
    call_submit(server, {:head, key, expect}, opts)
  end

  def get(server, key, range, expect, opts \\ []) do
    call_submit(server, {:get, key, range, expect}, opts)
  end

  def info(server) do
    GenServer.call(server, :info)
  end

  def close(server) do
    GenServer.call(server, :close)
  end

  def await_token_drain(server, token, reply_to \\ self()) when is_pid(reply_to) do
    send(server, {:await_token_drain, token, reply_to})
    :ok
  end

  @impl true
  def init({config, drain_timeout_ms}) do
    Process.flag(:trap_exit, true)

    case Storage.open(config) do
      {:ok, client} ->
        {:ok,
         %{
           client: client,
           drain_timeout_ms: drain_timeout_ms,
           pending: %{},
           by_monitor: %{},
           token_counts: %{},
           token_waiters: %{}
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply, Storage.info(state.client), state}
  end

  def handle_call(:close, _from, state) do
    {:reply, Storage.close(state.client), state}
  end

  def handle_call({:submit, op, budget, owner_token}, {caller_pid, _} = from, state) do
    case dispatch(state.client, op, budget) do
      {:ok, ref} ->
        monitor_ref = Process.monitor(caller_pid)

        entry = %{
          from: from,
          monitor_ref: monitor_ref,
          owner_token: owner_token
        }

        token_counts = increment_token(state.token_counts, owner_token)

        {:noreply,
         %{
           state
           | pending: Map.put(state.pending, ref, entry),
             by_monitor: Map.put(state.by_monitor, monitor_ref, ref),
             token_counts: token_counts
         }}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:longshore_reply, ref, result, stats}, state) do
    case Map.pop(state.pending, ref) do
      {nil, _pending} ->
        {:noreply, state}

      {entry, pending} ->
        if entry.monitor_ref do
          Process.demonitor(entry.monitor_ref, [:flush])
        end

        if entry.from do
          GenServer.reply(entry.from, format_reply(result, stats))
        end

        by_monitor =
          if entry.monitor_ref do
            Map.delete(state.by_monitor, entry.monitor_ref)
          else
            state.by_monitor
          end

        {token_counts, token_waiters} =
          decrement_token(state.token_counts, state.token_waiters, entry.owner_token)

        {:noreply,
         %{
           state
           | pending: pending,
             by_monitor: by_monitor,
             token_counts: token_counts,
             token_waiters: token_waiters
         }}
    end
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.pop(state.by_monitor, monitor_ref) do
      {nil, _by_monitor} ->
        {:noreply, state}

      {ref, by_monitor} ->
        pending =
          Map.update!(state.pending, ref, fn entry ->
            %{entry | from: nil, monitor_ref: nil}
          end)

        {:noreply, %{state | pending: pending, by_monitor: by_monitor}}
    end
  end

  def handle_info({:await_token_drain, token, reply_to}, state) do
    if Map.get(state.token_counts, token, 0) == 0 do
      send(reply_to, {:token_drained, token})
      {:noreply, state}
    else
      waiters =
        Map.update(state.token_waiters, token, [reply_to], fn existing ->
          [reply_to | existing]
        end)

      {:noreply, %{state | token_waiters: waiters}}
    end
  end

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  def handle_info(_other, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Storage.close(state.client)
    drain_replies(state, System.monotonic_time(:millisecond) + state.drain_timeout_ms)
  end

  defp call_submit(server, op, opts) when is_list(opts) do
    case validate_call_opts(opts) do
      {:ok, budget, owner_token, call_timeout} ->
        GenServer.call(server, {:submit, op, budget, owner_token}, call_timeout)

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_call_opts(opts) do
    unknown = Keyword.drop(opts, [:budget, :owner_token, :call_timeout])

    if unknown == [] do
      budget = Keyword.get(opts, :budget, Storage.default_budget())
      owner_token = Keyword.get(opts, :owner_token)
      call_timeout = Keyword.get(opts, :call_timeout, :infinity)

      if valid_call_timeout?(call_timeout) do
        {:ok, budget, owner_token, call_timeout}
      else
        {:error, :bad_config}
      end
    else
      {:error, :bad_config}
    end
  end

  defp valid_call_timeout?(:infinity), do: true
  defp valid_call_timeout?(ms) when is_integer(ms) and ms > 0, do: true
  defp valid_call_timeout?(_), do: false

  defp dispatch(client, {:put, key, bytes, options}, budget) do
    Storage.put_object(client, key, bytes, options, budget)
  end

  defp dispatch(client, {:head, key, expect}, budget) do
    Storage.head_object(client, key, expect, budget)
  end

  defp dispatch(client, {:get, key, range, expect}, budget) do
    Storage.get_object(client, key, range, expect, budget)
  end

  defp format_reply({:ok, report}, stats), do: {:ok, report, stats}
  defp format_reply({:error, reason}, _stats), do: {:error, reason}

  defp increment_token(counts, nil), do: counts
  defp increment_token(counts, token), do: Map.update(counts, token, 1, &(&1 + 1))

  defp decrement_token(counts, waiters, nil), do: {counts, waiters}

  defp decrement_token(counts, waiters, token) do
    case Map.get(counts, token, 0) do
      count when count <= 1 ->
        {recipients, remaining_waiters} = Map.pop(waiters, token, [])
        Enum.each(recipients, &send(&1, {:token_drained, token}))
        {Map.delete(counts, token), remaining_waiters}

      count ->
        {Map.put(counts, token, count - 1), waiters}
    end
  end

  defp drain_replies(state, deadline_ms) do
    timeout = if drained?(state.client, deadline_ms), do: 0, else: 5

    receive do
      {:longshore_reply, _ref, _result, _stats} = reply ->
        {:noreply, state} = handle_info(reply, state)
        drain_replies(state, deadline_ms)
    after
      timeout ->
        if timeout == 0, do: :ok, else: drain_replies(state, deadline_ms)
    end
  end

  defp drained?(client, deadline_ms) do
    Storage.info(client).workers == 0 or System.monotonic_time(:millisecond) >= deadline_ms
  end
end
