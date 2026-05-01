defmodule ServiceRadar.Camera.EventIngestor do
  @moduledoc """
  Persists camera-originated plugin events and correlates them to normalized
  camera inventory when the plugin payload includes camera descriptors.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.InventoryIngestor
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Events.PubSub, as: EventsPubSub
  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.Monitoring.OcsfEvent

  require Ash.Query
  require Logger

  @spec supports?(map() | list(), map()) :: boolean()
  def supports?(payload, status \\ %{})

  def supports?(payload, status) when is_list(payload) do
    Enum.any?(payload, &supports?(&1, status))
  end

  def supports?(payload, _status) when is_map(payload) do
    payload
    |> extract_events()
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
    actor = Keyword.get(opts, :actor, SystemActor.system(:camera_event_ingestor))
    observed_at = Keyword.get(opts, :observed_at) || resolve_observed_at(payload, status)
    record_event = Keyword.get(opts, :record_event, &record_event/2)
    load_source = Keyword.get(opts, :load_source, &load_source/2)

    payload
    |> extract_events()
    |> Enum.reduce_while(0, fn event, count ->
      correlation = resolve_event_correlation(event, payload, actor, load_source)
      attrs = build_event_attrs(event, correlation, observed_at, status)

      case record_event.(attrs, actor) do
        {:ok, _record} ->
          {:cont, count + 1}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      count when is_integer(count) and count > 0 ->
        EventsPubSub.broadcast_event(%{count: count})
        :ok

      0 ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("Camera event ingest failed: #{inspect(e)}")
      {:error, e}
  end

  def ingest(_payload, _status, _opts), do: :ok

  defp extract_events(payload) when is_map(payload) do
    payload
    |> Map.get("events", Map.get(payload, :events, []))
    |> case do
      events when is_list(events) -> Enum.filter(events, &is_map/1)
      _ -> []
    end
  end

  defp build_event_attrs(event, correlation, observed_at, status) do
    severity_id = event_severity_id(event)
    metadata = event_metadata_value(event, correlation, status, observed_at)

    event
    |> event_identity_attrs(observed_at)
    |> Map.merge(event_status_attrs(event, severity_id))
    |> Map.merge(event_payload_attrs(event, correlation, metadata))
  end

  defp resolve_event_correlation(event, payload, actor, load_source) do
    descriptors = InventoryIngestor.extract_camera_descriptors(payload)

    descriptor =
      case descriptors do
        [single] ->
          single

        many ->
          Enum.find(many, &event_matches_descriptor?(&1, event))
      end

    case descriptor do
      nil -> nil
      descriptor -> load_source.(descriptor, actor)
    end
  end

  defp load_source(descriptor, actor) when is_map(descriptor) do
    with {:ok, vendor, vendor_camera_id} <- descriptor_filters(descriptor),
         {:ok, source} <- read_source(vendor, vendor_camera_id, actor) do
      build_source_correlation(source)
    else
      _ -> nil
    end
  end

  defp event_matches_descriptor?(descriptor, event) when is_map(descriptor) and is_map(event) do
    descriptor_identities = descriptor_identities(descriptor)

    event
    |> event_candidate_values()
    |> Enum.any?(&(&1 in descriptor_identities))
  end

  defp event_time(event, observed_at) do
    event["time"] ||
      case event[:time] do
        nil -> observed_at
        value -> DateTime.truncate(FieldParser.parse_timestamp(value), :microsecond)
      end
  end

  defp enrich_metadata(metadata, nil, status, observed_at) do
    metadata
    |> Map.put_new("gateway_id", status[:gateway_id])
    |> Map.put_new("agent_id", status[:agent_id])
    |> Map.put_new("observed_at", DateTime.to_iso8601(observed_at))
  end

  defp enrich_metadata(metadata, correlation, status, observed_at) do
    metadata
    |> Map.put("camera_source_id", correlation.source_id)
    |> Map.put("camera_device_uid", correlation.device_uid)
    |> Map.put("camera_vendor", correlation.vendor)
    |> Map.put("camera_vendor_camera_id", correlation.vendor_camera_id)
    |> Map.put("camera_stream_profile_ids", correlation.stream_profile_ids)
    |> Map.put("camera_stream_profile_names", correlation.stream_profile_names)
    |> Map.put("assigned_agent_id", correlation.assigned_agent_id || status[:agent_id])
    |> Map.put("assigned_gateway_id", correlation.assigned_gateway_id || status[:gateway_id])
    |> Map.put("observed_at", DateTime.to_iso8601(observed_at))
  end

  defp enrich_device(device, nil), do: device

  defp enrich_device(device, correlation) do
    device
    |> Map.put_new("uid", correlation.device_uid)
    |> Map.put_new("name", correlation.display_name)
    |> Map.put_new("type", "camera")
  end

  defp enrich_unmapped(unmapped, nil), do: unmapped

  defp enrich_unmapped(unmapped, correlation) do
    unmapped
    |> Map.put("camera_source_id", correlation.source_id)
    |> Map.put("camera_device_uid", correlation.device_uid)
    |> Map.put("camera_vendor_camera_id", correlation.vendor_camera_id)
  end

  defp record_event(attrs, actor) do
    OcsfEvent
    |> Ash.Changeset.for_create(:record, attrs, actor: actor)
    |> Ash.create()
  end

  defp resolve_observed_at(payload, status) do
    payload
    |> Map.get("observed_at", Map.get(payload, :observed_at))
    |> case do
      nil -> status[:agent_timestamp] || status[:timestamp]
      value -> value
    end
    |> FieldParser.parse_timestamp()
    |> DateTime.truncate(:microsecond)
  end

  defp parse_int(value) when is_integer(value), do: value
  defp parse_int(value) when is_float(value), do: trunc(value)

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp parse_int(_value), do: nil

  defp event_id(event), do: parse_string(event["id"] || event[:id]) || Ash.UUID.generate()
  defp event_severity_id(event), do: parse_int(event["severity_id"] || event[:severity_id]) || 1

  defp event_class_uid(event), do: parse_int(event["class_uid"] || event[:class_uid]) || 1008

  defp event_category_uid(event),
    do: parse_int(event["category_uid"] || event[:category_uid]) || 1

  defp event_type_uid(event), do: parse_int(event["type_uid"] || event[:type_uid]) || 100_801
  defp event_activity_id(event), do: parse_int(event["activity_id"] || event[:activity_id]) || 1

  defp event_activity_name(event),
    do: parse_string(event["activity_name"] || event[:activity_name])

  defp event_severity_name(event, severity_id),
    do: parse_string(event["severity"] || event[:severity]) || severity_name(severity_id)

  defp event_message_text(event),
    do:
      parse_string(event["message"] || event[:message]) ||
        parse_string(event["status_detail"] || event[:status_detail])

  defp event_status_id(event), do: parse_int(event["status_id"] || event[:status_id])
  defp event_status(event), do: parse_string(event["status"] || event[:status])
  defp event_status_code(event), do: parse_string(event["status_code"] || event[:status_code])

  defp event_status_detail(event),
    do: parse_string(event["status_detail"] || event[:status_detail])

  defp event_log_name(event),
    do: parse_string(event["log_name"] || event[:log_name]) || "events.ocsf.processed"

  defp event_log_level(event), do: parse_string(event["log_level"] || event[:log_level])
  defp event_log_version(event), do: parse_string(event["log_version"] || event[:log_version])

  defp event_log_provider(event, correlation) do
    parse_string(event["log_provider"] || event[:log_provider]) ||
      Map.get(correlation || %{}, :plugin_id) ||
      "serviceradar-plugin"
  end

  defp event_identity_attrs(event, observed_at) do
    %{
      id: event_id(event),
      time: event_time(event, observed_at),
      class_uid: event_class_uid(event),
      category_uid: event_category_uid(event),
      type_uid: event_type_uid(event),
      activity_id: event_activity_id(event),
      activity_name: event_activity_name(event)
    }
  end

  defp event_status_attrs(event, severity_id) do
    %{
      severity_id: severity_id,
      severity: event_severity_name(event, severity_id),
      message: event_message_text(event),
      status_id: event_status_id(event),
      status: event_status(event),
      status_code: event_status_code(event),
      status_detail: event_status_detail(event)
    }
  end

  defp event_payload_attrs(event, correlation, metadata) do
    %{
      metadata: metadata,
      observables: encoded_event_value(event, "observables", :observables, []),
      trace_id: parse_string(event["trace_id"] || event[:trace_id]),
      span_id: parse_string(event["span_id"] || event[:span_id]),
      actor: encoded_event_value(event, "actor", :actor, %{}),
      device: enrich_device(encoded_event_value(event, "device", :device, %{}), correlation),
      src_endpoint: encoded_event_value(event, "src_endpoint", :src_endpoint, %{}),
      dst_endpoint: encoded_event_value(event, "dst_endpoint", :dst_endpoint, %{}),
      log_name: event_log_name(event),
      log_provider: event_log_provider(event, correlation),
      log_level: event_log_level(event),
      log_version: event_log_version(event),
      unmapped:
        enrich_unmapped(encoded_event_value(event, "unmapped", :unmapped, %{}), correlation),
      raw_data: parse_string(event["raw_data"] || event[:raw_data]) || Jason.encode!(event)
    }
  end

  defp event_metadata_value(event, correlation, status, observed_at) do
    event
    |> encoded_event_value("metadata", :metadata, %{})
    |> enrich_metadata(correlation, status, observed_at)
  end

  defp encoded_event_value(event, string_key, atom_key, default) do
    FieldParser.encode_jsonb(Map.get(event, string_key, Map.get(event, atom_key))) || default
  end

  defp descriptor_filters(descriptor) do
    with vendor when is_binary(vendor) <- descriptor_string(descriptor, ["vendor"]),
         vendor_camera_id when is_binary(vendor_camera_id) <-
           descriptor_string(descriptor, [
             "vendor_camera_id",
             "vendorCameraId",
             "camera_id",
             "cameraId",
             "id"
           ]) do
      {:ok, vendor, vendor_camera_id}
    else
      _ -> :error
    end
  end

  defp read_source(vendor, vendor_camera_id, actor) do
    query =
      Source
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(vendor == ^vendor and vendor_camera_id == ^vendor_camera_id)
      |> Ash.Query.load([:stream_profiles])

    case Ash.read(query, actor: actor) do
      {:ok, [source | _]} -> {:ok, source}
      _ -> :error
    end
  end

  defp build_source_correlation(source) do
    %{
      source_id: source.id,
      device_uid: source.device_uid,
      display_name: source.display_name || source.vendor_camera_id || source.device_uid,
      vendor: source.vendor,
      vendor_camera_id: source.vendor_camera_id,
      assigned_agent_id: source.assigned_agent_id,
      assigned_gateway_id: source.assigned_gateway_id,
      stream_profile_ids: Enum.map(source.stream_profiles || [], & &1.id),
      stream_profile_names: Enum.map(source.stream_profiles || [], & &1.profile_name),
      plugin_id: plugin_id(source.metadata)
    }
  end

  defp plugin_id(metadata) when is_map(metadata), do: Map.get(metadata, "plugin_id")
  defp plugin_id(_metadata), do: nil

  defp event_candidate_values(event) do
    event_device = FieldParser.encode_jsonb(event["device"] || event[:device]) || %{}
    event_unmapped = FieldParser.encode_jsonb(event["unmapped"] || event[:unmapped]) || %{}

    Enum.reject(
      [
        parse_string(event_device["uid"] || event_device[:uid]),
        parse_string(event_device["name"] || event_device[:name]),
        parse_string(event_unmapped["camera_device_uid"] || event_unmapped[:camera_device_uid]),
        parse_string(event_unmapped["camera_id"] || event_unmapped[:camera_id])
      ],
      &blank?/1
    )
  end

  defp descriptor_identities(descriptor) do
    Enum.reject(
      [
        descriptor_string(descriptor, ["device_uid", "deviceUid", "device_id", "deviceId", "uid"]),
        descriptor_string(descriptor, [
          "vendor_camera_id",
          "vendorCameraId",
          "camera_id",
          "cameraId",
          "id"
        ])
      ],
      &blank?/1
    )
  end

  defp parse_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp parse_string(nil), do: nil
  defp parse_string(value) when is_atom(value), do: Atom.to_string(value)
  defp parse_string(_value), do: nil

  defp descriptor_string(descriptor, keys) do
    Enum.find_value(keys, fn key ->
      descriptor
      |> Map.get(key, Map.get(descriptor, to_string(key)))
      |> parse_string()
    end)
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false

  defp severity_name(0), do: "Unknown"
  defp severity_name(1), do: "Informational"
  defp severity_name(2), do: "Low"
  defp severity_name(3), do: "Medium"
  defp severity_name(4), do: "High"
  defp severity_name(5), do: "Critical"
  defp severity_name(6), do: "Fatal"
  defp severity_name(_), do: "Unknown"
end
