defmodule ServiceRadarWebNGWeb.SRQL.BuilderTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.SRQL.Builder
  alias ServiceRadarWebNGWeb.SRQL.Catalog

  @moduletag :db_free

  test "parse supports quoted filter values with spaces" do
    query = ~s|in:devices type:"Access Point" sort:last_seen:desc limit:20|

    assert {:ok, state} = Builder.parse(query)
    assert state["entity"] == "devices"

    assert Enum.any?(state["filters"], fn filter ->
             filter["field"] == "type" and filter["op"] == "equals" and
               filter["value"] == "Access Point"
           end)
  end

  test "build after parsing quoted values remains builder-compatible" do
    query = ~s|in:devices type:"Access Point"|

    assert {:ok, parsed} = Builder.parse(query)
    rebuilt = Builder.build(parsed)
    assert rebuilt =~ "in:devices"
    assert rebuilt =~ "type:Access\\ Point"
  end

  test "parse supports escaped spaces in unquoted filter values" do
    query = ~S|in:devices vendor_name:Access\ Point sort:last_seen:desc limit:20|

    assert {:ok, state} = Builder.parse(query)
    assert state["entity"] == "devices"

    assert Enum.any?(state["filters"], fn filter ->
             filter["field"] == "vendor_name" and filter["op"] == "equals" and
               filter["value"] == "Access Point"
           end)
  end

  test "catalog exposes WiFi map entities and fields" do
    entity_ids = Enum.map(Catalog.entities(), & &1.id)

    assert "wifi_sites" in entity_ids
    assert "wifi_aps" in entity_ids
    assert "wifi_controllers" in entity_ids
    assert "wifi_radius_groups" in entity_ids

    wifi_sites = Catalog.entity("wifi_sites")
    assert wifi_sites.default_filter_field == "site_code"
    assert "ap_count" in wifi_sites.filter_fields
    assert "ap_count" in wifi_sites.numeric_fields
    assert "all_server_groups" in wifi_sites.array_fields
  end

  test "catalog exposes derived add-on fleet health fields" do
    addon_fleet = Catalog.entity("addon_fleet")

    assert addon_fleet.route == "/settings/agents/addons/fleet"
    assert addon_fleet.default_sort_field == "category"
    assert "reason_code" in addon_fleet.filter_fields
    assert "evidence_age_seconds" in addon_fleet.numeric_fields
    assert "action_required" in addon_fleet.known_values["category"]

    query = addon_fleet |> then(&Builder.default_state(&1.id, 25)) |> Builder.build()
    assert query =~ "in:addon_fleet"
    assert query =~ "sort:category:asc"
  end

  test "device catalog remains provider-neutral for external inventory plugins" do
    devices = Catalog.entity("devices")

    assert "armis" in devices.known_values["discovery_sources"]
    refute "example-inventory" in devices.known_values["discovery_sources"]
    refute Enum.any?(devices.filter_fields, &String.contains?(&1, "example_inventory"))
  end

  test "flows catalog includes device_id used by device-scoped explorer links" do
    flows = Catalog.entity("flows")
    assert "device_id" in flows.filter_fields
  end

  test "interfaces catalog includes interface_uid used by device interface pages" do
    interfaces = Catalog.entity("interfaces")
    assert "interface_uid" in interfaces.filter_fields
    assert "device_id" in interfaces.filter_fields
  end

  test "flows builder seeds its default IP filter with equals, not contains" do
    state = Builder.default_state("flows", 100)

    assert [%{"field" => "src_endpoint_ip", "op" => op}] = state["filters"]

    assert op == "equals",
           "the flows default filter field is an IP; `contains` wraps it in % and matches nothing"
  end

  test "address filters build an exact match rather than a wildcard" do
    state =
      "flows"
      |> Builder.default_state(100)
      |> Map.put("filters", [
        %{"field" => "dst_endpoint_ip", "op" => "equals", "value" => "34.98.126.170"}
      ])

    query = Builder.build(state)

    assert query =~ "dst_endpoint_ip:34.98.126.170"
    refute query =~ "%34.98.126.170%"
  end

  test "a missing filter operator falls back to the field's default, not always contains" do
    # An absent or unrecognised op used to become `contains` for every field, which
    # turns an address into `%addr%`. It should follow the field type instead.
    address =
      Builder.build(%{
        "entity" => "flows",
        "filters" => [%{"field" => "dst_ip", "value" => "34.98.126.170"}]
      })

    assert address =~ "dst_ip:34.98.126.170"
    refute address =~ "%"

    text =
      Builder.build(%{
        "entity" => "flows",
        "filters" => [%{"field" => "app", "value" => "https"}]
      })

    assert text =~ "app:%https%"
  end

  test "catalog reports address fields for the flow entities" do
    for entity <- ["flows", "attributed_flows"] do
      address_fields = Catalog.address_fields(entity)

      assert "src_endpoint_ip" in address_fields, entity
      assert "dst_endpoint_ip" in address_fields, entity
      assert "src_ip" in address_fields, entity
      assert "dst_ip" in address_fields, entity
      assert "sampler_address" in address_fields, entity

      assert Catalog.default_filter_op(entity, "dst_ip") == "equals", entity
      assert Catalog.default_filter_op(entity, "app") == "contains", entity
    end
  end

  test "builds default WiFi site query" do
    state = Builder.default_state("wifi_sites", 50)
    query = Builder.build(state)

    assert query =~ "in:wifi_sites"
    assert query =~ "sort:collection_timestamp:desc"
    assert query =~ "limit:50"
  end

  test "parse and build support WiFi numeric comparison filters" do
    query = "in:wifi_sites ap_count:>0 down_count:<=5 sort:ap_count:desc limit:25"

    assert {:ok, state} = Builder.parse(query)
    assert state["entity"] == "wifi_sites"

    assert Enum.any?(state["filters"], fn filter ->
             filter["field"] == "ap_count" and filter["op"] == "gt" and filter["value"] == "0"
           end)

    assert Enum.any?(state["filters"], fn filter ->
             filter["field"] == "down_count" and filter["op"] == "lte" and filter["value"] == "5"
           end)

    rebuilt = Builder.build(state)
    assert rebuilt =~ "ap_count:>0"
    assert rebuilt =~ "down_count:<=5"
    assert rebuilt =~ "sort:ap_count:desc"
  end

  test "WiFi array fields build list syntax" do
    state =
      "wifi_radius_groups"
      |> Builder.default_state(100)
      |> Map.put("filters", [
        %{"field" => "all_server_groups", "op" => "equals", "value" => "aaa-primary,aaa-backup"}
      ])

    query = Builder.build(state)

    assert query =~ "in:wifi_radius_groups"
    assert query =~ "all_server_groups:(aaa-primary,aaa-backup)"
  end

  test "dashboard discovery queries round trip through the shared builder" do
    query = "in:dashboards title:%NOC% type:authored sort:updated_at:desc limit:20"

    assert {:ok, state} = Builder.parse(query)
    assert state["entity"] == "dashboards"

    assert Enum.any?(state["filters"], fn filter ->
             filter["field"] == "title" and filter["op"] == "contains" and filter["value"] == "NOC"
           end)

    assert Enum.any?(state["filters"], fn filter ->
             filter["field"] == "type" and filter["op"] == "equals" and filter["value"] == "authored"
           end)

    rebuilt = Builder.build(state)
    assert rebuilt =~ "in:dashboards"
    assert rebuilt =~ "title:%NOC%"
    assert rebuilt =~ "type:authored"
    assert rebuilt =~ "sort:updated_at:desc"
    assert rebuilt =~ "limit:20"
  end
end
