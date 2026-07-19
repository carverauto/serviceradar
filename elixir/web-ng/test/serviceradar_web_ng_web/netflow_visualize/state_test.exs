defmodule ServiceRadarWebNGWeb.NetflowVisualize.StateTest do
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :db_free

  alias ServiceRadarWebNGWeb.NetflowVisualize.State

  test "default state includes nil prefix_tag" do
    assert State.default()["prefix_tag"] == nil
  end

  test "normalize accepts multi-colon tag values" do
    assert {:ok, state} =
             State.encode_param(%{"prefix_tag" => "netbox:tag:iot"})
             |> then(fn {:ok, encoded} -> State.decode_param(encoded) end)

    assert state["prefix_tag"] == "netbox:tag:iot"
  end

  test "normalize treats blank prefix_tag as nil" do
    assert {:ok, encoded} = State.encode_param(%{"prefix_tag" => "  "})
    assert {:ok, state} = State.decode_param(encoded)
    assert state["prefix_tag"] == nil
  end

  test "normalize rejects invalid prefix_tag characters" do
    assert {:error, :invalid_prefix_tag} =
             State.encode_param(%{"prefix_tag" => "bad tag with spaces"})
  end

  test "normalize rejects overly long prefix_tag" do
    long = String.duplicate("a", 129)

    assert {:error, :invalid_prefix_tag} =
             State.encode_param(%{"prefix_tag" => long})
  end

  test "round-trip preserves other fields with prefix_tag" do
    raw = %{
      "graph" => "lines",
      "units" => "bps",
      "time" => "last_24h",
      "prefix_tag" => "site:austin"
    }

    assert {:ok, encoded} = State.encode_param(raw)
    assert {:ok, state} = State.decode_param(encoded)
    assert state["graph"] == "lines"
    assert state["units"] == "bps"
    assert state["time"] == "last_24h"
    assert state["prefix_tag"] == "site:austin"
  end
end
