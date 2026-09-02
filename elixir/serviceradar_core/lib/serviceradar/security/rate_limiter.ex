defmodule ServiceRadar.Security.RateLimiter do
  @moduledoc """
  Cluster-aware sliding-window rate limiter backed by per-node ETS and
  broadcast convergence across the libcluster+Horde BEAM cluster.

  Each web-ng / core node owns a local `:set` ETS table keyed by
  `{bucket, subject_key}` whose value is a list of attempt timestamps
  (`System.system_time(:second)`). Reads hit the local table for low
  latency. Writes (records, clears) are also fanned out to peers
  discovered through `ServiceRadar.ProcessRegistry`
  (`{:rate_limiter, node()}` keys) so cluster nodes converge on the
  same counters within the broadcast window. On `:nodeup` a joining
  node requests a snapshot from a peer so it does not enforce against
  a cold counter while peers are already at-limit.

  Buckets are configured at the application level:

      config :serviceradar_core, #{__MODULE__},
        default_bucket: [limit: 60, window_seconds: 60],
        buckets: %{
          auth_local: [limit: 5, window_seconds: 60],
          cli_device_auth: [limit: 30, window_seconds: 60],
          dashboard_publish: [limit: 10, window_seconds: 60]
        }

  Consistency is eventual. A burst that races the broadcast window can
  slip at most `N - 1` extra requests through, where `N` is the cluster
  size — acceptable for rate-limit and lockout purposes.
  """

  use GenServer

  require Logger

  @table :serviceradar_security_rate_limiter
  @registry_type :rate_limiter
  @cleanup_interval to_timeout(minute: 5)
  @registration_interval to_timeout(second: 30)
  @snapshot_timeout to_timeout(second: 2)
  @built_in_default_bucket [limit: 60, window_seconds: 60]
  @built_in_buckets %{
    auth_local: [limit: 5, window_seconds: 60],
    auth_password_reset: [limit: 5, window_seconds: 300],
    auth_oidc_callback: [limit: 30, window_seconds: 60],
    auth_saml_callback: [limit: 30, window_seconds: 60],
    cli_device_auth: [limit: 30, window_seconds: 60],
    dashboard_publish: [limit: 10, window_seconds: 60],
    dashboard_publish_admin: [limit: 30, window_seconds: 60],
    edge_onboarding_package_create_actor: [limit: 10, window_seconds: 60],
    edge_onboarding_package_create_partition: [limit: 30, window_seconds: 60],
    cli_token_poll: [limit: 60, window_seconds: 60],
    plugin_upload: [limit: 10, window_seconds: 60],
    oauth_password_grant: [limit: 10, window_seconds: 60],
    oauth_client_credentials: [limit: 20, window_seconds: 60],
    oauth_authorize: [limit: 30, window_seconds: 60],
    oauth_authorization_code: [limit: 30, window_seconds: 60],
    mcp: [limit: 60, window_seconds: 60],
    remote_access_ssh_certificate_issue: [limit: 10, window_seconds: 60],
    automation_callback_grant: [limit: 30, window_seconds: 60],
    api_default: [limit: 120, window_seconds: 60]
  }

  @type bucket :: atom() | binary()
  @type subject_key :: term()
  @type opts :: [limit: pos_integer(), window_seconds: pos_integer()]

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns `:ok` if a request for `{bucket, key}` is under its limit,
  or `{:error, retry_after_seconds}` if denied.

  Reads the local ETS table only; does not block on peers.
  """
  @spec check(bucket(), subject_key(), opts()) :: :ok | {:error, pos_integer()}
  def check(bucket, key, opts \\ []) do
    {limit, window} = resolve_bucket(bucket, opts)
    do_check(bucket, key, limit, window)
  end

  @doc """
  Records an attempt for `{bucket, key}` and broadcasts it to peers.

  Returns `:ok` unconditionally; use `check/3` or `check_and_record/3`
  to gate on the limit.

  Writes are serialized through the GenServer so concurrent records
  from the same node accumulate correctly. The broadcast to peers is
  fire-and-forget.
  """
  @spec record(bucket(), subject_key(), opts()) :: :ok
  def record(bucket, key, opts \\ []) do
    {_limit, window} = resolve_bucket(bucket, opts)
    GenServer.call(__MODULE__, {:record, bucket, key, window})
  end

  @doc """
  Atomically checks the current window and records the attempt when
  allowed. Atomicity is per-node; broadcast to peers is still async.
  """
  @spec check_and_record(bucket(), subject_key(), opts()) ::
          :ok | {:error, pos_integer()}
  def check_and_record(bucket, key, opts \\ []) do
    {limit, window} = resolve_bucket(bucket, opts)
    GenServer.call(__MODULE__, {:check_and_record, bucket, key, limit, window})
  end

  @doc """
  Clears a bucket/key combination locally and on peers.
  """
  @spec clear(bucket(), subject_key()) :: :ok
  def clear(bucket, key) do
    GenServer.call(__MODULE__, {:clear, bucket, key})
  end

  @doc """
  Returns `{limit, window_seconds}` for a configured bucket. Security-sensitive
  bucket defaults are compiled into this shared module because a parent Mix
  release does not inherit a path dependency's config files. Explicit runtime
  config and caller-supplied `opts` may override those defaults.
  """
  @spec resolve_bucket(bucket(), opts()) :: {pos_integer(), pos_integer()}
  def resolve_bucket(bucket, opts \\ []) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    default = Keyword.get(config, :default_bucket, @built_in_default_bucket)

    buckets =
      Map.merge(@built_in_buckets, config |> Keyword.get(:buckets, %{}) |> normalize_buckets())

    base = Map.get(buckets, bucket, default)
    limit = Keyword.get(opts, :limit, Keyword.get(base, :limit, 60))
    window = Keyword.get(opts, :window_seconds, Keyword.get(base, :window_seconds, 60))
    {limit, window}
  end

  @doc false
  def __table__, do: @table

  @doc false
  def __registry_type__, do: @registry_type

  ## Server callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    register_in_horde()
    :ok = :net_kernel.monitor_nodes(true)
    schedule_cleanup()
    registration_timer = schedule_registration()
    request_snapshot_from_peer()
    {:ok, %{registration_timer: registration_timer}}
  end

  defp register_in_horde do
    if process_registry_available?() do
      case register_with_process_registry() do
        :registered -> remove_stale_self_registrations()
        :error -> :ok
      end
    else
      Logger.debug("RateLimiter: ProcessRegistry unavailable; using local-only enforcement")
      :ok
    end
  rescue
    ArgumentError ->
      Logger.warning(
        "RateLimiter: ProcessRegistry not ready; falling back to local-only enforcement"
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning(
        "RateLimiter: ProcessRegistry unavailable during registration: #{inspect(reason)}; using local-only enforcement"
      )

      :ok
  end

  defp register_with_process_registry do
    case ServiceRadar.ProcessRegistry.register({@registry_type, node()}, %{type: @registry_type}) do
      {:ok, _pid} ->
        :registered

      {:error, {:already_registered, pid}} when pid == self() ->
        :registered

      other ->
        Logger.warning(
          "RateLimiter: ProcessRegistry.register failed: #{inspect(other)}; falling back to local-only enforcement"
        )

        :error
    end
  end

  @impl true
  def handle_call({:check_and_record, bucket, key, limit, window}, _from, state) do
    now = System.system_time(:second)

    case do_check(bucket, key, limit, window, now) do
      :ok ->
        write_attempt(bucket, key, now, window)
        broadcast({:peer_record, bucket, key, now, window})
        {:reply, :ok, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:record, bucket, key, window}, _from, state) do
    now = System.system_time(:second)
    write_attempt(bucket, key, now, window)
    broadcast({:peer_record, bucket, key, now, window})
    {:reply, :ok, state}
  end

  def handle_call({:clear, bucket, key}, _from, state) do
    :ets.delete(@table, {bucket, key})
    broadcast({:peer_clear, bucket, key})
    {:reply, :ok, state}
  end

  def handle_call({:snapshot_request, from_node}, _from, state) do
    snapshot =
      :ets.foldl(
        fn {{_bucket, _key} = full_key, ts_list}, acc ->
          [{full_key, ts_list} | acc]
        end,
        [],
        @table
      )

    Logger.debug("RateLimiter: serving snapshot of #{length(snapshot)} entries to #{from_node}")
    {:reply, {:ok, snapshot}, state}
  end

  @impl true
  def handle_cast({:peer_record, bucket, key, ts, window}, state) do
    write_attempt(bucket, key, ts, window)
    {:noreply, state}
  end

  def handle_cast({:peer_clear, bucket, key}, state) do
    :ets.delete(@table, {bucket, key})
    {:noreply, state}
  end

  def handle_cast({:snapshot_merge, entries}, state) do
    Enum.each(entries, fn {{bucket, key}, ts_list} ->
      merged = merge_timestamps(bucket, key, ts_list)
      :ets.insert(@table, {{bucket, key}, merged})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info(:ensure_registry_registration, state) do
    register_in_horde()
    {:noreply, reschedule_registration(state)}
  end

  def handle_info({:nodeup, node}, state) do
    Logger.debug("RateLimiter: nodeup #{inspect(node)}; requesting snapshot")
    register_in_horde()
    request_snapshot_from_peer()
    {:noreply, state}
  end

  def handle_info({:nodedown, _node}, state), do: {:noreply, state}

  def handle_info(_, state), do: {:noreply, state}

  ## Private

  defp do_check(bucket, key, limit, window, now \\ nil) do
    now = now || System.system_time(:second)
    window_start = now - window
    attempts = get_attempts({bucket, key}, window_start)

    if length(attempts) >= limit do
      oldest = Enum.min(attempts, fn -> now end)
      {:error, max(1, oldest + window - now)}
    else
      :ok
    end
  end

  defp write_attempt(bucket, key, ts, window) do
    cache_key = {bucket, key}
    attempts = get_attempts(cache_key, ts - window)
    # Writes are serialized through the GenServer, so concurrent records
    # accumulate correctly. Peer broadcasts exclude self, so the same
    # logical event is only written once on each node.
    :ets.insert(@table, {cache_key, [ts | attempts]})
    :ok
  end

  defp get_attempts(cache_key, window_start) do
    case :ets.lookup(@table, cache_key) do
      [{^cache_key, attempts}] -> Enum.filter(attempts, &(&1 >= window_start))
      [] -> []
    end
  end

  defp merge_timestamps(bucket, key, incoming) do
    existing = get_attempts({bucket, key}, 0)
    (existing ++ incoming) |> Enum.uniq() |> Enum.sort(:desc)
  end

  defp peer_pids do
    if process_registry_available?() do
      self_pid = self()

      @registry_type
      |> ServiceRadar.ProcessRegistry.select_by_type()
      |> Enum.map(fn {_key, pid, _meta} -> pid end)
      |> Enum.reject(&(&1 == self_pid))
      |> Enum.uniq()
    else
      []
    end
  rescue
    ArgumentError -> []
  end

  defp process_registry_available? do
    Process.whereis(ServiceRadar.ProcessRegistry.registry_name()) != nil
  end

  defp remove_stale_self_registrations do
    self_pid = self()
    current_key = {@registry_type, node()}

    @registry_type
    |> ServiceRadar.ProcessRegistry.select_by_type()
    |> Enum.each(fn
      {^current_key, _pid, _metadata} ->
        :ok

      {key, ^self_pid, _metadata} ->
        ServiceRadar.ProcessRegistry.unregister(key)

      _other ->
        :ok
    end)
  end

  defp schedule_registration do
    Process.send_after(self(), :ensure_registry_registration, @registration_interval)
  end

  defp reschedule_registration(state) do
    if timer = state[:registration_timer] do
      Process.cancel_timer(timer)
    end

    Map.put(state, :registration_timer, schedule_registration())
  end

  defp broadcast(message) do
    Enum.each(peer_pids(), &GenServer.cast(&1, message))
  end

  defp request_snapshot_from_peer do
    self_pid = self()

    case peer_pids() do
      [] ->
        :ok

      [peer | _] ->
        Task.start(fn ->
          try do
            case GenServer.call(peer, {:snapshot_request, node(self_pid)}, @snapshot_timeout) do
              {:ok, entries} ->
                GenServer.cast(self_pid, {:snapshot_merge, entries})

              _ ->
                :ok
            end
          catch
            kind, reason ->
              Logger.debug(
                "RateLimiter: snapshot request to #{inspect(peer)} failed: #{inspect({kind, reason})}"
              )
          end
        end)
    end

    :ok
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp cleanup_expired do
    now = System.system_time(:second)
    # Keep timestamps for at least 24h so long-window buckets (e.g. the
    # 24h backoff bucket added by the lockout work) still see history.
    # Bucket-specific filtering still happens at read time.
    cutoff = now - 86_400

    :ets.foldl(
      fn {key, attempts}, _acc ->
        filtered = Enum.filter(attempts, &(&1 >= cutoff))

        if Enum.empty?(filtered) do
          :ets.delete(@table, key)
        else
          :ets.insert(@table, {key, filtered})
        end

        :ok
      end,
      :ok,
      @table
    )
  end

  defp normalize_buckets(buckets) when is_map(buckets), do: buckets

  defp normalize_buckets(buckets) when is_list(buckets) do
    Map.new(buckets, fn {k, v} -> {k, v} end)
  end

  defp normalize_buckets(_), do: %{}
end
