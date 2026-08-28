defmodule ServiceRadarWebNG.McpUnitTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Api.Access
  alias ServiceRadarWebNG.Api.OauthScopes
  alias ServiceRadarWebNG.Mcp

  @moduletag :db_free

  test "v1 tool allowlist is the four read-only facades" do
    names =
      Mcp
      |> AshAi.Info.tools()
      |> Enum.map(& &1.name)
      |> Enum.sort()

    assert names == Enum.sort(Mcp.v1_tools())
    assert names == [:execute_srql, :get_device, :get_srql_catalog, :list_devices]
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
end
