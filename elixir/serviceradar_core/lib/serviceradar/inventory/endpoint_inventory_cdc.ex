defmodule ServiceRadar.Inventory.EndpointInventoryCDC do
  @moduledoc """
  CDC/logical-replication table boundary for endpoint inventory.

  Endpoint inventory history is queried on demand through SRQL/TimescaleDB and
  must not be replayed through CDC. Keep any future CDC publication generator
  pointed at `cdc_candidate_tables/0` rather than broad `endpoint_inventory_%`
  discovery.
  """

  @current_state_tables [
    "endpoint_inventory_scans",
    "endpoint_inventory_packages",
    "endpoint_inventory_artifacts",
    "endpoint_inventory_artifact_contents",
    "endpoint_packages",
    "device_fleet_ordinals",
    "endpoint_inventory_current_package_counts",
    "endpoint_inventory_current_cpe_counts"
  ]

  @history_tables [
    "endpoint_inventory_scan_history",
    "endpoint_inventory_package_events",
    "endpoint_inventory_package_count_history",
    "endpoint_inventory_cpe_count_history"
  ]

  @continuous_aggregate_views [
    "endpoint_inventory_package_counts_hourly",
    "endpoint_inventory_cpe_counts_hourly"
  ]

  @spec current_state_tables() :: [String.t()]
  def current_state_tables, do: @current_state_tables

  @spec history_tables() :: [String.t()]
  def history_tables, do: @history_tables

  @spec continuous_aggregate_views() :: [String.t()]
  def continuous_aggregate_views, do: @continuous_aggregate_views

  @spec cdc_candidate_tables() :: [String.t()]
  def cdc_candidate_tables, do: @current_state_tables

  @spec cdc_excluded_tables() :: [String.t()]
  def cdc_excluded_tables, do: @history_tables ++ @continuous_aggregate_views

  @spec cdc_allowed?(String.t() | atom()) :: boolean()
  def cdc_allowed?(table_name) when is_binary(table_name) or is_atom(table_name) do
    {schema, table_name} =
      table_name
      |> to_string()
      |> split_table_name()

    schema in [nil, "platform"] and table_name in @current_state_tables
  end

  defp split_table_name(table_name) do
    case String.split(table_name, ".", parts: 2) do
      [table] -> {nil, table}
      [schema, table] -> {schema, table}
    end
  end
end
