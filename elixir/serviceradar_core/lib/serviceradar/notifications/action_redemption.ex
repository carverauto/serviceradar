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
  """
  @spec redeem(term(), keyword()) :: {:ok, Outcome.t()} | {:error, failure()}
  def redeem(token, opts \\ []) do
    actor = actor(opts)
    opts = Keyword.put(opts, :actor, actor)

    case ActionToken.verify(token, opts) do
      {:ok, :already_consumed, record} -> {:ok, replayed(record)}
      {:ok, :active, record} -> apply_capability(record, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  # --- application ----------------------------------------------------------

  defp apply_capability(record, opts) do
    # Ash notifiers cannot fire from inside a transaction, and a write that
    # neither returns its notifications nor sends them logs a warning per action.
    # Two per click is a paper cut operators report as a bug, so they are carried
    # out of the transaction and sent once it has committed.
    case Repo.transaction(fn -> consume_and_apply(record, opts) end) do
      {:ok, {outcome, notifications}} ->
        _ = Ash.Notifier.notify(notifications)
        {:ok, outcome}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp consume_and_apply(record, opts) do
    case ActionToken.consume(record, Keyword.put(opts, :return_notifications?, true)) do
      # Lost a concurrent race: the other presentation is the one that acted, and
      # this one is a replay by another name.
      {:error, :already_consumed} ->
        {replayed(record), []}

      {:error, reason} ->
        Repo.rollback(reason)

      {:ok, consumed, notifications} ->
        case apply_to_alert(consumed, opts) do
          {:ok, outcome, more} -> {outcome, notifications ++ more}
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

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

      {:ok, outcome, transition_notifications ++ audit_notifications}
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
        source: :action_link,
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
