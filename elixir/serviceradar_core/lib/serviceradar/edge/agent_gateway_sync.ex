defmodule ServiceRadar.Edge.AgentGatewaySync do
  @moduledoc """
  RPC helpers for agent-gateway to interact with core-owned data.

  These functions are intended to run on core-elx nodes with
  database access and should be invoked via :rpc.call from the
  agent-gateway release.
  """

  import Ash.Expr

  alias Ash.Error.Invalid
  alias Ash.Error.Query.NotFound
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.SafeFailureEvidence
  alias ServiceRadar.Automation.LaunchEnvelopes
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.SecretBroker
  alias ServiceRadar.Edge.AgentArtifactDelivery
  alias ServiceRadar.Edge.AgentReleaseManager
  alias ServiceRadar.Edge.AgentReleaseTarget
  alias ServiceRadar.Edge.OnboardingPackage
  alias ServiceRadar.Edge.ReleaseArtifactDelivery
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Gateway
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Identity.Fence
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.NetworkDiscovery.MapperJob
  alias ServiceRadar.SweepJobs.AgentAssignment
  alias ServiceRadar.SweepJobs.SweepGroup

  require Ash.Query
  require Logger

  @terminal_release_target_statuses [:healthy, :failed, :rolled_back, :canceled]

  @spec get_config_if_changed(String.t(), String.t()) ::
          :not_modified | {:ok, map()} | {:error, term()}
  def get_config_if_changed(_agent_id, _config_version),
    do: {:error, :authenticated_partition_required}

  @spec get_config_if_changed(String.t(), String.t(), String.t()) ::
          :not_modified | {:ok, map()} | {:error, term()}
  def get_config_if_changed(agent_id, partition_id, config_version) do
    ServiceRadar.Edge.AgentConfigGenerator.get_config_if_changed(
      agent_id,
      partition_id,
      config_version
    )
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

    with :ok <- ensure_gateway_for_agent(attrs, actor),
         :ok <- upsert_agent_record(agent_id, attrs, actor) do
      reconcile_agent_release_after_version_sync(agent_id, attrs, actor)
    end
  end

  @spec heartbeat_agent(String.t(), map()) :: :ok | {:error, term()}
  def heartbeat_agent(agent_id, attrs) do
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:gateway_sync)

    with :ok <- ensure_gateway_for_agent(attrs, actor),
         :ok <- heartbeat_agent_record_by_id(agent_id, attrs, actor) do
      reconcile_agent_release_after_version_sync(agent_id, attrs, actor)
    end
  end

  @doc """
  Persists a config acknowledgement forwarded by the agent-gateway.

  `attrs` carries `:config_version`, `:acked_at`, and optionally `:section_statuses`
  (a list of per-section maps from a sectioned ack). Acks without section statuses
  come from legacy agents (or heartbeat-hello reported versions) and are recorded as
  whole-version acks: the version and timestamp update, the previously recorded
  section detail is left untouched.
  """
  @spec record_config_ack(String.t(), map()) :: :ok | {:error, term()}
  def record_config_ack(agent_id, attrs) do
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:gateway_sync)

    ack_attrs =
      maybe_put_section_statuses(
        %{
          acked_config_version: Map.get(attrs, :config_version),
          config_acked_at: Map.get(attrs, :acked_at) || DateTime.utc_now()
        },
        Map.get(attrs, :section_statuses)
      )

    update_agent_config_state(agent_id, :record_config_ack, ack_attrs, actor)
  end

  @doc """
  Records the config version most recently pushed to an agent over the control
  stream. The first-push timestamp of a version anchors wedge detection (an agent
  that never acks a pushed version becomes config-unhealthy after the window), so a
  re-push of the same version does not refresh it.
  """
  @spec record_config_push(String.t(), map()) :: :ok | {:error, term()}
  def record_config_push(agent_id, attrs) do
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:gateway_sync)
    version = Map.get(attrs, :config_version)

    case Agent.get_by_uid(agent_id, actor: actor) do
      {:ok, %Agent{pushed_config_version: ^version}} ->
        # Same version re-pushed (reconnect / dependency-write re-stream): keep the
        # original push timestamp so the no-ack window keeps counting.
        :ok

      {:ok, %Agent{} = agent} ->
        agent
        |> Ash.Changeset.for_update(:record_config_push, %{
          pushed_config_version: version,
          config_pushed_at: Map.get(attrs, :pushed_at) || DateTime.utc_now()
        })
        |> Ash.update(actor: actor)
        |> case do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put_section_statuses(attrs, statuses) when is_list(statuses),
    do: Map.put(attrs, :config_section_statuses, statuses)

  defp maybe_put_section_statuses(attrs, _statuses), do: attrs

  defp update_agent_config_state(agent_id, action, attrs, actor) do
    case Agent.get_by_uid(agent_id, actor: actor) do
      {:ok, %Agent{} = agent} ->
        agent
        |> Ash.Changeset.for_update(action, attrs)
        |> Ash.update(actor: actor)
        |> case do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec reconcile_agent_release(String.t()) :: :ok
  def reconcile_agent_release(agent_id) do
    AgentReleaseManager.reconcile_agent(agent_id)
  end

  @spec resolve_release_artifact_download(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def resolve_release_artifact_download(target_id, command_id, caller_agent_id) do
    ReleaseArtifactDelivery.resolve_download(target_id, command_id, caller_agent_id)
  end

  @spec resolve_plugin_artifact_download(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def resolve_plugin_artifact_download(package_id, object_key, caller_agent_id) do
    AgentArtifactDelivery.resolve_plugin_download(package_id, object_key, caller_agent_id)
  end

  @spec resolve_addon_artifact_download(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def resolve_addon_artifact_download(package_id, object_key, caller_agent_id) do
    AgentArtifactDelivery.resolve_addon_download(package_id, object_key, caller_agent_id)
  end

  @spec resolve_agent_artifact_download(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def resolve_agent_artifact_download(token_id, object_key, caller_agent_id) do
    AgentArtifactDelivery.resolve_token_artifact_download(token_id, object_key, caller_agent_id)
  end

  @spec resolve_credential_broker_grant(map()) :: {:ok, map()} | {:error, term()}
  def resolve_credential_broker_grant(%{} = request) do
    actor = SystemActor.system(:gateway_credential_broker)
    grant_id = string_value(map_value(request, :grant_id))
    agent_id = string_value(map_value(request, :agent_id))

    with :ok <- present_required(grant_id, :grant_id),
         :ok <- present_required(agent_id, :agent_id),
         {:ok, %CredentialBrokerGrant{} = grant} <-
           CredentialBrokerGrant.get_by_id(grant_id, actor: actor),
         :ok <- validate_broker_request(grant, request),
         {:ok, resolved} <-
           resolve_broker_grant_material(grant, actor, agent_id) do
      {:ok, credential_material(resolved)}
    end
  end

  def resolve_credential_broker_grant(_request), do: {:error, :invalid_credential_broker_request}

  @spec resolve_automation_launch_envelope(map()) :: {:ok, map()} | {:error, term()}
  def resolve_automation_launch_envelope(%{} = request) do
    reference = string_value(map_value(request, :envelope_ref))
    command_id = string_value(map_value(request, :command_id))
    agent_id = string_value(map_value(request, :agent_id))
    partition_id = string_value(map_value(request, :partition_id))

    with :ok <- present_required(reference, :envelope_ref),
         :ok <- present_required(command_id, :command_id),
         :ok <- present_required(agent_id, :agent_id),
         :ok <- present_required(partition_id, :partition_id) do
      LaunchEnvelopes.resolve(reference, %{
        agent_id: agent_id,
        partition_id: partition_id,
        command_id: command_id
      })
    end
  end

  def resolve_automation_launch_envelope(_request),
    do: {:error, :invalid_automation_launch_envelope_request}

  @doc """
  Ensure a device record exists for the agent's host.

  When an agent enrolls, we create or update a device record representing
  the host machine. This enables the agent's sysmon metrics to be associated
  with a device in the inventory.

  The device identity is resolved using DIRE (Device Identity and Reconciliation Engine)
  based on the agent's identifiers, hostname and source IP.

  Host evidence (task 6.1, `refactor-device-identity-reconciliation`): in
  addition to the `agent_id` identifier, enrollment registers the agent host's
  own interface MACs whenever the hello attrs carry them (`:host_macs`,
  `:mac_addresses` or `:macs`, top-level or under `:metadata`; list or
  delimited string). Values are normalized/validated through
  `IdentityReconciler.normalize_mac_list/1`, so malformed entries and
  multi-MAC blobs can never become identifiers. Producers MUST only put the
  agent host's own interface MACs in these fields (never neighbour/sweep
  observations). Hostname (normalized) and machine-id are NOT identifier
  types today; they are surfaced in the device-update metadata
  (`"hostname_normalized"`, `"machine_id"`) so DIRE-side bridging can use
  them as corroborating evidence.
  """
  @spec ensure_device_for_agent(String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def ensure_device_for_agent(agent_id, attrs) do
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:gateway_sync)

    # Build device update from agent metadata
    device_update = build_device_update_from_agent(agent_id, attrs)

    # Resolve device ID using DIRE
    case resolve_device_id_for_agent(device_update, actor) do
      {:ok, device_uid} ->
        # Create or update the device record
        case upsert_device_for_agent(device_uid, agent_id, attrs, actor) do
          :ok ->
            complete_agent_device_sync(device_uid, agent_id, attrs, device_update, actor)

          {:ok, adopted_device_uid} ->
            complete_agent_device_sync(adopted_device_uid, agent_id, attrs, device_update, actor)

          {:error, reason} ->
            Logger.warning("Failed to upsert device for agent #{agent_id}: #{inspect(reason)}")

            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Failed to resolve device ID for agent #{agent_id}: #{inspect(reason)}")

        {:error, reason}
    end
  end

  defp complete_agent_device_sync(device_uid, agent_id, attrs, device_update, actor) do
    # Observe-only identity fence. Identity was resolved once above, and the six
    # writes below are independent, so a merge landing partway through leaves some
    # of them on the old device. This measures how often that actually happens
    # before anything is enforced; nothing branches on the result.
    pinned = Fence.observe_pin(device_uid)

    # Register agent_id as a strong identifier so DIRE can resolve
    # subsequent enrollments (even from different IPs) to this device
    ids = IdentityReconciler.extract_strong_identifiers(device_update)
    IdentityReconciler.register_identifiers(device_uid, ids, actor: actor)
    IdentityReconciler.repair_agent_identifier(agent_id, device_uid, actor)

    # Link the agent to the device
    link_agent_to_device(agent_id, device_uid, actor)
    backfill_endpoint_inventory_device_uid(agent_id, device_uid)
    retire_superseded_agents(agent_id, device_uid, attrs, actor)

    Fence.observe(pinned, :agent_gateway_sync)
    {:ok, device_uid}
  end

  defp resolve_device_id_for_agent(device_update, actor) do
    apply(IdentityReconciler, :resolve_device_id, [device_update, [actor: actor]])
  end

  @doc false
  # Public for unit testing only; not part of the gateway RPC surface.
  def build_device_update_from_agent(agent_id, attrs) do
    hostname = Map.get(attrs, :hostname)

    metadata =
      %{
        "agent_id" => agent_id,
        "hostname" => hostname,
        "os" => Map.get(attrs, :os),
        "arch" => Map.get(attrs, :arch)
      }
      |> maybe_put("hostname_normalized", normalize_hostname(hostname))
      |> maybe_put("machine_id", agent_machine_id(attrs))

    %{
      device_id: nil,
      ip: agent_source_ip(attrs),
      mac: nil,
      mac_addresses: agent_host_macs(attrs),
      partition: Map.get(attrs, :partition, "default"),
      metadata: metadata
    }
  end

  # Host-evidence MAC fields accepted from the gateway hello attrs. By
  # contract these carry ONLY the agent host's own interface MACs
  # (observer-excluded); they must never contain neighbour or sweep-observed
  # MACs. Each value may be a list or a delimited string; everything is
  # normalized and validated via IdentityReconciler.normalize_mac_list/1.
  @host_mac_attr_keys [:host_macs, "host_macs", :mac_addresses, "mac_addresses", :macs, "macs"]

  defp agent_host_macs(attrs) do
    metadata = agent_attrs_metadata(attrs)

    @host_mac_attr_keys
    |> Enum.flat_map(fn key ->
      collect_mac_values(Map.get(attrs, key)) ++ collect_mac_values(Map.get(metadata, key))
    end)
    |> Enum.uniq()
  end

  defp collect_mac_values(value) when is_list(value),
    do: Enum.flat_map(value, &IdentityReconciler.normalize_mac_list/1)

  defp collect_mac_values(value) when is_binary(value),
    do: IdentityReconciler.normalize_mac_list(value)

  defp collect_mac_values(_value), do: []

  defp agent_machine_id(attrs) do
    metadata = agent_attrs_metadata(attrs)

    Enum.find_value(
      [
        Map.get(attrs, :machine_id),
        Map.get(attrs, "machine_id"),
        Map.get(metadata, :machine_id),
        Map.get(metadata, "machine_id")
      ],
      &normalize_optional_string/1
    )
  end

  defp agent_attrs_metadata(attrs) do
    case Map.get(attrs, :metadata) || Map.get(attrs, "metadata") do
      %{} = metadata -> metadata
      _ -> %{}
    end
  end

  defp upsert_device_for_agent(device_uid, agent_id, attrs, actor) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    hostname = Map.get(attrs, :hostname)
    source_ip = agent_source_ip(attrs)
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
    case Device.get_by_uid(device_uid, true, actor: actor) do
      {:ok, nil} ->
        # No record found (get? actions can return nil), fall through to create
        create_device_for_agent(
          %{
            device_uid: device_uid,
            agent_id: agent_id,
            hostname: hostname,
            source_ip: source_ip,
            partition: partition,
            os_info: os_info,
            capabilities: capabilities
          },
          actor,
          now
        )

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

  defp create_device_for_agent(device_context, actor, now, allow_conflict_release? \\ true) do
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
        maybe_adopt_existing_active_ip_device(
          reason,
          source_ip,
          device_context,
          actor,
          now,
          allow_conflict_release?
        )
    end
  end

  defp maybe_adopt_existing_active_ip_device(
         reason,
         source_ip,
         device_context,
         actor,
         now,
         allow_conflict_release?
       ) do
    if active_ip_unique_conflict?(reason) and present_string?(source_ip) do
      case fetch_active_device_by_ip(source_ip, actor) do
        {:ok, %Device{} = existing_device} ->
          handle_active_ip_owner_conflict(
            existing_device,
            source_ip,
            device_context,
            actor,
            now,
            allow_conflict_release?
          )

        {:error, lookup_reason} ->
          if not_found_error?(lookup_reason), do: {:error, reason}, else: {:error, lookup_reason}
      end
    else
      {:error, reason}
    end
  end

  defp maybe_adopt_existing_active_ip_device(reason, source_ip, device_context, actor, now) do
    maybe_adopt_existing_active_ip_device(reason, source_ip, device_context, actor, now, true)
  end

  defp handle_active_ip_owner_conflict(
         existing_device,
         source_ip,
         device_context,
         actor,
         now,
         allow_conflict_release?
       ) do
    cond do
      adoptable_active_ip_owner?(existing_device, device_context) ->
        Logger.info(
          "Adopting existing device #{existing_device.uid} for agent #{device_context.agent_id} after active IP conflict on #{source_ip}"
        )

        case update_existing_device_for_agent(
               existing_device,
               device_context.agent_id,
               %{
                 hostname: device_context.hostname,
                 source_ip: source_ip
               },
               device_context.capabilities,
               actor,
               now
             ) do
          :ok -> {:ok, existing_device.uid}
          {:error, update_reason} -> {:error, update_reason}
        end

      allow_conflict_release? ->
        with :ok <-
               release_conflicting_active_ip_owner(
                 existing_device,
                 source_ip,
                 device_context,
                 actor
               ) do
          create_device_for_agent(device_context, actor, now, false)
        end

      true ->
        {:error,
         {:active_ip_owned_by_different_agent, source_ip, existing_device.uid,
          existing_device.agent_id}}
    end
  end

  defp adoptable_active_ip_owner?(%Device{} = existing_device, device_context) do
    existing_agent_id = normalize_optional_string(existing_device.agent_id)
    current_agent_id = normalize_optional_string(device_context.agent_id)
    existing_hostname = normalize_hostname(existing_device.hostname || existing_device.name)
    current_hostname = normalize_hostname(device_context.hostname)

    is_nil(existing_agent_id) or existing_agent_id == current_agent_id or
      (present_string?(existing_hostname) and existing_hostname == current_hostname)
  end

  defp release_conflicting_active_ip_owner(
         %Device{} = existing_device,
         source_ip,
         device_context,
         actor
       ) do
    existing_agent_id = normalize_optional_string(existing_device.agent_id)

    Logger.warning(
      "Releasing active IP #{source_ip} from device #{existing_device.uid} " <>
        "owned by agent #{inspect(existing_agent_id)} before linking agent #{device_context.agent_id}"
    )

    metadata =
      existing_device.metadata
      |> Map.new()
      |> Map.put("released_conflicting_active_ip", source_ip)
      |> Map.put("released_conflicting_active_ip_at", DateTime.to_iso8601(DateTime.utc_now()))
      |> Map.put("released_conflicting_active_ip_for_agent", device_context.agent_id)

    existing_device
    |> Ash.Changeset.for_update(:gateway_sync, %{ip: nil, metadata: metadata})
    |> Ash.update(actor: actor)
    |> case do
      {:ok, _updated} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_), do: nil

  defp normalize_hostname(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_hostname(_), do: nil

  defp fetch_active_device_by_ip(source_ip, actor) do
    case Device.get_by_ip(source_ip, false, actor: actor) do
      {:ok, %Device{} = device} -> {:ok, device}
      {:ok, [device | _]} -> {:ok, device}
      {:ok, []} -> {:error, %NotFound{}}
      {:ok, nil} -> {:error, %NotFound{}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_existing_device_for_agent(device, agent_id, attrs, capabilities, actor, now) do
    hostname = Map.get(attrs, :hostname)
    source_ip = agent_source_ip(attrs)

    # Merge discovery_sources with capability-based sources
    existing_sources = device.discovery_sources || []
    capability_sources = build_discovery_sources(capabilities)
    new_sources = Enum.uniq(capability_sources ++ existing_sources)
    {device_type, device_type_id} = agent_host_device_type(device)

    update_attrs =
      %{
        type_id: device_type_id,
        type: device_type,
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

      {:error, %Invalid{} = error} ->
        cond do
          stale_record_error?(error) ->
            force_gateway_sync_update(device.uid, update_attrs, actor)

          active_ip_unique_conflict?(error) ->
            maybe_adopt_existing_active_ip_device(
              error,
              source_ip,
              %{
                agent_id: agent_id,
                hostname: hostname,
                source_ip: source_ip,
                capabilities: capabilities
              },
              actor,
              now
            )

          true ->
            {:error, error}
        end

      {:error, reason} ->
        maybe_adopt_existing_active_ip_device(
          reason,
          source_ip,
          %{
            agent_id: agent_id,
            hostname: hostname,
            source_ip: source_ip,
            capabilities: capabilities
          },
          actor,
          now
        )
    end
  end

  defp agent_host_device_type(%Device{} = device) do
    if hypervisor_device?(device) do
      {"Hypervisor", 99}
    else
      {"Server", 1}
    end
  end

  defp hypervisor_device?(%Device{} = device) do
    metadata = device.metadata || %{}
    role = metadata |> Map.get("device_role") |> to_string() |> String.downcase()

    role == "hypervisor" or
      device.type == "Hypervisor" or
      Enum.any?(device.discovery_sources || [], &(&1 in ["proxmox-api", "proxmox-candidate"]))
  end

  # Build discovery_sources list based on agent capabilities
  defp build_discovery_sources(capabilities) when is_list(capabilities) do
    capability_names = Enum.map(capabilities, &normalize_capability_name/1)

    ["agent"]
    |> maybe_add_discovery_source("sysmon", has_sysmon_capability?(capability_names))
    |> maybe_add_discovery_source(
      "passive-netprobe",
      has_host_network_visibility_capability?(capability_names)
    )
  end

  defp build_discovery_sources(_), do: ["agent"]

  defp normalize_capability_name(capability) do
    capability
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace("_", "-")
  end

  defp has_sysmon_capability?(capability_names) do
    Enum.any?(capability_names, fn capability ->
      String.contains?(capability, "sysmon") or String.contains?(capability, "system-monitor")
    end)
  end

  defp has_host_network_visibility_capability?(capability_names) do
    Enum.any?(capability_names, fn capability ->
      capability == "host-network-visibility.fingerprint.enabled"
    end)
  end

  defp maybe_add_discovery_source(sources, source, true), do: [source | sources]
  defp maybe_add_discovery_source(sources, _source, false), do: sources

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

  defp backfill_endpoint_inventory_device_uid(agent_id, device_uid) do
    case IdentityReconciler.backfill_endpoint_inventory_device_uid_for_agent(agent_id, device_uid) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to backfill endpoint inventory device UID for agent #{agent_id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp retire_superseded_agents(agent_id, device_uid, attrs, actor) do
    source_ip = agent_source_ip(attrs)
    canonical_agent_id = canonicalize_agent_uid(agent_id)

    query = superseded_agent_query(device_uid, source_ip, actor)

    case Ash.read(query, actor: actor) do
      {:ok, agents} ->
        agents
        |> Enum.reject(&(&1.uid == agent_id))
        |> Enum.filter(fn agent ->
          canonicalize_agent_uid(agent.uid) == canonical_agent_id or
            matching_source?(agent, source_ip)
        end)
        |> Enum.each(&mark_agent_superseded(&1, agent_id, actor))

      {:error, reason} ->
        Logger.warning(
          "Failed to lookup superseded agents for #{agent_id} on #{device_uid}: #{inspect(reason)}"
        )
    end
  end

  defp superseded_agent_query(device_uid, source_ip, actor) do
    query = Ash.Query.for_read(Agent, :read, %{}, actor: actor)

    if present_string?(source_ip) do
      Ash.Query.filter(
        query,
        expr(device_uid == ^device_uid or ip == ^source_ip or host == ^source_ip)
      )
    else
      Ash.Query.filter(query, expr(device_uid == ^device_uid))
    end
  end

  defp matching_source?(_agent, nil), do: true

  defp matching_source?(%Agent{ip: ip, host: host}, source_ip),
    do: ip == source_ip or host == source_ip

  defp mark_agent_superseded(%Agent{status: :unavailable}, _replacement_agent_id, _actor), do: :ok

  defp mark_agent_superseded(agent, replacement_agent_id, actor) do
    reason = "superseded by reenrollment: #{replacement_agent_id}"

    case agent
         |> Ash.Changeset.for_update(:mark_unavailable, %{reason: reason})
         |> Ash.update(actor: actor) do
      {:ok, updated} ->
        cancel_superseded_release_targets(agent.uid, replacement_agent_id, actor)
        mark_superseded_release_state(updated, actor)
        transfer_superseded_assignments(agent.uid, replacement_agent_id, actor)

        Logger.info(
          "Marked superseded agent #{agent.uid} unavailable in favor of #{replacement_agent_id}"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to mark superseded agent #{agent.uid} unavailable: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp mark_superseded_release_state(agent, actor) do
    _ =
      agent
      |> Ash.Changeset.for_update(:update_release_status, %{
        release_rollout_state: :canceled,
        last_update_at: DateTime.utc_now(),
        last_update_error: "agent_superseded"
      })
      |> Ash.update(actor: actor)

    :ok
  end

  defp cancel_superseded_release_targets(agent_id, replacement_agent_id, actor) do
    AgentReleaseTarget
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(
      expr(agent_id == ^agent_id and status not in ^@terminal_release_target_statuses)
    )
    |> Ash.read(actor: actor)
    |> case do
      {:ok, targets} ->
        Enum.each(targets, fn target ->
          _ =
            AgentReleaseTarget.set_status(
              target,
              %{
                status: :canceled,
                last_status_message: "superseded by #{replacement_agent_id}",
                last_error: "agent_superseded",
                completed_at: DateTime.utc_now()
              },
              actor: actor
            )
        end)

      {:error, reason} ->
        Logger.warning(
          "Failed to cancel release targets for superseded agent #{agent_id}: #{inspect(reason)}"
        )
    end
  end

  defp transfer_superseded_assignments(agent_id, replacement_agent_id, actor) do
    Enum.each(
      [
        {:mapper_jobs,
         transfer_agent_assignment(MapperJob, agent_id, replacement_agent_id, actor)},
        {:sweep_groups, transfer_sweep_group_assignments(agent_id, replacement_agent_id, actor)}
      ],
      &log_assignment_transfer(&1, agent_id, replacement_agent_id)
    )
  end

  defp log_assignment_transfer({_label, {:ok, 0}}, _agent_id, _replacement_agent_id), do: :ok

  defp log_assignment_transfer({label, {:ok, count}}, agent_id, replacement_agent_id) do
    Logger.info(
      "Reassigned #{count} #{label} from superseded agent #{agent_id} to #{replacement_agent_id}"
    )
  end

  defp log_assignment_transfer({label, {:error, reason}}, agent_id, replacement_agent_id) do
    Logger.warning(
      "Failed to reassign #{label} from superseded agent #{agent_id} to #{replacement_agent_id}: #{inspect(reason)}"
    )
  end

  defp transfer_agent_assignment(resource, agent_id, replacement_agent_id, actor) do
    query =
      resource
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(agent_id == ^agent_id)

    case Ash.read(query, actor: actor) do
      {:ok, []} ->
        {:ok, 0}

      {:ok, records} ->
        update_agent_assignments(records, replacement_agent_id, actor)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp transfer_sweep_group_assignments(agent_id, replacement_agent_id, actor) do
    query =
      SweepGroup
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(^agent_id in agent_ids)

    case Ash.read(query, actor: actor) do
      {:ok, records} ->
        records
        |> Enum.map(&replace_sweep_group_assignment(&1, agent_id, replacement_agent_id))
        |> update_sweep_group_assignments(actor)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replace_sweep_group_assignment(group, agent_id, replacement_agent_id) do
    agent_ids =
      group.agent_ids
      |> AgentAssignment.normalize()
      |> Enum.map(fn current_agent_id ->
        if current_agent_id == agent_id, do: replacement_agent_id, else: current_agent_id
      end)
      |> AgentAssignment.normalize()

    {group, agent_ids}
  end

  defp update_agent_assignments(records, replacement_agent_id, actor) do
    records
    |> Enum.reduce_while(0, fn record, count ->
      record
      |> Ash.Changeset.for_update(:update, %{agent_id: replacement_agent_id}, actor: actor)
      |> Ash.update()
      |> case do
        {:ok, _record} -> {:cont, count + 1}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      count -> {:ok, count}
    end
  end

  defp update_sweep_group_assignments(assignments, actor) do
    assignments
    |> Enum.reduce_while(0, fn {group, agent_ids}, count ->
      group
      |> Ash.Changeset.for_update(:update, %{agent_ids: agent_ids}, actor: actor)
      |> Ash.update()
      |> case do
        {:ok, _group} -> {:cont, count + 1}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      count -> {:ok, count}
    end
  end

  defp canonicalize_agent_uid(uid) when is_binary(uid) do
    uid
    |> String.split("-", trim: true)
    |> collapse_duplicate_prefix()
    |> Enum.join("-")
  end

  defp canonicalize_agent_uid(uid), do: uid

  defp collapse_duplicate_prefix([prefix, prefix | rest]) do
    collapse_duplicate_prefix([prefix | rest])
  end

  defp collapse_duplicate_prefix(parts), do: parts

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp ensure_gateway_for_agent(attrs, actor) do
    case normalized_gateway_id(Map.get(attrs, :gateway_id)) do
      nil ->
        :ok

      gateway_id ->
        case Gateway.get_by_id(gateway_id, actor: actor) do
          {:ok, %Gateway{} = gateway} ->
            heartbeat_gateway(gateway, actor)

          {:error, reason} ->
            if not_found_error?(reason) do
              register_gateway(gateway_id, attrs, actor)
            else
              {:error, reason}
            end
        end
    end
  end

  defp normalized_gateway_id(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalized_gateway_id(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalized_gateway_id()

  defp normalized_gateway_id(_value), do: nil

  defp heartbeat_gateway(gateway, actor) do
    gateway
    |> Ash.Changeset.for_update(:heartbeat, %{is_healthy: true})
    |> Ash.update(actor: actor)
    |> case do
      {:ok, _gateway} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp register_gateway(gateway_id, attrs, actor) do
    register_attrs =
      compact_attrs(%{
        id: gateway_id,
        component_id: gateway_id,
        registration_source: "agent-gateway-auto",
        created_by: "agent_gateway_sync",
        metadata: gateway_metadata(attrs)
      })

    Gateway
    |> Ash.Changeset.for_create(:register, register_attrs)
    |> Ash.create(actor: actor)
    |> case do
      {:ok, _gateway} ->
        :ok

      {:error, reason} ->
        if unique_gateway_conflict?(reason) do
          case Gateway.get_by_id(gateway_id, actor: actor) do
            {:ok, %Gateway{} = gateway} -> heartbeat_gateway(gateway, actor)
            {:error, lookup_reason} -> {:error, lookup_reason}
          end
        else
          {:error, reason}
        end
    end
  end

  defp upsert_agent_record(agent_id, attrs, actor) do
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

  defp heartbeat_agent_record_by_id(agent_id, attrs, actor) do
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

  defp reconcile_agent_release_after_version_sync(agent_id, attrs, actor) do
    if present_string?(Map.get(attrs, :version)) do
      AgentReleaseManager.reconcile_agent(agent_id, actor: actor)
    end

    :ok
  end

  defp gateway_metadata(attrs) do
    attrs
    |> Map.get(:metadata, %{})
    |> case do
      %{} = metadata ->
        %{
          domain: metadata_value(metadata, :domain),
          partition_id: metadata_value(metadata, :partition_id),
          source: "agent_hello"
        }

      _ ->
        %{source: "agent_hello"}
    end
    |> compact_attrs()
  end

  defp update_agent(agent, attrs, actor) do
    update_attrs =
      attrs
      |> Map.take([
        :name,
        :capabilities,
        :host,
        :ip,
        :port,
        :spiffe_identity,
        :metadata,
        :gateway_id,
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
        :ip,
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
    if agent.status != :connected or agent.is_healthy != true do
      restore_connected_agent(agent, actor)
    end

    heartbeat_attrs =
      attrs
      |> Map.take([:capabilities, :is_healthy, :config_source, :gateway_id, :ip])
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

  defp restore_connected_agent(agent, actor) do
    attrs =
      agent
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
        :ip,
        :port,
        :spiffe_identity,
        :metadata
      ])
      |> compact_attrs()

    Agent
    |> Ash.Changeset.for_create(:register_connected, attrs)
    |> Ash.create(actor: actor)
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

  defp stale_record_error?(%Invalid{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
  end

  defp stale_record_error?(_), do: false

  # Device declares ocsf_devices_unique_active_ip_idx as a unique index name,
  # so collisions surface as Invalid (an `ip` "has already been taken" error)
  # rather than Unknown wrapping Ecto.ConstraintError. Match both shapes so
  # adopt/release keeps working.
  defp active_ip_unique_conflict?(%Invalid{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &ip_taken_error?/1) or index_conflict?(errors)
  end

  defp active_ip_unique_conflict?(reason), do: index_conflict?(reason)

  defp ip_taken_error?(%Ash.Error.Changes.InvalidChanges{} = error) do
    fields = List.wrap(Map.get(error, :fields, [])) ++ List.wrap(Map.get(error, :field))
    message = to_string(Map.get(error, :message, ""))

    :ip in fields and String.contains?(message, "has already been taken")
  end

  defp ip_taken_error?(%Ash.Error.Changes.InvalidAttribute{} = error) do
    Map.get(error, :field) == :ip and
      String.contains?(to_string(Map.get(error, :message, "")), "has already been taken")
  end

  defp ip_taken_error?(_), do: false

  defp index_conflict?(reason) do
    reason
    |> inspect()
    |> String.contains?("ocsf_devices_unique_active_ip_idx")
  end

  defp unique_gateway_conflict?(reason) do
    reason
    |> inspect()
    |> String.contains?(["gateways_unique_gateway_id_index", "gateways_pkey"])
  end

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, to_string(key))
  end

  defp metadata_value(_metadata, _key), do: nil

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp agent_source_ip(attrs) do
    Enum.find_value([:source_ip, :ip, :host], fn key ->
      case Map.get(attrs, key) do
        value when is_binary(value) ->
          value = String.trim(value)
          if value == "", do: nil, else: value

        _ ->
          nil
      end
    end)
  end

  defp force_gateway_sync_update(device_uid, update_attrs, actor) do
    query =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: true})
      |> Ash.Query.filter(uid == ^device_uid)

    case Ash.bulk_update(query, :gateway_sync, update_attrs,
           actor: actor,
           return_errors?: true,
           return_records?: false
         ) do
      %Ash.BulkResult{status: :success} ->
        Logger.debug("Force-updated device #{device_uid} via gateway_sync")
        :ok

      %Ash.BulkResult{status: :partial_success, errors: errors} ->
        {:error, List.first(errors) || :partial_failure}

      %Ash.BulkResult{status: :error, errors: errors} ->
        {:error, List.first(errors) || :bulk_update_failed}
    end
  end

  defp not_found_error?(%NotFound{}), do: true

  defp not_found_error?(%Invalid{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &match?(%NotFound{}, &1))
  end

  defp not_found_error?(_error), do: false

  defp validate_broker_request(grant, request) do
    with :ok <- validate_agent_bound_grant(grant, request),
         :ok <- validate_agent_resolution_location(grant),
         :ok <- validate_optional_match(grant, request, :secret_ref, :credential_secret_ref),
         :ok <- validate_optional_match(grant, request, :consumer_kind, :consumer_kind),
         :ok <- validate_optional_match(grant, request, :consumer_id, :consumer_id) do
      validate_optional_match(grant, request, :purpose, :purpose)
    end
  end

  defp validate_agent_bound_grant(grant, request) do
    expected_agent_id = string_value(map_value(request, :agent_id))

    case string_value(Map.get(grant, :agent_id)) do
      ^expected_agent_id -> :ok
      _ -> {:error, {:grant_scope_mismatch, :agent_id}}
    end
  end

  defp validate_agent_resolution_location(grant) do
    if grant.resolution_location in [:agent, :hybrid] do
      :ok
    else
      {:error, {:grant_scope_mismatch, :resolution_location}}
    end
  end

  defp validate_optional_match(grant, request, grant_key, request_key) do
    expected = string_value(map_value(request, request_key))

    if expected == "" do
      :ok
    else
      actual = grant |> Map.get(grant_key) |> string_value()

      if actual == expected do
        :ok
      else
        {:error, {:grant_scope_mismatch, request_key}}
      end
    end
  end

  defp resolve_broker_grant_material(%CredentialBrokerGrant{} = grant, actor, agent_id) do
    result =
      SecretBroker.resolve_with_grant(grant,
        actor: actor,
        audit?: true,
        agent_id: agent_id,
        resolution_location: grant.resolution_location
      )

    case result do
      {:error, :grant_expired} ->
        expire_broker_grant(grant, actor)
        result

      _ ->
        result
    end
  end

  defp expire_broker_grant(%CredentialBrokerGrant{status: status} = grant, actor)
       when status in [:issued, :active] do
    grant
    |> Ash.Changeset.for_update(:expire, %{}, actor: actor)
    |> Ash.update(actor: actor)
    |> case do
      {:ok, _grant} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to expire credential broker grant after TTL rejection",
          [grant_id: grant.id] ++ SafeFailureEvidence.log_metadata(reason)
        )

        :ok
    end
  end

  defp expire_broker_grant(_grant, _actor), do: :ok

  defp credential_material(resolved) do
    value = string_value(Map.get(resolved, :value))
    fields = credential_material_fields(value, Map.get(resolved, :secret))

    %{
      value: value,
      fields: fields,
      source_type: string_value(Map.get(resolved, :source_type)),
      lease_expires_at_unix: unix_seconds(Map.get(resolved, :lease_expires_at)),
      cache_status: string_value(Map.get(resolved, :cache_status))
    }
  end

  defp credential_material_fields(value, secret) do
    base = if value == "", do: %{}, else: %{"value" => value}

    fields =
      case Jason.decode(value) do
        {:ok, %{} = decoded} ->
          Enum.reduce(decoded, base, fn
            {key, field_value}, acc when is_binary(field_value) ->
              Map.put(acc, to_string(key), field_value)

            {key, field_value}, acc when is_number(field_value) or is_boolean(field_value) ->
              Map.put(acc, to_string(key), to_string(field_value))

            _other, acc ->
              acc
          end)

        _ ->
          base
      end

    case {map_value(secret, :credential_kind), string_value(map_value(secret, :username))} do
      {kind, username}
      when kind in [:username_password, "username_password"] and username != "" ->
        fields
        |> Map.put_new("username", username)
        |> Map.put_new("password", value)

      _ ->
        fields
    end
  end

  defp unix_seconds(%DateTime{} = value), do: DateTime.to_unix(value)
  defp unix_seconds(_value), do: 0

  defp present_required(value, field) do
    if value == "" do
      {:error, {:missing_required_field, field}}
    else
      :ok
    end
  end

  defp map_value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp map_value(_map, _key), do: nil

  defp string_value(nil), do: ""
  defp string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp string_value(value) when is_binary(value), do: String.trim(value)
  defp string_value(value), do: value |> to_string() |> String.trim()
end
