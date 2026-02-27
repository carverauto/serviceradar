defmodule ServiceRadar.NetworkDiscovery.MapperResultsIngestor do
  @moduledoc """
  Ingests mapper interface and topology results into CNPG and projects topology into AGE.
  """

  # credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
  # credo:disable-for-this-file Credo.Check.Refactor.Nesting

  require Logger
  require Ash.Query

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.AliasEvents
  alias ServiceRadar.Identity.DeviceAliasState

  alias ServiceRadar.Inventory.{
    Device,
    IdentityReconciler,
    Interface,
    InterfaceClassifier,
    InterfaceSettings
  }

  alias ServiceRadar.NetworkDiscovery.{MapperJob, TopologyGraph, TopologyLink}
  alias ServiceRadar.Repo
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
         records <- build_interface_records(updates),
         resolved_records <- resolve_device_ids(records, actor),
         :ok <- process_mapper_alias_updates(resolved_records, actor),
         classified_records <- InterfaceClassifier.classify_interfaces(resolved_records, actor) do
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
          :ok ->
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

  @spec ingest_topology(binary() | nil, map()) :: :ok | {:error, term()}
  def ingest_topology(message, _status) do
    actor = SystemActor.system(:mapper_topology_ingestor)

    with {:ok, updates} <- decode_payload(message),
         records <- build_topology_records(updates),
         resolved_records <- resolve_topology_device_ids(records),
         :ok <- promote_topology_sightings(resolved_records, actor),
         final_records <- resolve_topology_device_ids(resolved_records),
         records_with_wireguard <- add_deterministic_wireguard_links(final_records) do
      record_job_runs(updates, status: :success)

      if records_with_wireguard == [] do
        Logger.debug("No topology links to ingest after device ID resolution")
        :ok
      else
        case insert_bulk(records_with_wireguard, TopologyLink, actor, "topology") do
          :ok ->
            TopologyGraph.upsert_links(records_with_wireguard)
            maybe_bootstrap_topology_interface_metrics(records_with_wireguard, actor)
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
  defp parse_optional_bool(v) when is_boolean(v), do: v

  defp parse_optional_bool(v) when is_binary(v) do
    case String.downcase(String.trim(v)) do
      "true" -> true
      "1" -> true
      "yes" -> true
      "on" -> true
      "false" -> false
      "0" -> false
      "no" -> false
      "off" -> false
      _ -> nil
    end
  end

  defp parse_optional_bool(_), do: nil

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
      |> Enum.map(&to_string/1)
      |> MapSet.new()

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

  defp maybe_bootstrap_topology_interface_metrics(_records, _actor), do: :ok

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
    records
    |> Enum.filter(&topology_sighting_candidate?/1)
    |> Enum.each(&promote_topology_sighting(&1, actor))

    :ok
  rescue
    e ->
      Logger.warning("Topology sighting promotion failed: #{inspect(e)}")
      :ok
  end

  defp topology_sighting_candidate?(record) when is_map(record) do
    not present?(record.neighbor_device_id) and
      valid_alias_ip?(normalize_alias_ip(record.neighbor_mgmt_addr)) and
      present?(record.local_device_id) and
      not suppress_topology_sighting_candidate?(record)
  end

  defp topology_sighting_candidate?(_), do: false

  @doc false
  def suppress_topology_sighting_candidate?(record) when is_map(record) do
    protocol = normalize_topology_protocol(record.protocol)
    confidence_reason = metadata_value(record.metadata, "confidence_reason")
    source = metadata_value(record.metadata, "source")
    candidate_ip = normalize_alias_ip(record.neighbor_mgmt_addr)
    neighbor_name_present? = present?(normalize_string(record.neighbor_system_name))

    protocol == "snmp-l2" and
      confidence_reason == "single_identifier_inference" and
      source == "snmp-arp-fdb" and
      routable_public_ipv4?(candidate_ip) and
      not neighbor_name_present?
  end

  def suppress_topology_sighting_candidate?(_record), do: false

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
    ids = %{
      agent_id: nil,
      armis_id: nil,
      integration_id: nil,
      netbox_id: nil,
      mac: nil,
      ip: candidate_ip,
      partition: partition
    }

    uid = IdentityReconciler.generate_deterministic_device_id(ids)

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

      {:error, %Ash.Error.Invalid{errors: errors}} ->
        recover_existing_device_uid(uid, candidate_ip, errors, actor)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp touch_topology_candidate(uid, candidate_ip, metadata, actor) do
    with {:ok, %Device{} = device} <- Device.get_by_uid(uid, true, actor: actor) do
      merged_metadata = Map.merge(Map.new(device.metadata || %{}), metadata)
      merged_sources = merge_topology_discovery_sources(device.discovery_sources)
      attrs = %{metadata: merged_metadata, discovery_sources: merged_sources}
      attrs = if present?(device.ip), do: attrs, else: Map.put(attrs, :ip, candidate_ip)

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
    ts =
      case record.timestamp do
        %DateTime{} = dt -> dt
        _ -> DateTime.utc_now()
      end
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
    Enum.reduce(updates, [], fn update, acc ->
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

      case AliasEvents.process_and_persist(updates,
             actor: actor,
             confirm_threshold: confirm_threshold
           ) do
        {:ok, _events} ->
          :ok

        other ->
          Logger.warning("Mapper alias state processing failed: #{inspect(other)}")
          :ok
      end
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

    metadata = build_alias_metadata(alias_ips, latest_ts, role, candidate_ips)

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

  defp alias_ips_for_role("router", current_ip, stable_interface_ips) do
    [current_ip | stable_interface_ips]
    |> Enum.filter(&valid_alias_ip?/1)
    |> Enum.uniq()
  end

  defp alias_ips_for_role(_role, current_ip, _stable_interface_ips) do
    if valid_alias_ip?(current_ip), do: [current_ip], else: []
  end

  defp candidate_ips_for_role(
         "router",
         _stable_interface_ips,
         _mismatched_device_ips,
         _alias_ips
       ),
       do: []

  defp candidate_ips_for_role(_role, stable_interface_ips, mismatched_device_ips, alias_ips) do
    (stable_interface_ips ++ mismatched_device_ips)
    |> Enum.reject(&(&1 in alias_ips))
    |> Enum.uniq()
  end

  defp build_alias_metadata([], _timestamp, _role, _candidate_ips), do: %{}

  defp build_alias_metadata(alias_ips, timestamp, role, candidate_ips) do
    ts_string =
      timestamp
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    Enum.reduce(alias_ips, %{}, fn ip, acc ->
      Map.put(acc, "ip_alias:#{ip}", ts_string)
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
    device_ip_count =
      grouped
      |> Enum.map(&normalize_alias_ip(&1.device_ip))
      |> Enum.filter(&valid_alias_ip?/1)
      |> Enum.uniq()
      |> length()

    stable_records =
      grouped
      |> Enum.filter(&(normalize_alias_ip(&1.device_ip) == current_ip))

    stable_l3_alias_count =
      stable_records
      |> Enum.flat_map(&List.wrap(&1.ip_addresses))
      |> Enum.map(&normalize_alias_ip/1)
      |> Enum.filter(&valid_alias_ip?/1)
      |> Enum.reject(&(&1 == current_ip))
      |> Enum.uniq()
      |> length()

    bridge_like_count =
      Enum.count(grouped, fn r ->
        kind = String.downcase(to_string(r.interface_kind || ""))
        kind in ["bridge", "virtual", "tunnel"]
      end)

    physical_like_count =
      Enum.count(grouped, fn r ->
        kind = String.downcase(to_string(r.interface_kind || ""))
        kind in ["physical", "aggregate"]
      end)

    wireless_like_count =
      Enum.count(grouped, fn r ->
        if_name = String.downcase(to_string(r.if_name || ""))
        String.starts_with?(if_name, "wl") or String.contains?(if_name, "wlan")
      end)

    router_score =
      0
      |> add_score(stable_l3_alias_count >= 3, 55)
      |> add_score(device_ip_count == 1, 20)
      |> add_score(physical_like_count > 0, 10)

    ap_bridge_score =
      0
      |> add_score(device_ip_count >= 3, 45)
      |> add_score(wireless_like_count > 0, 30)
      |> add_score(bridge_like_count > 0, 20)
      |> add_score(stable_l3_alias_count <= 1, 10)

    switch_l2_score =
      0
      |> add_score(stable_l3_alias_count == 0, 35)
      |> add_score(device_ip_count == 1, 20)
      |> add_score(physical_like_count >= 8, 20)

    host_score =
      0
      |> add_score(stable_l3_alias_count <= 1, 20)
      |> add_score(device_ip_count == 1, 15)
      |> add_score(bridge_like_count == 0, 10)

    candidates = [
      {"router", router_score},
      {"ap_bridge", ap_bridge_score},
      {"switch_l2", switch_l2_score},
      {"host", host_score}
    ]

    {best_role, best_score} = Enum.max_by(candidates, fn {_role, score} -> score end)

    if best_score < 50 do
      %{role: "unknown", confidence: best_score, source: "mapper_role_heuristic_v1"}
    else
      %{role: best_role, confidence: best_score, source: "mapper_role_heuristic_v1"}
    end
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

        merged = Map.merge(metadata, role_metadata)

        if merged != metadata do
          device
          |> Ash.Changeset.for_update(:update, %{metadata: merged})
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

  defp ensure_candidate_device(ip, partition, source_device_id, actor) do
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
    ids = %{
      agent_id: nil,
      armis_id: nil,
      integration_id: nil,
      netbox_id: nil,
      mac: nil,
      ip: ip,
      partition: partition
    }

    uid = IdentityReconciler.generate_deterministic_device_id(ids)

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

      {:error, %Ash.Error.Invalid{errors: errors}} ->
        recover_existing_device_uid(uid, ip, errors, actor)

      {:error, reason} ->
        Logger.warning("Failed to create mapper candidate device for #{ip}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp valid_alias_ip?(nil), do: false
  defp valid_alias_ip?(""), do: false
  defp valid_alias_ip?("0.0.0.0"), do: false
  defp valid_alias_ip?("::"), do: false
  defp valid_alias_ip?("::1"), do: false

  defp valid_alias_ip?(ip) when is_binary(ip) do
    case :inet.parse_address(to_charlist(ip)) do
      {:ok, {127, _, _, _}} -> false
      {:ok, _} -> true
      _ -> false
    end
  end

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
    primary_mac = derive_primary_identity_mac(device_ip, records)

    # Derive a stable mapper identity seed:
    # - prefer a deterministic primary MAC from physical/aggregate interfaces
    # - fallback to IP-only when no trustworthy MAC exists
    ids = %{
      agent_id: nil,
      armis_id: nil,
      integration_id: nil,
      netbox_id: nil,
      mac: primary_mac,
      ip: device_ip,
      partition: partition
    }

    # Generate deterministic sr: UUID via DIRE
    device_uid = IdentityReconciler.generate_deterministic_device_id(ids)

    # If this IP appears as an interface address on another device, set management_device_id
    management_device_id = find_management_device_uid(device_ip, records, ip_to_uid)

    # Create the device record
    attrs =
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
      }
      |> maybe_put(:management_device_id, management_device_id)

    case Device
         |> Ash.Changeset.for_create(:create, attrs)
         |> Ash.create(actor: actor) do
      {:ok, _device} ->
        Logger.info("Mapper created device #{device_uid} for IP #{device_ip}")

        if management_device_id,
          do: TopologyGraph.upsert_managed_by(device_uid, management_device_id)

        {:ok, device_uid}

      {:error, %Ash.Error.Invalid{errors: errors}} ->
        recover_existing_device_uid(device_uid, device_ip, errors, actor)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_device_uid_by_alias(device_ip, partition, actor) do
    with {:ok, aliases} <- DeviceAliasState.lookup_by_value(:ip, device_ip, actor: actor) do
      aliases
      |> Enum.filter(&eligible_alias_partition?(&1.partition, partition))
      |> Enum.reject(&(&1.state in [:replaced, :archived]))
      |> Enum.sort_by(&alias_rank_key/1, :desc)
      |> Enum.find_value(fn alias_state ->
        case Device.get_by_uid(alias_state.device_id, false, actor: actor) do
          {:ok, %Device{deleted_at: nil}} ->
            maybe_reactivate_alias(alias_state, actor)
            alias_state.device_id

          _ ->
            nil
        end
      end)
      |> then(&{:ok, &1})
    else
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

  defp maybe_reactivate_alias(%DeviceAliasState{state: :stale} = alias_state, actor) do
    alias_state
    |> Ash.Changeset.for_update(:reactivate, %{})
    |> Ash.update(actor: actor)

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
    case Enum.any?(errors, &match?(%Ash.Error.Changes.InvalidChanges{}, &1)) do
      true -> recover_existing_device_uid_from_conflict(device_uid, device_ip, errors, actor)
      false -> {:error, errors}
    end
  end

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

  defp derive_primary_identity_mac(device_ip, records) do
    records
    |> Enum.filter(&(&1.device_ip == device_ip))
    |> Enum.filter(&primary_identity_interface?/1)
    |> Enum.map(&normalize_mac(&1.if_phys_address))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> List.first()
  end

  defp primary_identity_interface?(record) do
    case String.downcase(to_string(record.interface_kind || "")) do
      "loopback" -> false
      "virtual" -> false
      "bridge" -> false
      "tunnel" -> false
      _ -> true
    end
  end

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

    Repo.all(query)
    |> Enum.group_by(&elem(&1, 0))
    |> Map.new(fn {ip, entries} ->
      uid =
        entries
        |> Enum.sort_by(&device_ip_resolution_rank/1)
        |> Enum.find_value(fn
          {_ip, uid, _metadata} ->
            normalized_uid = normalize_string(uid)

            if canonical_topology_uid?(normalized_uid) do
              uid
            else
              nil
            end

          _ ->
            nil
        end)

      {ip, uid}
    end)
  rescue
    e ->
      Logger.warning("Device UID lookup failed: #{inspect(e)}")
      %{}
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

    query
    |> Repo.all()
  end

  defp canonicalize_wireguard_interface_device_ids([]), do: []

  defp canonicalize_wireguard_interface_device_ids(interfaces) do
    ips =
      interfaces
      |> Enum.filter(fn iface ->
        device_id = normalize_string(Map.get(iface, :device_id) || Map.get(iface, "device_id"))
        not canonical_topology_uid?(device_id)
      end)
      |> Enum.map(fn iface ->
        normalize_interface_ip(Map.get(iface, :device_ip) || Map.get(iface, "device_ip"))
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    ip_to_uid = lookup_device_uids_by_ip(ips)

    Enum.map(interfaces, fn iface ->
      device_id = normalize_string(Map.get(iface, :device_id) || Map.get(iface, "device_id"))

      if canonical_topology_uid?(device_id) do
        iface
      else
        device_ip =
          normalize_interface_ip(Map.get(iface, :device_ip) || Map.get(iface, "device_ip"))

        case Map.get(ip_to_uid, device_ip) do
          uid when is_binary(uid) -> Map.put(iface, :device_id, uid)
          _ -> iface
        end
      end
    end)
  end

  @doc false
  def infer_wireguard_tunnel_links(records, interfaces, devices)
      when is_list(records) and is_list(interfaces) and is_list(devices) do
    devices_by_uid = Map.new(devices, fn d -> {normalize_string(d.uid), d} end)
    existing = existing_topology_edge_set(records)
    context = inference_context(records)

    interfaces
    |> Enum.map(fn iface ->
      tunnel_name =
        normalize_string(Map.get(iface, :tunnel_name) || Map.get(iface, "tunnel_name")) ||
          wireguard_name_from_iface(
            Map.get(iface, :if_name) || Map.get(iface, "if_name"),
            Map.get(iface, :if_descr) || Map.get(iface, "if_descr")
          )

      tunnel_ip =
        normalize_interface_ip(Map.get(iface, :tunnel_ip) || Map.get(iface, "tunnel_ip")) ||
          first_wireguard_interface_ip(
            Map.get(iface, :ip_addresses) || Map.get(iface, "ip_addresses") || []
          )

      %{
        device_id: normalize_string(Map.get(iface, :device_id) || Map.get(iface, "device_id")),
        timestamp: Map.get(iface, :timestamp) || Map.get(iface, "timestamp"),
        tunnel_name: tunnel_name,
        tunnel_ip: tunnel_ip
      }
    end)
    |> Enum.filter(fn iface ->
      is_binary(iface.device_id) and is_binary(iface.tunnel_name) and is_binary(iface.tunnel_ip)
    end)
    |> Enum.group_by(fn iface -> {iface.device_id, iface.tunnel_name} end)
    |> Enum.map(fn {_key, rows} ->
      Enum.max_by(rows, fn row -> row.timestamp || DateTime.from_unix!(0) end)
    end)
    |> Enum.group_by(& &1.tunnel_name)
    |> Enum.flat_map(fn {tunnel_name, members} ->
      uniq_members = Enum.uniq_by(members, & &1.device_id)

      if length(uniq_members) != 2 do
        []
      else
        [left, right] = uniq_members
        left_device = Map.get(devices_by_uid, left.device_id)
        right_device = Map.get(devices_by_uid, right.device_id)
        edge_key = normalized_edge_key(left.device_id, right.device_id)

        valid_pair? =
          is_map(left_device) and is_map(right_device) and
            router_type?(normalize_string(left_device.type), left_device.type_id) and
            router_type?(normalize_string(right_device.type), right_device.type_id) and
            not MapSet.member?(existing, edge_key)

        if valid_pair? do
          {local, neighbor} =
            if left.device_id <= right.device_id, do: {left, right}, else: {right, left}

          local_device = Map.get(devices_by_uid, local.device_id)
          neighbor_device = Map.get(devices_by_uid, neighbor.device_id)

          local_ip = normalize_interface_ip(local_device.ip) || local.tunnel_ip
          neighbor_ip = normalize_interface_ip(neighbor_device.ip) || neighbor.tunnel_ip

          if is_binary(local_ip) and is_binary(neighbor_ip) do
            [
              %{
                timestamp: max_wireguard_timestamp(local.timestamp, neighbor.timestamp),
                agent_id: context.agent_id,
                gateway_id: context.gateway_id,
                partition: context.partition || "default",
                protocol: "wireguard-derived",
                local_device_ip: local_ip,
                local_device_id: local.device_id,
                local_if_index: nil,
                local_if_name: tunnel_name,
                neighbor_device_id: neighbor.device_id,
                neighbor_chassis_id: nil,
                neighbor_port_id: tunnel_name,
                neighbor_port_descr: "wireguard",
                neighbor_system_name:
                  first_non_blank([
                    neighbor_device.name,
                    neighbor_device.hostname,
                    neighbor.device_id
                  ]),
                neighbor_mgmt_addr: neighbor_ip,
                metadata: %{
                  "source" => "wireguard-derived",
                  "evidence_class" => "direct",
                  "rule" => "exact_wg_interface_name_two_router_endpoints",
                  "tunnel_name" => tunnel_name,
                  "confidence_tier" => "high",
                  "confidence_score" => 95,
                  "confidence_reason" => "deterministic_wireguard_tunnel_match"
                },
                created_at: context.created_at
              }
            ]
          else
            []
          end
        else
          []
        end
      end
    end)
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
    records
    |> Enum.reduce(MapSet.new(), fn record, acc ->
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
      created_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
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

  defp routable_public_ipv4?(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, {a, b, c, d}} ->
        not (a == 10 or
               (a == 172 and b in 16..31) or
               (a == 192 and b == 168) or
               (a == 169 and b == 254) or
               a == 127 or
               a == 0 or
               a >= 224 or
               {a, b, c, d} == {255, 255, 255, 255})

      _ ->
        false
    end
  end

  defp routable_public_ipv4?(_ip), do: false

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
          device_index
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

  defp resolve_topology_uid(candidate_uid, candidate_ip, candidate_name, candidate_chassis, index) do
    uid = normalize_string(candidate_uid)
    ip = normalize_string(candidate_ip)
    chassis = normalize_mac(candidate_chassis)

    name_candidates =
      candidate_name
      |> topology_name_candidates()

    cond do
      is_binary(uid) and Map.has_key?(index.uid_to_uid, uid) ->
        canonical_uid_from_index(index.uid_to_uid, uid)

      is_binary(ip) and Map.has_key?(index.ip_to_uid, ip) ->
        canonical_uid_from_index(index.ip_to_uid, ip)

      is_binary(chassis) and Map.has_key?(index.mac_to_uid, chassis) ->
        canonical_uid_from_index(index.mac_to_uid, chassis)

      is_binary(uid) and canonical_topology_uid?(uid) ->
        uid

      true ->
        Enum.find_value(name_candidates, fn name ->
          canonical_uid_from_index(index.name_to_uid, name)
        end)
    end
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

  defp preserve_source_endpoint_ids(record), do: record

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
        record.neighbor_system_name
        |> topology_name_candidates()
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
      query =
        from(d in Device,
          where: is_nil(d.deleted_at),
          where:
            fragment(
              "COALESCE((?->>'identity_source'), '') <> 'mapper_topology_sighting'",
              d.metadata
            ),
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

      Repo.all(query)
      |> build_topology_device_index_maps()
    end
  rescue
    e ->
      Logger.warning("Topology device index lookup failed: #{inspect(e)}")
      empty_topology_device_index()
  end

  defp build_topology_device_index_maps(rows) do
    rows
    |> Enum.sort_by(&topology_index_row_rank/1)
    |> Enum.reduce(empty_topology_device_index(), fn row, acc ->
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
    case Map.get(index_map, key) |> normalize_string() do
      uid when is_binary(uid) ->
        if canonical_topology_uid?(uid), do: uid, else: nil

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
    Enum.reduce(updates, [], fn update, acc ->
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
  def prune_unattributed_unifi_links(records) when is_list(records) do
    attributed_pairs =
      records
      |> Enum.reduce(MapSet.new(), fn record, acc ->
        if attributed_snmp_like_record?(record) do
          case topology_pair_key(record) do
            nil -> acc
            key -> MapSet.put(acc, key)
          end
        else
          acc
        end
      end)

    Enum.reject(records, fn record ->
      unattributed_unifi_record?(record) and
        case topology_pair_key(record) do
          nil -> false
          key -> MapSet.member?(attributed_pairs, key)
        end
    end)
  end

  def prune_unattributed_unifi_links(records), do: records

  @doc false
  def infer_reverse_interface_hints(records) when is_list(records) do
    hints =
      Enum.reduce(records, %{}, fn record, acc ->
        local = normalize_string(Map.get(record, :local_device_id))
        neighbor = normalize_string(Map.get(record, :neighbor_device_id))
        hint = reverse_port_hint(record)

        if is_binary(local) and is_binary(neighbor) and is_binary(hint) do
          key = {neighbor, local}
          rank = reverse_port_hint_rank(record)

          case Map.get(acc, key) do
            nil ->
              Map.put(acc, key, {hint, rank})

            {_existing_hint, existing_rank} ->
              if rank >= existing_rank, do: Map.put(acc, key, {hint, rank}), else: acc
          end
        else
          acc
        end
      end)

    Enum.map(records, fn record ->
      if reverse_hint_needed?(record) do
        local = normalize_string(Map.get(record, :local_device_id))
        neighbor = normalize_string(Map.get(record, :neighbor_device_id))

        case Map.get(hints, {local, neighbor}) do
          {hint, _rank} ->
            metadata = Map.get(record, :metadata, %{}) |> Map.put("local_if_name_inferred", hint)
            %{record | local_if_name: hint, metadata: metadata}

          _ ->
            record
        end
      else
        record
      end
    end)
  end

  def infer_reverse_interface_hints(records), do: records

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

  defp reverse_port_hint(_), do: nil

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

  defp reverse_port_hint_rank(_), do: 0

  # Some LLDP/CDP identifiers are colon-delimited hex bytes (e.g. "50:6f:72:74:20:31" -> "Port 1").
  defp decode_hex_port_id(value) when is_binary(value) do
    trimmed = String.trim(value)

    with true <- String.contains?(trimmed, ":"),
         parts <- String.split(trimmed, ":", trim: true),
         true <- parts != [],
         true <- Enum.all?(parts, &(String.length(&1) == 2)),
         ints <- Enum.map(parts, &Integer.parse(&1, 16)),
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
    else
      nil
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
      created_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    if record.device_id && record.interface_uid do
      record
    else
      nil
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

  defp sanitize_interface_metadata(_metadata, _update), do: %{}

  @doc false
  def normalize_topology(update) when is_map(update) do
    timestamp = parse_timestamp(get_value(update, ["timestamp", :timestamp]))
    metadata = get_map(update, ["metadata", :metadata])
    observation = extract_topology_observation(update, metadata)
    source_endpoint = get_map(observation, ["source_endpoint", :source_endpoint])
    target_endpoint = get_map(observation, ["target_endpoint", :target_endpoint])
    neighbor_identity = get_map(update, ["neighbor_identity", :neighbor_identity])
    {tier, score, reason} = score_topology_confidence(update, metadata)

    protocol_value =
      get_string(update, ["protocol", :protocol]) ||
        get_string(observation, ["source_protocol", :source_protocol]) ||
        "unknown"

    protocol = normalize_topology_protocol(protocol_value)
    source = normalize_topology_source(Map.get(metadata, "source"))

    observation_evidence_class =
      get_string(observation, ["evidence_class", :evidence_class]) ||
        metadata_value(metadata, "observation_evidence_class")

    evidence_class =
      classify_topology_evidence_class(
        protocol,
        source,
        reason,
        metadata,
        observation_evidence_class
      )

    tier =
      get_string(observation, ["confidence_tier", :confidence_tier]) ||
        metadata_value(metadata, "observation_confidence_tier") ||
        tier

    neighbor_mgmt_addr =
      get_string(update, ["neighbor_mgmt_addr", :neighbor_mgmt_addr]) ||
        get_string(neighbor_identity, ["management_ip", :management_ip, "neighbor_mgmt_addr"]) ||
        get_string(target_endpoint, ["ip", :ip])

    neighbor_device_id =
      get_string(update, ["neighbor_device_id", :neighbor_device_id]) ||
        get_string(neighbor_identity, ["device_id", :device_id]) ||
        get_string(target_endpoint, ["device_id", :device_id])

    neighbor_chassis_id =
      get_string(update, ["neighbor_chassis_id", :neighbor_chassis_id]) ||
        get_string(neighbor_identity, ["chassis_id", :chassis_id]) ||
        get_string(target_endpoint, ["mac", :mac])

    neighbor_port_id =
      get_string(update, ["neighbor_port_id", :neighbor_port_id]) ||
        get_string(neighbor_identity, ["port_id", :port_id]) ||
        get_string(target_endpoint, ["port_id", :port_id])

    neighbor_port_descr =
      get_string(update, ["neighbor_port_descr", :neighbor_port_descr]) ||
        get_string(neighbor_identity, ["port_descr", :port_descr])

    neighbor_system_name =
      get_string(update, ["neighbor_system_name", :neighbor_system_name]) ||
        get_string(neighbor_identity, ["system_name", :system_name])

    metadata =
      metadata
      |> Map.put("confidence_tier", tier)
      |> Map.put("confidence_score", score)
      |> Map.put("confidence_reason", reason)
      |> Map.put("evidence_class", evidence_class)
      |> maybe_put_topology_observation_metadata(observation, source_endpoint, target_endpoint)
      |> maybe_put_neighbor_identity(neighbor_identity)

    %{
      timestamp: timestamp,
      agent_id: get_string(update, ["agent_id", :agent_id]),
      gateway_id: get_string(update, ["gateway_id", :gateway_id]),
      partition: get_string(update, ["partition", :partition]) || "default",
      protocol: protocol_value,
      local_device_ip: get_string(update, ["local_device_ip", :local_device_ip]),
      local_device_id:
        get_string(update, ["local_device_id", :local_device_id]) ||
          get_string(source_endpoint, ["device_id", :device_id]),
      local_if_index: get_integer(update, ["local_if_index", :local_if_index]),
      local_if_name:
        get_string(update, ["local_if_name", :local_if_name]) ||
          get_string(source_endpoint, ["if_name", :if_name]),
      neighbor_device_id: neighbor_device_id,
      neighbor_chassis_id: neighbor_chassis_id,
      neighbor_port_id: neighbor_port_id,
      neighbor_port_descr: neighbor_port_descr,
      neighbor_system_name: neighbor_system_name,
      neighbor_mgmt_addr: neighbor_mgmt_addr,
      metadata: metadata,
      created_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }
  end

  def normalize_topology(_update), do: nil

  defp extract_topology_observation(update, metadata) do
    if topology_v2_contract_consumption_enabled?() do
      explicit =
        get_map(update, ["observation", :observation])
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
  defp normalize_topology_observation_map(_), do: %{}

  defp decode_topology_observation_json(nil), do: %{}
  defp decode_topology_observation_json(""), do: %{}

  defp decode_topology_observation_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_topology_observation_json(_), do: %{}

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

  defp indirect_topology_confidence(
         source,
         true,
         false,
         true,
         true
       )
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

  defp has_canonical_neighbor_device_id?(_update), do: false

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
    observation_class = normalize_string(observation_class)

    explicit =
      metadata
      |> metadata_value("evidence_class")
      |> normalize_string()

    cond do
      observation_class in ["direct", "inferred", "endpoint-attachment"] ->
        observation_class

      explicit in ["direct", "inferred", "endpoint-attachment"] ->
        explicit

      protocol in ["lldp", "cdp", "wireguard-derived"] ->
        "direct"

      protocol == "unifi-api" and String.contains?(source || "", "port-table") ->
        "endpoint-attachment"

      protocol == "unifi-api" ->
        "direct"

      (protocol == "snmp-l2" or source == "snmp-arp-fdb") and
          reason == "single_identifier_inference" ->
        "endpoint-attachment"

      protocol == "snmp-l2" or source == "snmp-arp-fdb" ->
        "inferred"

      true ->
        "inferred"
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

  defp maybe_put_topology_observation_metadata(
         metadata,
         _observation,
         _source_endpoint,
         _target_endpoint
       ),
       do: metadata

  defp maybe_put_metadata_value(metadata, _key, value) when value in [nil, ""], do: metadata
  defp maybe_put_metadata_value(metadata, key, value), do: Map.put(metadata, key, value)

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

  defp insert_bulk([], _resource, _actor, _label), do: :ok

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp insert_bulk(records, resource, actor, label) do
    {prepared_records, opts} = prepare_bulk_records(records, resource, actor)

    prepared_records
    |> Ash.bulk_create(resource, :create, opts)
    |> handle_bulk_result(label)
  end

  defp prepare_bulk_records(records, Interface, actor) do
    filtered = Enum.reject(records, &missing_interface_identity?/1)
    log_filtered_interfaces(records, filtered)

    deduped =
      filtered
      |> Enum.uniq_by(&interface_identity_key/1)
      |> dedupe_by_interface()

    log_deduped_interfaces(filtered, deduped)

    {deduped,
     [
       actor: actor,
       return_errors?: true,
       stop_on_error?: false,
       upsert?: true,
       upsert_identity: :unique_interface,
       upsert_fields: []
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

  defp handle_bulk_result(%Ash.BulkResult{status: :success}, _label), do: :ok

  defp handle_bulk_result(%Ash.BulkResult{status: :error, errors: errors}, label) do
    # Check if all errors are TimescaleDB chunk-prefixed constraint violations
    # These occur because TimescaleDB prefixes constraint names with chunk IDs
    # (e.g., "1_2_discovered_interfaces_pkey" instead of "discovered_interfaces_pkey")
    if timescaledb_pkey_violations?(errors) do
      Logger.debug(
        "Mapper #{label}: skipped #{length(List.wrap(errors))} duplicate(s) (TimescaleDB constraint)"
      )

      :ok
    else
      Logger.warning("Mapper #{label} ingestion failed: #{inspect(errors)}")
      {:error, errors}
    end
  end

  defp handle_bulk_result({:error, reason}, label) do
    Logger.warning("Mapper #{label} ingestion failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp missing_interface_identity?(record) do
    key = interface_identity_key(record)
    elem(key, 0) == nil or elem(key, 1) == nil or elem(key, 2) == nil
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

  defp timescaledb_pkey_violations?(%Ash.Error.Unknown{errors: nested_errors}) do
    timescaledb_pkey_violations?(nested_errors)
  end

  defp timescaledb_pkey_violations?(_), do: false

  defp timescaledb_pkey_violation?(%Ash.Error.Unknown{errors: nested_errors}) do
    Enum.all?(nested_errors, &timescaledb_pkey_violation?/1)
  end

  defp timescaledb_pkey_violation?(%Ash.Error.Unknown.UnknownError{error: error_msg})
       when is_binary(error_msg) do
    # Match patterns like "1_2_discovered_interfaces_pkey" or "1_3_topology_links_pkey"
    String.contains?(error_msg, "unique_constraint") and
      Regex.match?(~r/\d+_\d+_\w+_pkey/, error_msg)
  end

  defp timescaledb_pkey_violation?(_), do: false

  defp interface_identity_key(record) when is_map(record) do
    {
      get_record_value(record, :timestamp, "timestamp"),
      get_record_value(record, :device_id, "device_id"),
      get_record_value(record, :interface_uid, "interface_uid")
    }
  end

  defp interface_identity_key(_record), do: {nil, nil, nil}

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
      now: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      actor: SystemActor.system(:mapper_job_status),
      status: Keyword.get(opts, :status, :success),
      error: Keyword.get(opts, :error),
      include_counts: Keyword.get(opts, :include_interface_counts, false)
    }
  end

  defp interface_count(count, true), do: count
  defp interface_count(_count, false), do: :skip

  defp extract_job_counts(updates) do
    updates
    |> Enum.reduce(%{}, fn update, acc ->
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
        # Normalize each metric to ensure consistent key format
        Enum.map(value, &normalize_metric/1)

      _ ->
        nil
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

  defp parse_timestamp(nil), do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :microsecond)
      _ -> DateTime.utc_now() |> DateTime.truncate(:microsecond)
    end
  end

  defp parse_timestamp(%DateTime{} = timestamp) do
    DateTime.truncate(timestamp, :microsecond)
  end
end
