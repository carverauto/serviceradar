defmodule ServiceRadar.Notifications.Validations.RepeatIntervalFloor do
  @moduledoc """
  Enforces the cadence precedence fixed by design D6: the rule is the floor.

  Two knobs now govern how often one incident may page. `StatefulAlertRule`
  owns `renotify_seconds` and, per the observability signals spec, already owns
  cooldown and renotify semantics for the incident identity. A notification
  escalation policy's `repeat_interval_seconds` may therefore only make repeats
  LESS frequent, never more. A policy configured below the floor is rejected at
  save time with an actionable message rather than silently clamped, because a
  silent clamp means the policy no longer says what its author read.

  A policy is not bound to one rule, so the rule that will govern any given
  alert is unknown at save time. The floor checked here is the STRICTEST floor
  the deployment can present: the maximum `renotify_seconds` across all enabled
  stateful alert rules. A policy that clears that bar cannot violate the
  precedence for any rule currently enabled.

  The dispatcher re-checks per alert against the rule that actually fired,
  which is what covers the two cases this check cannot: a rule enabled or
  lowered after the policy was saved, and an alert created by a path that
  bypasses the stateful engine entirely.

  When no enabled rule exists, or the rule table cannot be read, there is no
  floor to enforce and the save proceeds; the per-alert re-check remains.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.StatefulAlertRule

  @impl true
  def validate(changeset, _opts, _context) do
    repeat_count = Ash.Changeset.get_attribute(changeset, :repeat_count) || 0
    interval = Ash.Changeset.get_attribute(changeset, :repeat_interval_seconds)

    if is_integer(repeat_count) and repeat_count > 0 and is_integer(interval) do
      compare_to_floor(interval)
    else
      :ok
    end
  end

  # Reading the rule floor is Elixir-side work that yields a decision, not an
  # attribute, so the check runs here and reports its result directly. That
  # keeps the enclosing update atomic instead of requiring
  # `require_atomic? false`.
  @impl true
  def atomic(changeset, opts, context) do
    case validate(changeset, opts, context) do
      :ok -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp compare_to_floor(interval) do
    case rule_floor() do
      nil ->
        :ok

      floor when interval >= floor ->
        :ok

      floor ->
        {:error,
         field: :repeat_interval_seconds,
         message:
           "must be at least #{floor} seconds; the stateful alert rule renotify_seconds is " <>
             "the floor and a policy may only make repeats less frequent"}
    end
  end

  defp rule_floor do
    actor = SystemActor.system(:notification_escalation_policy_cadence)

    StatefulAlertRule
    |> Ash.Query.for_read(:active)
    |> Ash.Query.select([:renotify_seconds])
    |> Ash.read(actor: actor)
    |> case do
      {:ok, rules} -> strictest_renotify(rules)
      {:error, _reason} -> nil
    end
  end

  defp strictest_renotify(rules) do
    rules
    |> Enum.map(& &1.renotify_seconds)
    |> Enum.filter(&(is_integer(&1) and &1 > 0))
    |> case do
      [] -> nil
      values -> Enum.max(values)
    end
  end
end
