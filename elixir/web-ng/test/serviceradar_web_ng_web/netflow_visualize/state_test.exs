defmodule ServiceRadarWebNGWeb.NetflowVisualize.StateTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Netflow.PrefixTagQuery
  alias ServiceRadarWebNGWeb.NetflowVisualize.State

  @moduletag :unit
  @moduletag :db_free

  test "default state does not include prefix_tag (query-only contract)" do
    refute Map.has_key?(State.default(), "prefix_tag")
  end

  test "normalize ignores legacy prefix_tag key in encoded state" do
    assert {:ok, encoded} =
             State.encode_param(%{
               "graph" => "lines",
               "prefix_tag" => "netbox:tag:iot"
             })

    assert {:ok, state} = State.decode_param(encoded)
    assert state["graph"] == "lines"
    refute Map.has_key?(state, "prefix_tag")
  end

  test "normalize treats blank optional fields as defaults" do
    assert {:ok, encoded} = State.encode_param(%{"units" => "bps"})
    assert {:ok, state} = State.decode_param(encoded)
    assert state["units"] == "bps"
  end

  test "round-trip preserves graph/units/time without prefix_tag" do
    raw = %{
      "graph" => "lines",
      "units" => "bps",
      "time" => "last_24h"
    }

    assert {:ok, encoded} = State.encode_param(raw)
    assert {:ok, state} = State.decode_param(encoded)
    assert state["graph"] == "lines"
    assert state["units"] == "bps"
    assert state["time"] == "last_24h"
  end

  test "PrefixTagQuery validates multi-colon tag values" do
    assert {:ok, "netbox:tag:iot"} = PrefixTagQuery.validate_tag("netbox:tag:iot")
  end

  test "PrefixTagQuery rejects invalid and overlong tags" do
    assert {:error, :invalid_chars} = PrefixTagQuery.validate_tag("bad tag with spaces")
    long = String.duplicate("a", 129)
    assert {:error, :too_long} = PrefixTagQuery.validate_tag(long)
  end
end
