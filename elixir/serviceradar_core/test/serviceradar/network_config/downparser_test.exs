defmodule ServiceRadar.NetworkConfig.DownparserTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.NetworkConfig.Downparser

  test "parser_version is network_config_v1" do
    assert Downparser.parser_version() == "network_config_v1"
  end

  if System.get_env("SERVICERADAR_SKIP_NIF_COMPILATION") == "1" do
    @tag skip: "network_config_nif compilation is disabled"
  end

  test "parse returns interface facts through the loaded NIF" do
    body = """
    interface GigabitEthernet0/1
     ip address 192.0.2.1 255.255.255.0
    """

    assert {:ok, [fact]} = Downparser.parse(body)
    assert fact.if_name == "GigabitEthernet0/1"
    assert fact.ipv4_prefix == "192.0.2.0/24"
  end
end
