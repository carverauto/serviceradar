defmodule ServiceRadarWebNGWeb.Settings.NotificationsLive.Data do
  @moduledoc """
  Every read the notification settings surface performs, in one module.

  Three properties are deliberate.

  **Everything is scoped and bounded.** Each read runs with the viewer's scope,
  so the Ash policies on the notification resources - not this module - decide
  what comes back, and each read carries an explicit limit. The Delivery Log in
  particular is unbounded in the database and must never be loaded whole into
  socket assigns; the limit here is what makes the stream honest.

  **Nothing is read in a disconnected mount.** The LiveView calls these only once
  `connected?/1` is true; this module simply never runs on its own.

  **A failed read degrades to empty, not to a crash.** A settings page that
  500s because one of five tabs could not read is worse than a page that renders
  the other four and says so, and the caller distinguishes the two by the
  `{:ok, _}` / `{:error, _}` return.
  """

  alias ServiceRadar.Notifications.NotificationChannel
  alias ServiceRadar.Notifications.NotificationDelivery
  alias ServiceRadar.Notifications.NotificationEscalationPolicy
  alias ServiceRadar.Notifications.NotificationProvider
  alias ServiceRadar.Notifications.NotificationProvider.Version, as: ProviderVersion
  alias ServiceRadar.Notifications.NotificationRoute
  alias ServiceRadar.Notifications.NotificationSchedule
  alias ServiceRadar.Notifications.NotificationSilence
  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.DeliveryFilters
  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.Presentation

  require Ash.Query

  @channel_limit 200
  @route_limit 200
  @policy_limit 200
  @silence_limit 200
  @provider_limit 200
  @provider_version_limit 50
  @delivery_limit 100
  @suppression_sample 500

  @doc "Channels with their provider, newest name order, bounded."
  @spec list_channels(term()) :: [struct()]
  def list_channels(scope) do
    NotificationChannel
    |> Ash.Query.for_read(:read)
    |> Ash.Query.load([:provider])
    |> Ash.Query.sort(name: :asc)
    |> Ash.Query.limit(@channel_limit)
    |> read(scope)
  end

  @doc """
  Channels keyed by id as a string.

  Used by the escalation editor and the edge-route safety warning, which need to
  resolve a step's channel ids without a query per row.
  """
  @spec channel_index([struct()]) :: %{optional(String.t()) => struct()}
  def channel_index(channels) when is_list(channels) do
    Map.new(channels, &{to_string(&1.id), &1})
  end

  @doc "Providers, first-party catalog and uploads alike."
  @spec list_providers(term()) :: [struct()]
  def list_providers(scope) do
    NotificationProvider
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort(display_name: :asc)
    |> Ash.Query.limit(@provider_limit)
    |> read(scope)
  end

  @doc """
  The audit rows a declarative provider's definition history is folded from.

  Read newest-first and bounded, then folded chronologically by
  `ServiceRadarWebNGWeb.Settings.NotificationsLive.ProviderVersions`. Newest-first
  is what makes the bound useful: a provider with more than
  #{@provider_version_limit} audited changes shows its most recent versions
  rather than its first ones, which are the versions a rollback would target.

  Note that the AshPaperTrail version resource carries no authorizer of its own,
  so unlike every other read here the row filtering is NOT done by an Ash policy:
  the caller's `notifications.providers.manage` check in
  `ServiceRadarWebNGWeb.Settings.NotificationsLive.Access` is what gates this. The
  content is provider configuration rather than credential material - a
  definition that named a credential outside `secrets.*` would not have validated
  - but the gate is the LiveView's, and a future caller must not assume the
  resource will refuse on its own.
  """
  @spec list_provider_versions(term(), term()) :: [struct()]
  def list_provider_versions(scope, provider_id) do
    ProviderVersion
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(version_source_id == ^provider_id)
    |> Ash.Query.sort(version_inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(@provider_version_limit)
    |> read(scope)
  end

  @doc """
  Routes in the order the routing engine evaluates them.

  Ascending `priority` with `id` as the stable tiebreak, which is the order
  `ServiceRadar.Notifications.Router.evaluation_order/1` applies. Showing any
  other order would show an operator an evaluation sequence the engine does not
  use, which is precisely the confusion `continue` already causes.
  """
  @spec list_routes(term()) :: [struct()]
  def list_routes(scope) do
    NotificationRoute
    |> Ash.Query.for_read(:read)
    |> Ash.Query.load([:escalation_policy, :schedule])
    |> Ash.Query.sort(priority: :asc, id: :asc)
    |> Ash.Query.limit(@route_limit)
    |> read(scope)
  end

  @doc "Escalation policies with their ordered steps and each step's channel set."
  @spec list_policies(term()) :: [struct()]
  def list_policies(scope) do
    steps_query =
      ServiceRadar.Notifications.NotificationEscalationStep
      |> Ash.Query.for_read(:read)
      |> Ash.Query.load([:step_channels])
      |> Ash.Query.sort(step_number: :asc)

    NotificationEscalationPolicy
    |> Ash.Query.for_read(:read)
    |> Ash.Query.load(steps: steps_query)
    |> Ash.Query.sort(name: :asc)
    |> Ash.Query.limit(@policy_limit)
    |> read(scope)
  end

  @doc "Schedules, for the route editor's schedule binding."
  @spec list_schedules(term()) :: [struct()]
  def list_schedules(scope) do
    NotificationSchedule
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort(name: :asc)
    |> Ash.Query.limit(@policy_limit)
    |> read(scope)
  end

  @doc """
  Silences, live ones first.

  Cancelled and expired rows stay listed: cancelling a silence is an auditable
  act and removing the row from the list would delete the audit trail from the
  only surface that shows it.
  """
  @spec list_silences(term()) :: [struct()]
  def list_silences(scope) do
    NotificationSilence
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort(starts_at: :desc)
    |> Ash.Query.limit(@silence_limit)
    |> read(scope)
  end

  @doc """
  One bounded page of the Delivery Log, in every state.

  Suppressed and skipped rows are included by construction: no state filter is
  applied unless the operator asked for one.
  """
  @spec list_deliveries(term(), map(), DateTime.t()) :: [struct()]
  def list_deliveries(scope, filters, now) do
    NotificationDelivery
    |> Ash.Query.for_read(:read)
    |> apply_delivery_filters(filters, now)
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(@delivery_limit)
    |> read(scope)
  end

  @doc "The page size the Delivery Log stream is bounded to."
  @spec delivery_limit() :: pos_integer()
  def delivery_limit, do: @delivery_limit

  @doc """
  The failover chain a delivery belongs to: the row it failed over from, and the
  rows that failed over from it.

  `originating_delivery_id` is the back-reference the engine writes, so the chain
  is walkable from either end rather than looking like unrelated attempts.
  """
  @spec failover_chain(term(), struct()) :: %{origin: struct() | nil, successors: [struct()]}
  def failover_chain(scope, delivery) do
    %{
      origin: fetch_delivery(scope, delivery.originating_delivery_id),
      successors: successors(scope, delivery.id)
    }
  end

  @doc "One delivery by id, or `nil`."
  @spec fetch_delivery(term(), term()) :: struct() | nil
  def fetch_delivery(_scope, nil), do: nil

  def fetch_delivery(scope, id) do
    NotificationDelivery
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.limit(1)
    |> read(scope)
    |> List.first()
  end

  defp successors(scope, id) do
    NotificationDelivery
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(originating_delivery_id == ^id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(20)
    |> read(scope)
  end

  @doc """
  What is currently being suppressed, by reason, over a bounded recent window.

  Reads a bounded sample of suppressed rows rather than nine count queries, and
  sums `occurrence_count` so a long-lived silence that collapsed a thousand
  identical decisions onto one row is reported as a thousand withheld
  notifications, not as one. The sample bound is returned alongside the tally so
  the UI can say the number is a floor when the window is saturated.
  """
  @spec suppression_summary(term(), DateTime.t() | nil) :: %{
          counts: [{atom(), non_neg_integer()}],
          silences: %{optional(String.t()) => non_neg_integer()},
          sampled: non_neg_integer(),
          saturated?: boolean()
        }
  def suppression_summary(scope, since) do
    rows =
      NotificationDelivery
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(state == :suppressed)
      |> filter_since(since)
      |> Ash.Query.sort(last_evaluated_at: :desc, id: :desc)
      |> Ash.Query.limit(@suppression_sample)
      |> read(scope)

    %{
      counts: tally_reasons(rows),
      silences: tally_silences(rows),
      sampled: length(rows),
      saturated?: length(rows) >= @suppression_sample
    }
  end

  defp tally_reasons(rows) do
    rows
    |> Enum.group_by(& &1.suppression_reason)
    |> Enum.reject(fn {reason, _rows} -> is_nil(reason) end)
    |> Enum.map(fn {reason, group} -> {reason, occurrences(group)} end)
    |> Enum.sort_by(fn {_reason, count} -> -count end)
  end

  # Silence attribution rides in the suppression detail the engine already
  # writes (`result_summary.suppression.detail.silence_id`). Reading it here
  # keeps the count honest without a second attribution column that would have to
  # be kept in step with the suppression evaluator by hand.
  defp tally_silences(rows) do
    rows
    |> Enum.filter(&(&1.suppression_reason == :silence))
    |> Enum.reduce(%{}, fn row, acc ->
      case silence_id(row) do
        nil -> acc
        id -> Map.update(acc, id, occurrence_count(row), &(&1 + occurrence_count(row)))
      end
    end)
  end

  # One reader for the attribution path, shared with the Delivery Log detail
  # pane, so the count and the link can never disagree about which silence a
  # withheld delivery belongs to.
  defp silence_id(row) do
    row |> Map.get(:result_summary) |> Presentation.suppressing_silence_id()
  end

  defp occurrences(rows), do: Enum.reduce(rows, 0, &(occurrence_count(&1) + &2))

  defp occurrence_count(%{occurrence_count: count}) when is_integer(count) and count > 0, do: count
  defp occurrence_count(_row), do: 1

  # --- filters ---------------------------------------------------------------

  defp apply_delivery_filters(query, filters, now) do
    query
    |> filter_since(DeliveryFilters.since(filters, now))
    |> maybe(filters[:alert_id], fn query, value ->
      Ash.Query.filter(query, alert_id == ^value)
    end)
    |> maybe(filters[:channel_id], fn query, value ->
      Ash.Query.filter(query, channel_id == ^value)
    end)
    |> maybe(filters[:route_id], fn query, value ->
      Ash.Query.filter(query, route_id == ^value)
    end)
    |> maybe(filters[:state], fn query, value ->
      Ash.Query.filter(query, state == ^value)
    end)
    |> maybe(filters[:suppression_reason], fn query, value ->
      Ash.Query.filter(query, suppression_reason == ^value)
    end)
    |> maybe(filters[:execution_route], fn query, value ->
      Ash.Query.filter(query, execution_route == ^value)
    end)
    |> maybe(filters[:payload_format], fn query, value ->
      Ash.Query.filter(query, payload_format == ^value)
    end)
    |> maybe(filters[:provider_version], fn query, value ->
      Ash.Query.filter(query, provider_version == ^value)
    end)
    |> maybe(filters[:is_test], fn query, value ->
      Ash.Query.filter(query, is_test == ^value)
    end)
  end

  defp filter_since(query, nil), do: query

  defp filter_since(query, %DateTime{} = since) do
    Ash.Query.filter(query, inserted_at >= ^since)
  end

  defp maybe(query, nil, _fun), do: query
  defp maybe(query, value, fun), do: fun.(query, value)

  # --- read ------------------------------------------------------------------

  defp read(query, scope) do
    case Ash.read(query, scope: scope) do
      {:ok, records} -> records
      {:error, _reason} -> []
    end
  end
end
