defmodule ServiceRadar.Observability.ServiceStateRegistry.StatusIngestor do
  @moduledoc false

  import Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.StateChangePublisher
  alias ServiceRadar.Observability.ServiceState
  alias ServiceRadar.Observability.ServiceStatePubSub
  alias ServiceRadar.Observability.ServiceStateRegistry.PluginState
  alias ServiceRadar.Observability.ServiceStateRegistry.SideEffects
  alias ServiceRadar.Observability.ServiceStateRegistry.StatusNormalizer
  alias ServiceRadar.Repo

  require Logger

  @doc false
  @spec upsert(map()) :: :ok
  def upsert(status) when is_map(status) do
    case upsert_strict(status) do
      :ok ->
        :ok

      {:error, error} ->
        Logger.warning("Failed to upsert service state: #{inspect(error)}")
        :ok
    end
  end

  def upsert(_), do: :ok

  @doc false
  @spec upsert_strict(map()) :: :ok | {:error, term()}
  def upsert_strict(status) when is_map(status) do
    case Repo.transaction(fn ->
           with :ok <- maybe_acquire_plugin_state_lock(status),
                {:ok, notifications, side_effects} <- upsert_with_notifications(status) do
             {notifications, side_effects}
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, {notifications, side_effects}} ->
        _ = Ash.Notifier.notify(notifications)
        SideEffects.dispatch(side_effects)

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_service_state_transaction_result, other}}
    end
  end

  def upsert_strict(_), do: {:error, :invalid_status}

  @doc false
  @spec upsert_strict_with_notifications(map()) ::
          {:ok, list(), list()} | {:error, term()}
  def upsert_strict_with_notifications(status) when is_map(status) do
    upsert_with_notifications(status, preserve_gateway?: true)
  end

  def upsert_strict_with_notifications(_), do: {:error, :invalid_status}

  @doc false
  def upsert_with_notifications(status, opts \\ []) do
    actor = SystemActor.system(:service_state_registry)
    attrs = StatusNormalizer.attrs_from_status(status, actor, opts)
    previous = previous_service_availability(attrs, actor)

    ServiceState
    |> Ash.Changeset.for_create(:upsert, attrs, actor: actor)
    |> Ash.create(
      domain: ServiceRadar.Observability,
      return_notifications?: true
    )
    |> case do
      {:ok, state, notifications} ->
        upserted? = not upsert_skipped?(state)
        notifications = if upserted?, do: notifications, else: []

        with {:ok, side_effect_notifications, side_effects} <-
               PluginState.prepare_upsert_side_effects(state, previous, actor, upserted?) do
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

  @doc false
  @spec bulk_upsert([map()]) :: :ok
  def bulk_upsert(statuses) when is_list(statuses) do
    actor = SystemActor.system(:service_state_registry)

    deduped =
      statuses
      |> Enum.filter(&is_map/1)
      |> Enum.map(&StatusNormalizer.attrs_from_status(&1, actor))
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

  def bulk_upsert(_), do: :ok

  @doc false
  def previous_service_availability(attrs, actor) do
    if StateChangePublisher.enabled?() do
      case existing_service_state(attrs, actor) do
        %ServiceState{} = state -> %{available: state.available, state: state.state}
        _ -> nil
      end
    end
  rescue
    _ -> nil
  end

  @doc false
  def upsert_skipped?(record), do: Ash.Resource.get_metadata(record, :upsert_skipped) == true

  defp maybe_acquire_plugin_state_lock(status) do
    if StatusNormalizer.normalize_string(StatusNormalizer.fetch(status, :service_type), "unknown") ==
         "plugin" do
      PluginState.acquire_lock(status)
    else
      :ok
    end
  end

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
        PluginState.deactivate_shadowed(state, actor)
        ServiceStatePubSub.broadcast_update(state)
        SideEffects.publish_transition(previous, state)
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
        states
        |> Enum.sort_by(&StatusNormalizer.logical_state_rank/1, :desc)
        |> List.first()

      _ ->
        nil
    end
  end
end
