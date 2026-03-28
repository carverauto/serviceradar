defmodule ServiceRadar.Camera.InventoryIngestor do
  @moduledoc """
  Ingests camera discovery descriptors from plugin results into normalized inventory.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.StreamProfile
  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.IdentityReconciler

  require Ash.Query
  require Logger

  @status_availability_labels %{true => "available", false => "unavailable"}

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
    context = build_ingest_context(payload, status, opts)
    descriptors = context.descriptors

    Enum.reduce_while(descriptors, :ok, fn descriptor, :ok ->
      case ingest_descriptor(descriptor, context) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def ingest(_payload, _status, _opts), do: :ok

  defp ingest_descriptor(descriptor, context) do
    descriptor =
      resolve_descriptor_device_uid(
        descriptor,
        context.status,
        context.actor,
        context.resolve_device_uid
      )

    with :ok <-
           context.device_sync.(
             descriptor,
             context.status,
             context.observed_at,
             context.actor
           ),
         {:ok, source_attrs} <-
           normalize_source(
             descriptor,
             context.descriptors,
             context.payload,
             context.status,
             context.observed_at
           ),
         {:ok, source_record} <- context.source_upsert.(source_attrs, context.actor) do
      descriptor
      |> normalize_profiles(context.observed_at)
      |> Enum.reduce_while(:ok, fn profile_attrs, :ok ->
        attrs = Map.put(profile_attrs, :camera_source_id, source_record.id)

        case context.profile_upsert.(attrs, context.actor) do
          {:ok, _profile} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      {:skip, reason} ->
        Logger.debug("Skipping camera descriptor during inventory ingest: #{reason}")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_ingest_context(payload, status, opts) do
    %{
      payload: payload,
      status: status,
      actor: Keyword.get(opts, :actor, SystemActor.system(:camera_inventory_ingestor)),
      observed_at: Keyword.get(opts, :observed_at) || resolve_observed_at(payload, status),
      source_upsert: Keyword.get(opts, :source_upsert, &upsert_source/2),
      profile_upsert: Keyword.get(opts, :profile_upsert, &upsert_profile/2),
      device_sync: Keyword.get(opts, :device_sync, &sync_device_inventory/4),
      resolve_device_uid: Keyword.get(opts, :resolve_device_uid, &default_resolve_device_uid/3),
      descriptors: extract_camera_descriptors(payload)
    }
  end

  @doc """
  Extract normalized camera descriptors from a plugin result payload.
  """
  @spec extract_camera_descriptors(map()) :: [map()]
  def extract_camera_descriptors(payload) when is_map(payload) do
    direct_descriptors =
      payload
      |> list_value(["camera_descriptors", "cameraDescriptors", "cameras"])
      |> Enum.filter(&is_map/1)

    case direct_descriptors do
      [] ->
        payload
        |> details_payload_or_self()
        |> extract_details_camera_descriptors()

      _ ->
        direct_descriptors
    end
  end

  def extract_camera_descriptors(_payload), do: []

  defp normalize_source(descriptor, descriptors, payload, status, observed_at)
       when is_map(descriptor) do
    vendor = string_value(descriptor, ["vendor"])

    vendor_camera_id =
      string_value(descriptor, [
        "vendor_camera_id",
        "vendorCameraId",
        "camera_id",
        "cameraId",
        "id"
      ])

    device_uid =
      string_value(descriptor, [
        "device_uid",
        "deviceUid",
        "device_id",
        "deviceId",
        "canonical_device_id",
        "canonicalDeviceId",
        "uid"
      ])

    if blank?(device_uid) or blank?(vendor) or blank?(vendor_camera_id) do
      {:skip, "missing required camera identity fields"}
    else
      source_state = derive_source_state(descriptor, descriptors, payload, status, observed_at)

      {:ok,
       Map.merge(
         %{
           device_uid: device_uid,
           vendor: vendor,
           vendor_camera_id: vendor_camera_id,
           display_name: string_value(descriptor, ["display_name", "displayName", "name"]),
           source_url:
             string_value(descriptor, ["source_url", "sourceUrl", "rtsp_url", "rtspUrl"]),
           assigned_agent_id:
             string_value(descriptor, [
               "assigned_agent_id",
               "assignedAgentId",
               "agent_id",
               "agentId"
             ]) || status[:agent_id],
           assigned_gateway_id:
             string_value(descriptor, [
               "assigned_gateway_id",
               "assignedGatewayId",
               "gateway_id",
               "gatewayId"
             ]) ||
               status[:gateway_id],
           metadata: map_value(descriptor, ["metadata"]) || %{}
         },
         source_state
       )}
    end
  end

  defp normalize_profiles(descriptor, observed_at) do
    profiles =
      descriptor
      |> list_value(["stream_profiles", "streamProfiles", "profiles"])
      |> Enum.map(&normalize_profile(&1, observed_at))
      |> Enum.reject(&is_nil/1)

    if profiles == [] do
      case normalize_default_profile(descriptor, observed_at) do
        nil -> []
        profile -> [profile]
      end
    else
      profiles
    end
  end

  defp normalize_profile(profile, observed_at) when is_map(profile) do
    profile_name = string_value(profile, ["profile_name", "profileName", "name", "profile"])

    profile_name =
      cond do
        not blank?(profile_name) ->
          profile_name

        not blank?(
          string_value(profile, [
            "vendor_profile_id",
            "vendorProfileId",
            "profile_id",
            "profileId",
            "id"
          ])
        ) ->
          string_value(profile, [
            "vendor_profile_id",
            "vendorProfileId",
            "profile_id",
            "profileId",
            "id"
          ])

        true ->
          nil
      end

    if blank?(profile_name) do
      nil
    else
      %{
        profile_name: profile_name,
        vendor_profile_id:
          string_value(profile, [
            "vendor_profile_id",
            "vendorProfileId",
            "profile_id",
            "profileId",
            "id"
          ]),
        source_url_override:
          string_value(profile, [
            "source_url_override",
            "sourceUrlOverride",
            "source_url",
            "sourceUrl",
            "rtsp_url",
            "rtspUrl"
          ]),
        rtsp_transport: string_value(profile, ["rtsp_transport", "rtspTransport", "transport"]),
        codec_hint: string_value(profile, ["codec_hint", "codecHint", "codec"]),
        container_hint: string_value(profile, ["container_hint", "containerHint", "container"]),
        relay_eligible: boolean_value(profile, ["relay_eligible", "relayEligible"], true),
        last_seen_at: observed_at,
        metadata: normalize_profile_metadata(map_value(profile, ["metadata"]) || %{})
      }
    end
  end

  defp normalize_profile(_profile, _observed_at), do: nil

  defp normalize_default_profile(descriptor, observed_at) do
    if blank?(string_value(descriptor, ["source_url", "sourceUrl", "rtsp_url", "rtspUrl"])) and
         blank?(string_value(descriptor, ["codec_hint", "codecHint", "codec"])) do
      nil
    else
      %{
        profile_name: "default",
        vendor_profile_id: string_value(descriptor, ["vendor_profile_id", "vendorProfileId"]),
        source_url_override: nil,
        rtsp_transport:
          string_value(descriptor, ["rtsp_transport", "rtspTransport", "transport"]),
        codec_hint: string_value(descriptor, ["codec_hint", "codecHint", "codec"]),
        container_hint:
          string_value(descriptor, ["container_hint", "containerHint", "container"]),
        relay_eligible: boolean_value(descriptor, ["relay_eligible", "relayEligible"], true),
        last_seen_at: observed_at,
        metadata: map_value(descriptor, ["profile_metadata", "profileMetadata"]) || %{}
      }
    end
  end

  defp extract_details_camera_descriptors(details) when is_map(details) do
    detail_descriptors =
      details
      |> list_value(["camera_descriptors", "cameraDescriptors", "cameras"])
      |> Enum.filter(&is_map/1)

    if detail_descriptors == [] do
      generic_descriptors = extract_enrichment_camera_descriptors(details)

      if generic_descriptors == [] do
        infer_axis_camera_descriptors(details)
      else
        generic_descriptors
      end
    else
      detail_descriptors
    end
  end

  defp extract_details_camera_descriptors(_details), do: []

  defp upsert_source(attrs, actor) do
    Source.upsert_source(attrs, actor: actor)
  end

  defp upsert_profile(attrs, actor) do
    StreamProfile.upsert_profile(attrs, actor: actor)
  end

  defp sync_device_inventory(descriptor, status, observed_at, actor) when is_map(descriptor) do
    case build_device_inventory_attrs(descriptor, status, observed_at) do
      {:ok, device_uid, attrs} ->
        upsert_device_inventory(device_uid, attrs, actor)

      :skip ->
        :ok
    end
  end

  defp sync_device_inventory(_descriptor, _status, _observed_at, _actor), do: :ok

  defp build_device_inventory_attrs(descriptor, status, observed_at) do
    device_uid = descriptor_device_uid(descriptor)

    if blank?(device_uid) do
      :skip
    else
      {:ok, device_uid,
       %{
         uid: device_uid,
         type: "camera",
         type_id: 7,
         name:
           first_present([
             string_value(descriptor, ["display_name", "displayName", "name"]),
             descriptor_vendor_camera_id(descriptor),
             device_uid
           ]),
         hostname: descriptor_hostname(descriptor),
         ip: descriptor_ip(descriptor),
         mac: descriptor_mac(descriptor),
         vendor_name: string_value(descriptor, ["vendor"]),
         model: descriptor_model(descriptor),
         discovery_sources: ["camera_plugin"],
         is_managed: true,
         is_available: descriptor_available?(descriptor, status),
         last_seen_time: observed_at,
         metadata:
           %{}
           |> maybe_put("camera_vendor_camera_id", descriptor_vendor_camera_id(descriptor))
           |> maybe_put(
             "camera_source_url",
             string_value(descriptor, ["source_url", "sourceUrl"])
           )
           |> maybe_put("camera_host", descriptor_hostname(descriptor))
           |> maybe_put("camera_metadata", map_value(descriptor, ["metadata"]))
       }}
    end
  end

  defp upsert_device_inventory(device_uid, attrs, actor) do
    attrs = enrich_camera_device_attrs(device_uid, attrs, actor)

    case Device.get_by_uid(device_uid, true, actor: actor) do
      {:ok, nil} ->
        {create_attrs, conflicting_ip_device} = prepare_camera_ip_claim(device_uid, attrs, actor)

        Device
        |> Ash.Changeset.for_create(:create, create_attrs, actor: actor)
        |> Ash.create()
        |> case do
          {:ok, _device} ->
            register_camera_identifiers(device_uid, attrs, actor)
            finalize_camera_ip_claim(device_uid, attrs, conflicting_ip_device, actor)

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, %Device{} = device} ->
        merged_attrs =
          device
          |> merge_camera_device_attrs(attrs)
          |> enrich_camera_device_attrs(device_uid, actor)

        with :ok <- claim_camera_ip_conflict(device_uid, merged_attrs, actor) do
          update_camera_device(device, merged_attrs, actor)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_camera_device(device, attrs, actor) do
    case {device, attrs} do
      {%Device{} = device, attrs} when is_map(attrs) ->
        device
        |> Ash.Changeset.for_update(
          :update,
          %{
            type: "camera",
            type_id: 7,
            name: attrs.name,
            hostname: attrs.hostname,
            ip: attrs.ip,
            mac: attrs.mac,
            gateway_id: nil,
            agent_id: nil,
            management_device_id: nil,
            vendor_name: attrs.vendor_name,
            model: attrs.model,
            is_managed: attrs.is_managed,
            is_available: attrs.is_available,
            discovery_sources:
              merge_discovery_sources(device.discovery_sources, attrs.discovery_sources),
            metadata: merge_device_metadata(device.metadata, attrs.metadata),
            last_seen_time: attrs.last_seen_time
          },
          actor: actor
        )
        |> Ash.update()
        |> case do
          {:ok, _device} ->
            register_camera_identifiers(device.uid, attrs, actor)
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      {%Device{} = device, target_uid} when is_binary(target_uid) ->
        # Tolerate older ingest paths that passed the target uid instead of attrs after
        # an IP-claim merge. Re-read the canonical camera row and continue with its
        # merged state rather than failing the whole ingest.
        with {:ok, %Device{} = target_device} <-
               Device.get_by_uid(target_uid, false, actor: actor) do
          target_device
          |> camera_device_update_attrs()
          |> then(&merge_camera_device_attrs(device, &1))
          |> then(&update_camera_device(target_device, &1, actor))
        end

      _ ->
        {:error, {:invalid_camera_update_target, device, attrs}}
    end
  end

  defp prepare_camera_ip_claim(device_uid, attrs, actor)
       when is_binary(device_uid) and is_map(attrs) do
    case camera_ip_conflict(device_uid, attrs, actor) do
      {:ok, nil} ->
        {attrs, nil}

      {:ok, %Device{} = device} ->
        {%{attrs | ip: nil}, device}

      {:error, _reason} ->
        {attrs, nil}
    end
  end

  defp prepare_camera_ip_claim(_device_uid, attrs, _actor), do: {attrs, nil}

  defp finalize_camera_ip_claim(_device_uid, _attrs, nil, _actor), do: :ok

  defp finalize_camera_ip_claim(device_uid, attrs, %Device{} = conflict, actor)
       when is_binary(device_uid) and is_map(attrs) do
    with :ok <- claim_conflicting_device_ip(conflict, device_uid, attrs, actor),
         {:ok, %Device{} = device} <- Device.get_by_uid(device_uid, false, actor: actor) do
      update_camera_device(device, attrs, actor)
    end
  end

  defp claim_camera_ip_conflict(device_uid, attrs, actor)
       when is_binary(device_uid) and is_map(attrs) do
    case camera_ip_conflict(device_uid, attrs, actor) do
      {:ok, nil} ->
        :ok

      {:ok, %Device{} = device} ->
        claim_conflicting_device_ip(device, device_uid, attrs, actor)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp claim_camera_ip_conflict(_device_uid, _attrs, _actor), do: :ok

  defp claim_conflicting_device_ip(%Device{} = conflict, device_uid, attrs, actor)
       when is_binary(device_uid) and is_map(attrs) do
    case IdentityReconciler.merge_devices(conflict.uid, device_uid,
           actor: actor,
           reason: "camera_ip_claim",
           details: %{
             source: "camera_inventory",
             camera_ip: attrs.ip,
             camera_mac: attrs.mac,
             camera_vendor: attrs.vendor_name,
             from_device_ip: conflict.ip,
             from_device_hostname: conflict.hostname
           }
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp camera_ip_conflict(device_uid, attrs, actor)
       when is_binary(device_uid) and is_map(attrs) do
    case Map.get(attrs, :ip) do
      ip when is_binary(ip) and ip != "" ->
        case list_devices_by_ip(ip, actor) do
          {:ok, devices} ->
            devices
            |> Enum.reject(&(&1.uid == device_uid))
            |> resolve_camera_ip_conflict(ip, actor)

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:ok, nil}
    end
  end

  defp camera_ip_conflict(_device_uid, _attrs, _actor), do: {:ok, nil}

  defp list_devices_by_ip(ip, actor) when is_binary(ip) and ip != "" do
    Device
    |> Ash.Query.for_read(:by_ip, %{ip: ip, include_deleted: true})
    |> Ash.read(actor: actor)
    |> Page.unwrap()
  end

  defp list_devices_by_ip(_ip, _actor), do: {:ok, []}

  defp resolve_camera_ip_conflict([], _ip, _actor), do: {:ok, nil}

  defp resolve_camera_ip_conflict(devices, ip, actor) when is_list(devices) do
    case Enum.filter(devices, &claimable_camera_ip_conflict?(&1, actor)) do
      [] ->
        device =
          Enum.max_by(devices, &camera_ip_conflict_score/1, fn -> nil end)

        case device do
          nil -> {:ok, nil}
          %Device{} = conflict -> {:error, {:ip_conflict, conflict.uid, ip}}
        end

      claimable ->
        {:ok, Enum.max_by(claimable, &camera_ip_conflict_score/1)}
    end
  end

  defp claimable_camera_ip_conflict?(%Device{} = device, actor) do
    not IdentityReconciler.service_device_id?(device.uid) and
      device.type != "camera" and
      not device_has_strong_identifiers?(device.uid, actor)
  end

  defp camera_ip_conflict_score(%Device{} = device) do
    {
      claimable_ip_placeholder_priority(device),
      if(String.starts_with?(device.uid || "", "sweep-"), do: 0, else: 1),
      count_present([device.mac, device.hostname]),
      device.modified_time || device.last_seen_time || ~U[1970-01-01 00:00:00Z]
    }
  end

  defp claimable_ip_placeholder_priority(%Device{} = device) do
    case Map.get(device.metadata || %{}, "identity_state") do
      "provisional" -> 2
      _ -> 1
    end
  end

  defp device_has_strong_identifiers?(device_uid, actor) when is_binary(device_uid) do
    DeviceIdentifier
    |> Ash.Query.for_read(:by_device, %{device_id: device_uid})
    |> Ash.Query.filter(
      identifier_type in [:agent_id, :armis_device_id, :integration_id, :netbox_device_id, :mac]
    )
    |> Ash.read(actor: actor)
    |> Page.unwrap()
    |> case do
      {:ok, identifiers} -> identifiers != []
      _ -> false
    end
  rescue
    _ -> false
  end

  defp device_has_strong_identifiers?(_device_uid, _actor), do: false

  defp merge_camera_device_attrs(%Device{} = existing, attrs) when is_map(attrs) do
    %{
      attrs
      | ip: prefer_non_empty(attrs.ip, existing.ip),
        mac: prefer_non_empty(attrs.mac, existing.mac),
        hostname: prefer_non_empty(attrs.hostname, existing.hostname),
        name: prefer_non_empty(attrs.name, existing.name),
        vendor_name: prefer_non_empty(attrs.vendor_name, existing.vendor_name),
        model: prefer_non_empty(attrs.model, existing.model)
    }
  end

  defp camera_device_update_attrs(%Device{} = device) do
    %{
      name: device.name,
      hostname: device.hostname,
      ip: device.ip,
      mac: device.mac,
      vendor_name: device.vendor_name,
      model: device.model,
      discovery_sources: device.discovery_sources || [],
      is_managed: device.is_managed,
      is_available: device.is_available,
      metadata: device.metadata || %{},
      last_seen_time: device.last_seen_time
    }
  end

  defp enrich_camera_device_attrs(device_uid, attrs, actor)
       when is_binary(device_uid) and is_map(attrs) do
    with mac when is_binary(mac) and mac != "" <- normalize_mac(attrs.mac),
         {:ok, peer} <- find_inventory_peer_by_mac(mac, device_uid, actor) do
      %{
        attrs
        | ip: prefer_non_empty(attrs.ip, peer.ip),
          hostname: prefer_non_empty(attrs.hostname, peer.hostname),
          vendor_name: prefer_non_empty(attrs.vendor_name, peer.vendor_name),
          model: prefer_non_empty(attrs.model, peer.model)
      }
    else
      _ -> attrs
    end
  end

  defp enrich_camera_device_attrs(_device_uid, attrs, _actor), do: attrs

  defp find_inventory_peer_by_mac(mac, device_uid, actor)
       when is_binary(mac) and mac != "" and is_binary(device_uid) do
    with {:ok, devices} <- read_inventory_peers_by_mac(mac, device_uid, actor) do
      select_inventory_peer(devices)
    end
  rescue
    error ->
      Logger.warning(
        "Failed to enrich camera inventory from peer MAC #{mac}: #{Exception.message(error)}"
      )

      {:error, :lookup_failed}
  end

  defp find_inventory_peer_by_mac(_mac, _device_uid, _actor), do: {:error, :invalid_mac}

  defp read_inventory_peers_by_mac(mac, device_uid, actor) do
    Device
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      mac == ^mac and uid != ^device_uid and (not is_nil(ip) or not is_nil(hostname))
    )
    |> Ash.read(actor: actor)
    |> Page.unwrap()
    |> case do
      {:ok, devices} when is_list(devices) -> {:ok, devices}
      _ -> {:error, :not_found}
    end
  end

  defp select_inventory_peer(devices) when is_list(devices) do
    case Enum.max_by(devices, &camera_inventory_peer_score/1, fn -> nil end) do
      %Device{} = device -> {:ok, device}
      nil -> {:error, :not_found}
    end
  end

  defp camera_inventory_peer_score(%Device{} = device) do
    camera_type_penalty =
      case device.type do
        "camera" -> 0
        _ -> 1
      end

    {
      camera_type_penalty,
      count_present([device.ip, device.hostname, device.vendor_name, device.model]),
      device.last_seen_time || ~U[1970-01-01 00:00:00Z]
    }
  end

  defp count_present(values) when is_list(values) do
    Enum.count(values, &(not blank?(&1)))
  end

  defp normalize_mac(nil), do: nil

  defp normalize_mac(mac) when is_binary(mac) do
    case IdentityReconciler.normalize_mac(mac) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_mac(_value), do: nil

  defp register_camera_identifiers(device_uid, attrs, actor)
       when is_binary(device_uid) and is_map(attrs) do
    ids =
      %{}
      |> maybe_put("mac", attrs.mac)
      |> maybe_put("integration_id", camera_integration_id(attrs))
      |> maybe_put("ip", attrs.ip)

    case ids do
      map when map_size(map) == 0 ->
        :ok

      map ->
        case IdentityReconciler.register_identifiers(device_uid, map, actor: actor) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Failed to register camera identifiers for #{device_uid}: #{inspect(reason)}"
            )

            :ok
        end
    end
  end

  defp register_camera_identifiers(_device_uid, _attrs, _actor), do: :ok

  defp camera_integration_id(attrs) when is_map(attrs) do
    vendor = normalize_identifier_component(attrs.vendor_name)

    vendor_camera_id =
      attrs
      |> Map.get(:metadata, %{})
      |> map_value(["camera_vendor_camera_id"])
      |> normalize_identifier_component()

    if blank?(vendor) or blank?(vendor_camera_id) do
      nil
    else
      "#{vendor}:camera:#{vendor_camera_id}"
    end
  end

  defp normalize_identifier_component(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_identifier_component(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_identifier_component()

  defp normalize_identifier_component(_value), do: nil

  defp merge_discovery_sources(existing_sources, incoming_sources) do
    existing_sources = if is_list(existing_sources), do: existing_sources, else: []
    incoming_sources = if is_list(incoming_sources), do: incoming_sources, else: []

    existing_sources
    |> Kernel.++(incoming_sources)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp merge_device_metadata(existing, incoming) do
    existing = if is_map(existing), do: existing, else: %{}
    incoming = if is_map(incoming), do: incoming, else: %{}
    Map.merge(existing, incoming)
  end

  defp prefer_non_empty(new_value, old_value) when new_value in [nil, ""], do: old_value
  defp prefer_non_empty(new_value, _old_value), do: new_value

  defp descriptor_available?(descriptor, status) do
    case string_value(descriptor, ["availability_status", "availabilityStatus"]) do
      "unavailable" -> false
      "degraded" -> true
      "available" -> true
      _ -> Map.get(status, :available, true)
    end
  end

  defp descriptor_vendor_camera_id(descriptor) when is_map(descriptor) do
    string_value(descriptor, [
      "vendor_camera_id",
      "vendorCameraId",
      "camera_id",
      "cameraId",
      "id"
    ])
  end

  defp descriptor_model(descriptor) when is_map(descriptor) do
    camera = map_value(descriptor, ["camera"]) || %{}

    first_present([
      string_value(camera, ["model", "model_key", "modelKey", "name"]),
      string_value(descriptor, ["model"])
    ])
  end

  defp derive_source_state(descriptor, descriptors, payload, status, observed_at) do
    matched_events = matching_camera_events(descriptor, descriptors, payload)
    latest_event = latest_camera_event(matched_events)

    %{}
    |> maybe_put(
      :availability_status,
      event_availability_status(latest_event) || status_availability(status, payload)
    )
    |> maybe_put(
      :availability_reason,
      event_availability_reason(latest_event) || status_availability_reason(payload)
    )
    |> maybe_put(:last_activity_at, event_time(latest_event))
    |> maybe_put(:last_event_at, event_time(latest_event))
    |> maybe_put(:last_event_type, event_type(latest_event))
    |> maybe_put(:last_event_message, event_message(latest_event, observed_at))
  end

  defp matching_camera_events(descriptor, descriptors, payload) do
    events = extract_events(payload)

    cond do
      events == [] ->
        []

      length(descriptors) == 1 ->
        events

      true ->
        Enum.filter(events, &camera_event_matches_descriptor?(&1, descriptor))
    end
  end

  defp extract_events(payload) when is_map(payload) do
    payload
    |> list_value(["events"])
    |> Enum.filter(&is_map/1)
  end

  defp latest_camera_event(events) when is_list(events) do
    Enum.max_by(events, &event_sort_key/1, fn -> nil end)
  end

  defp camera_event_matches_descriptor?(event, descriptor)
       when is_map(event) and is_map(descriptor) do
    device = map_value(event, ["device"]) || %{}
    unmapped = map_value(event, ["unmapped"]) || %{}

    identities =
      Enum.reject(
        [
          string_value(device, ["uid", "device_uid", "deviceUid"]),
          string_value(device, ["name", "camera_id", "cameraId"]),
          string_value(unmapped, [
            "camera_source_id",
            "camera_device_uid",
            "camera_id",
            "cameraId"
          ])
        ],
        &blank?/1
      )

    device_uid =
      string_value(descriptor, [
        "device_uid",
        "deviceUid",
        "device_id",
        "deviceId",
        "canonical_device_id",
        "canonicalDeviceId",
        "uid"
      ])

    vendor_camera_id =
      string_value(descriptor, [
        "vendor_camera_id",
        "vendorCameraId",
        "camera_id",
        "cameraId",
        "id"
      ])

    Enum.any?(identities, &(&1 in [device_uid, vendor_camera_id]))
  end

  defp event_sort_key(event) do
    event
    |> event_time()
    |> case do
      %DateTime{} = dt -> DateTime.to_unix(dt, :microsecond)
      _ -> 0
    end
  end

  defp event_time(nil), do: nil

  defp event_time(event) when is_map(event) do
    event
    |> value(["time", "observed_at", "observedAt"])
    |> case do
      nil -> nil
      value -> DateTime.truncate(FieldParser.parse_timestamp(value), :microsecond)
    end
  end

  defp event_type(nil), do: nil

  defp event_type(event) when is_map(event) do
    event_topic(event) ||
      string_value(event, ["activity_name", "activityName", "type_name", "typeName"]) ||
      string_value(event, ["message"])
  end

  defp event_message(nil, _observed_at), do: nil

  defp event_message(event, observed_at) when is_map(event) do
    string_value(event, ["message"]) ||
      event_topic(event) ||
      "Camera activity observed at #{DateTime.to_iso8601(observed_at)}"
  end

  defp event_topic(event) when is_map(event) do
    event
    |> map_value(["unmapped"])
    |> case do
      nil ->
        nil

      unmapped ->
        unmapped
        |> map_value(["axis_ws_payload"])
        |> case do
          nil ->
            nil

          axis_payload ->
            axis_payload
            |> value(["params"])
            |> map_value(["notification"])
            |> string_value(["topic"])
        end
    end
  end

  defp event_availability_status(nil), do: nil

  defp event_availability_status(event) when is_map(event) do
    text =
      [event_topic(event), string_value(event, ["message", "status", "status_detail"])]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
      |> String.downcase()

    cond do
      text == "" ->
        nil

      String.contains?(text, [
        "video lost",
        "videolost",
        "offline",
        "disconnect",
        "unavailable",
        "signal lost"
      ]) ->
        "unavailable"

      String.contains?(text, ["restored", "online", "reconnect", "connected", "available"]) ->
        "available"

      String.contains?(text, ["warning", "degraded", "tamper"]) ->
        "degraded"

      true ->
        nil
    end
  end

  defp event_availability_reason(nil), do: nil

  defp event_availability_reason(event) when is_map(event) do
    string_value(event, ["message", "status_detail"]) || event_topic(event)
  end

  defp status_availability(status, payload) do
    normalized_status_availability(status) ||
      case string_value(payload, ["status"]) do
        "OK" -> "available"
        "WARNING" -> "degraded"
        "CRITICAL" -> "unavailable"
        "UNKNOWN" -> "unavailable"
        _ -> nil
      end
  end

  defp normalized_status_availability(%{available: value}) when is_boolean(value),
    do: Map.fetch!(@status_availability_labels, value)

  defp normalized_status_availability(status) when is_map(status), do: nil
  defp normalized_status_availability(_status), do: nil

  defp status_availability_reason(payload) do
    string_value(payload, ["summary", "message"]) ||
      payload
      |> details_payload()
      |> string_value(["collection_error"])
  end

  defp resolve_observed_at(payload, status) do
    candidate =
      value(payload, ["observed_at", "observedAt"]) ||
        status[:agent_timestamp] ||
        status[:timestamp]

    case candidate do
      %DateTime{} = dt ->
        DateTime.truncate(dt, :microsecond)

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _offset} -> DateTime.truncate(dt, :microsecond)
          _ -> DateTime.truncate(DateTime.utc_now(), :microsecond)
        end

      _ ->
        DateTime.truncate(DateTime.utc_now(), :microsecond)
    end
  end

  defp value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key) || Map.get(map, to_string(key))
    end)
  end

  defp value(_map, _keys), do: nil

  defp details_payload(payload) when is_map(payload) do
    case value(payload, ["details"]) do
      value when is_map(value) ->
        value

      value when is_binary(value) ->
        case Jason.decode(value) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp details_payload_or_self(payload) when is_map(payload) do
    details_payload(payload) || payload
  end

  defp string_value(map, keys) do
    case value(map, keys) do
      nil -> nil
      value when is_binary(value) -> String.trim(value)
      value when is_atom(value) -> Atom.to_string(value)
      value when is_integer(value) -> Integer.to_string(value)
      _ -> nil
    end
  end

  defp map_value(map, keys) do
    case value(map, keys) do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  defp list_value(map, keys) do
    case value(map, keys) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp boolean_value(map, keys, default) do
    case value(map, keys) do
      nil -> default
      value when is_boolean(value) -> value
      "true" -> true
      "false" -> false
      _ -> default
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false

  defp infer_axis_camera_descriptors(details) do
    if axis_details?(details) do
      case build_axis_descriptor(details) do
        nil -> []
        descriptor -> [descriptor]
      end
    else
      []
    end
  end

  defp axis_details?(details) do
    metadata = map_value(details, ["metadata"]) || %{}
    enrichment = map_value(details, ["device_enrichment", "enrichment"]) || %{}
    camera = map_value(enrichment, ["camera"]) || %{}

    plugin_id = string_value(metadata, ["plugin"])
    vendor = string_value(camera, ["vendor"])

    cond do
      plugin_id == "axis-camera" -> true
      String.upcase(vendor || "") == "AXIS" -> true
      true -> false
    end
  end

  defp build_axis_descriptor(details) do
    host = string_value(details, ["camera_host"])
    device_info = map_value(details, ["device_info"]) || %{}
    streams = list_value(details, ["streams"])

    device_uid =
      first_present([
        string_value(device_info, ["S.Nbr", "SerialNumber", "Serial"]),
        string_value(device_info, ["MACAddress", "Network.HWaddress", "root.Network.HWaddress"]),
        host
      ])

    vendor_camera_id =
      first_present([
        string_value(device_info, ["S.Nbr", "SerialNumber", "Serial"]),
        host
      ])

    if blank?(device_uid) or blank?(vendor_camera_id) do
      nil
    else
      %{
        "device_uid" => device_uid,
        "vendor" => "axis",
        "camera_id" => vendor_camera_id,
        "display_name" =>
          first_present([
            string_value(device_info, ["ProductFullName", "ProdNbr", "Brand"]),
            host
          ]),
        "source_url" => first_stream_url(streams),
        "stream_profiles" => Enum.map(streams, &axis_profile_descriptor/1)
      }
    end
  end

  defp axis_profile_descriptor(stream) when is_map(stream) do
    url = string_value(stream, ["url"])

    %{
      "profile_name" => first_present([string_value(stream, ["id"]), "default"]),
      "vendor_profile_id" => string_value(stream, ["id"]),
      "source_url_override" => url,
      "rtsp_transport" => "tcp",
      "codec_hint" => codec_from_rtsp_url(url)
    }
  end

  defp axis_profile_descriptor(_stream), do: %{}

  defp extract_enrichment_camera_descriptors(details) when is_map(details) do
    enrichment = map_value(details, ["device_enrichment", "enrichment"]) || %{}

    case build_enrichment_descriptor(details, enrichment) do
      nil -> []
      descriptor -> [descriptor]
    end
  end

  defp build_enrichment_descriptor(details, enrichment)
       when is_map(details) and is_map(enrichment) do
    identity = map_value(enrichment, ["identity"]) || %{}
    camera = map_value(enrichment, ["camera"]) || %{}
    source = map_value(enrichment, ["source"]) || %{}
    streams = list_value(enrichment, ["streams"])

    vendor =
      camera
      |> string_value(["vendor"])
      |> case do
        nil -> nil
        value -> String.downcase(value)
      end

    vendor_camera_id =
      first_present([
        string_value(camera, ["camera_id", "cameraId", "id"]),
        string_value(source, ["camera_id", "cameraId"]),
        string_value(identity, ["serial"]),
        string_value(identity, ["mac"]),
        string_value(source, ["camera_host", "cameraHost"]),
        string_value(details, ["camera_host", "cameraHost"])
      ])

    explicit_device_uid =
      first_present([
        string_value(enrichment, [
          "device_uid",
          "deviceUid",
          "canonical_device_id",
          "canonicalDeviceId"
        ]),
        string_value(source, [
          "device_uid",
          "deviceUid",
          "canonical_device_id",
          "canonicalDeviceId"
        ]),
        string_value(identity, [
          "device_uid",
          "deviceUid",
          "canonical_device_id",
          "canonicalDeviceId"
        ])
      ])

    if blank?(vendor) or blank?(vendor_camera_id) do
      nil
    else
      %{
        "device_uid" => explicit_device_uid,
        "vendor" => vendor,
        "camera_id" => vendor_camera_id,
        "display_name" =>
          first_present([
            string_value(camera, ["display_name", "displayName", "name", "model"]),
            string_value(source, ["camera_host", "cameraHost"]),
            string_value(details, ["camera_host", "cameraHost"])
          ]),
        "source_url" => first_stream_url(streams),
        "stream_profiles" => Enum.map(streams, &generic_profile_descriptor/1),
        "identity" => identity,
        "camera" => camera,
        "source" => source,
        "metadata" =>
          %{
            "camera_host" =>
              first_present([
                string_value(source, ["camera_host", "cameraHost"]),
                string_value(details, ["camera_host", "cameraHost"])
              ]),
            "plugin_id" => string_value(source, ["plugin_id", "pluginId"]),
            "device_enrichment" => enrichment
          }
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)
          |> Map.new()
      }
    end
  end

  defp build_enrichment_descriptor(_details, _enrichment), do: nil

  defp generic_profile_descriptor(stream) when is_map(stream) do
    url = string_value(stream, ["url", "source_url", "sourceUrl", "rtsp_url", "rtspUrl"])

    metadata =
      %{
        "auth_mode" => string_value(stream, ["auth_mode", "authMode"]),
        "credential_reference_id" =>
          string_value(stream, ["credential_reference_id", "credentialReferenceId"]),
        "source" => string_value(stream, ["source"]),
        "protocol" => string_value(stream, ["protocol"])
      }
      |> Enum.reject(fn {_key, value} -> blank?(value) end)
      |> Map.new()

    %{
      "profile_name" =>
        first_present([
          string_value(stream, ["profile_name", "profileName", "name", "id"]),
          "default"
        ]),
      "vendor_profile_id" =>
        string_value(stream, [
          "vendor_profile_id",
          "vendorProfileId",
          "profile_id",
          "profileId",
          "id"
        ]),
      "source_url_override" => url,
      "rtsp_transport" =>
        first_present([
          string_value(stream, ["rtsp_transport", "rtspTransport", "transport"]),
          if(is_binary(url) and String.starts_with?(String.downcase(url), "rtsp"), do: "tcp")
        ]),
      "codec_hint" =>
        first_present([
          string_value(stream, ["codec_hint", "codecHint", "codec"]),
          codec_from_rtsp_url(url)
        ]),
      "metadata" => normalize_profile_metadata(metadata)
    }
  end

  defp generic_profile_descriptor(_stream), do: %{}

  defp resolve_descriptor_device_uid(descriptor, status, actor, resolve_device_uid)
       when is_map(descriptor) and is_function(resolve_device_uid, 3) do
    explicit_uid = descriptor_device_uid(descriptor)

    case resolve_device_uid.(descriptor, status, actor) do
      value when is_binary(value) and value != "" ->
        cond do
          blank?(explicit_uid) ->
            Map.put(descriptor, "device_uid", value)

          value == explicit_uid ->
            descriptor

          IdentityReconciler.serviceradar_uuid?(value) ->
            Map.put(descriptor, "device_uid", value)

          true ->
            descriptor
        end

      _ ->
        descriptor
    end
  end

  defp descriptor_device_uid(descriptor) when is_map(descriptor) do
    string_value(descriptor, [
      "device_uid",
      "deviceUid",
      "device_id",
      "deviceId",
      "canonical_device_id",
      "canonicalDeviceId",
      "uid"
    ])
  end

  defp default_resolve_device_uid(descriptor, status, actor) do
    case resolve_identity_from_hints(descriptor, status, actor) do
      {:ok, uid} when is_binary(uid) and uid != "" -> uid
      _ -> nil
    end
  end

  defp resolve_identity_from_hints(descriptor, _status, actor) when is_map(descriptor) do
    with {:error, _reason} <- lookup_device_uid_from_existing_source(descriptor, actor),
         {:ok, update} <- identity_update_from_descriptor(descriptor) do
      update
      |> IdentityReconciler.extract_strong_identifiers()
      |> resolve_camera_identity(update, descriptor, actor)
    else
      {:ok, uid} -> {:ok, uid}
      _ -> lookup_device_by_hostname(descriptor_hostname(descriptor), actor)
    end
  end

  defp resolve_identity_from_hints(_descriptor, _status, _actor), do: {:error, :unresolved}

  defp resolve_camera_identity(ids, update, descriptor, actor) when is_map(update) do
    if IdentityReconciler.has_strong_identifier?(ids) do
      resolve_strong_camera_identity(ids)
    else
      resolve_weak_camera_identity(update, descriptor, actor)
    end
  end

  defp lookup_device_uid_from_existing_source(descriptor, actor) when is_map(descriptor) do
    vendor = string_value(descriptor, ["vendor"])
    vendor_camera_id = descriptor_vendor_camera_id(descriptor)

    if blank?(vendor) or blank?(vendor_camera_id) do
      {:error, :not_found}
    else
      Source
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(vendor == ^vendor and vendor_camera_id == ^vendor_camera_id)
      |> Ash.Query.limit(1)
      |> Ash.read(actor: actor)
      |> Page.unwrap()
      |> case do
        {:ok, [%Source{device_uid: device_uid} | _]}
        when is_binary(device_uid) and device_uid != "" ->
          {:ok, device_uid}

        _ ->
          {:error, :not_found}
      end
    end
  end

  defp resolve_strong_camera_identity(ids) when is_map(ids) do
    case IdentityReconciler.lookup_by_strong_identifiers(ids, nil) do
      {:ok, uid} when is_binary(uid) and uid != "" ->
        {:ok, uid}

      _ ->
        {:ok, IdentityReconciler.generate_deterministic_device_id(ids)}
    end
  end

  defp resolve_weak_camera_identity(update, descriptor, actor) when is_map(update) do
    with {:ok, uid} <- IdentityReconciler.resolve_device_id(update, actor: actor),
         true <- is_binary(uid) and uid != "" do
      {:ok, uid}
    else
      _ -> lookup_device_by_hostname(descriptor_hostname(descriptor), actor)
    end
  end

  defp identity_update_from_descriptor(descriptor) do
    mac = descriptor_mac(descriptor)
    ip = descriptor_ip(descriptor)
    integration_id = descriptor_integration_id(descriptor)

    if blank?(mac) and blank?(ip) and blank?(integration_id) do
      {:error, :no_identity_hints}
    else
      {:ok,
       %{
         device_id: nil,
         ip: ip,
         mac: mac,
         partition: "default",
         metadata:
           %{}
           |> maybe_put("integration_id", integration_id)
           |> maybe_put(
             "integration_type",
             if(blank?(integration_id), do: nil, else: "camera_plugin")
           )
       }}
    end
  end

  defp descriptor_hostname(descriptor) when is_map(descriptor) do
    metadata = map_value(descriptor, ["metadata"]) || %{}
    source = map_value(descriptor, ["source"]) || %{}

    first_present([
      string_value(source, ["camera_host", "cameraHost", "hostname", "host"]),
      string_value(metadata, ["camera_host", "cameraHost", "hostname", "host"])
    ])
  end

  defp descriptor_mac(descriptor) when is_map(descriptor) do
    descriptor
    |> map_value(["identity"])
    |> case do
      nil ->
        descriptor_mac_fallback(descriptor)

      identity ->
        first_present([
          string_value(identity, ["mac"]),
          descriptor_mac_fallback(descriptor)
        ])
    end
  end

  defp descriptor_mac_fallback(descriptor) when is_map(descriptor) do
    case descriptor_device_uid(descriptor) do
      value when is_binary(value) and value != "" ->
        if mac_like?(value), do: value

      _ ->
        nil
    end
  end

  defp descriptor_ip(descriptor) when is_map(descriptor) do
    candidate =
      first_present([
        string_value(descriptor, ["ip", "ip_address", "ipAddress"]),
        descriptor_hostname(descriptor)
      ])

    if ip_address?(candidate), do: candidate
  end

  defp descriptor_integration_id(descriptor) when is_map(descriptor) do
    identity = map_value(descriptor, ["identity"]) || %{}
    vendor = string_value(descriptor, ["vendor"])
    serial = string_value(identity, ["serial"])

    cond do
      not blank?(string_value(identity, ["integration_id", "integrationId"])) ->
        string_value(identity, ["integration_id", "integrationId"])

      not blank?(serial) and not blank?(vendor) ->
        "#{vendor}:serial:#{serial}"

      true ->
        nil
    end
  end

  defp normalize_profile_metadata(metadata) when is_map(metadata) do
    auth_mode =
      metadata
      |> string_value(["auth_mode", "authMode"])
      |> normalize_auth_mode()

    credential_reference_id =
      metadata
      |> string_value(["credential_reference_id", "credentialReferenceId"])
      |> case do
        value when auth_mode in ["basic", "digest", "unknown"] -> value
        _ -> nil
      end

    metadata
    |> maybe_put("auth_mode", auth_mode)
    |> maybe_put("credential_reference_id", credential_reference_id)
  end

  defp normalize_profile_metadata(_metadata), do: %{}

  defp normalize_auth_mode(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "none" -> "none"
      "basic" -> "basic"
      "digest" -> "digest"
      "unknown" -> "unknown"
      _ -> "unknown"
    end
  end

  defp normalize_auth_mode(_value), do: nil

  defp lookup_device_by_hostname(nil, _actor), do: {:error, :not_found}
  defp lookup_device_by_hostname("", _actor), do: {:error, :not_found}

  defp lookup_device_by_hostname(hostname, actor) do
    query =
      Device
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(hostname == ^hostname)
      |> Ash.Query.limit(1)

    case Ash.read(query, actor: actor) do
      {:ok, [%{uid: uid} | _]} when is_binary(uid) and uid != "" -> {:ok, uid}
      _ -> {:error, :not_found}
    end
  end

  defp ip_address?(value) when is_binary(value) do
    case :inet.parse_address(String.to_charlist(String.trim(value))) do
      {:ok, _address} -> true
      _ -> false
    end
  end

  defp ip_address?(_value), do: false

  defp mac_like?(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.replace(":", "")
      |> String.replace("-", "")

    byte_size(normalized) == 12 and String.match?(normalized, ~r/\A[0-9A-Fa-f]{12}\z/)
  end

  defp first_stream_url(streams) do
    Enum.find_value(streams, fn stream ->
      string_value(stream, ["url", "source_url", "sourceUrl", "rtsp_url", "rtspUrl"])
    end)
  end

  defp codec_from_rtsp_url(nil), do: nil

  defp codec_from_rtsp_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{query: nil} ->
        nil

      %URI{query: query} ->
        query
        |> URI.decode_query()
        |> Map.get("videocodec")
    end
  end

  defp first_present(values) do
    Enum.find_value(values, fn value ->
      if blank?(value), do: nil, else: value
    end)
  end
end
