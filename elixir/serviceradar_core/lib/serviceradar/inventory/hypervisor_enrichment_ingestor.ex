defmodule ServiceRadar.Inventory.HypervisorEnrichmentIngestor do
  @moduledoc """
  Ingests provider-neutral hypervisor enrichment records into virtualization inventory.

  Provider-specific collectors should normalize API-native shapes into this
  shared record set before persistence. Proxmox currently adapts its legacy
  payload into these records; future vSphere/vCenter support should emit this
  envelope directly.
  """

  alias ServiceRadar.Inventory.DeviceClaimPolicy
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.IntegrationIdentity
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Inventory.VirtualizationCluster
  alias ServiceRadar.Inventory.VirtualizationDatastore
  alias ServiceRadar.Inventory.VirtualizationGuest
  alias ServiceRadar.Inventory.VirtualizationHost
  alias ServiceRadar.Inventory.VirtualizationHostDisk
  alias ServiceRadar.Inventory.VirtualizationIdentityAliases
  alias ServiceRadar.Inventory.VirtualizationNetworkInterface
  alias ServiceRadar.Inventory.VirtualizationStorageSystem
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @schema "serviceradar.hypervisor_enrichment.v1"

  @record_keys [
    :clusters,
    :hosts,
    :guests,
    :datastores,
    :host_disks,
    :network_interfaces,
    :storage_systems,
    :console_targets
  ]

  @record_sources %{
    clusters: ["clusters"],
    hosts: ["hosts"],
    guests: ["guests"],
    datastores: ["datastores"],
    host_disks: ["host_disks", "disks"],
    network_interfaces: ["network_interfaces", "guest_network_interfaces"],
    storage_systems: ["storage_systems"],
    console_targets: ["console_targets"]
  }

  @field_allowlist %{
    clusters: [
      :provider,
      :provider_ref,
      :identity_version,
      :identity_state,
      :integration_id,
      :controller_id,
      :native_cluster_id,
      :object_kind,
      :native_object_id,
      :provider_instance_ref,
      :legacy_provider_refs,
      :name,
      :status,
      :version,
      :metadata,
      :observed_at
    ],
    hosts: [
      :provider,
      :provider_ref,
      :identity_version,
      :identity_state,
      :integration_id,
      :controller_id,
      :native_cluster_id,
      :object_kind,
      :native_object_id,
      :provider_instance_ref,
      :legacy_provider_refs,
      :cluster_provider_ref,
      :device_uid,
      :name,
      :status,
      :version,
      :cpu_ratio,
      :memory_used_bytes,
      :memory_total_bytes,
      :uptime_seconds,
      :metadata,
      :observed_at
    ],
    guests: [
      :provider,
      :provider_ref,
      :identity_version,
      :identity_state,
      :integration_id,
      :controller_id,
      :native_cluster_id,
      :object_kind,
      :native_object_id,
      :provider_instance_ref,
      :legacy_provider_refs,
      :host_provider_ref,
      :device_uid,
      :name,
      :guest_type,
      :vmid,
      :status,
      :cpu_ratio,
      :memory_used_bytes,
      :memory_total_bytes,
      :disk_used_bytes,
      :disk_total_bytes,
      :uptime_seconds,
      :metadata,
      :observed_at
    ],
    datastores: [
      :provider,
      :provider_ref,
      :cluster_provider_ref,
      :host_provider_ref,
      :name,
      :storage_type,
      :content,
      :active,
      :enabled,
      :shared,
      :used_bytes,
      :available_bytes,
      :total_bytes,
      :metadata,
      :observed_at
    ],
    host_disks: [
      :provider,
      :provider_ref,
      :host_provider_ref,
      :device_uid,
      :path,
      :by_id,
      :disk_type,
      :vendor,
      :model,
      :health,
      :size_bytes,
      :wearout,
      :usage,
      :metadata,
      :observed_at
    ],
    network_interfaces: [
      :provider,
      :provider_ref,
      :host_provider_ref,
      :guest_provider_ref,
      :device_uid,
      :name,
      :interface_type,
      :active,
      :exists,
      :method,
      :method6,
      :address,
      :cidr,
      :gateway,
      :bridge_ports,
      :vlan_id,
      :mac_address,
      :ip_addresses,
      :source,
      :metadata,
      :observed_at
    ],
    storage_systems: [
      :provider,
      :provider_ref,
      :cluster_provider_ref,
      :host_provider_ref,
      :name,
      :storage_system_type,
      :health,
      :status,
      :metadata,
      :observed_at
    ],
    console_targets: [
      :provider,
      :provider_ref,
      :target_ref,
      :target_type,
      :protocol,
      :transport,
      :credential_purpose,
      :agent_id,
      :capabilities,
      :device_uid,
      :metadata,
      :observed_at
    ]
  }
  @field_by_name @field_allowlist
                 |> Map.values()
                 |> List.flatten()
                 |> Enum.uniq()
                 |> Map.new(&{Atom.to_string(&1), &1})

  @spec supports?(map() | list(), map()) :: boolean()
  def supports?(payload, status \\ %{})

  def supports?(payload, status) when is_list(payload) do
    Enum.any?(payload, &supports?(&1, status))
  end

  def supports?(payload, _status) when is_map(payload) do
    case details(payload) do
      %{"schema" => @schema} -> true
      _ -> false
    end
  end

  def supports?(_payload, _status), do: false

  @spec ingest(map() | list(), map(), keyword()) :: :ok | {:error, term()}
  def ingest(payload, status, opts \\ [])

  def ingest(payload, status, opts) when is_list(payload) do
    payload
    |> Enum.filter(&supports?(&1, status))
    |> case do
      [] ->
        :ok

      entries ->
        records =
          entries
          |> Enum.map(&records_for_payload(&1, status, opts))
          |> merge_records()
          |> dedupe_records()

        persist = Keyword.get(opts, :persist, &persist_records(&1, opts))
        persist.(records)
    end
  end

  def ingest(payload, status, opts) when is_map(payload) do
    case details(payload) do
      %{"schema" => @schema} ->
        records =
          payload
          |> records_for_payload(status, opts)
          |> dedupe_records()

        persist = Keyword.get(opts, :persist, &persist_records(&1, opts))
        persist.(records)

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning("Hypervisor enrichment ingest failed: #{Exception.message(e)}")
      {:error, e}
  end

  def ingest(_payload, _status, _opts), do: :ok

  def empty_records do
    %{
      clusters: [],
      hosts: [],
      guests: [],
      datastores: [],
      host_disks: [],
      network_interfaces: [],
      storage_systems: [],
      console_targets: []
    }
  end

  def merge_records(record_sets) do
    Enum.reduce(record_sets, empty_records(), fn records, acc ->
      Map.new(acc, fn {key, values} -> {key, values ++ Map.get(records, key, [])} end)
    end)
  end

  def dedupe_records(records) do
    Map.new(records, fn {key, values} ->
      {key, dedupe_provider_refs(values)}
    end)
  end

  def persist_records(records, opts) do
    actor = Keyword.fetch!(opts, :actor)

    with :ok <- validate_source_scoped_identities(records),
         :ok <- validate_trusted_proxmox_source_binding(records, opts),
         records = discard_untrusted_proxmox_device_uids(records),
         records = resolve_existing_device_uids(records, actor),
         records = normalize_host_management_ips(records),
         {:ok, records} <- ensure_inventory_devices(records, actor),
         records = resolve_existing_device_uids(records, actor),
         records = propagate_resolved_device_uids(records),
         {:ok, cluster_ids} <- upsert_group(VirtualizationCluster, records.clusters, actor),
         host_rows = link_refs(records.hosts, cluster_ids, %{}),
         {:ok, host_ids} <- upsert_group(VirtualizationHost, host_rows, actor),
         {:ok, host_ids} <-
           load_existing_reference_ids(
             VirtualizationHost,
             host_ids,
             referenced_provider_refs(records, :host_provider_ref),
             actor
           ),
         datastores = link_refs(records.datastores, cluster_ids, host_ids),
         disks = link_refs(records.host_disks, %{}, host_ids),
         guests = link_refs(records.guests, %{}, host_ids),
         {:ok, guest_ids} <- upsert_group(VirtualizationGuest, guests, actor),
         nics = link_network_interface_refs(records.network_interfaces, host_ids, guest_ids),
         storage_systems = link_refs(records.storage_systems, cluster_ids, host_ids),
         {:ok, _} <- upsert_group(VirtualizationDatastore, datastores, actor),
         {:ok, _} <- upsert_group(VirtualizationHostDisk, disks, actor),
         {:ok, _} <- upsert_group(VirtualizationNetworkInterface, nics, actor),
         {:ok, _} <- upsert_group(VirtualizationStorageSystem, storage_systems, actor) do
      VirtualizationIdentityAliases.reconcile(records)
    end
  end

  # Proxmox v3 object identity is authoritative only because its integration
  # and controller scope was derived from the authenticated assignment. A
  # plugin result can suggest network observations, but it may never select an
  # existing ServiceRadar device by UID. Clear every result-owned UID before
  # lookup; the subsequent identity maps restore only server-owned bindings.
  defp discard_untrusted_proxmox_device_uids(records) do
    Map.new(records, fn {key, values} ->
      {key,
       Enum.map(values, fn record ->
         if proxmox_record?(record) and Map.has_key?(record, :device_uid),
           do: Map.put(record, :device_uid, nil),
           else: record
       end)}
    end)
  end

  defp validate_source_scoped_identities(records) do
    records
    |> Map.take([:clusters, :hosts, :guests])
    |> Map.values()
    |> List.flatten()
    |> Enum.reduce_while(:ok, fn record, :ok ->
      if String.downcase(to_string(Map.get(record, :provider))) == "proxmox" do
        result =
          if Map.get(record, :identity_version) == 3 and
               Map.get(record, :identity_state) in [:authoritative, "authoritative"] do
            IntegrationIdentity.validate_v3_record(record)
          else
            {:error, :proxmox_v3_identity_required}
          end

        case result do
          :ok ->
            {:cont, :ok}

          {:error, reason} ->
            {:halt, {:error, {reason, Map.get(record, :provider_ref)}}}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  # A generic hypervisor result is not allowed to self-assert Proxmox UUIDs.
  # The specialized Proxmox result handler resolves this scope from the
  # authenticated assignment/rule chain and passes it through `opts`.
  defp validate_trusted_proxmox_source_binding(records, opts) do
    proxmox_records = proxmox_records(records)

    if proxmox_records == [] do
      :ok
    else
      with {:ok, integration_id, controller_id, partition_id} <- trusted_source_scope(opts),
           primary_records when primary_records != [] <- proxmox_primary_records(records),
           true <-
             Enum.all?(primary_records, fn record ->
               canonical_uuid_value(Map.get(record, :integration_id)) == integration_id and
                 canonical_uuid_value(Map.get(record, :controller_id)) == controller_id
             end),
           provider_instances =
             primary_records
             |> Enum.map(&Map.get(&1, :provider_instance_ref))
             |> Enum.filter(&present?/1)
             |> Enum.uniq(),
           true <- provider_instances != [],
           true <-
             Enum.all?(proxmox_records, fn record ->
               record_bound_to_instances?(record, provider_instances) and
                 metadata_partition(record) == partition_id
             end) do
        :ok
      else
        {:error, _reason} = error -> error
        [] -> {:error, :missing_authoritative_proxmox_identity}
        false -> {:error, :proxmox_source_scope_mismatch}
      end
    end
  end

  defp proxmox_primary_records(records) do
    records
    |> Map.take([:clusters, :hosts, :guests])
    |> Map.values()
    |> List.flatten()
    |> Enum.filter(&proxmox_record?/1)
  end

  defp proxmox_records(records) do
    records
    |> Map.values()
    |> List.flatten()
    |> Enum.filter(&proxmox_record?/1)
  end

  defp proxmox_record?(record) when is_map(record) do
    String.downcase(to_string(Map.get(record, :provider))) == "proxmox"
  end

  defp proxmox_record?(_record), do: false

  defp trusted_source_scope(opts) do
    case Keyword.get(opts, :source_scope) do
      scope when is_map(scope) ->
        with {:ok, integration_id} <- canonical_uuid(scope_value(scope, :integration_id)),
             {:ok, controller_id} <- canonical_uuid(scope_value(scope, :controller_id)),
             partition_id when is_binary(partition_id) <- scope_value(scope, :partition_id),
             partition_id = String.trim(partition_id),
             true <- partition_id != "" do
          {:ok, integration_id, controller_id, partition_id}
        else
          _ -> {:error, :invalid_trusted_proxmox_source_scope}
        end

      _ ->
        {:error, :missing_trusted_proxmox_source_scope}
    end
  end

  defp scope_value(scope, key), do: Map.get(scope, key) || Map.get(scope, to_string(key))

  defp canonical_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(String.trim(value)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_uuid}
    end
  end

  defp canonical_uuid(_value), do: {:error, :invalid_uuid}

  defp canonical_uuid_value(value) do
    case canonical_uuid(value) do
      {:ok, uuid} -> uuid
      {:error, _reason} -> nil
    end
  end

  defp record_bound_to_instances?(record, provider_instances) do
    [:provider_ref, :cluster_provider_ref, :host_provider_ref, :guest_provider_ref]
    |> Enum.map(&Map.get(record, &1))
    |> Enum.filter(&present?/1)
    |> Enum.all?(fn ref ->
      Enum.any?(provider_instances, &String.starts_with?(ref, &1 <> ":"))
    end)
  end

  defp records_for_payload(payload, status, opts) do
    payload
    |> details()
    |> build_records(Keyword.get(opts, :observed_at) || observed_at(payload, status))
  end

  defp build_records(details, observed_at) when is_map(details) do
    provider = string_value(details, "provider")

    Enum.reduce(@record_keys, empty_records(), fn key, acc ->
      records =
        key
        |> records_for_key(details)
        |> Enum.map(&normalize_record(&1, key, provider, observed_at))
        |> Enum.filter(&valid_record?/1)

      Map.put(acc, key, records)
    end)
  end

  defp build_records(_details, _observed_at), do: empty_records()

  defp records_for_key(key, details) do
    @record_sources
    |> Map.fetch!(key)
    |> Enum.flat_map(&list_value(details, &1))
  end

  defp normalize_record(record, key, default_provider, observed_at) do
    allowed = Map.fetch!(@field_allowlist, key)

    record
    |> Enum.reduce(%{}, fn {raw_key, raw_value}, acc ->
      field = normalize_field(raw_key)

      if field in allowed do
        Map.put(acc, field, normalize_field_value(field, raw_value))
      else
        acc
      end
    end)
    |> maybe_put_default(:provider, default_provider)
    |> maybe_put_console_provider_ref(key)
    |> maybe_put_default(:metadata, %{})
    |> maybe_put_default(:observed_at, observed_at)
    |> sanitize_record_metadata()
  end

  defp maybe_put_console_provider_ref(%{provider_ref: provider_ref} = record, :console_targets)
       when provider_ref not in [nil, ""], do: record

  defp maybe_put_console_provider_ref(%{target_ref: target_ref} = record, :console_targets)
       when target_ref not in [nil, ""], do: Map.put(record, :provider_ref, target_ref)

  defp maybe_put_console_provider_ref(record, _key), do: record

  defp normalize_field(key) when is_atom(key), do: key

  defp normalize_field(key) when is_binary(key) do
    key
    |> String.replace("-", "_")
    |> then(&Map.get(@field_by_name, &1))
  end

  defp normalize_field(_key), do: nil

  defp normalize_field_value(:metadata, value), do: sanitize_metadata(value)
  defp normalize_field_value(:observed_at, value), do: parse_time(value) || value
  defp normalize_field_value(:ip_addresses, value), do: list_string(value)
  defp normalize_field_value(_field, value), do: value

  defp maybe_put_default(record, _key, value) when value in [nil, ""], do: record

  defp maybe_put_default(record, key, value) do
    case Map.get(record, key) do
      nil -> Map.put(record, key, value)
      "" -> Map.put(record, key, value)
      _ -> record
    end
  end

  defp sanitize_record_metadata(record) do
    Map.update(record, :metadata, %{}, &sanitize_metadata/1)
  end

  defp valid_record?(%{provider: provider, provider_ref: provider_ref}) do
    present?(provider) and present?(provider_ref)
  end

  defp valid_record?(_record), do: false

  defp details(%{"details" => raw}) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> nil
    end
  end

  defp details(%{"details" => raw}) when is_map(raw), do: raw
  defp details(%{"schema" => @schema} = raw), do: raw
  defp details(_payload), do: nil

  defp observed_at(payload, status) do
    parse_time(
      payload["observed_at"] || payload["observedAt"] || status[:agent_timestamp] ||
        status[:timestamp]
    ) ||
      DateTime.utc_now()
  end

  defp parse_time(%DateTime{} = value), do: value

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> DateTime.truncate(parsed, :microsecond)
      _ -> nil
    end
  end

  defp parse_time(_value), do: nil

  defp dedupe_provider_refs(records) do
    records
    |> Enum.reduce(%{}, fn record, acc ->
      key = {record.provider, record.provider_ref}

      Map.update(acc, key, record, fn current ->
        if newer_record?(record, current), do: record, else: current
      end)
    end)
    |> Map.values()
  end

  defp newer_record?(candidate, current) do
    case {candidate[:observed_at], current[:observed_at]} do
      {%DateTime{} = left, %DateTime{} = right} -> DateTime.compare(left, right) != :lt
      {%DateTime{}, _} -> true
      {_, nil} -> true
      _ -> true
    end
  end

  defp resolve_existing_device_uids(records, actor) do
    candidates =
      records.hosts ++ records.guests ++ records.host_disks ++ records.network_interfaces

    current_uids =
      candidates
      |> Enum.map(&Map.get(&1, :device_uid))
      |> Enum.filter(&present?/1)

    names =
      candidates
      |> Enum.flat_map(fn record ->
        [Map.get(record, :name), node_name_from_provider_ref(Map.get(record, :provider_ref))]
      end)
      |> Enum.filter(&present?/1)

    integration_identity = integration_identity_by_ref(records)
    network_identity = network_identity_by_guest(records.network_interfaces, actor)
    host_network_identity = network_identity_by_host(records, actor)
    devices = lookup_devices(current_uids, names, actor)

    guest_identity_maps = [integration_identity, network_identity]
    host_identity_maps = [integration_identity, host_network_identity]

    Map.merge(records, %{
      hosts: Enum.map(records.hosts, &resolve_record_device_uid(&1, devices, host_identity_maps)),
      guests:
        Enum.map(records.guests, fn record ->
          resolve_record_device_uid(
            record,
            devices,
            guest_identity_maps,
            actor,
            :managed_child_asset
          )
        end),
      host_disks:
        Enum.map(records.host_disks, &resolve_record_device_uid(&1, devices, host_identity_maps)),
      network_interfaces:
        Enum.map(records.network_interfaces, fn record ->
          if present?(Map.get(record, :guest_provider_ref)) do
            resolve_record_device_uid(
              record,
              devices,
              guest_identity_maps,
              actor,
              :managed_child_asset
            )
          else
            resolve_record_device_uid(record, devices, host_identity_maps)
          end
        end)
    })
  end

  defp ensure_inventory_devices(records, actor) do
    guest_ip_by_ref = primary_ip_by_guest(records.network_interfaces)
    host_ip_by_ref = primary_ip_by_host(records.network_interfaces)
    guest_macs = guest_macs_by_ref(records.network_interfaces)

    host_updates =
      records.hosts
      |> Enum.filter(&missing_device_uid?/1)
      |> Enum.map(fn record ->
        placeholder_device_update(
          record,
          :hypervisor,
          Map.get(host_ip_by_ref, Map.get(record, :provider_ref)),
          guest_macs
        )
      end)

    guest_updates =
      records.guests
      |> Enum.filter(&missing_device_uid?/1)
      |> Enum.map(fn record ->
        placeholder_device_update(
          record,
          :virtual_guest,
          Map.get(guest_ip_by_ref, Map.get(record, :provider_ref)),
          guest_macs
        )
      end)
      |> reject_guests_without_network_identity()

    updates =
      host_updates ++
        guest_updates ++
        existing_device_updates(records.hosts, :hypervisor, host_ip_by_ref, guest_macs) ++
        existing_device_updates(records.guests, :virtual_guest, guest_ip_by_ref, guest_macs)

    case updates do
      [] ->
        {:ok, records}

      _ ->
        # Records left without a device_uid get resolved by the follow-up
        # resolve_existing_device_uids pass via the integration_id identifier
        # rows the reconciler registered for these updates.
        case SyncIngestor.ingest_updates(updates, actor: actor) do
          :ok -> {:ok, records}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp missing_device_uid?(record) do
    record
    |> Map.get(:device_uid)
    |> existing_sr_uid()
    |> is_nil()
  end

  # The update intentionally carries NO "device_id": pre-set IDs bypassed
  # reconciliation entirely. DIRE resolves (or creates) the device from the
  # update's identity evidence (integration_id metadata, IP), and the
  # follow-up resolution pass links the virtualization record to whatever
  # device the reconciler chose.
  defp placeholder_device_update(record, role, ip_override, guest_macs) do
    provider_ref = Map.fetch!(record, :provider_ref)
    partition = metadata_partition(record)
    ip = first_non_empty(ip_override, metadata_ip(record))

    metadata = placeholder_device_metadata(record, role, guest_macs)

    maybe_put(
      %{
        "hostname" => Map.get(record, :name) || provider_ref,
        "partition" => partition,
        "source" => "hypervisor_enrichment",
        "is_available" => available_status?(Map.get(record, :status)),
        "metadata" => metadata
      },
      "ip",
      ip
    )
  end

  # A virtual guest only earns a device when we discovered an IP the reconciler
  # can merge on. Without one it becomes an orphan device that can never
  # reconcile with the host's own agent device — exactly the IP-less duplicate
  # the proxmox integration kept producing. So drop guests with no discoverable
  # IP rather than importing identity-less placeholders.
  defp reject_guests_without_network_identity(updates) do
    {kept, skipped} =
      Enum.split_with(updates, fn update -> (Map.get(update, "ip") || "") != "" end)

    if skipped != [] do
      Logger.info(
        "HypervisorEnrichment: skipped #{length(skipped)} guest(s) with no discoverable IP"
      )
    end

    kept
  end

  defp existing_device_updates(records, role, ip_by_ref, guest_macs) do
    records
    |> Enum.reject(&missing_device_uid?/1)
    |> Enum.flat_map(fn record ->
      ip =
        first_non_empty(
          Map.get(ip_by_ref, Map.get(record, :provider_ref)),
          metadata_ip(record)
        )

      case existing_sr_uid(Map.get(record, :device_uid)) do
        uid when is_binary(uid) ->
          [
            maybe_put(
              %{
                "device_id" => uid,
                "partition" => metadata_partition(record),
                "source" => "hypervisor_enrichment",
                "metadata" => placeholder_device_metadata(record, role, guest_macs)
              },
              "ip",
              ip
            )
          ]

        _ ->
          []
      end
    end)
  end

  defp placeholder_device_metadata(record, role, guest_macs) do
    provider_ref = Map.fetch!(record, :provider_ref)
    integration_id = record_integration_id(record) || provider_ref

    legacy_integration_ids =
      if authoritative_v3_record?(record) do
        # V3 legacy refs are reconciliation evidence only. Looking them up here
        # could merge two independent controllers before the alias reconciler
        # has quarantined their shared legacy name/node/vmid.
        []
      else
        [
          provider_ref
          | IntegrationIdentity.legacy_candidates(
              integration_id,
              legacy_record_fields(record, guest_macs)
            )
        ]
        |> Enum.uniq()
        |> Enum.reject(&(&1 == integration_id))
      end

    %{
      "integration_id" => integration_id,
      "integration_type" => "hypervisor",
      "device_role" => device_role(role),
      "hypervisor_provider" => Map.get(record, :provider),
      "hypervisor_provider_ref" => provider_ref
    }
    |> maybe_put("hypervisor_guest_type", Map.get(record, :guest_type))
    |> maybe_put("hypervisor_host_provider_ref", Map.get(record, :host_provider_ref))
    |> maybe_put("hypervisor_vmid", Map.get(record, :vmid))
    |> maybe_put("hypervisor_status", Map.get(record, :status))
    |> maybe_put_legacy_integration_ids(legacy_integration_ids)
    |> maybe_put_proxmox_candidate(record, role)
  end

  defp maybe_put_legacy_integration_ids(metadata, []), do: metadata

  defp maybe_put_legacy_integration_ids(metadata, ids) when is_list(ids),
    do: Map.put(metadata, "legacy_integration_ids", ids)

  defp maybe_put_proxmox_candidate(metadata, record, :hypervisor) do
    if String.downcase(to_string(Map.get(record, :provider))) == "proxmox" do
      metadata
      |> Map.put("proxmox_candidate", true)
      |> Map.put("proxmox_candidate_source", "hypervisor_enrichment")
      |> Map.put("proxmox_candidate_service", "pve-api")
    else
      metadata
    end
  end

  defp maybe_put_proxmox_candidate(metadata, _record, _role), do: metadata

  defp primary_ip_by_guest(network_interfaces) do
    Enum.reduce(network_interfaces, %{}, fn iface, acc ->
      guest_ref = Map.get(iface, :guest_provider_ref)
      ip = primary_interface_ip(iface)

      if present?(guest_ref) and present?(ip) do
        Map.put_new(acc, guest_ref, ip)
      else
        acc
      end
    end)
  end

  defp primary_ip_by_host(network_interfaces) do
    network_interfaces
    |> Enum.reduce(%{}, fn iface, acc ->
      host_ref = Map.get(iface, :host_provider_ref)
      guest_ref = Map.get(iface, :guest_provider_ref)
      ip = primary_interface_ip(iface)

      if present?(host_ref) and not present?(guest_ref) and present?(ip) do
        candidate = {ip, management_ip_score(iface, ip)}

        Map.update(acc, host_ref, candidate, fn current ->
          if elem(candidate, 1) > elem(current, 1), do: candidate, else: current
        end)
      else
        acc
      end
    end)
    |> Map.new(fn {host_ref, {ip, _score}} -> {host_ref, ip} end)
  end

  defp normalize_host_management_ips(records) do
    host_ip_by_ref = primary_ip_by_host(records.network_interfaces)

    Map.update!(records, :hosts, fn hosts ->
      Enum.map(hosts, fn record ->
        provider_ref = Map.get(record, :provider_ref)
        ip = Map.get(host_ip_by_ref, provider_ref)

        if present?(ip) and not present?(metadata_ip(record)) do
          metadata =
            record
            |> Map.get(:metadata, %{})
            |> Map.put("ip", ip)

          Map.put(record, :metadata, metadata)
        else
          record
        end
      end)
    end)
  end

  defp primary_interface_ip(iface) do
    Enum.find_value(
      [
        iface |> Map.get(:ip_addresses, []) |> Enum.find_value(&normalize_ip_identifier/1),
        normalize_ip_identifier(Map.get(iface, :cidr)),
        normalize_ip_identifier(Map.get(iface, :address))
      ],
      & &1
    )
  end

  defp management_ip_score(iface, ip) do
    score =
      cond do
        not routable_management_ip?(ip) -> 0
        present?(Map.get(iface, :gateway)) -> 100
        private_management_ip?(ip) -> 80
        true -> 50
      end

    if String.starts_with?(String.downcase(to_string(Map.get(iface, :name) || "")), ["vmbr", "br"]) do
      score + 5
    else
      score
    end
  end

  defp private_management_ip?(value) when is_binary(value) do
    String.starts_with?(value, ["10.", "192.168."]) or private_172_ip?(value)
  end

  defp private_management_ip?(_value), do: false

  defp private_172_ip?("172." <> rest) do
    case rest |> String.split(".", parts: 2) |> List.first() |> Integer.parse() do
      {octet, _} -> octet in 16..31
      _ -> false
    end
  end

  defp private_172_ip?(_value), do: false

  defp routable_management_ip?(value) when is_binary(value) do
    not String.starts_with?(value, ["0.", "127.", "169.254."])
  end

  defp routable_management_ip?(_value), do: false

  defp metadata_ip(record) do
    metadata = Map.get(record, :metadata) || %{}

    Enum.find_value(
      [
        Map.get(metadata, "ip"),
        get_in(metadata, ["cluster_node", "ip"])
      ],
      fn
        value when is_binary(value) -> value |> strip_cidr() |> blank_to_nil()
        _ -> nil
      end
    )
  end

  # Fan resolved host/guest device uids out to dependent records (disks,
  # NICs, console targets) that reference them by provider ref.
  defp propagate_resolved_device_uids(records) do
    host_uid_by_ref = resolved_uid_by_ref(records.hosts)
    guest_uid_by_ref = resolved_uid_by_ref(records.guests)

    Map.merge(records, %{
      host_disks:
        Enum.map(records.host_disks, &fill_device_uid(&1, :host_provider_ref, host_uid_by_ref)),
      network_interfaces:
        Enum.map(records.network_interfaces, fn record ->
          if present?(Map.get(record, :guest_provider_ref)) do
            fill_device_uid(record, :guest_provider_ref, guest_uid_by_ref)
          else
            fill_device_uid(record, :host_provider_ref, host_uid_by_ref)
          end
        end),
      console_targets:
        Enum.map(records.console_targets, &fill_device_uid(&1, :provider_ref, guest_uid_by_ref))
    })
  end

  defp resolved_uid_by_ref(rows) do
    Enum.reduce(rows, %{}, fn record, acc ->
      case existing_sr_uid(Map.get(record, :device_uid)) do
        uid when is_binary(uid) -> Map.put(acc, Map.get(record, :provider_ref), uid)
        _ -> acc
      end
    end)
  end

  defp fill_device_uid(record, ref_key, uid_by_ref) do
    if missing_device_uid?(record) do
      case Map.get(uid_by_ref, Map.get(record, ref_key)) do
        uid when is_binary(uid) and uid != "" -> Map.put(record, :device_uid, uid)
        _ -> record
      end
    else
      record
    end
  end

  defp metadata_partition(record) do
    record
    |> Map.get(:metadata, %{})
    |> string_value("partition")
    |> Kernel.||("default")
  end

  defp device_role(:hypervisor), do: "hypervisor"
  defp device_role(:virtual_guest), do: "virtual-guest"
  defp device_role(_role), do: "managed-child-asset"

  defp available_status?(status) when is_binary(status) do
    status
    |> String.downcase()
    |> String.trim()
    |> Kernel.in(["online", "running", "connected", "poweredon", "ok", "available"])
  end

  defp available_status?(_status), do: false

  defp lookup_devices([], [], _actor), do: %{by_uid: %{}, by_name: %{}}

  defp lookup_devices(uids, names, _actor) do
    uids = Enum.uniq(uids)

    # Hostname matching is case-insensitive: hypervisors and discovery
    # sources disagree on hostname casing, which must not fork identity.
    names =
      names
      |> Enum.map(&normalize_lookup_key/1)
      |> Enum.filter(&present?/1)
      |> Enum.uniq()

    case Repo.query(device_lookup_sql(), [uids, names]) do
      {:ok, %{rows: rows}} ->
        %{
          by_uid: Map.new(rows, fn [uid, _name, _hostname] -> {uid, uid} end),
          by_name:
            rows
            |> Enum.flat_map(fn [uid, name, hostname] ->
              [
                {normalize_lookup_key(name), uid},
                {normalize_lookup_key(hostname), uid}
              ]
            end)
            |> Enum.reject(fn {key, _uid} -> is_nil(key) end)
            |> Map.new()
        }

      {:error, reason} ->
        Logger.warning("Hypervisor enrichment device lookup failed: #{inspect(reason)}")
        %{by_uid: %{}, by_name: %{}}
    end
  end

  defp device_lookup_sql do
    """
    SELECT uid, name, hostname
    FROM platform.ocsf_devices
    WHERE deleted_at IS NULL
      AND (
        uid = ANY($1::text[])
        OR LOWER(name) = ANY($2::text[])
        OR LOWER(hostname) = ANY($2::text[])
      )
    """
  end

  # Map host/guest provider refs to existing devices via their
  # integration_id identifier rows. The stable (v2) id from the record
  # metadata is consulted first, then the provider ref, then every
  # legacy-format generation (name-keyed, MAC-keyed, node-scoped) so
  # identifier rows written by earlier connector generations keep resolving
  # to the same device instead of forking a new one.
  defp integration_identity_by_ref(records) do
    guest_macs = guest_macs_by_ref(records.network_interfaces)

    entries =
      Enum.map(records.hosts ++ records.guests, fn record ->
        {
          Map.get(record, :provider_ref),
          integration_lookup_values(record, guest_macs),
          metadata_partition(record)
        }
      end)

    wanted =
      entries
      |> Enum.flat_map(fn {_ref, values, partition} ->
        Enum.map(values, &%{type: :integration_id, value: &1, partition: partition})
      end)
      |> Enum.uniq()

    if wanted == [] do
      %{}
    else
      identifier_to_device = lookup_identifier_devices(wanted)

      Enum.reduce(entries, %{}, fn {ref, values, partition}, acc ->
        uid =
          Enum.find_value(
            values,
            &Map.get(identifier_to_device, {:integration_id, &1, partition})
          )

        if is_binary(uid) and uid != "" do
          Map.put_new(acc, ref, uid)
        else
          acc
        end
      end)
    end
  end

  defp integration_lookup_values(record, guest_macs) do
    provider_ref = Map.get(record, :provider_ref)
    integration_id = record_integration_id(record)

    legacy =
      if authoritative_v3_record?(record) do
        []
      else
        IntegrationIdentity.legacy_candidates(
          integration_id,
          legacy_record_fields(record, guest_macs)
        )
      end

    IntegrationIdentity.lookup_values(%{
      integration_id: List.wrap(integration_id) ++ List.wrap(provider_ref),
      legacy_integration_ids: legacy
    })
  end

  defp record_integration_id(record) do
    record
    |> Map.get(:metadata)
    |> Kernel.||(%{})
    |> string_value("integration_id")
  end

  defp legacy_record_fields(record, guest_macs) do
    %{
      name: Map.get(record, :name),
      node:
        node_name_from_provider_ref(
          Map.get(record, :host_provider_ref) || Map.get(record, :provider_ref)
        ),
      vmid: Map.get(record, :vmid),
      guest_type: Map.get(record, :guest_type),
      macs: Map.get(guest_macs, Map.get(record, :provider_ref), [])
    }
  end

  defp guest_macs_by_ref(network_interfaces) do
    network_interfaces
    |> Enum.filter(&present?(Map.get(&1, :guest_provider_ref)))
    |> mac_list_by_ref(:guest_provider_ref)
  end

  defp host_macs_by_ref(network_interfaces) do
    network_interfaces
    |> Enum.reject(&present?(Map.get(&1, :guest_provider_ref)))
    |> mac_list_by_ref(:host_provider_ref)
  end

  defp mac_list_by_ref(network_interfaces, ref_key) do
    Enum.reduce(network_interfaces, %{}, fn iface, acc ->
      ref = Map.get(iface, ref_key)
      mac = normalize_mac_identifier(Map.get(iface, :mac_address))

      if present?(ref) and present?(mac) do
        Map.update(acc, ref, [mac], &Enum.uniq(&1 ++ [mac]))
      else
        acc
      end
    end)
  end

  # Resolve hypervisor hosts by their own NIC MACs (when the provider
  # supplies them) through the DIRE lookup path, so a host that already
  # exists as a discovered/agent device resolves instead of minting a
  # parallel placeholder.
  defp network_identity_by_host(records, actor) do
    host_macs = host_macs_by_ref(records.network_interfaces)

    Enum.reduce(records.hosts, %{}, fn record, acc ->
      ref = Map.get(record, :provider_ref)
      macs = Map.get(host_macs, ref, [])

      with [_ | _] <- macs,
           uid when is_binary(uid) <-
             lookup_device_by_macs(macs, metadata_partition(record), actor) do
        Map.put(acc, ref, uid)
      else
        _ -> acc
      end
    end)
  end

  defp lookup_device_by_macs(macs, partition, actor) do
    ids =
      IdentityReconciler.extract_strong_identifiers(%{
        device_id: nil,
        ip: nil,
        mac: nil,
        mac_addresses: macs,
        partition: partition,
        metadata: %{}
      })

    case IdentityReconciler.lookup_by_strong_identifiers(ids, actor) do
      {:ok, uid} when is_binary(uid) and uid != "" -> uid
      _ -> nil
    end
  end

  defp network_identity_by_guest(network_interfaces, _actor) do
    identities =
      network_interfaces
      |> Enum.filter(&present?(Map.get(&1, :guest_provider_ref)))
      |> Enum.flat_map(fn iface ->
        guest_ref = Map.fetch!(iface, :guest_provider_ref)

        macs =
          iface
          |> Map.get(:mac_address)
          |> List.wrap()
          |> Enum.map(&normalize_mac_identifier/1)
          |> Enum.filter(&present?/1)

        ips =
          iface
          |> Map.get(:ip_addresses, [])
          |> Enum.map(&normalize_ip_identifier/1)
          |> Enum.filter(&present?/1)

        partition =
          iface
          |> Map.get(:metadata, %{})
          |> string_value("partition")
          |> Kernel.||("default")

        Enum.map(macs, &%{guest_ref: guest_ref, type: :mac, value: &1, partition: partition}) ++
          Enum.map(ips, &%{guest_ref: guest_ref, type: :ip, value: &1, partition: partition})
      end)

    if identities == [] do
      %{}
    else
      identifiers =
        identities
        |> Enum.map(&Map.take(&1, [:type, :value, :partition]))
        |> Enum.uniq()

      identifier_to_device = lookup_identifier_devices(identifiers)

      Enum.reduce(identities, %{}, fn identity, acc ->
        key = {identity.type, identity.value, identity.partition}

        case Map.get(identifier_to_device, key) do
          uid when is_binary(uid) and uid != "" -> Map.put_new(acc, identity.guest_ref, uid)
          _ -> acc
        end
      end)
    end
  end

  defp lookup_identifier_devices(identifiers) do
    types = Enum.map(identifiers, &to_string(&1.type))
    values = Enum.map(identifiers, & &1.value)
    partitions = Enum.map(identifiers, &(&1.partition || "default"))

    case Repo.query(identifier_lookup_sql(), [types, values, partitions]) do
      {:ok, %{rows: rows}} ->
        Map.new(rows, fn [type, value, partition, device_id] ->
          {{identifier_type_atom(type), value, partition || "default"}, device_id}
        end)

      {:error, reason} ->
        Logger.warning(
          "Hypervisor enrichment device identifier lookup failed: #{inspect(reason)}"
        )

        %{}
    end
  end

  defp identifier_lookup_sql do
    """
    WITH wanted(identifier_type, identifier_value, partition) AS (
      SELECT * FROM unnest($1::text[], $2::text[], $3::text[])
    )
    SELECT DISTINCT ON (di.identifier_type::text, di.identifier_value, COALESCE(di.partition, 'default'))
      di.identifier_type::text,
      di.identifier_value,
      COALESCE(di.partition, 'default') AS partition,
      di.device_id
    FROM platform.device_identifiers di
    JOIN wanted w
      ON di.identifier_type::text = w.identifier_type
     AND di.identifier_value = w.identifier_value
     AND COALESCE(di.partition, 'default') = COALESCE(w.partition, 'default')
    ORDER BY di.identifier_type::text, di.identifier_value, COALESCE(di.partition, 'default'), di.last_seen DESC NULLS LAST
    """
  end

  defp identifier_type_atom("ip"), do: :ip
  defp identifier_type_atom("mac"), do: :mac
  defp identifier_type_atom("integration_id"), do: :integration_id
  defp identifier_type_atom(_value), do: nil

  defp resolve_record_device_uid(record, devices, identity_maps) do
    current_uid = Map.get(record, :device_uid)

    Map.put(record, :device_uid, resolved_device_uid(record, devices, identity_maps, current_uid))
  end

  defp resolve_record_device_uid(record, devices, identity_maps, actor, claim_type) do
    current_uid = reusable_current_uid(Map.get(record, :device_uid), claim_type, actor)

    Map.put(record, :device_uid, resolved_device_uid(record, devices, identity_maps, current_uid))
  end

  defp resolved_device_uid(record, devices, identity_maps, current_uid) do
    Map.get(devices.by_uid, current_uid) ||
      lookup_device_by_identity_maps(record, identity_maps) ||
      maybe_lookup_device_by_record_name(record, devices) ||
      existing_sr_uid(current_uid)
  end

  defp maybe_lookup_device_by_record_name(record, devices) do
    if authoritative_v3_record?(record) do
      nil
    else
      lookup_device_by_record_name(record, devices)
    end
  end

  defp authoritative_v3_record?(record) when is_map(record) do
    Map.get(record, :identity_version) == 3 and
      Map.get(record, :identity_state) in [:authoritative, "authoritative"]
  end

  defp authoritative_v3_record?(_record), do: false

  defp reusable_current_uid(uid, claim_type, actor) do
    if DeviceClaimPolicy.reusable_for_claim?(uid, claim_type, actor), do: uid
  end

  defp lookup_device_by_identity_maps(record, identity_maps) do
    refs = identity_lookup_refs(record)

    Enum.find_value(identity_maps, fn identity_map ->
      Enum.find_value(refs, &Map.get(identity_map, &1))
    end)
  end

  # Guest-scoped records resolve through their guest ref; host-scoped
  # records (hosts themselves, host disks/NICs) fall back to the host ref.
  defp identity_lookup_refs(record) do
    refs =
      case Map.get(record, :guest_provider_ref) do
        guest_ref when is_binary(guest_ref) and guest_ref != "" ->
          [guest_ref, Map.get(record, :provider_ref)]

        _ ->
          [Map.get(record, :provider_ref), Map.get(record, :host_provider_ref)]
      end

    Enum.filter(refs, &present?/1)
  end

  defp lookup_device_by_record_name(record, devices) do
    Enum.find_value(
      [
        Map.get(record, :name),
        node_name_from_provider_ref(Map.get(record, :provider_ref))
      ],
      fn value ->
        Map.get(devices.by_name, normalize_lookup_key(value))
      end
    )
  end

  defp existing_sr_uid(value) when is_binary(value) do
    if String.starts_with?(value, "sr:"), do: value
  end

  defp existing_sr_uid(_value), do: nil

  defp node_name_from_provider_ref(value) when is_binary(value) do
    case String.split(value, ":") do
      [_provider, "node", node | _] -> node
      [_provider, "host", host | _] -> host
      [_provider, kind, node | _] when kind in ["disk", "nic", "guest"] -> node
      _ -> nil
    end
  end

  defp node_name_from_provider_ref(_value), do: nil

  defp normalize_lookup_key(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.trim()
    |> blank_to_nil()
  end

  defp normalize_lookup_key(_value), do: nil

  defp upsert_group(_resource, [], _actor), do: {:ok, %{}}

  defp upsert_group(resource, rows, actor) do
    rows =
      rows
      |> Enum.map(&strip_ref_helpers/1)
      |> Enum.uniq_by(&{&1.provider, &1.provider_ref})

    case Ash.bulk_create(rows, resource, :create,
           actor: actor,
           domain: ServiceRadar.Inventory,
           return_records?: true,
           return_errors?: true,
           stop_on_error?: false,
           upsert?: true,
           upsert_identity: :unique_provider_ref,
           upsert_fields: upsert_fields(resource)
         ) do
      %Ash.BulkResult{status: :success, records: records} ->
        {:ok, Map.new(records, &{{&1.provider, &1.provider_ref}, &1.id})}

      %Ash.BulkResult{errors: errors} = result ->
        {:error, errors || result}
    end
  end

  defp referenced_provider_refs(records, ref_key) do
    records
    |> Map.values()
    |> List.flatten()
    |> Enum.map(&{Map.get(&1, :provider), Map.get(&1, ref_key)})
    |> Enum.filter(fn {provider, provider_ref} ->
      present?(provider) and present?(provider_ref)
    end)
    |> Enum.uniq()
  end

  defp load_existing_reference_ids(_resource, known_ids, [], _actor), do: {:ok, known_ids}

  defp load_existing_reference_ids(resource, known_ids, provider_refs, actor) do
    missing_refs = Enum.reject(provider_refs, &Map.has_key?(known_ids, &1))

    if missing_refs == [] do
      {:ok, known_ids}
    else
      providers = missing_refs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      provider_refs = missing_refs |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
      missing_ref_set = MapSet.new(missing_refs)

      resource
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(provider in ^providers and provider_ref in ^provider_refs)
      |> Ash.read(actor: actor)
      |> case do
        {:ok, records} ->
          existing_ids =
            records
            |> Enum.filter(&MapSet.member?(missing_ref_set, {&1.provider, &1.provider_ref}))
            |> Map.new(&{{&1.provider, &1.provider_ref}, &1.id})

          {:ok, Map.merge(known_ids, existing_ids)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp upsert_fields(VirtualizationCluster),
    do: [:name, :status, :version, :metadata, :observed_at, :updated_at]

  defp upsert_fields(VirtualizationHost) do
    [
      :cluster_id,
      :device_uid,
      :name,
      :status,
      :version,
      :cpu_ratio,
      :memory_used_bytes,
      :memory_total_bytes,
      :uptime_seconds,
      :metadata,
      :observed_at,
      :updated_at
    ]
  end

  defp upsert_fields(VirtualizationGuest) do
    [
      :host_id,
      :device_uid,
      :name,
      :guest_type,
      :vmid,
      :status,
      :cpu_ratio,
      :memory_used_bytes,
      :memory_total_bytes,
      :disk_used_bytes,
      :disk_total_bytes,
      :uptime_seconds,
      :metadata,
      :observed_at,
      :updated_at
    ]
  end

  defp upsert_fields(VirtualizationDatastore) do
    [
      :cluster_id,
      :host_id,
      :name,
      :storage_type,
      :content,
      :active,
      :enabled,
      :shared,
      :used_bytes,
      :available_bytes,
      :total_bytes,
      :metadata,
      :observed_at,
      :updated_at
    ]
  end

  defp upsert_fields(VirtualizationHostDisk) do
    [
      :host_id,
      :device_uid,
      :path,
      :by_id,
      :disk_type,
      :vendor,
      :model,
      :health,
      :size_bytes,
      :wearout,
      :usage,
      :metadata,
      :observed_at,
      :updated_at
    ]
  end

  defp upsert_fields(VirtualizationNetworkInterface) do
    [
      :host_id,
      :guest_id,
      :guest_provider_ref,
      :device_uid,
      :name,
      :interface_type,
      :active,
      :exists,
      :method,
      :method6,
      :address,
      :cidr,
      :gateway,
      :bridge_ports,
      :vlan_id,
      :mac_address,
      :ip_addresses,
      :source,
      :metadata,
      :observed_at,
      :updated_at
    ]
  end

  defp upsert_fields(VirtualizationStorageSystem) do
    [
      :cluster_id,
      :host_id,
      :name,
      :storage_system_type,
      :health,
      :status,
      :metadata,
      :observed_at,
      :updated_at
    ]
  end

  defp link_refs(rows, cluster_ids, host_ids) do
    Enum.map(rows, fn row ->
      row
      |> maybe_link_ref(:cluster_provider_ref, :cluster_id, cluster_ids)
      |> maybe_link_ref(:host_provider_ref, :host_id, host_ids)
    end)
  end

  defp link_network_interface_refs(rows, host_ids, guest_ids) do
    Enum.map(rows, fn row ->
      row
      |> maybe_link_ref(:host_provider_ref, :host_id, host_ids)
      |> maybe_link_ref(:guest_provider_ref, :guest_id, guest_ids)
    end)
  end

  defp maybe_link_ref(row, ref_key, id_key, id_map) do
    case {Map.get(row, :provider), Map.get(row, ref_key)} do
      {provider, ref} when is_binary(provider) and is_binary(ref) ->
        Map.put(row, id_key, Map.get(id_map, {provider, ref}))

      _ ->
        row
    end
  end

  defp strip_ref_helpers(row) do
    Map.drop(row, [:cluster_provider_ref, :host_provider_ref, :legacy_provider_refs])
  end

  defp list_value(map, key) when is_map(map), do: map |> field_value(key) |> list()
  defp list_value(_map, _key), do: []

  defp list(values) when is_list(values), do: Enum.filter(values, &is_map/1)
  defp list(_values), do: []

  defp string_value(map, key) when is_map(map) do
    case field_value(map, key) do
      value when is_binary(value) -> value |> String.trim() |> blank_to_nil()
      value when is_integer(value) -> Integer.to_string(value)
      value when is_float(value) -> Float.to_string(value)
      _ -> nil
    end
  end

  defp string_value(_map, _key), do: nil

  defp list_string(value) when is_list(value) do
    value
    |> Enum.map(&stringify_scalar/1)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&present?/1)
  end

  defp list_string(value) when is_binary(value) do
    value
    |> String.split([",", " "], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&present?/1)
  end

  defp list_string(_value), do: []

  defp stringify_scalar(value) when is_binary(value), do: value
  defp stringify_scalar(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify_scalar(value) when is_float(value), do: Float.to_string(value)
  defp stringify_scalar(_value), do: ""

  defp normalize_mac_identifier(value) when is_binary(value) do
    case IdentityReconciler.normalize_mac(value) do
      normalized when is_binary(normalized) and byte_size(normalized) == 12 -> normalized
      _ -> nil
    end
  end

  defp normalize_mac_identifier(_value), do: nil

  defp normalize_ip_identifier(value) when is_binary(value) do
    value
    |> strip_cidr()
    |> normalize_ip_cidr()
  end

  defp normalize_ip_identifier(_value), do: nil

  defp normalize_ip_cidr(value) when is_binary(value) do
    value = String.trim(value)

    case String.downcase(value) do
      "" -> nil
      "dhcp" -> nil
      "auto" -> nil
      "manual" -> nil
      "none" -> nil
      _ -> value
    end
  end

  defp normalize_ip_cidr(_value), do: nil

  defp strip_cidr(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.split("/", parts: 2)
    |> List.first()
    |> blank_to_nil()
  end

  defp strip_cidr(_value), do: nil

  defp field_value(map, key) do
    string_key = to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> nil
    end
  end

  defp sanitize_metadata(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, acc ->
      key = to_string(key)

      if sensitive_key?(key) do
        acc
      else
        Map.put(acc, key, sanitize_metadata(raw_value))
      end
    end)
  end

  defp sanitize_metadata(value) when is_list(value), do: Enum.map(value, &sanitize_metadata/1)

  defp sanitize_metadata(value) when is_binary(value) do
    if String.contains?(value, "PVEAPIToken="), do: "REDACTED", else: value
  end

  defp sanitize_metadata(value), do: value

  defp sensitive_key?(key) do
    normalized = String.downcase(String.trim(key))

    Enum.any?(
      [
        "password",
        "passwd",
        "secret",
        "token",
        "credential",
        "apikey",
        "api_key",
        "privatekey",
        "private_key"
      ],
      &String.contains?(normalized, &1)
    )
  end

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
  defp blank?(value), do: value in [nil, ""]
  defp present?(value), do: not blank?(value)
  defp first_non_empty(left, right) when left in [nil, ""], do: right
  defp first_non_empty(left, _right), do: left
end
