defmodule ServiceRadarWebNGWeb.DeviceLive.InterfaceDataPresenceTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.InterfaceData

  @moduletag :db_free

  defmodule InventorySRQL do
    @moduledoc false
    @behaviour ServiceRadarWebNG.SRQLBehaviour

    @impl true
    def query("in:interfaces" <> _ = query, _opts) do
      if String.contains?(query, "stats:count()") do
        {:ok, %{"results" => [%{"interface_count" => 2}]}}
      else
        {:ok, %{"results" => [%{"if_name" => "eth0", "if_index" => 1}]}}
      end
    end

    def query("in:snmp_metrics" <> _, _opts), do: {:ok, %{"results" => []}}
    def query(_query, _opts), do: {:error, :invalid_query}

    @impl true
    def query_request(%{"query" => query}), do: query(query, %{})
  end

  defmodule SnmpOnlySRQL do
    @moduledoc false
    @behaviour ServiceRadarWebNG.SRQLBehaviour

    @impl true
    def query("in:interfaces" <> _, _opts), do: {:ok, %{"results" => []}}

    def query("in:snmp_metrics" <> _ = query, _opts) do
      if String.contains?(query, "series:if_index") do
        {:ok,
         %{
           "results" => [
             %{"series" => "2", "value" => 80},
             %{"series" => "10", "value" => 80},
             %{"if_index" => 2, "value" => 80}
           ]
         }}
      else
        {:ok, %{"results" => [%{"metric_name" => "ifInOctets", "if_index" => 2}]}}
      end
    end

    def query(_query, _opts), do: {:error, :invalid_query}

    @impl true
    def query_request(%{"query" => query}), do: query(query, %{})
  end

  defmodule EmptySRQL do
    @moduledoc false
    @behaviour ServiceRadarWebNG.SRQLBehaviour

    @impl true
    def query(_query, _opts), do: {:ok, %{"results" => []}}

    @impl true
    def query_request(_payload), do: {:ok, %{"results" => []}}
  end

  test "inventory snapshots still count as interface presence" do
    assert InterfaceData.has_interfaces?(InventorySRQL, "sr:u6-mesh", %{})
  end

  test "SNMP metrics keep the Interfaces tab available without inventory" do
    assert InterfaceData.has_interfaces?(SnmpOnlySRQL, "sr:u6-mesh", %{})
    refute InterfaceData.has_interfaces?(EmptySRQL, "sr:u6-mesh", %{})
  end

  test "empty inventory falls back to SNMP ifIndex rows" do
    {interfaces, error} = InterfaceData.load_interfaces(SnmpOnlySRQL, "sr:u6-mesh", %{})

    assert is_nil(error)
    assert Enum.map(interfaces, & &1["if_index"]) == [2, 10]
    assert Enum.all?(interfaces, &(&1["inferred_from_metrics"] == true))
    assert hd(interfaces)["interface_uid"] == "sr:u6-mesh-if2"
  end

  test "inventory rows win over SNMP inference" do
    {interfaces, error} = InterfaceData.load_interfaces(InventorySRQL, "sr:u6-mesh", %{})

    assert is_nil(error)
    assert Enum.map(interfaces, & &1["if_name"]) == ["eth0"]
    refute Enum.any?(interfaces, &Map.get(&1, "inferred_from_metrics"))
  end
end
