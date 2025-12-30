defmodule ServiceRadar.EventWriter.Processors.Logs do
  @moduledoc """
  Processor for log messages in OCSF Event Log Activity format.

  Parses logs from NATS JetStream and inserts them into the `ocsf_events`
  hypertable using OCSF v1.7.0 Event Log Activity schema (class_uid: 1008).

  ## OCSF Classification

  - Category: System Activity (category_uid: 1)
  - Class: Event Log Activity (class_uid: 1008)
  - Activity: 1=Create, 2=Read, 3=Update, 4=Delete

  ## Severity Mapping

  OCSF severity_id values:
  - 0: Unknown
  - 1: Informational (TRACE, DEBUG, INFO)
  - 2: Low
  - 3: Medium (WARN)
  - 4: High (ERROR)
  - 5: Critical
  - 6: Fatal (FATAL)

  ## Message Format

  Supports both JSON and OpenTelemetry log formats, mapping them to OCSF schema.
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.EventWriter.FieldParser

  require Logger

  # OCSF constants
  @category_uid_system_activity 1
  @class_uid_event_log_activity 1008
  @activity_id_create 1

  # Severity mappings
  @severity_unknown 0
  @severity_informational 1
  @severity_low 2
  @severity_medium 3
  @severity_high 4
  @severity_critical 5
  @severity_fatal 6

  @impl true
  def table_name, do: "ocsf_events"

  @impl true
  def process_batch(messages) do
    rows =
      messages
      |> Enum.map(&parse_message/1)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(rows) do
      {:ok, 0}
    else
      case ServiceRadar.Repo.insert_all(table_name(), rows,
             on_conflict: :nothing,
             returning: false
           ) do
        {count, _} ->
          {:ok, count}
      end
    end
  rescue
    e ->
      Logger.error("OCSF events batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(%{data: data, metadata: metadata}) do
    case Jason.decode(data) do
      {:ok, json} ->
        parse_json_log(json, metadata)

      {:error, _} ->
        # Try protobuf parsing (future support)
        parse_protobuf_log(data, metadata)
    end
  end

  # Private functions

  defp parse_json_log(json, metadata) do
    time = FieldParser.parse_timestamp(json["timestamp"] || json["time_unix_nano"] || json["time"])
    severity_id = map_severity(json)
    activity_id = @activity_id_create

    # Calculate type_uid: class_uid * 100 + activity_id
    type_uid = @class_uid_event_log_activity * 100 + activity_id

    %{
      # Primary key components
      id: UUID.uuid4(),
      time: time,

      # OCSF Classification (required)
      class_uid: @class_uid_event_log_activity,
      category_uid: @category_uid_system_activity,
      type_uid: type_uid,
      activity_id: activity_id,
      severity_id: severity_id,

      # Content
      message: extract_message(json),
      severity: severity_name(severity_id),
      activity_name: "Create",

      # Status
      status_id: 1,
      status: "Success",
      status_code: nil,
      status_detail: nil,

      # OCSF Metadata
      metadata: build_metadata(json, metadata),

      # Observables
      observables: build_observables(json),

      # OpenTelemetry trace context
      trace_id: FieldParser.get_field(json, "trace_id", "traceId"),
      span_id: FieldParser.get_field(json, "span_id", "spanId"),

      # Actor/Source
      actor: build_actor(json),
      device: build_device(json),
      src_endpoint: build_src_endpoint(json),

      # Log-specific fields
      log_name: json["logger"] || FieldParser.get_field(json, "scope_name", "scopeName"),
      log_provider: FieldParser.get_field(json, "service_name", "serviceName", "unknown"),
      log_level: FieldParser.get_field(json, "severity_text", "severityText") || json["level"],
      log_version: FieldParser.get_field(json, "scope_version", "scopeVersion"),

      # Unmapped data
      unmapped: extract_unmapped(json),

      # Raw data for debugging
      raw_data: nil,

      # Multi-tenancy (default tenant if not specified)
      tenant_id: json["tenant_id"] || "00000000-0000-0000-0000-000000000000",

      # Record timestamp
      created_at: DateTime.utc_now()
    }
  end

  defp parse_protobuf_log(_data, _metadata) do
    # TODO: Implement protobuf parsing for ExportLogsServiceRequest
    nil
  end

  defp map_severity(json) do
    # Check OpenTelemetry severity_number first
    otel_severity = json["severity_number"] || json["severityNumber"]

    if otel_severity do
      map_otel_severity(otel_severity)
    else
      # Fall back to text-based severity
      severity_text =
        (json["severity_text"] || json["severityText"] || json["level"] || "")
        |> String.upcase()

      case severity_text do
        "FATAL" -> @severity_fatal
        "CRITICAL" -> @severity_critical
        "ERROR" -> @severity_high
        "WARN" -> @severity_medium
        "WARNING" -> @severity_medium
        "INFO" -> @severity_informational
        "DEBUG" -> @severity_informational
        "TRACE" -> @severity_informational
        _ -> @severity_unknown
      end
    end
  end

  # Map OpenTelemetry severity (1-24) to OCSF severity (0-6)
  defp map_otel_severity(otel) when otel >= 21, do: @severity_fatal
  defp map_otel_severity(otel) when otel >= 17, do: @severity_high
  defp map_otel_severity(otel) when otel >= 13, do: @severity_medium
  defp map_otel_severity(otel) when otel >= 9, do: @severity_informational
  defp map_otel_severity(otel) when otel >= 5, do: @severity_informational
  defp map_otel_severity(otel) when otel >= 1, do: @severity_informational
  defp map_otel_severity(_), do: @severity_unknown

  defp severity_name(@severity_unknown), do: "Unknown"
  defp severity_name(@severity_informational), do: "Informational"
  defp severity_name(@severity_low), do: "Low"
  defp severity_name(@severity_medium), do: "Medium"
  defp severity_name(@severity_high), do: "High"
  defp severity_name(@severity_critical), do: "Critical"
  defp severity_name(@severity_fatal), do: "Fatal"
  defp severity_name(_), do: "Unknown"

  defp extract_message(json) do
    cond do
      is_binary(json["body"]) -> json["body"]
      is_map(json["body"]) -> Jason.encode!(json["body"])
      json["message"] -> json["message"]
      json["msg"] -> json["msg"]
      json["short_message"] -> json["short_message"]
      true -> nil
    end
  end

  defp build_metadata(json, nats_metadata) do
    base = %{
      version: "1.7.0",
      product: %{
        vendor_name: "ServiceRadar",
        name: "EventWriter",
        version: "1.0.0"
      },
      logged_time: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    # Add correlation IDs if present
    base =
      if nats_metadata[:subject] do
        put_in(base, [:correlation_uid], nats_metadata[:subject])
      else
        base
      end

    # Add original event attributes
    if json["attributes"] do
      Map.put(base, :original_attributes, json["attributes"])
    else
      base
    end
  end

  defp build_observables(json) do
    observables = []

    # Add IP addresses as observables
    observables =
      if json["host_ip"] || json["ip"] do
        ip = json["host_ip"] || json["ip"]

        [
          %{
            name: ip,
            type: "IP Address",
            type_id: 2
          }
          | observables
        ]
      else
        observables
      end

    # Add hostnames as observables
    observables =
      if json["hostname"] || json["host"] do
        hostname = json["hostname"] || json["host"]

        [
          %{
            name: hostname,
            type: "Hostname",
            type_id: 1
          }
          | observables
        ]
      else
        observables
      end

    observables
  end

  defp build_actor(json) do
    service_name = FieldParser.get_field(json, "service_name", "serviceName")

    if service_name do
      %{
        app_name: service_name,
        app_ver: FieldParser.get_field(json, "service_version", "serviceVersion")
      }
    else
      %{}
    end
  end

  defp build_device(json) do
    hostname = json["hostname"] || json["host"]
    ip = json["host_ip"] || json["ip"]

    device = %{}

    device =
      if hostname do
        Map.put(device, :hostname, hostname)
      else
        device
      end

    if ip do
      Map.put(device, :ip, ip)
    else
      device
    end
  end

  defp build_src_endpoint(json) do
    # Build source endpoint from resource attributes
    resource = json["resource_attributes"] || json["resourceAttributes"] || %{}

    endpoint = %{}

    endpoint =
      if resource["host.name"] do
        Map.put(endpoint, :hostname, resource["host.name"])
      else
        endpoint
      end

    endpoint =
      if resource["host.ip"] do
        Map.put(endpoint, :ip, resource["host.ip"])
      else
        endpoint
      end

    endpoint
  end

  defp extract_unmapped(json) do
    # Extract fields that don't map directly to OCSF
    known_fields = ~w(
      timestamp time time_unix_nano
      trace_id traceId span_id spanId
      severity_text severityText severity_number severityNumber level
      body message msg short_message
      service_name serviceName service_version serviceVersion service_instance serviceInstance
      scope_name scopeName scope_version scopeVersion
      attributes resource_attributes resourceAttributes
      hostname host host_ip ip logger tenant_id
    )

    json
    |> Map.drop(known_fields)
    |> case do
      map when map == %{} -> %{}
      map -> map
    end
  end
end
