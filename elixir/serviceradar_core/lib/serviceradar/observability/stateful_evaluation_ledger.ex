defmodule ServiceRadar.Observability.StatefulEvaluationLedger do
  @moduledoc """
  Which OCSF events have had their stateful evaluation accepted and their
  promotion callback applied.

  EventWriter records this marker only after durable evaluation acceptance and
  its synchronous promotion callback succeed:

      pending = StatefulEvaluationLedger.unevaluated(event_ids)
      :ok = evaluate(pending)            # rejection fails the batch
      :ok = StatefulEvaluationLedger.record(pending)

  This is not a completion receipt. The alert evaluation inbox and receipts
  own ordered effects and replay safety; they deduplicate accepted occurrences
  if a process dies before recording this marker. The marker holds ids, not
  telemetry, and is pruned after three days. Completion receipts have a
  separately configured retention covering the supported source replay horizon.

  A deployment whose alert evaluation is not activated (`Rollout.mode/0` is
  `:prepared`) admits nothing, by design, and the engine answers
  `{:error, :alert_evaluation_not_activated}`. EventWriter must still store and
  acknowledge its records then: a rejection fails the batch, JetStream
  redelivers it until `max_deliver` and drops it, and a batch that commits its
  records together with their admission (lifecycle transitions) loses them. So
  that refusal is a skip, not a failure: nothing is recorded or promoted, and a
  periodic warning says alert rules are not evaluating.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Actors.SystemActor

  require Ash.Query
  require Logger

  @retention_days 3
  @not_activated_log_interval_ms 60_000

  postgres do
    table "stateful_evaluation_ledger"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read]

    create :record do
      accept [:event_id]
      upsert? true
      upsert_identity :event
      upsert_fields []
    end

    destroy :prune do
      require_atomic? false
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
  end

  attributes do
    attribute :event_id, :uuid do
      primary_key? true
      allow_nil? false
      public? true
    end

    create_timestamp :evaluated_at
  end

  identities do
    identity :event, [:event_id]
  end

  @doc """
  Evaluates the unevaluated events of `events` against stateful alert rules,
  once, then passes those same events to `after_evaluation` for the caller's
  own consequences of a first evaluation (log promotion's alerts). The engine
  is `:stateful_alert_engine` (default
  `ServiceRadar.Observability.StatefulAlertEngine`).

  The engine receives each id as UUID text. Bulk-insert rows carry it as 16
  raw bytes, and the engine copies source ids into alert metadata as JSON: its
  own text check cannot tell raw bytes that happen to be valid UTF-8 from text,
  while a 16-byte UUID is never text, so the conversion is made here.
  `after_evaluation` receives the events as given. Each event needs an `:id`
  (UUID text or raw 16 bytes). On an error nothing is recorded and the error
  is returned, so the caller fails its batch and a redelivery retries exactly
  these events.
  """
  @spec evaluate_once([map()], ([map()] -> :ok | {:error, term()})) :: :ok | {:error, term()}
  def evaluate_once(events, after_evaluation \\ fn _pending -> :ok end) do
    apply_once(events, fn pending ->
      pending
      |> Enum.map(fn event -> Map.update!(event, :id, &to_uuid/1) end)
      |> engine().evaluate_events()
      |> case do
        :ok -> after_evaluation.(pending)
        {:error, :alert_evaluation_not_activated} -> skip_not_activated(pending)
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc """
  Admits `events` to stateful evaluation directly, for a caller that commits
  them together with its own writes and so cannot use the ledger. A deployment
  whose alert evaluation is not activated skips them, as `evaluate_once/2` does.
  """
  @spec evaluate_events([map()]) :: :ok | {:error, term()}
  def evaluate_events(events) when is_list(events) do
    case engine().evaluate_events(events) do
      {:error, :alert_evaluation_not_activated} ->
        {:skipped, _count} = skip_not_activated(events)
        :ok

      result ->
        result
    end
  end

  # Only the not-activated refusal is skipped. Draining and capability failures
  # still fail the batch: they are transient states of an activated deployment.
  defp skip_not_activated(events) do
    count = length(events)

    :telemetry.execute(
      [:serviceradar, :observability, :alert_evaluation, :not_activated],
      %{count: count},
      %{}
    )

    # Per EventWriter process, so a busy pipeline logs a few lines a minute.
    now = System.monotonic_time(:millisecond)
    logged_at = Process.get({__MODULE__, :not_activated_logged_at})

    if is_nil(logged_at) or now - logged_at >= @not_activated_log_interval_ms do
      Process.put({__MODULE__, :not_activated_logged_at}, now)

      Logger.warning(
        "Alert evaluation is not activated (SERVICERADAR_ALERT_EVALUATION_MODE=prepared): " <>
          "records are stored, but no alert rule evaluates them"
      )
    end

    {:skipped, count}
  end

  @doc false
  def engine do
    Application.get_env(
      :serviceradar_core,
      :stateful_alert_engine,
      ServiceRadar.Observability.StatefulAlertEngine
    )
  end

  # Applies `consequences` to the events not yet recorded, then records them.
  # On error nothing is recorded and the error is returned, so the caller
  # fails its batch and a redelivery retries exactly these events.
  defp apply_once([], _consequences), do: :ok

  defp apply_once(events, consequences) do
    pending_ids = events |> Enum.map(& &1.id) |> unevaluated() |> MapSet.new()
    pending = Enum.filter(events, &MapSet.member?(pending_ids, &1.id))

    case apply_consequences(pending, consequences) do
      :ok -> record(Enum.map(pending, & &1.id))
      # Not evaluated, so not recorded: nothing claims these events were.
      {:skipped, _count} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp apply_consequences([], _consequences), do: :ok

  defp apply_consequences(pending, consequences) do
    case consequences.(pending) do
      :ok -> :ok
      {:skipped, _count} = skipped -> skipped
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The ids among `event_ids` not yet recorded, in their given order. Accepts
  UUID strings or raw 16-byte ids and returns them as given.
  """
  @spec unevaluated([binary()]) :: [binary()]
  def unevaluated([]), do: []

  def unevaluated(event_ids) when is_list(event_ids) do
    uuids = Enum.map(event_ids, &to_uuid/1)

    recorded =
      __MODULE__
      |> Ash.Query.filter(event_id in ^uuids)
      |> Ash.Query.select([:event_id])
      |> Ash.read!(actor: actor())
      |> MapSet.new(& &1.event_id)

    Enum.reject(event_ids, &MapSet.member?(recorded, to_uuid(&1)))
  end

  @doc "Records `event_ids` as evaluated. Already recorded ids are left alone."
  @spec record([binary()]) :: :ok | {:error, term()}
  def record([]), do: :ok

  def record(event_ids) when is_list(event_ids) do
    event_ids
    |> Enum.map(&%{event_id: to_uuid(&1)})
    |> Ash.bulk_create(__MODULE__, :record,
      actor: actor(),
      return_errors?: true,
      stop_on_error?: true
    )
    |> case do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> {:error, errors}
    end
  end

  @doc "Deletes rows older than the retention window."
  @spec prune(DateTime.t()) :: :ok | {:error, term()}
  def prune(now \\ DateTime.utc_now()) do
    cutoff = DateTime.shift(now, day: -@retention_days)

    __MODULE__
    |> Ash.Query.filter(evaluated_at < ^cutoff)
    |> Ash.bulk_destroy(:prune, %{},
      actor: actor(),
      strategy: [:atomic, :stream],
      return_errors?: true
    )
    |> case do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> {:error, errors}
    end
  end

  defp to_uuid(<<_::128>> = raw), do: Ecto.UUID.load!(raw)
  defp to_uuid(uuid) when is_binary(uuid), do: uuid

  defp actor, do: SystemActor.system(:stateful_evaluation_ledger)
end
