defmodule ServiceRadar.NetworkDiscovery.MapperResultsIngestor do
  @moduledoc """
  Ingests mapper interface and topology results into CNPG and projects topology into AGE.
  """

  import Ecto.Query

  alias Ash.Error.Changes.InvalidAttribute
  alias Ash.Error.Invalid
  alias Ash.Error.Unknown
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.AliasEvents
  alias ServiceRadar.Identity.AliasPolicy
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.InterfaceMacs
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.Interface
  alias ServiceRadar.Inventory.InterfaceClassifier
  alias ServiceRadar.Inventory.InterfaceSettings
  alias ServiceRadar.NetworkDiscovery.MapperJob
  alias ServiceRadar.NetworkDiscovery.TopologyGraph
  alias ServiceRadar.NetworkDiscovery.TopologyLink
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  # Minimum score for a role to be asserted at all; below this the device is
  # "unknown". Deliberately a compile-time constant rather than config: this is a
  # heuristic with fleet-wide reach, and a value that can be turned during an
  # incident would reclassify every device with no review. Note `host` cannot
  # reach it (its terms total 45) -- see the issue on the role heuristic; that is
  # currently harmless because no branch distinguishes "host" from "unknown".
  @role_score_threshold 50

  @unifi_interface_metadata_keys ~w(
    unifi_api_urls
    unifi_api_names
    controller_url
    controller_name
    site_id
    site_name
    unifi_device_id
  )

  @spec ingest_interfaces(binary() | nil, map()) :: :ok | {:error, term()}
  def ingest_interfaces(message, _status) do
    actor = SystemActor.system(:mapper_interface_ingestor)

    with {:ok, updates} <- decode_payload(message),
         records = build_interface_records(updates),
         resolved_records = resolve_device_ids(records, actor),
         :ok <- register_interface_macs(resolved_records, actor),
         :ok <- process_mapper_alias_updates(resolved_records, actor) do
      classified_records = InterfaceClassifier.classify_interfaces(resolved_records, actor)

      if classified_records == [] do
        Logger.debug("No interfaces to ingest after device ID resolution")

        record_job_runs(updates,
          status: :error,
          include_interface_counts: true,
          error: "no interfaces discovered"
        )

        :ok
      else
        case insert_bulk(classified_records, Interface, actor, "interfaces") do
          # Per-record isolation: partial rejections are logged by
          # handle_bulk_result/3 but must not stop the surviving interface
          # evidence from reaching the AGE projection.
          {:ok, _summary} ->
            TopologyGraph.upsert_interfaces(classified_records)
            record_job_runs(updates, status: :success, include_interface_counts: true)
            :ok

          {:error, reason} ->
            record_job_runs(updates,
              status: :error,
              include_interface_counts: true,
              error: reason
            )

            {:error, reason}
        end
      end
    else
      {:error, reason} ->
        Logger.warning("Mapper interface ingestion failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Record the MACs each device reports on its OWN interfaces, as :interface_mac
  # identifiers. Corroboration only -- :interface_mac is absent from
  # Ids.identifier_priority/0, so it never resolves an update or identifies a
  # device. It exists so AliasGuard can tell "another address of this chassis"
  # from "different hardware"; see Identity.InterfaceMacs.
  #
  # Reuses primary_identity_interface?/1, so loopback, virtual, bridge, tunnel
  # and VRRP interfaces are excluded here exactly as they are for identity seeding.
  # InterfaceMacs additionally refuses locally-administered addresses and skips
  # values already registered, so a poll that discovers nothing new writes
  # nothing.
  #
  # Never fails ingestion: interface evidence is the point of this path, and
  # corroboration that could not be recorded is worth less than the interfaces
  # themselves.
  defp register_interface_macs(records, actor) do
    records
    |> Enum.filter(&primary_identity_interface?/1)
    |> Enum.group_by(& &1.device_id)
    |> Enum.each(fn {device_id, grouped} ->
      macs = Enum.map(grouped, & &1.if_phys_address)
      partition = grouped |> List.first() |> Map.get(:partition)

      InterfaceMacs.register(device_id, macs, partition, actor)
    end)

    :ok
  rescue
    error ->
      Logger.warning("Interface MAC registration failed: #{inspect(error)}")
      :ok
  end

  @spec ingest_topology(binary() | nil, map()) :: :ok | {:error, term()}
  def ingest_topology(message, _status) do
    actor = SystemActor.system(:mapper_topology_ingestor)

    with {:ok, updates} <- decode_payload(message),
         records = build_topology_records(updates),
         canonical_seed_records = sanitize_topology_records(records),
         resolved_records = resolve_topology_device_ids(canonical_seed_records),
         :ok <- promote_topology_sightings(resolved_records, actor) do
      final_records =
        resolved_records
        |> resolve_topology_device_ids()
        |> enrich_resolved_topology_records()

      records_with_wireguard = add_deterministic_wireguard_links(final_records)
      record_job_runs(updates, status: :success)

      if records_with_wireguard == [] do
        Logger.debug("No topology links to ingest after device ID resolution")
        :ok
      else
        case insert_bulk(records_with_wireguard, TopologyLink, actor, "topology") do
          # Per-record isolation: rejected records are counted into telemetry
          # and filtered out, but the accepted evidence still reaches the AGE
          # graph instead of freezing the whole payload.
          {:ok, %{rejected: rejected}} ->
            emit_topology_ingest_rejections(rejected)
            surviving = reject_rejected_topology_records(records_with_wireguard, rejected)
            TopologyGraph.upsert_links(surviving)
            maybe_bootstrap_topology_interface_metrics(surviving, actor)
            :ok

          {:error, reason} ->
            {:error, reason}
        end
      end
    else
      {:error, reason} ->
        Logger.warning("Mapper topology ingestion failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @required_topology_metrics ~w(ifInOctets ifInUcastPkts ifOutOctets ifOutUcastPkts)
  @required_topology_metrics_hc ~w(ifHCInOctets ifHCInUcastPkts ifHCOutOctets ifHCOutUcastPkts)
  @truthy_string_values MapSet.new(~w(true 1 yes on))
  @falsey_string_values MapSet.new(~w(false 0 no off))
  @topology_evidence_classes [
    "direct-physical",
    "direct-logical",
    "hosted-virtual",
    "inferred-segment",
    "observed-only"
  ]
  @topology_relation_families [
    "CONNECTS_TO",
    "LOGICAL_PEER",
    "HOSTED_ON",
    "ATTACHED_TO",
    "INFERRED_TO",
    "OBSERVED_TO"
  ]

  @doc false
  def topology_metric_bootstrap_targets(records) when is_list(records) do
    records
    |> Enum.reduce(MapSet.new(), fn record, acc ->
      device_id =
        normalize_string(Map.get(record, :local_device_id) || Map.get(record, "local_device_id"))

      if_index = Map.get(record, :local_if_index) || Map.get(record, "local_if_index")

      if is_binary(device_id) and is_integer(if_index) and if_index > 0 do
        MapSet.put(acc, {device_id, if_index})
      else
        acc
      end
    end)
    |> MapSet.to_list()
  end

  def topology_metric_bootstrap_targets(_), do: []

  @doc false
  def topology_metric_bootstrap_enabled?(records, default_enabled \\ nil)

  def topology_metric_bootstrap_enabled?(records, default_enabled) when is_list(records) do
    default =
      if is_boolean(default_enabled) do
        default_enabled
      else
        Application.get_env(
          :serviceradar_core,
          :topology_interface_metrics_autobootstrap_enabled,
          true
        ) == true
      end

    override =
      Enum.reduce_while(records, nil, fn record, _acc ->
        metadata = Map.get(record, :metadata) || Map.get(record, "metadata")

        value =
          parse_optional_bool(
            metadata_value(metadata, "topology_snmp_bootstrap_enabled") ||
              metadata_value(metadata, "topology_interface_metrics_autobootstrap_enabled")
          )

        if is_nil(value), do: {:cont, nil}, else: {:halt, value}
      end)

    case override do
      nil -> default
      value -> value
    end
  end

  def topology_metric_bootstrap_enabled?(_, default_enabled) when is_boolean(default_enabled),
    do: default_enabled

  def topology_metric_bootstrap_enabled?(_, _), do: true

  defp parse_optional_bool(nil), do: nil

  defp parse_optional_bool(v) when is_binary(v) do
    normalized = v |> String.trim() |> String.downcase()

    cond do
      MapSet.member?(@truthy_string_values, normalized) -> true
      MapSet.member?(@falsey_string_values, normalized) -> false
      true -> nil
    end
  end

  @doc false
  def merge_required_topology_metrics(existing, interface_or_available_metrics \\ nil)

  def merge_required_topology_metrics(existing, interface_or_available_metrics)
      when is_list(existing) do
    required =
      @required_topology_metrics ++
        hc_required_topology_metrics(interface_or_available_metrics)

    (existing ++ required)
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def merge_required_topology_metrics(_, interface_or_available_metrics) do
    @required_topology_metrics ++ hc_required_topology_metrics(interface_or_available_metrics)
  end

  defp hc_required_topology_metrics(nil), do: []

  defp hc_required_topology_metrics(%{available_metrics: available_metrics}) do
    hc_required_topology_metrics(available_metrics)
  end

  defp hc_required_topology_metrics(available_metrics) when is_list(available_metrics) do
    names =
      available_metrics
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn metric ->
        Map.get(metric, "name") || Map.get(metric, :name) || ""
      end)
      |> MapSet.new(&to_string/1)

    if MapSet.member?(names, "ifHCInOctets") or MapSet.member?(names, "ifHCOutOctets") do
      @required_topology_metrics_hc
    else
      []
    end
  end

  defp hc_required_topology_metrics(_), do: []

  defp maybe_bootstrap_topology_interface_metrics(records, actor) when is_list(records) do
    if topology_metric_bootstrap_enabled?(records) do
      records
      |> topology_metric_bootstrap_targets()
      |> Enum.each(fn {device_id, if_index} ->
        ensure_topology_interface_metric_settings(device_id, if_index, actor)
      end)
    end

    :ok
  rescue
    e ->
      Logger.warning("Topology interface metric bootstrap failed: #{inspect(e)}")
      :ok
  end

  defp ensure_topology_interface_metric_settings(device_id, if_index, actor) do
    with {:ok, interface} <- latest_interface_for_ifindex(device_id, if_index, actor),
         true <- is_binary(interface.interface_uid) and interface.interface_uid != "" do
      existing =
        case InterfaceSettings.get_by_interface(device_id, interface.interface_uid, actor: actor) do
          {:ok, settings} -> settings
          _ -> nil
        end

      case topology_interface_settings_patch(existing, interface) do
        nil ->
          {:ok, existing}

        patch ->
          InterfaceSettings.upsert(
            device_id,
            interface.interface_uid,
            patch,
            actor: actor
          )
      end
    else
      _ -> :ok
    end
  rescue
    e ->
      Logger.debug(
        "Topology interface metric bootstrap skipped for #{device_id}/ifindex:#{if_index}: #{inspect(e)}"
      )

      :ok
  end

  defp latest_interface_for_ifindex(device_id, if_index, actor)
       when is_binary(device_id) and is_integer(if_index) do
    query =
      Interface
      |> Ash.Query.filter(device_id == ^device_id and if_index == ^if_index)
      |> Ash.Query.sort(timestamp: :desc)
      |> Ash.Query.limit(1)

    case Ash.read_one(query, actor: actor) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, interface} -> {:ok, interface}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def topology_interface_settings_patch(existing, interface_or_available_metrics \\ nil)

  def topology_interface_settings_patch(existing, interface_or_available_metrics) do
    existing_selected =
      case existing do
        nil -> []
        settings -> Map.get(settings, :metrics_selected) || []
      end

    enabled? =
      case existing do
        nil -> false
        settings -> Map.get(settings, :metrics_enabled) == true
      end

    selected =
      merge_required_topology_metrics(existing_selected, interface_or_available_metrics)

    if enabled? and selected == existing_selected do
      nil
    else
      %{metrics_enabled: true, metrics_selected: selected}
    end
  end

  defp promote_topology_sightings([], _actor), do: :ok

  defp promote_topology_sightings(records, actor) do
    endpoint_promotion? = endpoint_identity_promotion_enabled?()

    %{endpoint: endpoint_candidates, ip: candidates, suppressed: suppressed_count} =
      partition_topology_sighting_candidates(records, endpoint_promotion?)

    cond do
      endpoint_promotion? and
          (candidates != [] or endpoint_candidates != [] or suppressed_count > 0) ->
        Logger.info(
          "topology_sighting_promotion_stats total=#{length(records)} candidates=#{length(candidates)} endpoint_candidates=#{length(endpoint_candidates)} suppressed=#{suppressed_count}"
        )

      candidates != [] or suppressed_count > 0 ->
        Logger.info(
          "topology_sighting_promotion_stats total=#{length(records)} candidates=#{length(candidates)} suppressed=#{suppressed_count}"
        )

      true ->
        :ok
    end

    Enum.each(endpoint_candidates, &promote_endpoint_topology_sighting(&1, actor))
    Enum.each(candidates, &promote_topology_sighting(&1, actor))

    :ok
  rescue
    e ->
      Logger.warning("Topology sighting promotion failed: #{inspect(e)}")
      :ok
  end

  # Endpoint attachment identity promotion (task: fix-topology-evidence-pipeline-
  # resilience 3.1). When disabled (default), the legacy candidate/suppression
  # split is unchanged: FDB neighbors matching the 4-way suppression conjunction
  # never mint devices. When enabled, MAC-carrying FDB/UniFi-client neighbors are
  # carved out FIRST and promoted with MAC+partition-keyed provisional `sr:`
  # identities instead of being suppressed; the remaining records keep the legacy
  # IP-keyed candidate rules (including suppression for MAC-less records —
  # identity is never keyed on IP alone here, per the network-agnostic rule).
  @doc false
  def partition_topology_sighting_candidates(records, endpoint_promotion_enabled?)
      when is_list(records) do
    {endpoint_candidates, remaining} =
      if endpoint_promotion_enabled? do
        Enum.split_with(records, &endpoint_identity_candidate?/1)
      else
        {[], records}
      end

    candidates = Enum.filter(remaining, &topology_sighting_candidate?/1)

    suppressed_count =
      Enum.count(remaining, fn record ->
        topology_sighting_candidate_base?(record) and
          suppress_topology_sighting_candidate?(record)
      end)

    %{endpoint: endpoint_candidates, ip: candidates, suppressed: suppressed_count}
  end

  defp endpoint_identity_promotion_enabled? do
    Application.get_env(:serviceradar_core, :topology_endpoint_identity_promotion_enabled, false) ==
      true
  end

  defp topology_sighting_candidate?(record) when is_map(record) do
    topology_sighting_candidate_base?(record) and
      not suppress_topology_sighting_candidate?(record)
  end

  defp topology_sighting_candidate?(_), do: false

  defp topology_sighting_candidate_base?(record) when is_map(record) do
    not present?(record.neighbor_device_id) and
      valid_alias_ip?(normalize_alias_ip(record.neighbor_mgmt_addr)) and
      present?(record.local_device_id)
  end

  defp topology_sighting_candidate_base?(_), do: false

  @doc false
  def suppress_topology_sighting_candidate?(record) when is_map(record) do
    protocol = normalize_topology_protocol(record.protocol)
    confidence_reason = metadata_value(record.metadata, "confidence_reason")
    source = metadata_value(record.metadata, "source")
    neighbor_name_present? = present?(normalize_string(record.neighbor_system_name))

    protocol == "snmp-l2" and
      confidence_reason == "single_identifier_inference" and
      source == "snmp-arp-fdb" and
      not neighbor_name_present?
  end

  def suppress_topology_sighting_candidate?(_record), do: false

  # Evidence sources whose neighbors are ordinary hosts observed behind a switch
  # port / AP association (ARP+FDB correlation, UniFi client tables, and
  # direct-physical LLDP/CDP endpoint sightings). Promotion only ever fires for
  # UNRESOLVED neighbors, so resolved infrastructure never reaches it; residual
  # un-inventoried infrastructure is filtered downstream by the device-side
  # guards (`endpoint_attachment_candidate_device?/1`).
  @endpoint_attachment_sighting_sources ~w(snmp-arp-fdb unifi-api-port-table unifi-api-wireless-client unifi-api-wired-client lldp cdp)

  @doc false
  def endpoint_identity_candidate?(record) when is_map(record) do
    not present?(record.neighbor_device_id) and
      present?(record.local_device_id) and
      metadata_value(record.metadata, "source") in @endpoint_attachment_sighting_sources and
      normalize_mac(record.neighbor_chassis_id) != nil
  end

  def endpoint_identity_candidate?(_record), do: false

  # Weak L2 pairings (cross-subnet ARP+FDB, observed joins across devices) may
  # put one host's chassis MAC next to another host's IP. That is topology
  # evidence, not identity: never register the MAC onto the IP's device.
  @weak_l2_identity_reasons ~w(cross_subnet_arp_fdb_port_mapping cross_device_arp_fdb_join)

  @doc false
  def endpoint_ip_mac_bind_allowed?(metadata) when is_map(metadata) do
    not weak_l2_neighbor_identity?(metadata)
  end

  def endpoint_ip_mac_bind_allowed?(_), do: true

  @doc false
  def weak_l2_neighbor_identity?(metadata) when is_map(metadata) do
    reason =
      metadata_value(metadata, "topology_last_seen_confidence_reason") ||
        metadata_value(metadata, "confidence_reason")

    reason in @weak_l2_identity_reasons
  end

  def weak_l2_neighbor_identity?(_), do: false

  @doc false
  def endpoint_identity_confidence_tier(evidence_class) do
    case normalize_topology_evidence_class(evidence_class) do
      "endpoint-attachment" -> "high"
      "direct-physical" -> "high"
      "direct-logical" -> "high"
      "hosted-virtual" -> "medium"
      "inferred-segment" -> "medium"
      "observed-only" -> "low"
      _ -> "low"
    end
  end

  # LLDP/CDP-promoted endpoint identities are deliberately capped at "medium":
  # the physical adjacency is direct, but a chassis MAC alone says less about
  # the endpoint's identity than a controller/FDB-correlated sighting, so they
  # must not inherit the direct-physical -> "high" identity tier.
  @doc false
  def endpoint_identity_confidence_tier(evidence_class, source) when source in ["lldp", "cdp"] do
    case endpoint_identity_confidence_tier(evidence_class) do
      "high" -> "medium"
      tier -> tier
    end
  end

  def endpoint_identity_confidence_tier(evidence_class, _source),
    do: endpoint_identity_confidence_tier(evidence_class)

  defp promote_endpoint_topology_sighting(record, actor) do
    mac = normalize_mac(record.neighbor_chassis_id)
    partition = normalize_partition(record.partition)
    candidate_ip = endpoint_candidate_ip(record)
    metadata = endpoint_topology_candidate_metadata(record, mac)

    case resolve_or_create_endpoint_topology_device(
           mac,
           candidate_ip,
           partition,
           record.local_device_id,
           metadata,
           actor
         ) do
      {:ok, uid} ->
        touch_topology_candidate(uid, candidate_ip, metadata, actor)

      {:error, reason} ->
        Logger.debug(
          "Endpoint topology sighting promotion skipped for mac #{mac}: #{inspect(reason)}"
        )
    end
  end

  defp endpoint_candidate_ip(record) do
    ip = normalize_alias_ip(record.neighbor_mgmt_addr)
    if valid_alias_ip?(ip), do: ip
  end

  # Identity is keyed on the neighbor MAC within the partition: DIRE resolution
  # consults registered MAC identifiers and the merge-audit canonical mapping
  # first, then falls back to the deterministic MAC+partition-seeded `sr:` uid
  # (never the IP when a MAC is present), so repeated sightings of the same
  # hardware converge on one uid and distinct MACs mint distinct devices.
  defp resolve_or_create_endpoint_topology_device(
         mac,
         candidate_ip,
         partition,
         source_device_id,
         metadata,
         actor
       ) do
    with {:ok, uid} <- resolve_device_uid_via_dire(candidate_ip, partition, [mac], actor) do
      cond do
        device_exists?(uid, actor) ->
          # DIRE resolved the sighting onto an existing device (MAC identifier,
          # alias, or merge-audit canonical hit) — reuse it, never duplicate.
          {:ok, uid}

        is_binary(existing_uid = find_live_device_uid_by_ip(candidate_ip, partition, actor)) and
          bindable_endpoint_ip_device?(existing_uid, mac, actor) and
            endpoint_ip_mac_bind_allowed?(metadata) ->
          # The sighting's IP already belongs to a live device with no
          # conflicting MAC identity (e.g. an IP-only hypervisor record). DIRE
          # never consults the IP when a strong MAC is present, so bind here
          # and register the MAC so future sightings resolve via DIRE instead
          # of minting a provisional duplicate. Distinct MAC = different
          # hardware: when the device already carries a different MAC (column
          # or registered identifier), shared-IP evidence (DHCP churn, NAT/VIP
          # reuse) must never merge them, so the guard falls through to the
          # deterministic MAC-seeded mint below.
          #
          # Cross-subnet / observed-join FDB is excluded: that evidence can
          # pair one chassis MAC with another host's IP, which is how a dead
          # MikroTik CHR absorbed a live vJunos identity.
          register_mapper_mac_identifiers(existing_uid, [mac], candidate_ip, partition, actor)
          {:ok, existing_uid}

        true ->
          create_endpoint_topology_device(
            uid,
            mac,
            candidate_ip,
            partition,
            source_device_id,
            metadata,
            actor
          )
      end
    end
  end

  defp find_live_device_uid_by_ip(nil, _partition, _actor), do: nil

  defp find_live_device_uid_by_ip(candidate_ip, partition, actor) do
    case lookup_device_uids_by_ip([candidate_ip]) do
      %{^candidate_ip => uid} when is_binary(uid) ->
        uid

      _ ->
        case find_device_uid_by_alias(candidate_ip, partition, actor) do
          {:ok, uid} when is_binary(uid) and uid != "" -> uid
          _ -> nil
        end
    end
  end

  # Identity-safety guard for the IP/alias bind: only a device with NO MAC
  # identity at all — empty `mac` column and no registered :mac identifier
  # rows — or one matching the sighting MAC may be bound. A failed check
  # counts as a conflict (do not bind) rather than crashing the promotion.
  # NOTE: `find_live_device_uid_by_ip` may already have reactivated a stale
  # :ip alias before this guard rejects; the reactivation lives in the shared
  # alias helper (`alias_device_uid/2`) used by non-endpoint paths too, so it
  # is left in place rather than restructured.
  defp bindable_endpoint_ip_device?(device_uid, mac, actor) do
    not device_mac_column_conflict?(device_uid, mac, actor) and
      not registered_mac_identifier_conflict?(device_uid, mac)
  end

  defp device_mac_column_conflict?(device_uid, mac, actor) do
    case Device.get_by_uid(device_uid, false, actor: actor) do
      {:ok, %Device{deleted_at: nil} = device} ->
        device_mac = normalize_mac(device.mac)
        is_binary(device_mac) and device_mac != mac

      _ ->
        # Unloadable device: treat as conflicting rather than binding blind.
        true
    end
  rescue
    e ->
      Logger.warning("Endpoint bind MAC column check raised for #{device_uid}: #{inspect(e)}")
      true
  end

  defp registered_mac_identifier_conflict?(device_uid, mac) do
    registered =
      from(di in DeviceIdentifier,
        where: di.device_id == ^device_uid,
        where: di.identifier_type == ^"mac",
        select: di.identifier_value
      )
      |> Repo.all()
      |> Enum.map(&normalize_mac/1)
      |> Enum.reject(&is_nil/1)

    registered != [] and mac not in registered
  rescue
    e ->
      Logger.warning("Endpoint bind MAC identifier check raised for #{device_uid}: #{inspect(e)}")

      true
  end

  defp create_endpoint_topology_device(
         uid,
         mac,
         candidate_ip,
         partition,
         source_device_id,
         metadata,
         actor
       ) do
    attrs =
      maybe_put(
        %{
          uid: uid,
          mac: mac,
          discovery_sources: ["mapper", "sighting"],
          metadata:
            metadata
            |> Map.put("identity_state", "provisional")
            |> Map.put("identity_source", "mapper_topology_sighting")
            |> Map.put("candidate_from_device_id", source_device_id)
        },
        :ip,
        candidate_ip
      )

    case Device
         |> Ash.Changeset.for_create(:create, attrs)
         |> Ash.create(actor: actor) do
      {:ok, _device} ->
        register_mapper_mac_identifiers(uid, [mac], candidate_ip, partition, actor)
        {:ok, uid}

      {:error, %Invalid{errors: errors}} ->
        recover_existing_device_uid(uid, candidate_ip, errors, actor)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def endpoint_topology_candidate_metadata(record, mac) when is_map(record) do
    evidence_class = metadata_value(record.metadata, "evidence_class")
    source = metadata_value(record.metadata, "source")

    record
    |> topology_candidate_metadata()
    |> Map.put("topology_last_seen_neighbor_mac", mac)
    |> Map.put(
      "identity_confidence_tier",
      endpoint_identity_confidence_tier(evidence_class, source)
    )
  end

  defp promote_topology_sighting(record, actor) do
    candidate_ip = normalize_alias_ip(record.neighbor_mgmt_addr)
    partition = normalize_partition(record.partition)
    metadata = topology_candidate_metadata(record)

    case resolve_or_create_topology_candidate_uid(
           candidate_ip,
           partition,
           record.local_device_id,
           metadata,
           actor
         ) do
      {:ok, uid} ->
        touch_topology_candidate(uid, candidate_ip, metadata, actor)

      {:error, reason} ->
        Logger.debug(
          "Topology sighting candidate promotion skipped for #{candidate_ip}: #{inspect(reason)}"
        )
    end
  end

  defp resolve_or_create_topology_candidate_uid(
         candidate_ip,
         partition,
         source_device_id,
         metadata,
         actor
       ) do
    case lookup_device_uids_by_ip([candidate_ip]) do
      %{^candidate_ip => uid} ->
        {:ok, uid}

      _ ->
        case find_device_uid_by_alias(candidate_ip, partition, actor) do
          {:ok, uid} when is_binary(uid) and uid != "" ->
            {:ok, uid}

          _ ->
            create_topology_candidate_device_for_ip(
              candidate_ip,
              partition,
              source_device_id,
              metadata,
              actor
            )
        end
    end
  end

  defp create_topology_candidate_device_for_ip(
         candidate_ip,
         partition,
         source_device_id,
         metadata,
         actor
       ) do
    with {:ok, uid} <- resolve_device_uid_via_dire(candidate_ip, partition, [], actor) do
      if device_exists?(uid, actor) do
        # DIRE resolved the sighting onto an existing device (identifier,
        # alias, or merge-audit canonical hit) — reuse it, never duplicate.
        {:ok, uid}
      else
        attrs = %{
          uid: uid,
          ip: candidate_ip,
          discovery_sources: ["mapper", "sighting"],
          metadata:
            metadata
            |> Map.put("identity_state", "provisional")
            |> Map.put("identity_source", "mapper_topology_sighting")
            |> Map.put("candidate_from_device_id", source_device_id)
        }

        case Device
             |> Ash.Changeset.for_create(:create, attrs)
             |> Ash.create(actor: actor) do
          {:ok, _device} ->
            {:ok, uid}

          {:error, %Invalid{errors: errors}} ->
            recover_existing_device_uid(uid, candidate_ip, errors, actor)

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  defp touch_topology_candidate(uid, candidate_ip, metadata, actor) do
    with {:ok, %Device{} = device} <- Device.get_by_uid(uid, true, actor: actor) do
      merged_metadata = Map.merge(Map.new(device.metadata || %{}), metadata)
      merged_sources = merge_topology_discovery_sources(device.discovery_sources)
      attrs = %{metadata: merged_metadata, discovery_sources: merged_sources}

      attrs =
        if present?(device.ip) or is_nil(candidate_ip),
          do: attrs,
          else: Map.put(attrs, :ip, candidate_ip)

      device
      |> Ash.Changeset.for_update(:update, attrs)
      |> Ash.update(actor: actor)
    end

    :ok
  rescue
    e ->
      Logger.debug("Failed to refresh topology candidate #{uid}: #{inspect(e)}")
      :ok
  end

  defp merge_topology_discovery_sources(existing_sources) do
    (List.wrap(existing_sources) ++ ["mapper", "sighting"])
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @doc false
  def topology_candidate_metadata(record) when is_map(record) do
    case_result =
      case record.timestamp do
        %DateTime{} = dt -> dt
        _ -> DateTime.utc_now()
      end

    ts =
      case_result
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    confidence_tier = metadata_value(record.metadata, "confidence_tier") || "low"
    confidence_score = metadata_value(record.metadata, "confidence_score")
    confidence_reason = metadata_value(record.metadata, "confidence_reason")

    %{
      "topology_last_seen_at" => ts,
      "topology_last_seen_neighbor_ip" => normalize_alias_ip(record.neighbor_mgmt_addr),
      "topology_last_seen_from_device_id" => normalize_string(record.local_device_id),
      "topology_last_seen_protocol" => normalize_topology_protocol(record.protocol),
      "topology_last_seen_confidence_tier" => confidence_tier,
      "topology_last_seen_confidence_score" => to_string(confidence_score || ""),
      "topology_last_seen_confidence_reason" => to_string(confidence_reason || "")
    }
  end

  def record_runs_from_payload(message) do
    case decode_payload(message) do
      {:ok, updates} ->
        record_job_runs(updates, status: :success)

      {:error, reason} ->
        Logger.debug("Mapper job run decode failed: #{inspect(reason)}")
        :ok
    end
  end

  defp decode_payload(nil), do: {:ok, []}

  defp decode_payload(message) when is_binary(message) do
    case Jason.decode(message) do
      {:ok, updates} when is_list(updates) -> {:ok, updates}
      {:ok, _} -> {:error, :unexpected_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_payload(_message), do: {:error, :unsupported_payload}

  defp build_interface_records(updates) do
    updates
    |> Enum.reduce([], fn update, acc ->
      case normalize_interface(update) do
        nil -> acc
        record -> [record | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp process_mapper_alias_updates([], _actor), do: :ok

  defp process_mapper_alias_updates(records, actor) do
    grouped_updates =
      records
      |> Enum.group_by(& &1.device_id)
      |> Enum.map(fn {device_id, grouped} -> build_grouped_alias_update(device_id, grouped) end)

    Enum.each(grouped_updates, fn update ->
      persist_role_metadata(update.device_id, update.role, actor)

      create_candidate_devices(
        update.candidate_ips,
        update.partition,
        update.device_id,
        actor
      )
    end)

    updates =
      grouped_updates
      |> Enum.reject(&(map_size(&1.metadata) == 0))
      |> Enum.map(&Map.drop(&1, [:role, :candidate_ips]))

    if updates == [] do
      :ok
    else
      confirm_threshold =
        Application.get_env(:serviceradar_core, :identity_alias_confirm_threshold, 3)

      {:ok, _events} =
        AliasEvents.process_and_persist(
          updates,
          actor: actor,
          confirm_threshold: confirm_threshold
        )

      :ok
    end
  rescue
    e ->
      Logger.warning("Mapper alias state processing raised: #{inspect(e)}")
      :ok
  end

  defp build_grouped_alias_update(device_id, grouped) do
    latest_ts = grouped_latest_timestamp(grouped)
    partition = grouped_partition(grouped)
    current_ip = primary_device_ip(grouped)
    role = infer_device_role(grouped, current_ip)
    stable_interface_ips = grouped_stable_interface_ips(grouped, current_ip)
    mismatched_device_ips = grouped_mismatched_device_ips(grouped, current_ip)
    alias_ips = alias_ips_for_role(role.role, current_ip, stable_interface_ips)

    candidate_ips =
      candidate_ips_for_role(role.role, stable_interface_ips, mismatched_device_ips, alias_ips)

    # Addresses on this device's own interfaces that did NOT become identity
    # aliases. For a router alias_ips already covers them, so this is empty;
    # for every other role it is the set that used to be silently dropped (and
    # before that, minted as phantom devices -- see candidate_ips_for_role/4).
    interface_ips =
      stable_interface_ips
      |> Enum.reject(&(&1 in alias_ips))
      |> cap_interface_ips(device_id)

    warn_on_large_identity_alias_set(device_id, alias_ips)

    metadata =
      build_alias_metadata(alias_ips, latest_ts, role, candidate_ips, interface_ips)

    %{
      device_id: device_id,
      partition: partition,
      ip: current_ip,
      timestamp: latest_ts,
      metadata: metadata,
      role: role,
      candidate_ips: candidate_ips
    }
  end

  defp grouped_latest_timestamp(grouped) do
    grouped
    |> Enum.map(& &1.timestamp)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> DateTime.utc_now() end)
  end

  defp grouped_partition(grouped) do
    grouped
    |> Enum.map(& &1.partition)
    |> Enum.reject(&is_nil/1)
    |> List.first() || "default"
  end

  defp grouped_stable_interface_ips(grouped, current_ip) do
    grouped
    |> Enum.filter(&(normalize_alias_ip(&1.device_ip) == current_ip))
    |> Enum.flat_map(&List.wrap(&1.ip_addresses))
    |> Enum.map(&normalize_alias_ip/1)
    |> Enum.filter(&valid_alias_ip?/1)
    |> Enum.reject(&(&1 == current_ip))
    |> Enum.uniq()
  end

  defp grouped_mismatched_device_ips(grouped, current_ip) do
    grouped
    |> Enum.map(&normalize_alias_ip(&1.device_ip))
    |> Enum.filter(&valid_alias_ip?/1)
    |> Enum.reject(&(&1 == current_ip))
    |> Enum.uniq()
  end

  # Upper bound on how many `:interface_ip` rows one device may accumulate.
  #
  # Nothing else bounds this: there is no cap in the writer, no constraint in the
  # schema, no limit on the read action, and the UI renders the rows in an
  # un-streamed table. A device reporting one address per interface would produce
  # a row per interface -- the largest switch on farm01 enumerates 239.
  #
  # 64 is chosen to sit above real L3 topologies (a core router with per-VLAN
  # SVIs lands in the dozens) and below pathological ones. These are
  # observational records, not identity, so dropping the tail costs visibility
  # rather than correctness -- which is exactly why the cap goes here and not on
  # `:ip`.
  @max_interface_ip_aliases 64

  # Above this many IDENTITY aliases on one device, something is probably wrong --
  # a merge has over-collapsed, or a shared address is being treated as identity.
  # Deliberately a warning and not a cap: dropping an identity alias would change
  # which device an address resolves to, which is a correctness change, whereas
  # too many is a signal worth surfacing rather than silently trimming.
  @large_identity_alias_warning 32

  @doc """
  Caps and stably orders the interface addresses recorded for one device.

  Public as a testable seam, like `role_for_metrics/1` and
  `candidate_ips_for_role/4`: the stability property (same input set always
  yields the same retained subset) is the part worth pinning, and it is invisible
  from the outside.
  """
  def cap_interface_ips(ips, device_id) do
    # Sorted before truncating so the retained set is STABLE across runs. An
    # arbitrary subset would differ run to run, and the aliases would churn --
    # created, gone stale, recreated -- which is worse than a smaller stable set.
    sorted = Enum.sort(ips)

    if length(sorted) > @max_interface_ip_aliases do
      Logger.warning(
        "Capping interface_ip aliases for #{device_id}: " <>
          "#{length(sorted)} addresses observed, keeping #{@max_interface_ip_aliases}"
      )

      Enum.take(sorted, @max_interface_ip_aliases)
    else
      sorted
    end
  end

  defp warn_on_large_identity_alias_set(device_id, alias_ips) do
    count = length(alias_ips)

    if count > @large_identity_alias_warning do
      Logger.warning(
        "Device #{device_id} has #{count} identity ip aliases, which is unusually many -- " <>
          "check for an over-merge or a shared address being treated as identity"
      )
    end

    :ok
  end

  @doc """
  Which addresses become identity (`:ip`) aliases for a mapper-discovered device.

  Public as a testable seam: this is the mapper producer of alias evidence.
  GitHub #4022 requires this path to be proven independently of `AliasPolicy`
  and of `AliasEvents.process_and_persist/2`. A test of `valid_alias_ip?/1`
  alone does not prove the mapper still consults it here.
  """
  def alias_ips_for_role(role, current_ip, stable_interface_ips),
    do: do_alias_ips_for_role(role, current_ip, stable_interface_ips)

  defp do_alias_ips_for_role("router", current_ip, stable_interface_ips) do
    [current_ip | stable_interface_ips]
    |> Enum.filter(&valid_alias_ip?/1)
    |> Enum.uniq()
  end

  defp do_alias_ips_for_role(_role, current_ip, _stable_interface_ips) do
    if valid_alias_ip?(current_ip), do: [current_ip], else: []
  end

  @doc """
  Which addresses seen alongside a device should be seeded as separate devices.

  Public as a testable seam: the distinction between a device's own interface
  addresses and genuinely different neighbours is the whole correctness question
  here, and getting it wrong mints duplicate device records.
  """
  def candidate_ips_for_role(role, stable_interface_ips, mismatched_device_ips, alias_ips),
    do: do_candidate_ips_for_role(role, stable_interface_ips, mismatched_device_ips, alias_ips)

  defp do_candidate_ips_for_role(
         "router",
         _stable_interface_ips,
         _mismatched_device_ips,
         _alias_ips
       ), do: []

  # `stable_interface_ips` are addresses on THIS device's own interfaces
  # (grouped_stable_interface_ips/2 filters to records whose device_ip is the
  # device being processed). They are never candidates for a SEPARATE device,
  # whatever the role: a device cannot be its own neighbour.
  #
  # They used to be included here, and the router clause above was the only thing
  # preventing the consequence. For any other role the device's own addresses
  # fell through to create_candidate_devices/4, and because non-routers receive
  # no interface-derived aliases there was no alias to suppress them either --
  # so ensure_candidate_device/4 found no device and no alias at that address and
  # minted a phantom.
  #
  # Observed on farm01: switch `switchcff8f2` (sr:f3f0e473, 192.168.2.55) reports
  # its out-of-band management address 192.168.1.143 on an `oob` interface, and
  # that address became sr:eab6cd98 -- a second device record with no hostname
  # and no MAC, tagged identity_source=mapper_client_ip_candidate_seed. One
  # physical switch, two records.
  #
  # `mismatched_device_ips` stay: those are other device_ips seen in the same
  # group, i.e. genuinely different devices, which is what this seeding is for.
  defp do_candidate_ips_for_role(_role, _stable_interface_ips, mismatched_device_ips, alias_ips) do
    mismatched_device_ips
    |> Enum.reject(&(&1 in alias_ips))
    |> Enum.uniq()
  end

  defp build_alias_metadata([], _timestamp, _role, _candidate_ips, _interface_ips), do: %{}

  defp build_alias_metadata(alias_ips, timestamp, role, candidate_ips, interface_ips) do
    ts_string =
      timestamp
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    alias_ips
    |> Enum.reduce(%{}, fn ip, acc ->
      Map.put(acc, "ip_alias:#{ip}", ts_string)
    end)
    # A DIFFERENT key prefix, producing a DIFFERENT alias_type. These addresses
    # are recorded so they are attributable to the device rather than orphaned,
    # but `:interface_ip` is not consulted by any identity reader, so they cannot
    # merge devices. Interface tables carry addresses that several devices
    # legitimately share -- VRRP/HSRP virtual IPs, EVPN anycast gateways, cluster
    # VIPs, Junos internals like 10.0.0.4 -- and merge_audit already holds 212
    # alias-driven merges, so routing these to `ip_alias:` would be feeding a
    # mechanism with a demonstrated failure mode.
    |> then(fn acc ->
      Enum.reduce(interface_ips, acc, fn ip, inner ->
        Map.put(inner, "interface_ip_alias:#{ip}", ts_string)
      end)
    end)
    |> Map.put("_alias_last_seen_at", ts_string)
    |> Map.put("_alias_last_seen_ip", List.first(alias_ips))
    |> Map.put("_device_role", role.role)
    |> Map.put("_device_role_confidence", role.confidence)
    |> Map.put("_device_role_source", role.source)
    |> Map.put("_candidate_ip_count", length(candidate_ips))
  end

  defp normalize_alias_ip(value) when is_binary(value), do: String.trim(value)
  defp normalize_alias_ip(_), do: nil

  defp primary_device_ip(records) do
    records
    |> Enum.map(&normalize_alias_ip(&1.device_ip))
    |> Enum.filter(&valid_alias_ip?/1)
    |> Enum.frequencies()
    |> Enum.max_by(fn {_ip, count} -> count end, fn -> {nil, 0} end)
    |> elem(0)
  end

  defp infer_device_role(grouped, current_ip) do
    grouped
    |> device_role_metrics(current_ip)
    |> role_for_metrics()
  end

  @doc """
  Scores the role candidates for an already-computed metrics map.

  Public as a testable seam: `infer_device_role/2` needs a set of interface
  records to derive metrics from, which makes the scoring rules themselves
  awkward to pin down. The rules are a cliff-edged heuristic where the
  interesting behaviour lives at exact boundaries, so they are worth asserting
  directly rather than through fixtures.
  """
  def role_for_metrics(metrics) do
    {best_role, best_score} =
      Enum.max_by(role_candidates(metrics), fn {_role, score} -> score end)

    if best_score < @role_score_threshold do
      %{role: "unknown", confidence: best_score, source: "mapper_role_heuristic_v1"}
    else
      %{role: best_role, confidence: best_score, source: "mapper_role_heuristic_v1"}
    end
  end

  defp device_role_metrics(grouped, current_ip) do
    stable_records = Enum.filter(grouped, &(normalize_alias_ip(&1.device_ip) == current_ip))

    %{
      device_ip_count: device_ip_count(grouped),
      stable_l3_alias_count: stable_l3_alias_count(stable_records, current_ip),
      bridge_like_count: count_interface_kinds(grouped, ["bridge", "virtual", "tunnel"]),
      physical_like_count: count_interface_kinds(grouped, ["physical", "aggregate"]),
      wireless_like_count: wireless_like_count(grouped)
    }
  end

  defp device_ip_count(grouped) do
    grouped
    |> Enum.map(&normalize_alias_ip(&1.device_ip))
    |> Enum.filter(&valid_alias_ip?/1)
    |> Enum.uniq()
    |> length()
  end

  defp stable_l3_alias_count(stable_records, current_ip) do
    stable_records
    |> Enum.flat_map(&List.wrap(&1.ip_addresses))
    |> Enum.map(&normalize_alias_ip/1)
    |> Enum.filter(&valid_alias_ip?/1)
    |> Enum.reject(&(&1 == current_ip))
    |> Enum.uniq()
    |> length()
  end

  defp count_interface_kinds(grouped, kinds) when is_list(kinds) do
    Enum.count(grouped, fn record ->
      kind = String.downcase(to_string(record.interface_kind || ""))
      kind in kinds
    end)
  end

  defp wireless_like_count(grouped) do
    Enum.count(grouped, fn record ->
      if_name = String.downcase(to_string(record.if_name || ""))
      String.starts_with?(if_name, "wl") or String.contains?(if_name, "wlan")
    end)
  end

  defp role_candidates(metrics) do
    [
      {"router", router_role_score(metrics)},
      {"ap_bridge", ap_bridge_role_score(metrics)},
      {"switch_l2", switch_l2_role_score(metrics)},
      {"host", host_role_score(metrics)}
    ]
  end

  defp router_role_score(metrics) do
    0
    |> add_score(metrics.stable_l3_alias_count >= 3, 55)
    |> add_score(metrics.device_ip_count == 1, 20)
    |> add_score(metrics.physical_like_count > 0, 10)
  end

  defp ap_bridge_role_score(metrics) do
    0
    |> add_score(metrics.device_ip_count >= 3, 45)
    |> add_score(metrics.wireless_like_count > 0, 30)
    |> add_score(metrics.bridge_like_count > 0, 20)
    |> add_score(metrics.stable_l3_alias_count <= 1, 10)
  end

  defp switch_l2_role_score(metrics) do
    0
    # Requires L2 EVIDENCE, not merely the absence of L3. Without the
    # physical_like_count guard this term plus device_ip_count == 1 reached 55 on
    # its own, so any single-homed device with no aliases scored switch_l2 with
    # nothing switch-like about it: demo classified a 2-interface MikroTik --
    # whose own SNMP type is "Router" -- as switch_l2@55.
    |> add_score(metrics.stable_l3_alias_count == 0 and metrics.physical_like_count >= 8, 35)
    # A switch with strong L2 evidence keeps its role when it picks up one or
    # two L3 aliases -- an out-of-band management address, or a global IPv6 now
    # that ipAddressTable is walked. Without this the 35 above is all-or-nothing:
    # a single alias dropped a switch from 75 to 40, below the threshold, and the
    # best alternative (host, 45) is also below it, so the device landed on
    # "unknown" until the count reached 3 and router took over. The dead zone was
    # two counts wide.
    #
    # Deliberately +25, not +35: at +35 the term clears the threshold without
    # `device_ip_count == 1`, which would also promote devices seen under several
    # device_ips -- exactly the split-record shape, where the right fix is
    # identity merging rather than a role that hides it. 65 also reads honestly
    # as less confident than the 75 a zero-alias switch earns.
    #
    # The two alias terms are disjoint only by their literal bounds (== 0 versus
    # 1..2). Widening either without narrowing the other makes both fire and
    # scores a zero-alias switch BELOW today's 75. Keep them disjoint.
    |> add_score(
      metrics.stable_l3_alias_count in 1..2 and metrics.physical_like_count >= 8 and
        metrics.wireless_like_count == 0,
      25
    )
    |> add_score(metrics.device_ip_count == 1, 20)
    |> add_score(metrics.physical_like_count >= 8, 20)
  end

  # Reachable as of this change. The terms previously totalled 20+15+10 = 45
  # against a threshold of 50, so no input could produce the role and a genuine
  # single-homed host scored "unknown" -- or worse, switch_l2, once that term is
  # understood (see above). Being NOT port-dense is positive evidence for a host,
  # so it is scored rather than merely not penalised.
  #
  # Modelled over the realistic parameter space before changing: 100 of 1215
  # cells move, as 30 unknown -> host, 20 switch_l2 -> host, and 50 confidence
  # adjustments within "unknown". NO device loses a role to unknown, real
  # switches are untouched, and the alias 1..2 case from the switch dead-zone fix
  # is preserved.
  defp host_role_score(metrics) do
    0
    |> add_score(metrics.stable_l3_alias_count <= 1, 25)
    |> add_score(metrics.device_ip_count == 1, 20)
    |> add_score(metrics.bridge_like_count == 0, 10)
    |> add_score(metrics.physical_like_count < 8, 10)
  end

  defp add_score(score, true, add), do: score + add
  defp add_score(score, false, _add), do: score

  defp persist_role_metadata(device_id, role, actor) do
    case Device.get_by_uid(device_id, true, actor: actor) do
      {:ok, %Device{} = device} ->
        metadata = Map.new(device.metadata || %{})

        role_metadata = %{
          "device_role" => role.role,
          "device_role_confidence" => role.confidence,
          "device_role_source" => role.source
        }

        # The comparison still uses the freshly read map -- it is only deciding
        # whether there is anything to write. The WRITE sends the role keys alone
        # and merges them in the database, so a concurrent writer's keys are not
        # carried back from this read.
        if Map.merge(metadata, role_metadata) != metadata do
          device
          |> Ash.Changeset.for_update(:merge_metadata, %{metadata_patch: role_metadata})
          |> Ash.update(actor: actor)
        end

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning("Failed to persist device role metadata for #{device_id}: #{inspect(e)}")
      :ok
  end

  defp create_candidate_devices([], _partition, _source_device_id, _actor), do: :ok

  defp create_candidate_devices(candidate_ips, partition, source_device_id, actor) do
    candidate_ips
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(fn ip ->
      ensure_candidate_device(ip, partition, source_device_id, actor)
    end)
  end

  @doc """
  Whether an address may be seeded as a candidate device.

  Public as a testable seam. The rule is the same one aliases use: an address
  every device has (loopback, link-local, unspecified) identifies nothing, so a
  device record at that address describes nothing.
  """
  def candidate_device_address?(ip), do: AliasPolicy.valid_alias_ip?(ip)

  defp ensure_candidate_device(ip, partition, source_device_id, actor) do
    if candidate_device_address?(ip) do
      do_ensure_candidate_device(ip, partition, source_device_id, actor)
    else
      # Never mint a device for an address that cannot identify one. AliasPolicy
      # rejects loopback, unspecified, and link-local (fe80::/10, 169.254/16) --
      # every device has those, so a device record "at" one of them describes
      # nothing.
      #
      # Observed: 169.254.0.1, an APIPA address reported on switchcff8f2's own
      # interface, became device sr:b53d5a38 with no hostname and no MAC. Worse,
      # it was self-sustaining -- once the record existed, sweep picked it up as
      # a target (the record carries sweep_consecutive_failures) and revived it
      # through the undelete path, clearing the deleted_reason. Deleting it by
      # hand was not enough while something kept re-creating it.
      Logger.debug("Skipping candidate device for unroutable address #{ip}")
      :ok
    end
  end

  defp do_ensure_candidate_device(ip, partition, source_device_id, actor) do
    existing = lookup_device_uids_by_ip([ip])

    if Map.has_key?(existing, ip) do
      :ok
    else
      case find_device_uid_by_alias(ip, partition, actor) do
        {:ok, alias_uid} when is_binary(alias_uid) and alias_uid != "" ->
          Logger.debug("Mapper candidate IP #{ip} already mapped via alias #{alias_uid}")
          :ok

        _ ->
          _ = create_candidate_device_for_ip(ip, partition, source_device_id, actor)
          :ok
      end
    end
  end

  defp create_candidate_device_for_ip(ip, partition, source_device_id, actor) do
    with {:ok, uid} <- resolve_device_uid_via_dire(ip, partition, [], actor) do
      if device_exists?(uid, actor) do
        # DIRE resolved the candidate IP onto an existing device — reuse it.
        {:ok, uid}
      else
        attrs = %{
          uid: uid,
          ip: ip,
          discovery_sources: ["mapper"],
          metadata: %{
            "identity_state" => "provisional",
            "identity_source" => "mapper_client_ip_candidate_seed",
            "candidate_from_device_id" => source_device_id
          }
        }

        case Device
             |> Ash.Changeset.for_create(:create, attrs)
             |> Ash.create(actor: actor) do
          {:ok, _device} ->
            Logger.info("Mapper created candidate device #{uid} for filtered IP #{ip}")
            {:ok, uid}

          {:error, %Invalid{errors: errors}} ->
            recover_existing_device_uid(uid, ip, errors, actor)

          {:error, reason} ->
            Logger.warning(
              "Failed to create mapper candidate device for #{ip}: #{inspect(reason)}"
            )

            {:error, reason}
        end
      end
    end
  end

  @doc """
  Whether an address may be recorded as a device alias.

  Delegates to `ServiceRadar.Identity.AliasPolicy`, which is shared with the
  AliasEvents producer so both enforce one rule. Kept public because tests and
  callers in this module reference it directly.
  """
  defdelegate valid_alias_ip?(value), to: AliasPolicy

  # Resolve device_ids from device_ip addresses by looking up existing devices.
  # The agent sends device_id as "partition:ip" but Device.uid is "sr:<uuid>".
  # We need to look up the actual device UID from the IP address.
  # For IPs with no existing device, creates one via DIRE.
  defp resolve_device_ids([], _actor), do: []

  defp resolve_device_ids(records, actor) do
    # Extract unique device IPs from records
    device_ips =
      records
      |> Enum.map(& &1.device_ip)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    # Look up device UIDs by IP address
    ip_to_uid = lookup_device_uids_by_ip(device_ips)

    # For IPs with no existing device, create devices via DIRE
    ip_to_uid = create_missing_devices(records, ip_to_uid, actor)

    # Update records with resolved device_ids, filtering out those we can't resolve
    records
    |> Enum.map(fn record ->
      case Map.get(ip_to_uid, record.device_ip) do
        nil ->
          Logger.debug("No device found for interface IP: #{record.device_ip}")
          nil

        device_uid ->
          %{record | device_id: device_uid}
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Creates devices via DIRE for IPs that have no existing device record.
  # This closes the device creation gap for SNMP-polled devices that don't run agents.
  defp create_missing_devices(records, ip_to_uid, actor) do
    records
    |> Enum.map(& &1.device_ip)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reject(&Map.has_key?(ip_to_uid, &1))
    |> Enum.reduce(ip_to_uid, fn device_ip, acc ->
      partition = partition_for_device_ip(device_ip, records)
      put_alias_or_created_uid(acc, device_ip, partition, records, actor)
    end)
  end

  defp put_alias_or_created_uid(acc, device_ip, partition, records, actor) do
    case find_device_uid_by_alias(device_ip, partition, actor) do
      {:ok, alias_uid} when is_binary(alias_uid) and alias_uid != "" ->
        Logger.info("Mapper resolved device #{alias_uid} for IP #{device_ip} via alias state")
        Map.put(acc, device_ip, alias_uid)

      _ ->
        case create_device_for_ip(device_ip, records, acc, actor) do
          {:ok, device_uid} ->
            Map.put(acc, device_ip, device_uid)

          {:error, reason} ->
            Logger.warning(
              "Failed to create device for mapper-discovered IP #{device_ip}: #{inspect(reason)}"
            )

            acc
        end
    end
  end

  defp create_device_for_ip(device_ip, records, ip_to_uid, actor) do
    # Get partition from the first record matching this IP
    partition = partition_for_device_ip(device_ip, records)

    # MAC evidence comes from physical/aggregate interfaces only (deterministic
    # order). The polling agent's `agent_id` on these records names the agent
    # that performed the poll, never the polled device, and is deliberately
    # excluded from identity resolution and registration (Polling Agent
    # Exclusion).
    identity_macs = derive_identity_macs(device_ip, records)
    primary_mac = List.first(identity_macs)

    # The UID decision belongs to DIRE: resolution consults identifier rows,
    # alias states, and the merge-audit canonical mapping before falling back
    # to the deterministic seed (primary MAC when present, otherwise IP-only).
    with {:ok, device_uid} <-
           resolve_device_uid_via_dire(device_ip, partition, identity_macs, actor) do
      if device_exists?(device_uid, actor) do
        # DIRE resolved onto an existing device (e.g. a MAC already registered
        # for another IP) — reuse it instead of creating a duplicate.
        register_mapper_mac_identifiers(device_uid, identity_macs, device_ip, partition, actor)
        {:ok, device_uid}
      else
        create_resolved_device_for_ip(
          device_uid,
          device_ip,
          identity_macs,
          primary_mac,
          partition,
          records,
          ip_to_uid,
          actor
        )
      end
    end
  end

  defp create_resolved_device_for_ip(
         device_uid,
         device_ip,
         identity_macs,
         primary_mac,
         partition,
         records,
         ip_to_uid,
         actor
       ) do
    # If this IP appears as an interface address on another device, set management_device_id
    management_device_id = find_management_device_uid(device_ip, records, ip_to_uid)

    # Create the device record
    attrs =
      maybe_put(
        %{
          uid: device_uid,
          ip: device_ip,
          mac: primary_mac,
          discovery_sources: ["mapper"],
          metadata: %{
            "identity_state" => "provisional",
            "identity_source" =>
              if(primary_mac, do: "mapper_primary_mac_seed", else: "mapper_ip_seed")
          }
        },
        :management_device_id,
        management_device_id
      )

    case Device
         |> Ash.Changeset.for_create(:create, attrs)
         |> Ash.create(actor: actor) do
      {:ok, _device} ->
        Logger.info("Mapper created device #{device_uid} for IP #{device_ip}")
        register_mapper_mac_identifiers(device_uid, identity_macs, device_ip, partition, actor)

        if management_device_id,
          do: TopologyGraph.upsert_managed_by(device_uid, management_device_id)

        {:ok, device_uid}

      {:error, %Invalid{errors: errors}} ->
        with {:ok, recovered_uid} <-
               recover_existing_device_uid(device_uid, device_ip, errors, actor) do
          register_mapper_mac_identifiers(
            recovered_uid,
            identity_macs,
            device_ip,
            partition,
            actor
          )

          {:ok, recovered_uid}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # All mapper device creation routes through DIRE: the reconciler decides the
  # UID by consulting strong identifiers, confirmed IP aliases, and the
  # merge-audit canonical mapping (so merged-away devices are never
  # resurrected) before falling back to the deterministic `sr:` uid. The
  # update never carries the polling agent's identity.
  defp resolve_device_uid_via_dire(ip, partition, mac_evidence, actor) do
    update = %{
      device_id: nil,
      ip: ip,
      mac: List.first(mac_evidence),
      mac_addresses: mac_evidence,
      partition: partition,
      metadata: %{}
    }

    case IdentityReconciler.resolve_device_id(update, actor: actor) do
      {:ok, uid} when is_binary(uid) and uid != "" ->
        {:ok, uid}

      {:ok, other} ->
        {:error, {:unresolved_device_uid, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Register the mapper's interface MAC evidence for the resolved device
  # through DIRE so subsequent updates carrying any of these MACs resolve to
  # the same device. Confidence is derived per-MAC (IEEE local bit) inside the
  # reconciler. The polling agent's `agent_id` is never registered for the
  # polled device (Polling Agent Exclusion).
  defp register_mapper_mac_identifiers(_device_uid, [], _ip, _partition, _actor), do: :ok

  defp register_mapper_mac_identifiers(device_uid, macs, ip, partition, actor) do
    ids =
      IdentityReconciler.extract_strong_identifiers(%{
        device_id: nil,
        ip: ip,
        mac: List.first(macs),
        mac_addresses: macs,
        partition: partition,
        metadata: %{}
      })

    case IdentityReconciler.register_identifiers(device_uid, ids, actor: actor) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Mapper identifier registration failed for #{device_uid}: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning("Mapper identifier registration raised for #{device_uid}: #{inspect(e)}")
      :ok
  end

  @doc false
  def find_device_uid_by_alias(device_ip, partition, actor) do
    if AliasPolicy.valid_alias_ip?(device_ip) do
      do_find_device_uid_by_alias(device_ip, partition, actor)
    else
      {:ok, nil}
    end
  end

  defp do_find_device_uid_by_alias(device_ip, partition, actor) do
    case DeviceAliasState.lookup_by_value(:ip, device_ip, actor: actor) do
      {:ok, aliases} ->
        aliases
        |> Enum.filter(&eligible_alias_partition?(&1.partition, partition))
        |> Enum.reject(&(&1.state in [:replaced, :archived]))
        |> Enum.sort_by(&alias_rank_key/1, :desc)
        |> Enum.find_value(&alias_device_uid(&1, actor))
        |> then(&{:ok, &1})

      {:error, reason} ->
        Logger.warning(
          "Failed alias lookup for mapper-discovered IP #{device_ip}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("Alias lookup raised for mapper-discovered IP #{device_ip}: #{inspect(e)}")
      {:error, e}
  end

  defp eligible_alias_partition?(alias_partition, requested_partition) do
    alias_partition = normalize_partition(alias_partition)
    requested_partition = normalize_partition(requested_partition)
    alias_partition == requested_partition
  end

  defp alias_device_uid(alias_state, actor) do
    case Device.get_by_uid(alias_state.device_id, false, actor: actor) do
      {:ok, %Device{deleted_at: nil}} ->
        maybe_reactivate_alias(alias_state, actor)
        alias_state.device_id

      _ ->
        nil
    end
  end

  defp normalize_partition(nil), do: "default"
  defp normalize_partition(""), do: "default"
  defp normalize_partition(value), do: value

  defp alias_rank_key(alias_state) do
    state_rank =
      case alias_state.state do
        :confirmed -> 4
        :updated -> 3
        :detected -> 2
        :stale -> 1
        _ -> 0
      end

    sighting_count = alias_state.sighting_count || 0

    last_seen_unix =
      case alias_state.last_seen_at do
        %DateTime{} = dt -> DateTime.to_unix(dt, :microsecond)
        _ -> 0
      end

    {state_rank, sighting_count, last_seen_unix}
  end

  defp maybe_reactivate_alias(
         %DeviceAliasState{state: :stale, alias_value: value} = alias_state,
         actor
       ) do
    if AliasPolicy.valid_alias_ip?(value) do
      alias_state
      |> Ash.Changeset.for_update(:reactivate, %{})
      |> Ash.update(actor: actor)
    end

    :ok
  rescue
    e ->
      Logger.warning("Failed to reactivate stale alias #{alias_state.id}: #{inspect(e)}")
      :ok
  end

  defp maybe_reactivate_alias(_alias_state, _actor), do: :ok

  defp partition_for_device_ip(device_ip, records) do
    records
    |> Enum.find(fn record -> record.device_ip == device_ip end)
    |> case do
      nil -> "default"
      record -> record.partition || "default"
    end
  end

  # Checks if device_ip appears in any interface's ip_addresses belonging to a
  # different device, and returns that parent device's UID if found.
  defp find_management_device_uid(device_ip, records, ip_to_uid) do
    records
    |> Enum.find(fn record ->
      record.device_ip != device_ip &&
        is_list(record.ip_addresses) &&
        Enum.any?(record.ip_addresses, &ip_matches?(&1, device_ip))
    end)
    |> case do
      nil -> nil
      record -> Map.get(ip_to_uid, record.device_ip)
    end
  end

  # Matches an interface IP (which may include a CIDR suffix like "203.0.113.5/24")
  # against a bare IP address.
  defp ip_matches?(interface_ip, device_ip) when is_binary(interface_ip) do
    interface_ip == device_ip || String.starts_with?(interface_ip, device_ip <> "/")
  end

  defp ip_matches?(_, _), do: false

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp recover_existing_device_uid(device_uid, device_ip, errors, actor) do
    # Device may have been created concurrently; recover by re-reading by IP.
    if Enum.any?(errors, &recoverable_device_create_conflict?/1) do
      recover_existing_device_uid_from_conflict(device_uid, device_ip, errors, actor)
    else
      {:error, errors}
    end
  end

  defp recoverable_device_create_conflict?(%Ash.Error.Changes.InvalidChanges{}), do: true

  defp recoverable_device_create_conflict?(%InvalidAttribute{} = error) do
    error.field == :uid and
      Keyword.get(error.private_vars || [], :constraint_type) == :unique
  end

  defp recoverable_device_create_conflict?(_error), do: false

  defp recover_existing_device_uid_from_conflict(device_uid, device_ip, errors, actor) do
    if device_exists?(device_uid, actor) do
      {:ok, device_uid}
    else
      case lookup_device_uids_by_ip([device_ip]) do
        %{^device_ip => uid} -> {:ok, uid}
        _ -> {:error, errors}
      end
    end
  end

  defp device_exists?(uid, actor) when is_binary(uid) do
    case Device.get_by_uid(uid, false, actor: actor) do
      {:ok, _device} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  # Deterministically ordered MAC evidence for a polled device: physical and
  # aggregate interfaces only (loopback/virtual/bridge/tunnel and VRRP
  # interfaces are not identity evidence). The sorted-first entry is the primary
  # identity seed, matching the historical deterministic-uid derivation.
  defp derive_identity_macs(device_ip, records) do
    records
    |> Enum.filter(&(&1.device_ip == device_ip))
    |> Enum.filter(&primary_identity_interface?/1)
    |> Enum.map(&normalize_mac(&1.if_phys_address))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp primary_identity_interface?(record) do
    not vrrp_interface?(record) and
      case String.downcase(to_string(record.interface_kind || "")) do
        "loopback" -> false
        "virtual" -> false
        "bridge" -> false
        "tunnel" -> false
        _ -> true
      end
  end

  defp vrrp_interface?(record) do
    Enum.any?([record.if_name, record.if_descr], &vrrp_interface_label?/1)
  end

  defp vrrp_interface_label?(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
    |> String.starts_with?("vrrp")
  end

  defp vrrp_interface_label?(_label), do: false

  defp normalize_mac(nil), do: nil
  defp normalize_mac(mac), do: IdentityReconciler.normalize_mac(mac)

  defp lookup_device_uids_by_ip([]), do: %{}

  defp lookup_device_uids_by_ip(ips) do
    query =
      from(d in Device,
        where: is_nil(d.deleted_at),
        where: d.ip in ^ips,
        select: {d.ip, d.uid, d.metadata}
      )

    query
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0))
    |> Map.new(fn {ip, entries} -> {ip, canonical_uid_for_ip_entries(entries)} end)
  rescue
    e ->
      Logger.warning("Device UID lookup failed: #{inspect(e)}")
      %{}
  end

  defp canonical_uid_for_ip_entries(entries) do
    entries
    |> Enum.sort_by(&device_ip_resolution_rank/1)
    |> Enum.find_value(fn
      {_ip, uid, _metadata} -> maybe_canonical_topology_uid(uid)
      _ -> nil
    end)
  end

  defp maybe_canonical_topology_uid(uid) do
    normalized_uid = normalize_string(uid)
    if canonical_topology_uid?(normalized_uid), do: uid
  end

  defp device_ip_resolution_rank({_ip, uid, metadata}) do
    metadata = if is_map(metadata), do: metadata, else: %{}
    identity_source = normalize_string(Map.get(metadata, "identity_source"))
    identity_state = normalize_string(Map.get(metadata, "identity_state"))

    provisional_rank =
      if identity_source == "mapper_topology_sighting" do
        1
      else
        0
      end

    uid_rank =
      if is_binary(uid) and String.starts_with?(uid, "sr:") do
        0
      else
        1
      end

    state_rank =
      case identity_state do
        "canonical" -> 0
        "provisional" -> 1
        _ -> 2
      end

    {provisional_rank, uid_rank, state_rank, uid || ""}
  end

  # Resolve device IDs for topology records (local_device_id and neighbor_device_id)
  defp resolve_topology_device_ids([]), do: []

  defp resolve_topology_device_ids(records) do
    device_index = build_topology_device_index(records)
    resolve_topology_records(records, device_index)
  end

  @doc false
  def enrich_resolved_topology_records(records, devices_by_uid \\ nil)

  def enrich_resolved_topology_records([], _devices_by_uid), do: []

  def enrich_resolved_topology_records(records, nil) when is_list(records) do
    devices_by_uid =
      records
      |> Enum.flat_map(fn record ->
        [
          normalize_string(Map.get(record, :local_device_id)),
          normalize_string(Map.get(record, :neighbor_device_id))
        ]
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> lookup_topology_devices_by_uid()
      |> Map.new(fn device -> {normalize_string(device.uid), device} end)

    strong_device_ids = strong_topology_device_ids(records)

    enrich_resolved_topology_records(records, %{
      devices_by_uid: devices_by_uid,
      strong_device_ids: strong_device_ids
    })
  end

  def enrich_resolved_topology_records(records, %{
        devices_by_uid: devices_by_uid,
        strong_device_ids: strong_device_ids
      })
      when is_list(records) do
    Enum.map(records, &enrich_resolved_topology_record(&1, devices_by_uid, strong_device_ids))
  end

  def enrich_resolved_topology_records(records, devices_by_uid)
      when is_list(records) and is_map(devices_by_uid) do
    strong_device_ids = strong_topology_device_ids(records)
    Enum.map(records, &enrich_resolved_topology_record(&1, devices_by_uid, strong_device_ids))
  end

  defp enrich_resolved_topology_record(record, devices_by_uid, strong_device_ids)
       when is_map(record) do
    cond do
      snmp_arp_fdb_record?(record) ->
        maybe_promote_snmp_fdb_attachment(record, devices_by_uid, strong_device_ids)

      direct_endpoint_attachment_record?(record) ->
        maybe_promote_direct_endpoint_attachment(record, devices_by_uid)

      true ->
        record
    end
  end

  defp enrich_resolved_topology_record(record, _devices_by_uid, _strong_device_ids), do: record

  defp maybe_promote_snmp_fdb_attachment(record, devices_by_uid, strong_device_ids) do
    neighbor_uid = normalize_string(Map.get(record, :neighbor_device_id))
    neighbor_device = Map.get(devices_by_uid, neighbor_uid)

    cond do
      MapSet.member?(strong_device_ids, neighbor_uid) ->
        ensure_relation_family(record, "INFERRED_TO")

      endpoint_attachment_candidate_device?(neighbor_device) ->
        metadata =
          record
          |> Map.get(:metadata)
          |> ensure_map()
          |> Map.put("evidence_class", "inferred-segment")
          |> Map.put("relation_family", "ATTACHED_TO")
          |> maybe_put_metadata_value("confidence_tier", "medium")
          |> maybe_put_metadata_value("confidence_score", 72)
          |> maybe_put_metadata_value("confidence_reason", "arp_fdb_port_mapping")

        Map.put(record, :metadata, metadata)

      true ->
        ensure_relation_family(record, "INFERRED_TO")
    end
  end

  defp snmp_arp_fdb_record?(record) when is_map(record) do
    normalize_topology_protocol(Map.get(record, :protocol)) == "snmp-l2" and
      metadata_value(Map.get(record, :metadata), "source") == "snmp-arp-fdb"
  end

  defp snmp_arp_fdb_record?(_record), do: false

  defp direct_endpoint_attachment_record?(record) when is_map(record) do
    metadata_value(Map.get(record, :metadata), "source") in ["lldp", "cdp"]
  end

  defp direct_endpoint_attachment_record?(_record), do: false

  # LLDP/CDP neighbors that resolved to a provisional endpoint-candidate device
  # get the ATTACHED_TO upgrade; infrastructure-resolved (or unresolved)
  # neighbors keep their direct-physical CONNECTS_TO backbone semantics. The
  # strong-evidence set is deliberately not consulted here: an LLDP/CDP record
  # marks its own neighbor strong, which would make the upgrade unreachable.
  defp maybe_promote_direct_endpoint_attachment(record, devices_by_uid) do
    neighbor_uid = normalize_string(Map.get(record, :neighbor_device_id))
    neighbor_device = Map.get(devices_by_uid, neighbor_uid)

    if endpoint_attachment_candidate_device?(neighbor_device) do
      metadata =
        record
        |> Map.get(:metadata)
        |> ensure_map()
        |> Map.put("relation_family", "ATTACHED_TO")

      Map.put(record, :metadata, metadata)
    else
      record
    end
  end

  defp endpoint_attachment_candidate_device?(device) when is_map(device) do
    metadata = ensure_map(Map.get(device, :metadata))
    type = normalize_string(Map.get(device, :type))
    type_id = Map.get(device, :type_id)
    identity_source = normalize_string(Map.get(metadata, "identity_source"))
    identity_state = normalize_string(Map.get(metadata, "identity_state"))
    device_role = normalize_string(Map.get(metadata, "device_role"))
    name = normalize_string(Map.get(device, :name))
    hostname = normalize_string(Map.get(device, :hostname))

    provisional_topology_sighting? =
      identity_source == "mapper_topology_sighting" or identity_state == "provisional"

    endpoint_like_role? = device_role in [nil, "", "host", "unknown"]

    provisional_topology_sighting? and endpoint_like_role? and
      not infrastructure_topology_device?(type, type_id) and
      not present?(name) and not present?(hostname)
  end

  defp endpoint_attachment_candidate_device?(_device), do: false

  defp ensure_relation_family(record, relation_family)
       when is_map(record) and is_binary(relation_family) do
    metadata =
      record
      |> Map.get(:metadata)
      |> ensure_map()
      |> Map.put_new("relation_family", relation_family)
      |> Map.update("evidence_class", "inferred-segment", &normalize_topology_evidence_class/1)

    Map.put(record, :metadata, metadata)
  end

  defp infrastructure_topology_device?(type, type_id) do
    normalized_type = normalize_string(type)

    normalized_type in ["router", "switch", "access point", "firewall", "wireless controller"] or
      type_id in [10, 12, 99]
  end

  defp strong_topology_device_ids(records) when is_list(records) do
    Enum.reduce(records, MapSet.new(), fn record, acc ->
      if strong_topology_evidence_record?(record) do
        [Map.get(record, :local_device_id), Map.get(record, :neighbor_device_id)]
        |> Enum.map(&normalize_string/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.reduce(acc, &MapSet.put(&2, &1))
      else
        acc
      end
    end)
  end

  defp strong_topology_evidence_record?(record) when is_map(record) do
    metadata = ensure_map(Map.get(record, :metadata))
    protocol = normalize_topology_protocol(Map.get(record, :protocol))
    source = metadata_value(metadata, "source")

    evidence_class =
      metadata_value(metadata, "evidence_class") || default_topology_evidence_class(protocol)

    evidence_class in ["direct-physical", "direct-logical", "hosted-virtual"] and
      (protocol in ["lldp", "cdp", "wireguard-derived", "unifi-api"] or
         source in ["unifi-api-uplink", "wireguard-derived", "lldp", "cdp"])
  end

  defp strong_topology_evidence_record?(_record), do: false

  defp maybe_put_neighbor_id(record, uid) when is_binary(uid),
    do: Map.put(record, :neighbor_device_id, uid)

  defp maybe_put_neighbor_id(record, nil) do
    current = normalize_string(record.neighbor_device_id)

    if canonical_topology_uid?(current) do
      record
    else
      Map.put(record, :neighbor_device_id, nil)
    end
  end

  # Deterministic rule:
  # - tunnel interface name starts with "wg"
  # - same exact tunnel name appears on exactly 2 router devices
  # - each side provides at least one tunnel IP
  # Emits a single derived WireGuard edge for that pair.
  defp add_deterministic_wireguard_links([]), do: []

  defp add_deterministic_wireguard_links(records) do
    context = inference_context(records)
    partition = context.partition || "default"

    interfaces =
      partition
      |> lookup_recent_wireguard_interfaces_by_partition()
      |> canonicalize_wireguard_interface_device_ids()

    device_uids =
      interfaces
      |> Enum.map(fn iface ->
        normalize_string(Map.get(iface, :device_id) || Map.get(iface, "device_id"))
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if device_uids == [] do
      records
    else
      devices = lookup_topology_devices_by_uid(device_uids)
      inferred = infer_wireguard_tunnel_links(records, interfaces, devices)
      records ++ inferred
    end
  rescue
    e ->
      Logger.warning("Deterministic WireGuard derivation failed: #{inspect(e)}")
      records
  end

  defp lookup_recent_wireguard_interfaces_by_partition(partition) do
    query =
      from(i in Interface,
        where: i.partition == ^partition,
        where: i.timestamp > ago(6, "hour"),
        where: ilike(i.if_name, "wg%") or ilike(i.if_descr, "wg%"),
        select: %{
          device_id: i.device_id,
          device_ip: i.device_ip,
          timestamp: i.timestamp,
          if_name: i.if_name,
          if_descr: i.if_descr,
          ip_addresses: i.ip_addresses
        }
      )

    Repo.all(query)
  end

  defp canonicalize_wireguard_interface_device_ids([]), do: []

  defp canonicalize_wireguard_interface_device_ids(interfaces) do
    ips =
      interfaces
      |> Enum.filter(&wireguard_device_id_needs_resolution?/1)
      |> Enum.map(&wireguard_device_ip/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    ip_to_uid = lookup_device_uids_by_ip(ips)
    Enum.map(interfaces, &put_canonical_wireguard_device_id(&1, ip_to_uid))
  end

  defp wireguard_device_id_needs_resolution?(iface) do
    iface
    |> Map.get(:device_id, Map.get(iface, "device_id"))
    |> normalize_string()
    |> canonical_topology_uid?()
    |> Kernel.not()
  end

  defp wireguard_device_ip(iface) do
    normalize_interface_ip(Map.get(iface, :device_ip) || Map.get(iface, "device_ip"))
  end

  defp put_canonical_wireguard_device_id(iface, ip_to_uid) do
    if wireguard_device_id_needs_resolution?(iface) do
      case Map.get(ip_to_uid, wireguard_device_ip(iface)) do
        uid when is_binary(uid) -> Map.put(iface, :device_id, uid)
        _ -> iface
      end
    else
      iface
    end
  end

  @doc false
  def infer_wireguard_tunnel_links(records, interfaces, devices)
      when is_list(records) and is_list(interfaces) and is_list(devices) do
    devices_by_uid = Map.new(devices, fn d -> {normalize_string(d.uid), d} end)
    existing = existing_topology_edge_set(records)
    context = inference_context(records)

    interfaces
    |> Enum.map(&normalize_wireguard_interface/1)
    |> Enum.filter(&valid_wireguard_interface?/1)
    |> latest_wireguard_interfaces()
    |> Enum.group_by(& &1.tunnel_name)
    |> Enum.flat_map(&infer_wireguard_group(&1, devices_by_uid, existing, context))
  end

  defp normalize_wireguard_interface(iface) do
    %{
      device_id: normalize_string(Map.get(iface, :device_id) || Map.get(iface, "device_id")),
      timestamp: Map.get(iface, :timestamp) || Map.get(iface, "timestamp"),
      tunnel_name: wireguard_tunnel_name(iface),
      tunnel_ip: wireguard_tunnel_ip(iface)
    }
  end

  defp wireguard_tunnel_name(iface) do
    normalize_string(Map.get(iface, :tunnel_name) || Map.get(iface, "tunnel_name")) ||
      wireguard_name_from_iface(
        Map.get(iface, :if_name) || Map.get(iface, "if_name"),
        Map.get(iface, :if_descr) || Map.get(iface, "if_descr")
      )
  end

  defp wireguard_tunnel_ip(iface) do
    normalize_interface_ip(Map.get(iface, :tunnel_ip) || Map.get(iface, "tunnel_ip")) ||
      first_wireguard_interface_ip(
        Map.get(iface, :ip_addresses) || Map.get(iface, "ip_addresses") || []
      )
  end

  defp valid_wireguard_interface?(iface) do
    is_binary(iface.device_id) and is_binary(iface.tunnel_name) and is_binary(iface.tunnel_ip)
  end

  defp latest_wireguard_interfaces(interfaces) do
    interfaces
    |> Enum.group_by(fn iface -> {iface.device_id, iface.tunnel_name} end)
    |> Enum.map(fn {_key, rows} ->
      Enum.max_by(rows, fn row -> row.timestamp || DateTime.from_unix!(0) end)
    end)
  end

  defp infer_wireguard_group({_tunnel_name, members}, devices_by_uid, existing, context) do
    case unique_wireguard_members(members) do
      [left, right] ->
        build_wireguard_link_pair(left, right, devices_by_uid, existing, context)

      _ ->
        []
    end
  end

  defp unique_wireguard_members(members) do
    Enum.uniq_by(members, & &1.device_id)
  end

  defp build_wireguard_link_pair(left, right, devices_by_uid, existing, context) do
    left_device = Map.get(devices_by_uid, left.device_id)
    right_device = Map.get(devices_by_uid, right.device_id)
    edge_key = normalized_edge_key(left.device_id, right.device_id)

    if valid_wireguard_pair?(left_device, right_device, existing, edge_key) do
      emit_wireguard_link(left, right, left_device, right_device, context)
    else
      []
    end
  end

  defp valid_wireguard_pair?(left_device, right_device, existing, edge_key) do
    is_map(left_device) and is_map(right_device) and
      router_type?(normalize_string(left_device.type), left_device.type_id) and
      router_type?(normalize_string(right_device.type), right_device.type_id) and
      not MapSet.member?(existing, edge_key)
  end

  defp emit_wireguard_link(left, right, left_device, right_device, context) do
    {local, neighbor, local_device, neighbor_device} =
      canonical_wireguard_pair(left, right, left_device, right_device)

    local_ip = normalize_interface_ip(local_device.ip) || local.tunnel_ip
    neighbor_ip = normalize_interface_ip(neighbor_device.ip) || neighbor.tunnel_ip

    if is_binary(local_ip) and is_binary(neighbor_ip) do
      [build_wireguard_link(local, neighbor, local_ip, neighbor_ip, neighbor_device, context)]
    else
      []
    end
  end

  defp canonical_wireguard_pair(left, right, left_device, right_device) do
    if left.device_id <= right.device_id do
      {left, right, left_device, right_device}
    else
      {right, left, right_device, left_device}
    end
  end

  defp build_wireguard_link(local, neighbor, local_ip, neighbor_ip, neighbor_device, context) do
    %{
      timestamp: max_wireguard_timestamp(local.timestamp, neighbor.timestamp),
      agent_id: context.agent_id,
      gateway_id: context.gateway_id,
      partition: context.partition || "default",
      protocol: "wireguard-derived",
      local_device_ip: local_ip,
      local_device_id: local.device_id,
      local_if_index: nil,
      local_if_name: local.tunnel_name,
      neighbor_device_id: neighbor.device_id,
      neighbor_chassis_id: nil,
      neighbor_port_id: local.tunnel_name,
      neighbor_port_descr: "wireguard",
      neighbor_system_name:
        first_non_blank([neighbor_device.name, neighbor_device.hostname, neighbor.device_id]),
      neighbor_mgmt_addr: neighbor_ip,
      metadata: wireguard_link_metadata(local.tunnel_name),
      created_at: context.created_at
    }
  end

  defp wireguard_link_metadata(tunnel_name) do
    %{
      "source" => "wireguard-derived",
      "evidence_class" => "direct-logical",
      "relation_family" => "LOGICAL_PEER",
      "rule" => "exact_wg_interface_name_two_router_endpoints",
      "tunnel_name" => tunnel_name,
      "confidence_tier" => "high",
      "confidence_score" => 95,
      "confidence_reason" => "deterministic_wireguard_tunnel_match"
    }
  end

  defp wireguard_name_from_iface(if_name, if_descr) do
    [if_name, if_descr]
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.find(fn name -> String.starts_with?(name, "wg") end)
  end

  defp first_wireguard_interface_ip(values) when is_list(values) do
    values
    |> Enum.map(&normalize_interface_ip/1)
    |> Enum.find(&is_binary/1)
  end

  defp first_wireguard_interface_ip(_values), do: nil

  defp max_wireguard_timestamp(a, b) do
    [a, b]
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> Enum.max(fn -> DateTime.utc_now() end)
  end

  defp existing_topology_edge_set(records) do
    Enum.reduce(records, MapSet.new(), fn record, acc ->
      local_uid = normalize_string(record.local_device_id)
      neighbor_uid = normalize_string(record.neighbor_device_id)

      if local_uid && neighbor_uid do
        MapSet.put(acc, normalized_edge_key(local_uid, neighbor_uid))
      else
        acc
      end
    end)
  end

  defp inference_context(records) do
    newest_timestamp =
      records
      |> Enum.map(& &1.timestamp)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> DateTime.utc_now() end)

    %{
      timestamp: newest_timestamp,
      agent_id: first_present(records, & &1.agent_id),
      gateway_id: first_present(records, & &1.gateway_id),
      partition: first_present(records, & &1.partition) || "default",
      created_at: DateTime.truncate(DateTime.utc_now(), :microsecond)
    }
  end

  defp first_present(records, accessor) when is_function(accessor, 1) do
    records
    |> Enum.map(accessor)
    |> Enum.find(&present?/1)
  end

  defp lookup_topology_devices_by_uid([]), do: []

  defp lookup_topology_devices_by_uid(uids) do
    query =
      from(d in Device,
        where: d.uid in ^uids and is_nil(d.deleted_at),
        select: %{
          uid: d.uid,
          management_device_id: d.management_device_id,
          ip: d.ip,
          name: d.name,
          hostname: d.hostname,
          type: d.type,
          type_id: d.type_id,
          metadata: d.metadata
        }
      )

    Repo.all(query)
  end

  defp router_type?(type, type_id), do: type_id == 12 or type == "router"

  defp metadata_value(metadata, key) when is_map(metadata) and is_binary(key) do
    metadata
    |> Map.get(key)
    |> normalize_string()
  end

  defp metadata_value(_, _), do: nil

  defp normalized_edge_key(a, b) when is_binary(a) and is_binary(b) do
    if a <= b, do: {a, b}, else: {b, a}
  end

  defp normalize_interface_ip(nil), do: nil
  defp normalize_interface_ip(""), do: nil

  defp normalize_interface_ip(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" ->
        nil

      trimmed ->
        trimmed
        |> String.split("/", parts: 2)
        |> List.first()
        |> case do
          "" -> nil
          ip -> ip
        end
    end
  end

  defp normalize_interface_ip(value) do
    value
    |> to_string()
    |> normalize_interface_ip()
  end

  defp first_non_blank(values) when is_list(values) do
    values
    |> Enum.find(fn value ->
      value
      |> normalize_string()
      |> is_binary()
    end)
    |> case do
      nil -> nil
      value -> String.trim(to_string(value))
    end
  end

  @doc false
  def resolve_topology_records(records, device_index)
      when is_list(records) and is_map(device_index) do
    # For topology, we keep records even if we can't resolve neighbor (it may be external).
    # Local endpoint must resolve to a canonical active device.
    records
    |> Enum.map(fn record ->
      partition = topology_record_partition(record)

      local_uid =
        resolve_topology_uid(
          record.local_device_id,
          record.local_device_ip,
          nil,
          nil,
          device_index
        )

      neighbor_uid =
        resolve_topology_uid(
          record.neighbor_device_id,
          record.neighbor_mgmt_addr,
          record.neighbor_system_name,
          record.neighbor_chassis_id,
          device_index,
          record
        )

      resolved_local_uid =
        local_uid ||
          fallback_topology_uid(record.local_device_id, record.local_device_ip, partition)

      if resolved_local_uid do
        record
        |> preserve_source_endpoint_ids()
        |> Map.put(:local_device_id, resolved_local_uid)
        |> maybe_put_neighbor_id(neighbor_uid)
      else
        Logger.debug(
          "No canonical device found for topology local endpoint id=#{inspect(record.local_device_id)} ip=#{inspect(record.local_device_ip)}"
        )

        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp resolve_topology_uid(
         candidate_uid,
         candidate_ip,
         candidate_name,
         candidate_chassis,
         index,
         record \\ nil
       ) do
    uid = normalize_string(candidate_uid)
    chassis = normalize_mac(candidate_chassis)
    mac_uid = resolve_topology_uid_match(index.mac_to_uid, chassis)
    ip_uid = resolve_topology_uid_match(index.ip_to_uid, normalize_string(candidate_ip))

    Enum.find(
      [
        resolve_topology_uid_match(index.uid_to_uid, uid),
        canonical_topology_uid_or_nil(uid),
        neighbor_mac_or_ip_uid(chassis, mac_uid, ip_uid, record),
        resolve_topology_name_match(candidate_name, index)
      ],
      &is_binary/1
    )
  end

  # Chassis MAC is L2 identity. When it names a different device than the
  # neighbor IP, the IP is hearsay (stale ARP, cross-subnet FDB) and must not
  # win. When the MAC is unknown, weak L2 evidence also must not fall back to
  # IP — that fallback is what drew a farm switch to a dead MikroTik.
  defp neighbor_mac_or_ip_uid(chassis, mac_uid, ip_uid, record) do
    cond do
      is_binary(mac_uid) ->
        mac_uid

      is_binary(chassis) and weak_l2_neighbor_identity?(topology_record_metadata(record)) ->
        nil

      true ->
        ip_uid
    end
  end

  defp topology_record_metadata(%{metadata: metadata}) when is_map(metadata), do: metadata
  defp topology_record_metadata(%{"metadata" => metadata}) when is_map(metadata), do: metadata
  defp topology_record_metadata(_), do: %{}

  defp resolve_topology_uid_match(_index_map, nil), do: nil

  defp resolve_topology_uid_match(index_map, value),
    do: canonical_uid_from_index(index_map, value)

  defp canonical_topology_uid_or_nil(uid) do
    if is_binary(uid) and canonical_topology_uid?(uid), do: uid
  end

  defp resolve_topology_name_match(candidate_name, index) do
    candidate_name
    |> topology_name_candidates()
    |> Enum.find_value(&canonical_uid_from_index(index.name_to_uid, &1))
  end

  defp preserve_source_endpoint_ids(record) when is_map(record) do
    metadata =
      record
      |> Map.get(:metadata, %{})
      |> case do
        map when is_map(map) -> map
        _ -> %{}
      end

    metadata =
      metadata
      |> maybe_put_metadata_value("source_local_uid", normalize_string(record.local_device_id))
      |> maybe_put_metadata_value(
        "source_target_uid",
        normalize_string(record.neighbor_device_id)
      )

    Map.put(record, :metadata, metadata)
  end

  defp canonical_topology_uid?(uid) when is_binary(uid) do
    IdentityReconciler.serviceradar_uuid?(uid) or IdentityReconciler.service_device_id?(uid)
  end

  defp canonical_topology_uid?(_uid), do: false

  defp fallback_topology_uid(candidate_uid, candidate_ip, partition) do
    uid = normalize_string(candidate_uid)
    ip = normalize_string(candidate_ip)

    cond do
      is_binary(uid) and canonical_topology_uid?(uid) ->
        uid

      is_binary(ip) ->
        IdentityReconciler.generate_deterministic_device_id(%{
          agent_id: nil,
          armis_id: nil,
          integration_id: nil,
          netbox_id: nil,
          mac: nil,
          ip: ip,
          partition: normalize_partition(partition)
        })

      true ->
        nil
    end
  end

  defp topology_record_partition(record) when is_map(record) do
    Map.get(record, :partition) || Map.get(record, "partition")
  end

  defp build_topology_device_index(records) do
    ips =
      records
      |> Enum.flat_map(
        &[normalize_string(&1.local_device_ip), normalize_string(&1.neighbor_mgmt_addr)]
      )
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    uids =
      records
      |> Enum.flat_map(
        &[normalize_string(&1.local_device_id), normalize_string(&1.neighbor_device_id)]
      )
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    names =
      records
      |> Enum.flat_map(fn record ->
        topology_name_candidates(record.neighbor_system_name)
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    macs =
      records
      |> Enum.map(&normalize_mac(&1.neighbor_chassis_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if ips == [] and uids == [] and names == [] and macs == [] do
      empty_topology_device_index()
    else
      identifier_index =
        build_identifier_topology_index(macs, ips, topology_record_partitions(records))

      query =
        from(d in Device,
          where: is_nil(d.deleted_at),
          where:
            d.ip in ^ips or d.uid in ^uids or fragment("LOWER(COALESCE(?, ''))", d.name) in ^names or
              fragment("LOWER(COALESCE(?, ''))", d.hostname) in ^names or
              fragment(
                "REPLACE(REPLACE(REPLACE(UPPER(COALESCE(?, '')), ':', ''), '-', ''), '.', '')",
                d.mac
              ) in ^macs,
          select: %{
            uid: d.uid,
            ip: d.ip,
            name: d.name,
            hostname: d.hostname,
            mac: d.mac,
            metadata: d.metadata
          }
        )

      query
      |> Repo.all()
      |> build_topology_device_index_maps(identifier_index)
    end
  rescue
    e ->
      Logger.warning("Topology device index lookup failed: #{inspect(e)}")
      empty_topology_device_index()
  end

  defp topology_record_partitions(records) do
    records
    |> Enum.map(&normalize_partition(topology_record_partition(&1)))
    |> Enum.uniq()
  end

  # Identifier-aware neighbor resolution: consult the canonical identity graph
  # (platform.device_identifiers) for the payload's MACs and IPs so a sighting
  # carrying a registered secondary identifier binds to its device. MAC values
  # are byte-identical to the index keys (12 uppercase hex). Kept in its own
  # rescue so a failure here degrades to the ocsf-only index instead of
  # killing all binding for the payload.
  defp build_identifier_topology_index(macs, ips, partitions) do
    if macs == [] and ips == [] do
      empty_topology_device_index()
    else
      query =
        from(di in DeviceIdentifier,
          join: d in Device,
          on: d.uid == di.device_id,
          where: is_nil(d.deleted_at),
          where: di.partition in ^partitions,
          where:
            (di.identifier_type == ^"mac" and di.identifier_value in ^macs) or
              (di.identifier_type == ^"ip" and di.identifier_value in ^ips),
          select: {di.identifier_type, di.identifier_value, di.device_id}
        )

      query
      |> Repo.all()
      |> Enum.sort()
      |> Enum.reduce(empty_topology_device_index(), fn {type, value, device_id}, acc ->
        uid = normalize_string(device_id)

        if canonical_topology_uid?(uid) do
          case to_string(type) do
            "mac" -> put_topology_index_entry(acc, :mac_to_uid, value, uid)
            "ip" -> put_topology_index_entry(acc, :ip_to_uid, value, uid)
            _ -> acc
          end
        else
          acc
        end
      end)
    end
  rescue
    e ->
      Logger.warning("Topology identifier index lookup failed: #{inspect(e)}")
      empty_topology_device_index()
  end

  # Identifier-graph entries seed the base index FIRST; ocsf_devices rows fold
  # in afterwards with Map.put_new (first-wins) semantics, so a registered
  # identifier beats a direct-column match for the same key while the direct
  # columns remain the fallback for everything else. Public (@doc false) so the
  # merge precedence stays pinned by unit tests.
  @doc false
  def build_topology_device_index_maps(rows, base_index \\ empty_topology_device_index()) do
    rows
    |> Enum.sort_by(&topology_index_row_rank/1)
    |> Enum.reduce(base_index, fn row, acc ->
      uid = normalize_string(row.uid)
      ip = normalize_string(row.ip)
      mac = normalize_mac(row.mac)

      name_candidates =
        row.name
        |> topology_name_candidates()
        |> Kernel.++(topology_name_candidates(row.hostname))
        |> Enum.uniq()

      if canonical_topology_uid?(uid) do
        acc
        |> put_topology_index_entry(:uid_to_uid, uid)
        |> put_topology_index_entry(:ip_to_uid, ip, uid)
        |> put_topology_index_entry(:mac_to_uid, mac, uid)
        |> put_topology_name_entries(name_candidates, uid)
      else
        acc
      end
    end)
  end

  defp canonical_uid_from_index(index_map, key) when is_map(index_map) do
    case index_map |> Map.get(key) |> normalize_string() do
      uid when is_binary(uid) ->
        if canonical_topology_uid?(uid), do: uid

      _ ->
        nil
    end
  end

  defp topology_index_row_rank(row) do
    uid = normalize_string(row.uid)
    metadata = if is_map(Map.get(row, :metadata)), do: Map.get(row, :metadata), else: %{}
    identity_source = normalize_string(Map.get(metadata, "identity_source"))
    identity_state = normalize_string(Map.get(metadata, "identity_state"))

    provisional_rank =
      if identity_source == "mapper_topology_sighting" do
        1
      else
        0
      end

    uid_rank =
      if is_binary(uid) and String.starts_with?(uid, "sr:") do
        0
      else
        1
      end

    state_rank =
      case identity_state do
        "canonical" -> 0
        "provisional" -> 1
        _ -> 2
      end

    {provisional_rank, uid_rank, state_rank, uid || ""}
  end

  defp empty_topology_device_index do
    %{uid_to_uid: %{}, ip_to_uid: %{}, name_to_uid: %{}, mac_to_uid: %{}}
  end

  defp put_topology_name_entries(index, names, uid) do
    Enum.reduce(names, index, fn name, acc ->
      put_topology_index_entry(acc, :name_to_uid, name, uid)
    end)
  end

  defp put_topology_index_entry(index, _bucket, nil), do: index

  defp put_topology_index_entry(index, bucket, value) do
    put_topology_index_entry(index, bucket, value, value)
  end

  defp put_topology_index_entry(index, _bucket, nil, _uid), do: index

  defp put_topology_index_entry(index, bucket, value, uid) do
    update_in(index, [bucket], fn entries -> Map.put_new(entries, value, uid) end)
  end

  defp topology_name_candidates(name) do
    case normalize_string(name) do
      nil ->
        []

      normalized ->
        short =
          case String.split(normalized, ".", parts: 2) do
            [single] -> single
            [first, _rest] -> first
          end

        [normalized, short]
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
    end
  end

  defp normalize_string(nil), do: nil
  defp normalize_string(""), do: nil

  defp normalize_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" ->
        nil

      trimmed ->
        normalized = String.downcase(trimmed)

        if normalized in ["nil", "null", "undefined"] do
          nil
        else
          normalized
        end
    end
  end

  defp normalize_string(value) do
    value
    |> to_string()
    |> normalize_string()
  end

  defp build_topology_records(updates) do
    updates
    |> Enum.reduce([], fn update, acc ->
      case normalize_topology(update) do
        nil -> acc
        record -> [record | acc]
      end
    end)
    |> Enum.reverse()
    |> prune_unattributed_unifi_links()
    |> infer_reverse_interface_hints()
  end

  @doc false
  def sanitize_topology_records(records) when is_list(records) do
    Enum.map(records, &sanitize_topology_record/1)
  end

  defp sanitize_topology_record(record) when is_map(record) do
    local_candidate = normalize_string(Map.get(record, :local_device_id))
    neighbor_candidate = normalize_string(Map.get(record, :neighbor_device_id))

    metadata =
      record
      |> Map.get(:metadata, %{})
      |> case do
        map when is_map(map) -> map
        _ -> %{}
      end
      |> maybe_put_metadata_value("source_local_uid", local_candidate)
      |> maybe_put_metadata_value("source_target_uid", neighbor_candidate)

    record
    |> Map.put(:metadata, metadata)
    |> Map.put(:local_device_id, sanitize_topology_candidate_uid(local_candidate))
    |> Map.put(:neighbor_device_id, sanitize_topology_candidate_uid(neighbor_candidate))
  end

  defp sanitize_topology_record(record), do: record

  defp sanitize_topology_candidate_uid(uid) when is_binary(uid) do
    if canonical_topology_uid?(uid), do: uid
  end

  defp sanitize_topology_candidate_uid(_), do: nil

  @doc false
  def prune_unattributed_unifi_links(records) when is_list(records) do
    attributed_pairs = attributed_topology_pairs(records)
    Enum.reject(records, &shadowed_unattributed_unifi_record?(&1, attributed_pairs))
  end

  def prune_unattributed_unifi_links(records), do: records

  @doc false
  def infer_reverse_interface_hints(records) when is_list(records) do
    hints = reverse_hint_map(records)
    Enum.map(records, &apply_reverse_hint(&1, hints))
  end

  def infer_reverse_interface_hints(records), do: records

  defp attributed_topology_pairs(records) do
    Enum.reduce(records, MapSet.new(), &put_attributed_topology_pair/2)
  end

  defp put_attributed_topology_pair(record, acc) do
    if attributed_snmp_like_record?(record) do
      case topology_pair_key(record) do
        nil -> acc
        key -> MapSet.put(acc, key)
      end
    else
      acc
    end
  end

  defp shadowed_unattributed_unifi_record?(record, attributed_pairs) do
    unattributed_unifi_record?(record) and
      case topology_pair_key(record) do
        nil -> false
        key -> MapSet.member?(attributed_pairs, key)
      end
  end

  defp reverse_hint_map(records) do
    Enum.reduce(records, %{}, &put_reverse_hint/2)
  end

  defp put_reverse_hint(record, acc) do
    local = normalize_string(Map.get(record, :local_device_id))
    neighbor = normalize_string(Map.get(record, :neighbor_device_id))
    hint = reverse_port_hint(record)

    if is_binary(local) and is_binary(neighbor) and is_binary(hint) do
      key = {neighbor, local}
      rank = reverse_port_hint_rank(record)

      case Map.get(acc, key) do
        nil ->
          Map.put(acc, key, {hint, rank})

        {_existing_hint, existing_rank} when rank >= existing_rank ->
          Map.put(acc, key, {hint, rank})

        _ ->
          acc
      end
    else
      acc
    end
  end

  defp apply_reverse_hint(record, hints) do
    if reverse_hint_needed?(record) do
      reverse_hint_record(record, hints)
    else
      record
    end
  end

  defp reverse_hint_record(record, hints) do
    local = normalize_string(Map.get(record, :local_device_id))
    neighbor = normalize_string(Map.get(record, :neighbor_device_id))

    case Map.get(hints, {local, neighbor}) do
      {hint, _rank} ->
        metadata = record |> Map.get(:metadata, %{}) |> Map.put("local_if_name_inferred", hint)
        %{record | local_if_name: hint, metadata: metadata}

      _ ->
        record
    end
  end

  defp reverse_hint_needed?(record) when is_map(record) do
    if_index = Map.get(record, :local_if_index)
    if_name = normalize_string(Map.get(record, :local_if_name))

    is_binary(normalize_string(Map.get(record, :local_device_id))) and
      is_binary(normalize_string(Map.get(record, :neighbor_device_id))) and
      (not is_integer(if_index) or if_index <= 0) and not is_binary(if_name)
  end

  defp reverse_hint_needed?(_), do: false

  defp reverse_port_hint(record) when is_map(record) do
    decode_hex_port_id(Map.get(record, :neighbor_port_id)) ||
      normalize_string(Map.get(record, :neighbor_port_id)) ||
      normalize_string(Map.get(record, :neighbor_port_descr))
  end

  defp reverse_port_hint_rank(record) when is_map(record) do
    protocol = normalize_topology_protocol(Map.get(record, :protocol))

    protocol_rank =
      case protocol do
        "lldp" -> 3
        "cdp" -> 3
        "snmp-l2" -> 2
        _ -> 1
      end

    confidence_rank =
      case metadata_value(Map.get(record, :metadata), "confidence_tier") do
        "high" -> 3
        "medium" -> 2
        "low" -> 1
        _ -> 0
      end

    protocol_rank * 10 + confidence_rank
  end

  # Some LLDP/CDP identifiers are colon-delimited hex bytes (e.g. "50:6f:72:74:20:31" -> "Port 1").
  defp decode_hex_port_id(value) when is_binary(value) do
    trimmed = String.trim(value)

    with true <- String.contains?(trimmed, ":"),
         parts = String.split(trimmed, ":", trim: true),
         true <- parts != [],
         true <- Enum.all?(parts, &(String.length(&1) == 2)),
         ints = Enum.map(parts, &Integer.parse(&1, 16)),
         true <- Enum.all?(ints, &match?({_, ""}, &1)) do
      ints
      |> Enum.map(fn {i, _} -> i end)
      |> :binary.list_to_bin()
      |> normalize_string()
    else
      _ -> nil
    end
  end

  defp decode_hex_port_id(_), do: nil

  defp attributed_snmp_like_record?(record) when is_map(record) do
    normalize_topology_protocol(record.protocol) != "unifi-api" and
      is_integer(record.local_if_index) and record.local_if_index > 0
  end

  defp attributed_snmp_like_record?(_record), do: false

  defp unattributed_unifi_record?(record) when is_map(record) do
    if_index = record.local_if_index
    if_name = normalize_string(record.local_if_name)

    normalize_topology_protocol(record.protocol) == "unifi-api" and
      (not is_integer(if_index) or if_index <= 0) and not is_binary(if_name)
  end

  defp unattributed_unifi_record?(_record), do: false

  defp topology_pair_key(record) when is_map(record) do
    left = normalize_string(record.local_device_id) || normalize_string(record.local_device_ip)

    right =
      normalize_string(record.neighbor_device_id) || normalize_string(record.neighbor_mgmt_addr)

    if is_binary(left) and is_binary(right) do
      if left <= right, do: {left, right}, else: {right, left}
    end
  end

  defp topology_pair_key(_record), do: nil

  @doc false
  def normalize_interface(update) when is_map(update) do
    metadata =
      update
      |> get_map(["metadata", :metadata])
      |> sanitize_interface_metadata(update)

    if_type =
      get_integer(update, ["if_type", :if_type]) ||
        get_integer(metadata, ["if_type", :if_type])

    if_name = get_string(update, ["if_name", :if_name])
    if_descr = get_string(update, ["if_descr", :if_descr])
    if_index = get_integer(update, ["if_index", :if_index])
    {if_type_name, interface_kind} = classify_if_type(if_type, if_name)
    interface_uid = build_interface_uid(if_index, if_name, if_descr)
    speed_bps = get_integer(update, ["speed_bps", :speed_bps])
    if_speed = get_integer(update, ["if_speed", :if_speed])

    record = %{
      timestamp: parse_timestamp(get_value(update, ["timestamp", :timestamp])),
      device_id: get_string(update, ["device_id", :device_id]),
      interface_uid: interface_uid,
      agent_id: get_string(update, ["agent_id", :agent_id]),
      gateway_id: get_string(update, ["gateway_id", :gateway_id]),
      partition: get_string(update, ["partition", :partition]) || "default",
      device_ip: get_string(update, ["device_ip", :device_ip]),
      if_index: if_index,
      if_name: if_name,
      if_descr: if_descr,
      if_alias: get_string(update, ["if_alias", :if_alias]),
      if_speed: if_speed,
      speed_bps: speed_bps || if_speed,
      if_phys_address: get_string(update, ["if_phys_address", :if_phys_address]),
      ip_addresses: get_list(update, ["ip_addresses", :ip_addresses]),
      if_admin_status: get_integer(update, ["if_admin_status", :if_admin_status]),
      if_oper_status: get_integer(update, ["if_oper_status", :if_oper_status]),
      if_type: if_type,
      if_type_name: if_type_name,
      interface_kind: interface_kind,
      mtu: get_integer(update, ["mtu", :mtu]) || get_integer(metadata, ["mtu", :mtu]),
      duplex:
        get_string(update, ["duplex", :duplex]) || get_string(metadata, ["duplex", :duplex]),
      metadata: metadata,
      available_metrics: get_metrics_list(update, ["available_metrics", :available_metrics]),
      created_at: DateTime.truncate(DateTime.utc_now(), :microsecond)
    }

    if record.device_id && record.interface_uid do
      record
    end
  end

  def normalize_interface(_update), do: nil

  defp sanitize_interface_metadata(metadata, update) when is_map(metadata) do
    source =
      get_string(update, ["source", :source]) ||
        get_string(metadata, ["source", :source])

    case source do
      "unifi-api" -> metadata
      _ -> Map.drop(metadata, @unifi_interface_metadata_keys)
    end
  end

  @doc false
  def normalize_topology(update) when is_map(update) do
    context = topology_normalization_context(update)
    neighbors = topology_neighbor_fields(update, context)
    metadata = build_topology_metadata(context)

    %{
      timestamp: context.timestamp,
      agent_id: get_string(update, ["agent_id", :agent_id]),
      gateway_id: get_string(update, ["gateway_id", :gateway_id]),
      partition: get_string(update, ["partition", :partition]) || "default",
      protocol: context.protocol_value,
      local_device_ip: get_string(update, ["local_device_ip", :local_device_ip]),
      local_device_id:
        get_string(update, ["local_device_id", :local_device_id]) ||
          get_string(context.source_endpoint, ["device_id", :device_id]),
      local_if_index: get_integer(update, ["local_if_index", :local_if_index]),
      local_if_name:
        get_string(update, ["local_if_name", :local_if_name]) ||
          get_string(context.source_endpoint, ["if_name", :if_name]),
      neighbor_device_id: neighbors.neighbor_device_id,
      neighbor_chassis_id: neighbors.neighbor_chassis_id,
      neighbor_port_id: neighbors.neighbor_port_id,
      neighbor_port_descr: neighbors.neighbor_port_descr,
      neighbor_system_name: neighbors.neighbor_system_name,
      neighbor_mgmt_addr: neighbors.neighbor_mgmt_addr,
      metadata: metadata,
      created_at: DateTime.truncate(DateTime.utc_now(), :microsecond)
    }
  end

  def normalize_topology(_update), do: nil

  defp topology_normalization_context(update) do
    metadata = get_map(update, ["metadata", :metadata])
    observation = extract_topology_observation(update, metadata)
    source_endpoint = get_map(observation, ["source_endpoint", :source_endpoint])
    target_endpoint = get_map(observation, ["target_endpoint", :target_endpoint])
    neighbor_identity = get_map(update, ["neighbor_identity", :neighbor_identity])
    {fallback_tier, fallback_score, fallback_reason} = score_topology_confidence(update, metadata)
    protocol_value = topology_protocol_value(update, observation)
    protocol = normalize_topology_protocol(protocol_value)
    source = normalize_topology_source(Map.get(metadata, "source"))
    observation_evidence_class = topology_observation_evidence_class(observation, metadata)

    {explicit_tier, explicit_score, explicit_reason} =
      explicit_topology_confidence(update, observation, metadata)

    tier = explicit_tier || fallback_tier
    score = explicit_score || fallback_score
    reason = explicit_reason || fallback_reason

    evidence_class =
      classify_topology_evidence_class(
        protocol,
        source,
        reason,
        metadata,
        observation_evidence_class
      )

    relation_family =
      classify_topology_relation_family(
        protocol,
        source,
        reason,
        evidence_class,
        metadata,
        observation
      )

    %{
      timestamp: parse_timestamp(get_value(update, ["timestamp", :timestamp])),
      metadata: metadata,
      observation: observation,
      source_endpoint: source_endpoint,
      target_endpoint: target_endpoint,
      neighbor_identity: neighbor_identity,
      tier:
        get_string(observation, ["confidence_tier", :confidence_tier]) ||
          metadata_value(metadata, "observation_confidence_tier") ||
          tier,
      score: score,
      reason: reason,
      protocol_value: protocol_value,
      evidence_class: evidence_class,
      relation_family: relation_family
    }
  end

  defp explicit_topology_confidence(update, observation, metadata) do
    explicit_tier =
      get_string(update, ["confidence_tier", :confidence_tier]) ||
        get_string(observation, ["confidence_tier", :confidence_tier]) ||
        metadata_value(metadata, "observation_confidence_tier") ||
        metadata_value(metadata, "confidence_tier")

    explicit_score =
      get_integer(update, ["confidence_score", :confidence_score]) ||
        get_integer(observation, ["confidence_score", :confidence_score]) ||
        get_integer(metadata, ["observation_confidence_score", :observation_confidence_score]) ||
        get_integer(metadata, ["confidence_score", :confidence_score])

    explicit_reason =
      get_string(update, ["confidence_reason", :confidence_reason]) ||
        get_string(observation, ["confidence_reason", :confidence_reason]) ||
        metadata_value(metadata, "observation_confidence_reason") ||
        metadata_value(metadata, "confidence_reason")

    {explicit_tier, explicit_score, explicit_reason}
  end

  defp topology_protocol_value(update, observation) do
    get_string(update, ["protocol", :protocol]) ||
      get_string(observation, ["source_protocol", :source_protocol]) ||
      "unknown"
  end

  defp topology_observation_evidence_class(observation, metadata) do
    get_string(observation, ["evidence_class", :evidence_class]) ||
      metadata_value(metadata, "observation_evidence_class")
  end

  defp topology_neighbor_fields(update, context) do
    %{
      neighbor_mgmt_addr: topology_neighbor_value(update, context, :neighbor_mgmt_addr),
      neighbor_device_id: topology_neighbor_value(update, context, :neighbor_device_id),
      neighbor_chassis_id: topology_neighbor_value(update, context, :neighbor_chassis_id),
      neighbor_port_id: topology_neighbor_value(update, context, :neighbor_port_id),
      neighbor_port_descr: topology_neighbor_value(update, context, :neighbor_port_descr),
      neighbor_system_name: topology_neighbor_value(update, context, :neighbor_system_name)
    }
  end

  defp topology_neighbor_value(update, context, field) do
    candidate_paths =
      case field do
        :neighbor_mgmt_addr ->
          [
            {update, ["neighbor_mgmt_addr", :neighbor_mgmt_addr]},
            {context.neighbor_identity, ["management_ip", :management_ip, "neighbor_mgmt_addr"]},
            {context.target_endpoint, ["ip", :ip]}
          ]

        :neighbor_device_id ->
          [
            {update, ["neighbor_device_id", :neighbor_device_id]},
            {context.neighbor_identity, ["device_id", :device_id]},
            {context.target_endpoint, ["device_id", :device_id]}
          ]

        :neighbor_chassis_id ->
          [
            {update, ["neighbor_chassis_id", :neighbor_chassis_id]},
            {context.neighbor_identity, ["chassis_id", :chassis_id]},
            {context.target_endpoint, ["mac", :mac]}
          ]

        :neighbor_port_id ->
          [
            {update, ["neighbor_port_id", :neighbor_port_id]},
            {context.neighbor_identity, ["port_id", :port_id]},
            {context.target_endpoint, ["port_id", :port_id]}
          ]

        :neighbor_port_descr ->
          [
            {update, ["neighbor_port_descr", :neighbor_port_descr]},
            {context.neighbor_identity, ["port_descr", :port_descr]}
          ]

        :neighbor_system_name ->
          [
            {update, ["neighbor_system_name", :neighbor_system_name]},
            {context.neighbor_identity, ["system_name", :system_name]}
          ]
      end

    Enum.find_value(candidate_paths, fn {source, keys} -> get_string(source, keys) end)
  end

  defp build_topology_metadata(context) do
    context.metadata
    |> Map.put("confidence_tier", context.tier)
    |> Map.put("confidence_score", context.score)
    |> Map.put("confidence_reason", context.reason)
    |> Map.put("evidence_class", context.evidence_class)
    |> Map.put("relation_family", context.relation_family)
    |> maybe_put_topology_observation_metadata(
      context.observation,
      context.source_endpoint,
      context.target_endpoint
    )
    |> maybe_put_neighbor_identity(context.neighbor_identity)
  end

  defp extract_topology_observation(update, metadata) do
    if topology_v2_contract_consumption_enabled?() do
      explicit =
        update
        |> get_map(["observation", :observation])
        |> normalize_topology_observation_map()

      if map_size(explicit) > 0 do
        explicit
      else
        metadata
        |> metadata_value("observation_v2_json")
        |> decode_topology_observation_json()
      end
    else
      %{}
    end
  end

  defp normalize_topology_observation_map(map) when is_map(map), do: map

  defp decode_topology_observation_json(nil), do: %{}
  defp decode_topology_observation_json(""), do: %{}

  defp decode_topology_observation_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp topology_v2_contract_consumption_enabled? do
    Application.get_env(:serviceradar_core, :topology_v2_contract_consumption_enabled, true) ==
      true
  end

  defp score_topology_confidence(update, metadata) do
    protocol = normalize_topology_protocol(get_string(update, ["protocol", :protocol]))
    source = normalize_topology_source(Map.get(metadata, "source"))
    has_neighbor_id = has_neighbor_identifier?(update)
    has_neighbor_ip = present?(get_string(update, ["neighbor_mgmt_addr", :neighbor_mgmt_addr]))
    has_neighbor_port = has_neighbor_port?(update)
    has_canonical_neighbor_device_id = has_canonical_neighbor_device_id?(update)

    topology_protocol_confidence(protocol) ||
      indirect_topology_confidence(
        source,
        has_neighbor_id,
        has_neighbor_port,
        has_neighbor_ip,
        has_canonical_neighbor_device_id
      )
  end

  defp topology_protocol_confidence("lldp"), do: {"high", 95, "direct_lldp_neighbor"}
  defp topology_protocol_confidence("cdp"), do: {"high", 95, "direct_cdp_neighbor"}
  defp topology_protocol_confidence(_), do: nil

  defp indirect_topology_confidence(
         "unifi-api",
         true,
         true,
         true,
         _has_canonical_neighbor_device_id
       ),
       do: {"medium", 78, "bridge_uplink_with_neighbor_ip"}

  defp indirect_topology_confidence(
         "unifi-api",
         true,
         true,
         false,
         _has_canonical_neighbor_device_id
       ),
       do: {"medium", 72, "bridge_uplink_without_neighbor_ip"}

  defp indirect_topology_confidence(
         _source,
         true,
         true,
         _has_neighbor_ip,
         _has_canonical_neighbor_device_id
       ),
       do: {"medium", 66, "port_neighbor_inference"}

  defp indirect_topology_confidence(source, true, false, true, true)
       when source in ["snmp-arp-fdb", "snmp-arp-only", "unifi-api"] do
    {"medium", 62, "managed_neighbor_identifier"}
  end

  defp indirect_topology_confidence(
         _source,
         true,
         false,
         _has_neighbor_ip,
         _has_canonical_neighbor_device_id
       ),
       do: {"low", 40, "single_identifier_inference"}

  defp indirect_topology_confidence(
         _source,
         false,
         _has_neighbor_port,
         _has_neighbor_ip,
         _has_canonical_neighbor_device_id
       ),
       do: {"low", 20, "insufficient_neighbor_evidence"}

  defp has_canonical_neighbor_device_id?(update) when is_map(update) do
    neighbor_identity = get_map(update, ["neighbor_identity", :neighbor_identity])

    candidate =
      get_string(update, ["neighbor_device_id", :neighbor_device_id]) ||
        get_string(neighbor_identity, ["device_id", :device_id])

    case normalize_string(candidate) do
      value when is_binary(value) -> String.starts_with?(value, "sr:")
      _ -> false
    end
  end

  defp normalize_topology_protocol(nil), do: "unknown"

  defp normalize_topology_protocol(protocol) do
    protocol
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_topology_source(nil), do: ""

  defp normalize_topology_source(source) do
    source
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp classify_topology_evidence_class(protocol, source, reason, metadata, observation_class) do
    preferred_topology_evidence_class(observation_class, metadata) ||
      protocol_topology_evidence_class(protocol, source, reason) ||
      default_topology_evidence_class(protocol) ||
      "inferred-segment"
  end

  defp preferred_topology_evidence_class(observation_class, metadata) do
    [observation_class, metadata_value(metadata, "evidence_class")]
    |> Enum.map(&normalize_topology_evidence_class/1)
    |> Enum.find(&(&1 in @topology_evidence_classes))
  end

  defp protocol_topology_evidence_class("unifi-api", source, _reason) do
    cond do
      String.contains?(source, "wireless-client") -> "endpoint-attachment"
      String.contains?(source, "port-table") -> "inferred-segment"
      true -> "direct-physical"
    end
  end

  defp protocol_topology_evidence_class(protocol, source, "single_identifier_inference")
       when protocol == "snmp-l2" or source == "snmp-arp-fdb", do: "observed-only"

  defp protocol_topology_evidence_class(protocol, source, _reason)
       when protocol == "snmp-l2" or source == "snmp-arp-fdb",
       do: "inferred-segment"

  defp protocol_topology_evidence_class("wireguard-derived", _source, _reason),
    do: "direct-logical"

  defp protocol_topology_evidence_class(protocol, source, _reason)
       when protocol in ["proxmox", "proxmox-api", "vmware", "esxi", "hyperv", "kvm"] or
              source in ["proxmox", "proxmox-api", "vmware", "esxi", "hyperv", "kvm"],
       do: "hosted-virtual"

  defp protocol_topology_evidence_class(_protocol, _source, _reason), do: nil

  defp default_topology_evidence_class(protocol) when protocol in ["lldp", "cdp", "unifi-api"],
    do: "direct-physical"

  defp default_topology_evidence_class("wireguard-derived"), do: "direct-logical"

  defp default_topology_evidence_class(_protocol), do: nil

  defp classify_topology_relation_family(
         protocol,
         source,
         reason,
         evidence_class,
         metadata,
         observation
       ) do
    preferred_topology_relation_family(observation, metadata) ||
      protocol_topology_relation_family(protocol, source, reason, evidence_class) ||
      default_topology_relation_family(protocol, source, reason, evidence_class)
  end

  defp preferred_topology_relation_family(observation, metadata) do
    [
      get_string(observation, ["relation_family", :relation_family]),
      metadata_value(metadata, "relation_family")
    ]
    |> Enum.map(&normalize_topology_relation_family/1)
    |> Enum.find(&(&1 in @topology_relation_families))
  end

  defp protocol_topology_relation_family("unifi-api", source, _reason, _evidence_class) do
    if String.contains?(source, "port-table"), do: "ATTACHED_TO"
  end

  defp protocol_topology_relation_family(_protocol, _source, _reason, "direct-physical"),
    do: "CONNECTS_TO"

  defp protocol_topology_relation_family(_protocol, _source, _reason, "direct-logical"),
    do: "LOGICAL_PEER"

  defp protocol_topology_relation_family(_protocol, _source, _reason, "hosted-virtual"),
    do: "HOSTED_ON"

  defp protocol_topology_relation_family(
         protocol,
         source,
         "single_identifier_inference",
         evidence_class
       )
       when evidence_class in ["observed-only", "inferred-segment"] and
              (protocol == "snmp-l2" or source == "snmp-arp-fdb"),
       do: "OBSERVED_TO"

  defp protocol_topology_relation_family(_protocol, _source, _reason, _evidence_class), do: nil

  defp default_topology_relation_family(_protocol, _source, _reason, "direct-physical"),
    do: "CONNECTS_TO"

  defp default_topology_relation_family(_protocol, _source, _reason, "direct-logical"),
    do: "LOGICAL_PEER"

  defp default_topology_relation_family(_protocol, _source, _reason, "hosted-virtual"),
    do: "HOSTED_ON"

  defp default_topology_relation_family(_protocol, _source, _reason, "observed-only"),
    do: "OBSERVED_TO"

  defp default_topology_relation_family(
         protocol,
         source,
         "single_identifier_inference",
         "inferred-segment"
       )
       when protocol == "snmp-l2" or source == "snmp-arp-fdb", do: "OBSERVED_TO"

  defp default_topology_relation_family(
         _protocol,
         _source,
         "single_identifier_inference",
         "inferred-segment"
       ), do: nil

  defp default_topology_relation_family(_protocol, _source, _reason, "inferred-segment"),
    do: "INFERRED_TO"

  defp default_topology_relation_family(_protocol, _source, _reason, _), do: "OBSERVED_TO"

  defp normalize_topology_evidence_class(nil), do: nil

  defp normalize_topology_evidence_class(value) do
    case normalize_string(value) do
      "direct" -> "direct-physical"
      "inferred" -> "inferred-segment"
      "endpoint-attachment" -> "endpoint-attachment"
      other -> other
    end
  end

  defp normalize_topology_relation_family(nil), do: nil

  defp normalize_topology_relation_family(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      family -> String.upcase(family)
    end
  end

  defp maybe_put_topology_observation_metadata(
         metadata,
         observation,
         source_endpoint,
         target_endpoint
       )
       when is_map(metadata) do
    metadata
    |> maybe_put_metadata_value(
      "observation_contract_version",
      get_string(observation, ["contract_version", :contract_version])
    )
    |> maybe_put_metadata_value(
      "observation_source_adapter",
      get_string(observation, ["source_adapter", :source_adapter])
    )
    |> maybe_put_metadata_value(
      "source_local_uid",
      get_string(source_endpoint, ["uid", :uid])
    )
    |> maybe_put_metadata_value(
      "source_target_uid",
      get_string(target_endpoint, ["uid", :uid])
    )
  end

  defp maybe_put_metadata_value(metadata, _key, value) when value in [nil, ""], do: metadata
  defp maybe_put_metadata_value(metadata, key, value), do: Map.put(metadata, key, value)

  defp ensure_map(map) when is_map(map), do: map
  defp ensure_map(_), do: %{}

  defp maybe_put_neighbor_identity(metadata, map) when is_map(map) and map_size(map) > 0 do
    Map.put(metadata, "neighbor_identity", map)
  end

  defp maybe_put_neighbor_identity(metadata, _value), do: metadata

  defp has_neighbor_identifier?(update) do
    present?(get_string(update, ["neighbor_device_id", :neighbor_device_id])) ||
      present?(get_string(update, ["neighbor_chassis_id", :neighbor_chassis_id])) ||
      present?(get_string(update, ["neighbor_system_name", :neighbor_system_name])) ||
      present?(get_string(update, ["neighbor_mgmt_addr", :neighbor_mgmt_addr]))
  end

  defp has_neighbor_port?(update) do
    present?(get_string(update, ["neighbor_port_id", :neighbor_port_id])) ||
      present?(get_string(update, ["neighbor_port_descr", :neighbor_port_descr]))
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp build_interface_uid(nil, if_name, if_descr) do
    cond do
      is_binary(if_name) and String.trim(if_name) != "" -> "ifname:#{String.trim(if_name)}"
      is_binary(if_descr) and String.trim(if_descr) != "" -> "ifdescr:#{String.trim(if_descr)}"
      true -> nil
    end
  end

  defp build_interface_uid(if_index, _if_name, _if_descr) when is_integer(if_index) do
    "ifindex:#{if_index}"
  end

  defp classify_if_type(nil, if_name) do
    case classify_if_name(if_name) do
      nil -> {nil, nil}
      kind -> {nil, kind}
    end
  end

  defp classify_if_type(if_type, if_name) when is_integer(if_type) do
    case interface_type_map(if_type) do
      {name, kind} -> {name, kind}
      nil -> {nil, classify_if_name(if_name)}
    end
  end

  @interface_type_map %{
    1 => {"other", "unknown"},
    6 => {"ethernetCsmacd", "physical"},
    24 => {"softwareLoopback", "loopback"},
    53 => {"propVirtual", "virtual"},
    62 => {"fastEthernet", "physical"},
    69 => {"fastEthernetFx", "physical"},
    71 => {"ieee80211", "wireless"},
    117 => {"gigabitEthernet", "physical"},
    131 => {"tunnel", "tunnel"},
    135 => {"l2vlan", "virtual"},
    136 => {"l3ipvlan", "virtual"},
    161 => {"ieee8023adLag", "aggregate"},
    166 => {"mplsTunnel", "tunnel"},
    209 => {"bridge", "bridge"}
  }

  defp interface_type_map(if_type) do
    Map.get(@interface_type_map, if_type)
  end

  defp classify_if_name(nil), do: nil

  @interface_name_prefixes [
    {"lo", "loopback"},
    {"br", "bridge"},
    {"vlan", "virtual"},
    {"tun", "tunnel"},
    {"wg", "tunnel"},
    {"docker", "virtual"},
    {"veth", "virtual"}
  ]

  defp classify_if_name(if_name) when is_binary(if_name) do
    name = String.downcase(String.trim(if_name))
    interface_kind_for_name(name)
  end

  defp interface_kind_for_name(""), do: nil

  defp interface_kind_for_name(name) do
    Enum.find_value(@interface_name_prefixes, fn {prefix, kind} ->
      if String.starts_with?(name, prefix), do: kind
    end)
  end

  defp insert_bulk([], _resource, _actor, _label), do: {:ok, %{accepted: [], rejected: []}}

  defp insert_bulk(records, resource, actor, label) do
    {prepared_records, opts} = prepare_bulk_records(records, resource, actor)

    prepared_records
    |> Ash.bulk_create(resource, :create, opts)
    |> handle_bulk_result(prepared_records, label)
  end

  defp prepare_bulk_records(records, Interface, actor) do
    filtered = Enum.reject(records, &missing_interface_identity?/1)
    log_filtered_interfaces(records, filtered)

    deduped = dedupe_by_interface(filtered)

    log_deduped_interfaces(filtered, deduped)

    {deduped,
     [
       actor: actor,
       return_errors?: true,
       stop_on_error?: false,
       upsert?: true,
       upsert_identity: :unique_interface,
       # Enumerated, and deliberately NOT shared with the sync writer.
       #
       # An empty list becomes `DO UPDATE SET <key> = EXCLUDED.<key>` and
       # freezes every column at its first-observed value. A writer must list
       # ONLY the fields it actually sets. `inventory/sync/` does not set
       # if_index, if_speed, speed_bps, if_admin_status, if_oper_status,
       # if_type, mtu, duplex or available_metrics; if it shared this list it
       # would write NULL over the mapper's operational data on every sync run.
       #
       # :created_at is excluded on purpose -- first observation, not latest.
       upsert_fields: [
         :timestamp,
         :agent_id,
         :gateway_id,
         :partition,
         :device_ip,
         :if_index,
         :if_name,
         :if_descr,
         :if_alias,
         :if_speed,
         :speed_bps,
         :if_phys_address,
         :ip_addresses,
         :if_admin_status,
         :if_oper_status,
         :if_type,
         :if_type_name,
         :interface_kind,
         :classifications,
         :classification_meta,
         :classification_source,
         :mtu,
         :duplex,
         :metadata,
         :available_metrics
       ]
     ]}
  end

  defp prepare_bulk_records(records, TopologyLink, actor) do
    # The mapper re-inserts the entire topology every ~5 minutes. Without an upsert
    # this appends duplicate rows forever (the 1.5M-row bloat). Normalize the
    # logical-key columns to their non-nil DB defaults, collapse in-batch dups
    # (last-wins), and upsert against the :logical_key identity.
    deduped =
      records
      |> Enum.map(&normalize_topology_link_key/1)
      |> Enum.reverse()
      |> Enum.uniq_by(&topology_link_identity_key/1)
      |> Enum.reverse()

    {deduped,
     [
       actor: actor,
       return_errors?: true,
       stop_on_error?: false,
       upsert?: true,
       upsert_identity: :logical_key,
       upsert_fields: [
         :timestamp,
         :created_at,
         :metadata,
         :neighbor_system_name,
         :neighbor_mgmt_addr,
         :gateway_id,
         :agent_id
       ]
     ]}
  end

  defp prepare_bulk_records(records, _resource, actor) do
    {records,
     [
       actor: actor,
       return_errors?: true,
       stop_on_error?: false
     ]}
  end

  # Coalesce the logical-key columns to the resource's NOT NULL defaults so the
  # in-batch dedup key and the upsert ON CONFLICT inference both line up with the
  # plain-column unique index.
  defp normalize_topology_link_key(record) when is_map(record) do
    record
    |> Map.put(
      :local_device_id,
      blank_to_empty(get_record_value(record, :local_device_id, "local_device_id"))
    )
    |> Map.put(
      :neighbor_device_id,
      blank_to_empty(get_record_value(record, :neighbor_device_id, "neighbor_device_id"))
    )
    |> Map.put(
      :local_if_index,
      nil_to_zero(get_record_value(record, :local_if_index, "local_if_index"))
    )
    |> Map.put(
      :neighbor_port_id,
      blank_to_empty(get_record_value(record, :neighbor_port_id, "neighbor_port_id"))
    )
    |> Map.put(:protocol, blank_to_empty(get_record_value(record, :protocol, "protocol")))
    |> Map.put(
      :neighbor_chassis_id,
      blank_to_empty(get_record_value(record, :neighbor_chassis_id, "neighbor_chassis_id"))
    )
  end

  defp topology_link_identity_key(record) when is_map(record) do
    {
      Map.get(record, :local_device_id),
      Map.get(record, :neighbor_device_id),
      Map.get(record, :local_if_index),
      Map.get(record, :neighbor_port_id),
      Map.get(record, :protocol),
      Map.get(record, :neighbor_chassis_id)
    }
  end

  defp blank_to_empty(nil), do: ""
  defp blank_to_empty(value) when is_binary(value), do: value
  defp blank_to_empty(value), do: to_string(value)

  defp nil_to_zero(nil), do: 0
  defp nil_to_zero(value) when is_integer(value), do: value

  # Drop the raw topology records whose prepared (normalized) counterparts were
  # rejected by the bulk insert, keyed by the logical-key identity. Records for
  # unattributable errors ({nil, error} pairs) cannot be filtered and stay in
  # the surviving set, which is safe because the AGE MERGEs are idempotent.
  defp reject_rejected_topology_records(records, []), do: records

  defp reject_rejected_topology_records(records, rejected) do
    rejected_keys =
      rejected
      |> Enum.reject(fn {record, _error} -> is_nil(record) end)
      |> MapSet.new(fn {record, _error} -> topology_link_identity_key(record) end)

    Enum.reject(records, fn record ->
      key =
        record
        |> normalize_topology_link_key()
        |> topology_link_identity_key()

      MapSet.member?(rejected_keys, key)
    end)
  end

  # Public for tests; see handle_bulk_result/3.
  @doc false
  def emit_topology_ingest_rejections([]), do: :ok

  def emit_topology_ingest_rejections(rejected) when is_list(rejected) do
    rejected
    |> Enum.group_by(&topology_rejection_group/1)
    |> Enum.each(fn {{reason, protocol, agent_id}, group} ->
      :telemetry.execute(
        [:serviceradar, :mapper_topology, :ingest_rejected],
        %{count: length(group)},
        %{reason: reason, protocol: protocol, agent_id: agent_id}
      )
    end)
  end

  defp topology_rejection_group({record, error}) do
    {
      topology_rejection_reason(error),
      topology_rejection_field(record, :protocol, "protocol"),
      topology_rejection_field(record, :agent_id, "agent_id")
    }
  end

  defp topology_rejection_field(record, atom_key, string_key) when is_map(record) do
    case get_record_value(record, atom_key, string_key) do
      value when is_binary(value) and value != "" -> value
      _ -> "unknown"
    end
  end

  defp topology_rejection_field(_record, _atom_key, _string_key), do: "unknown"

  defp topology_rejection_reason(%Ash.Error.Changes.Required{field: field}),
    do: "required:#{field}"

  defp topology_rejection_reason(%InvalidAttribute{field: field}),
    do: "invalid_attribute:#{field}"

  defp topology_rejection_reason(%{errors: [error | _]}), do: topology_rejection_reason(error)

  defp topology_rejection_reason(%struct{}) do
    struct |> Module.split() |> List.last() |> Macro.underscore()
  end

  defp topology_rejection_reason(_error), do: "unknown"

  @bulk_rejection_log_samples 3

  # Per-record failure isolation: a partial bulk-create success MUST NOT abort
  # the pipeline. Return the accepted records plus {record, error} rejection
  # pairs so callers keep the surviving evidence flowing (e.g. into the AGE
  # graph) instead of dropping the whole payload; only a total failure returns
  # {:error, errors}. Public for tests: partial failures cannot be induced
  # through the JSON ingest path once validation accepts real payload shapes.
  @doc false
  def handle_bulk_result(%Ash.BulkResult{status: :success}, prepared_records, _label) do
    {:ok, %{accepted: prepared_records, rejected: []}}
  end

  def handle_bulk_result(
        %Ash.BulkResult{status: :partial_success, errors: errors},
        prepared_records,
        label
      ) do
    if timescaledb_pkey_violations?(errors) do
      Logger.debug(
        "Mapper #{label}: skipped #{length(List.wrap(errors))} duplicate(s) (TimescaleDB constraint)"
      )

      {:ok, %{accepted: prepared_records, rejected: []}}
    else
      {accepted, rejected} = split_bulk_rejections(prepared_records, errors)

      Logger.error(
        "Mapper #{label} ingestion rejected #{length(rejected)} of " <>
          "#{length(prepared_records)} record(s); continuing with #{length(accepted)}; " <>
          "sample errors: #{inspect(sample_bulk_error_messages(rejected))}"
      )

      {:ok, %{accepted: accepted, rejected: rejected}}
    end
  end

  def handle_bulk_result(%Ash.BulkResult{status: :error, errors: errors}, prepared_records, label) do
    # Check if all errors are TimescaleDB chunk-prefixed constraint violations
    # These occur because TimescaleDB prefixes constraint names with chunk IDs
    # (e.g., "1_2_discovered_interfaces_pkey" instead of "discovered_interfaces_pkey")
    if timescaledb_pkey_violations?(errors) do
      Logger.debug(
        "Mapper #{label}: skipped #{length(List.wrap(errors))} duplicate(s) (TimescaleDB constraint)"
      )

      {:ok, %{accepted: prepared_records, rejected: []}}
    else
      Logger.warning("Mapper #{label} ingestion failed: #{inspect(errors)}")
      {:error, errors}
    end
  end

  # Ash tags each per-record bulk error with the record's index as the head of
  # the error path. Partition the prepared batch into accepted records and
  # {record, error} rejection pairs. Errors that cannot be attributed to an
  # index become {nil, error} pairs and leave the batch unfiltered for those
  # records, which is safe because the downstream AGE MERGEs are idempotent.
  defp split_bulk_rejections(prepared_records, errors) do
    {indexed, unattributed} =
      errors
      |> List.wrap()
      |> Enum.split_with(&indexed_bulk_error?/1)

    errors_by_index = Map.new(indexed, fn %{path: [index | _]} = error -> {index, error} end)

    {accepted, rejected} =
      prepared_records
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {record, index}, {accepted, rejected} ->
        case errors_by_index do
          %{^index => error} -> {accepted, [{record, error} | rejected]}
          _ -> {[record | accepted], rejected}
        end
      end)

    unattributed_pairs = Enum.map(unattributed, fn error -> {nil, error} end)

    {Enum.reverse(accepted), Enum.reverse(rejected, unattributed_pairs)}
  end

  defp indexed_bulk_error?(%{path: [index | _]}) when is_integer(index), do: true
  defp indexed_bulk_error?(_error), do: false

  defp sample_bulk_error_messages(rejected) do
    rejected
    |> Enum.take(@bulk_rejection_log_samples)
    |> Enum.map(fn {_record, error} -> bulk_error_message(error) end)
  end

  defp bulk_error_message(error) when is_exception(error), do: Exception.message(error)
  defp bulk_error_message(error), do: inspect(error)

  defp missing_interface_identity?(record) do
    is_nil(get_record_value(record, :device_id, "device_id")) or
      is_nil(get_record_value(record, :interface_uid, "interface_uid"))
  end

  defp log_filtered_interfaces(records, filtered) do
    if length(filtered) != length(records) do
      Logger.debug(
        "Mapper interfaces batch dropped #{length(records) - length(filtered)} record(s) missing identity fields"
      )
    end
  end

  defp log_deduped_interfaces(filtered, deduped) do
    if length(deduped) != length(filtered) do
      Logger.debug(
        "Mapper interfaces batch contained duplicates, deduped #{length(filtered) - length(deduped)} record(s)"
      )
    end
  end

  # Check if errors are all TimescaleDB chunk-prefixed primary key constraint violations.
  # TimescaleDB creates chunk-specific constraint names like "1_2_discovered_interfaces_pkey"
  # which Ash/Ecto can't match to the base constraint "discovered_interfaces_pkey".
  defp timescaledb_pkey_violations?(errors) when is_list(errors) do
    Enum.all?(errors, &timescaledb_pkey_violation?/1)
  end

  defp timescaledb_pkey_violations?(_), do: false

  defp timescaledb_pkey_violation?(%Unknown{errors: nested_errors}) do
    Enum.all?(nested_errors, &timescaledb_pkey_violation?/1)
  end

  defp timescaledb_pkey_violation?(%Ash.Error.Unknown.UnknownError{error: error_msg})
       when is_binary(error_msg) do
    # Match patterns like "1_2_discovered_interfaces_pkey" or "1_3_topology_links_pkey"
    String.contains?(error_msg, "unique_constraint") and
      Regex.match?(~r/\d+_\d+_\w+_pkey/, error_msg)
  end

  defp timescaledb_pkey_violation?(_), do: false

  defp get_record_value(record, atom_key, string_key) when is_map(record) do
    Map.get(record, atom_key) || Map.get(record, string_key)
  end

  defp dedupe_by_interface(records) do
    records
    |> Enum.group_by(fn record ->
      {
        get_record_value(record, :device_id, "device_id"),
        get_record_value(record, :interface_uid, "interface_uid")
      }
    end)
    |> Enum.map(fn {_key, grouped} -> newest_record(grouped) end)
  end

  defp newest_record([record]), do: record

  defp newest_record(records) do
    Enum.max_by(records, &record_timestamp/1, fn -> List.first(records) end)
  end

  defp record_timestamp(record) do
    case get_record_value(record, :timestamp, "timestamp") do
      %DateTime{} = timestamp -> timestamp
      _ -> DateTime.from_unix!(0)
    end
  end

  defp record_job_runs(updates, opts) do
    job_counts = extract_job_counts(updates)

    case map_size(job_counts) do
      0 ->
        :ok

      _ ->
        run_context = build_run_context(opts)

        Enum.each(job_counts, fn {job_id, count} ->
          record_job_run(
            job_id,
            run_context.now,
            run_context.status,
            interface_count(count, run_context.include_counts),
            run_context.error,
            run_context.actor
          )
        end)
    end
  rescue
    error ->
      Logger.warning("Mapper run status update failed: #{inspect(error)}")
      :ok
  end

  defp record_job_run(job_id, now, status, interface_count, error, actor) do
    case Ash.get(MapperJob, job_id, actor: actor) do
      {:ok, job} ->
        attrs = %{
          last_run_at: now,
          last_run_status: status
        }

        attrs =
          case interface_count do
            :skip -> attrs
            value -> Map.put(attrs, :last_run_interface_count, value)
          end

        attrs =
          if status == :error do
            Map.put(attrs, :last_run_error, format_run_error(error))
          else
            Map.put(attrs, :last_run_error, nil)
          end

        job
        |> Ash.Changeset.for_update(:record_run, attrs)
        |> Ash.update(actor: actor)
        |> case do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to record mapper run: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.debug("Mapper job not found for run update: #{inspect(reason)}")
    end
  end

  defp format_run_error(nil), do: nil
  defp format_run_error(value) when is_binary(value), do: value
  defp format_run_error(value), do: inspect(value)

  defp build_run_context(opts) do
    %{
      now: DateTime.truncate(DateTime.utc_now(), :microsecond),
      actor: SystemActor.system(:mapper_job_status),
      status: Keyword.get(opts, :status, :success),
      error: Keyword.get(opts, :error),
      include_counts: Keyword.get(opts, :include_interface_counts, false)
    }
  end

  defp interface_count(count, true), do: count
  defp interface_count(_count, false), do: :skip

  defp extract_job_counts(updates) do
    Enum.reduce(updates, %{}, fn update, acc ->
      meta = get_map(update, ["metadata", :metadata])

      case get_string(meta, ["mapper_job_id", :mapper_job_id]) do
        nil -> acc
        job_id -> Map.update(acc, job_id, 1, &(&1 + 1))
      end
    end)
  end

  defp get_value(update, keys) do
    Enum.find_value(keys, fn key -> Map.get(update, key) end)
  end

  defp get_string(update, keys) do
    case get_value(update, keys) do
      value when is_binary(value) ->
        normalize_optional_string(value)

      value when is_atom(value) and value in [nil, :null, :undefined, :unknown, :none] ->
        nil

      value when is_atom(value) and not is_nil(value) ->
        normalize_optional_string(Atom.to_string(value))

      _ ->
        nil
    end
  end

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" or String.downcase(trimmed) in ["nil", "null", "undefined"] do
      nil
    else
      trimmed
    end
  end

  defp get_integer(update, keys) do
    case get_value(update, keys) do
      value when is_integer(value) ->
        value

      value when is_float(value) ->
        trunc(value)

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, _} -> parsed
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp get_list(update, keys) do
    case get_value(update, keys) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp get_map(update, keys) do
    case get_value(update, keys) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  # Get available_metrics list, ensuring it's nil if empty/invalid
  defp get_metrics_list(update, keys) do
    case get_value(update, keys) do
      [_ | _] = value ->
        # Normalize each metric to ensure consistent key format. Drop entries
        # that cannot be normalized so we never persist nil array elements.
        case value |> Enum.map(&normalize_metric/1) |> Enum.reject(&is_nil/1) do
          [] -> nil
          normalized -> normalized
        end

      _ ->
        nil
    end
  end

  # Metric entries usually arrive as decoded maps, but some discovery sources
  # emit each entry as a JSON-encoded string. Decode those so the persisted
  # `available_metrics` column holds proper jsonb objects (preserving
  # supports_64bit/oid_64bit) rather than an array of JSON strings.
  defp normalize_metric(metric) when is_binary(metric) do
    case Jason.decode(metric) do
      {:ok, decoded} when is_map(decoded) -> normalize_metric(decoded)
      _ -> nil
    end
  end

  defp normalize_metric(metric) when is_map(metric) do
    %{
      "name" => get_string(metric, ["name", :name, "Name"]),
      "oid" => get_string(metric, ["oid", :oid, "OID"]),
      "data_type" => get_string(metric, ["data_type", :data_type, "DataType"]),
      "supports_64bit" =>
        get_boolean(metric, ["supports_64bit", :supports_64bit, "Supports64Bit"]),
      "oid_64bit" => get_string(metric, ["oid_64bit", :oid_64bit, "OID64Bit"]),
      "category" => get_string(metric, ["category", :category, "Category"]),
      "unit" => get_string(metric, ["unit", :unit, "Unit"])
    }
  end

  defp normalize_metric(_), do: nil

  defp get_boolean(update, keys) do
    case get_value(update, keys) do
      true -> true
      false -> false
      "true" -> true
      "false" -> false
      _ -> false
    end
  end

  defp parse_timestamp(nil), do: DateTime.truncate(DateTime.utc_now(), :microsecond)

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :microsecond)
      _ -> DateTime.truncate(DateTime.utc_now(), :microsecond)
    end
  end

  defp parse_timestamp(%DateTime{} = timestamp) do
    DateTime.truncate(timestamp, :microsecond)
  end
end
