defmodule ServiceRadar.Inventory.EndpointInventoryCDCTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.EndpointInventoryCDC

  test "cdc candidate list contains only endpoint inventory current-state tables" do
    assert "endpoint_inventory_scans" in EndpointInventoryCDC.cdc_candidate_tables()
    assert "endpoint_inventory_packages" in EndpointInventoryCDC.cdc_candidate_tables()
    assert "endpoint_inventory_artifacts" in EndpointInventoryCDC.cdc_candidate_tables()
    assert "endpoint_packages" in EndpointInventoryCDC.cdc_candidate_tables()
    assert "device_fleet_ordinals" in EndpointInventoryCDC.cdc_candidate_tables()

    refute "endpoint_inventory_scan_history" in EndpointInventoryCDC.cdc_candidate_tables()
    refute "endpoint_inventory_package_events" in EndpointInventoryCDC.cdc_candidate_tables()

    refute "endpoint_inventory_package_count_history" in EndpointInventoryCDC.cdc_candidate_tables()

    refute "endpoint_inventory_cpe_count_history" in EndpointInventoryCDC.cdc_candidate_tables()
  end

  test "history hypertables and continuous aggregates are explicitly excluded from cdc" do
    excluded = EndpointInventoryCDC.cdc_excluded_tables()

    assert "endpoint_inventory_scan_history" in excluded
    assert "endpoint_inventory_package_events" in excluded
    assert "endpoint_inventory_package_count_history" in excluded
    assert "endpoint_inventory_cpe_count_history" in excluded
    assert "endpoint_inventory_package_counts_hourly" in excluded
    assert "endpoint_inventory_cpe_counts_hourly" in excluded

    Enum.each(excluded, fn table_name ->
      refute EndpointInventoryCDC.cdc_allowed?(table_name)
      refute EndpointInventoryCDC.cdc_allowed?("platform.#{table_name}")
    end)
  end

  test "cdc_allowed handles schema-qualified current-state table names" do
    assert EndpointInventoryCDC.cdc_allowed?("endpoint_inventory_packages")
    assert EndpointInventoryCDC.cdc_allowed?("platform.endpoint_inventory_packages")
    assert EndpointInventoryCDC.cdc_allowed?(:endpoint_inventory_packages)
    assert EndpointInventoryCDC.cdc_allowed?("platform.device_fleet_ordinals")

    refute EndpointInventoryCDC.cdc_allowed?("public.endpoint_inventory_packages")
    refute EndpointInventoryCDC.cdc_allowed?("endpoint_inventory_package_events")
    refute EndpointInventoryCDC.cdc_allowed?("unrelated_table")
  end
end
