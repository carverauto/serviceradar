defmodule ServiceRadar.Observability.ServiceStateRegistry do
  @moduledoc """
  Maintains the current service state registry.
  """

  import Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.EventWriter.StateChangePublisher
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Observability.ServiceState
  alias ServiceRadar.Observability.ServiceStatePubSub
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Repo

  require Logger

  @streaming_plugin_capability "camera_media_stream"
  @streaming_plugin_output "serviceradar.camera_stream.v1"
  @plugin_result_output "serviceradar.plugin_result.v1"

  @spec upsert_from_status(map()) :: :ok
  def upsert_from_status(status) when is_map(status) do
    case upsert_from_status_strict(status) do
      :ok ->
        :ok

      {:error, error} ->
        Logger.warning("Failed to upsert service state: #{inspect(error)}")
        :ok
    end
  end

  def upsert_from_status(_), do: :ok

  @doc """
  Persists a current service state while returning database or side-effect errors.

  The `ServiceState` upsert is timestamp-guarded, so an older observation cannot
  replace a newer current state even when concurrent ingestors race. For equal
  timestamps, unavailable wins over available; otherwise the existing row wins.
  """
  @spec upsert_from_status_strict(map()) :: :ok | {:error, term()}
  def upsert_from_status_strict(status) when is_map(status) do
    do_upsert_from_status_strict(status, false)
  end

  def upsert_from_status_strict(_), do: {:error, :invalid_status}

  @doc false
  @spec upsert_from_status_strict_with_notifications(map()) ::
          {:ok, list(), list()} | {:error, term()}
  def upsert_from_status_strict_with_notifications(status) when is_map(status) do
    do_upsert_from_status_strict(status, true, preserve_gateway?: true)
  end

  def upsert_from_status_strict_with_notifications(_), do: {:error, :invalid_status}

  defp do_upsert_from_status_strict(status, return_notifications?, opts \\ []) do
    actor = SystemActor.system(:service_state_registry)
    attrs = build_attrs_from_status(status, actor, opts)
    previous = previous_service_availability(attrs, actor)

    ServiceState
    |> Ash.Changeset.for_create(:upsert, attrs, actor: actor)
    |> Ash.create(
      domain: ServiceRadar.Observability,
      return_notifications?: return_notifications?
    )
    |> case do
      {:ok, state} ->
        run_state_upsert_side_effects(state, previous, actor)
        :ok

      {:ok, state, notifications} ->
        if upsert_skipped?(state) do
          {:ok, [], []}
        else
          {side_effect_notifications, side_effects} =
            prepare_state_upsert_side_effects(state, previous, actor)

          {:ok, notifications ++ side_effect_notifications, side_effects}
        end

      {:error, error} ->
        {:error, error}

      other ->
        {:error, {:unexpected_service_state_upsert_result, other}}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp run_state_upsert_side_effects(state, previous, actor) do
    if !upsert_skipped?(state) do
      deactivate_shadowed_plugin_states(state, actor)
      ServiceStatePubSub.broadcast_update(state)
      maybe_publish_service_transition(previous, state)
    end
  end

  defp prepare_state_upsert_side_effects(state, previous, actor) do
    {notifications, shadow_states} =
      deactivate_shadowed_plugin_states_with_notifications(state, actor)

    side_effects =
      Enum.map(shadow_states, &{:broadcast_update, &1}) ++
        [{:state_upserted, state, previous}]

    {notifications, side_effects}
  end

  @doc false
  @spec dispatch_deferred_side_effects(list()) :: :ok | {:error, term()}
  def dispatch_deferred_side_effects(side_effects) when is_list(side_effects) do
    Enum.each(side_effects, fn
      {:broadcast_update, state} ->
        ServiceStatePubSub.broadcast_update(state)

      {:state_upserted, state, previous} ->
        ServiceStatePubSub.broadcast_update(state)
        maybe_publish_service_transition(previous, state)
    end)

    :ok
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc """
  Batched equivalent of `upsert_from_status/1` for a list of statuses.

  Builds attrs for each status, dedups by the `:unique_service_identity`
  (agent_id/gateway_id/partition/service_type/service_name) keeping the last
  status per identity, then performs ONE `Ash.bulk_create(:upsert, ...)`. The
  per-state side-effects (`deactivate_shadowed_plugin_states/2`,
  `ServiceStatePubSub.broadcast_update/1`, `maybe_publish_service_transition/2`)
  run per returned record so behavior matches the single-status path.

  Returns `:ok`; failures are logged and never raise (matches the per-status
  path's best-effort contract on the ResultsRouter hot path).
  """
  @spec bulk_upsert_from_statuses([map()]) :: :ok
  def bulk_upsert_from_statuses(statuses) when is_list(statuses) do
    actor = SystemActor.system(:service_state_registry)

    deduped =
      statuses
      |> Enum.filter(&is_map/1)
      |> Enum.map(&build_attrs_from_status(&1, actor))
      |> dedup_attrs_by_identity()

    case deduped do
      [] ->
        :ok

      attrs_list ->
        previous_by_identity = previous_availability_by_identity(attrs_list, actor)

        attrs_list
        |> Ash.bulk_create(ServiceState, :upsert,
          actor: actor,
          domain: ServiceRadar.Observability,
          upsert_identity: :unique_service_identity,
          return_records?: true,
          return_errors?: true,
          stop_on_error?: false
        )
        |> handle_bulk_upsert_result(previous_by_identity, actor)
    end
  rescue
    error ->
      Logger.warning("Bulk service state upsert failed: #{Exception.message(error)}")
      :ok
  end

  def bulk_upsert_from_statuses(_), do: :ok

  # Keep the LAST status per unique identity (most recent observation wins),
  # preserving first-seen order for deterministic side-effect ordering.
  defp dedup_attrs_by_identity(attrs_list) do
    {ordered_keys, by_key} =
      Enum.reduce(attrs_list, {[], %{}}, fn attrs, {keys, acc} ->
        key = identity_key(attrs)
        keys = if Map.has_key?(acc, key), do: keys, else: [key | keys]
        {keys, Map.put(acc, key, attrs)}
      end)

    ordered_keys
    |> Enum.reverse()
    |> Enum.map(&Map.fetch!(by_key, &1))
  end

  defp identity_key(attrs) do
    {attrs.agent_id, attrs.gateway_id, attrs.partition, attrs.service_type, attrs.service_name}
  end

  # Read prior availability for the whole batch, keyed by identity, only when the
  # state-change feed is enabled (mirrors previous_service_availability/2). One
  # read per identity, but only on the feed-enabled path.
  defp previous_availability_by_identity(attrs_list, actor) do
    if StateChangePublisher.enabled?() do
      Map.new(attrs_list, fn attrs ->
        prev =
          case existing_service_state(attrs, actor) do
            %ServiceState{} = state -> %{available: state.available, state: state.state}
            _ -> nil
          end

        {identity_key(attrs), prev}
      end)
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  defp handle_bulk_upsert_result(%Ash.BulkResult{} = result, previous_by_identity, actor) do
    records = result.records || []

    Enum.each(records, fn %ServiceState{} = state ->
      if !upsert_skipped?(state) do
        previous = Map.get(previous_by_identity, identity_key_from_state(state))
        deactivate_shadowed_plugin_states(state, actor)
        ServiceStatePubSub.broadcast_update(state)
        maybe_publish_service_transition(previous, state)
      end
    end)

    case result.errors do
      [] -> :ok
      nil -> :ok
      errors -> Logger.warning("Bulk service state upsert had errors: #{inspect(errors)}")
    end

    :ok
  end

  defp handle_bulk_upsert_result(other, _previous_by_identity, _actor) do
    Logger.warning("Unexpected bulk service state upsert result: #{inspect(other)}")
    :ok
  end

  defp identity_key_from_state(%ServiceState{} = state) do
    {state.agent_id, state.gateway_id, state.partition, state.service_type, state.service_name}
  end

  defp upsert_skipped?(record), do: Ash.Resource.get_metadata(record, :upsert_skipped) == true

  # add-causal-engine (Decision 1): capture prior availability BEFORE the upsert
  # so a transition can be published to signals.state.service_state afterward.
  # Gated behind the feed flag (StateChangePublisher.enabled?/0) so disabled
  # deployments incur no extra read; best-effort (never affects the upsert).
  defp previous_service_availability(attrs, actor) do
    if StateChangePublisher.enabled?() do
      case existing_service_state(attrs, actor) do
        %ServiceState{} = state -> %{available: state.available, state: state.state}
        _ -> nil
      end
    end
  rescue
    _ -> nil
  end

  defp existing_service_state(attrs, actor) do
    ServiceState
    |> filter(
      agent_id == ^Map.fetch!(attrs, :agent_id) and
        partition == ^Map.fetch!(attrs, :partition) and
        service_type == ^Map.fetch!(attrs, :service_type) and
        service_name == ^Map.fetch!(attrs, :service_name)
    )
    |> Ash.read(actor: actor, domain: ServiceRadar.Observability)
    |> case do
      {:ok, states} when is_list(states) ->
        states |> Enum.sort_by(&logical_state_rank/1, :desc) |> List.first()

      _ ->
        nil
    end
  end

  defp maybe_publish_service_transition(previous, %ServiceState{} = state) do
    old_available = previous && Map.get(previous, :available)
    new_available = state.available

    if not is_nil(previous) and old_available != new_available do
      StateChangePublisher.publish_transition(
        "service_state",
        service_state_entity_uid(state),
        field: "available",
        old: old_available,
        new: new_available,
        partition_id: state.partition,
        entity_type: "service",
        extra: %{
          "agent_id" => state.agent_id,
          "gateway_id" => state.gateway_id,
          "service_type" => state.service_type,
          "service_name" => state.service_name
        }
      )
    else
      :ok
    end
  end

  defp maybe_publish_service_transition(_previous, _state), do: :ok

  # Composite service identity (Decision 2): service_state has no device uid, so
  # the engine keys service transitions by this composite and resolves the owning
  # device from agent_id when needed.
  defp service_state_entity_uid(%ServiceState{} = state) do
    "#{state.agent_id}:#{state.service_type}:#{state.service_name}"
  end

  @spec repair_plugin_states_from_history(keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def repair_plugin_states_from_history(opts \\ []) do
    interval = opts |> Keyword.get(:interval, "30 days") |> to_string()
    limit = Keyword.get(opts, :limit, 5_000)

    case Repo.query(latest_plugin_status_sql(), [interval, limit]) do
      {:ok, %{rows: rows}} ->
        Enum.each(rows, fn row -> upsert_from_status(status_from_history_row(row)) end)

        case deactivate_inactive_plugin_state_count() do
          {:ok, inactive_count} -> {:ok, length(rows) + inactive_count}
          {:error, _reason} = error -> error
        end

      {:error, reason} = error ->
        Logger.warning("Plugin service state history repair failed: #{inspect(reason)}")
        error
    end
  rescue
    error ->
      Logger.warning("Plugin service state history repair failed: #{Exception.message(error)}")
      {:error, error}
  end

  @spec upsert_for_assignment(PluginAssignment.t()) :: :ok
  def upsert_for_assignment(%PluginAssignment{} = assignment) do
    actor = SystemActor.system(:service_state_registry)

    with {:ok, package} <- load_package(assignment, actor),
         true <- should_track_assignment_service?(assignment, package),
         {:ok, agent} <- Agent.get_by_uid(assignment.agent_uid, actor: actor) do
      assignment
      |> build_attrs_from_assignment(agent, package)
      |> maybe_upsert_assignment_state(actor)
    else
      false ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to resolve assignment service identity: #{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("Assignment service state upsert failed: #{Exception.message(error)}")
      :ok
  end

  def upsert_for_assignment(_), do: :ok

  @spec reconcile_plugin_assignments(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def reconcile_plugin_assignments(opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:service_state_registry))

    PluginAssignment
    |> filter(enabled == true)
    |> Ash.read(actor: actor, domain: ServiceRadar.Plugins)
    |> case do
      {:ok, assignments} ->
        Enum.each(assignments, &upsert_for_assignment/1)

        case deactivate_inactive_plugin_state_count() do
          {:ok, inactive_count} -> {:ok, length(assignments) + inactive_count}
          {:error, _reason} = error -> error
        end

      {:error, reason} = error ->
        Logger.warning("Failed to reconcile plugin assignment service states: #{inspect(reason)}")
        error
    end
  rescue
    error ->
      Logger.warning(
        "Plugin assignment service state reconciliation failed: #{Exception.message(error)}"
      )

      {:error, error}
  end

  @spec deactivate_for_assignment(PluginAssignment.t()) :: :ok
  def deactivate_for_assignment(%PluginAssignment{} = assignment) do
    actor = SystemActor.system(:service_state_registry)

    with {:ok, package} <- load_package(assignment, actor),
         {:ok, agent} <- Agent.get_by_uid(assignment.agent_uid, actor: actor) do
      identity = identity_from_agent(agent, package.name, "plugin", assignment.agent_uid)
      deactivate_by_identity(identity, actor)
    else
      {:error, reason} ->
        Logger.warning("Failed to resolve service identity for assignment: #{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("Service state deactivate failed: #{Exception.message(error)}")
      :ok
  end

  def deactivate_for_assignment(_), do: :ok

  @spec deactivate_for_package(PluginPackage.t()) :: :ok
  def deactivate_for_package(%PluginPackage{} = package) do
    actor = SystemActor.system(:service_state_registry)

    PluginAssignment
    |> filter(plugin_package_id == ^package.id)
    |> Ash.read(actor: actor, domain: ServiceRadar.Plugins)
    |> case do
      {:ok, assignments} ->
        Enum.each(assignments, fn assignment ->
          deactivate_assignment_with_package(assignment, package, actor)
        end)

      {:error, reason} ->
        Logger.warning("Failed to load plugin assignments: #{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("Service state package deactivate failed: #{Exception.message(error)}")
      :ok
  end

  def deactivate_for_package(_), do: :ok

  defp deactivate_assignment_with_package(%PluginAssignment{} = assignment, package, actor) do
    case Agent.get_by_uid(assignment.agent_uid, actor: actor) do
      {:ok, agent} ->
        identity = identity_from_agent(agent, package.name, "plugin", assignment.agent_uid)
        deactivate_by_identity(identity, actor)

      {:error, reason} ->
        Logger.warning("Failed to resolve agent for assignment: #{inspect(reason)}")
        :ok
    end
  end

  defp deactivate_by_identity(identity, actor) when is_map(identity) do
    ServiceState
    |> Ash.Query.for_read(:by_identity, identity, actor: actor)
    |> Ash.read_one(actor: actor, domain: ServiceRadar.Observability)
    |> case do
      {:ok, nil} ->
        :ok

      {:ok, state} ->
        state
        |> Ash.Changeset.for_update(:deactivate, %{}, actor: actor)
        |> Ash.update(domain: ServiceRadar.Observability)
        |> case do
          {:ok, updated} ->
            ServiceStatePubSub.broadcast_update(updated)
            :ok

          {:error, error} ->
            Logger.warning("Failed to deactivate service state: #{inspect(error)}")
            :ok
        end

      {:error, error} ->
        Logger.warning("Failed to load service state: #{inspect(error)}")
        :ok
    end
  end

  defp deactivate_shadowed_plugin_states(
         %ServiceState{service_type: "plugin"} = current_state,
         actor
       ) do
    ServiceState
    |> filter(
      id != ^current_state.id and
        agent_id == ^current_state.agent_id and
        partition == ^current_state.partition and
        service_type == ^current_state.service_type and
        service_name == ^current_state.service_name and
        state == "active"
    )
    |> Ash.read(actor: actor, domain: ServiceRadar.Observability)
    |> case do
      {:ok, states} ->
        Enum.each(states, &deactivate_shadow_state(&1, actor))

      {:error, error} ->
        Logger.warning("Failed to load shadowed plugin states: #{inspect(error)}")
    end
  end

  defp deactivate_shadowed_plugin_states(_state, _actor), do: :ok

  defp deactivate_shadowed_plugin_states_with_notifications(
         %ServiceState{service_type: "plugin"} = current_state,
         actor
       ) do
    ServiceState
    |> filter(
      id != ^current_state.id and
        agent_id == ^current_state.agent_id and
        partition == ^current_state.partition and
        service_type == ^current_state.service_type and
        service_name == ^current_state.service_name and
        state == "active"
    )
    |> Ash.read(actor: actor, domain: ServiceRadar.Observability)
    |> case do
      {:ok, states} ->
        Enum.reduce(states, {[], []}, fn state, {notifications, updated_states} ->
          case deactivate_shadow_state_with_notifications(state, actor) do
            {:ok, updated, state_notifications} ->
              {notifications ++ state_notifications, updated_states ++ [updated]}

            :error ->
              {notifications, updated_states}
          end
        end)

      {:error, error} ->
        Logger.warning("Failed to load shadowed plugin states: #{inspect(error)}")
        {[], []}
    end
  end

  defp deactivate_shadowed_plugin_states_with_notifications(_state, _actor), do: {[], []}

  defp deactivate_shadow_state(%ServiceState{} = state, actor) do
    state
    |> Ash.Changeset.for_update(:deactivate, %{}, actor: actor)
    |> Ash.update(domain: ServiceRadar.Observability)
    |> case do
      {:ok, updated} ->
        ServiceStatePubSub.broadcast_update(updated)

      {:error, error} ->
        Logger.warning("Failed to deactivate shadowed plugin state: #{inspect(error)}")
    end
  end

  defp deactivate_shadow_state_with_notifications(%ServiceState{} = state, actor) do
    state
    |> Ash.Changeset.for_update(:deactivate, %{}, actor: actor)
    |> Ash.update(domain: ServiceRadar.Observability, return_notifications?: true)
    |> case do
      {:ok, updated, notifications} ->
        {:ok, updated, notifications}

      {:error, error} ->
        Logger.warning("Failed to deactivate shadowed plugin state: #{inspect(error)}")
        :error
    end
  end

  defp deactivate_stale_active_plugin_shadows do
    case Repo.query(deactivate_stale_active_plugin_shadows_sql(), []) do
      {:ok, %{rows: [[count]]}} ->
        {:ok, normalize_count(count)}

      {:ok, _result} ->
        {:ok, 0}

      {:error, reason} = error ->
        Logger.warning("Failed to deactivate stale plugin service shadows: #{inspect(reason)}")
        error
    end
  end

  defp deactivate_orphaned_active_plugin_states do
    params = [
      @plugin_result_output,
      @streaming_plugin_output,
      @streaming_plugin_capability
    ]

    case Repo.query(deactivate_orphaned_active_plugin_states_sql(), params) do
      {:ok, %{rows: [[count]]}} ->
        {:ok, normalize_count(count)}

      {:ok, _result} ->
        {:ok, 0}

      {:error, reason} = error ->
        Logger.warning("Failed to deactivate orphaned plugin service states: #{inspect(reason)}")
        error
    end
  end

  defp deactivate_inactive_plugin_state_count do
    # These bulk cleanup passes intentionally skip PubSub. They reconcile reload-time
    # Postgres state and avoid broadcasting one message per stale row.
    with {:ok, shadow_count} <- deactivate_stale_active_plugin_shadows(),
         {:ok, orphan_count} <- deactivate_orphaned_active_plugin_states() do
      {:ok, shadow_count + orphan_count}
    end
  end

  defp deactivate_stale_active_plugin_shadows_sql do
    """
    WITH ranked AS (
      SELECT
        id,
        row_number() OVER (
          PARTITION BY agent_id, partition, service_type, service_name
          ORDER BY last_observed_at DESC, updated_at DESC, inserted_at DESC, id DESC
        ) AS row_number
      FROM platform.service_state
      WHERE service_type = 'plugin' AND state = 'active'
    ),
    deactivated AS (
      UPDATE platform.service_state AS service_state
      SET state = 'inactive',
          updated_at = (now() AT TIME ZONE 'utc')
      FROM ranked
      WHERE service_state.id = ranked.id
        AND ranked.row_number > 1
      RETURNING service_state.id
    )
    SELECT count(*)::bigint FROM deactivated
    """
  end

  defp deactivate_orphaned_active_plugin_states_sql do
    """
    WITH deactivated AS (
      UPDATE platform.service_state AS service_state
      SET state = 'inactive',
          updated_at = (now() AT TIME ZONE 'utc')
      WHERE service_state.service_type = 'plugin'
        AND service_state.state = 'active'
        AND NOT EXISTS (
          SELECT 1
          FROM platform.plugin_assignments AS assignment
          JOIN platform.plugin_packages AS package
            ON package.id = assignment.plugin_package_id
          WHERE assignment.enabled = true
            AND assignment.agent_uid = service_state.agent_id
            AND (
              package.name = service_state.service_name
              OR (
                service_state.details IS JSON
                AND (
                  service_state.details::jsonb #>> '{labels,plugin_id}' = package.plugin_id
                  OR service_state.details::jsonb ->> 'plugin_id' = package.plugin_id
                )
              )
            )
            AND (
              package.outputs IN ($1, $2)
              OR $3 = ANY(package.approved_capabilities)
              OR (
                coalesce(array_length(package.approved_capabilities, 1), 0) = 0
                AND package.manifest->'capabilities' ? $3
              )
            )
        )
      RETURNING service_state.id
    )
    SELECT count(*)::bigint FROM deactivated
    """
  end

  defp normalize_count(count) when is_integer(count), do: count

  defp normalize_count(count) when is_binary(count) do
    case Integer.parse(count) do
      {value, _rest} -> value
      :error -> 0
    end
  end

  defp normalize_count(_count), do: 0

  defp build_attrs_from_status(status, actor, opts \\ []) do
    message = normalize_message(fetch(status, :message))
    agent_id = normalize_string(fetch(status, :agent_id), "unknown")
    service_type = normalize_string(fetch(status, :service_type), "unknown")

    gateway_id =
      if Keyword.get(opts, :preserve_gateway?, false) do
        normalize_string(fetch(status, :gateway_id), "unknown")
      else
        canonical_gateway_id(status, agent_id, actor)
      end

    %{
      agent_id: agent_id,
      gateway_id: gateway_id,
      partition: resolve_partition(status),
      service_type: service_type,
      service_name: normalize_string(fetch(status, :service_name), "unknown"),
      available: normalize_available(fetch(status, :available)),
      message: normalize_message_value(message),
      details: normalize_details(fetch(status, :message)),
      last_observed_at: resolve_observed_at(status),
      state: "active"
    }
  end

  defp normalize_string(value, fallback) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: fallback, else: trimmed
  end

  defp normalize_string(_value, fallback), do: fallback

  defp resolve_partition(status) do
    fetch(status, :partition) || fetch(status, :partition_id) || "default"
  end

  defp normalize_available(true), do: true
  defp normalize_available(false), do: false
  defp normalize_available(1), do: true
  defp normalize_available(0), do: false
  defp normalize_available(_), do: false

  defp normalize_message(message) when is_binary(message) do
    case Jason.decode(message) do
      {:ok, decoded} when is_map(decoded) ->
        decoded["summary"] || decoded["message"] || decoded["status"] || slice_message(message)

      {:ok, decoded} when is_list(decoded) ->
        normalize_message(decoded) || slice_message(message)

      _ ->
        slice_message(message)
    end
  end

  defp normalize_message(message) when is_map(message) do
    summary =
      Map.get(message, "summary") ||
        Map.get(message, :summary) ||
        Map.get(message, "message") ||
        Map.get(message, :message) ||
        Map.get(message, "status") ||
        Map.get(message, :status)

    if is_binary(summary) do
      slice_message(summary)
    else
      slice_message(FieldParser.encode_json(message))
    end
  end

  defp normalize_message(message) when is_list(message) do
    message
    |> Enum.find_value(&message_summary/1)
    |> case do
      summary when is_binary(summary) -> slice_message(summary)
      _ -> slice_message(FieldParser.encode_json(message))
    end
  end

  defp normalize_message(_), do: nil

  defp message_summary(message) when is_map(message) do
    Map.get(message, "summary") ||
      Map.get(message, :summary) ||
      Map.get(message, "message") ||
      Map.get(message, :message) ||
      Map.get(message, "status") ||
      Map.get(message, :status)
  end

  defp message_summary(_message), do: nil

  defp slice_message(nil), do: nil
  defp slice_message(message) when is_binary(message), do: String.slice(message, 0, 2048)

  defp normalize_message_value(value) when is_binary(value) or is_nil(value), do: value

  defp normalize_message_value(value) do
    FieldParser.encode_json(value) || inspect(value)
  end

  defp normalize_details(message) when is_binary(message) do
    case Jason.decode(message) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) ->
        FieldParser.encode_json(decoded)

      _ ->
        nil
    end
  end

  defp normalize_details(message) when is_map(message) or is_list(message) do
    FieldParser.encode_json(message)
  end

  defp normalize_details(_message), do: nil

  defp resolve_observed_at(status) do
    raw =
      fetch(status, :agent_timestamp) || fetch(status, :timestamp) || fetch(status, :observed_at)

    case raw do
      %DateTime{} = timestamp ->
        DateTime.truncate(timestamp, :microsecond)

      %NaiveDateTime{} = timestamp ->
        timestamp
        |> DateTime.from_naive!("Etc/UTC")
        |> DateTime.truncate(:microsecond)

      raw ->
        (%DateTime{} = timestamp) = FieldParser.parse_timestamp(raw)
        DateTime.truncate(timestamp, :microsecond)
    end
  rescue
    _ -> DateTime.truncate(DateTime.utc_now(), :microsecond)
  end

  defp fetch(status, key) when is_map(status) do
    Map.get(status, key) || Map.get(status, Atom.to_string(key))
  end

  defp should_track_assignment_service?(
         %PluginAssignment{} = assignment,
         %PluginPackage{} = package
       ) do
    assignment.enabled == true and
      (streaming_plugin_package?(package) or plugin_result_package?(package))
  end

  defp streaming_plugin_package?(%PluginPackage{} = package) do
    package.outputs == @streaming_plugin_output or
      Enum.member?(effective_capabilities(package), @streaming_plugin_capability)
  end

  defp plugin_result_package?(%PluginPackage{} = package) do
    package.outputs == @plugin_result_output
  end

  defp effective_capabilities(%PluginPackage{} = package) do
    approved = package.approved_capabilities || []

    if approved == [] do
      manifest = package.manifest || %{}
      Map.get(manifest, "capabilities") || Map.get(manifest, :capabilities) || []
    else
      approved
    end
  end

  defp build_attrs_from_assignment(
         %PluginAssignment{} = assignment,
         agent,
         %PluginPackage{} = package
       ) do
    plugin_type = assignment_plugin_type(package)
    {available, message} = assignment_initial_state(plugin_type)

    agent
    |> identity_from_agent(package.name, "plugin", assignment.agent_uid)
    |> Map.merge(%{
      available: available,
      message: message,
      details:
        FieldParser.encode_json(%{
          "assignment_id" => to_string(assignment.id),
          "plugin_id" => package.plugin_id,
          "package_id" => package.id,
          "plugin_type" => plugin_type,
          "package_version" => package.version
        }),
      last_observed_at: DateTime.truncate(DateTime.utc_now(), :microsecond),
      state: "active"
    })
  end

  defp maybe_upsert_assignment_state(attrs, actor) do
    case load_existing_logical_state(attrs, actor) do
      {:ok, %ServiceState{state: "active"} = state} ->
        if assignment_placeholder_state?(state) do
          upsert_service_state(attrs, actor)
        else
          :ok
        end

      _ ->
        upsert_service_state(attrs, actor)
    end
  end

  defp load_existing_logical_state(attrs, actor) do
    ServiceState
    |> filter(
      agent_id == ^Map.fetch!(attrs, :agent_id) and
        partition == ^Map.fetch!(attrs, :partition) and
        service_type == ^Map.fetch!(attrs, :service_type) and
        service_name == ^Map.fetch!(attrs, :service_name) and
        state == "active"
    )
    |> Ash.read(actor: actor, domain: ServiceRadar.Observability)
    |> case do
      {:ok, states} ->
        {:ok, Enum.max_by(states, &logical_state_rank/1, fn -> nil end)}

      error ->
        error
    end
  end

  defp assignment_placeholder_state?(%ServiceState{} = state) do
    placeholder_message?(state.message)
  end

  defp placeholder_message?("plugin assignment pending result"), do: true
  defp placeholder_message?("streaming plugin ready"), do: true
  defp placeholder_message?(_), do: false

  defp logical_state_rank(%ServiceState{} = state) do
    observed_at =
      case state.last_observed_at do
        %DateTime{} = dt -> DateTime.to_unix(dt, :nanosecond)
        _ -> 0
      end

    real_result_rank = if placeholder_message?(state.message), do: 0, else: 1
    {real_result_rank, observed_at}
  end

  defp assignment_plugin_type(%PluginPackage{} = package) do
    cond do
      streaming_plugin_package?(package) -> "streaming"
      plugin_result_package?(package) -> "scheduled"
      true -> "plugin"
    end
  end

  defp assignment_initial_state("streaming"), do: {true, "streaming plugin ready"}
  defp assignment_initial_state(_), do: {false, "plugin assignment pending result"}

  defp upsert_service_state(attrs, actor) when is_map(attrs) do
    ServiceState
    |> Ash.Changeset.for_create(:upsert, attrs, actor: actor)
    |> Ash.create(domain: ServiceRadar.Observability)
    |> case do
      {:ok, state} ->
        if !upsert_skipped?(state) do
          deactivate_shadowed_plugin_states(state, actor)
          ServiceStatePubSub.broadcast_update(state)
        end

        :ok

      {:error, error} ->
        Logger.warning("Failed to upsert service state: #{inspect(error)}")
        :ok

      other ->
        Logger.warning("Unexpected service state upsert result: #{inspect(other)}")
        :ok
    end
  end

  defp load_package(%PluginAssignment{} = assignment, actor) do
    PluginPackage
    |> Ash.Query.filter(id == ^assignment.plugin_package_id)
    |> Ash.read_one(actor: actor, domain: ServiceRadar.Plugins)
  end

  defp identity_from_agent(agent, service_name, service_type, agent_id) do
    %{
      agent_id: agent_id,
      gateway_id: normalize_string(agent.gateway_id, "unknown"),
      partition: resolve_partition_from_agent(agent),
      service_type: service_type,
      service_name: normalize_string(service_name, "unknown")
    }
  end

  defp resolve_partition_from_agent(agent) do
    metadata = agent.metadata || %{}

    metadata["partition_id"] || metadata["partition"] || "default"
  end

  defp canonical_gateway_id(status, agent_id, actor) do
    raw_gateway_id = normalize_string(fetch(status, :gateway_id), "unknown")

    if normalize_string(fetch(status, :service_type), "unknown") == "plugin" do
      agent_gateway_id(agent_id, actor) || raw_gateway_id
    else
      raw_gateway_id
    end
  end

  defp agent_gateway_id(agent_id, actor)
       when is_binary(agent_id) and agent_id not in ["", "unknown"] do
    case Agent.get_by_uid(agent_id, actor: actor) do
      {:ok, agent} -> normalize_string(agent.gateway_id, nil)
      _ -> nil
    end
  end

  defp agent_gateway_id(_agent_id, _actor), do: nil

  defp latest_plugin_status_sql do
    """
    SELECT DISTINCT ON (agent_id, COALESCE(partition, 'default'), service_type, service_name)
      agent_id,
      gateway_id,
      COALESCE(partition, 'default') AS partition,
      service_type,
      service_name,
      available,
      message,
      details,
      timestamp
    FROM platform.service_status
    WHERE service_type = 'plugin'
      AND timestamp >= (now() - ($1::text)::interval)
    ORDER BY agent_id, COALESCE(partition, 'default'), service_type, service_name, timestamp DESC
    LIMIT $2
    """
  end

  defp status_from_history_row([
         agent_id,
         gateway_id,
         partition,
         service_type,
         service_name,
         available,
         message,
         details,
         timestamp
       ]) do
    %{
      agent_id: agent_id,
      gateway_id: gateway_id,
      partition: partition,
      service_type: service_type,
      service_name: service_name,
      available: available,
      message: details || message,
      timestamp: timestamp
    }
  end
end
