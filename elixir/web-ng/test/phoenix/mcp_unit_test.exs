defmodule ServiceRadarWebNG.McpUnitTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Api.Access
  alias ServiceRadarWebNG.Api.OauthScopes
  alias ServiceRadarWebNG.Mcp
  alias ServiceRadarWebNG.Mcp.Docs

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
    refute text =~ "sidebar_position"
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
