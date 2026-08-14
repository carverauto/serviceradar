defmodule ServiceRadarWebNGWeb.DeviceLive.IndexData do
  @moduledoc false

  alias ServiceRadarWebNGWeb.DeviceLive.IndexData.Availability
  alias ServiceRadarWebNGWeb.DeviceLive.IndexData.Composite
  alias ServiceRadarWebNGWeb.DeviceLive.IndexData.Query
  alias ServiceRadarWebNGWeb.DeviceLive.IndexData.Stats
  alias ServiceRadarWebNGWeb.DeviceLive.IndexData.Telemetry

  def build_device_enrichments(scope, query, devices) do
    {icmp_sparklines, icmp_error} = Telemetry.icmp_sparklines(scope, devices)
    {snmp_presence, sysmon_presence} = Telemetry.metric_presence(scope, devices)

    %{
      icmp_sparklines: icmp_sparklines,
      icmp_error: icmp_error,
      effective_availability_by_device: Availability.effective_availability(devices, scope),
      snmp_presence: snmp_presence,
      sysmon_presence: sysmon_presence,
      sysmon_profiles_by_device: load_sysmon_profiles_for_devices(scope, devices),
      agent_device_uids: Availability.agent_device_uids(devices, scope),
      composite_verdicts_by_device: Composite.verdicts_by_device(scope, query, devices),
      total_device_count: Query.get_total_matching_count(scope, query)
    }
  end

  defdelegate load_availability_source_agent_options(scope),
    to: Availability,
    as: :availability_source_agent_options

  defdelegate load_device_stats(srql_module, scope), to: Stats
  defdelegate default_device_stats(), to: Stats
  defdelegate get_total_matching_count(scope, query), to: Query
  defdelegate include_inactive_inventory_params(params), to: Query
  defdelegate parse_page_param(params), to: Query
  defdelegate get_all_matching_uids(scope, query), to: Query

  # Sysmon profile helpers
  # Note: Profile-per-device tracking removed - profiles now target devices via SRQL queries.
  # This function returns an empty map for profiles_by_device.
  def load_sysmon_profiles_for_devices(_scope, _devices) do
    %{}
  rescue
    _ -> %{}
  end
end
