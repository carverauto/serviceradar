defmodule ServiceRadar.Notifications.ActionRedemption do
  @moduledoc """
  Turns a presented capability token into an alert state change plus an audit row
  (design D7 Phase 1, task 1.6.6).

  This is the half of the action-link mechanism that touches the alert lifecycle.
  It deliberately owns no crypto: `ServiceRadar.Notifications.ActionToken` decides
  whether a token is real, and this module decides what a real one does.

  ## It goes through the existing `Alert` actions

  `update :acknowledge`, `update :snooze`, and `update :resolve` already exist on
  `ServiceRadar.Monitoring.Alert` with an RBAC permission described verbatim as
  "Acknowledge and resolve alerts" and, until this change, no user interface at
  all. Nothing here reimplements them, and nothing here writes `status`,
  `acknowledged_at`, or `snooze_until` directly - the state machine stays the
  only thing that moves an alert.

  ## Halting escalation is the status transition, not a second mechanism

  Task 1.6.6 requires that acknowledging halts escalation. That is already what
  `:acknowledged` means: `Suppression.acknowledged?/1` keys on
  `status == :acknowledged` and nothing else
  (`notifications/suppression.ex:306`), and suppression is re-evaluated at every
  dispatch rather than only at routing (design D5), so an `:if_unacknowledged`
  rung due fifteen minutes from now is withheld with reason `:acknowledged` when
  it comes due. Cancelling scheduled deliveries here as well would be a second
  implementation of the same gate, and the two would drift.

  ## Actor identity

  There is no platform user behind a link click. The capability authenticates the
  *bearer of one delivery's token*, not a person, so every row written here is
  `actor_kind: :external_principal` with `source: :action_link`, and
  `external_principal` is `"action_link:<delivery_id>"` - traceable to the
  delivery whose body carried the link, and never silently promoted to an
  `actor_user_id`. That promotion is the Phase 4 open question recorded on
  `NotificationAcknowledgement`.

  ## Three outcomes, and why "already" is a success

    * `:applied` - the alert moved.
    * `:already_applied` - the capability was real and is now spent, but the
      alert was already in the state it asked for. This is the fan-out case: an
      operator acknowledges in Slack, then clicks the link in the email that also
      paged them. A `NotificationAcknowledgement` row IS written, because a
      second human acting is a real event worth auditing, but the alert does not
      transition twice.
    * `:replayed` - the *same* token was presented again. Nothing is written at
      all: this is one event delivered twice, not two events. See `ActionToken`
      for why a mail scanner that GETs every link makes this the required
      behaviour rather than a convenience.

  Only `:applied` and `:already_applied` consume a capability; `:replayed` finds
  one already consumed.

  ## Atomicity

  The consume, the alert transition, and the audit row commit together. Without
  that, a transient failure between burning the capability and applying it would
  leave an operator holding a dead link and an alert nobody acknowledged - the
  one failure mode a single-use credential must not have.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Notifications.ActionToken
  alias ServiceRadar.Notifications.NotificationAcknowledgement
  alias ServiceRadar.Notifications.NotificationDelivery
  alias ServiceRadar.Notifications.RoutingWorker
  alias ServiceRadar.Notifications.Telemetry
  alias ServiceRadar.Repo

  @acknowledged_statuses [:acknowledged]
  @resolved_statuses [:resolved]

  # Snoozing only means anything for an alert that is still going to page
  # someone; "snoozed" is derived as `status in [:pending, :escalated] and
  # snooze_until > now()` (design "Alert Lifecycle Changes").
  @snoozable_statuses [:pending, :escalated]

  defmodule Outcome do
    @moduledoc """
    What a redemption did. See `ServiceRadar.Notifications.ActionRedemption` for
    why `:already_applied` and `:replayed` are successes.
    """

    @enforce_keys [:status, :action, :alert_id, :delivery_id]
    defstruct [
      :status,
      :action,
      :alert_id,
      :delivery_id,
      :alert_status,
      :snooze_until,
      :acknowledgement_id,
      :consumed_at
    ]

    @type status :: :applied | :already_applied | :replayed

    @type t :: %__MODULE__{
            status: status(),
            action: ActionToken.action(),
            alert_id: String.t(),
            delivery_id: String.t(),
            alert_status: atom() | nil,
            snooze_until: DateTime.t() | nil,
            acknowledgement_id: String.t() | nil,
            consumed_at: DateTime.t() | nil
          }
  end

  @type failure ::
          ActionToken.failure()
          | :alert_not_found
          | {:alert_not_actionable, atom()}
          | term()

  @doc """
  Verifies a presented token and applies what it grants.

  ## Options

    * `:now` - the instant expiry and any snooze are measured from.
    * `:note` - free text recorded on the alert and the audit row.
    * `:external_principal` - overrides the default
      `"action_link:<delivery_id>"`.
    * `:actor` - defaults to a system actor. The capability is the
      authorisation; the actor is what lets the write pass policy.
    * `:enqueue_routing` - a two-argument routing enqueue function. Intended
      for tests; production uses `RoutingWorker.enqueue/2`.
  """
  @spec redeem(term(), keyword()) :: {:ok, Outcome.t()} | {:error, failure()}
  def redeem(token, opts \\ []) do
    actor = actor(opts)
    opts = Keyword.put(opts, :actor, actor)

    case ActionToken.verify(token, opts) do
      {:ok, :already_consumed, record} -> {:ok, emit_acknowledged(replayed(record), nil, opts)}
      {:ok, :active, record} -> apply_capability(record, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Applies an already-authorised action that arrived without a capability token.

  This is the ingress for a native interactive component - a Slack button, a
  Discord component, a PagerDuty acknowledgement webhook (task 4.3.7). Those
  carry no capability token: the provider's signature over the request is what
  authorises them, and the caller is responsible for having verified it *before*
  calling this. Nothing here re-checks authorisation.

  It deliberately shares `apply_to_alert/2` with `redeem/2` rather than
  reimplementing the effect. Interactive components are a second **ingress** to
  one acknowledgement mechanism, not a second acknowledgement mechanism - so a
  native acknowledgement halts escalation, writes its audit row, and emits its
  telemetry on exactly the code path an action link does. A parallel
  implementation would drift, and the way it would drift is that one of the two
  stops halting escalation.

  What differs is provenance, not effect: the acknowledgement row and the
  telemetry record `source: :callback`, and `:external_principal` names the
  provider identity (`"slack:U123"`).

  There is no single-use token to consume, so idempotency comes from
  `disposition/3`, which returns `:already_applied` against an alert that is
  already in the target state. That is the same guard that absorbs a
  double-clicked action link, and it is what makes a provider's retry safe.

  ## Options

  As `redeem/2`, plus `:source` (defaults to `:callback` here).
  """
  @spec apply_native(map(), keyword()) :: {:ok, Outcome.t()} | {:error, failure()}
  def apply_native(capability, opts \\ [])

  def apply_native(%{action: action, alert_id: alert_id} = capability, opts)
      when action in [:acknowledge, :snooze, :resolve] and is_binary(alert_id) do
    actor = actor(opts)

    opts =
      opts
      |> Keyword.put(:actor, actor)
      |> Keyword.put_new(:source, :callback)

    with {:ok, snooze_seconds} <- native_snooze_seconds(capability, action) do
      record = %{
        action: action,
        alert_id: alert_id,
        delivery_id: Map.get(capability, :delivery_id),
        snooze_seconds: snooze_seconds,
        consumed_at: nil
      }

      apply_native_record(record, opts)
    end
  end

  def apply_native(_capability, _opts), do: {:error, :invalid_native_capability}

  # A snooze with no duration is rejected rather than given a house default, the
  # same way `ActionToken` rejects one. A default here would mean two ingresses
  # to one mechanism disagreeing about how long "snooze" is.
  defp native_snooze_seconds(capability, :snooze) do
    case Map.get(capability, :snooze_seconds) do
      seconds when is_integer(seconds) and seconds > 0 -> {:ok, seconds}
      _other -> {:error, :missing_snooze_seconds}
    end
  end

  defp native_snooze_seconds(_capability, _action), do: {:ok, nil}

  defp apply_native_record(record, opts) do
    case Repo.transaction(fn ->
           case apply_to_alert(record, opts) do
             {:ok, outcome, notifications, triggered_at} ->
               case ensure_resolution_routed(outcome, opts) do
                 :ok -> {outcome, notifications, triggered_at}
                 {:error, reason} -> Repo.rollback(reason)
               end

             {:error, reason} ->
               Repo.rollback(reason)
           end
         end) do
      {:ok, {outcome, notifications, triggered_at}} ->
        _ = Ash.Notifier.notify(notifications)
        {:ok, emit_acknowledged(outcome, triggered_at, opts)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- application ----------------------------------------------------------

  defp apply_capability(record, opts) do
    # Ash notifiers cannot fire from inside a transaction, and a write that
    # neither returns its notifications nor sends them logs a warning per action.
    # Two per click is a paper cut operators report as a bug, so they are carried
    # out of the transaction and sent once it has committed.
    case Repo.transaction(fn -> consume_and_apply(record, opts) end) do
      {:ok, {outcome, notifications, triggered_at}} ->
        _ = Ash.Notifier.notify(notifications)
        # Emitted AFTER the commit. A rollback would otherwise report an
        # acknowledgement that never happened, which is worse than none at all -
        # it drags the acknowledgement-latency distribution toward zero with
        # samples for actions nobody took.
        {:ok, emit_acknowledged(outcome, triggered_at, opts)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp consume_and_apply(record, opts) do
    case ActionToken.consume(record, Keyword.put(opts, :return_notifications?, true)) do
      # Lost a concurrent race: the other presentation is the one that acted, and
      # this one is a replay by another name.
      {:error, :already_consumed} ->
        {replayed(record), [], nil}

      {:error, reason} ->
        Repo.rollback(reason)

      {:ok, consumed, notifications} ->
        case apply_to_alert(consumed, opts) do
          {:ok, outcome, more, triggered_at} ->
            case ensure_resolution_routed(outcome, opts) do
              :ok -> {outcome, notifications ++ more, triggered_at}
              {:error, reason} -> Repo.rollback(reason)
            end

          {:error, reason} ->
            Repo.rollback(reason)
        end
    end
  end

  # Keep the durable routing request in the same database transaction as the
  # alert transition and acknowledgement. A provider retry that observes an
  # already-resolved alert deliberately does not enqueue again.
  defp ensure_resolution_routed(
         %Outcome{action: :resolve, status: :applied, alert_id: alert_id},
         opts
       ) do
    enqueue = Keyword.get(opts, :enqueue_routing, &RoutingWorker.enqueue/2)

    case enqueue.(alert_id, :resolve) do
      :ok -> :ok
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, {:routing_enqueue_failed, reason}}
      other -> {:error, {:routing_enqueue_failed, other}}
    end
  end

  defp ensure_resolution_routed(_outcome, _opts), do: :ok

  defp apply_to_alert(record, opts) do
    with {:ok, alert} <- load_alert(record, opts),
         {:ok, disposition} <- disposition(record, alert, opts),
         {:ok, alert, transition_notifications} <- transition(record, alert, disposition, opts),
         {:ok, acknowledgement, audit_notifications} <-
           record_acknowledgement(record, disposition, opts) do
      outcome = %Outcome{
        status: disposition.status,
        action: record.action,
        alert_id: record.alert_id,
        delivery_id: record.delivery_id,
        alert_status: Map.get(alert, :status),
        snooze_until: disposition.snooze_until,
        acknowledgement_id: Map.get(acknowledgement, :id),
        consumed_at: record.consumed_at
      }

      # Carried out rather than re-read: the alert is already loaded here, and
      # MTTR is measured from its fire time.
      {:ok, outcome, transition_notifications ++ audit_notifications,
       Map.get(alert, :triggered_at)}
    end
  end

  defp load_alert(record, opts) do
    case Alert.get_by_id(record.alert_id, actor: Keyword.fetch!(opts, :actor)) do
      {:ok, nil} -> {:error, :alert_not_found}
      {:ok, alert} -> {:ok, alert}
      {:error, reason} -> {:error, reason}
    end
  end

  # Decides what the capability does against the alert as it stands now, without
  # writing anything. `:already_applied` is what keeps a fan-out double-click
  # from hitting a state machine that has no transition for it.
  defp disposition(%{action: :acknowledge}, alert, _opts) do
    cond do
      alert.status in @acknowledged_statuses -> {:ok, settled(:already_applied)}
      alert.status in @resolved_statuses -> {:error, {:alert_not_actionable, alert.status}}
      alert.status == :suppressed -> {:error, {:alert_not_actionable, alert.status}}
      true -> {:ok, settled(:applied)}
    end
  end

  defp disposition(%{action: :resolve}, alert, _opts) do
    if alert.status in @resolved_statuses do
      {:ok, settled(:already_applied)}
    else
      {:ok, settled(:applied)}
    end
  end

  defp disposition(%{action: :snooze} = record, alert, opts) do
    if alert.status in @snoozable_statuses do
      {:ok, %{status: :applied, snooze_until: snooze_until(record, opts)}}
    else
      {:error, {:alert_not_actionable, alert.status}}
    end
  end

  defp settled(status), do: %{status: status, snooze_until: nil}

  defp snooze_until(record, opts) do
    DateTime.add(now(opts), record.snooze_seconds, :second)
  end

  defp transition(_record, alert, %{status: :already_applied}, _opts), do: {:ok, alert, []}

  defp transition(record, alert, disposition, opts) do
    actor = Keyword.fetch!(opts, :actor)

    alert
    |> Ash.Changeset.for_update(record.action, alert_params(record, disposition, opts),
      actor: actor
    )
    |> Ash.update(return_notifications?: true)
  end

  defp alert_params(%{action: :acknowledge} = record, _disposition, opts) do
    %{acknowledged_by: principal(opts, record), note: Keyword.get(opts, :note)}
  end

  defp alert_params(%{action: :resolve} = record, _disposition, opts) do
    %{resolved_by: principal(opts, record), resolution_note: Keyword.get(opts, :note)}
  end

  defp alert_params(%{action: :snooze}, disposition, opts) do
    %{snooze_until: disposition.snooze_until, note: Keyword.get(opts, :note)}
  end

  defp record_acknowledgement(record, disposition, opts) do
    actor = Keyword.fetch!(opts, :actor)

    NotificationAcknowledgement
    |> Ash.Changeset.for_create(
      :record,
      %{
        delivery_id: record.delivery_id,
        alert_id: record.alert_id,
        action: record.action,
        actor_kind: :external_principal,
        external_principal: principal(opts, record),
        note: Keyword.get(opts, :note),
        snooze_until: disposition.snooze_until,
        source: source(opts),
        received_at: now(opts)
      },
      actor: actor
    )
    |> Ash.create(return_notifications?: true)
  end

  # --- outcomes -------------------------------------------------------------

  defp replayed(record) do
    %Outcome{
      status: :replayed,
      action: record.action,
      alert_id: record.alert_id,
      delivery_id: record.delivery_id,
      consumed_at: Map.get(record, :consumed_at)
    }
  end

  # --- telemetry ------------------------------------------------------------

  # Ids and classifications only. The note an operator typed is deliberately NOT
  # here: it is free text on an incident and telemetry metadata reaches label
  # sets, logs, and traces without further review.
  #
  # Returns the outcome so the caller can pipe through it.
  defp emit_acknowledged(%Outcome{} = outcome, triggered_at, opts) do
    received_at = now(opts)

    Telemetry.acknowledged(%{
      alert_id: outcome.alert_id,
      delivery_id: outcome.delivery_id,
      action: outcome.action,
      # Either ingress of the one acknowledgement mechanism: a signed action link
      # presented by an external principal, or a provider's verified interactive
      # component (`:callback`). The UI and API paths write their own audit rows.
      source: source(opts),
      actor_kind: :external_principal,
      status: outcome.status,
      ack_latency_ms: ack_latency_ms(outcome, received_at, opts),
      resolution_latency_ms: resolution_latency_ms(outcome, triggered_at, received_at)
    })

    outcome
  end

  # Only the FIRST accepted acknowledgement is a latency sample. A replayed or
  # already-applied redemption is still counted - `status` is a tag, and a
  # fan-out of double-clicks is worth seeing - but it contributes no latency:
  # every later presentation of the same link would add a larger sample for one
  # incident and drag the distribution to the right.
  defp ack_latency_ms(%Outcome{status: :applied, delivery_id: delivery_id}, received_at, opts) do
    Telemetry.latency_ms(first_sent_at(delivery_id, opts), received_at)
  end

  defp ack_latency_ms(_outcome, _received_at, _opts), do: nil

  # MTTR is the fire-time-to-resolve interval, so only a resolve contributes one.
  # An acknowledge is measured by `ack_latency_ms` and counting it here would
  # report every acknowledged incident as repaired.
  defp resolution_latency_ms(%Outcome{action: :resolve, status: :applied}, triggered_at, now) do
    Telemetry.latency_ms(triggered_at, now)
  end

  defp resolution_latency_ms(_outcome, _triggered_at, _now), do: nil

  # The delivery that carried the link is the one whose `:sent` instant starts
  # the acknowledgement clock. A read failure yields no measurement rather than a
  # wrong one - a redemption must never fail because telemetry could not be
  # measured.
  defp first_sent_at(delivery_id, opts) when is_binary(delivery_id) do
    case NotificationDelivery.get_by_id(delivery_id, actor: Keyword.fetch!(opts, :actor)) do
      {:ok, %{state: :sent, finished_at: %DateTime{} = finished_at}} -> finished_at
      _other -> nil
    end
  rescue
    _error -> nil
  end

  defp first_sent_at(_delivery_id, _opts), do: nil

  # --- helpers --------------------------------------------------------------

  defp principal(opts, record) do
    case Keyword.get(opts, :external_principal) do
      value when is_binary(value) and value != "" -> value
      _other -> default_principal(record)
    end
  end

  defp default_principal(%{delivery_id: delivery_id}) when is_binary(delivery_id),
    do: "action_link:" <> delivery_id

  defp default_principal(_record), do: "action_link"

  # A native ingress should always name its provider identity explicitly, so a
  # missing `:external_principal` there is a caller bug rather than something to
  # paper over with a plausible-looking default.
  defp source(opts) do
    case Keyword.get(opts, :source) do
      :callback -> :callback
      _other -> :action_link
    end
  end

  defp now(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now -> now
      _other -> DateTime.utc_now()
    end
  end

  defp actor(opts) do
    Keyword.get(opts, :actor) || SystemActor.system(:notification_action_link)
  end
end
