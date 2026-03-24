defmodule ServiceRadar.Observability.ServiceStateRegistry do
  @moduledoc """
  Maintains the current service state registry.
  """

  import Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Observability.ServiceState
  alias ServiceRadar.Observability.ServiceStatePubSub
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage

  require Logger

  @spec upsert_from_status(map()) :: :ok
  def upsert_from_status(status) when is_map(status) do
    actor = SystemActor.system(:service_state_registry)

    attrs = build_attrs_from_status(status)

    ServiceState
    |> Ash.Changeset.for_create(:upsert, attrs, actor: actor)
    |> Ash.create(domain: ServiceRadar.Observability)
    |> case do
      {:ok, state} ->
        ServiceStatePubSub.broadcast_update(state)
        :ok

      {:error, error} ->
        Logger.warning("Failed to upsert service state: #{inspect(error)}")
        :ok

      other ->
        Logger.warning("Unexpected service state upsert result: #{inspect(other)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("Service state upsert failed: #{Exception.message(error)}")
      :ok
  end

  def upsert_from_status(_), do: :ok

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

  defp build_attrs_from_status(status) do
    message = normalize_message(fetch(status, :message))

    %{
      agent_id: normalize_string(fetch(status, :agent_id), "unknown"),
      gateway_id: normalize_string(fetch(status, :gateway_id), "unknown"),
      partition: resolve_partition(status),
      service_type: normalize_string(fetch(status, :service_type), "unknown"),
      service_name: normalize_string(fetch(status, :service_name), "unknown"),
      available: normalize_available(fetch(status, :available)),
      message: normalize_message_value(message),
      details: nil,
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
    slice_message(FieldParser.encode_json(message))
  end

  defp normalize_message(_), do: nil

  defp slice_message(nil), do: nil
  defp slice_message(message) when is_binary(message), do: String.slice(message, 0, 2048)

  defp normalize_message_value(value) when is_binary(value) or is_nil(value), do: value

  defp normalize_message_value(value) do
    FieldParser.encode_json(value) || inspect(value)
  end

  defp resolve_observed_at(status) do
    raw =
      fetch(status, :agent_timestamp) || fetch(status, :timestamp) || fetch(status, :observed_at)

    (%DateTime{} = dt) = FieldParser.parse_timestamp(raw)
    DateTime.truncate(dt, :microsecond)
  rescue
    _ -> DateTime.truncate(DateTime.utc_now(), :microsecond)
  end

  defp fetch(status, key) when is_map(status) do
    Map.get(status, key) || Map.get(status, Atom.to_string(key))
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
end
