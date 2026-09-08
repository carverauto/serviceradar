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

  test "catalog exposes the sweep diagnostics entities" do
    entity_ids = Enum.map(Catalog.entities(), & &1.id)

    for id <- ~w(sweep_groups sweep_profiles sweep_executions sweep_results sweep_coverage
                 device_sweep_overlap) do
      assert id in entity_ids, id
    end

    overlap = Catalog.entity("device_sweep_overlap")
    assert overlap.label == "Sweep Declared vs Observed"
    assert overlap.default_filter_field == "device_uid"
    assert "relationship" in overlap.filter_fields
    assert "declared_not_observed" in overlap.known_values["relationship"]
    assert overlap.downsample == false
  end

  # Every alias below is one the SRQL parser accepts and `EntityAccess` gates.
  # An alias the catalog does not know does not fail loudly: `entity/1` returns a
  # synthesized entry whose `default_sort_field` is "timestamp" and whose filter
  # allowlist is empty, so the builder emits `sort:timestamp:desc` against an
  # entity with no `timestamp` column.
  test "every sweep alias resolves to its canonical catalog entry" do
    aliases = %{
      "sweep_group" => "sweep_groups",
      "sweeps" => "sweep_groups",
      "sweep_profile" => "sweep_profiles",
      "scanner_profiles" => "sweep_profiles",
      "scanner_profile" => "sweep_profiles",
      "sweep_execution" => "sweep_executions",
      "sweep_group_executions" => "sweep_executions",
      "sweep_result" => "sweep_results",
      "sweep_host_results" => "sweep_results",
      "sweep_coverage_daily" => "sweep_coverage",
      "sweep_overlap" => "device_sweep_overlap"
    }

    for {alias_name, canonical} <- aliases do
      entry = Catalog.entity(alias_name)
      assert entry.id == canonical, "#{alias_name} resolved to #{entry.id}"
      refute entry.default_sort_field == "timestamp", alias_name
      refute entry.filter_fields == [], alias_name
    end
  end

  # The overlap view's whole point is the `declared_not_observed` row, and those
  # rows carry a NULL `last_seen_at` by construction. The Rust query therefore
  # defaults to a compound sort that lifts them to the front; an explicit `sort:`
  # from the caller replaces that default entirely. If the catalog advertised a
  # `default_sort_field`, the visual builder would emit exactly such a token on
  # every query it builds and bury every alert behind every ordinary row.
  test "the sweep overlap builder emits no sort token so the alert-first default survives" do
    overlap = Catalog.entity("device_sweep_overlap")
    assert overlap.default_sort_field == ""

    for alias_name <- ~w(device_sweep_overlap sweep_overlap) do
      assert %{id: "device_sweep_overlap"} = Catalog.entity(alias_name)

      query = Builder.build(Builder.default_state("device_sweep_overlap", 25))
      assert query =~ "in:device_sweep_overlap"
      refute query =~ "sort:"

      assert {:ok, parsed} = Builder.parse("in:#{alias_name} limit:25")
      assert parsed["entity"] == "device_sweep_overlap", alias_name
      assert parsed["sort_field"] == "", alias_name
      refute Builder.build(parsed) =~ "sort:", alias_name
    end
  end

  test "device catalog remains provider-neutral for external inventory plugins" do
    devices = Catalog.entity("devices")

    assert "armis" in devices.known_values["discovery_sources"]
    refute "example-inventory" in devices.known_values["discovery_sources"]
    refute Enum.any?(devices.filter_fields, &String.contains?(&1, "example_inventory"))
    assert "first_seen" in devices.filter_fields
    assert "last_30d" in devices.known_values["first_seen"]
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

  # Engine fixture: keep in sync with rust/srql/.../downsample/filters.rs flows_filter_clause.
  @flows_downsample_engine_fields ~w(
    src_endpoint_ip src_ip dst_endpoint_ip dst_ip ip endpoint_ip
    device_addr device_address
    src_cidr dst_cidr cidr
    src_endpoint_port src_port dst_endpoint_port dst_port
    protocol_name protocol_num proto protocol_group proto_group app direction
    sampler_address exporter_name
    input_snmp in_if_index output_snmp out_if_index
    in_if_name out_if_name in_if_speed_bps out_if_speed_bps
  )

  test "flows filter_fields_downsample is a subset of the downsample engine allowlist" do
    downsample = Catalog.filter_fields("flows", :downsample)
    engine = MapSet.new(@flows_downsample_engine_fields)

    assert is_list(downsample)
    assert downsample != []

    for field <- downsample do
      assert field in engine,
             "#{field} is in catalog filter_fields_downsample but not the engine fixture"
    end
  end

  test "stats mode remains outside the visual builder catalog" do
    assert Catalog.filter_fields("flows", :stats) == nil
  end

  test "every advertised flows chart field survives builder normalization" do
    for field <- Catalog.filter_fields("flows", :downsample) do
      chart =
        "flows"
        |> Builder.default_state(100)
        |> Map.put("filters", [
          %{"field" => field, "op" => Catalog.default_filter_op("flows", field), "value" => ""}
        ])

      {normalized, stripped} = Builder.update_meta(chart, %{})

      assert stripped == [], field
      assert Enum.any?(normalized["filters"], &(&1["field"] == field)), field
    end
  end

  test "flows row filter list includes chart-illegal fields that remain row-valid" do
    row = Catalog.filter_fields("flows", :row)

    for field <- ~w(port tag near src_country_iso2 dst_country_iso2) do
      assert field in row, field
    end

    downsample = Catalog.filter_fields("flows", :downsample)

    for field <- ~w(port tag near src_country_iso2 as_path bgp_communities) do
      refute field in downsample, field
    end

    assert "cidr" in downsample
  end

  test "flows row filter list does not advertise engine-unsupported BGP fields" do
    row = Catalog.filter_fields("flows", :row)

    for field <- ~w(as_path bgp_communities) do
      refute field in row, field
    end
  end

  test "builder mode is downsample when bucket is set" do
    with_bucket = Builder.default_state("flows", 100)
    assert with_bucket["bucket"] != ""
    assert Builder.mode(with_bucket) == :downsample

    row = Builder.update(with_bucket, %{"bucket" => ""})

    assert Builder.mode(row) == :row
  end

  test "clearing the bucket switches flows to row mode and preserves row-only filters" do
    chart =
      "flows"
      |> Builder.default_state(100)
      |> Map.put("filters", [
        %{"field" => "tag", "op" => "equals", "value" => "edge"},
        %{"field" => "app", "op" => "equals", "value" => "https"}
      ])

    {row, stripped} = Builder.update_meta(chart, %{"bucket" => ""})

    assert Builder.mode(row) == :row
    assert row["bucket"] == ""
    assert stripped == []
    assert Enum.any?(row["filters"], &(&1["field"] == "tag"))
    assert Enum.any?(row["filters"], &(&1["field"] == "app"))
  end

  test "parsing a flows query without a bucket preserves row mode and row-only filters" do
    query = "in:flows time:last_1h tag:edge sort:time:desc limit:100"

    assert {:ok, row} = Builder.parse(query)
    assert Builder.mode(row) == :row
    assert Enum.any?(row["filters"], &(&1["field"] == "tag" and &1["value"] == "edge"))

    rebuilt = Builder.build(row)
    assert rebuilt =~ "tag:edge"
    refute rebuilt =~ "bucket:"
  end

  test "enabling chart mode strips illegal flows filters and reports them" do
    # Start from a row-shaped state (no bucket) with a tag filter, then set bucket.
    base = %{
      "entity" => "flows",
      "time" => "last_1h",
      "bucket" => "",
      "agg" => "sum",
      "value_field" => "bytes_total",
      "series" => "app",
      "sort_field" => "time",
      "sort_dir" => "desc",
      "limit" => 100,
      "filters" => [
        %{"field" => "tag", "op" => "equals", "value" => "edge"},
        %{"field" => "app", "op" => "contains", "value" => "https"},
        %{"field" => "cidr", "op" => "equals", "value" => "10.0.0.0/8"}
      ]
    }

    {state, stripped} = Builder.update_meta(base, %{"bucket" => "5m"})

    assert Builder.mode(state) == :downsample
    assert "tag" in stripped
    refute Enum.any?(state["filters"], &(&1["field"] == "tag"))
    assert Enum.any?(state["filters"], &(&1["field"] == "app"))
    assert Enum.any?(state["filters"], &(&1["field"] == "cidr"))

    query = Builder.build(state)
    assert query =~ "bucket:5m"
    assert query =~ "cidr:10.0.0.0/8"
    assert query =~ "app:%https%"
    refute query =~ "tag:"
  end

  test "build never emits chart + tag for flows even if state is inconsistent" do
    query =
      Builder.build(%{
        "entity" => "flows",
        "time" => "last_1h",
        "bucket" => "5m",
        "agg" => "sum",
        "value_field" => "bytes_total",
        "series" => "app",
        "sort_field" => "time",
        "sort_dir" => "desc",
        "limit" => 100,
        "filters" => [
          %{"field" => "tag", "op" => "equals", "value" => "edge"}
        ]
      })

    assert query =~ "bucket:5m"
    refute query =~ "tag:"
  end

  test "chart mode filter field options exclude illegal fields" do
    state =
      "flows"
      |> Builder.default_state(100)
      |> Map.put("bucket", "5m")

    fields = Builder.filter_fields_for(state)
    refute "tag" in fields
    refute "port" in fields
    assert "cidr" in fields
    assert "app" in fields
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

  @new_entity_alias_families [
    {"vulnerability_advisories", "Vulnerability Advisories",
     ~w(vulnerability_advisories vulnerability_advisory advisories cves)},
    {"advisory_coordinates", "Advisory Coordinates", ~w(advisory_coordinates advisory_cpes cpe_coordinates)},
    {"endpoint_vulnerability_assessments", "Vulnerability Assessments",
     ~w(endpoint_vulnerability_assessments endpoint_vulnerability_assessment package_vulnerabilities endpoint_vulnerability_matches vulnerability_matches cve_matches advisory_matches)}
  ]

  test "every advisory entity alias parses and rebuilds with its canonical catalog entry" do
    for {canonical_id, label, aliases} <- @new_entity_alias_families,
        alias_name <- aliases do
      assert %{id: ^canonical_id, label: ^label, default_sort_field: ""} =
               Catalog.entity(alias_name)

      assert {:ok, parsed} = Builder.parse("in:#{alias_name} limit:25")
      assert parsed["entity"] == canonical_id, alias_name
      assert parsed["sort_field"] == "", alias_name

      rebuilt = parsed |> Builder.update(%{"limit" => "50"}) |> Builder.build()
      assert rebuilt =~ "in:#{canonical_id}", alias_name
      assert rebuilt =~ "limit:50", alias_name
      refute rebuilt =~ "sort:", alias_name
    end
  end

  test "advisory entities leave their compound engine ordering implicit" do
    for {entity, _label, _aliases} <- @new_entity_alias_families do
      state = Builder.default_state(entity, 25)

      assert state["sort_field"] == "", entity

      query = Builder.build(state)

      assert query =~ "in:#{entity}", entity
      assert query =~ "limit:25", entity
      refute query =~ "sort:", entity

      assert {:ok, parsed} = Builder.parse("in:#{entity} limit:25")

      assert parsed["sort_field"] == "", entity
      refute parsed |> Builder.build() |> String.contains?("sort:"), entity
    end
  end

  test "legacy vulnerability match queries parse, edit, and rebuild with assessment metadata" do
    package_ref = "62508706-cf2f-4ca5-8446-b18b2b96e3a5"

    query =
      "in:endpoint_vulnerability_matches package_name:%curl% assessment:confirmed " <>
        "endpoint_package_ref:#{package_ref} limit:25"

    assert {:ok, parsed} = Builder.parse(query)

    assert parsed["entity"] == "endpoint_vulnerability_assessments"
    assert parsed["sort_field"] == ""

    assert [
             %{"field" => "package_name", "op" => "contains", "value" => "curl"},
             %{"field" => "assessment", "op" => "equals", "value" => "confirmed"},
             %{"field" => "endpoint_package_ref", "op" => "equals", "value" => ^package_ref}
           ] = parsed["filters"]

    rebuilt =
      parsed
      |> Builder.update(%{"limit" => "50"})
      |> Builder.build()

    assert rebuilt =~ "in:endpoint_vulnerability_assessments"
    assert rebuilt =~ "package_name:%curl%"
    assert rebuilt =~ "assessment:confirmed"
    assert rebuilt =~ "endpoint_package_ref:#{package_ref}"
    assert rebuilt =~ "limit:50"
    refute rebuilt =~ "sort:"
    refute rebuilt =~ "%#{package_ref}%"
  end

  test "advisory filters default text to contains and structured values to exact matching" do
    package_ref = "62508706-cf2f-4ca5-8446-b18b2b96e3a5"

    for {entity, field} <- [
          {"vulnerability_advisories", "title"},
          {"vulnerability_advisories", "description"},
          {"advisory_coordinates", "cpe_vendor"},
          {"advisory_coordinates", "cpe_version"}
        ] do
      assert Catalog.default_filter_op(entity, field) == "contains", "#{entity}.#{field}"
    end

    for {entity, field} <- [
          {"vulnerability_advisories", "severity"},
          {"advisory_coordinates", "coordinate_type"},
          {"advisory_coordinates", "cpe_part"}
        ] do
      assert Catalog.default_filter_op(entity, field) == "equals", "#{entity}.#{field}"
    end

    for field <-
          ~w(name package_name version package_version installed_version source_package source_version binary_package fixed_version purl package_purl purl_canonical) do
      assert Catalog.default_filter_op("endpoint_vulnerability_assessments", field) ==
               "contains",
             field
    end

    for field <-
          ~w(assessment disposition package_namespace namespace package_release release distro device_uid device_id agent_id advisory_ref package_id endpoint_package_ref inventory_package_ref scan_ref) do
      assert Catalog.default_filter_op("endpoint_vulnerability_assessments", field) == "equals",
             field
    end

    query =
      Builder.build(%{
        "entity" => "endpoint_vulnerability_assessments",
        "filters" => [
          %{"field" => "package_name", "value" => "curl"},
          %{"field" => "assessment", "value" => "confirmed"},
          %{"field" => "endpoint_package_ref", "value" => package_ref}
        ]
      })

    assert query =~ "package_name:%curl%"
    assert query =~ "assessment:confirmed"
    assert query =~ "endpoint_package_ref:#{package_ref}"
    refute query =~ "assessment:%confirmed%"
    refute query =~ "%#{package_ref}%"
  end

  test "advisory UUID filters cannot rebuild wildcard operators" do
    package_ref = "62508706-cf2f-4ca5-8446-b18b2b96e3a5"

    uuid_fields_by_entity = [
      {"vulnerability_advisories", ~w(id)},
      {"advisory_coordinates", ~w(id advisory_ref)},
      {"endpoint_vulnerability_assessments",
       ~w(id advisory_ref package_id endpoint_package_ref inventory_package_ref scan_ref)}
    ]

    for {entity, uuid_fields} <- uuid_fields_by_entity do
      query =
        Builder.build(%{
          "entity" => entity,
          "filters" =>
            Enum.map(uuid_fields, fn field ->
              %{"field" => field, "op" => "contains", "value" => package_ref}
            end)
        })

      for field <- uuid_fields do
        assert query =~ "#{field}:#{package_ref}", field
      end

      refute query =~ "%#{package_ref}%", entity
    end

    negative_query =
      Builder.build(%{
        "entity" => "endpoint_vulnerability_assessments",
        "filters" => [
          %{"field" => "advisory_ref", "op" => "not_contains", "value" => package_ref}
        ]
      })

    assert negative_query =~ "!advisory_ref:#{package_ref}"
    refute negative_query =~ "%#{package_ref}%"

    assert {:ok, parsed} =
             Builder.parse("in:endpoint_vulnerability_matches advisory_ref:%#{package_ref}% limit:25")

    assert [%{"field" => "advisory_ref", "op" => "equals", "value" => ^package_ref}] =
             parsed["filters"]

    parsed_query = Builder.build(parsed)
    assert parsed_query =~ "advisory_ref:#{package_ref}"
    refute parsed_query =~ "%#{package_ref}%"
  end

  test "assessment authority audit fields parse and rebuild as scalar comparisons" do
    entity = Catalog.entity("endpoint_vulnerability_assessments")

    assert "authority_generation" in entity.filter_fields
    assert "authority_as_of" in entity.filter_fields
    assert "authority_generation" in entity.numeric_fields
    assert "authority_as_of" in entity.timestamp_fields
    assert Catalog.default_filter_op(entity, "authority_generation") == "equals"
    assert Catalog.default_filter_op(entity, "authority_as_of") == "equals"

    query =
      "in:endpoint_vulnerability_matches authority_generation:>=7 " <>
        "authority_as_of:<2026-09-02T12:30:00Z limit:25"

    assert {:ok, parsed} = Builder.parse(query)

    assert parsed["entity"] == "endpoint_vulnerability_assessments"

    assert [
             %{"field" => "authority_generation", "op" => "gte", "value" => "7"},
             %{
               "field" => "authority_as_of",
               "op" => "lt",
               "value" => "2026-09-02T12:30:00Z"
             }
           ] = parsed["filters"]

    rebuilt = Builder.build(parsed)
    assert rebuilt =~ "authority_generation:>=7"
    assert rebuilt =~ "authority_as_of:<2026-09-02T12:30:00Z"

    structured = Catalog.structured()

    assert "authority_as_of" in structured["entities"]["endpoint_vulnerability_assessments"]["fields"]["timestamp"]
  end

  test "advisory catalogs expose every filter field supported by their Rust queries" do
    advisories = Catalog.entity("vulnerability_advisories")

    for field <- ~w(id description cpe_version) do
      assert field in advisories.filter_fields, field
    end

    coordinates = Catalog.entity("advisory_coordinates")

    for field <- ~w(id cpes cvss_score) do
      assert field in coordinates.filter_fields, field
    end

    assessments = Catalog.entity("endpoint_vulnerability_assessments")

    for field <-
          ~w(id advisory_ref inventory_package_ref scan_ref namespace release distro name package_version version purl purl_canonical cpes) do
      assert field in assessments.filter_fields, field
    end
  end
end
