defmodule ServiceRadarWebNGWeb.SRQL.BuilderTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.SRQL.Builder
  alias ServiceRadarWebNGWeb.SRQL.Catalog

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
end
