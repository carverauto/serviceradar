defmodule ServiceRadar.NetworkDiscovery.MapperResultsIngestor do
  @moduledoc """
  Ingests mapper interface and topology results into CNPG and projects topology into AGE.
  """

  require Logger
  require Ash.Query

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.AliasEvents
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Inventory.{Device, IdentityReconciler, Interface, InterfaceClassifier}
  alias ServiceRadar.NetworkDiscovery.{MapperJob, TopologyGraph, TopologyLink}
  alias ServiceRadar.Repo

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
         enriched_records <- add_inferred_topology_links(resolved_records) do
      record_job_runs(updates, status: :success)

      if enriched_records == [] do
        Logger.debug("No topology links to ingest after device ID resolution")
        :ok
      else
        case insert_bulk(enriched_records, TopologyLink, actor, "topology") do
          :ok ->
            TopologyGraph.upsert_links(enriched_records)
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
        where: d.ip in ^ips,
        select: {d.ip, d.uid}
      )

    Repo.all(query)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {ip, uids} ->
      # Prefer sr: UIDs over sweep-/other legacy device IDs
      uid = Enum.find(uids, List.first(uids), &String.starts_with?(&1, "sr:"))
      {ip, uid}
    end)
  rescue
    e ->
      Logger.warning("Device UID lookup failed: #{inspect(e)}")
      %{}
  end

  # Resolve device IDs for topology records (local_device_id and neighbor_device_id)
  defp resolve_topology_device_ids([]), do: []

  defp resolve_topology_device_ids(records) do
    device_index = build_topology_device_index(records)
    resolve_topology_records(records, device_index)
  end

  defp maybe_put_neighbor_id(record, nil), do: record
  defp maybe_put_neighbor_id(record, uid), do: Map.put(record, :neighbor_device_id, uid)

  defp add_inferred_topology_links([]), do: []

  defp add_inferred_topology_links(records) do
    inferred =
      infer_gateway_topology_links(records) ++
        infer_management_topology_links(records) ++
        infer_site_topology_links(records)

    records ++ inferred
  rescue
    e ->
      Logger.warning("Topology inference failed: #{inspect(e)}")
      records
  end

  defp infer_gateway_topology_links(records) do
    local_ids =
      records
      |> Enum.map(&normalize_string(&1.local_device_id))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    neighbor_only_ids =
      records
      |> Enum.map(&normalize_string(&1.neighbor_device_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&MapSet.member?(local_ids, &1))
      |> Enum.uniq()

    if neighbor_only_ids == [] do
      []
    else
      existing_edges = existing_topology_edge_set(records)
      inferred_context = inference_context(records)
      lldp_anchor_uids = lldp_anchor_uids(records)
      neighbors = lookup_active_devices_by_uid(neighbor_only_ids)
      router_index = router_subnet_index()

      neighbors
      |> Enum.reduce([], fn neighbor, acc ->
        maybe_inferred_gateway_link(
          neighbor,
          router_index,
          existing_edges,
          inferred_context,
          lldp_anchor_uids,
          acc
        )
      end)
      |> Enum.reverse()
    end
  end

  defp lldp_anchor_uids(records) do
    records
    |> Enum.reduce(MapSet.new(), fn record, acc ->
      protocol = normalize_string(record.protocol)

      if protocol in ["lldp", "cdp"] do
        local_uid = normalize_string(record.local_device_id)
        if is_binary(local_uid), do: MapSet.put(acc, local_uid), else: acc
      else
        acc
      end
    end)
  end

  defp topology_anchor_uids(records) do
    records
    |> Enum.flat_map(fn record ->
      [
        normalize_string(record.local_device_id),
        normalize_string(record.neighbor_device_id)
      ]
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
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

  defp lookup_active_devices_by_uid([]), do: []

  defp lookup_active_devices_by_uid(uids) do
    query =
      from(d in Device,
        where: d.uid in ^uids and is_nil(d.deleted_at),
        select: %{
          uid: d.uid,
          ip: d.ip,
          name: d.name,
          hostname: d.hostname,
          type: d.type,
          type_id: d.type_id
        }
      )

    Repo.all(query)
  end

  defp router_subnet_index do
    routers =
      from(d in Device,
        where: is_nil(d.deleted_at),
        where: fragment("LOWER(COALESCE(?, ''))", d.type) == "router" or d.type_id == 12,
        select: %{uid: d.uid, ip: d.ip, name: d.name, hostname: d.hostname}
      )
      |> Repo.all()

    router_uids = Enum.map(routers, & &1.uid)
    router_by_uid = Map.new(routers, fn router -> {normalize_string(router.uid), router} end)

    interface_rows =
      if router_uids == [] do
        []
      else
        from(i in Interface,
          where: i.device_id in ^router_uids,
          where: i.timestamp > ago(3, "day"),
          select: %{device_id: i.device_id, ip_addresses: i.ip_addresses}
        )
        |> Repo.all()
      end

    Enum.reduce(interface_rows, %{}, fn row, acc ->
      router = Map.get(router_by_uid, normalize_string(row.device_id))

      if router do
        row.ip_addresses
        |> List.wrap()
        |> Enum.reduce(acc, fn raw_ip, memo ->
          case normalize_interface_ip(raw_ip) do
            nil ->
              memo

            ip ->
              case ipv4_subnet_key(ip) do
                nil ->
                  memo

                subnet ->
                  candidate = %{
                    uid: router.uid,
                    router_ip: router.ip,
                    iface_ip: ip,
                    name: router.name,
                    hostname: router.hostname
                  }

                  Map.update(memo, subnet, candidate, &preferred_router_for_subnet(&1, candidate))
              end
          end
        end)
      else
        acc
      end
    end)
  end

  defp maybe_inferred_gateway_link(
         neighbor,
         router_index,
         existing_edges,
         context,
         lldp_anchor_uids,
         acc
       ) do
    neighbor_uid = normalize_string(neighbor.uid)
    neighbor_ip = normalize_interface_ip(neighbor.ip)
    neighbor_type = normalize_string(neighbor.type)

    cond do
      neighbor_uid == nil or neighbor_ip == nil ->
        acc

      not switch_type?(neighbor_type, neighbor.type_id) ->
        acc

      true ->
        case ipv4_subnet_key(neighbor_ip) do
          nil ->
            acc

          subnet ->
            case Map.get(router_index, subnet) do
              nil ->
                acc

              router ->
                router_uid = normalize_string(router.uid)

                if router_uid == nil or router_uid == neighbor_uid do
                  acc
                else
                  edge_key = normalized_edge_key(neighbor_uid, router_uid)

                  if MapSet.member?(existing_edges, edge_key) do
                    acc
                  else
                    [
                      build_inferred_gateway_record(
                        context,
                        neighbor,
                        neighbor_ip,
                        router,
                        lldp_anchor_uids
                      )
                      | acc
                    ]
                  end
                end
            end
        end
    end
  end

  defp infer_management_topology_links(records) do
    anchor_uids = topology_anchor_uids(records)

    if anchor_uids == [] do
      []
    else
      existing_edges = existing_topology_edge_set(records)
      context = inference_context(records)
      devices = lookup_management_topology_devices(anchor_uids)
      by_uid = Map.new(devices, fn device -> {normalize_string(device.uid), device} end)

      devices
      |> Enum.reduce([], fn child, acc ->
        maybe_inferred_management_link(child, by_uid, existing_edges, context, acc)
      end)
      |> Enum.reverse()
    end
  end

  defp infer_site_topology_links(records) do
    anchor_uids = topology_anchor_uids(records)

    if anchor_uids == [] do
      []
    else
      existing_edges = existing_topology_edge_set(records)
      context = inference_context(records)
      anchors = lookup_topology_devices_by_uid(anchor_uids)
      candidates = lookup_site_topology_candidates(anchors, anchor_uids)
      connected_ids = MapSet.new(anchor_uids)
      degree = edge_degree(records)

      candidates
      |> Enum.reduce([], fn candidate, acc ->
        maybe_inferred_site_link(
          candidate,
          anchors,
          connected_ids,
          existing_edges,
          degree,
          context,
          acc
        )
      end)
      |> Enum.reverse()
    end
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

  defp lookup_site_topology_candidates([], _anchor_uids), do: []

  defp lookup_site_topology_candidates(anchors, anchor_uids) do
    controller_names =
      anchors
      |> Enum.map(&metadata_value(&1.metadata, "controller_name"))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    site_ids =
      anchors
      |> Enum.map(&metadata_value(&1.metadata, "site_id"))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if controller_names == [] and site_ids == [] do
      []
    else
      query =
        from(d in Device,
          where: is_nil(d.deleted_at),
          where: d.uid not in ^anchor_uids,
          where:
            fragment("COALESCE(LOWER((?->>'controller_name')), '')", d.metadata) in ^controller_names or
              fragment("COALESCE((?->>'site_id'), '')", d.metadata) in ^site_ids,
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
      |> Enum.filter(fn d ->
        snmp_topology_candidate_type?(normalize_string(d.type), d.type_id)
      end)
    end
  end

  defp maybe_inferred_site_link(
         candidate,
         anchors,
         connected_ids,
         existing_edges,
         degree,
         context,
         acc
       ) do
    candidate_uid = normalize_string(candidate.uid)
    candidate_ip = normalize_interface_ip(candidate.ip)
    candidate_type = normalize_string(candidate.type)

    cond do
      candidate_uid == nil or candidate_ip == nil ->
        acc

      MapSet.member?(connected_ids, candidate_uid) ->
        acc

      router_type?(candidate_type, candidate.type_id) ->
        # Site/controller proximity should not synthesize physical router edges.
        # Router-router and router-switch relationships must come from explicit topology
        # data (LLDP/CDP/tunnel telemetry), not this heuristic.
        acc

      true ->
        case choose_site_parent(candidate, anchors, degree) do
          nil ->
            acc

          parent ->
            parent_uid = normalize_string(parent.uid)

            cond do
              parent_uid == nil or parent_uid == candidate_uid ->
                acc

              MapSet.member?(existing_edges, normalized_edge_key(candidate_uid, parent_uid)) ->
                acc

              true ->
                [build_inferred_site_record(context, candidate, parent) | acc]
            end
        end
    end
  end

  defp choose_site_parent(candidate, anchors, degree) do
    candidate_site = metadata_value(candidate.metadata, "site_id")
    candidate_controller = metadata_value(candidate.metadata, "controller_name")
    candidate_ip = normalize_interface_ip(candidate.ip)
    candidate_type = normalize_string(candidate.type)

    base =
      anchors
      |> Enum.filter(fn parent ->
        parent_uid = normalize_string(parent.uid)
        parent_ip = normalize_interface_ip(parent.ip)
        parent_site = metadata_value(parent.metadata, "site_id")
        parent_controller = metadata_value(parent.metadata, "controller_name")

        parent_uid != nil and parent_ip != nil and
          ((candidate_site != nil and parent_site == candidate_site) or
             (candidate_controller != nil and parent_controller == candidate_controller))
      end)

    subnet_pref =
      Enum.filter(base, fn parent ->
        same_subnet24?(candidate_ip, normalize_interface_ip(parent.ip))
      end)

    pool = if subnet_pref == [], do: base, else: subnet_pref

    preferred =
      cond do
        access_point_type?(candidate_type, candidate.type_id) ->
          pool
          |> Enum.filter(fn p ->
            switch_type?(normalize_string(p.type), p.type_id)
          end)
          |> reject_aggregation_switches()

        switch_type?(candidate_type, candidate.type_id) ->
          agg =
            pool
            |> Enum.filter(fn p ->
              switch_type?(normalize_string(p.type), p.type_id) and aggregation_switch?(p)
            end)

          if agg == [],
            do: pool |> Enum.filter(&switch_or_router?/1),
            else: agg

        true ->
          pool
      end

    rank_by_degree(preferred, degree)
  end

  defp rank_by_degree([], _degree), do: nil

  defp rank_by_degree(devices, degree) do
    Enum.max_by(
      devices,
      fn d ->
        uid = normalize_string(d.uid)
        Map.get(degree, uid, 0)
      end,
      fn -> nil end
    )
  end

  defp switch_or_router?(d) do
    type = normalize_string(d.type)
    switch_type?(type, d.type_id) or router_type?(type, d.type_id)
  end

  defp reject_aggregation_switches([]), do: []

  defp reject_aggregation_switches(devices) do
    filtered = Enum.reject(devices, &aggregation_switch?/1)
    if filtered == [], do: devices, else: filtered
  end

  defp build_inferred_site_record(context, candidate, parent) do
    candidate_type = normalize_string(candidate.type)

    {tier, score, reason} =
      cond do
        access_point_type?(candidate_type, candidate.type_id) ->
          {"medium", 74, "snmp_site_ap_to_switch_inference"}

        switch_type?(candidate_type, candidate.type_id) ->
          {"medium", 72, "snmp_site_switch_uplink_inference"}

        true ->
          {"low", 60, "snmp_site_topology_inference"}
      end

    parent_name =
      first_non_blank([
        parent.name,
        parent.hostname,
        parent.ip,
        parent.uid,
        "site-parent"
      ])

    %{
      timestamp: context.timestamp,
      agent_id: context.agent_id,
      gateway_id: context.gateway_id,
      partition: context.partition,
      protocol: "snmp-site",
      local_device_ip: normalize_interface_ip(candidate.ip),
      local_device_id: candidate.uid,
      local_if_index: nil,
      local_if_name: "snmp-site-inferred-uplink",
      neighbor_device_id: parent.uid,
      neighbor_chassis_id: nil,
      neighbor_port_id: "snmp-site",
      neighbor_port_descr: "snmp-site-inferred-uplink",
      neighbor_system_name: parent_name,
      neighbor_mgmt_addr: normalize_interface_ip(parent.ip),
      metadata: %{
        "source" => "snmp-site-inference",
        "inference" => "controller_site_proximity",
        "confidence_tier" => tier,
        "confidence_score" => score,
        "confidence_reason" => reason
      },
      created_at: context.created_at
    }
  end

  defp maybe_inferred_management_link(child, by_uid, existing_edges, context, acc) do
    child_uid = normalize_string(child.uid)
    child_ip = normalize_interface_ip(child.ip)
    child_parent_uid = normalize_string(child.management_device_id)

    cond do
      child_uid == nil or child_ip == nil or child_parent_uid == nil ->
        acc

      child_uid == child_parent_uid ->
        acc

      not snmp_topology_candidate_type?(normalize_string(child.type), child.type_id) ->
        acc

      true ->
        case Map.get(by_uid, child_parent_uid) do
          nil ->
            acc

          parent ->
            parent_uid = normalize_string(parent.uid)
            parent_ip = normalize_interface_ip(parent.ip)

            cond do
              parent_uid == nil or parent_ip == nil ->
                acc

              not snmp_topology_candidate_type?(normalize_string(parent.type), parent.type_id) ->
                acc

              true ->
                edge_key = normalized_edge_key(child_uid, parent_uid)

                if MapSet.member?(existing_edges, edge_key) do
                  acc
                else
                  [build_inferred_management_record(context, child, parent) | acc]
                end
            end
        end
    end
  end

  defp lookup_management_topology_devices([]), do: []

  defp lookup_management_topology_devices(anchor_uids) do
    anchor_set = MapSet.new(anchor_uids)

    query =
      from(d in Device,
        where: is_nil(d.deleted_at),
        where: d.uid in ^anchor_uids or d.management_device_id in ^anchor_uids,
        select: %{
          uid: d.uid,
          management_device_id: d.management_device_id,
          ip: d.ip,
          name: d.name,
          hostname: d.hostname,
          type: d.type,
          type_id: d.type_id
        }
      )

    Repo.all(query)
    |> Enum.filter(fn device ->
      uid = normalize_string(device.uid)
      mgmt_uid = normalize_string(device.management_device_id)
      MapSet.member?(anchor_set, uid) or MapSet.member?(anchor_set, mgmt_uid)
    end)
  end

  defp build_inferred_management_record(context, child, parent) do
    child_type = normalize_string(child.type)
    parent_type = normalize_string(parent.type)

    {tier, score, reason} =
      cond do
        access_point_type?(child_type, child.type_id) and
            switch_type?(parent_type, parent.type_id) ->
          {"high", 90, "snmp_management_parent_ap_uplink"}

        switch_type?(child_type, child.type_id) and
            router_type?(parent_type, parent.type_id) ->
          {"high", 88, "snmp_management_parent_switch_uplink"}

        switch_type?(child_type, child.type_id) and
            switch_type?(parent_type, parent.type_id) ->
          {"high", 84, "snmp_management_parent_switch_trunk"}

        true ->
          {"medium", 70, "snmp_management_parent_link"}
      end

    parent_name =
      first_non_blank([
        parent.name,
        parent.hostname,
        parent.ip,
        parent.uid,
        "parent"
      ])

    %{
      timestamp: context.timestamp,
      agent_id: context.agent_id,
      gateway_id: context.gateway_id,
      partition: context.partition,
      protocol: "snmp-parent",
      local_device_ip: normalize_interface_ip(child.ip),
      local_device_id: child.uid,
      local_if_index: nil,
      local_if_name: "snmp-management-parent",
      neighbor_device_id: parent.uid,
      neighbor_chassis_id: nil,
      neighbor_port_id: "snmp-parent",
      neighbor_port_descr: "snmp-management-parent",
      neighbor_system_name: parent_name,
      neighbor_mgmt_addr: normalize_interface_ip(parent.ip),
      metadata: %{
        "source" => "snmp-management-parent",
        "inference" => "device_management_parent",
        "confidence_tier" => tier,
        "confidence_score" => score,
        "confidence_reason" => reason
      },
      created_at: context.created_at
    }
  end

  defp preferred_router_for_subnet(existing, candidate) do
    existing_ip = normalize_interface_ip(existing.iface_ip)
    candidate_ip = normalize_interface_ip(candidate.iface_ip)

    existing_pref = ip_preference_score(existing_ip)
    candidate_pref = ip_preference_score(candidate_ip)

    if candidate_pref > existing_pref, do: candidate, else: existing
  end

  defp ip_preference_score(nil), do: 0

  defp ip_preference_score(ip) do
    if String.ends_with?(ip, ".1"), do: 2, else: 1
  end

  defp snmp_topology_candidate_type?(type, type_id) do
    switch_type?(type, type_id) or router_type?(type, type_id) or
      access_point_type?(type, type_id)
  end

  defp switch_type?(type, type_id), do: type_id == 10 or type == "switch"
  defp router_type?(type, type_id), do: type_id == 12 or type == "router"

  defp access_point_type?(type, type_id) do
    type = normalize_string(type)

    cond do
      type in ["ap", "access_point", "access-point", "wireless_ap", "wireless"] -> true
      type_id == 7 -> true
      is_binary(type) and String.contains?(type, "access point") -> true
      is_binary(type) and String.contains?(type, "wireless") -> true
      is_binary(type) and String.ends_with?(type, " ap") -> true
      true -> false
    end
  end

  defp aggregation_switch?(device) when is_map(device) do
    text =
      [device.name, device.hostname, device.type]
      |> Enum.map(&normalize_string/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    String.contains?(text, "aggregation")
  end

  defp aggregation_switch?(_), do: false

  defp metadata_value(metadata, key) when is_map(metadata) and is_binary(key) do
    metadata
    |> Map.get(key)
    |> normalize_string()
  end

  defp metadata_value(_, _), do: nil

  defp edge_degree(records) when is_list(records) do
    Enum.reduce(records, %{}, fn record, acc ->
      local_uid = normalize_string(record.local_device_id)
      neighbor_uid = normalize_string(record.neighbor_device_id)

      acc
      |> maybe_increment_degree(local_uid)
      |> maybe_increment_degree(neighbor_uid)
    end)
  end

  defp maybe_increment_degree(acc, nil), do: acc
  defp maybe_increment_degree(acc, uid), do: Map.update(acc, uid, 1, &(&1 + 1))

  defp same_subnet24?(ip_a, ip_b) when is_binary(ip_a) and is_binary(ip_b) do
    with [a1, a2, a3, _] <- String.split(ip_a, "."),
         [b1, b2, b3, _] <- String.split(ip_b, ".") do
      a1 == b1 and a2 == b2 and a3 == b3
    else
      _ -> false
    end
  end

  defp same_subnet24?(_, _), do: false

  defp build_inferred_gateway_record(context, neighbor, neighbor_ip, router, lldp_anchor_uids) do
    router_name =
      first_non_blank([
        router.name,
        router.hostname,
        router.iface_ip,
        router.router_ip,
        "gateway"
      ])

    gateway_ip =
      normalize_interface_ip(router.iface_ip) || normalize_interface_ip(router.router_ip)

    neighbor_uid_norm = normalize_string(neighbor.uid)

    lldp_anchored? =
      is_binary(neighbor_uid_norm) and MapSet.member?(lldp_anchor_uids, neighbor_uid_norm)

    gateway_like? = is_binary(gateway_ip) and String.ends_with?(gateway_ip, ".1")

    {tier, score, reason} =
      if lldp_anchored? and gateway_like? do
        {"high", 88, "corroborated_l3_gateway_uplink"}
      else
        {"medium", 64, "shared_subnet_gateway_inference"}
      end

    %{
      timestamp: context.timestamp,
      agent_id: context.agent_id,
      gateway_id: context.gateway_id,
      partition: context.partition,
      protocol: "l3-uplink",
      local_device_ip: neighbor_ip,
      local_device_id: neighbor.uid,
      local_if_index: nil,
      local_if_name: nil,
      neighbor_device_id: router.uid,
      neighbor_chassis_id: nil,
      neighbor_port_id: "gateway-uplink",
      neighbor_port_descr: "l3-uplink",
      neighbor_system_name: router_name,
      neighbor_mgmt_addr: gateway_ip,
      metadata: %{
        "source" => "gateway-correlation",
        "inference" => "router_interface_subnet_match",
        "confidence_tier" => tier,
        "confidence_score" => score,
        "confidence_reason" => reason
      },
      created_at: context.created_at
    }
  end

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

  defp ipv4_subnet_key(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, {a, b, c, _d}} -> "#{a}.#{b}.#{c}"
      _ -> nil
    end
  end

  defp ipv4_subnet_key(_ip), do: nil

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

      if local_uid do
        record
        |> Map.put(:local_device_id, local_uid)
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
        Map.get(index.uid_to_uid, uid)

      is_binary(ip) and Map.has_key?(index.ip_to_uid, ip) ->
        Map.get(index.ip_to_uid, ip)

      is_binary(chassis) and Map.has_key?(index.mac_to_uid, chassis) ->
        Map.get(index.mac_to_uid, chassis)

      true ->
        Enum.find_value(name_candidates, fn name -> Map.get(index.name_to_uid, name) end)
    end
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
            mac: d.mac
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
    Enum.reduce(rows, empty_topology_device_index(), fn row, acc ->
      uid = normalize_string(row.uid)
      ip = normalize_string(row.ip)
      mac = normalize_mac(row.mac)

      name_candidates =
        row.name
        |> topology_name_candidates()
        |> Kernel.++(topology_name_candidates(row.hostname))
        |> Enum.uniq()

      acc
      |> put_topology_index_entry(:uid_to_uid, uid)
      |> put_topology_index_entry(:ip_to_uid, ip, uid)
      |> put_topology_index_entry(:mac_to_uid, mac, uid)
      |> put_topology_name_entries(name_candidates, uid)
    end)
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
      "" -> nil
      trimmed -> String.downcase(trimmed)
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
  end

  @doc false
  def normalize_interface(update) when is_map(update) do
    metadata = get_map(update, ["metadata", :metadata])

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

  @doc false
  def normalize_topology(update) when is_map(update) do
    timestamp = parse_timestamp(get_value(update, ["timestamp", :timestamp]))
    metadata = get_map(update, ["metadata", :metadata])
    {tier, score, reason} = score_topology_confidence(update, metadata)

    metadata =
      metadata
      |> Map.put("confidence_tier", tier)
      |> Map.put("confidence_score", score)
      |> Map.put("confidence_reason", reason)

    %{
      timestamp: timestamp,
      agent_id: get_string(update, ["agent_id", :agent_id]),
      gateway_id: get_string(update, ["gateway_id", :gateway_id]),
      partition: get_string(update, ["partition", :partition]) || "default",
      protocol: get_string(update, ["protocol", :protocol]),
      local_device_ip: get_string(update, ["local_device_ip", :local_device_ip]),
      local_device_id: get_string(update, ["local_device_id", :local_device_id]),
      local_if_index: get_integer(update, ["local_if_index", :local_if_index]),
      local_if_name: get_string(update, ["local_if_name", :local_if_name]),
      neighbor_device_id: get_string(update, ["neighbor_device_id", :neighbor_device_id]),
      neighbor_chassis_id: get_string(update, ["neighbor_chassis_id", :neighbor_chassis_id]),
      neighbor_port_id: get_string(update, ["neighbor_port_id", :neighbor_port_id]),
      neighbor_port_descr: get_string(update, ["neighbor_port_descr", :neighbor_port_descr]),
      neighbor_system_name: get_string(update, ["neighbor_system_name", :neighbor_system_name]),
      neighbor_mgmt_addr: get_string(update, ["neighbor_mgmt_addr", :neighbor_mgmt_addr]),
      metadata: metadata,
      created_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }
  end

  def normalize_topology(_update), do: nil

  defp score_topology_confidence(update, metadata) do
    protocol = normalize_topology_protocol(get_string(update, ["protocol", :protocol]))
    source = normalize_topology_source(Map.get(metadata, "source"))
    has_neighbor_id = has_neighbor_identifier?(update)
    has_neighbor_ip = present?(get_string(update, ["neighbor_mgmt_addr", :neighbor_mgmt_addr]))
    has_neighbor_port = has_neighbor_port?(update)

    topology_protocol_confidence(protocol) ||
      indirect_topology_confidence(source, has_neighbor_id, has_neighbor_port, has_neighbor_ip)
  end

  defp topology_protocol_confidence("lldp"), do: {"high", 95, "direct_lldp_neighbor"}
  defp topology_protocol_confidence("cdp"), do: {"high", 95, "direct_cdp_neighbor"}
  defp topology_protocol_confidence(_), do: nil

  defp indirect_topology_confidence("unifi-api", true, true, true),
    do: {"medium", 78, "bridge_uplink_with_neighbor_ip"}

  defp indirect_topology_confidence("unifi-api", true, true, false),
    do: {"medium", 72, "bridge_uplink_without_neighbor_ip"}

  defp indirect_topology_confidence(_source, true, true, _has_neighbor_ip),
    do: {"medium", 66, "port_neighbor_inference"}

  defp indirect_topology_confidence(_source, true, false, _has_neighbor_ip),
    do: {"low", 40, "single_identifier_inference"}

  defp indirect_topology_confidence(_source, false, _has_neighbor_port, _has_neighbor_ip),
    do: {"low", 20, "insufficient_neighbor_evidence"}

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
      value when is_binary(value) -> value
      value when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
      _ -> nil
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
