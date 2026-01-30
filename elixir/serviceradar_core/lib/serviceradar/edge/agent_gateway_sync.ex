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

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.OnboardingPackage
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.{Device, IdentityReconciler}

  @spec get_config_if_changed(String.t(), String.t()) ::
          :not_modified | {:ok, map()} | {:error, term()}
  def get_config_if_changed(agent_id, config_version) do
    ServiceRadar.Edge.AgentConfigGenerator.get_config_if_changed(agent_id, config_version)
  end

  @spec component_type_for_component_id(String.t()) :: {:ok, atom()} | {:error, term()}
  def component_type_for_component_id(component_id) do
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:gateway_sync)

    query =
      OnboardingPackage
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(
        expr(component_id == ^component_id and status in [:issued, :delivered, :activated])
      )
      |> Ash.Query.sort(created_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.Query.select([:component_type])

    case Ash.read(query, actor: actor) do
      {:ok, [%OnboardingPackage{component_type: type}]} when is_atom(type) ->
        {:ok, type}

      {:ok, []} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec upsert_agent(String.t(), map()) :: :ok | {:error, term()}
  def upsert_agent(agent_id, attrs) do
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:gateway_sync)

    case Agent.get_by_uid(agent_id, actor: actor) do
      {:ok, %Agent{} = agent} ->
        update_agent(agent, attrs, actor)

      {:error, reason} ->
        if not_found_error?(reason) do
          create_agent(agent_id, attrs, actor)
        else
          Logger.warning("Failed to lookup agent #{agent_id}: #{inspect(reason)}")
          {:error, reason}
        end
    end
  end

  @spec heartbeat_agent(String.t(), map()) :: :ok | {:error, term()}
  def heartbeat_agent(agent_id, attrs) do
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:gateway_sync)

    case Agent.get_by_uid(agent_id, actor: actor) do
      {:ok, %Agent{} = agent} ->
        heartbeat_agent_record(agent, attrs, actor)

      {:error, reason} ->
        if not_found_error?(reason) do
          create_agent(agent_id, attrs, actor)
        else
          Logger.warning("Failed to lookup agent #{agent_id}: #{inspect(reason)}")
          {:error, reason}
        end
    end
  end

  @doc """
  Ensure a device record exists for the agent's host.

  When an agent enrolls, we create or update a device record representing
  the host machine. This enables the agent's sysmon metrics to be associated
  with a device in the inventory.

  The device identity is resolved using DIRE (Device Identity and Reconciliation Engine)
  based on the agent's hostname and source IP.
  """
  @spec ensure_device_for_agent(String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def ensure_device_for_agent(agent_id, attrs) do
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:gateway_sync)

    # Build device update from agent metadata
    device_update = build_device_update_from_agent(attrs)

    # Resolve device ID using DIRE
    case IdentityReconciler.resolve_device_id(device_update, actor: actor) do
      {:ok, device_uid} ->
        # Create or update the device record
        case upsert_device_for_agent(device_uid, agent_id, attrs, actor) do
          :ok ->
            # Link the agent to the device
            link_agent_to_device(agent_id, device_uid, actor)
            {:ok, device_uid}

          {:error, reason} ->
            Logger.warning("Failed to upsert device for agent #{agent_id}: #{inspect(reason)}")

            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Failed to resolve device ID for agent #{agent_id}: #{inspect(reason)}")

        {:error, reason}
    end
  end

  defp build_device_update_from_agent(attrs) do
    %{
      device_id: nil,
      ip: Map.get(attrs, :source_ip) || Map.get(attrs, :host),
      mac: nil,
      partition: Map.get(attrs, :partition, "default"),
      metadata: %{
        "hostname" => Map.get(attrs, :hostname),
        "os" => Map.get(attrs, :os),
        "arch" => Map.get(attrs, :arch)
      }
    }
  end

  defp upsert_device_for_agent(device_uid, agent_id, attrs, actor) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    hostname = Map.get(attrs, :hostname)
    source_ip = Map.get(attrs, :source_ip) || Map.get(attrs, :host)
    partition = Map.get(attrs, :partition, "default")
    os_name = Map.get(attrs, :os)
    arch = Map.get(attrs, :arch)
    capabilities = Map.get(attrs, :capabilities, [])

    # Build OS info map
    os_info =
      %{}
      |> maybe_put("name", os_name)
      |> maybe_put("cpu_architecture", arch)

    os_info = if map_size(os_info) == 0, do: nil, else: os_info

    # Check if device exists
    case Device.get_by_uid(device_uid, include_deleted: true, actor: actor) do
      {:ok, device} ->
        # Update existing device
        update_existing_device_for_agent(device, agent_id, attrs, capabilities, actor, now)

      {:error, reason} ->
        if not_found_error?(reason) do
          # Create new device
          device_context = %{
            device_uid: device_uid,
            agent_id: agent_id,
            hostname: hostname,
            source_ip: source_ip,
            partition: partition,
            os_info: os_info,
            capabilities: capabilities
          }

          create_device_for_agent(device_context, actor, now)
        else
          {:error, reason}
        end
    end
  end

  defp create_device_for_agent(device_context, actor, now) do
    %{
      device_uid: device_uid,
      agent_id: agent_id,
      hostname: hostname,
      source_ip: source_ip,
      partition: partition,
      os_info: os_info,
      capabilities: capabilities
    } = device_context

    # Build discovery_sources based on agent capabilities
    discovery_sources = build_discovery_sources(capabilities)

    create_attrs =
      %{
        uid: device_uid,
        hostname: hostname,
        name: hostname,
        ip: source_ip,
        agent_id: agent_id,
        type_id: 1,
        type: "Server",
        is_available: true,
        is_managed: true,
        is_trusted: true,
        discovery_sources: discovery_sources,
        first_seen_time: now,
        last_seen_time: now,
        created_time: now,
        modified_time: now
      }
      |> maybe_put(:os, os_info)
      |> maybe_put(:zone, partition)
      |> compact_attrs()

    # DB connection's search_path determines the schema
    Device
    |> Ash.Changeset.for_create(:create, create_attrs)
    |> Ash.create(actor: actor)
    |> case do
      {:ok, _device} ->
        Logger.info("Created device #{device_uid} for agent #{agent_id}")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_existing_device_for_agent(device, agent_id, attrs, capabilities, actor, now) do
    hostname = Map.get(attrs, :hostname)
    source_ip = Map.get(attrs, :source_ip) || Map.get(attrs, :host)

    # Merge discovery_sources with capability-based sources
    existing_sources = device.discovery_sources || []
    capability_sources = build_discovery_sources(capabilities)
    new_sources = Enum.uniq(capability_sources ++ existing_sources)

    update_attrs =
      %{
        agent_id: agent_id,
        is_available: true,
        is_managed: true,
        is_trusted: true,
        discovery_sources: new_sources,
        last_seen_time: now
      }
      |> maybe_put(:hostname, hostname)
      |> maybe_put(:ip, source_ip)
      |> compact_attrs()

    # DB connection's search_path determines the schema
    device
    |> Ash.Changeset.for_update(:gateway_sync, update_attrs)
    |> Ash.update(actor: actor)
    |> case do
      {:ok, _device} ->
        Logger.debug("Updated device #{device.uid} for agent #{agent_id}")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Build discovery_sources list based on agent capabilities
  defp build_discovery_sources(capabilities) when is_list(capabilities) do
    base_sources = ["agent"]

    # Add sysmon source if agent has sysmon capability
    has_sysmon =
      Enum.any?(capabilities, fn cap ->
        cap_lower = String.downcase(to_string(cap))
        String.contains?(cap_lower, "sysmon") or String.contains?(cap_lower, "system_monitor")
      end)

    if has_sysmon do
      ["sysmon" | base_sources]
    else
      base_sources
    end
  end

  defp build_discovery_sources(_), do: ["agent"]

  defp link_agent_to_device(agent_id, device_uid, actor) do
    # DB connection's search_path determines the schema
    case Agent.get_by_uid(agent_id, actor: actor) do
      {:ok, %Agent{device_uid: existing_uid} = agent} when existing_uid != device_uid ->
        agent
        |> Ash.Changeset.for_update(:gateway_sync, %{device_uid: device_uid})
        |> Ash.update(actor: actor)
        |> case do
          {:ok, _} ->
            Logger.debug("Linked agent #{agent_id} to device #{device_uid}")
            :ok

          {:error, reason} ->
            Logger.warning("Failed to link agent #{agent_id} to device: #{inspect(reason)}")
            :ok
        end

      {:ok, _agent} ->
        # Already linked or same device
        :ok

      {:error, _} ->
        # Agent not found yet, will be linked on next update
        :ok
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp update_agent(agent, attrs, actor) do
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

    # DB connection's search_path determines the schema
    result =
      if map_size(update_attrs) > 0 do
        agent
        |> Ash.Changeset.for_update(:gateway_sync, update_attrs)
        |> Ash.update(actor: actor)
      else
        {:ok, agent}
      end

    case result do
      {:ok, updated} -> heartbeat_agent_record(updated, attrs, actor)
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_agent(agent_id, attrs, actor) do
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

    # DB connection's search_path determines the schema
    Agent
    |> Ash.Changeset.for_create(:register_connected, create_attrs)
    |> Ash.create(actor: actor)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp heartbeat_agent_record(agent, attrs, actor) do
    heartbeat_attrs =
      attrs
      |> Map.take([:capabilities, :is_healthy, :config_source])
      |> compact_attrs()

    # DB connection's search_path determines the schema
    agent
    |> Ash.Changeset.for_update(:heartbeat, heartbeat_attrs)
    |> Ash.update(actor: actor)
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
end
