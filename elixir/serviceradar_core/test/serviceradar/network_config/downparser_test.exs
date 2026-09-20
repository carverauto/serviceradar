defmodule ServiceRadar.NetworkConfig.DownparserTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.NetworkConfig.Downparser

  test "parser_version is network_config_v1" do
    assert Downparser.parser_version() == "network_config_v1"
  end

  test "parse reports a clear error when the NIF is not loaded" do
    case Downparser.parse("interface GigabitEthernet0/1\n") do
      {:ok, facts} when is_list(facts) ->
        assert Enum.any?(facts, &(&1.if_name == "GigabitEthernet0/1"))

      {:error, reason} ->
        assert reason =~ "nif"
    end
  end
end
