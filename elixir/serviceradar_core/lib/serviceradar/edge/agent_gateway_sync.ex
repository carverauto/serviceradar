defmodule ServiceRadar.Edge.AgentGatewaySync do
  @moduledoc """
  RPC helpers for agent-gateway to interact with core-owned data.

  These functions are intended to run on core-elx nodes with
  database access and should be invoked via :rpc.call from the
  agent-gateway release.
  """

  require Logger
  require Ash.Query
  import Ash.Expr

  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Edge.OnboardingPackage

  @spec get_config_if_changed(String.t(), String.t(), String.t()) ::
          :not_modified | {:ok, map()} | {:error, term()}
  def get_config_if_changed(agent_id, tenant_id, config_version) do
    ServiceRadar.Edge.AgentConfigGenerator.get_config_if_changed(
      agent_id,
      tenant_id,
      config_version
    )
  end

  @spec component_type_for_component_id(String.t(), String.t()) :: {:ok, atom()} | {:error, term()}
  def component_type_for_component_id(component_id, tenant_id) do
    actor = system_actor(tenant_id)

    query =
      OnboardingPackage
      |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: tenant_id, authorize?: false)
      |> Ash.Query.filter(
        expr(component_id == ^component_id and status in [:issued, :delivered, :activated])
      )
      |> Ash.Query.sort(created_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.Query.select([:component_type])

    case Ash.read(query, authorize?: false) do
      {:ok, [%OnboardingPackage{component_type: type}]} when is_atom(type) ->
        {:ok, type}

      {:ok, []} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec upsert_agent(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def upsert_agent(agent_id, tenant_id, attrs) do
    actor = system_actor(tenant_id)

    case Agent.get_by_uid(agent_id, tenant: tenant_id, actor: actor, authorize?: false) do
      {:ok, %Agent{} = agent} ->
        update_agent(agent, tenant_id, attrs, actor)

      {:error, reason} ->
        if not_found_error?(reason) do
          create_agent(agent_id, tenant_id, attrs, actor)
        else
          Logger.warning("Failed to lookup agent #{agent_id}: #{inspect(reason)}")
          {:error, reason}
        end
    end
  end

  @spec heartbeat_agent(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def heartbeat_agent(agent_id, tenant_id, attrs) do
    actor = system_actor(tenant_id)

    case Agent.get_by_uid(agent_id, tenant: tenant_id, actor: actor, authorize?: false) do
      {:ok, %Agent{} = agent} ->
        heartbeat_agent_record(agent, tenant_id, attrs, actor)

      {:error, reason} ->
        if not_found_error?(reason) do
          create_agent(agent_id, tenant_id, attrs, actor)
        else
          Logger.warning("Failed to lookup agent #{agent_id}: #{inspect(reason)}")
          {:error, reason}
        end
    end
  end

  defp update_agent(agent, tenant_id, attrs, actor) do
    update_attrs =
      attrs
      |> Map.take([
        :name,
        :capabilities,
        :host,
        :port,
        :spiffe_identity,
        :metadata,
        :version,
        :type_id
      ])
      |> compact_attrs()

    result =
      if map_size(update_attrs) > 0 do
        agent
        |> Ash.Changeset.for_update(:gateway_sync, update_attrs)
        |> Ash.update(tenant: tenant_id, actor: actor, authorize?: false)
      else
        {:ok, agent}
      end

    case result do
      {:ok, updated} -> heartbeat_agent_record(updated, tenant_id, attrs, actor)
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_agent(agent_id, tenant_id, attrs, actor) do
    create_attrs =
      attrs
      |> Map.put_new(:type_id, 4)
      |> Map.put(:uid, agent_id)
      |> Map.take([
        :uid,
        :name,
        :type_id,
        :type,
        :uid_alt,
        :vendor_name,
        :version,
        :policies,
        :gateway_id,
        :device_uid,
        :capabilities,
        :host,
        :port,
        :spiffe_identity,
        :metadata
      ])
      |> compact_attrs()

    Agent
    |> Ash.Changeset.for_create(:register_connected, create_attrs)
    |> Ash.create(tenant: tenant_id, actor: actor, authorize?: false)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp heartbeat_agent_record(agent, tenant_id, attrs, actor) do
    heartbeat_attrs =
      attrs
      |> Map.take([:capabilities, :is_healthy])
      |> compact_attrs()

    agent
    |> Ash.Changeset.for_update(:heartbeat, heartbeat_attrs)
    |> Ash.update(tenant: tenant_id, actor: actor, authorize?: false)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp compact_attrs(attrs) do
    attrs
    |> Enum.reject(fn
      {_key, nil} -> true
      {_key, ""} -> true
      {_key, []} -> true
      {_key, %{} = value} -> map_size(value) == 0
      _ -> false
    end)
    |> Map.new()
  end

  defp not_found_error?(%Ash.Error.Query.NotFound{}), do: true

  defp not_found_error?(%Ash.Error.Invalid{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))
  end

  defp not_found_error?(_error), do: false

  defp system_actor(tenant_id) do
    %{
      id: "system",
      email: "gateway@serviceradar",
      role: :admin,
      tenant_id: tenant_id
    }
  end
end
