defmodule ServiceRadar.Inventory.HypervisorEnrichmentIngestor do
  @moduledoc """
  Ingests provider-neutral hypervisor enrichment records into virtualization inventory.

  Provider-specific collectors should normalize API-native shapes into this
  shared record set before persistence. Proxmox currently adapts its legacy
  payload into these records; future vSphere/vCenter support should emit this
  envelope directly.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Dgraph
  alias ServiceRadar.Inventory.Availability.SyncEvidence
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceClaimPolicy
  alias ServiceRadar.Inventory.DevicePubSub
  alias ServiceRadar.Inventory.Identity.GuestAddress
  alias ServiceRadar.Inventory.Identity.SourceAuthorityGuard
  alias ServiceRadar.Inventory.Identity.SourceRetirement
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.IntegrationIdentity
  alias ServiceRadar.Inventory.MergeAudit
  alias ServiceRadar.Inventory.Sync.IdentifierRecords
  alias ServiceRadar.Inventory.Sync.Normalize
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Inventory.VirtualizationCluster
  alias ServiceRadar.Inventory.VirtualizationDatastore
  alias ServiceRadar.Inventory.VirtualizationGuest
  alias ServiceRadar.Inventory.VirtualizationHost
  alias ServiceRadar.Inventory.VirtualizationHostDisk
  alias ServiceRadar.Inventory.VirtualizationIdentityAliases
  alias ServiceRadar.Inventory.VirtualizationNetworkInterface
  alias ServiceRadar.Inventory.VirtualizationStorageSystem
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.DgraphPersist
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @schema "serviceradar.hypervisor_enrichment.v1"
  @hosted_page_size 500

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
    records
    |> Map.new(fn {key, values} ->
      {key, dedupe_provider_refs(values)}
    end)
    |> normalize_host_management_ips()
  end

  def persist_records(records, opts) do
    actor = Keyword.fetch!(opts, :actor)

    with :ok <- validate_source_scoped_identities(records),
         :ok <- validate_trusted_proxmox_source_binding(records, opts),
         records = discard_untrusted_proxmox_device_uids(records),
         {:ok, records} <- resolve_existing_device_uids(records, actor),
         records = normalize_host_management_ips(records),
         {:ok, records} <- ensure_inventory_devices(records, actor),
         {:ok, records} <- resolve_existing_device_uids(records, actor),
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
         {:ok, _} <- upsert_group(VirtualizationStorageSystem, storage_systems, actor),
         :ok <- VirtualizationIdentityAliases.reconcile(records),
         :ok <- retire_legacy_proxmox_records(records, actor),
         :ok <- reconcile_saved_guest_ids(Map.values(guest_ids), actor) do
      if !Repo.in_transaction?() do
        nics |> Stream.map(& &1[:device_uid]) |> DevicePubSub.broadcast_invalidated()
      end

      enqueue_world_reconcile()
    end
  end

  defp retire_legacy_proxmox_records(records, actor) when is_map(records) do
    proxmox_records =
      [:clusters, :hosts, :guests]
      |> Enum.flat_map(&Map.get(records, &1, []))
      |> Enum.filter(&(to_string(Map.get(&1, :provider) || Map.get(&1, "provider")) == "proxmox"))

    if proxmox_records == [] do
      :ok
    else
      partitions =
        proxmox_records
        |> Enum.map(fn record ->
          metadata = Map.get(record, :metadata) || Map.get(record, "metadata") || %{}
          string_value(metadata, "partition") || "default"
        end)
        |> Enum.uniq()

      Enum.each(partitions, fn partition ->
        _ = SourceRetirement.retire_legacy_proxmox_identifiers(partition: partition, actor: actor)
      end)

      :ok
    end
  rescue
    e ->
      Logger.warning(
        "HypervisorEnrichmentIngestor: legacy Proxmox retirement failed: #{Exception.message(e)}"
      )

      :ok
  end

  defp retire_legacy_proxmox_records(_records, _actor), do: :ok

  @doc "Repairs one bounded page of saved owners and existing projections."
  def reconcile_hosted_topology(checkpoint \\ %{}) do
    actor = SystemActor.system(:topology_world)

    with {:ok, guests} <- hosted_guest_page(checkpoint, actor),
         {:ok, edges} <- hosted_projection_page(checkpoint),
         :ok <- Enum.reduce_while(guests, :ok, &reconcile_saved_guest(&1, &2, actor)),
         :ok <- Enum.reduce_while(edges, :ok, &reconcile_saved_projection(&1, &2, actor)) do
      checkpoint =
        checkpoint
        |> advance_hosted_page("guests", guests, fn guest -> guest.id end)
        |> advance_hosted_page("edges", edges, fn edge -> edge["uid"] end)

      {:ok, checkpoint}
    end
  end

  defp hosted_guest_page(checkpoint, actor) do
    if checkpoint["guests_done"] do
      {:ok, []}
    else
      query = hosted_guest_query() |> Ash.Query.sort(:id) |> Ash.Query.limit(@hosted_page_size)
      cursor = checkpoint["guests_cursor"]
      query = if cursor, do: Ash.Query.filter(query, id > ^cursor), else: query
      with {:ok, page} <- Ash.read(query, actor: actor), do: Page.unwrap(page)
    end
  end

  defp hosted_guest_query do
    VirtualizationGuest |> Ash.Query.for_read(:read) |> Ash.Query.load(:host)
  end

  defp hosted_projection_page(checkpoint) do
    if checkpoint["edges_done"] do
      {:ok, []}
    else
      cursor = checkpoint["edges_cursor"] || "0x0"

      if Regex.match?(~r/^0x[0-9a-f]+$/, cursor) do
        query =
          "{ edges(func: eq(topo.ingestor, \"hypervisor_enrichment_v1\"), first: #{@hosted_page_size}, after: #{cursor}) @filter(eq(topo.kind, \"HOSTED_ON\")) { uid observed_at: topo.last_seen source: topo.src { id: device.id } target: topo.dst { id: device.id } } }"

        case Dgraph.query(query) do
          {:ok, %{"edges" => edges}} when is_list(edges) ->
            if Enum.all?(edges, &valid_hosted_projection?/1),
              do: {:ok, edges},
              else: {:error, :incomplete_hosted_projection_page}

          {:error, _reason} = error ->
            error

          _ ->
            {:error, :incomplete_hosted_projection_page}
        end
      else
        {:error, :invalid_hosted_projection_cursor}
      end
    end
  end

  defp valid_hosted_projection?(%{
         "uid" => uid,
         "source" => [%{"id" => source}],
         "target" => [%{"id" => target}],
         "observed_at" => observed_at
       }) do
    is_binary(uid) and is_binary(source) and is_binary(target) and is_binary(observed_at)
  end

  defp valid_hosted_projection?(_), do: false

  defp advance_hosted_page(checkpoint, name, rows, cursor) do
    checkpoint
    |> Map.put(name <> "_done", length(rows) < @hosted_page_size)
    |> Map.put(
      name <> "_cursor",
      if(rows == [], do: checkpoint[name <> "_cursor"], else: cursor.(List.last(rows)))
    )
  end

  defp reconcile_saved_guest_ids([], _actor), do: :ok

  defp reconcile_saved_guest_ids(ids, actor) do
    query = Ash.Query.filter(hosted_guest_query(), id in ^ids)

    with {:ok, page} <- Ash.read(query, actor: actor),
         {:ok, guests} <- Page.unwrap(page) do
      Enum.reduce_while(guests, :ok, &reconcile_saved_guest(&1, &2, actor))
    end
  end

  defp saved_hosted_link(guest, actor) do
    with %{host: host} when is_map(host) <- guest,
         false <- guest.identity_state == :quarantined or host.identity_state == :quarantined,
         guest_uid when is_binary(guest_uid) <- guest.device_uid,
         host_uid when is_binary(host_uid) <- host.device_uid,
         {:ok, guest_uid} <- live_canonical_device_uid(guest_uid, actor),
         {:ok, host_uid} <- live_canonical_device_uid(host_uid, actor),
         false <- guest_uid == host_uid do
      {:ok,
       %{
         guest_device_id: guest_uid,
         host_device_id: host_uid,
         observed_at: observed_at_string(guest.observed_at)
       }}
    else
      {:error, _reason} = error -> error
      _ -> {:skip, :invalid_saved_owner}
    end
  end

  defp reconcile_saved_guest(guest, :ok, actor) do
    case saved_hosted_link(guest, actor) do
      # A valid owner without an observation can retain last-known evidence,
      # but cannot create or refresh it from a host heartbeat.
      {:ok, %{observed_at: nil}} -> {:cont, :ok}
      {:ok, link} -> reduce_hosted_result(DgraphPersist.upsert_hosted_link(link))
      {:skip, _reason} -> {:cont, :ok}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp reconcile_saved_projection(
         %{
           "source" => [%{"id" => source}],
           "target" => [%{"id" => target}],
           "observed_at" => observed_at
         },
         :ok,
         actor
       ) do
    with {:ok, owner_ids} <- hosted_owner_ids([source], [source], 5, actor),
         query = Ash.Query.filter(hosted_guest_query(), device_uid in ^owner_ids),
         {:ok, guests} <- complete_hosted_read(query, actor),
         {:ok, links} <- saved_hosted_links(guests, actor),
         {:ok, live?} <- live_hosted_projection(source, target, actor) do
      if live? and Enum.any?(links, &(&1.guest_device_id == source)) do
        {:cont, :ok}
      else
        reduce_hosted_result(DgraphPersist.retire_hosted_link(source, target, observed_at))
      end
    else
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp live_hosted_projection(source, target, actor) do
    with {:ok, ^source} <- live_canonical_device_uid(source, actor),
         {:ok, ^target} <- live_canonical_device_uid(target, actor) do
      {:ok, true}
    else
      {:error, _reason} = error -> error
      _ -> {:ok, false}
    end
  end

  # Inventory may retain the original UID after a canonical merge. Read its
  # bounded ancestry before concluding that the saved owner no longer exists.
  defp hosted_owner_ids(_ids, _frontier, 0, _actor),
    do: {:error, :incomplete_hosted_owner_ancestry}

  defp hosted_owner_ids(ids, frontier, depth, actor) do
    # Audit rows are events. Bound unique identities at the source so repeated
    # events neither re-enter the frontier nor consume the ancestry budget.
    query =
      MergeAudit
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(to_device_id in ^frontier)
      |> Ash.Query.select([:from_device_id])
      |> Ash.Query.distinct(:from_device_id)
      |> Ash.Query.limit(@hosted_page_size + 1)

    with {:ok, merges} <- complete_hosted_read(query, actor) do
      ancestors = Enum.map(merges, & &1.from_device_id) -- ids

      cond do
        ancestors == [] ->
          {:ok, ids}

        length(ids) + length(ancestors) > @hosted_page_size ->
          {:error, :incomplete_hosted_owner_ancestry}

        true ->
          hosted_owner_ids(ids ++ ancestors, ancestors, depth - 1, actor)
      end
    end
  end

  defp complete_hosted_read(query, actor) do
    case Ash.read(query, actor: actor) do
      {:ok, %{more?: true}} -> {:error, :incomplete_hosted_inventory_read}
      {:ok, page} -> Page.unwrap(page)
      {:error, _reason} = error -> error
    end
  end

  defp saved_hosted_links(guests, actor) do
    Enum.reduce_while(guests, {:ok, []}, fn guest, {:ok, links} ->
      case saved_hosted_link(guest, actor) do
        {:ok, link} -> {:cont, {:ok, [link | links]}}
        {:skip, _reason} -> {:cont, {:ok, links}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp reduce_hosted_result(:ok), do: {:cont, :ok}
  defp reduce_hosted_result({:error, _reason} = error), do: {:halt, error}

  defp enqueue_world_reconcile do
    case ServiceRadar.NetworkDiscovery.WorldWorker.enqueue_reconcile() do
      {:ok, _job} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp live_canonical_device_uid(uid, actor) do
    with {:ok, canonical_uid} <- IdentityReconciler.resolve_canonical_device_id(uid, actor) do
      query =
        Device
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(uid == ^canonical_uid and is_nil(deleted_at))

      case Ash.read_one(query, actor: actor) do
        {:ok, %Device{}} -> {:ok, canonical_uid}
        {:ok, nil} -> {:skip, {:missing_or_inactive_virtualization_endpoint, canonical_uid}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp observed_at_string(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp observed_at_string(timestamp) when is_binary(timestamp), do: timestamp
  defp observed_at_string(_), do: nil

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

    with {:ok, integration_identity} <- integration_identity_by_ref(records),
         {:ok, guest_resolution} <-
           resolve_guest_network_and_awx_candidates(records, integration_identity, actor),
         {:ok, host_network_identity} <- network_identity_by_host(records, actor),
         {:ok, devices} <- lookup_devices(current_uids, names, actor) do
      network_identity = guest_resolution.by_ref
      guest_identity_maps = [integration_identity, network_identity]
      host_identity_maps = [integration_identity, host_network_identity]

      {:ok,
       Map.merge(records, %{
         hosts:
           Enum.map(records.hosts, &resolve_record_device_uid(&1, devices, host_identity_maps)),
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
           Enum.map(
             records.host_disks,
             &resolve_record_device_uid(&1, devices, host_identity_maps)
           ),
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
       })}
    end
  end

  defp ensure_inventory_devices(records, actor) do
    with {:ok, integration_identity} <- integration_identity_by_ref(records),
         {:ok, guest_resolution} <-
           resolve_guest_network_and_awx_candidates(records, integration_identity, actor),
         :ok <-
           reconcile_guest_device_merges(
             records.guests,
             guest_resolution.merge_sources,
             actor
           ) do
      guest_ip_by_ref =
        Map.merge(
          guest_resolution.inferred_ips,
          primary_ip_by_guest(records.network_interfaces)
        )

      host_ip_by_ref = primary_ip_by_host(records.network_interfaces)
      guest_macs = guest_macs_by_ref(records.network_interfaces)
      host_macs = host_macs_by_ref(records.network_interfaces)

      host_updates =
        records.hosts
        |> Enum.filter(&missing_device_uid?/1)
        |> Enum.map(fn record ->
          placeholder_device_update(
            record,
            :hypervisor,
            Map.get(host_ip_by_ref, Map.get(record, :provider_ref)),
            host_macs
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
          existing_device_updates(records.hosts, :hypervisor, host_ip_by_ref, host_macs) ++
          existing_device_updates(records.guests, :virtual_guest, guest_ip_by_ref, guest_macs)

      ingest_result =
        case updates do
          [] ->
            :ok

          _ ->
            # Records left without a device_uid get resolved by the follow-up
            # resolve_existing_device_uids pass via the integration_id identifier
            # rows the reconciler registered for these updates.
            SyncIngestor.ingest_updates(updates,
              actor: actor,
              availability_evidence: &availability_observation/1
            )
        end

      case ingest_result do
        :ok ->
          :ok =
            sync_existing_device_mac_identities(records, guest_macs, host_macs, actor)

          {:ok, records}

        {:error, reason} ->
          {:error, reason}
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
  defp placeholder_device_update(record, role, ip_override, macs_by_ref) do
    provider_ref = Map.fetch!(record, :provider_ref)
    partition = metadata_partition(record)
    ip = first_non_empty(ip_override, metadata_ip(record))
    macs = Map.get(macs_by_ref, provider_ref, [])

    metadata = placeholder_device_metadata(record, role, macs_by_ref)

    %{
      "hostname" => Map.get(record, :name) || provider_ref,
      "partition" => partition,
      "source" => "hypervisor_enrichment",
      "is_available" => available_status?(Map.get(record, :status)),
      "metadata" => metadata
    }
    |> maybe_put("ip", ip)
    |> maybe_put("mac", List.first(macs))
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

  defp existing_device_updates(records, role, ip_by_ref, macs_by_ref) do
    records
    |> Enum.reject(&missing_device_uid?/1)
    |> Enum.flat_map(fn record ->
      provider_ref = Map.get(record, :provider_ref)

      ip =
        first_non_empty(
          Map.get(ip_by_ref, provider_ref),
          metadata_ip(record)
        )

      macs = Map.get(macs_by_ref, provider_ref, [])

      case existing_sr_uid(Map.get(record, :device_uid)) do
        uid when is_binary(uid) ->
          [
            %{
              "device_id" => uid,
              "partition" => metadata_partition(record),
              "source" => "hypervisor_enrichment",
              "metadata" => placeholder_device_metadata(record, role, macs_by_ref)
            }
            |> maybe_put("ip", ip)
            |> maybe_put("mac", List.first(macs))
          ]

        _ ->
          []
      end
    end)
  end

  defp placeholder_device_metadata(record, role, macs_by_ref) do
    provider_ref = Map.fetch!(record, :provider_ref)
    integration_id = record_integration_id(record) || provider_ref
    macs = Map.get(macs_by_ref, provider_ref, [])

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
              legacy_record_fields(record, macs_by_ref)
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
    |> maybe_put_mac_addresses(macs)
    |> maybe_put_legacy_integration_ids(legacy_integration_ids)
    |> maybe_put_proxmox_candidate(record, role)
  end

  defp maybe_put_mac_addresses(metadata, []), do: metadata

  defp maybe_put_mac_addresses(metadata, macs) when is_list(macs),
    do: Map.put(metadata, "mac_addresses", macs)

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

  # A guest's interfaces include the networks it runs for itself (container
  # bridges, CNI overlays); GuestAddress keeps those from becoming its primary.
  defp primary_ip_by_guest(network_interfaces) do
    network_interfaces
    |> Enum.filter(&present?(Map.get(&1, :guest_provider_ref)))
    |> Enum.group_by(&Map.get(&1, :guest_provider_ref))
    |> Enum.reduce(%{}, fn {guest_ref, interfaces}, acc ->
      case GuestAddress.primary(interfaces) do
        nil -> acc
        ip -> Map.put(acc, guest_ref, ip)
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

    name = iface |> Map.get(:name) |> to_string() |> String.downcase() |> String.trim()

    if String.starts_with?(name, ["vmbr", "br"]) and not GuestAddress.host_internal_name?(name) do
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

  # Availability evidence is the hypervisor's reported status only. A record with no
  # status still writes is_available false through the legacy path
  # (available_status?/1), but it is no evidence.
  @doc false
  def availability_observation(update) do
    metadata = Map.get(update, :metadata) || %{}

    case metadata["hypervisor_status"] do
      status when is_binary(status) and status != "" ->
        %{
          source_kind: "hypervisor",
          source_instance: metadata["hypervisor_provider"],
          state: if(available_status?(status), do: :up, else: :down),
          observed_at: SyncEvidence.observed_at(update),
          detail: %{"status" => status}
        }

      _missing ->
        nil
    end
  end

  defp available_status?(status) when is_binary(status) do
    status
    |> String.downcase()
    |> String.trim()
    |> Kernel.in(["online", "running", "connected", "poweredon", "ok", "available"])
  end

  defp available_status?(_status), do: false

  defp lookup_devices([], [], _actor), do: {:ok, %{by_uid: %{}, by_name: %{}}}

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
        {:ok,
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
         }}

      {:error, reason} ->
        Logger.warning("Hypervisor enrichment device lookup failed: #{inspect(reason)}")
        {:error, {:device_lookup_failed, reason}}
    end
  end

  defp device_lookup_sql do
    """
    SELECT uid, name, hostname
    FROM platform.ocsf_devices
    WHERE deleted_at IS NULL
      AND (
        uid = ANY($1::text[])
        -- A record marked source_retired is awaiting deletion: sharing a name never adopts it.
        OR (source_retired_at IS NULL
          AND (LOWER(name) = ANY($2::text[]) OR LOWER(hostname) = ANY($2::text[])))
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
      {:ok, %{}}
    else
      case lookup_identifier_devices(wanted) do
        {:ok, identifier_to_device} ->
          identity_map =
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

          {:ok, identity_map}

        {:error, _} = error ->
          error
      end
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
    |> Enum.filter(fn iface ->
      present?(Map.get(iface, :guest_provider_ref)) and
        not host_internal_guest_interface?(iface)
    end)
    |> Enum.sort_by(fn iface ->
      {
        guest_interface_identity_rank(iface),
        to_string(Map.get(iface, :name) || ""),
        to_string(Map.get(iface, :provider_ref) || "")
      }
    end)
    |> mac_list_by_ref(:guest_provider_ref)
  end

  defp host_macs_by_ref(network_interfaces) do
    network_interfaces
    |> Enum.reject(&present?(Map.get(&1, :guest_provider_ref)))
    |> Enum.reject(&host_internal_guest_interface?/1)
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

  defp guest_interface_identity_rank(iface) do
    if hypervisor_attached_interface?(iface), do: 0, else: 1
  end

  defp hypervisor_attached_interface?(iface) do
    iface
    |> Map.get(:source)
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.any?(&(String.trim(&1) == "config"))
  end

  defp host_internal_guest_interface?(iface) when is_map(iface) do
    name =
      iface
      |> Map.get(:name)
      |> to_string()
      |> String.trim()
      |> String.downcase()

    name == "lo" or
      (not hypervisor_attached_interface?(iface) and GuestAddress.host_internal_name?(name))
  end

  defp host_internal_guest_interface?(_iface), do: false

  # Resolve hypervisor hosts by their own NIC MACs (when the provider
  # supplies them) through the DIRE lookup path, so a host that already
  # exists as a discovered/agent device resolves instead of minting a
  # parallel placeholder.
  defp network_identity_by_host(records, actor) do
    host_macs = host_macs_by_ref(records.network_interfaces)

    Enum.reduce_while(records.hosts, {:ok, %{}}, fn record, {:ok, acc} ->
      ref = Map.get(record, :provider_ref)
      macs = Map.get(host_macs, ref, [])

      case macs do
        [_ | _] ->
          case lookup_device_by_macs(macs, metadata_partition(record), actor) do
            {:ok, uid} when is_binary(uid) and uid != "" ->
              {:cont, {:ok, Map.put(acc, ref, uid)}}

            {:ok, nil} ->
              {:cont, {:ok, acc}}

            {:error, _} = error ->
              {:halt, error}
          end

        _ ->
          {:cont, {:ok, acc}}
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
      {:ok, uid} when is_binary(uid) and uid != "" -> {:ok, uid}
      {:ok, nil} -> {:ok, nil}
      {:error, _} = error -> error
      _ -> {:ok, nil}
    end
  end

  @doc false
  def guest_lookup_identities(network_interfaces) when is_list(network_interfaces) do
    network_interfaces
    |> Enum.filter(&present?(Map.get(&1, :guest_provider_ref)))
    |> Enum.flat_map(fn iface ->
      guest_ref = Map.fetch!(iface, :guest_provider_ref)

      macs =
        if host_internal_guest_interface?(iface) do
          []
        else
          iface
          |> Map.get(:mac_address)
          |> List.wrap()
          |> Enum.map(&normalize_mac_identifier/1)
          |> Enum.filter(&present?/1)
        end

      ips =
        iface
        |> Map.get(:ip_addresses, [])
        |> List.wrap()
        |> Enum.reject(&GuestAddress.host_internal_address?(iface, &1))
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
  end

  defp resolve_guest_network_and_awx_candidates(records, integration_identity, _actor) do
    identities = guest_lookup_identities(records.network_interfaces)
    guest_macs = guest_macs_by_ref(records.network_interfaces)
    guest_ips = guest_discoverable_ips_by_ref(records.network_interfaces)

    all_macs =
      identities
      |> Enum.filter(&(&1.type == :mac))
      |> Enum.map(& &1.value)
      |> Enum.uniq()

    all_ips =
      identities
      |> Enum.filter(&(&1.type == :ip))
      |> Enum.map(& &1.value)
      |> Enum.uniq()

    has_vmids? =
      Enum.any?(records.guests, fn guest ->
        not is_nil(normalize_guest_vmid(Map.get(guest, :vmid)))
      end)

    if all_macs == [] and all_ips == [] and not has_vmids? do
      {:ok, %{by_ref: %{}, merge_sources: %{}, inferred_ips: %{}}}
    else
      case query_guest_candidate_devices(all_ips, all_macs, has_vmids?) do
        {:ok, candidates} ->
          {:ok,
           build_guest_resolution(
             records,
             identities,
             guest_macs,
             guest_ips,
             integration_identity,
             candidates
           )}

        {:error, _} = error ->
          error
      end
    end
  end

  defp guest_discoverable_ips_by_ref(network_interfaces) do
    network_interfaces
    |> guest_lookup_identities()
    |> Enum.filter(&(&1.type == :ip))
    |> Enum.reduce(%{}, fn %{guest_ref: guest_ref, value: ip}, acc ->
      Map.update(acc, guest_ref, [ip], &Enum.uniq(&1 ++ [ip]))
    end)
  end

  defp query_guest_candidate_devices(all_ips, all_macs, has_vmids?) do
    sql = """
    SELECT d.uid,
           d.ip,
           d.mac,
           d.hostname,
           COALESCE(d.partition, 'default') AS partition,
           COALESCE(d.metadata, '{}'::jsonb) AS metadata,
           COALESCE(d.discovery_sources, ARRAY[]::text[]) AS discovery_sources,
           d.agent_id,
           COALESCE(
             ARRAY(
               SELECT di.identifier_value
               FROM platform.device_identifiers di
               WHERE di.device_id = d.uid AND di.identifier_type = 'mac'
             ),
             ARRAY[]::text[]
           ) AS mac_identifiers,
           COALESCE(
             ARRAY(
               SELECT di.identifier_value
               FROM platform.device_identifiers di
               WHERE di.device_id = d.uid AND di.identifier_type = 'ip'
             ),
             ARRAY[]::text[]
           ) AS ip_identifiers,
           COALESCE(
             ARRAY(
               SELECT di.identifier_value
               FROM platform.device_identifiers di
               WHERE di.device_id = d.uid AND di.identifier_type = 'integration_id'
             ),
             ARRAY[]::text[]
           ) AS integration_identifiers
    FROM platform.ocsf_devices d
    -- A record marked source_retired is awaiting deletion, whichever source retired it: no
    -- address, MAC or AWX hint it still carries makes it a guest's device. Adopting it would
    -- not clear the mark, and the grace pass would then delete the guest's record.
    WHERE d.deleted_at IS NULL
      AND d.source_retired_at IS NULL
      AND (
        btrim(COALESCE(d.ip, '')) = ANY($1::text[])
        OR upper(replace(replace(btrim(COALESCE(d.mac, '')), '-', ':'), '.', ':')) = ANY($2::text[])
        OR EXISTS (
          SELECT 1
          FROM platform.device_identifiers di
          WHERE di.device_id = d.uid
            AND (
              (di.identifier_type = 'mac' AND di.identifier_value = ANY($2::text[]))
              OR (di.identifier_type = 'ip' AND di.identifier_value = ANY($1::text[]))
            )
        )
        OR (
          $3::boolean
          AND (
            'awx' = ANY(COALESCE(d.discovery_sources, ARRAY[]::text[]))
            OR COALESCE(d.metadata->>'integration_type', '') = 'awx'
            OR COALESCE(d.metadata, '{}'::jsonb) ? 'awx'
          )
        )
      )
    """

    case Repo.query(sql, [all_ips, all_macs, has_vmids?]) do
      {:ok, %{rows: rows}} ->
        {:ok, Enum.map(rows, &row_to_guest_candidate/1)}

      {:error, reason} ->
        Logger.warning("Hypervisor enrichment guest candidate lookup failed: #{inspect(reason)}")

        {:error, {:identifier_lookup_failed, reason}}
    end
  end

  defp row_to_guest_candidate([
         uid,
         ip,
         mac,
         hostname,
         partition,
         metadata,
         discovery_sources,
         agent_id,
         mac_identifiers,
         ip_identifiers,
         integration_identifiers
       ]) do
    metadata = if is_map(metadata), do: metadata, else: %{}
    awx_info = extract_awx_proxmox_info(metadata, ip)

    macs =
      ([mac | List.wrap(mac_identifiers)] ++ ((awx_info && awx_info.macs) || []))
      |> Enum.map(&normalize_mac_identifier/1)
      |> Enum.filter(&present?/1)
      |> MapSet.new()

    ips =
      [ip | List.wrap(ip_identifiers)]
      |> Enum.map(&normalize_ip_identifier/1)
      |> Enum.filter(&present?/1)
      |> MapSet.new()

    %{
      uid: uid,
      ip: normalize_ip_identifier(ip),
      mac: normalize_mac_identifier(mac),
      hostname: hostname,
      partition: partition || "default",
      metadata: metadata,
      discovery_sources: List.wrap(discovery_sources),
      agent_id: agent_id,
      macs: macs,
      ips: ips,
      integration_identifiers: List.wrap(integration_identifiers),
      awx: awx_info
    }
  end

  defp build_guest_resolution(
         records,
         identities,
         guest_macs,
         guest_ips,
         integration_identity,
         candidates
       ) do
    reserved_host_uids =
      records.hosts
      |> Enum.flat_map(fn host ->
        ref = Map.get(host, :provider_ref)
        [Map.get(host, :device_uid), Map.get(integration_identity, ref)]
      end)
      |> Enum.filter(&present?/1)
      |> MapSet.new()

    guests_by_ref =
      Map.new(records.guests, fn guest -> {Map.get(guest, :provider_ref), guest} end)

    all_guest_refs =
      (Map.keys(guests_by_ref) ++ Enum.map(identities, & &1.guest_ref))
      |> Enum.filter(&present?/1)
      |> Enum.uniq()

    node_vmid_counts =
      Enum.reduce(records.guests, %{}, fn guest, acc ->
        key = {guest_node_name(guest), normalize_guest_vmid(Map.get(guest, :vmid))}

        if elem(key, 1) do
          Map.update(acc, key, 1, &(&1 + 1))
        else
          acc
        end
      end)

    Enum.reduce(
      all_guest_refs,
      %{by_ref: %{}, merge_sources: %{}, inferred_ips: %{}},
      fn guest_ref, acc ->
        guest = Map.get(guests_by_ref, guest_ref, %{provider_ref: guest_ref})
        partition = guest_partition_for_ref(guest, identities, guest_ref)
        integration_uid = Map.get(integration_identity, guest_ref)
        g_macs = guest_macs |> Map.get(guest_ref, []) |> MapSet.new()
        g_ips = guest_ips |> Map.get(guest_ref, []) |> MapSet.new()
        active? = not stopped_guest_status?(Map.get(guest, :status))
        g_vmid = normalize_guest_vmid(Map.get(guest, :vmid))
        g_node = guest_node_name(guest)
        unique_node_vmid? = Map.get(node_vmid_counts, {g_node, g_vmid}, 0) <= 1

        other_guest_uids =
          integration_identity
          |> Enum.reject(fn {ref, _uid} -> ref == guest_ref end)
          |> MapSet.new(&elem(&1, 1))

        matched =
          candidates
          |> Enum.filter(fn cand ->
            cand.partition == partition and
              eligible_guest_candidate?(
                cand,
                guest_ref,
                record_integration_id(guest),
                reserved_host_uids,
                other_guest_uids,
                integration_uid
              )
          end)
          |> Enum.flat_map(fn cand ->
            case classify_guest_candidate_match(
                   cand,
                   g_macs,
                   g_ips,
                   active?,
                   g_node,
                   g_vmid,
                   unique_node_vmid?
                 ) do
              nil -> []
              rank -> [{rank, cand}]
            end
          end)
          |> Enum.sort_by(fn {rank, cand} -> {rank, cand.uid} end)
          |> Enum.map(&elem(&1, 1))
          |> Enum.uniq_by(& &1.uid)

        matched_uids = Enum.map(matched, & &1.uid)

        inferred_ip =
          if MapSet.size(g_ips) == 0 do
            Enum.find_value(matched, fn cand ->
              cand.ip || (cand.awx && cand.awx.ip)
            end)
          end

        by_ref =
          case matched_uids do
            [primary_uid | _] -> Map.put(acc.by_ref, guest_ref, primary_uid)
            [] -> acc.by_ref
          end

        merge_sources =
          case matched_uids do
            [] -> acc.merge_sources
            uids -> Map.put(acc.merge_sources, guest_ref, uids)
          end

        inferred_ips =
          if present?(inferred_ip) do
            Map.put(acc.inferred_ips, guest_ref, inferred_ip)
          else
            acc.inferred_ips
          end

        %{by_ref: by_ref, merge_sources: merge_sources, inferred_ips: inferred_ips}
      end
    )
  end

  defp guest_partition_for_ref(guest, identities, guest_ref) do
    case Map.get(guest, :metadata) do
      %{} = meta when is_map_key(meta, "partition") ->
        metadata_partition(guest)

      _ ->
        identities
        |> Enum.find_value(fn identity ->
          if identity.guest_ref == guest_ref, do: identity.partition
        end)
        |> Kernel.||(metadata_partition(guest))
    end
  end

  defp eligible_guest_candidate?(
         cand,
         guest_ref,
         guest_integration_id,
         reserved_host_uids,
         other_guest_uids,
         integration_uid
       ) do
    device_struct = %Device{
      uid: cand.uid,
      agent_id: cand.agent_id,
      discovery_sources: cand.discovery_sources,
      metadata: cand.metadata
    }

    cand_hv_ids = Enum.filter(cand.integration_identifiers, &hypervisor_integration_id?/1)

    owns_other_hypervisor_id? =
      cand_hv_ids != [] and
        not Enum.any?(cand_hv_ids, &(&1 in [guest_integration_id, guest_ref]))

    not MapSet.member?(reserved_host_uids, cand.uid) and
      not MapSet.member?(other_guest_uids, cand.uid) and
      not owns_other_hypervisor_id? and
      DeviceClaimPolicy.reusable_for_claim?(device_struct, :managed_child_asset) and
      merge_allowed_with_integration_uid?(cand.uid, integration_uid)
  end

  defp hypervisor_integration_id?(value) when is_binary(value) do
    String.starts_with?(value, ["proxmox:", "vsphere:", "esxi:", "hypervisor:"])
  end

  defp hypervisor_integration_id?(_value), do: false

  defp merge_allowed_with_integration_uid?(_cand_uid, nil), do: true
  defp merge_allowed_with_integration_uid?(uid, uid), do: true

  defp merge_allowed_with_integration_uid?(cand_uid, integration_uid) do
    case SourceAuthorityGuard.ensure_merge_allowed([cand_uid, integration_uid]) do
      :ok -> true
      _ -> false
    end
  end

  defp classify_guest_candidate_match(
         cand,
         g_macs,
         g_ips,
         active?,
         g_node,
         g_vmid,
         unique_node_vmid?
       ) do
    mac_match? = MapSet.size(g_macs) > 0 and not MapSet.disjoint?(g_macs, cand.macs)

    mac_contradicts? =
      MapSet.size(g_macs) > 0 and MapSet.size(cand.macs) > 0 and
        MapSet.disjoint?(g_macs, cand.macs)

    ip_match? =
      active? and MapSet.size(g_ips) > 0 and not MapSet.disjoint?(g_ips, cand.ips) and
        not mac_contradicts?

    awx_match? =
      awx_candidate_matches_guest?(
        cand.awx,
        g_node,
        g_vmid,
        g_ips,
        mac_match?,
        ip_match?,
        mac_contradicts?,
        unique_node_vmid?
      )

    cond do
      mac_match? -> 0
      awx_match? and ip_match? -> 1
      ip_match? -> 2
      awx_match? -> 3
      true -> nil
    end
  end

  defp awx_candidate_matches_guest?(
         nil,
         _g_node,
         _g_vmid,
         _g_ips,
         _mac_match?,
         _ip_match?,
         _mac_contradicts?,
         _unique_node_vmid?
       ),
       do: false

  defp awx_candidate_matches_guest?(
         _awx,
         _g_node,
         nil,
         _g_ips,
         _mac_match?,
         _ip_match?,
         _mac_contradicts?,
         _unique_node_vmid?
       ),
       do: false

  defp awx_candidate_matches_guest?(
         awx,
         g_node,
         g_vmid,
         g_ips,
         mac_match?,
         ip_match?,
         mac_contradicts?,
         unique_node_vmid?
       ) do
    vmid_matches? = awx.vmid == g_vmid

    node_matches? =
      is_nil(g_node) or is_nil(awx.node) or
        String.downcase(g_node) == String.downcase(awx.node)

    awx_ip_matches? =
      MapSet.size(g_ips) > 0 and present?(awx.ip) and MapSet.member?(g_ips, awx.ip)

    ip_contradicts? =
      MapSet.size(g_ips) > 0 and present?(awx.ip) and not MapSet.member?(g_ips, awx.ip)

    corroborated_or_unique? =
      mac_match? or ip_match? or awx_ip_matches? or
        (unique_node_vmid? and present?(g_node) and present?(awx.node))

    vmid_matches? and node_matches? and not mac_contradicts? and not ip_contradicts? and
      corroborated_or_unique?
  end

  defp stopped_guest_status?(status) when is_binary(status) do
    status
    |> String.downcase()
    |> String.trim()
    |> Kernel.in(["stopped", "poweredoff", "off", "halted", "suspended", "paused", "template"])
  end

  defp stopped_guest_status?(_status), do: false

  defp guest_node_name(guest) when is_map(guest) do
    meta_node =
      guest
      |> Map.get(:metadata, %{})
      |> string_value("node")

    meta_node ||
      Enum.find_value(
        [Map.get(guest, :host_provider_ref), Map.get(guest, :provider_ref)] ++
          List.wrap(Map.get(guest, :legacy_provider_refs)),
        &node_name_from_provider_ref/1
      )
  end

  defp normalize_guest_vmid(value) when is_integer(value) and value > 0, do: value

  defp normalize_guest_vmid(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_guest_vmid(_value), do: nil

  @doc false
  def extract_awx_proxmox_info(metadata, fallback_ip \\ nil) when is_map(metadata) do
    awx =
      case Map.get(metadata, "awx") || Map.get(metadata, :awx) do
        map when is_map(map) -> map
        _ -> %{}
      end

    vars =
      parse_awx_variables(
        Map.get(awx, "variables") || Map.get(awx, :variables) ||
          Map.get(metadata, "variables") || Map.get(metadata, :variables)
      )

    vmid =
      normalize_guest_vmid(
        first_present_in_maps([awx, metadata, vars], [
          "proxmox_vmid",
          "vmid",
          "hypervisor_vmid"
        ])
      )

    node =
      first_present_in_maps([awx, metadata, vars], [
        "proxmox_node",
        "node",
        "hypervisor_node"
      ])

    vmtype =
      first_present_in_maps([awx, metadata, vars], [
        "proxmox_vmtype",
        "vmtype",
        "hypervisor_vmtype"
      ])

    raw_ip =
      first_present_in_maps([awx, metadata, vars], [
        "ansible_host",
        "ansible_ssh_host"
      ]) || fallback_ip

    ip = normalize_ip_identifier(raw_ip)
    macs = extract_awx_proxmox_macs(awx, metadata, vars)

    if not is_nil(vmid) or present?(node) or present?(vmtype) or present?(ip) or macs != [] do
      %{vmid: vmid, node: node, vmtype: vmtype, ip: ip, macs: macs}
    end
  end

  defp first_present_in_maps(maps, keys) do
    Enum.find_value(maps, fn map ->
      if is_map(map) do
        Enum.find_value(keys, fn key ->
          case Map.get(map, key) do
            value when is_integer(value) -> Integer.to_string(value)
            value when is_binary(value) -> if String.trim(value) != "", do: String.trim(value)
            _ -> nil
          end
        end)
      end
    end)
  end

  @doc false
  def parse_awx_variables(raw) when is_map(raw), do: raw

  def parse_awx_variables(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    if trimmed == "" do
      %{}
    else
      case Jason.decode(trimmed) do
        {:ok, decoded} when is_map(decoded) ->
          decoded

        _ ->
          parse_simple_yaml_variables(trimmed)
      end
    end
  end

  def parse_awx_variables(_raw), do: %{}

  defp parse_simple_yaml_variables(text) do
    text
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      trimmed = String.trim(line)

      if trimmed == "" or String.starts_with?(trimmed, ["#"]) do
        acc
      else
        case String.split(trimmed, ":", parts: 2) do
          [key, value] ->
            clean_key = String.trim(key)

            clean_val =
              value
              |> String.trim()
              |> String.trim_leading("\"")
              |> String.trim_trailing("\"")
              |> String.trim_leading("'")
              |> String.trim_trailing("'")

            if clean_key != "" and clean_val != "" do
              Map.put(acc, clean_key, clean_val)
            else
              acc
            end

          _ ->
            acc
        end
      end
    end)
  end

  defp extract_awx_proxmox_macs(awx, metadata, vars) do
    direct_macs =
      List.flatten([
        Map.get(awx, "mac_addresses"),
        Map.get(metadata, "mac_addresses"),
        Map.get(vars, "proxmox_hwaddr"),
        Map.get(awx, "proxmox_hwaddr")
      ])

    net_macs =
      [awx, metadata, vars]
      |> Enum.filter(&is_map/1)
      |> Enum.flat_map(fn map ->
        Enum.flat_map(map, fn {k, v} ->
          key = to_string(k)

          if String.starts_with?(key, "proxmox_net") do
            extract_macs_from_proxmox_net_value(v)
          else
            []
          end
        end)
      end)

    (direct_macs ++ net_macs)
    |> Enum.map(&normalize_mac_identifier/1)
    |> Enum.filter(&present?/1)
    |> Enum.uniq()
  end

  defp extract_macs_from_proxmox_net_value(value) when is_binary(value) do
    ~r/(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}/
    |> Regex.scan(value)
    |> List.flatten()
  end

  defp extract_macs_from_proxmox_net_value(value) when is_map(value) do
    value
    |> Map.values()
    |> Enum.flat_map(&extract_macs_from_proxmox_net_value/1)
  end

  defp extract_macs_from_proxmox_net_value(value) when is_list(value) do
    Enum.flat_map(value, &extract_macs_from_proxmox_net_value/1)
  end

  defp extract_macs_from_proxmox_net_value(_value), do: []

  defp reconcile_guest_device_merges(guests, merge_sources_by_ref, actor) do
    Enum.each(guests, fn guest ->
      provider_ref = Map.get(guest, :provider_ref)
      target_uid = existing_sr_uid(Map.get(guest, :device_uid))
      source_uids = Map.get(merge_sources_by_ref, provider_ref, [])

      if is_binary(target_uid) do
        Enum.each(source_uids, fn source_uid ->
          if is_binary(source_uid) and source_uid != target_uid do
            case IdentityReconciler.merge_devices(source_uid, target_uid,
                   actor: actor,
                   reason: "hypervisor_guest_network_match",
                   details: %{
                     "guest_provider_ref" => provider_ref,
                     "hypervisor_vmid" => Map.get(guest, :vmid)
                   }
                 ) do
              :ok ->
                :ok

              {:ok, _} ->
                :ok

              {:error, reason} ->
                Logger.debug(
                  "HypervisorEnrichment: skipped guest merge #{source_uid} -> #{target_uid}: #{inspect(reason)}"
                )
            end
          end
        end)
      end
    end)

    :ok
  end

  defp sync_existing_device_mac_identities(records, guest_macs, host_macs, _actor) do
    host_entries =
      Enum.flat_map(records.hosts, fn record ->
        uid = existing_sr_uid(Map.get(record, :device_uid))
        ref = Map.get(record, :provider_ref)
        macs = Map.get(host_macs, ref, [])

        if is_binary(uid) and macs != [] do
          [{record, :hypervisor, uid, macs, host_macs}]
        else
          []
        end
      end)

    guest_entries =
      Enum.flat_map(records.guests, fn record ->
        uid = existing_sr_uid(Map.get(record, :device_uid))
        ref = Map.get(record, :provider_ref)
        macs = Map.get(guest_macs, ref, [])

        if is_binary(uid) and macs != [] do
          [{record, :virtual_guest, uid, macs, guest_macs}]
        else
          []
        end
      end)

    entries = host_entries ++ guest_entries

    if entries != [] do
      Enum.each(entries, fn {_record, _role, uid, macs, _macs_by_ref} ->
        _ =
          Repo.query(
            """
            UPDATE platform.ocsf_devices
            SET mac = COALESCE(NULLIF(btrim(mac), ''), $2),
                metadata = jsonb_set(
                  COALESCE(metadata, '{}'::jsonb),
                  '{mac_addresses}',
                  $3::jsonb,
                  true
                )
            WHERE uid = $1 AND deleted_at IS NULL
            """,
            [uid, List.first(macs), macs]
          )
      end)

      resolved_updates =
        Enum.map(entries, fn {record, role, uid, macs, macs_by_ref} ->
          raw_update = %{
            "device_id" => uid,
            "mac" => List.first(macs),
            "partition" => metadata_partition(record),
            "source" => "hypervisor_enrichment",
            "metadata" => placeholder_device_metadata(record, role, macs_by_ref)
          }

          {Normalize.normalize_update(raw_update), uid}
        end)

      identifier_records = IdentifierRecords.build_identifier_records(resolved_updates)
      _ = IdentifierRecords.bulk_upsert_identifiers(identifier_records)
    end

    :ok
  end

  defp lookup_identifier_devices(identifiers) do
    types = Enum.map(identifiers, &to_string(&1.type))
    values = Enum.map(identifiers, & &1.value)
    partitions = Enum.map(identifiers, &(&1.partition || "default"))

    case Repo.query(identifier_lookup_sql(), [types, values, partitions]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Map.new(rows, fn [type, value, partition, device_id] ->
           {{identifier_type_atom(type), value, partition || "default"}, device_id}
         end)}

      {:error, reason} ->
        Logger.warning(
          "Hypervisor enrichment device identifier lookup failed: #{inspect(reason)}"
        )

        {:error, {:identifier_lookup_failed, reason}}
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

  # Host-scoped records: hosts, host disks and host NICs.
  defp resolve_record_device_uid(record, devices, identity_maps) do
    current_uid = Map.get(record, :device_uid)
    refs = host_scoped_lookup_refs(record)

    Map.put(
      record,
      :device_uid,
      resolved_device_uid(record, devices, identity_maps, current_uid, refs)
    )
  end

  # Guest-scoped records: guests and guest NICs.
  defp resolve_record_device_uid(record, devices, identity_maps, actor, claim_type) do
    current_uid = reusable_current_uid(Map.get(record, :device_uid), claim_type, actor)
    refs = guest_scoped_lookup_refs(record)

    Map.put(
      record,
      :device_uid,
      resolved_device_uid(record, devices, identity_maps, current_uid, refs)
    )
  end

  defp resolved_device_uid(record, devices, identity_maps, current_uid, refs) do
    Map.get(devices.by_uid, current_uid) ||
      lookup_device_by_identity_maps(refs, identity_maps) ||
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

  defp lookup_device_by_identity_maps(refs, identity_maps) do
    Enum.find_value(identity_maps, fn identity_map ->
      Enum.find_value(refs, &Map.get(identity_map, &1))
    end)
  end

  # A host disk or NIC belongs to its host's device, so it falls back to the
  # host ref.
  defp host_scoped_lookup_refs(record) do
    Enum.filter(
      [Map.get(record, :provider_ref), Map.get(record, :host_provider_ref)],
      &present?/1
    )
  end

  # A guest is never its host. Guest records carry the host ref too, and the
  # integration map is keyed by every host in the batch, so a host-ref
  # fallback bound a guest whose own identity was not registered yet to its
  # node's device. A guest NIC resolves through its guest's ref.
  defp guest_scoped_lookup_refs(record) do
    Enum.filter(
      [Map.get(record, :guest_provider_ref), Map.get(record, :provider_ref)],
      &present?/1
    )
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
      [_provider, "v3", _controller_id, _cluster_id, kind, node | _]
      when kind in ["node", "host"] ->
        node

      [_provider, "v2", _cluster_id, kind, node | _] when kind in ["node", "host"] ->
        node

      [_provider, "node", node | _] ->
        node

      [_provider, "host", host | _] ->
        host

      [_provider, kind, node | _] when kind in ["disk", "nic", "guest"] ->
        node

      _ ->
        nil
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
