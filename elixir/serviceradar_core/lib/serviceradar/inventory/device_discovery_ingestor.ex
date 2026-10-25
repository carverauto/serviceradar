defmodule ServiceRadar.Inventory.DeviceDiscoveryIngestor do
  @moduledoc """
  Ingests plugin-emitted device discovery/enrichment records into inventory.

  Plugins emit `serviceradar.device_discovery.v1` envelopes inside the normal
  `serviceradar.plugin_result.v1` payload. This module translates those records
  into the existing SyncIngestor update contract so discovered devices reconcile
  into `platform.ocsf_devices` and device identifiers.

  ## Integration id format

  When a record does not carry an explicit `integration_id`, one is minted as:

      <source>:<kind>:<key>

  where `<source>` is the discovery envelope source (fallback `"plugin"`),
  `<kind>` is the device type/kind/role (fallback `"device"`), and `<key>` is
  the most stable available identity component, preferred in this order:

  1. serial number (`serial`/`serial_number`/`serialNumber`)
  2. stable hardware id (`hardware_id`, `hw_id`, `machine_id`, `chassis_id`,
     `chassis_serial`, `asset_tag`, `uuid`, `hardware_uuid` and camelCase
     variants)
  3. hostname (`hostname`/`name`/`host`)
  4. MAC address — only when no other key exists. The MAC component is the
     first valid MAC normalized via `IdentityReconciler.normalize_mac/1`
     (uppercase, separator-free, 12 hex chars) so payload format variations
     (`aa:bb…`, `AA-BB…`, multi-value blobs) cannot rotate the id.

  A MAC is never used as the id component when a more stable key exists:
  rotating/randomized MACs would otherwise rotate the `integration_id` and
  mint a new duplicate device per rotation.
  """

  alias ServiceRadar.Automation.Ansible.AwxInventoryObservationFence
  alias ServiceRadar.Automation.Ansible.AwxMembershipReconciler
  alias ServiceRadar.Inventory.Availability.Sources
  alias ServiceRadar.Inventory.Availability.SyncEvidence
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceClaimPolicy
  alias ServiceRadar.Inventory.DeviceSourceObservationIngestor
  alias ServiceRadar.Inventory.HypervisorEnrichmentIngestor
  alias ServiceRadar.Inventory.Identity.GuestAddress
  alias ServiceRadar.Inventory.Identity.SourceAuthorityGuard
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Repo

  require Logger

  @schema "serviceradar.device_discovery.v1"

  @spec supports?(map() | list(), map()) :: boolean()
  def supports?(payload, status \\ %{})

  def supports?(payload, status) when is_list(payload) do
    Enum.any?(payload, &supports?(&1, status))
  end

  def supports?(payload, _status) when is_map(payload) do
    payload
    |> discovery_envelopes()
    |> Enum.any?()
  end

  def supports?(_payload, _status), do: false

  @spec ingest(map() | list(), map(), keyword()) :: :ok | {:error, term()}
  def ingest(payload, status, opts \\ [])

  def ingest(payload, status, opts) when is_list(payload) do
    payload
    |> Enum.find(&is_map/1)
    |> case do
      nil -> :ok
      entry -> ingest(entry, status, opts)
    end
  end

  def ingest(payload, status, opts) when is_map(payload) do
    with {:ok, aggregates} <- AwxMembershipReconciler.parse(payload) do
      ingest_with_membership_ordering(aggregates, payload, status, opts)
    end
  rescue
    e ->
      Logger.warning("Plugin device discovery ingest failed: #{Exception.message(e)}")
      {:error, e}
  end

  def ingest(_payload, _status, _opts), do: :ok

  defp ingest_with_membership_ordering([], payload, status, opts),
    do: ingest_payload(payload, status, opts, false)

  defp ingest_with_membership_ordering(aggregates, payload, status, opts) do
    transaction =
      Keyword.get(opts, :membership_transaction, &AwxInventoryObservationFence.with_locks/2)

    emit_state_events =
      Keyword.get(opts, :emit_state_events, &SyncIngestor.emit_committed_state_events/1)

    with {:ok, %{notifications: notifications, state_events: state_events}} <-
           transaction.(aggregates, fn -> ingest_payload(payload, status, opts, true) end) do
      :ok = emit_state_events.(state_events)
      AwxMembershipReconciler.notify_committed(notifications, opts)
    end
  end

  defp ingest_payload(payload, status, opts, serialize_awx?) do
    actor = Keyword.fetch!(opts, :actor)
    device_sync = Keyword.get(opts, :device_sync, &sync_device_inventory/2)
    membership_sync = Keyword.get(opts, :membership_sync, &sync_awx_memberships/2)

    membership_preflight =
      Keyword.get(opts, :membership_preflight, &preflight_awx_memberships/2)

    source_observation_sync =
      Keyword.get(opts, :source_observation_sync, &sync_source_observations/3)

    source_observation_preflight =
      Keyword.get(opts, :source_observation_preflight, &preflight_source_observations/3)

    discovery_batches =
      payload
      |> discovery_envelopes()
      |> Enum.map(fn envelope ->
        {envelope, device_updates(envelope, payload, status)}
      end)

    context = source_observation_context(status, actor)
    membership_context = %{actor: actor, return_notifications?: serialize_awx?}

    device_context = %{
      actor: actor,
      serialize_awx?: serialize_awx?,
      availability_evidence: availability_observation(status)
    }

    with :ok <- membership_preflight.(payload, %{actor: actor}),
         {:ok, process_batches} <-
           preflight_source_observation_batches(
             discovery_batches,
             context,
             source_observation_preflight
           ),
         updates = Enum.flat_map(process_batches, fn {_envelope, batch} -> batch end),
         {:ok, state_events} <- sync_devices_if_present(updates, device_context, device_sync),
         :ok <-
           sync_source_observation_batches(
             process_batches,
             context,
             source_observation_sync
           ) do
      case membership_sync.(payload, membership_context) do
        {:ok, notifications} when serialize_awx? and is_list(notifications) ->
          {:ok, %{notifications: notifications, state_events: state_events}}

        :ok when serialize_awx? ->
          {:ok, %{notifications: [], state_events: state_events}}

        result ->
          result
      end
    end
  end

  defp sync_device_inventory(updates, context) when is_list(updates) do
    updates = enrich_and_reconcile_awx_updates(updates, context.actor)
    opts = [actor: context.actor, availability_evidence: context.availability_evidence]

    opts =
      if context.serialize_awx?,
        do: Keyword.merge(opts, batch_concurrency: 1, defer_state_events?: true),
        else: opts

    SyncIngestor.ingest_updates(updates, opts)
  end

  # A discovery record's is_available is evidence registered under the reporting
  # plugin, whose approved manifest declares its authority class
  # (Availability.Sources). The plugin is the one the agent's status names; a record
  # without is_available, or a result that names no plugin, carries no evidence.
  @doc false
  def availability_observation(status) do
    case status_field(status, :plugin_id) do
      nil ->
        &SyncEvidence.default_observation/1

      plugin_id ->
        source_kind = Sources.plugin_kind(plugin_id)
        assignment_id = status_field(status, :assignment_id)
        agent_id = status_field(status, :agent_id)

        fn
          %{is_available: available?} = update when is_boolean(available?) ->
            %{
              source_kind: source_kind,
              source_instance: assignment_id,
              reporter_agent_id: agent_id,
              state: if(available?, do: :up, else: :down),
              observed_at: SyncEvidence.observed_at(update)
            }

          _update ->
            nil
        end
    end
  end

  defp status_field(status, key) when is_map(status) do
    labels = Map.get(status, :labels) || Map.get(status, "labels") || %{}

    Enum.find_value(
      [Map.get(status, key), Map.get(status, to_string(key)), label(labels, key)],
      fn
        value when is_binary(value) -> blank_to_nil(String.trim(value))
        _value -> nil
      end
    )
  end

  defp status_field(_status, _key), do: nil

  defp label(labels, key) when is_map(labels),
    do: Map.get(labels, key) || Map.get(labels, to_string(key))

  defp label(_labels, _key), do: nil

  defp sync_devices_if_present([], _context, _device_sync), do: {:ok, []}

  defp sync_devices_if_present(updates, context, device_sync) do
    case device_sync.(updates, context) do
      :ok -> {:ok, []}
      {:ok, effects} when context.serialize_awx? and is_list(effects) -> {:ok, effects}
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_device_sync_result, other}}
    end
  end

  defp sync_source_observations(envelope, updates, context) do
    DeviceSourceObservationIngestor.ingest(envelope, updates, context)
  end

  defp preflight_source_observations(envelope, updates, context) do
    DeviceSourceObservationIngestor.preflight(envelope, updates, context)
  end

  defp source_observation_context(status, actor) do
    %{
      actor: actor,
      partition: partition_value(status)
    }
  end

  defp preflight_source_observation_batches(batches, context, preflight) do
    batches
    |> Enum.reduce_while({:ok, []}, fn {envelope, updates} = batch, {:ok, acc} ->
      case preflight.(envelope, updates, context) do
        :ok -> {:cont, {:ok, [batch | acc]}}
        {:ok, :process} -> {:cont, {:ok, [batch | acc]}}
        {:ok, :idempotent} -> {:cont, {:ok, acc}}
        {:error, _} = error -> {:halt, error}
        _other -> {:halt, {:error, :invalid_source_observation_preflight_result}}
      end
    end)
    |> case do
      {:ok, process_batches} -> {:ok, Enum.reverse(process_batches)}
      error -> error
    end
  end

  defp sync_source_observation_batches(batches, context, source_observation_sync) do
    Enum.reduce_while(batches, :ok, fn {envelope, updates}, :ok ->
      case source_observation_sync.(envelope, updates, context) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
        _other -> {:halt, {:error, :invalid_source_observation_result}}
      end
    end)
  end

  defp sync_awx_memberships(payload, context) do
    AwxMembershipReconciler.reconcile(payload,
      actor: context.actor,
      return_notifications?: context.return_notifications?
    )
  end

  defp preflight_awx_memberships(payload, _context) do
    AwxMembershipReconciler.preflight(payload)
  end

  defp discovery_envelopes(payload) do
    direct =
      if discovery_envelope?(payload) do
        [payload]
      else
        []
      end

    nested =
      payload
      |> list_value(["device_discovery", "deviceDiscovery", "discoveries"])
      |> Enum.filter(&discovery_envelope?/1)

    direct ++ nested
  end

  defp discovery_envelope?(value) when is_map(value) do
    string_value(value, ["schema"]) == @schema
  end

  defp discovery_envelope?(_value), do: false

  defp device_updates(envelope, payload, status) do
    envelope
    |> list_value(["devices", "assets"])
    |> Enum.map(&device_update(&1, envelope, payload, status))
    |> Enum.reject(&is_nil/1)
  end

  defp device_update(device, envelope, payload, status) when is_map(device) do
    metadata = device_metadata(device, envelope, payload)

    mac =
      string_value(device, ["mac", "mac_address", "macAddress"]) ||
        first_metadata_mac(metadata)

    update = %{
      "device_id" => string_value(device, ["device_id", "deviceId", "uid"]),
      "ip" => device_ip(device),
      "mac" => mac,
      "hostname" => string_value(device, ["hostname", "name", "host"]),
      "partition" => partition_value(status),
      "source" =>
        string_value(envelope, ["source"]) ||
          string_value(payload, ["source"]) ||
          "plugin_device_discovery",
      "is_available" => bool_value(device, ["is_available", "isAvailable"]),
      "is_managed" => managed_value(device, metadata),
      "os" => map_value(device, ["os"]) || map_value(metadata, ["os"]),
      "hw_info" => map_value(device, ["hw_info"]) || map_value(metadata, ["hw_info"]),
      "owner" => map_value(device, ["owner"]) || map_value(metadata, ["owner"]),
      "metadata" => metadata,
      "tags" => device_tags(device),
      "source_instance" =>
        string_value(map_value(envelope, ["metadata"]) || %{}, ["source_instance"]) ||
          string_value(envelope, ["source_instance"]),
      "facts" => discovery_facts(device, metadata)
    }

    if strong_enough?(update) do
      update
    end
  end

  defp device_update(_device, _envelope, _payload, _status), do: nil

  defp first_metadata_mac(%{"mac_addresses" => [mac | _]}) when is_binary(mac), do: mac
  defp first_metadata_mac(_metadata), do: nil

  defp strong_enough?(update) do
    present?(update["device_id"]) or present?(update["ip"]) or present?(update["mac"]) or
      present?(get_in(update, ["metadata", "integration_id"]))
  end

  # Resolve the device's canonical IP. Most plugins set `ip` directly. The AWX
  # inventory-sync plugin extracts `ansible_host` from the host's variables and
  # stamps it on `metadata.awx.ansible_host`; it only copies that value onto
  # `ip` when it looks like an address, and JSON may omit a blank `ip`. When
  # the direct `ip` is blank we recover a valid-IP `ansible_host` from AWX
  # metadata so the device reconciles with the same host seen by
  # sweep/agent/proxmox.
  #
  # Current plugin payloads carry `ansible_host` as a sibling of the join keys
  # and do not emit the secret-capable `variables` blob. Older in-flight
  # payloads still wrap it in stringified `variables`. A host whose
  # `ansible_host` is a DNS name stays IP-less — we never fabricate an address.
  defp device_ip(device) do
    case string_value(device, ["ip", "ip_address", "ipAddress"]) do
      ip when is_binary(ip) -> ip
      _ -> awx_ansible_host_ip(device)
    end
  end

  defp awx_ansible_host_ip(device) do
    candidates = [
      awx_metadata(device),
      map_value(device, ["metadata"]),
      device
    ]

    host =
      Enum.find_value(candidates, fn
        map when is_map(map) -> awx_ansible_host_value(map)
        _ -> nil
      end)

    if is_binary(host) and valid_ip?(host), do: host
  end

  defp awx_ansible_host_value(awx) do
    case string_value(awx, ["ansible_host", "ansible_ssh_host"]) do
      host when is_binary(host) ->
        host

      _ ->
        case Map.get(awx, "variables") || Map.get(awx, :variables) do
          raw when is_binary(raw) -> ansible_host_from_variables(raw)
          raw when is_map(raw) -> string_value(raw, ["ansible_host", "ansible_ssh_host"])
          _ -> nil
        end
    end
  end

  defp awx_metadata(device) do
    case map_value(device, ["metadata"]) do
      metadata when is_map(metadata) -> map_value(metadata, ["awx"])
      _ -> nil
    end
  end

  # AWX returns a host's `variables` as a stringified JSON object or YAML lines.
  # Decode it and read `ansible_host` (or the legacy `ansible_ssh_host`).
  defp ansible_host_from_variables(raw) do
    trimmed = String.trim(raw)

    if trimmed == "" do
      nil
    else
      decoded = HypervisorEnrichmentIngestor.parse_awx_variables(trimmed)
      string_value(decoded, ["ansible_host", "ansible_ssh_host"])
    end
  end

  defp valid_ip?(value) when is_binary(value) do
    case value |> String.trim() |> String.to_charlist() |> :inet.parse_address() do
      {:ok, _address} -> true
      _ -> false
    end
  end

  defp valid_ip?(_value), do: false

  defp discovery_facts(device, metadata) do
    map_value(device, ["facts"]) ||
      map_value(device, ["canonical_facts"]) ||
      map_value(metadata, ["facts"]) ||
      map_value(metadata, ["canonical_facts"]) ||
      %{}
  end

  defp device_metadata(device, envelope, payload) do
    location = map_value(device, ["location"])
    envelope_metadata = map_value(envelope, ["metadata"]) || %{}

    base =
      device
      |> map_value(["metadata"])
      |> Kernel.||(%{})
      |> stringify_map()
      |> enrich_awx_proxmox_metadata(device, envelope)

    base
    |> maybe_put_new("integration_type", string_value(envelope, ["source"]) || "plugin")
    |> maybe_put_new("integration_id", integration_id(device, envelope))
    |> maybe_put("plugin_discovery_schema", @schema)
    |> maybe_put("plugin_discovery_source", string_value(envelope, ["source"]))
    |> maybe_put("plugin_inventory_snapshot", Map.get(envelope_metadata, "snapshot_complete"))
    |> maybe_put("collection_id", string_value(envelope, ["collection_id", "collectionId"]))
    |> maybe_put("reference_hash", string_value(envelope, ["reference_hash", "referenceHash"]))
    |> maybe_put("vendor_name", string_value(device, ["vendor_name", "vendorName", "vendor"]))
    |> maybe_put("model", string_value(device, ["model"]))
    |> maybe_put(
      "serial_number",
      string_value(device, ["serial", "serial_number", "serialNumber"])
    )
    |> maybe_put("device_type", string_value(device, ["type", "device_type", "deviceType"]))
    |> maybe_put("device_role", string_value(device, ["role", "device_role", "deviceRole"]))
    |> maybe_put("status", string_value(device, ["status"]))
    |> maybe_put("site_code", string_value(location, ["site_code", "siteCode", "iata"]))
    |> maybe_put("site_name", string_value(location, ["site_name", "siteName", "name"]))
    |> maybe_put("latitude", number_value(location, ["latitude", "lat"]))
    |> maybe_put("longitude", number_value(location, ["longitude", "lon", "lng"]))
    |> maybe_put("plugin_result_summary", string_value(payload, ["summary"]))
    |> maybe_put("os_name", string_value(device, ["os_name", "osName"]) || os_field(base, "name"))
    |> maybe_put(
      "os_version",
      string_value(device, ["os_version", "osVersion"]) || os_field(base, "version")
    )
    |> maybe_put(
      "firmware_version",
      string_value(device, ["firmware_version", "firmwareVersion"]) ||
        string_value(base, ["firmware_version"])
    )
    |> maybe_put("sys_contact", string_value(device, ["contact"]) || owner_name(base))
    |> maybe_put(
      "is_managed",
      bool_value(device, ["is_managed", "isManaged"]) || bool_value(base, ["is_managed"])
    )
    |> maybe_put(
      "geographical_location",
      string_value(location, ["geographical_location"]) ||
        string_value(base, ["geographical_location"]) ||
        string_value(map_value(base, ["source_metadata"]) || %{}, ["geographical_location"])
    )
  end

  defp os_field(metadata, key) when is_map(metadata) do
    case map_value(metadata, ["os"]) do
      os when is_map(os) -> string_value(os, [key])
      _ -> string_value(metadata, [key])
    end
  end

  defp os_field(_metadata, _key), do: nil

  defp owner_name(metadata) when is_map(metadata) do
    case map_value(metadata, ["owner"]) do
      owner when is_map(owner) -> string_value(owner, ["name"])
      _ -> nil
    end
  end

  defp owner_name(_metadata), do: nil

  defp managed_value(device, metadata) do
    case bool_value(device, ["is_managed", "isManaged"]) do
      nil ->
        case bool_value(metadata, ["is_managed", "isManaged"]) do
          nil -> managed_from_status(string_value(device, ["status"]))
          value -> value
        end

      value ->
        value
    end
  end

  defp managed_from_status(status) when is_binary(status) do
    case String.downcase(String.trim(status)) do
      "managed" -> true
      "unmanaged" -> false
      _ -> nil
    end
  end

  defp managed_from_status(_status), do: nil

  defp integration_id(device, envelope) do
    metadata = map_value(device, ["metadata"]) || %{}

    string_value(metadata, ["integration_id", "integrationId"]) ||
      string_value(device, ["integration_id", "integrationId"]) ||
      prefixed_identifier(envelope, device)
  end

  # Key preference: serial > stable hardware id > hostname > normalized MAC.
  # MAC is the last resort because rotating/randomized MACs must not rotate
  # the integration_id (see moduledoc).
  defp prefixed_identifier(envelope, device) do
    source = string_value(envelope, ["source"]) || "plugin"
    kind = string_value(device, ["type", "kind", "role"]) || "device"

    value =
      first_present([
        string_value(device, ["serial", "serial_number", "serialNumber"]),
        stable_hardware_id(device),
        string_value(device, ["hostname", "name", "host"]),
        IdentityReconciler.normalize_mac(
          string_value(device, ["mac", "mac_address", "macAddress"])
        )
      ])

    if present?(value), do: "#{source}:#{kind}:#{value}"
  end

  defp stable_hardware_id(device) do
    string_value(device, [
      "hardware_id",
      "hardwareId",
      "hw_id",
      "hwId",
      "machine_id",
      "machineId",
      "chassis_id",
      "chassisId",
      "chassis_serial",
      "chassisSerial",
      "asset_tag",
      "assetTag",
      "uuid",
      "hardware_uuid",
      "hardwareUuid"
    ])
  end

  defp device_tags(device) do
    device
    |> map_value(["labels", "tags"])
    |> stringify_map()
  end

  defp partition_value(status) do
    case status[:partition] || status["partition"] do
      value when is_binary(value) and value != "" -> value
      _ -> "default"
    end
  end

  defp list_value(map, keys) when is_map(map) do
    case value_for(map, keys) do
      value when is_list(value) -> Enum.filter(value, &is_map/1)
      _ -> []
    end
  end

  defp list_value(_map, _keys), do: []

  defp map_value(map, keys) when is_map(map) do
    case value_for(map, keys) do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  defp map_value(_map, _keys), do: nil

  defp string_value(map, keys) when is_map(map) do
    case value_for(map, keys) do
      nil ->
        nil

      value when is_binary(value) ->
        value |> String.trim() |> blank_to_nil()

      value when is_atom(value) ->
        value |> Atom.to_string() |> String.trim() |> blank_to_nil()

      value when is_integer(value) ->
        Integer.to_string(value)

      value when is_float(value) ->
        Float.to_string(value)

      _ ->
        nil
    end
  end

  defp string_value(_map, _keys), do: nil

  defp bool_value(map, keys) when is_map(map) do
    case value_for(map, keys) do
      value when is_boolean(value) ->
        value

      value when is_binary(value) ->
        String.downcase(String.trim(value)) in ["true", "up", "ok", "online"]

      _ ->
        nil
    end
  end

  defp bool_value(_map, _keys), do: nil

  defp number_value(map, keys) when is_map(map) do
    case value_for(map, keys) do
      value when is_integer(value) ->
        value / 1

      value when is_float(value) ->
        value

      value when is_binary(value) ->
        case Float.parse(String.trim(value)) do
          {parsed, _rest} -> parsed
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp number_value(_map, _keys), do: nil

  defp value_for(map, keys) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key) || Map.get(map, to_string(key))
    end)
  end

  defp stringify_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), value)
    end)
  end

  defp stringify_map(_map), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_new(map, _key, nil), do: map
  defp maybe_put_new(map, _key, ""), do: map
  defp maybe_put_new(map, key, value), do: Map.put_new(map, key, value)

  defp first_present(values), do: Enum.find(values, &present?/1)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp enrich_awx_proxmox_metadata(base, device, envelope) when is_map(base) and is_map(device) do
    merged_input = Map.merge(stringify_map(device), base)

    if awx_context?(base, merged_input, envelope) do
      case HypervisorEnrichmentIngestor.extract_awx_proxmox_info(merged_input) do
        nil -> base
        info -> apply_awx_proxmox_info(base, info)
      end
    else
      base
    end
  end

  defp enrich_awx_proxmox_metadata(base, _device, _envelope), do: base

  defp awx_context?(base, merged_input, envelope) do
    envelope_source = String.downcase(to_string(string_value(envelope || %{}, ["source"]) || ""))

    Map.has_key?(base, "awx") or
      envelope_source == "awx" or
      String.downcase(to_string(Map.get(base, "integration_type") || "")) == "awx" or
      String.downcase(to_string(Map.get(merged_input, "source") || "")) == "awx" or
      Enum.any?(
        [
          "proxmox_vmid",
          "proxmox_node",
          "proxmox_vmtype",
          "ansible_host",
          "ansible_ssh_host",
          "variables"
        ],
        &present?(Map.get(merged_input, &1))
      )
  end

  defp apply_awx_proxmox_info(base, info) do
    awx =
      case Map.get(base, "awx") do
        map when is_map(map) -> stringify_map(map)
        _ -> %{}
      end

    updated_awx =
      awx
      |> maybe_put_new("proxmox_vmid", info.vmid)
      |> maybe_put_new("proxmox_node", info.node)
      |> maybe_put_new("proxmox_vmtype", info.vmtype)
      |> maybe_put_new("ansible_host", info.ip)

    base =
      if map_size(updated_awx) > 0 do
        Map.put(base, "awx", updated_awx)
      else
        base
      end

    merge_awx_proxmox_macs(base, info.macs)
  end

  defp merge_awx_proxmox_macs(base, []), do: base

  defp merge_awx_proxmox_macs(base, macs) when is_list(macs) do
    existing_macs =
      case Map.get(base, "mac_addresses") do
        list when is_list(list) -> list
        _ -> []
      end

    combined_macs =
      (existing_macs ++ macs)
      |> Enum.map(&IdentityReconciler.normalize_mac/1)
      |> Enum.filter(&present?/1)
      |> Enum.uniq()

    if combined_macs == [] do
      base
    else
      Map.put(base, "mac_addresses", combined_macs)
    end
  end

  defp awx_update?(update) when is_map(update) do
    source = String.downcase(to_string(Map.get(update, "source") || ""))
    metadata = Map.get(update, "metadata") || %{}
    integration_type = String.downcase(to_string(Map.get(metadata, "integration_type") || ""))

    source == "awx" or integration_type == "awx" or is_map(Map.get(metadata, "awx"))
  end

  defp awx_update?(_update), do: false

  defp enrich_and_reconcile_awx_updates(updates, actor) when is_list(updates) do
    if Enum.any?(updates, &awx_update?/1) do
      do_enrich_and_reconcile_awx_updates(updates, actor)
    else
      updates
    end
  rescue
    e ->
      Logger.warning(
        "DeviceDiscoveryIngestor: AWX/Proxmox enrichment fallback after error: #{Exception.message(e)}"
      )

      updates
  end

  defp do_enrich_and_reconcile_awx_updates(updates, actor) do
    vmids =
      updates
      |> Enum.filter(&awx_update?/1)
      |> Enum.map(&awx_update_vmid/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    guests_by_vmid = query_virtualization_guests_by_vmid(vmids)

    enriched_updates =
      Enum.map(updates, fn update ->
        if awx_update?(update) do
          attach_matching_virtualization_guest(update, guests_by_vmid)
        else
          {update, nil}
        end
      end)

    reconcile_awx_device_links(enriched_updates, actor)
  end

  defp awx_update_vmid(update) do
    metadata = Map.get(update, "metadata") || %{}

    case HypervisorEnrichmentIngestor.extract_awx_proxmox_info(metadata, Map.get(update, "ip")) do
      %{vmid: vmid} when is_integer(vmid) and vmid > 0 -> vmid
      _ -> nil
    end
  end

  defp query_virtualization_guests_by_vmid([]), do: %{}

  defp query_virtualization_guests_by_vmid(vmids) do
    sql = """
    SELECT g.provider_ref,
           g.vmid,
           COALESCE(g.metadata->>'node', h.name) AS node_name,
           g.device_uid,
           g.status,
           COALESCE(
             ARRAY(
               SELECT n.mac_address
               FROM platform.virtualization_network_interfaces n
               WHERE n.guest_id = g.id
                 AND n.mac_address IS NOT NULL
                 AND btrim(n.mac_address) <> ''
                 AND lower(COALESCE(n.name, '')) <> 'lo'
             ),
             ARRAY[]::text[]
           ) AS nic_macs,
           COALESCE(
             ARRAY(
               SELECT unnest(n.ip_addresses)
               FROM platform.virtualization_network_interfaces n
               WHERE n.guest_id = g.id
             ),
             ARRAY[]::text[]
           ) AS nic_ips
    FROM platform.virtualization_guests g
    LEFT JOIN platform.virtualization_hosts h ON h.id = g.host_id
    WHERE g.vmid = ANY($1::integer[])
    """

    case Repo.query(sql, [vmids]) do
      {:ok, %{rows: rows}} ->
        Enum.reduce(rows, %{}, fn [
                                    provider_ref,
                                    vmid,
                                    node_name,
                                    device_uid,
                                    status,
                                    nic_macs,
                                    nic_ips
                                  ],
                                  acc ->
          macs =
            nic_macs
            |> List.wrap()
            |> Enum.map(&IdentityReconciler.normalize_mac/1)
            |> Enum.filter(&present?/1)
            |> Enum.uniq()

          ips =
            nic_ips
            |> List.wrap()
            |> Enum.map(fn raw ->
              raw |> to_string() |> String.split("/", parts: 2) |> hd() |> String.trim()
            end)
            |> Enum.filter(&valid_ip?/1)
            |> Enum.reject(&GuestAddress.host_internal_address?(%{name: "eth0"}, &1))
            |> Enum.uniq()

          entry = %{
            provider_ref: provider_ref,
            vmid: vmid,
            node: node_name,
            device_uid: device_uid,
            status: status,
            macs: macs,
            ips: ips
          }

          Map.update(acc, vmid, [entry], &[entry | &1])
        end)

      _ ->
        %{}
    end
  end

  defp attach_matching_virtualization_guest(update, guests_by_vmid) do
    metadata = Map.get(update, "metadata") || %{}
    info = HypervisorEnrichmentIngestor.extract_awx_proxmox_info(metadata, Map.get(update, "ip"))

    case info do
      %{vmid: vmid} when is_integer(vmid) and vmid > 0 ->
        candidates = Map.get(guests_by_vmid, vmid, [])

        matching =
          Enum.filter(candidates, fn guest ->
            is_nil(info.node) or is_nil(guest.node) or
              String.downcase(to_string(info.node)) == String.downcase(to_string(guest.node))
          end)

        case select_matching_guest(matching, update, info) do
          nil ->
            {update, nil}

          guest ->
            existing_macs =
              case Map.get(metadata, "mac_addresses") do
                list when is_list(list) -> list
                _ -> []
              end

            macs =
              ([Map.get(update, "mac") | existing_macs] ++ guest.macs)
              |> Enum.map(&IdentityReconciler.normalize_mac/1)
              |> Enum.filter(&present?/1)
              |> Enum.uniq()

            ip = Map.get(update, "ip") || List.first(guest.ips)

            updated_metadata =
              if macs == [] do
                metadata
              else
                Map.put(metadata, "mac_addresses", macs)
              end

            updated =
              update
              |> maybe_put("ip", ip)
              |> maybe_put("mac", Map.get(update, "mac") || List.first(macs))
              |> Map.put("metadata", updated_metadata)

            {updated, guest}
        end

      _ ->
        {update, nil}
    end
  end

  defp select_matching_guest([single], _update, _info), do: single

  defp select_matching_guest(candidates, update, info) when is_list(candidates) do
    update_ip = Map.get(update, "ip") || (info && info.ip)

    update_macs =
      ([Map.get(update, "mac") | List.wrap(get_in(update, ["metadata", "mac_addresses"]))] ++
         ((info && info.macs) || []))
      |> Enum.map(&IdentityReconciler.normalize_mac/1)
      |> Enum.filter(&present?/1)
      |> MapSet.new()

    Enum.find(candidates, fn guest ->
      (present?(update_ip) and update_ip in guest.ips) or
        (MapSet.size(update_macs) > 0 and
           not MapSet.disjoint?(update_macs, MapSet.new(guest.macs)))
    end)
  end

  defp reconcile_awx_device_links(enriched_updates, actor) do
    Enum.map(enriched_updates, fn
      {update, guest} ->
        if awx_update?(update) do
          reconcile_one_awx_update(update, guest, actor)
        else
          update
        end
    end)
  end

  defp reconcile_one_awx_update(update, guest, actor) do
    partition = Map.get(update, "partition") || "default"
    metadata = Map.get(update, "metadata") || %{}
    integration_id = Map.get(metadata, "integration_id")
    legacy_ids = List.wrap(Map.get(metadata, "legacy_integration_ids"))
    ip = Map.get(update, "ip")

    macs =
      [Map.get(update, "mac") | List.wrap(Map.get(metadata, "mac_addresses"))]
      |> Enum.map(&IdentityReconciler.normalize_mac/1)
      |> Enum.filter(&present?/1)
      |> Enum.uniq()

    guest_uid =
      if is_map(guest) and is_binary(guest.device_uid) and
           String.starts_with?(guest.device_uid, "sr:") do
        live_device_uid(guest.device_uid)
      end

    existing_awx_uid =
      lookup_awx_integration_owner([integration_id | legacy_ids], partition)

    network_holder_uid =
      lookup_corroborated_network_holder(
        ip,
        macs,
        partition,
        guest_uid || existing_awx_uid,
        guest != nil
      )

    candidate_uids =
      [guest_uid, existing_awx_uid, network_holder_uid]
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    case candidate_uids do
      [] ->
        update

      [survivor_uid | rest] ->
        Enum.each(rest, fn source_uid ->
          if source_uid != survivor_uid do
            _ =
              IdentityReconciler.merge_devices(source_uid, survivor_uid,
                actor: actor,
                reason: "awx_proxmox_network_match",
                details: %{
                  "awx_integration_id" => integration_id,
                  "guest_provider_ref" => guest && guest.provider_ref
                }
              )
          end
        end)

        if is_nil(existing_awx_uid) do
          Map.put(update, "device_id", survivor_uid)
        else
          update
        end
    end
  end

  defp live_device_uid(uid) when is_binary(uid) do
    case Repo.query(
           "SELECT uid FROM platform.ocsf_devices WHERE uid = $1 AND deleted_at IS NULL LIMIT 1",
           [uid]
         ) do
      {:ok, %{rows: [[found]]}} -> found
      _ -> nil
    end
  end

  defp lookup_awx_integration_owner(ids, partition) do
    clean_ids =
      ids
      |> Enum.filter(&present?/1)
      |> Enum.uniq()

    if clean_ids == [] do
      nil
    else
      sql = """
      SELECT di.device_id
      FROM platform.device_identifiers di
      JOIN platform.ocsf_devices d ON d.uid = di.device_id AND d.deleted_at IS NULL
      WHERE di.identifier_type = 'integration_id'
        AND di.identifier_value = ANY($1::text[])
        AND COALESCE(di.partition, 'default') = $2
      ORDER BY di.last_seen DESC NULLS LAST
      LIMIT 1
      """

      case Repo.query(sql, [clean_ids, partition]) do
        {:ok, %{rows: [[uid]]}} -> uid
        _ -> nil
      end
    end
  end

  defp lookup_corroborated_network_holder(ip, macs, partition, anchor_uid, has_proxmox_link?) do
    cond do
      macs != [] ->
        lookup_mac_holder_uid(macs, partition, anchor_uid) ||
          if(present?(ip), do: lookup_ip_holder_uid(ip, macs, partition, anchor_uid, true))

      present?(ip) and has_proxmox_link? ->
        lookup_ip_holder_uid(ip, [], partition, anchor_uid, true)

      present?(ip) ->
        lookup_ip_holder_uid(ip, [], partition, anchor_uid, false)

      true ->
        nil
    end
  end

  defp lookup_mac_holder_uid(macs, partition, anchor_uid) do
    sql = """
    SELECT d.uid, d.agent_id, COALESCE(d.discovery_sources, ARRAY[]::text[]), COALESCE(d.metadata, '{}'::jsonb)
    FROM platform.ocsf_devices d
    WHERE d.deleted_at IS NULL
      AND COALESCE(d.partition, 'default') = $2
      AND (
        upper(replace(replace(btrim(COALESCE(d.mac, '')), '-', ':'), '.', ':')) = ANY($1::text[])
        OR EXISTS (
          SELECT 1
          FROM platform.device_identifiers di
          WHERE di.device_id = d.uid
            AND di.identifier_type = 'mac'
            AND di.identifier_value = ANY($1::text[])
        )
      )
    LIMIT 1
    """

    case Repo.query(sql, [macs, partition]) do
      {:ok, %{rows: [[uid, agent_id, discovery_sources, metadata]]}} ->
        device = %Device{
          uid: uid,
          agent_id: agent_id,
          discovery_sources: List.wrap(discovery_sources),
          metadata: metadata || %{}
        }

        if DeviceClaimPolicy.reusable_for_claim?(device, :managed_child_asset) and
             (is_nil(anchor_uid) or uid == anchor_uid or
                SourceAuthorityGuard.ensure_merge_allowed([uid, anchor_uid]) == :ok) do
          uid
        end

      _ ->
        nil
    end
  end

  defp lookup_ip_holder_uid(ip, guest_macs, partition, anchor_uid, corroborated_by_proxmox?) do
    sql = """
    SELECT d.uid,
           d.agent_id,
           COALESCE(d.discovery_sources, ARRAY[]::text[]),
           COALESCE(d.metadata, '{}'::jsonb),
           d.mac,
           COALESCE(
             ARRAY(
               SELECT di.identifier_value
               FROM platform.device_identifiers di
               WHERE di.device_id = d.uid AND di.identifier_type = 'mac'
             ),
             ARRAY[]::text[]
           ) AS device_macs
    FROM platform.ocsf_devices d
    WHERE d.deleted_at IS NULL
      AND COALESCE(d.partition, 'default') = $2
      AND btrim(COALESCE(d.ip, '')) = $1
    LIMIT 1
    """

    case Repo.query(sql, [ip, partition]) do
      {:ok, %{rows: [[uid, agent_id, discovery_sources, metadata, d_mac, device_macs]]}} ->
        device = %Device{
          uid: uid,
          agent_id: agent_id,
          discovery_sources: List.wrap(discovery_sources),
          metadata: metadata || %{}
        }

        holder_macs =
          [d_mac | List.wrap(device_macs)]
          |> Enum.map(&IdentityReconciler.normalize_mac/1)
          |> Enum.filter(&present?/1)
          |> MapSet.new()

        g_macs = MapSet.new(guest_macs)

        mac_contradicts? =
          MapSet.size(g_macs) > 0 and MapSet.size(holder_macs) > 0 and
            MapSet.disjoint?(g_macs, holder_macs)

        unanchored_holder? = MapSet.size(holder_macs) == 0

        if not mac_contradicts? and
             (corroborated_by_proxmox? or unanchored_holder?) and
             DeviceClaimPolicy.reusable_for_claim?(device, :managed_child_asset) and
             (is_nil(anchor_uid) or uid == anchor_uid or
                SourceAuthorityGuard.ensure_merge_allowed([uid, anchor_uid]) == :ok) do
          uid
        end

      _ ->
        nil
    end
  end
end
