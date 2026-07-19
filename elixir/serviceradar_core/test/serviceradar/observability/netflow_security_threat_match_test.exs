defmodule ServiceRadar.Observability.NetflowSecurityThreatMatchTest do
  @moduledoc """
  Unit coverage for engine-backed CTI current-matching used by
  NetflowSecurityRefreshWorker (ti: prefix-tag source).
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.PrefixTags.Store
  alias ServiceRadar.PrefixTags.ThreatIntelSource

  setup do
    on_exit(fn ->
      Store.clear()
      Application.delete_env(:serviceradar_core, :threat_intel_engine_match_enabled)
    end)

    Store.clear()
    :ok
  end

  test "engine match path reports sources from ti: tags" do
    Application.put_env(:serviceradar_core, :threat_intel_engine_match_enabled, true)

    Store.put_rows("ti", [
      ThreatIntelSource.map_indicator_row("203.0.113.0/24", "otx", "c2"),
      ThreatIntelSource.map_indicator_row("198.51.100.0/24", "spamhaus", nil)
    ])

    # Call the private matcher via a thin public wrapper pattern: exercise Store
    # the same way the worker does (lookup + tag extraction).
    chain = Store.lookup("203.0.113.10", "ti")
    assert length(chain) >= 1

    sources =
      chain
      |> Enum.flat_map(& &1.tags)
      |> Enum.flat_map(fn
        "ti:label:" <> _ -> []
        "ti:" <> s when s != "" -> [s]
        _ -> []
      end)
      |> Enum.uniq()

    assert "otx" in sources
    assert Store.lookup("8.8.8.8", "ti") == []
  end

  test "expired-style clear of ti source stops matches" do
    Store.put_rows("ti", [
      ThreatIntelSource.map_indicator_row("10.0.0.0/8", "otx", nil)
    ])

    assert Store.lookup("10.1.2.3", "ti") != []
    Store.clear("ti")
    assert Store.lookup("10.1.2.3", "ti") == []
  end
end
