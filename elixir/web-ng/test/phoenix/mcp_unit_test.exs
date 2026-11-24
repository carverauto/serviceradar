defmodule ServiceRadarWebNG.McpUnitTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Processors.HorizonProjection
  alias ServiceRadarSRQL.Native
  alias ServiceRadarWebNG.Api.Access
  alias ServiceRadarWebNG.Api.OauthScopes
  alias ServiceRadarWebNG.Mcp
  alias ServiceRadarWebNG.Mcp.Docs
  alias ServiceRadarWebNGWeb.SRQL.Builder
  alias ServiceRadarWebNGWeb.SRQL.Catalog

  @moduletag :db_free

  test "v1 tool allowlist is the read-only facades plus SRQL docs lookup" do
    names =
      Mcp
      |> AshAi.Info.tools()
      |> Enum.map(& &1.name)
      |> Enum.sort()

    assert names == Enum.sort(Mcp.v1_tools())

    assert names == [
             :execute_srql,
             :get_device,
             :get_srql_catalog,
             :horizon_intel_lookup,
             :list_devices,
             :lookup_srql_docs
           ]
  end

  test "v1 MCP resources are the SRQL teaching documents" do
    names =
      Mcp
      |> AshAi.Info.mcp_action_resources()
      |> Enum.map(& &1.name)
      |> Enum.sort()

    assert names == Enum.sort(Mcp.v1_resources())
    assert names == [:srql_cookbook, :srql_entities, :srql_grammar]
  end

  test "initialize instructions point at lookup_srql_docs first" do
    text = Mcp.instructions()
    assert text =~ "lookup_srql_docs"
    assert text =~ "serviceradar://srql/grammar"
    assert text =~ "execute_srql"
    assert text =~ "in:<entity>"
    refute text =~ "SELECT"
  end

  test "grammar resource teaches token shape and forbids SQL and cross-field OR" do
    text = Docs.grammar()
    assert text =~ "in:<entity>"
    assert text =~ "!field:value"
    assert text =~ "time:last_"
    assert text =~ "not SQL"
    assert text =~ "cross-field `OR`"
    assert text =~ "get_srql_catalog"
    refute text =~ "docusaurus"
  end

  test "cookbook resource is recipes not the human tutorial" do
    text = Docs.cookbook()
    assert text =~ "in:devices hostname:%edge%"
    assert text =~ "in:flows"
    assert text =~ "port:22"
    assert text =~ "in:horizon_outages"
    assert text =~ "in:horizon_bgp"
    assert text =~ "in:horizon_zombies"
    assert text =~ "in:horizon_paths"
    assert text =~ "in:horizon_isp_accountability"
    assert text =~ "horizon_intel_lookup"
    refute text =~ "sidebar_position"
  end

  test "every Horizon SRQL cookbook recipe translates against the Rust StarRocks dialect" do
    recipes = extract_horizon_cookbook_recipes(Docs.cookbook())

    assert length(recipes) >= 20

    entities_seen =
      MapSet.new(recipes, fn query ->
        sql = translate_horizon_sql!(query)
        assert sql =~ "FROM serviceradar.horizon_"
        [_, entity] = Regex.run(~r/\bin:(horizon_[a-z_]+)/, query)
        entity
      end)

    assert entities_seen ==
             MapSet.new(~w(horizon_outages horizon_bgp horizon_zombies horizon_paths horizon_isp_accountability))
  end

  test "live entity index and lookup_srql_docs surface all Horizon entities and intel tool" do
    previous = Application.get_env(:serviceradar_web_ng, :srql_catalog)
    Application.put_env(:serviceradar_web_ng, :srql_catalog, fn _scope -> Catalog.structured() end)

    on_exit(fn ->
      if previous do
        Application.put_env(:serviceradar_web_ng, :srql_catalog, previous)
      else
        Application.delete_env(:serviceradar_web_ng, :srql_catalog)
      end
    end)

    index = Docs.entity_index(:unused)

    for id <- ~w(horizon_outages horizon_bgp horizon_zombies horizon_paths horizon_isp_accountability) do
      assert index =~ "`#{id}`"
      assert {:ok, hit} = Docs.lookup(id, :unused)
      assert hit["hit_count"] > 0
      assert "catalog:#{id}" in Enum.map(hit["matches"], & &1["source"])
    end

    assert {:ok, intel_hits} = Docs.lookup("horizon_intel_lookup", :unused)
    assert intel_hits["hit_count"] > 0
    assert intel_hits["text"] =~ "horizon_intel_lookup"
  end

  test "Horizon SRQL catalog entries translate against the Rust StarRocks dialect and cover projector defaults" do
    catalog = Catalog.structured()
    horizon_ids = ~w(horizon_outages horizon_bgp horizon_zombies horizon_paths horizon_isp_accountability)

    for id <- horizon_ids do
      assert {:ok, sliced} = Access.slice_srql_catalog(catalog, id)
      assert Map.keys(sliced["entities"]) == [id]

      assert_horizon_catalog_translates!(id, sliced["entities"][id])
    end

    assert_horizon_enums_cover_projector_defaults!(catalog["entities"])
  end

  test "entity index is generated from the live catalog" do
    previous = Application.get_env(:serviceradar_web_ng, :srql_catalog)

    Application.put_env(:serviceradar_web_ng, :srql_catalog, fn _scope ->
      %{
        "entities" => %{
          "devices" => %{
            "label" => "Devices",
            "default_filter_field" => "hostname",
            "default_time" => ""
          },
          "flows" => %{
            "label" => "NetFlow",
            "default_filter_field" => "src_ip",
            "default_time" => "last_1h"
          }
        }
      }
    end)

    on_exit(fn ->
      if previous do
        Application.put_env(:serviceradar_web_ng, :srql_catalog, previous)
      else
        Application.delete_env(:serviceradar_web_ng, :srql_catalog)
      end
    end)

    text = Docs.entity_index(:unused)
    assert text =~ "`devices`"
    assert text =~ "Devices"
    assert text =~ "`flows`"
    assert text =~ "get_srql_catalog"
  end

  test "lookup_srql_docs returns catalog and cookbook hits for an entity id" do
    with_stub_catalog(fn ->
      assert {:ok, result} = Docs.lookup("devices", :unused)
      assert result["hit_count"] > 0
      sources = Enum.map(result["matches"], & &1["source"])
      assert "catalog:devices" in sources
      assert result["text"] =~ "in:devices"
      assert result["text"] =~ "hostname"
    end)
  end

  test "lookup_srql_docs finds grammar for operators and cookbook for tasks" do
    with_stub_catalog(fn ->
      assert {:ok, time} = Docs.lookup("time:", :unused)
      assert time["text"] =~ "time:last_"

      assert {:ok, ssh} = Docs.lookup("ssh", :unused)
      assert ssh["text"] =~ "port:22"

      assert {:ok, none} = Docs.lookup("zzzznotatoken", :unused)
      assert none["hit_count"] == 0
      assert none["text"] =~ "No SRQL docs matched"
    end)
  end

  test "lookup_srql_docs rejects a blank query" do
    assert {:error, message} = Docs.lookup("  ", :unused)
    assert message =~ "query is required"
  end

  test "slice_srql_catalog keeps one entity or errors on unknown ids" do
    catalog = %{
      "control_tokens" => ["in:", "time:"],
      "entities" => %{
        "devices" => %{"label" => "Devices", "fields" => %{}},
        "logs" => %{"label" => "Logs", "fields" => %{}}
      }
    }

    assert {:ok, sliced} = Access.slice_srql_catalog(catalog, "devices")
    assert Map.keys(sliced["entities"]) == ["devices"]
    assert sliced["control_tokens"] == ["in:", "time:"]

    assert {:ok, ^catalog} = Access.slice_srql_catalog(catalog, nil)
    assert {:error, message} = Access.slice_srql_catalog(catalog, "nope")
    assert message =~ "unknown SRQL entity"
    assert message =~ "devices"
  end

  test "wrap_tool_arguments nests a flat map under input" do
    assert {:ok, %{"input" => %{"query" => "in:devices"}}} =
             Mcp.wrap_tool_arguments(:execute_srql, %{"query" => "in:devices"}, %{})
  end

  test "wrap_tool_arguments leaves an AshAi input wrapper intact" do
    args = %{"input" => %{"uid" => "device-1"}}

    assert {:ok, ^args} = Mcp.wrap_tool_arguments(:get_device, args, %{})
  end

  test "mcp is a compiled OAuth scope atom" do
    assert :mcp in OauthScopes.all()
    assert OauthScopes.valid_name?("mcp")
    assert OauthScopes.to_atom("mcp") == :mcp
  end

  test "parse_uid rejects injection payloads and empty values" do
    assert {:error, {:invalid, "invalid uid"}} = Access.parse_uid("device' OR '1'='1")
    assert {:error, {:invalid, "invalid uid"}} = Access.parse_uid("")
    assert {:error, {:invalid, "invalid uid"}} = Access.parse_uid(nil)
    assert {:ok, "host.example"} = Access.parse_uid("host.example")
  end

  test "clamp_limit and clamp_offset match HTTP caps" do
    assert Access.clamp_limit(nil) == 100
    assert Access.clamp_limit(10_000) == 500
    assert Access.clamp_offset(-1) == 0
    assert Access.clamp_offset(1_000_000) == 100_000
  end

  defp assert_horizon_catalog_translates!(id, meta) do
    fields = meta["fields"]
    filter_fields = fields["filter"]
    numeric_fields = fields["numeric"]
    boolean_fields = fields["boolean"]
    address_fields = fields["address"]

    assert filter_fields != []
    assert meta["default_filter_field"] in filter_fields
    assert MapSet.subset?(MapSet.new(numeric_fields ++ boolean_fields ++ address_fields), MapSet.new(filter_fields))

    default_query = id |> Builder.default_state(10) |> Builder.build()
    default_sql = translate_horizon_sql!(default_query)
    sort_field = meta["default_sort"]["field"]
    sort_dir = String.upcase(meta["default_sort"]["direction"])
    assert default_sql =~ "ORDER BY `#{sort_field}` #{sort_dir}"

    for field <- filter_fields do
      {query, expected_sql} =
        horizon_filter_probe(id, field, numeric_fields, boolean_fields, address_fields)

      assert translate_horizon_sql!(query) =~ expected_sql
    end

    assert_horizon_enums_translate!(id, filter_fields, meta["enums"])
  end

  defp assert_horizon_enums_translate!(id, filter_fields, enums) do
    for {field, values} <- enums do
      assert field in filter_fields
      assert values != []

      Enum.each(values, fn value ->
        assert translate_horizon_sql!("in:#{id} #{field}:#{value} limit:5") =~ "`#{field}` ="
      end)
    end
  end

  defp horizon_filter_probe(id, field, numeric_fields, boolean_fields, address_fields) do
    cond do
      field in numeric_fields ->
        {"in:#{id} #{field}:>=1 limit:5", "`#{field}` >= 1"}

      field in boolean_fields ->
        {"in:#{id} #{field}:true limit:5", "`#{field}` = TRUE"}

      field in address_fields ->
        {"in:#{id} #{field}:198.51.100.1 limit:5", "`#{field}` = '198.51.100.1'"}

      true ->
        {"in:#{id} #{field}:sample limit:5", "`#{field}` = 'sample'"}
    end
  end

  defp translate_horizon_sql!(query) do
    assert {:ok, json} = Native.translate(query, nil, nil, nil, "starrocks"),
           "expected StarRocks SRQL translation to accept #{inspect(query)}"

    %{"sql" => sql} = Jason.decode!(json)
    sql
  end

  defp assert_horizon_enums_cover_projector_defaults!(entities) do
    now = ~U[2026-11-23 16:00:00Z]

    projections =
      HorizonProjection.build_projections([
        %{log_name: "horizon.outage", time: now, unmapped: %{"outage_id" => "out-1"}},
        %{
          log_name: "horizon.bgp_anomaly",
          time: now,
          unmapped: %{"event_id" => "bgp-1", "covering_prefix" => "198.51.100.0/24"}
        },
        %{
          log_name: "horizon.bgp_watchlist",
          time: now,
          unmapped: %{"event_id" => "wl-1", "observed_prefix" => "198.51.100.0/24"}
        },
        %{
          log_name: "horizon.bgp_zombie",
          time: now,
          unmapped: %{"episode_id" => "ep-1", "covering_prefix" => "198.51.100.0/24"}
        },
        %{
          log_name: "horizon.path_hop",
          time: now,
          unmapped: %{"round_id" => "r-1", "target_id" => "t-1", "pop_id" => "pop-1", "hop_ttl" => 1}
        }
      ])

    projected_by_entity = [
      {"horizon_outages", projections.outages},
      {"horizon_bgp", projections.bgp_events},
      {"horizon_zombies", projections.bgp_zombies},
      {"horizon_paths", projections.path_hops}
    ]

    for {entity_id, rows} <- projected_by_entity do
      assert rows != []
      assert_projected_defaults_in_enums!(entity_id, rows, entities[entity_id]["enums"])
    end
  end

  defp assert_projected_defaults_in_enums!(entity_id, rows, enums) do
    for row <- rows,
        string_row = Map.new(row, fn {k, v} -> {Atom.to_string(k), v} end),
        {field, allowed_values} <- enums do
      projected_value = string_row |> Map.fetch!(field) |> to_string()

      assert projected_value in allowed_values,
             "expected #{entity_id}.#{field} enum #{inspect(allowed_values)} to include projected default #{inspect(projected_value)}"
    end
  end

  defp extract_horizon_cookbook_recipes(cookbook) do
    [_before, horizon_section] =
      String.split(cookbook, "## Horizon Internet Weather, BGP, Zombies, and Multipath Paths", parts: 2)

    [section_body | _rest] = String.split(horizon_section, "\n## ", parts: 2)

    ~r/```\n(.*?)\n```/s
    |> Regex.scan(section_body, capture: :all_but_first)
    |> List.flatten()
    |> Enum.flat_map(&String.split(&1, "\n", trim: true))
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "in:horizon_"))
    |> Enum.map(fn query ->
      query
      |> String.replace("<watchlist-id>", "wl-sample-1")
      |> String.replace("<target-id>", "tgt-sample-1")
      |> String.replace("<round-id>", "rnd-sample-1")
    end)
  end

  defp with_stub_catalog(fun) do
    previous = Application.get_env(:serviceradar_web_ng, :srql_catalog)

    Application.put_env(:serviceradar_web_ng, :srql_catalog, fn _scope ->
      %{
        "entities" => %{
          "devices" => %{
            "label" => "Devices",
            "default_filter_field" => "hostname",
            "default_time" => "",
            "fields" => %{
              "filter" => ["hostname", "ip", "uid"],
              "boolean" => ["is_available"]
            },
            "enums" => %{"discovery_sources" => ["agent", "sweep"]}
          }
        }
      }
    end)

    try do
      fun.()
    after
      if previous do
        Application.put_env(:serviceradar_web_ng, :srql_catalog, previous)
      else
        Application.delete_env(:serviceradar_web_ng, :srql_catalog)
      end
    end
  end
end
