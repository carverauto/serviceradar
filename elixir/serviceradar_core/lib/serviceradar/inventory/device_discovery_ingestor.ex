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

  alias ServiceRadar.Automation.Ansible.AwxMembershipReconciler
  alias ServiceRadar.Inventory.DeviceSourceObservationIngestor
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.SyncIngestor

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
    actor = Keyword.fetch!(opts, :actor)
    device_sync = Keyword.get(opts, :device_sync, &sync_device_inventory/2)
    membership_sync = Keyword.get(opts, :membership_sync, &sync_awx_memberships/2)

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

    with {:ok, process_batches} <-
           preflight_source_observation_batches(
             discovery_batches,
             context,
             source_observation_preflight
           ),
         updates = Enum.flat_map(process_batches, fn {_envelope, batch} -> batch end),
         :ok <- sync_devices_if_present(updates, actor, device_sync),
         :ok <-
           sync_source_observation_batches(
             process_batches,
             context,
             source_observation_sync
           ) do
      membership_sync.(payload, %{actor: actor})
    end
  rescue
    e ->
      Logger.warning("Plugin device discovery ingest failed: #{Exception.message(e)}")
      {:error, e}
  end

  def ingest(_payload, _status, _opts), do: :ok

  defp sync_device_inventory(updates, context) when is_list(updates) do
    SyncIngestor.ingest_updates(updates, actor: context.actor)
  end

  defp sync_devices_if_present([], _actor, _device_sync), do: :ok

  defp sync_devices_if_present(updates, actor, device_sync) do
    case device_sync.(updates, %{actor: actor}) do
      :ok -> :ok
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
    AwxMembershipReconciler.reconcile(payload, actor: context.actor)
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

    update = %{
      "device_id" => string_value(device, ["device_id", "deviceId", "uid"]),
      "ip" => device_ip(device),
      "mac" => string_value(device, ["mac", "mac_address", "macAddress"]),
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
    with awx when is_map(awx) <- awx_metadata(device),
         host when is_binary(host) <- awx_ansible_host_value(awx),
         true <- valid_ip?(host) do
      host
    else
      _ -> nil
    end
  end

  defp awx_ansible_host_value(awx) do
    case string_value(awx, ["ansible_host", "ansible_ssh_host"]) do
      host when is_binary(host) ->
        host

      _ ->
        case string_value(awx, ["variables"]) do
          raw when is_binary(raw) -> ansible_host_from_variables(raw)
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

  # AWX returns a host's `variables` as a stringified JSON object (the proxmox
  # dynamic inventory emits JSON). Decode it and read `ansible_host` (or the
  # legacy `ansible_ssh_host`). A non-object blob or a decode failure yields nil.
  defp ansible_host_from_variables(raw) do
    trimmed = String.trim(raw)

    with "{" <> _ <- trimmed,
         {:ok, decoded} when is_map(decoded) <- Jason.decode(trimmed) do
      string_value(decoded, ["ansible_host", "ansible_ssh_host"])
    else
      _ -> nil
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
    base = stringify_map(map_value(device, ["metadata"]) || %{})

    base
    |> maybe_put_new("integration_type", "plugin_device_discovery")
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
end
