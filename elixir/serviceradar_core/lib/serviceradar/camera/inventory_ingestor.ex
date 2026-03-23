defmodule ServiceRadar.Camera.InventoryIngestor do
  @moduledoc """
  Ingests camera discovery descriptors from plugin results into normalized inventory.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.StreamProfile

  require Logger

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
    actor = Keyword.get(opts, :actor, SystemActor.system(:camera_inventory_ingestor))
    observed_at = Keyword.get(opts, :observed_at) || resolve_observed_at(payload, status)
    source_upsert = Keyword.get(opts, :source_upsert, &upsert_source/2)
    profile_upsert = Keyword.get(opts, :profile_upsert, &upsert_profile/2)

    payload
    |> extract_camera_descriptors()
    |> Enum.reduce_while(:ok, fn descriptor, :ok ->
      case ingest_descriptor(
             descriptor,
             status,
             observed_at,
             actor,
             source_upsert,
             profile_upsert
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def ingest(_payload, _status, _opts), do: :ok

  defp ingest_descriptor(descriptor, status, observed_at, actor, source_upsert, profile_upsert) do
    with {:ok, source_attrs} <- normalize_source(descriptor, status),
         {:ok, source_record} <- source_upsert.(source_attrs, actor) do
      descriptor
      |> normalize_profiles(observed_at)
      |> Enum.reduce_while(:ok, fn profile_attrs, :ok ->
        attrs = Map.put(profile_attrs, :camera_source_id, source_record.id)

        case profile_upsert.(attrs, actor) do
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

  defp normalize_source(descriptor, status) when is_map(descriptor) do
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
      {:ok,
       %{
         device_uid: device_uid,
         vendor: vendor,
         vendor_camera_id: vendor_camera_id,
         display_name: string_value(descriptor, ["display_name", "displayName", "name"]),
         source_url: string_value(descriptor, ["source_url", "sourceUrl", "rtsp_url", "rtspUrl"]),
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
       }}
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
        metadata: map_value(profile, ["metadata"]) || %{}
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

  defp extract_camera_descriptors(payload) when is_map(payload) do
    direct_descriptors =
      payload
      |> list_value(["camera_descriptors", "cameraDescriptors", "cameras"])
      |> Enum.filter(&is_map/1)

    if direct_descriptors == [] do
      payload
      |> details_payload()
      |> extract_details_camera_descriptors()
    else
      direct_descriptors
    end
  end

  defp extract_camera_descriptors(_payload), do: []

  defp extract_details_camera_descriptors(details) when is_map(details) do
    detail_descriptors =
      details
      |> list_value(["camera_descriptors", "cameraDescriptors", "cameras"])
      |> Enum.filter(&is_map/1)

    if detail_descriptors == [] do
      infer_axis_camera_descriptors(details)
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

  defp details_payload(_payload), do: nil

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

    plugin_id == "axis-camera" or String.upcase(vendor || "") == "AXIS"
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

  defp first_stream_url(streams) do
    Enum.find_value(streams, fn stream ->
      string_value(stream, ["url"])
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
