defmodule ServiceRadar.Notifications.CallbackWorker do
  @moduledoc """
  Applies a verified provider interaction, off the request path (task 4.3.0c).

  ## Why this is a job rather than inline work

  Every provider imposes a response deadline - Slack's is 3 seconds, and missing
  it shows the operator an error on a click that in fact succeeded.
  `ActionRedemption.apply_native/2` opens a transaction that loads the alert,
  transitions it, writes an audit row, and sends notifications. That is fast on a
  healthy database and is exactly the work that is slow on an unhealthy one,
  which is when an on-call engineer is clicking the button.

  So the controller verifies, enqueues, and answers; this applies. The verified
  capability is what crosses the boundary, never the raw request: by the time a
  job exists the signature has already been checked, and re-checking it here
  would need the raw body and the secret in `oban_jobs` in plaintext.

  ## Idempotency

  Args are string-keyed and carry no structs, per the Oban rules in AGENTS.md.
  The job is idempotent because the work it performs is: `apply_native/2`
  disposes an alert that is already in the target state as `:already_applied`,
  which is the same guard that absorbs a double-clicked action link. A retry, a
  provider re-delivery, and two operators clicking at once all converge on one
  transition and an audit row per receipt.

  `max_attempts: 3` rather than 1: unlike a dispatch, there is no destination to
  annoy by retrying, and the failure this protects against is a transient
  database error losing an acknowledgement an operator believes they made.
  """

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 3

  alias ServiceRadar.Notifications.ActionRedemption
  alias ServiceRadar.Notifications.CallbackBinding

  require Logger

  # How long two deliveries of one provider event are treated as the same event.
  # Comfortably wider than any provider's retry span - PagerDuty's is ~20
  # minutes - so a redelivery lands inside the window rather than just outside
  # it, which is the failure that makes a dedupe window look like it works.
  @dedupe_window_seconds 3600

  @actions %{
    "acknowledge" => :acknowledge,
    "snooze" => :snooze,
    "resolve" => :resolve
  }

  @doc """
  Builds the job for a verified interaction.

  Takes the already-parsed capability so a caller cannot enqueue an unverified
  request by accident - there is no arm of this that accepts a raw body.
  """
  @spec build(map()) :: Oban.Job.changeset()
  def build(%{action: action, alert_id: alert_id, delivery_id: delivery_id} = capability) do
    args =
      %{
        "action" => to_string(action),
        "alert_id" => alert_id,
        "delivery_id" => delivery_id,
        "snooze_seconds" => Map.get(capability, :snooze_seconds),
        "external_principal" => Map.get(capability, :external_principal),
        "provider_key" => to_string(Map.get(capability, :provider_key, "unknown")),
        "event_id" => Map.get(capability, :event_id),
        "app_id" => Map.get(capability, :app_id),
        "action_id" => Map.get(capability, :action_id)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    new(args, dedupe_opts(args))
  end

  # Uniqueness is applied ONLY when the provider gave us an event id, and that
  # condition is the whole point. Slack's block_actions payload carries no event
  # id, so a blanket `unique` on these keys would compare two distinct clicks on
  # a missing value and collapse them into one - silently dropping the second
  # operator's acknowledgement. A provider without an event id is left to the
  # `:already_applied` disposition, which absorbs a retry without conflating two
  # real interactions.
  defp dedupe_opts(%{"event_id" => event_id}) when is_binary(event_id) and event_id != "" do
    [
      unique: [
        keys: [:provider_key, :event_id],
        period: @dedupe_window_seconds,
        states: [:available, :scheduled, :executing, :retryable, :completed]
      ]
    ]
  end

  defp dedupe_opts(_args), do: []

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, action} <- action(args),
         {:ok, alert_id} <- required(args, "alert_id") do
      capability =
        maybe_put(
          %{
            action: action,
            alert_id: alert_id,
            delivery_id: Map.get(args, "delivery_id"),
            provider_key: Map.get(args, "provider_key"),
            app_id: Map.get(args, "app_id"),
            action_id: Map.get(args, "action_id")
          },
          :snooze_seconds,
          Map.get(args, "snooze_seconds")
        )

      apply_capability(capability, args)
    else
      {:error, reason} ->
        # A malformed job is a bug in the enqueuer, not a transient fault, so it
        # is discarded rather than retried three times to the same conclusion.
        Logger.error("notification callback job is malformed reason=#{inspect(reason)}")
        {:discard, reason}
    end
  end

  defp apply_capability(capability, args) do
    opts = [source: :callback, external_principal: Map.get(args, "external_principal")]

    case CallbackBinding.bind(capability) do
      {:ok, bound_capability} ->
        apply_bound_capability(bound_capability, args, opts)

      {:error, reason} ->
        if CallbackBinding.rejection?(reason) do
          Logger.warning(
            "notification callback binding refused provider=#{Map.get(args, "provider_key")} " <>
              "action=#{Map.get(args, "action")} reason=#{inspect(reason)}"
          )

          {:discard, reason}
        else
          {:error, reason}
        end
    end
  end

  defp apply_bound_capability(capability, args, opts) do
    case ActionRedemption.apply_native(capability, opts) do
      {:ok, outcome} ->
        Logger.info(
          "notification callback applied provider=#{Map.get(args, "provider_key")} " <>
            "action=#{outcome.action} status=#{outcome.status}"
        )

        :ok

      # The alert is gone, or is in a state this action cannot act on. Retrying
      # cannot change either, and a job that retries to the same refusal three
      # times buries the one that could still succeed.
      {:error, :alert_not_found} = error ->
        {:discard, error}

      {:error, {:alert_not_actionable, _status}} = error ->
        {:discard, error}

      {:error, :missing_snooze_seconds} = error ->
        {:discard, error}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp action(args) do
    case Map.fetch(args, "action") do
      {:ok, value} ->
        # A closed map, never String.to_atom/1 on a job argument.
        case Map.fetch(@actions, value) do
          {:ok, action} -> {:ok, action}
          :error -> {:error, {:unknown_action, value}}
        end

      :error ->
        {:error, :missing_action}
    end
  end

  defp required(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _absent -> {:error, {:missing_argument, key}}
    end
  end

  defp maybe_put(map, _key, nil), do: map

  defp maybe_put(map, key, value) when is_integer(value) and value > 0,
    do: Map.put(map, key, value)

  defp maybe_put(map, _key, _value), do: map
end
