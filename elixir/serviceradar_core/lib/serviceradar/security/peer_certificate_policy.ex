defmodule ServiceRadar.Security.PeerCertificatePolicy do
  @moduledoc """
  Replica-local admission and active-transport enforcement for managed peers.

  Snapshots must arrive over an authenticated authority channel. This store does
  not authenticate bytes and never replaces TLS chain or hostname verification.
  Start its task supervisor before this process. Each transport guard owns a
  monotonic deadline and monitors both the store and transport owner, so loss of
  the store does not leave an established managed connection open.
  """
  use GenServer

  @max_validity_ms 30_000

  def start_link(opts) do
    names =
      if Keyword.has_key?(opts, :name), do: Keyword.take(opts, [:name]), else: [name: __MODULE__]

    names = if names[:name] == nil, do: [], else: names
    GenServer.start_link(__MODULE__, opts, names)
  end

  def apply_snapshot(snapshot, server \\ __MODULE__),
    do: GenServer.call(server, {:apply, snapshot})

  def authorize(fingerprint, server \\ __MODULE__), do: call(server, {:authorize, fingerprint})
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Reports this receiver's admission and live guard counts for one full-DER fingerprint."
  def peer_status(fingerprint, server \\ __MODULE__),
    do: call(server, {:peer_status, fingerprint})

  def fingerprint(der) when is_binary(der),
    do: Base.encode16(:crypto.hash(:sha256, der), case: :lower)

  @doc "Registers an admitted transport; close must terminate that exact connection."
  def watch(fingerprint, owner, close, server \\ __MODULE__)
      when is_pid(owner) and is_function(close, 0) do
    call(server, {:watch, fingerprint, owner, close})
  end

  @doc "Register immediately after a verified SSL handshake, before exposing the socket."
  def watch_ssl(socket, owner, server \\ __MODULE__) do
    with {:ok, der} <- :ssl.peercert(socket) do
      watch(fingerprint(der), owner, fn -> :ssl.close(socket, 1_000) end, server)
    end
  end

  @doc "Release the guard only after its transport is closed."
  def release(guard, server \\ __MODULE__), do: GenServer.cast(server, {:release, guard})

  @doc "Compose policy admission with existing SSL verification; unmanaged callers omit this."
  def ssl_options(opts, policy_opts \\ []) do
    state = %{
      previous: Keyword.get(opts, :verify_fun),
      store: Keyword.get(policy_opts, :store, __MODULE__),
      owner: Keyword.get(policy_opts, :owner)
    }

    versions = Keyword.get(opts, :versions, [:"tlsv1.3", :"tlsv1.2"])

    opts =
      if versions == [:"tlsv1.3"],
        do: Keyword.delete(opts, :reuse_sessions),
        else: Keyword.put(opts, :reuse_sessions, false)

    opts =
      if :"tlsv1.3" in versions,
        do: Keyword.put(opts, :session_tickets, :disabled),
        else: Keyword.delete(opts, :session_tickets)

    opts
    |> Keyword.put(:verify, :verify_peer)
    |> Keyword.put(:verify_fun, {&__MODULE__.verify/3, state})
  end

  @doc "Bind a named Gnat connection to the certificate verified during its initialization."
  def gnat_options(settings, name, store \\ __MODULE__) do
    opts = Map.get(settings, :ssl_opts, [])

    opts =
      Keyword.put_new(opts, :server_name_indication, to_charlist(Map.fetch!(settings, :host)))

    Map.merge(settings, %{
      tls: true,
      ssl_opts: ssl_options(opts, store: store, owner: {:gnat, name})
    })
  end

  def verify(cert, event, state) do
    case previous_verify(cert, event, state.previous) do
      {result, previous} when result in [:valid, :valid_peer] ->
        state = %{state | previous: previous}
        if event == :valid_peer, do: admit_certificate(cert, state), else: {result, state}

      {:unknown, previous} ->
        {:unknown, %{state | previous: previous}}

      {:fail, reason} ->
        {:fail, reason}
    end
  end

  defp previous_verify(cert, event, {fun, prior_state}) do
    case fun.(cert, event, prior_state) do
      {result, next} when result in [:valid, :valid_peer, :unknown] -> {result, {fun, next}}
      {:fail, reason} -> {:fail, reason}
    end
  end

  defp previous_verify(_cert, {:bad_cert, reason}, nil), do: {:fail, reason}
  defp previous_verify(_cert, {:extension, _}, nil), do: {:unknown, nil}
  defp previous_verify(_cert, _event, nil), do: {:valid, nil}

  defp admit_certificate(cert, state) do
    der = :public_key.pkix_encode(:OTPCertificate, cert, :otp)
    fp = fingerprint(der)

    with :ok <- authorize(fp, state.store), :ok <- bind_owner(fp, state) do
      {:valid, state}
    else
      {:error, reason} -> {:fail, reason}
    end
  end

  defp bind_owner(_fp, %{owner: nil}), do: :ok

  # OTP 28 keeps verify_fun in the per-connection TLS state machine. The
  # distribution compatibility test owns this dependency in both directions.
  defp bind_owner(fp, %{owner: :verify_process, store: store}) do
    owner = self()

    case watch(fp, owner, fn -> :gen_statem.stop(owner, :normal, 1_000) end, store) do
      {:ok, _guard} -> :ok
      error -> error
    end
  end

  defp bind_owner(fp, %{owner: {:gnat, name}, store: store}) do
    case GenServer.whereis(name) do
      owner when is_pid(owner) ->
        case watch(fp, owner, fn -> GenServer.stop(owner, :normal, 1_000) end, store) do
          {:ok, _guard} -> :ok
          error -> error
        end

      nil ->
        {:error, :transport_owner_missing}
    end
  end

  defp call(server, message) do
    GenServer.call(server, message)
  catch
    :exit, _ -> {:error, :policy_unavailable}
  end

  @impl true
  def init(opts),
    do:
      {:ok,
       %{policy: nil, watchers: %{}, task_supervisor: Keyword.fetch!(opts, :task_supervisor)}}

  @impl true
  def handle_call({:apply, snapshot}, _from, state) do
    with {:ok, policy} <- normalize(snapshot), :ok <- newer(policy, state.policy) do
      policy =
        if state.policy && policy.generated_at == state.policy.generated_at,
          do: state.policy,
          else: policy

      Enum.each(state.watchers, fn {pid, watcher} ->
        message =
          if allowed?(policy, watcher.fingerprint),
            do: {:policy_deadline, policy.deadline},
            else: :revoke

        send(pid, message)
      end)

      {:reply, :ok, %{state | policy: policy}}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:authorize, fp}, _from, state),
    do: {:reply, admission(state.policy, fp), state}

  def handle_call({:watch, fp, owner, close}, _from, state) do
    case admission(state.policy, fp) do
      :ok ->
        watcher = %{fingerprint: fp, owner: owner, close: close, status: :active}
        {pid, state} = start_guard(watcher, state)
        {:reply, {:ok, pid}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(:status, _from, state),
    do: {:reply, policy_status(state.policy, Map.values(state.watchers)), state}

  def handle_call({:peer_status, fp}, _from, state) do
    watchers = state.watchers |> Map.values() |> Enum.filter(&(&1.fingerprint == fp))
    status = policy_status(state.policy, watchers)

    admission =
      cond do
        not status.fresh -> :stale
        MapSet.member?(state.policy.allowed, fp) -> :allowed
        true -> :denied
      end

    {:reply, Map.put(status, :admission, admission), state}
  end

  defp policy_status(policy, watchers) do
    counts = Enum.frequencies_by(watchers, & &1.status)

    %{
      fresh: fresh?(policy),
      generated_at: policy && policy.generated_at,
      valid_until: policy && policy.valid_until,
      active: Map.get(counts, :active, 0),
      closing: Map.get(counts, :closing, 0),
      failed: Map.get(counts, :failed, 0)
    }
  end

  @impl true
  def handle_cast({:release, pid}, state) do
    send(pid, :release)
    {:noreply, forget_guard(state, pid)}
  end

  @impl true
  def handle_info({:guard_status, pid, status}, state) do
    watchers =
      if Map.has_key?(state.watchers, pid),
        do: Map.update!(state.watchers, pid, &Map.put(&1, :status, status)),
        else: state.watchers

    {:noreply, %{state | watchers: watchers}}
  end

  def handle_info({:guard_closed, pid}, state), do: {:noreply, forget_guard(state, pid)}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Map.pop(state.watchers, pid) do
      {nil, _} ->
        {:noreply, state}

      {watcher, watchers} ->
        state = %{state | watchers: watchers}

        if Process.alive?(watcher.owner) do
          {_pid, state} = start_guard(watcher, state)
          {:noreply, state}
        else
          {:noreply, state}
        end
    end
  end

  defp start_guard(watcher, state) do
    store = self()

    deadline =
      if watcher.status == :active && allowed?(state.policy, watcher.fingerprint),
        do: state.policy.deadline,
        else: monotonic_ms()

    {:ok, pid} =
      Task.Supervisor.start_child(state.task_supervisor, fn -> guard(store, watcher, deadline) end)

    monitor = Process.monitor(pid)
    {pid, %{state | watchers: Map.put(state.watchers, pid, Map.put(watcher, :monitor, monitor))}}
  end

  defp forget_guard(state, pid) do
    case Map.pop(state.watchers, pid) do
      {nil, _} ->
        state

      {watcher, watchers} ->
        Process.demonitor(watcher.monitor, [:flush])
        %{state | watchers: watchers}
    end
  end

  defp guard(store, watcher, deadline) do
    Process.flag(:trap_exit, true)
    store_ref = Process.monitor(store)
    owner_ref = Process.monitor(watcher.owner)
    guard_loop(store, store_ref, owner_ref, watcher.close, deadline)
  end

  defp guard_loop(store, store_ref, owner_ref, close, deadline) do
    receive do
      {:policy_deadline, deadline} -> guard_loop(store, store_ref, owner_ref, close, deadline)
      :release -> :ok
      :revoke -> close_transport(store, owner_ref, close)
      {:DOWN, ^owner_ref, :process, _, _} -> send(store, {:guard_closed, self()})
      {:DOWN, ^store_ref, :process, _, _} -> close_transport(store, owner_ref, close)
      {:EXIT, _, _} -> close_transport(store, owner_ref, close)
    after
      max(deadline - monotonic_ms(), 0) -> close_transport(store, owner_ref, close)
    end
  end

  defp close_transport(store, owner_ref, close) do
    send(store, {:guard_status, self(), :closing})

    result =
      try do
        close.()
      rescue
        _ -> {:error, :close_failed}
      catch
        _, _ -> {:error, :close_failed}
      end

    if result in [:ok, {:error, :closed}] do
      send(store, {:guard_closed, self()})
    else
      send(store, {:guard_status, self(), :failed})

      receive do
        {:DOWN, ^owner_ref, :process, _, _} -> send(store, {:guard_closed, self()})
        :release -> :ok
      after
        1_000 -> close_transport(store, owner_ref, close)
      end
    end
  end

  defp normalize(snapshot) when is_map(snapshot) do
    with 1 <- field(snapshot, :version),
         {:ok, generated} <- datetime(field(snapshot, :generated_at)),
         {:ok, until} <- datetime(field(snapshot, :valid_until)),
         allowed when is_list(allowed) <- field(snapshot, :allowed_fingerprints),
         true <- Enum.all?(allowed, &(is_binary(&1) and Regex.match?(~r/\A[0-9a-f]{64}\z/, &1))) do
      now = DateTime.utc_now()
      remaining = DateTime.diff(until, now, :millisecond)
      span = DateTime.diff(until, generated, :millisecond)

      if remaining > 0 && span > 0 && span <= @max_validity_ms &&
           DateTime.diff(generated, now, :millisecond) <= 5_000 do
        {:ok,
         %{
           generated_at: generated,
           valid_until: until,
           allowed: MapSet.new(allowed),
           deadline: monotonic_ms() + min(remaining, @max_validity_ms)
         }}
      else
        {:error, :invalid_snapshot}
      end
    else
      _ -> {:error, :invalid_snapshot}
    end
  end

  defp normalize(_), do: {:error, :invalid_snapshot}
  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp datetime(%DateTime{} = value), do: {:ok, value}

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> {:ok, datetime}
      _ -> {:error, :invalid_time}
    end
  end

  defp datetime(_), do: {:error, :invalid_time}
  defp newer(_policy, nil), do: :ok

  defp newer(policy, previous) do
    case DateTime.compare(policy.generated_at, previous.generated_at) do
      :gt ->
        :ok

      :eq
      when policy.valid_until == previous.valid_until and policy.allowed == previous.allowed ->
        :ok

      _ ->
        {:error, :snapshot_rollback}
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
  defp fresh?(nil), do: false
  defp fresh?(policy), do: monotonic_ms() < policy.deadline
  defp allowed?(policy, fp), do: fresh?(policy) && MapSet.member?(policy.allowed, fp)

  defp admission(policy, fp) do
    cond do
      not fresh?(policy) -> {:error, :policy_unavailable}
      not MapSet.member?(policy.allowed, fp) -> {:error, :certificate_denied}
      true -> :ok
    end
  end
end
