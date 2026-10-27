defmodule ServiceRadar.Observability.StatefulAlertEngine.PeerReadiness do
  @moduledoc """
  Cluster-wide check that every connected alert evaluator can take durable work.

  `Rollout.admission_ready/0` refuses admission unless every connected node
  either runs none of the evaluator roles (status handler, EventWriter, alert
  consumer) or reports the deployment capability. Each peer answers with one
  call to `readiness/0`, and one deadline covers the whole cohort.

  Admission runs once per ingest batch, so the check is shaped for that rate:

    * A passing result is reused for two seconds while cluster membership is
      unchanged. Any node joining or leaving invalidates it, and a failure is
      never cached, so a refusal is always re-checked.
    * A failing check is retried once after a short pause before admission is
      refused. A peer that stalls briefly (a GC pause, a scheduler hiccup) then
      no longer fails a whole batch, while a peer that is really not ready
      still does.

  Peers running a release that predates `readiness/0` answer `:undef`. They are
  checked with the previous per-role calls instead, so a rolling upgrade never
  blocks admission. That fallback can go once no supported release predates
  `readiness/0`.

  This process owns the cache table. When it is not running, every check
  queries the peers, so the verdict never depends on the cache existing.
  """

  use GenServer

  alias ServiceRadar.Observability.StatefulAlertEngine.Rollout

  @table __MODULE__
  @cache_ttl_ms 2_000
  @deadline_ms 1_500
  @retry_delay_ms 250
  @legacy_role_deadline_ms 500

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  This node's answer to a peer check: `:not_evaluator` when it runs none of
  the evaluator roles, otherwise `{:evaluator, Rollout.capability()}`.
  """
  @spec readiness() :: :not_evaluator | {:evaluator, term()} | :invalid_roles
  def readiness do
    maybe_set_process_label({__MODULE__, :readiness})

    roles = [
      Application.get_env(:serviceradar_core, :status_handler_enabled, false),
      Application.get_env(:serviceradar_core, :event_writer_enabled, false),
      Rollout.alert_consumer?()
    ]

    cond do
      roles == [false, false, false] -> :not_evaluator
      Enum.all?(roles, &is_boolean/1) -> {:evaluator, Rollout.capability()}
      true -> :invalid_roles
    end
  end

  @doc "`:ok` when every connected peer is ready for durable alert admission."
  @spec check() :: :ok | {:error, :alert_evaluation_peer_not_ready}
  def check do
    case attempt() do
      :ok ->
        :ok

      {:error, _} ->
        Process.sleep(@retry_delay_ms)
        attempt()
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  defp attempt do
    peers = Enum.sort(Node.list())

    if cached?(peers) do
      :ok
    else
      with :ok <- query(peers), do: remember(peers)
    end
  end

  defp query(peers) do
    expected = Rollout.capability_name()

    peers
    |> :erpc.multicall(__MODULE__, :readiness, [], @deadline_ms)
    |> Enum.zip(peers)
    |> Enum.reduce_while({:ok, []}, fn
      {{:ok, :not_evaluator}, _peer}, acc ->
        {:cont, acc}

      {{:ok, {:evaluator, {:ok, ^expected}}}, _peer}, acc ->
        {:cont, acc}

      {{:error, {:exception, :undef, [{__MODULE__, :readiness, _, _} | _]}}, peer},
      {:ok, legacy} ->
        {:cont, {:ok, [peer | legacy]}}

      _result, _acc ->
        {:halt, {:error, :alert_evaluation_peer_not_ready}}
    end)
    |> case do
      {:ok, []} -> :ok
      {:ok, legacy} -> legacy_query(legacy, expected)
      {:error, _} = error -> error
    end
  catch
    _, _ -> {:error, :alert_evaluation_peer_not_ready}
  end

  # The pre-readiness/0 protocol: one call per role, then the capability of
  # each evaluator. Only peers on an older release take this path.
  defp legacy_query(peers, expected) do
    handlers =
      role_multicall(peers, Application, :get_env, [
        :serviceradar_core,
        :status_handler_enabled,
        false
      ])

    writers =
      role_multicall(peers, Application, :get_env, [
        :serviceradar_core,
        :event_writer_enabled,
        false
      ])

    consumers = role_multicall(peers, Rollout, :alert_consumer?, [])

    with {:ok, evaluators} <- legacy_evaluators(Enum.zip([peers, handlers, writers, consumers])) do
      evaluators
      |> :erpc.multicall(Rollout, :capability, [], @deadline_ms)
      |> Enum.all?(&(&1 == {:ok, {:ok, expected}}))
      |> if(do: :ok, else: {:error, :alert_evaluation_peer_not_ready})
    end
  end

  defp role_multicall(peers, module, function, args),
    do: :erpc.multicall(peers, module, function, args, @legacy_role_deadline_ms)

  defp legacy_evaluators(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn
      {_peer, {:ok, false}, {:ok, false}, {:ok, false}}, acc ->
        {:cont, acc}

      {peer, {:ok, handler}, {:ok, writer}, {:ok, consumer}}, {:ok, acc}
      when is_boolean(handler) and is_boolean(writer) and is_boolean(consumer) ->
        {:cont, {:ok, [peer | acc]}}

      _, _ ->
        {:halt, {:error, :alert_evaluation_peer_not_ready}}
    end)
  end

  defp cached?(peers) do
    with tid when tid != :undefined <- :ets.whereis(@table),
         [{:ready, ^peers, expires_at}] <- :ets.lookup(tid, :ready) do
      expires_at > now_ms()
    else
      _ -> false
    end
  end

  defp remember(peers) do
    case :ets.whereis(@table) do
      :undefined -> :ok
      tid -> :ets.insert(tid, {:ready, peers, now_ms() + @cache_ttl_ms})
    end

    :ok
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp maybe_set_process_label(caller) do
    case Process.info(self(), :registered_name) do
      {:registered_name, []} -> Process.set_label(caller)
      _ -> :ok
    end
  end
end
