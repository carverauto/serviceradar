defmodule ServiceRadarWebNG.AlertActions do
  @moduledoc """
  Operator-facing alert acknowledgement, snooze, and resolve.

  This module is the ONLY place the web layer is allowed to move an alert
  through its lifecycle. It does not reimplement any of the engine: it calls
  the existing `ServiceRadar.Monitoring.Alert` actions (`:acknowledge`,
  `:snooze`, `:unsnooze`, `:resolve`) and writes the matching
  `ServiceRadar.Notifications.NotificationAcknowledgement` audit row inside one
  transaction, so an alert can never transition without the row that says who
  moved it.

  ## Authorization

  Every mutating entry point re-derives the caller's authority with
  `ServiceRadarWebNG.RBAC.authorize_current/2` against
  `observability.alerts.manage`. That helper deliberately ignores the
  permissions cached on the socket's scope and reloads them from persistence,
  because a LiveView process outlives a role change. A hidden button is not
  authorization, so the check lives here rather than only in the template, and
  the LiveView calls it again per event.

  `observability.alerts.manage` is catalogued as "Acknowledge and resolve
  alerts" and is the sole gate. Notifications do not mint a second key for the
  same authority.

  ## Snooze is not a state

  "Snoozed" is derived - `status in [:pending, :escalated] and snooze_until >
  now()` - and `Alert.:snooze` leaves `status` untouched. `snoozed?/2` is that
  derivation, and it is the only definition the UI may use.

  ## No atoms from user input

  Durations and action names arrive as strings from the browser. They are
  mapped through the explicit whitelists below. Nothing here calls
  `String.to_atom/1` or `String.to_existing_atom/1`.
  """

  use Boundary,
    top_level?: true,
    deps: [ServiceRadarWebNG.RBAC],
    exports: :all

  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Notifications.NotificationAcknowledgement
  alias ServiceRadar.Notifications.NotificationDelivery
  alias ServiceRadar.Notifications.RoutingWorker
  alias ServiceRadarWebNG.RBAC

  require Ash.Query
  require Logger

  @permission "observability.alerts.manage"
  @deliveries_permission "notifications.deliveries.view"
  @channels_permission "notifications.channels.view"

  # Bounds the fan-out of one bulk submission. The list surface renders a
  # bounded page, so a larger selection can only come from a crafted payload.
  @bulk_limit 50

  # Bounded delivery history rendered inline on the alert page. The full log is
  # a separate, paginated surface.
  @delivery_limit 50

  @snooze_options [
    %{value: "15m", label: "15 minutes", seconds: 900},
    %{value: "1h", label: "1 hour", seconds: 3_600},
    %{value: "4h", label: "4 hours", seconds: 14_400},
    %{value: "24h", label: "24 hours", seconds: 86_400}
  ]

  @default_snooze_value "1h"
  @custom_snooze_value "custom"
  @min_custom_snooze_minutes 5
  @max_custom_snooze_minutes 10_080

  @actionable_statuses [:pending, :escalated]

  @doc "The single RBAC key gating every control in this module."
  def permission, do: @permission

  @doc "RBAC key required to read the delivery history of an alert."
  def deliveries_permission, do: @deliveries_permission

  @doc "RBAC key required to resolve delivery rows to channel names."
  def channels_permission, do: @channels_permission

  @doc "Maximum number of alerts one bulk submission may carry."
  def bulk_limit, do: @bulk_limit

  @doc "Enumerated snooze durations offered by the UI."
  def snooze_options, do: @snooze_options

  def default_snooze_value, do: @default_snooze_value
  def custom_snooze_value, do: @custom_snooze_value
  def min_custom_snooze_minutes, do: @min_custom_snooze_minutes
  def max_custom_snooze_minutes, do: @max_custom_snooze_minutes

  @doc """
  Maps submitted duration parameters onto a bounded integer number of seconds.

  Accepts one of the enumerated `snooze_options/0` values, or the literal
  `"custom"` paired with `"custom_minutes"` bounded to
  #{@min_custom_snooze_minutes}..#{@max_custom_snooze_minutes} minutes. Any
  other input is `:error`; no atom is created from it.
  """
  @spec snooze_seconds(map()) :: {:ok, pos_integer()} | :error
  def snooze_seconds(params) when is_map(params) do
    case Map.get(params, "duration") do
      @custom_snooze_value -> custom_snooze_seconds(Map.get(params, "custom_minutes"))
      value when is_binary(value) -> enumerated_snooze_seconds(value)
      _other -> :error
    end
  end

  def snooze_seconds(_params), do: :error

  defp enumerated_snooze_seconds(value) do
    case Enum.find(@snooze_options, &(&1.value == value)) do
      %{seconds: seconds} -> {:ok, seconds}
      nil -> :error
    end
  end

  defp custom_snooze_seconds(raw) when is_binary(raw) do
    case Integer.parse(String.trim(raw)) do
      {minutes, ""} when minutes >= @min_custom_snooze_minutes and minutes <= @max_custom_snooze_minutes ->
        {:ok, minutes * 60}

      _other ->
        :error
    end
  end

  defp custom_snooze_seconds(_raw), do: :error

  @doc """
  True when the alert is currently deferred.

  Snooze is NOT a state-machine state. This is the derived condition the engine
  itself uses, and it is deliberately the only definition in the web layer.
  """
  @spec snoozed?(map() | nil, DateTime.t()) :: boolean()
  def snoozed?(alert, now \\ DateTime.utc_now())

  def snoozed?(%{status: status, snooze_until: %DateTime{} = snooze_until}, %DateTime{} = now)
      when status in @actionable_statuses do
    DateTime.after?(snooze_until, now)
  end

  def snoozed?(_alert, _now), do: false

  @doc """
  What the alert's current state permits, and the explanation when it does not.

  Returns a map keyed by `:acknowledge`, `:snooze`, `:unsnooze`, and `:resolve`,
  each `%{enabled?: boolean, reason: nil | String.t()}`. A disabled control
  renders disabled with its reason rather than failing after the click.
  """
  @spec action_states(map() | nil, DateTime.t()) :: map()
  def action_states(alert, now \\ DateTime.utc_now())

  def action_states(%{status: status} = alert, %DateTime{} = now) do
    %{
      acknowledge: acknowledge_state(status),
      snooze: snooze_state(status),
      unsnooze: unsnooze_state(alert, now),
      resolve: resolve_state(status)
    }
  end

  def action_states(_alert, _now) do
    unavailable = %{enabled?: false, reason: "Alert is unavailable"}

    %{
      acknowledge: unavailable,
      snooze: unavailable,
      unsnooze: unavailable,
      resolve: unavailable
    }
  end

  # `transition :acknowledge, from: [:pending, :escalated]`. `:escalated` is the
  # important source state: an escalated alert is exactly the one a human most
  # needs to take ownership of.
  defp acknowledge_state(:pending), do: allowed()
  defp acknowledge_state(:escalated), do: allowed()
  defp acknowledge_state(:acknowledged), do: refused("Already acknowledged")
  defp acknowledge_state(:resolved), do: refused("Alert is already resolved")
  defp acknowledge_state(:suppressed), do: refused("Alert is suppressed")
  defp acknowledge_state(_status), do: refused("Alert state does not allow acknowledgement")

  defp snooze_state(status) when status in @actionable_statuses, do: allowed()

  defp snooze_state(:acknowledged), do: refused("Acknowledged alerts are already withheld from dispatch")

  defp snooze_state(:resolved), do: refused("Alert is resolved")
  defp snooze_state(:suppressed), do: refused("Alert is suppressed")
  defp snooze_state(_status), do: refused("Alert state does not allow snoozing")

  defp unsnooze_state(alert, now) do
    if snoozed?(alert, now) do
      allowed()
    else
      refused("Alert is not snoozed")
    end
  end

  # `transition :resolve, from: [:pending, :acknowledged, :escalated]`.
  defp resolve_state(status) when status in [:pending, :acknowledged, :escalated], do: allowed()
  defp resolve_state(:resolved), do: refused("Already resolved")
  defp resolve_state(:suppressed), do: refused("Suppressed alerts must be reopened before resolving")
  defp resolve_state(_status), do: refused("Alert state does not allow resolving")

  defp allowed, do: %{enabled?: true, reason: nil}
  defp refused(reason), do: %{enabled?: false, reason: reason}

  @doc """
  Loads one alert for the acknowledgement controls.

  Reads through Ash so the caller's own read policy applies. Returns
  `{:error, :not_found}` for an alert the caller may not see, which is the same
  answer it gets for an alert that does not exist.
  """
  @spec load(map(), String.t()) :: {:ok, Alert.t()} | {:error, :not_found}
  def load(scope, alert_id) when is_binary(alert_id) do
    Alert
    |> Ash.Query.for_read(:by_id, %{id: alert_id}, scope: scope)
    |> Ash.read_one(scope: scope)
    |> case do
      {:ok, %{} = alert} -> {:ok, alert}
      _other -> {:error, :not_found}
    end
  rescue
    _error -> {:error, :not_found}
  end

  def load(_scope, _alert_id), do: {:error, :not_found}

  @doc """
  Acknowledges one alert and records who did it.

  Sets `acknowledged_by_user_id` to the acting platform user and keeps the
  free-text `acknowledged_by` populated so the row reads the same way whether
  the actor was a platform user or an external principal that redeemed an
  emailed action link.
  """
  @spec acknowledge(map(), String.t(), keyword()) :: {:ok, Alert.t()} | {:error, term()}
  def acknowledge(scope, alert_id, opts \\ []) do
    with {:ok, scope} <- authorize(scope) do
      apply_action(scope, :acknowledge, alert_id, opts)
    end
  end

  @doc """
  Defers dispatch for one alert until `now + seconds`.

  `seconds` must already have come through `snooze_seconds/1`.
  """
  @spec snooze(map(), String.t(), pos_integer(), keyword()) :: {:ok, Alert.t()} | {:error, term()}
  def snooze(scope, alert_id, seconds, opts \\ []) when is_integer(seconds) and seconds > 0 do
    with {:ok, scope} <- authorize(scope) do
      apply_action(scope, :snooze, alert_id, Keyword.put(opts, :seconds, seconds))
    end
  end

  @doc "Clears an active snooze so dispatch resumes immediately."
  @spec unsnooze(map(), String.t(), keyword()) :: {:ok, Alert.t()} | {:error, term()}
  def unsnooze(scope, alert_id, opts \\ []) do
    with {:ok, scope} <- authorize(scope) do
      apply_action(scope, :unsnooze, alert_id, opts)
    end
  end

  @doc "Resolves one alert."
  @spec resolve(map(), String.t(), keyword()) :: {:ok, Alert.t()} | {:error, term()}
  def resolve(scope, alert_id, opts \\ []) do
    with {:ok, scope} <- authorize(scope) do
      apply_action(scope, :resolve, alert_id, opts)
    end
  end

  @doc """
  Applies `:acknowledge` or `:snooze` to a bounded selection of alerts.

  Every id is re-authorized and re-loaded server-side; `visible_ids` is the set
  the server itself rendered for the caller's active filter, so a client-supplied
  id outside it is refused without disclosing whether it exists.

  Returns `%{succeeded: [id], failed: [{id, reason}]}`. A partial failure is
  never reported as success.
  """
  @spec bulk(map(), :acknowledge | :snooze, [String.t()], keyword()) ::
          {:ok, %{succeeded: [String.t()], failed: [{String.t(), String.t()}]}}
          | {:error, term()}
  def bulk(scope, action, ids, opts \\ [])

  def bulk(scope, action, ids, opts) when action in [:acknowledge, :snooze] and is_list(ids) do
    ids = ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    cond do
      ids == [] ->
        {:error, :empty_selection}

      length(ids) > @bulk_limit ->
        {:error, {:selection_too_large, @bulk_limit}}

      true ->
        with {:ok, scope} <- authorize(scope) do
          visible = Keyword.get(opts, :visible_ids)
          {:ok, run_bulk(scope, action, ids, visible, opts)}
        end
    end
  end

  def bulk(_scope, _action, _ids, _opts), do: {:error, :not_authorized}

  defp run_bulk(scope, action, ids, visible, opts) do
    ids
    |> Enum.reduce(%{succeeded: [], failed: []}, fn id, acc ->
      case bulk_one(scope, action, id, visible, opts) do
        {:ok, _alert} ->
          %{acc | succeeded: [id | acc.succeeded]}

        {:error, reason} ->
          %{acc | failed: [{id, describe_error(reason)} | acc.failed]}
      end
    end)
    |> then(fn acc ->
      %{succeeded: Enum.reverse(acc.succeeded), failed: Enum.reverse(acc.failed)}
    end)
  end

  # A client-supplied id is not evidence of visibility. `visible_ids` is what
  # the server rendered for this viewer's active filter; anything else is
  # refused with a reason that does not say whether the row exists.
  defp bulk_one(scope, action, id, visible, opts) do
    if is_list(visible) and id not in visible do
      {:error, :not_in_current_results}
    else
      apply_action(scope, action, id, opts)
    end
  end

  defp authorize(scope) do
    case RBAC.authorize_current(scope, [@permission]) do
      {:ok, scope} -> {:ok, scope}
      _denied -> {:error, :not_authorized}
    end
  end

  # --- engine calls ---------------------------------------------------------

  defp apply_action(scope, action, alert_id, opts) do
    with {:ok, alert} <- load(scope, alert_id),
         :ok <- check_transition(action, alert, opts) do
      transact(scope, action, alert, opts)
    end
  end

  defp check_transition(action, alert, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    case Map.get(action_states(alert, now), action) do
      %{enabled?: true} -> :ok
      %{reason: reason} -> {:error, {:not_allowed, reason}}
      _other -> {:error, {:not_allowed, "Action is unavailable"}}
    end
  end

  defp transact(scope, action, alert, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    note = normalize_note(Keyword.get(opts, :note))
    snooze_until = snooze_until(action, now, opts)

    # `Ash.transact/3` returns `{:ok, <whatever the function returned>}` and
    # rolls back when the function returns `{:error, _}`. The success branch
    # therefore returns the record itself, not an `{:ok, record}` tuple.
    result =
      Ash.transact([Alert, NotificationAcknowledgement], fn ->
        with {:ok, updated} <-
               alert
               |> Ash.Changeset.for_update(action, alert_params(action, scope, note, snooze_until), scope: scope)
               |> Ash.update(scope: scope),
             {:ok, _acknowledgement} <-
               record_acknowledgement(scope, action, updated, note, snooze_until, now),
             :ok <- ensure_resolution_routed(action, updated, opts) do
          updated
        end
      end)

    case result do
      {:ok, %{} = alert} -> {:ok, alert}
      {:error, reason} -> {:error, {:engine, reason}}
      other -> {:error, {:engine, other}}
    end
  end

  defp snooze_until(:snooze, now, opts) do
    DateTime.add(now, Keyword.fetch!(opts, :seconds), :second)
  end

  defp snooze_until(_action, _now, _opts), do: nil

  # Oban persists through the same Repo transaction Ash opened above. Keeping
  # the enqueue inside it makes the resolve transition, audit row, and durable
  # close-out request one atomic unit.
  defp ensure_resolution_routed(:resolve, %{id: alert_id}, opts) when is_binary(alert_id) do
    enqueue = Keyword.get(opts, :enqueue_routing, &RoutingWorker.enqueue/2)

    case enqueue.(alert_id, :resolve) do
      :ok -> :ok
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, {:routing_enqueue_failed, reason}}
      other -> {:error, {:routing_enqueue_failed, other}}
    end
  end

  defp ensure_resolution_routed(_action, _alert, _opts), do: :ok

  defp alert_params(:acknowledge, scope, note, _snooze_until) do
    %{
      acknowledged_by: principal(scope),
      acknowledged_by_user_id: actor_id(scope),
      note: note
    }
  end

  defp alert_params(:snooze, _scope, note, snooze_until) do
    %{snooze_until: snooze_until, note: note}
  end

  defp alert_params(:unsnooze, _scope, _note, _snooze_until), do: %{}

  defp alert_params(:resolve, scope, note, _snooze_until) do
    %{resolved_by: principal(scope), resolution_note: note}
  end

  # `:unsnooze` is a correction of an operator's own deferral rather than an
  # inbound action on the incident, and the acknowledgement enum has no member
  # for it, so it is not audited as one.
  defp record_acknowledgement(_scope, :unsnooze, _alert, _note, _snooze_until, _now), do: {:ok, nil}

  defp record_acknowledgement(scope, action, alert, note, snooze_until, now) do
    NotificationAcknowledgement
    |> Ash.Changeset.for_create(
      :record,
      %{
        alert_id: alert.id,
        action: action,
        actor_kind: :platform_user,
        actor_user_id: actor_id(scope),
        note: note,
        snooze_until: snooze_until,
        source: :ui,
        received_at: now
      },
      scope: scope
    )
    |> Ash.create(scope: scope)
  end

  defp normalize_note(note) when is_binary(note) do
    case String.trim(note) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, 1_000)
    end
  end

  defp normalize_note(_note), do: nil

  defp actor_id(%{user: %{id: id}}) when is_binary(id), do: id
  defp actor_id(_scope), do: nil

  # The free-text principal recorded on the alert. `User.email` is an
  # `Ash.CiString`, not a binary, so it has to be flattened rather than
  # guarded on `is_binary/1` - guarding alone silently falls through to the
  # opaque user id and the acknowledgement reads as anonymous.
  defp principal(%{user: user}) when is_map(user) do
    case email_string(Map.get(user, :email)) do
      email when is_binary(email) and email != "" -> email
      _blank -> user_reference(Map.get(user, :id))
    end
  end

  defp principal(_scope), do: "unknown"

  defp email_string(nil), do: nil
  defp email_string(email) when is_binary(email), do: email
  defp email_string(email), do: to_string(email)

  defp user_reference(id) when is_binary(id), do: "user:" <> id
  defp user_reference(_id), do: "unknown"

  # --- delivery history -----------------------------------------------------

  @doc """
  The notification history for one alert, suppressed rows included.

  This is the "why was I not paged?" answer at the point the operator is
  already looking at the alert. Test rows are returned so they can be labelled,
  and `delivery_counts/1` excludes them from every count.

  `:channel` is loaded only when the caller holds
  `notifications.channels.view`; the channel read is a strict permission check,
  so loading it unconditionally would turn a missing permission into a failed
  history panel instead of an unnamed channel.
  """
  @spec deliveries(map(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def deliveries(scope, alert_id, opts \\ []) when is_binary(alert_id) do
    limit = Keyword.get(opts, :limit, @delivery_limit)

    query =
      NotificationDelivery
      |> Ash.Query.for_read(:for_alert, %{alert_id: alert_id}, scope: scope)
      |> Ash.Query.limit(limit)
      |> maybe_load_channel(scope)

    case Ash.read(query, scope: scope) do
      {:ok, deliveries} -> {:ok, deliveries}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp maybe_load_channel(query, scope) do
    if RBAC.can?(scope, @channels_permission) do
      Ash.Query.load(query, :channel)
    else
      query
    end
  end

  @doc """
  Counts an alert's deliveries for display.

  Test deliveries are excluded from every count: an un-flagged test row
  corrupts exactly the counters an operator uses to judge notification volume.
  """
  @spec delivery_counts([map()]) :: %{
          total: non_neg_integer(),
          sent: non_neg_integer(),
          suppressed: non_neg_integer(),
          pending: non_neg_integer(),
          failed: non_neg_integer(),
          test: non_neg_integer()
        }
  def delivery_counts(deliveries) when is_list(deliveries) do
    {tests, real} = Enum.split_with(deliveries, &test_delivery?/1)

    %{
      total: length(real),
      sent: count_state(real, [:sent]),
      suppressed: count_state(real, [:suppressed, :skipped]),
      pending: count_state(real, [:pending, :dispatching]),
      failed: count_state(real, [:failed, :expired, :cancelled]),
      test: length(tests)
    }
  end

  def delivery_counts(_deliveries), do: delivery_counts([])

  @doc "True for a delivery written by a test send rather than by an alert."
  def test_delivery?(%{is_test: true}), do: true
  def test_delivery?(_delivery), do: false

  defp count_state(deliveries, states) do
    Enum.count(deliveries, fn delivery -> Map.get(delivery, :state) in states end)
  end

  @doc "Human label for a `NotificationDelivery` state."
  def delivery_state_label(:pending), do: "Pending"
  def delivery_state_label(:dispatching), do: "Dispatching"
  def delivery_state_label(:sent), do: "Sent"
  def delivery_state_label(:failed), do: "Failed"
  def delivery_state_label(:expired), do: "Expired"
  def delivery_state_label(:cancelled), do: "Cancelled"
  def delivery_state_label(:suppressed), do: "Suppressed"
  def delivery_state_label(:skipped), do: "Skipped"
  def delivery_state_label(_state), do: "Unknown"

  @doc "Badge variant for a `NotificationDelivery` state. Never the only signal."
  def delivery_state_variant(:sent), do: "success"
  def delivery_state_variant(state) when state in [:pending, :dispatching], do: "info"
  def delivery_state_variant(state) when state in [:suppressed, :skipped], do: "warning"
  def delivery_state_variant(state) when state in [:failed, :expired, :cancelled], do: "error"
  def delivery_state_variant(_state), do: "ghost"

  @doc """
  Human explanation for a recorded `suppression_reason`.

  Every reason the platform records has an entry, including
  `:no_matching_route` - the reason that makes an unrouted alert visible at all.
  """
  def suppression_reason_label(:device_out_of_service), do: "Device marked out of service"
  def suppression_reason_label(:silence), do: "Matched an active silence"
  def suppression_reason_label(:schedule), do: "Outside the route schedule"
  def suppression_reason_label(:snoozed), do: "Alert was snoozed"
  def suppression_reason_label(:throttled), do: "Throttled by the route"
  def suppression_reason_label(:acknowledged), do: "Alert was already acknowledged"
  def suppression_reason_label(:channel_disabled), do: "Channel is disabled"
  def suppression_reason_label(:dependency), do: "Suppressed by a dependency"
  def suppression_reason_label(:no_matching_route), do: "No enabled route matched this alert"
  def suppression_reason_label(nil), do: nil
  def suppression_reason_label(_reason), do: "Suppressed"

  @doc """
  Path into the notification Delivery Log filtered to one alert.

  Built as a plain string rather than a verified route: the notifications
  settings surface is a sibling change and this module must not depend on its
  router entry existing yet.
  """
  def delivery_log_path(alert_id) when is_binary(alert_id) and alert_id != "" do
    "/settings/notifications/deliveries?" <> URI.encode_query(%{"alert_id" => alert_id})
  end

  def delivery_log_path(_alert_id), do: "/settings/notifications/deliveries"

  # --- error rendering ------------------------------------------------------

  @doc """
  Operator-facing sentence for a failure returned by this module.

  Never discloses whether a record the caller may not see exists.
  """
  def describe_error(:not_authorized), do: "You are not authorized to manage alerts"
  def describe_error(:not_found), do: "Alert is not available"
  def describe_error(:not_in_current_results), do: "Not in the current result set"
  def describe_error(:empty_selection), do: "Select at least one alert"

  def describe_error({:selection_too_large, limit}), do: "Select at most #{limit} alerts at a time"

  def describe_error(:invalid_duration), do: "Choose a valid snooze duration"
  def describe_error({:not_allowed, reason}) when is_binary(reason), do: reason
  def describe_error({:engine, reason}), do: engine_message(reason)
  def describe_error(_reason), do: "The action could not be completed"

  defp engine_message(%Ash.Error.Forbidden{}), do: "You are not authorized to manage alerts"

  defp engine_message(%Ash.Error.Invalid{errors: errors}) when is_list(errors) do
    errors
    |> Enum.map(&error_message/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "The action was rejected"
      messages -> Enum.join(Enum.uniq(messages), "; ")
    end
  end

  defp engine_message(reason) do
    Logger.debug(fn -> "alert action failed: #{inspect(reason)}" end)
    "The action could not be completed"
  end

  defp error_message(%{message: message}) when is_binary(message) and message != "", do: message
  defp error_message(_error), do: nil
end
