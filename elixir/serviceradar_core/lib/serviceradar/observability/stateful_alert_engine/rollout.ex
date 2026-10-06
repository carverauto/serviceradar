defmodule ServiceRadar.Observability.StatefulAlertEngine.Rollout do
  @moduledoc """
  Fail-closed admission and consumer capability checks for the durable cutover.

  Prepared installations reject new admission. Operators first retire every
  old evaluator (including disconnected pods), verify the deployment cohort,
  and only then activate it. Draining rejects new admission while consumers
  finish accepted work. Connected peer checks and legacy registrations are
  additional safeguards, not a substitute for checking the complete deployment.
  """

  alias ServiceRadar.Observability.AlertEvaluationReceipt
  alias ServiceRadar.Observability.StatefulAlertEngine.EvaluationWorker
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  @capability "durable-alert-evaluation-v1"

  def mode, do: Application.get_env(:serviceradar_core, :alert_evaluation_mode, :prepared)
  def consumers_enabled?, do: mode() in [:active, :draining]

  @doc "Whether this host is configured to consume the shared alert work queue."
  def alert_consumer? do
    config = Application.get_env(:serviceradar_core, Oban, false)

    if Application.get_env(:serviceradar_core, :oban_enabled, true) and is_list(config) do
      queues = Keyword.get(config, :queues, [])
      queue = if is_list(queues), do: Keyword.get(queues, :alerts)
      limit = if is_list(queue), do: Keyword.get(queue, :limit), else: queue
      is_integer(limit) and limit > 0
    else
      false
    end
  end

  @doc "Validated deployment settings shared by core and embedded-core releases."
  def runtime_config! do
    mode =
      case System.get_env("SERVICERADAR_ALERT_EVALUATION_MODE", "prepared") do
        "prepared" -> :prepared
        "active" -> :active
        "draining" -> :draining
        _ -> raise ArgumentError, "invalid alert evaluation mode"
      end

    limits =
      Enum.flat_map(
        [
          :admission_timeout_ms,
          :batch_records,
          :batch_work,
          :pending_count,
          :pending_bytes,
          :rule_count,
          :rule_bytes
        ],
        fn key ->
          name = "SERVICERADAR_ALERT_EVALUATION_" <> String.upcase(Atom.to_string(key))

          case System.get_env(name) do
            nil -> []
            value -> [{key, positive!(name, value)}]
          end
        end
      )

    replay =
      positive!(
        "SERVICERADAR_ALERT_EVALUATION_REPLAY_DAYS",
        System.get_env("SERVICERADAR_ALERT_EVALUATION_REPLAY_DAYS", "7")
      )

    retention =
      positive!(
        "SERVICERADAR_ALERT_EVALUATION_RECEIPT_DAYS",
        System.get_env("SERVICERADAR_ALERT_EVALUATION_RECEIPT_DAYS", "7")
      )

    if retention < replay,
      do: raise(ArgumentError, "alert receipts must cover the source replay horizon")

    [
      alert_evaluation_mode: mode,
      alert_evaluation_limits: limits,
      alert_evaluation_replay_days: replay,
      alert_evaluation_receipt_days: retention
    ]
  end

  defp positive!(name, value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _ -> raise ArgumentError, "invalid alert evaluation setting #{name}"
    end
  end

  def admission_ready do
    with :active <- mode(),
         {:ok, @capability} <- capability(),
         :ok <- no_legacy_registration(),
         :ok <- peer_capabilities() do
      :ok
    else
      :prepared -> {:error, :alert_evaluation_not_activated}
      :draining -> {:error, :alert_evaluation_draining}
      {:error, _} = error -> error
      _ -> {:error, :alert_evaluation_capability_unavailable}
    end
  end

  @doc "Deployment capability queried before enabling admission on connected evaluator peers."
  def capability do
    with true <- Application.get_env(:serviceradar_core, :repo_enabled, true) != false,
         true <- is_pid(Process.whereis(Repo)),
         true <- ObanSupport.available?(),
         true <- AlertEvaluationReceipt.retention_valid?(),
         true <- Code.ensure_loaded?(EvaluationWorker),
         true <- consumer_ready?(),
         {:ok, %{rows: [[true]]}} <-
           Repo.query(
             """
             SELECT to_regclass('platform.alert_evaluation_work') IS NOT NULL
                AND to_regclass('platform.alert_evaluation_receipts') IS NOT NULL
                AND to_regclass('platform.alert_evaluation_lanes') IS NOT NULL
                AND EXISTS (SELECT 1 FROM pg_trigger
                            WHERE tgname = 'fence_alert_rule_admission' AND NOT tgisinternal)
             """,
             [],
             timeout: 1_000
           ) do
      {:ok, @capability}
    else
      _ -> {:error, :alert_evaluation_capability_unavailable}
    end
  rescue
    _ -> {:error, :alert_evaluation_capability_unavailable}
  catch
    :exit, _ -> {:error, :alert_evaluation_capability_unavailable}
  end

  defp consumer_ready? do
    # Oban's manual mode is a real supported consumer driven by drain_queue,
    # used by the CI fixture. Production must have its bounded alerts producer.
    case Oban.config().testing do
      testing when testing in [:manual, :inline] ->
        true

      _ ->
        case Oban.check_queue(queue: :alerts) do
          %{limit: limit, paused: false} when is_integer(limit) and limit > 0 -> true
          _ -> false
        end
    end
  end

  defp no_legacy_registration do
    entries =
      if Process.whereis(ProcessRegistry.registry_name()),
        do: ProcessRegistry.select_all(),
        else: []

    if Enum.any?(entries, fn
         {:stateful_alert_engine, _, _} -> true
         {{:stateful_alert_engine, _}, _, _} -> true
         _ -> false
       end), do: {:error, :legacy_alert_evaluator_present}, else: :ok
  rescue
    _ -> {:error, :alert_evaluation_capability_unavailable}
  catch
    :exit, _ -> {:error, :alert_evaluation_capability_unavailable}
  end

  defp peer_capabilities do
    peers = Node.list()

    handlers =
      :erpc.multicall(
        peers,
        Application,
        :get_env,
        [:serviceradar_core, :status_handler_enabled, false],
        500
      )

    writers =
      :erpc.multicall(
        peers,
        Application,
        :get_env,
        [:serviceradar_core, :event_writer_enabled, false],
        500
      )

    consumers = :erpc.multicall(peers, __MODULE__, :alert_consumer?, [], 500)

    with {:ok, evaluators} <- evaluator_peers(Enum.zip([peers, handlers, writers, consumers])) do
      # One deadline covers the whole cohort, rather than one timeout per node.
      evaluators
      |> :erpc.multicall(__MODULE__, :capability, [], 1_500)
      |> Enum.all?(&(&1 == {:ok, {:ok, @capability}}))
      |> case do
        true -> :ok
        false -> {:error, :alert_evaluation_peer_not_ready}
      end
    end
  catch
    _, _ -> {:error, :alert_evaluation_peer_not_ready}
  end

  defp evaluator_peers(entries) do
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
end
