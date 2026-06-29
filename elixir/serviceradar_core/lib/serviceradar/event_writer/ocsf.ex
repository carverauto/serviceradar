defmodule ServiceRadar.EventWriter.OCSF do
  @moduledoc """
  OCSF (Open Cybersecurity Schema Framework) constants and shared builders.

  This module provides:
  - Category, class, and activity ID constants
  - Severity mappings
  - Shared field builders for OCSF events

  ## OCSF Version
  Common network and system activity helpers retain their historical defaults.
  Security producer helpers target OCSF v1.9.0-dev until the next stable
  schema release carries the same classes.

  ## Usage Strategy
  - Logs: Keep native OTEL format (observability data)
  - Sweep/Discovery: OCSF Network Activity (class_uid: 4001)
  - NetFlow: OCSF Network Activity (class_uid: 4001)
  - OTel traces/metrics: Keep native format (observability, not security)
  - Telemetry metrics: Keep native format (time-series data)

  ## References
  - https://schema.ocsf.io/
  - https://github.com/ocsf/ocsf-schema
  """

  alias ServiceRadar.EventWriter.FieldParser

  # =============================================================================
  # OCSF Schema Version
  # =============================================================================

  # Canonical OCSF schema version emitted in event metadata. Bump here only.
  @schema_version "1.7.0"

  @doc "Canonical OCSF schema version emitted in event metadata."
  @spec schema_version() :: String.t()
  def schema_version, do: @schema_version

  # =============================================================================
  # Category UIDs
  # =============================================================================

  @doc "System Activity category (category_uid: 1)"
  def category_system_activity, do: 1

  @doc "Findings category (category_uid: 2)"
  def category_findings, do: 2

  @doc "Network Activity category (category_uid: 4)"
  def category_network_activity, do: 4

  @doc "Application Activity category (category_uid: 6)"
  def category_application_activity, do: 6

  # =============================================================================
  # Class UIDs
  # =============================================================================

  # System Activity classes
  @doc "Event Log Activity class (class_uid: 1008)"
  def class_event_log_activity, do: 1008

  # Finding classes
  @doc "Vulnerability Finding class (class_uid: 2002)"
  def class_vulnerability_finding, do: 2002

  @doc "Compliance Finding class (class_uid: 2003)"
  def class_compliance_finding, do: 2003

  @doc "Detection Finding class (class_uid: 2004)"
  def class_detection_finding, do: 2004

  @doc "Application Security Posture Finding class (class_uid: 2007)"
  def class_application_security_posture_finding, do: 2007

  # Network Activity classes
  @doc "Network Activity class (class_uid: 4001)"
  def class_network_activity, do: 4001

  @doc "HTTP Activity class (class_uid: 4002)"
  def class_http_activity, do: 4002

  @doc "DNS Activity class (class_uid: 4003)"
  def class_dns_activity, do: 4003

  @doc "Scan Activity class (class_uid: 6007)"
  def class_scan_activity, do: 6007

  # =============================================================================
  # Activity IDs - Event Log Activity (1008)
  # =============================================================================

  @doc "Log Create activity"
  def activity_log_create, do: 1
  @doc "Log Read activity"
  def activity_log_read, do: 2
  @doc "Log Update activity"
  def activity_log_update, do: 3
  @doc "Log Delete activity"
  def activity_log_delete, do: 4

  # =============================================================================
  # Activity IDs - Findings (200x)
  # =============================================================================

  @doc "Finding Create activity"
  def activity_finding_create, do: 1
  @doc "Finding Update activity"
  def activity_finding_update, do: 2
  @doc "Finding Close activity"
  def activity_finding_close, do: 3

  # =============================================================================
  # Activity IDs - Network Activity (4001)
  # =============================================================================

  @doc "Network connection Open"
  def activity_network_open, do: 1
  @doc "Network connection Close"
  def activity_network_close, do: 2
  @doc "Network connection Reset"
  def activity_network_reset, do: 3
  @doc "Network connection Fail"
  def activity_network_fail, do: 4
  @doc "Network connection Refuse"
  def activity_network_refuse, do: 5
  @doc "Network Traffic report"
  def activity_network_traffic, do: 6
  @doc "Network Listen"
  def activity_network_listen, do: 7
  @doc "Network Scan (discovery)"
  def activity_network_scan, do: 99

  # =============================================================================
  # Activity IDs - Scan Activity (6007)
  # =============================================================================

  @doc "Scan started"
  def activity_scan_started, do: 1
  @doc "Scan completed"
  def activity_scan_completed, do: 2
  @doc "Scan cancelled"
  def activity_scan_cancelled, do: 3
  @doc "Scan duration violation"
  def activity_scan_duration_violation, do: 4
  @doc "Scan pause violation"
  def activity_scan_pause_violation, do: 5
  @doc "Scan error"
  def activity_scan_error, do: 6
  @doc "Scan paused"
  def activity_scan_paused, do: 7
  @doc "Scan resumed"
  def activity_scan_resumed, do: 8
  @doc "Scan restarted"
  def activity_scan_restarted, do: 9
  @doc "Scan delayed"
  def activity_scan_delayed, do: 10

  # =============================================================================
  # Severity IDs
  # =============================================================================

  @doc "Unknown severity"
  def severity_unknown, do: 0
  @doc "Informational severity"
  def severity_informational, do: 1
  @doc "Low severity"
  def severity_low, do: 2
  @doc "Medium severity"
  def severity_medium, do: 3
  @doc "High severity"
  def severity_high, do: 4
  @doc "Critical severity"
  def severity_critical, do: 5
  @doc "Fatal severity"
  def severity_fatal, do: 6

  @doc "Convert severity_id to human-readable name"
  def severity_name(0), do: "Unknown"
  def severity_name(1), do: "Informational"
  def severity_name(2), do: "Low"
  def severity_name(3), do: "Medium"
  def severity_name(4), do: "High"
  def severity_name(5), do: "Critical"
  def severity_name(6), do: "Fatal"
  def severity_name(_), do: "Unknown"

  # =============================================================================
  # Status IDs
  # =============================================================================

  @doc "Unknown status"
  def status_unknown, do: 0
  @doc "Success status"
  def status_success, do: 1
  @doc "Failure status"
  def status_failure, do: 2
  @doc "Other status"
  def status_other, do: 99

  @doc "Convert status_id to human-readable name"
  def status_name(0), do: "Unknown"
  def status_name(1), do: "Success"
  def status_name(2), do: "Failure"
  def status_name(99), do: "Other"
  def status_name(_), do: "Unknown"

  # =============================================================================
  # Action IDs (for Network Activity)
  # =============================================================================

  @doc "Unknown action"
  def action_unknown, do: 0
  @doc "Allowed action"
  def action_allowed, do: 1
  @doc "Denied action"
  def action_denied, do: 2
  @doc "Other action"
  def action_other, do: 99

  # =============================================================================
  # Type UID Calculation
  # =============================================================================

  @doc """
  Calculate type_uid from class_uid and activity_id.

  Formula: type_uid = class_uid * 100 + activity_id

  ## Examples

      iex> OCSF.type_uid(4001, 6)
      400106
  """
  def type_uid(class_uid, activity_id), do: class_uid * 100 + activity_id

  # =============================================================================
  # Activity Name Helpers
  # =============================================================================

  @doc "Get activity name for Network Activity class"
  def network_activity_name(1), do: "Open"
  def network_activity_name(2), do: "Close"
  def network_activity_name(3), do: "Reset"
  def network_activity_name(4), do: "Fail"
  def network_activity_name(5), do: "Refuse"
  def network_activity_name(6), do: "Traffic"
  def network_activity_name(7), do: "Listen"
  def network_activity_name(99), do: "Scan"
  def network_activity_name(_), do: "Unknown"

  @doc "Get activity name for Event Log Activity class"
  def log_activity_name(1), do: "Create"
  def log_activity_name(2), do: "Read"
  def log_activity_name(3), do: "Update"
  def log_activity_name(4), do: "Delete"
  def log_activity_name(_), do: "Unknown"

  @doc "Get activity name for OCSF finding classes"
  def finding_activity_name(1), do: "Create"
  def finding_activity_name(2), do: "Update"
  def finding_activity_name(3), do: "Close"
  def finding_activity_name(_), do: "Unknown"

  @doc "Get activity name for Scan Activity class"
  def scan_activity_name(1), do: "Started"
  def scan_activity_name(2), do: "Completed"
  def scan_activity_name(3), do: "Cancelled"
  def scan_activity_name(4), do: "Duration Violation"
  def scan_activity_name(5), do: "Pause Violation"
  def scan_activity_name(6), do: "Error"
  def scan_activity_name(7), do: "Paused"
  def scan_activity_name(8), do: "Resumed"
  def scan_activity_name(9), do: "Restarted"
  def scan_activity_name(10), do: "Delayed"
  def scan_activity_name(99), do: "Other"
  def scan_activity_name(_), do: "Unknown"

  # =============================================================================
  # Shared Field Builders
  # =============================================================================

  @doc """
  Build OCSF metadata object.

  Required by all OCSF events.
  """
  def build_metadata(opts \\ []) do
    %{
      version: Keyword.get(opts, :version, @schema_version),
      product: %{
        vendor_name: "ServiceRadar",
        name: Keyword.get(opts, :product_name, "EventWriter"),
        version: Keyword.get(opts, :product_version, "1.0.0")
      },
      logged_time: DateTime.to_iso8601(DateTime.utc_now())
    }
    |> maybe_put(:correlation_uid, Keyword.get(opts, :correlation_uid))
    |> maybe_put(:original_time, Keyword.get(opts, :original_time))
  end

  @doc """
  Build OCSF endpoint object from IP/hostname/port.

  Used for src_endpoint and dst_endpoint fields.
  """
  def build_endpoint(opts \\ []) do
    %{}
    |> maybe_put(:ip, Keyword.get(opts, :ip))
    |> maybe_put(:hostname, Keyword.get(opts, :hostname))
    |> maybe_put(:port, Keyword.get(opts, :port))
    |> maybe_put(:mac, Keyword.get(opts, :mac))
    |> maybe_put(:name, Keyword.get(opts, :name))
    |> maybe_put(:domain, Keyword.get(opts, :domain))
  end

  @doc """
  Build OCSF network_endpoint object with interface info.
  """
  def build_network_endpoint(opts \\ []) do
    endpoint = build_endpoint(opts)

    endpoint
    |> maybe_put(:interface_uid, Keyword.get(opts, :interface_uid))
    |> maybe_put(:interface_name, Keyword.get(opts, :interface_name))
    |> maybe_put(:subnet_uid, Keyword.get(opts, :subnet_uid))
  end

  @doc """
  Build OCSF device object.
  """
  def build_device(opts \\ []) do
    %{}
    |> maybe_put(:hostname, Keyword.get(opts, :hostname))
    |> maybe_put(:ip, Keyword.get(opts, :ip))
    |> maybe_put(:mac, Keyword.get(opts, :mac))
    |> maybe_put(:name, Keyword.get(opts, :name))
    |> maybe_put(:type_id, Keyword.get(opts, :type_id))
    |> maybe_put(:uid, Keyword.get(opts, :uid))
  end

  @doc """
  Build OCSF actor object.
  """
  def build_actor(opts \\ []) do
    %{}
    |> maybe_put(:app_name, Keyword.get(opts, :app_name))
    |> maybe_put(:app_ver, Keyword.get(opts, :app_ver))
    |> maybe_put(:process, Keyword.get(opts, :process))
    |> maybe_put(:user, Keyword.get(opts, :user))
  end

  @doc """
  Build OCSF observable from a value.
  """
  def build_observable(name, type, type_id) do
    %{
      name: name,
      type: type,
      type_id: type_id
    }
  end

  @doc "Build IP Address observable"
  def ip_observable(ip), do: build_observable(ip, "IP Address", 2)

  @doc "Build Hostname observable"
  def hostname_observable(hostname), do: build_observable(hostname, "Hostname", 1)

  @doc "Build MAC Address observable"
  def mac_observable(mac), do: build_observable(mac, "MAC Address", 3)

  @doc "Build Port observable"
  def port_observable(port), do: build_observable(to_string(port), "Port", 8)

  @doc """
  Build observables list from endpoint data.
  """
  def build_observables_from_endpoint(opts) do
    []
    |> maybe_add_observable(Keyword.get(opts, :ip), &ip_observable/1)
    |> maybe_add_observable(Keyword.get(opts, :hostname), &hostname_observable/1)
    |> maybe_add_observable(Keyword.get(opts, :mac), &mac_observable/1)
    |> maybe_add_observable(Keyword.get(opts, :port), &port_observable/1)
  end

  @doc """
  Build network connection info for Network Activity events.
  """
  def build_connection_info(opts \\ []) do
    %{}
    |> maybe_put(:protocol_name, Keyword.get(opts, :protocol_name))
    |> maybe_put(:protocol_num, Keyword.get(opts, :protocol_num))
    |> maybe_put(:direction, Keyword.get(opts, :direction))
    |> maybe_put(:direction_id, Keyword.get(opts, :direction_id))
  end

  @doc """
  Build traffic info for Network Activity events.
  """
  def build_traffic(opts \\ []) do
    %{}
    |> maybe_put(:bytes, Keyword.get(opts, :bytes))
    |> maybe_put(:bytes_in, Keyword.get(opts, :bytes_in))
    |> maybe_put(:bytes_out, Keyword.get(opts, :bytes_out))
    |> maybe_put(:packets, Keyword.get(opts, :packets))
    |> maybe_put(:packets_in, Keyword.get(opts, :packets_in))
    |> maybe_put(:packets_out, Keyword.get(opts, :packets_out))
  end

  @doc """
  Map protocol number to name.
  """
  def protocol_name(1), do: "ICMP"
  def protocol_name(6), do: "TCP"
  def protocol_name(17), do: "UDP"
  def protocol_name(47), do: "GRE"
  def protocol_name(50), do: "ESP"
  def protocol_name(51), do: "AH"
  def protocol_name(58), do: "ICMPv6"
  def protocol_name(89), do: "OSPF"
  def protocol_name(132), do: "SCTP"
  def protocol_name(_), do: "Unknown"

  @doc """
  Parse time field using FieldParser.
  """
  def parse_time(json, field \\ "timestamp") do
    FieldParser.parse_timestamp(json[field])
  end

  # =============================================================================
  # Private Helpers
  # =============================================================================

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_add_observable(list, nil, _builder), do: list
  defp maybe_add_observable(list, "", _builder), do: list
  defp maybe_add_observable(list, value, builder), do: [builder.(value) | list]
end
